import AVFoundation
import Foundation

enum VibeVoiceRunnerError: LocalizedError {
    case invalidBaseURL(String)
    case invalidCompletionResponse
    case invalidRawTextPayload
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            "Invalid VibeVoice API base URL: \(value)"
        case .invalidCompletionResponse:
            "VibeVoice completion response was invalid"
        case .invalidRawTextPayload:
            "VibeVoice raw_text payload could not be parsed"
        case .processFailed(let message):
            message
        }
    }
}

protocol VibeVoiceRunning {
    func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: (@Sendable (MeetingTranscriptionProgress) async -> Void)?
    ) async throws -> MeetingTranscriptionResult
}

final class VibeVoiceRunnerClient: VibeVoiceRunning {
    private enum Timeout {
        static let request: TimeInterval = 600
    }

    static let systemPrompt = "You are a helpful assistant that transcribes audio input into text output in JSON format."
    private static let maxModelContextTokens = 16384
    private static let tokenSafetyBuffer = 128
    private static let targetRequestJSONBytes = 1_500_000
    private static let defaultChunkDuration: TimeInterval = 20 * 60
    private static let minimumChunkDuration: TimeInterval = 10
    private static let overlapDuration: TimeInterval = 3
    private static let maximumBoundarySearchWindow: TimeInterval = 5
    private static let truncatedChunkRetryMinimumDuration: TimeInterval = 40 * 60
    private static let timestampGraceDuration: TimeInterval = 1.5
    private static let timedOutChunkRetryMinimumDuration: TimeInterval = 40 * 60

    private struct ContextLimitAdjustment: Equatable {
        let requestedMaxTokens: Int
        let adjustedMaxTokens: Int
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let configProvider: MeetingVibeVoiceConfigProviding
    private let chunkDuration: TimeInterval

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        configProvider: MeetingVibeVoiceConfigProviding = AppPreferences.shared,
        chunkDuration: TimeInterval = defaultChunkDuration
    ) {
        self.session = session
        self.decoder = decoder
        self.configProvider = configProvider
        self.chunkDuration = chunkDuration
    }

    func transcribe(
        audioURL: URL,
        hotwords: [String] = [],
        progress: (@Sendable (MeetingTranscriptionProgress) async -> Void)? = nil
    ) async throws -> MeetingTranscriptionResult {
        let config = configProvider.meetingVibeVoiceConfig
        let startedAt = Date()
        let fileSizeBytes = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        MeetingLog.info(
            "VibeVoice transcription start file=\(audioURL.lastPathComponent) size=\(Self.formattedFileSize(fileSizeBytes))"
        )

        guard let requestURL = config.chatCompletionsURL() else {
            throw VibeVoiceRunnerError.invalidBaseURL(config.baseURL)
        }

        await progress?(.preparingAudio())
        let effectiveChunkDuration = Self.resolvedChunkDuration(
            audioURL: audioURL,
            configuredChunkDuration: chunkDuration,
            targetRequestJSONBytes: Self.targetRequestJSONBytes
        )
        let audioChunks = Self.makeAudioChunks(audioURL: audioURL, chunkDuration: effectiveChunkDuration)
        defer { audioChunks.cleanup() }
        let promptText = Self.makePromptText(contextInfo: config.combinedContextInfo(hotwords: hotwords))
        await progress?(.analyzingAudio(
            estimatedChunkCount: audioChunks.items.count,
            chunkDuration: effectiveChunkDuration
        ))
        if audioChunks.items.count > 1 {
            MeetingLog.info(
                "VibeVoice transcription split into \(audioChunks.items.count) chunks duration=\(effectiveChunkDuration)s overlap=\(Self.resolvedOverlapDuration(for: effectiveChunkDuration))s"
            )
        }
        MeetingLog.info("VibeVoice chat completion request url=\(requestURL.absoluteString)")

        RequestLogStore.log(.asr, "Meeting ASR chat completions -> \(requestURL.absoluteString)")

        var mergedSegments: [MeetingTranscriptionSegmentPayload] = []
        for (chunkIndex, chunk) in audioChunks.items.enumerated() {
            let displayIndex = chunkIndex + 1
            let totalChunks = audioChunks.items.count
            await progress?(.uploadingAudio(chunkIndex: displayIndex, totalChunks: totalChunks))
            await progress?(.transcribing(
                chunkIndex: displayIndex,
                totalChunks: totalChunks,
                chunkStartTime: chunk.timeOffset,
                chunkEndTime: chunk.timeOffset + chunk.duration
            ))
            let chunkSegments = try await transcribeChunk(
                chunk,
                requestURL: requestURL,
                promptText: promptText,
                config: config,
                recursionDepth: 0,
                requestOrdinal: displayIndex,
                totalRequests: totalChunks
            )
            mergedSegments.append(contentsOf: chunkSegments)
            MeetingLog.info("VibeVoice chunk completed index=\(chunkIndex + 1)/\(audioChunks.items.count) segments=\(chunkSegments.count)")
        }

        await progress?(.finalizing())
        mergedSegments = Self.mergeSegmentsDroppingOverlapDuplicates(mergedSegments)
        let fullText = mergedSegments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let result = MeetingTranscriptionResult(fullText: fullText, segments: mergedSegments)
        MeetingLog.info(
            "VibeVoice transcription completed segments=\(result.segments.count) elapsed=\(Self.formattedElapsed(since: startedAt))"
        )
        return result
    }

    private func transcribeChunk(
        _ chunk: AudioChunk,
        requestURL: URL,
        promptText: String,
        config: MeetingVibeVoiceConfig,
        recursionDepth: Int,
        requestOrdinal: Int,
        totalRequests: Int
    ) async throws -> [MeetingTranscriptionSegmentPayload] {
        RequestLogStore.log(
            .asr,
            Self.chunkLogMessage(
                "Meeting ASR chunk started",
                chunk: chunk,
                recursionDepth: recursionDepth,
                requestOrdinal: requestOrdinal,
                totalRequests: totalRequests
            )
        )

        do {
            let audioDataURL = try Self.makeAudioDataURL(audioURL: chunk.url)
            let completion = try await requestCompletion(
                requestURL: requestURL,
                audioDataURL: audioDataURL,
                promptText: promptText,
                config: config
            )
            guard let choice = completion.choices.first else {
                throw VibeVoiceRunnerError.invalidCompletionResponse
            }
            guard
                let content = choice.message.content,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                MeetingLog.error("VibeVoice completion invalid response body=\(String(describing: completion.choices.first?.message.content?.prefix(2000)))")
                throw VibeVoiceRunnerError.invalidCompletionResponse
            }

            do {
                let sanitizedSegments = try transcribeChunkContent(content, chunk: chunk)
                RequestLogStore.log(
                    .asr,
                    Self.chunkLogMessage(
                        "Meeting ASR chunk completed segments=\(sanitizedSegments.count)",
                        chunk: chunk,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests
                    )
                )
                return sanitizedSegments
            } catch {
                let finishReason = choice.finishReason?.lowercased() ?? ""
                let preview = String(content.prefix(2000))
                MeetingLog.error(
                    "VibeVoice chunk parse failed depth=\(recursionDepth) finishReason=\(finishReason) duration=\(chunk.duration) preview=\(preview)"
                )

                if Self.isLikelyNonSpeechOnlyPayload(content) {
                    MeetingLog.info("VibeVoice chunk skipped as non-speech placeholder output duration=\(chunk.duration)")
                    RequestLogStore.log(
                        .asr,
                        Self.chunkLogMessage(
                            "Meeting ASR chunk skipped non-speech placeholder output",
                            chunk: chunk,
                            recursionDepth: recursionDepth,
                            requestOrdinal: requestOrdinal,
                            totalRequests: totalRequests
                        )
                    )
                    return []
                }

                if finishReason == "length",
                   recursionDepth < 2,
                   chunk.duration >= Self.truncatedChunkRetryMinimumDuration {
                    RequestLogStore.log(
                        .asr,
                        Self.chunkLogMessage(
                            "Meeting ASR chunk retrying because response was truncated",
                            chunk: chunk,
                            recursionDepth: recursionDepth,
                            requestOrdinal: requestOrdinal,
                            totalRequests: totalRequests
                        )
                    )
                    return try await transcribeUsingSmallerChunks(
                        chunk,
                        requestURL: requestURL,
                        promptText: promptText,
                        config: config,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests,
                        targetChunkDuration: max(Self.minimumChunkDuration / 2, chunk.duration * 0.51)
                    )
                }

                RequestLogStore.log(
                    .asr,
                    Self.chunkLogMessage(
                        "Meeting ASR chunk failed \(error.localizedDescription)",
                        chunk: chunk,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests
                    )
                )
                throw error
            }
        } catch {
            if Self.isTimeoutError(error) {
                MeetingLog.error(
                    "VibeVoice chunk timeout depth=\(recursionDepth) range=\(Self.formattedTimestamp(chunk.timeOffset))-\(Self.formattedTimestamp(chunk.timeOffset + chunk.duration)) duration=\(String(format: "%.2f", chunk.duration))s"
                )
                RequestLogStore.log(
                    .asr,
                    Self.chunkLogMessage(
                        "Meeting ASR chunk timed out",
                        chunk: chunk,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests
                    )
                )

                if recursionDepth < 3,
                   chunk.duration >= Self.timedOutChunkRetryMinimumDuration {
                    return try await transcribeUsingSmallerChunks(
                        chunk,
                        requestURL: requestURL,
                        promptText: promptText,
                        config: config,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests,
                        targetChunkDuration: max(Self.timedOutChunkRetryMinimumDuration / 2, chunk.duration * 0.51)
                    )
                }

                let friendlyError = VibeVoiceRunnerError.processFailed(
                    Self.friendlyTimeoutMessage(
                        chunk: chunk,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests
                    )
                )
                RequestLogStore.log(
                    .asr,
                    Self.chunkLogMessage(
                        "Meeting ASR chunk failed \(friendlyError.localizedDescription)",
                        chunk: chunk,
                        recursionDepth: recursionDepth,
                        requestOrdinal: requestOrdinal,
                        totalRequests: totalRequests
                    )
                )
                throw friendlyError
            }

            RequestLogStore.log(
                .asr,
                Self.chunkLogMessage(
                    "Meeting ASR chunk failed \(error.localizedDescription)",
                    chunk: chunk,
                    recursionDepth: recursionDepth,
                    requestOrdinal: requestOrdinal,
                    totalRequests: totalRequests
                )
            )
            throw error
        }
    }

    private func transcribeChunkContent(
        _ content: String,
        chunk: AudioChunk
    ) throws -> [MeetingTranscriptionSegmentPayload] {
        let chunkResult = try Self.decodeResult(
            from: Data(content.utf8),
            decoder: decoder,
            timeOffset: chunk.timeOffset,
            sequenceOffset: 0
        )
        return Self.sanitizedSegments(
            chunkResult.segments,
            chunkStartTime: chunk.timeOffset,
            chunkDuration: chunk.duration
        )
    }

    private func transcribeUsingSmallerChunks(
        _ chunk: AudioChunk,
        requestURL: URL,
        promptText: String,
        config: MeetingVibeVoiceConfig,
        recursionDepth: Int,
        requestOrdinal: Int,
        totalRequests: Int,
        targetChunkDuration: TimeInterval
    ) async throws -> [MeetingTranscriptionSegmentPayload] {
        let retryChunks = Self.makeAudioChunks(
            audioURL: chunk.url,
            chunkDuration: targetChunkDuration,
            alignToLowEnergyBoundary: false
        )
        defer { retryChunks.cleanup() }

        guard retryChunks.items.count > 1 else {
            throw VibeVoiceRunnerError.processFailed(
                Self.friendlyTimeoutMessage(
                    chunk: chunk,
                    requestOrdinal: requestOrdinal,
                    totalRequests: totalRequests
                )
            )
        }

        RequestLogStore.log(
            .asr,
            Self.chunkLogMessage(
                "Meeting ASR chunk retrying with smaller subchunks x\(retryChunks.items.count)",
                chunk: chunk,
                recursionDepth: recursionDepth,
                requestOrdinal: requestOrdinal,
                totalRequests: totalRequests
            )
        )

        var retriedSegments: [MeetingTranscriptionSegmentPayload] = []
        for retryChunk in retryChunks.items {
            let absoluteChunk = AudioChunk(
                url: retryChunk.url,
                timeOffset: chunk.timeOffset + retryChunk.timeOffset,
                duration: retryChunk.duration
            )
            let retryResult = try await transcribeChunk(
                absoluteChunk,
                requestURL: requestURL,
                promptText: promptText,
                config: config,
                recursionDepth: recursionDepth + 1,
                requestOrdinal: requestOrdinal,
                totalRequests: totalRequests
            )
            retriedSegments.append(contentsOf: retryResult)
        }
        return retriedSegments
    }

    private struct AudioChunk {
        let url: URL
        let timeOffset: TimeInterval
        let duration: TimeInterval
    }

    private struct AudioChunks {
        let items: [AudioChunk]
        let temporaryDirectory: URL?

        func cleanup() {
            guard let temporaryDirectory else { return }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

#if DEBUG
    static func chunkTimeOffsetsForTesting(
        audioURL: URL,
        chunkDuration: TimeInterval
    ) -> [TimeInterval] {
        let chunks = makeAudioChunks(audioURL: audioURL, chunkDuration: chunkDuration)
        defer { chunks.cleanup() }
        return chunks.items.map(\.timeOffset)
    }
#endif

    private static func makeAudioChunks(
        audioURL: URL,
        chunkDuration: TimeInterval,
        alignToLowEnergyBoundary: Bool = true
    ) -> AudioChunks {
        guard chunkDuration > 0 else {
            return AudioChunks(items: [.init(url: audioURL, timeOffset: 0, duration: Self.audioDuration(audioURL) ?? 0)], temporaryDirectory: nil)
        }

        do {
            let sourceFile = try AVAudioFile(forReading: audioURL)
            let sampleRate = sourceFile.processingFormat.sampleRate
            let totalFrames = sourceFile.length
            let chunkFrames = AVAudioFramePosition(ceil(chunkDuration * sampleRate))
            let overlapFrames = AVAudioFramePosition(ceil(Self.resolvedOverlapDuration(for: chunkDuration) * sampleRate))

            guard chunkFrames > 0, totalFrames > chunkFrames else {
                return AudioChunks(
                    items: [.init(url: audioURL, timeOffset: 0, duration: Double(totalFrames) / sampleRate)],
                    temporaryDirectory: nil
                )
            }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("neutype-vibevoice-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            var chunks: [AudioChunk] = []
            var startFrame: AVAudioFramePosition = 0
            var index = 0

            while startFrame < totalFrames {
                let nominalEndFrame = min(startFrame + chunkFrames, totalFrames)
                let endFrame = alignToLowEnergyBoundary && nominalEndFrame < totalFrames
                    ? lowEnergyBoundaryFrame(
                        sourceFile: sourceFile,
                        nominalEndFrame: nominalEndFrame,
                        chunkStartFrame: startFrame,
                        chunkFrames: chunkFrames,
                        totalFrames: totalFrames,
                        sampleRate: sampleRate
                    ) ?? nominalEndFrame
                    : nominalEndFrame
                let framesInChunk = endFrame - startFrame
                let chunkURL = temporaryDirectory
                    .appendingPathComponent("chunk-\(index)")
                    .appendingPathExtension("wav")
                try writeAudioChunk(
                    sourceFile: sourceFile,
                    outputURL: chunkURL,
                    startFrame: startFrame,
                    frameCount: framesInChunk
                )
                chunks.append(
                    AudioChunk(
                        url: chunkURL,
                        timeOffset: Double(startFrame) / sampleRate,
                        duration: Double(framesInChunk) / sampleRate
                    )
                )
                guard endFrame < totalFrames else { break }
                let nextStartFrame = max(endFrame - overlapFrames, startFrame + 1)
                startFrame = nextStartFrame
                index += 1
            }

            return AudioChunks(items: chunks, temporaryDirectory: temporaryDirectory)
        } catch {
            MeetingLog.error("VibeVoice audio split failed, falling back to original file: \(error.localizedDescription)")
            return AudioChunks(items: [.init(url: audioURL, timeOffset: 0, duration: Self.audioDuration(audioURL) ?? 0)], temporaryDirectory: nil)
        }
    }

    private static func resolvedOverlapDuration(for chunkDuration: TimeInterval) -> TimeInterval {
        guard chunkDuration >= overlapDuration * 4 else { return 0 }
        return min(overlapDuration, chunkDuration * 0.15)
    }

    private static func boundarySearchWindowDuration(for chunkDuration: TimeInterval) -> TimeInterval {
        min(maximumBoundarySearchWindow, max(0.25, chunkDuration * 0.2))
    }

    private static func lowEnergyBoundaryFrame(
        sourceFile: AVAudioFile,
        nominalEndFrame: AVAudioFramePosition,
        chunkStartFrame: AVAudioFramePosition,
        chunkFrames: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        sampleRate: Double
    ) -> AVAudioFramePosition? {
        let originalFramePosition = sourceFile.framePosition
        defer { sourceFile.framePosition = originalFramePosition }

        let searchWindowFrames = AVAudioFramePosition(ceil(
            boundarySearchWindowDuration(for: Double(chunkFrames) / sampleRate) * sampleRate
        ))
        let minimumFramesBeforeBoundary = max(
            AVAudioFramePosition(ceil(0.2 * sampleRate)),
            chunkFrames / 2
        )
        let lowerBoundFrame = max(chunkStartFrame + minimumFramesBeforeBoundary, nominalEndFrame - searchWindowFrames)
        let upperBoundFrame = min(totalFrames, nominalEndFrame + searchWindowFrames)
        guard upperBoundFrame > lowerBoundFrame else { return nil }

        let format = sourceFile.processingFormat
        let framesToRead = AVAudioFrameCount(min(
            AVAudioFramePosition(UInt32.max),
            upperBoundFrame - lowerBoundFrame
        ))
        guard
            framesToRead > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead)
        else {
            return nil
        }

        do {
            sourceFile.framePosition = lowerBoundFrame
            try sourceFile.read(into: buffer, frameCount: framesToRead)
        } catch {
            MeetingLog.error("VibeVoice boundary analysis failed: \(error.localizedDescription)")
            return nil
        }

        guard
            buffer.frameLength > 0,
            let channelData = buffer.floatChannelData
        else {
            return nil
        }

        let analysisWindowFrames = max(
            AVAudioFrameCount(1),
            min(AVAudioFrameCount(max(1, Int(sampleRate * 0.08))), max(AVAudioFrameCount(1), buffer.frameLength / 4))
        )
        let stepFrames = max(AVAudioFrameCount(1), analysisWindowFrames / 2)
        guard buffer.frameLength >= analysisWindowFrames else { return nil }

        var bestLocalFrame: AVAudioFrameCount = 0
        var bestEnergy = Double.greatestFiniteMagnitude
        var localFrame: AVAudioFrameCount = 0
        while localFrame + analysisWindowFrames <= buffer.frameLength {
            let energy = rmsEnergy(
                channelData: channelData,
                channelCount: Int(format.channelCount),
                startFrame: localFrame,
                frameCount: analysisWindowFrames
            )
            if energy < bestEnergy {
                bestEnergy = energy
                bestLocalFrame = localFrame
            }
            localFrame += stepFrames
        }

        let nominalLocalFrame = AVAudioFrameCount(max(0, min(
            AVAudioFramePosition(buffer.frameLength - analysisWindowFrames),
            nominalEndFrame - lowerBoundFrame
        )))
        let nominalEnergy = rmsEnergy(
            channelData: channelData,
            channelCount: Int(format.channelCount),
            startFrame: nominalLocalFrame,
            frameCount: analysisWindowFrames
        )
        let hasMeaningfulSilence = bestEnergy < 0.02 || bestEnergy < nominalEnergy * 0.45
        guard hasMeaningfulSilence else { return nil }

        let boundaryFrame = lowerBoundFrame
            + AVAudioFramePosition(bestLocalFrame)
            + AVAudioFramePosition(analysisWindowFrames / 2)
        guard boundaryFrame > chunkStartFrame, boundaryFrame < totalFrames else {
            return nil
        }
        return boundaryFrame
    }

    private static func rmsEnergy(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        startFrame: AVAudioFrameCount,
        frameCount: AVAudioFrameCount
    ) -> Double {
        guard channelCount > 0, frameCount > 0 else { return .greatestFiniteMagnitude }

        var sum = 0.0
        for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for frameOffset in 0..<Int(frameCount) {
                let sample = Double(channel[Int(startFrame) + frameOffset])
                sum += sample * sample
            }
        }

        return sqrt(sum / Double(channelCount * Int(frameCount)))
    }

    private static func audioDuration(_ audioURL: URL) -> TimeInterval? {
        guard
            let audioFile = try? AVAudioFile(forReading: audioURL),
            audioFile.processingFormat.sampleRate > 0
        else {
            return nil
        }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    static func resolvedChunkDuration(
        audioURL: URL,
        configuredChunkDuration: TimeInterval,
        targetRequestJSONBytes: Int
    ) -> TimeInterval {
        _ = targetRequestJSONBytes
        guard configuredChunkDuration > 0 else {
            return configuredChunkDuration
        }
        return configuredChunkDuration
    }

    private static func writeAudioChunk(
        sourceFile: AVAudioFile,
        outputURL: URL,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition
    ) throws {
        let format = sourceFile.processingFormat
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        sourceFile.framePosition = startFrame

        var remainingFrames = frameCount
        let maxBufferFrames: AVAudioFrameCount = 8_192

        while remainingFrames > 0 {
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(maxBufferFrames), remainingFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw VibeVoiceRunnerError.processFailed("Unable to allocate audio chunk buffer.")
            }
            try sourceFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
            remainingFrames -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func requestCompletion(
        requestURL: URL,
        audioDataURL: String,
        promptText: String,
        config: MeetingVibeVoiceConfig
    ) async throws -> VibeVoiceChatCompletionResponse {
        let initialMaxTokens = Self.resolvedMaxTokens(
            configuredMaxTokens: config.maxNewTokens,
            promptText: promptText
        )
        let firstAttempt = try await sendStreamingChatCompletionRequest(
            requestURL: requestURL,
            audioDataURL: audioDataURL,
            promptText: promptText,
            maxTokens: initialMaxTokens,
            temperature: config.temperature,
            apiKey: config.trimmedAPIKey
        )

        switch firstAttempt {
        case .success(let completion):
            return completion
        case .retry(let adjustment):
            MeetingLog.info(
                "VibeVoice retrying with reduced max_tokens requested=\(adjustment.requestedMaxTokens) adjusted=\(adjustment.adjustedMaxTokens)"
            )
            let secondAttempt = try await sendStreamingChatCompletionRequest(
                requestURL: requestURL,
                audioDataURL: audioDataURL,
                promptText: promptText,
                maxTokens: adjustment.adjustedMaxTokens,
                temperature: config.temperature,
                apiKey: config.trimmedAPIKey
            )

            switch secondAttempt {
            case .success(let completion):
                return completion
            case .retry:
                throw VibeVoiceRunnerError.processFailed(
                    "VibeVoice request could not satisfy the model context limit after retry."
                )
            }
        }
    }

    private func sendStreamingChatCompletionRequest(
        requestURL: URL,
        audioDataURL: String,
        promptText: String,
        maxTokens: Int,
        temperature: Double,
        apiKey: String
    ) async throws -> ChatCompletionAttempt {
        let requestBody = VibeVoiceChatCompletionRequest(
            model: "vibevoice",
            messages: [
                .init(role: "system", content: .text(Self.systemPrompt)),
                .init(
                    role: "user",
                    content: .parts(
                        [
                            .audioURL(url: audioDataURL),
                            .text(promptText),
                        ]
                    )
                ),
            ],
            maxTokens: maxTokens,
            temperature: temperature,
            stream: true
        )

        let requestBodyData = try JSONEncoder().encode(requestBody)

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Timeout.request
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        request.httpBody = requestBodyData

        let requestArtifactURL = Self.persistDebugArtifact(
            prefix: "request",
            pathExtension: "json",
            data: requestBodyData
        )
        let curlCommand = Self.makeDebugCurlCommand(
            requestURL: requestURL,
            apiKey: apiKey,
            requestBodyFileURL: requestArtifactURL
        )
        RequestLogStore.log(.asr, "Meeting ASR curl -> \(curlCommand)")
        if let requestArtifactURL {
            RequestLogStore.log(.asr, "Meeting ASR request body saved -> \(requestArtifactURL.path)")
        }
        MeetingLog.info("VibeVoice curl=\(curlCommand)")

        let response: URLResponse
        do {
            let (bytes, streamResponse) = try await session.bytes(for: request)
            response = streamResponse

            let streamResult = try await consumeStreamingResponse(
                bytes: bytes,
                response: response,
                requestedMaxTokens: maxTokens
            )
            switch streamResult {
            case .success(let completion):
                return .success(completion)
            case .retry(let adjustment):
                return .retry(adjustment)
            }
        } catch {
            RequestLogStore.log(.asr, "Meeting ASR response <- error \(error.localizedDescription)")
            MeetingLog.error("VibeVoice request transport error: \(error.localizedDescription)")
            throw error
        }
    }

    private static func makeAudioDataURL(audioURL: URL) throws -> String {
        let mimeType = mimeType(for: audioURL.pathExtension)
        let fileData = try Data(contentsOf: audioURL)
        return "data:\(mimeType);base64,\(fileData.base64EncodedString())"
    }

    private func consumeStreamingResponse(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        requestedMaxTokens: Int
    ) async throws -> ChatCompletionAttempt {
        var rawBody = ""
        var streamEvents: [String] = []
        var currentEventDataLines: [String] = []

        for try await line in bytes.lines {
            rawBody.append(line)
            rawBody.append("\n")

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("data:") {
                let eventData = String(trimmedLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if !currentEventDataLines.isEmpty,
                   (eventData == "[DONE]" || eventData.hasPrefix("{")) {
                    streamEvents.append(currentEventDataLines.joined(separator: "\n"))
                    currentEventDataLines.removeAll(keepingCapacity: true)
                }
                currentEventDataLines.append(eventData)
                RequestLogStore.log(.asr, "Meeting ASR stream <- \(eventData.replacingOccurrences(of: "\n", with: "\\n"))")
                MeetingLog.info("VibeVoice stream event=\(eventData)")
            } else if trimmedLine.isEmpty, !currentEventDataLines.isEmpty {
                streamEvents.append(currentEventDataLines.joined(separator: "\n"))
                currentEventDataLines.removeAll(keepingCapacity: true)
            }
        }
        if !currentEventDataLines.isEmpty {
            streamEvents.append(currentEventDataLines.joined(separator: "\n"))
        }

        let rawData = Data(rawBody.utf8)

        let responseArtifactURL = Self.persistDebugArtifact(
            prefix: "response",
            pathExtension: "txt",
            data: rawData
        )

        if let httpResponse = response as? HTTPURLResponse {
            RequestLogStore.log(.asr, "Meeting ASR response <- status=\(httpResponse.statusCode)")
            if let responseArtifactURL {
                RequestLogStore.log(.asr, "Meeting ASR response body saved -> \(responseArtifactURL.path)")
            }
            MeetingLog.info("VibeVoice response status=\(httpResponse.statusCode)")

            if let adjustment = Self.contextLimitAdjustment(
                response: response,
                data: rawData,
                requestedMaxTokens: requestedMaxTokens
            ) {
                return .retry(adjustment)
            }

            try Self.ensureSuccess(response, data: rawData)
        }

        if !streamEvents.isEmpty {
            var assembledContent = ""
            var finishReason: String?

            for event in streamEvents {
                guard event != "[DONE]" else { continue }
                guard let eventData = event.data(using: .utf8) else { continue }
                let chunk = try decoder.decode(VibeVoiceChatCompletionStreamChunk.self, from: eventData)
                if let choice = chunk.choices.first {
                    if let contentDelta = choice.delta?.content ?? choice.message?.content {
                        assembledContent.append(contentDelta)
                    }
                    if let choiceFinishReason = choice.finishReason {
                        finishReason = choiceFinishReason
                    }
                }
            }

            assembledContent = Self.repairMojibakeIfNeeded(assembledContent)

            RequestLogStore.log(
                .asr,
                "Meeting ASR assembled content <- \(String(assembledContent.prefix(2000)).replacingOccurrences(of: "\n", with: "\\n"))"
            )
            return .success(.singleChoice(content: assembledContent, finishReason: finishReason))
        }

        let responsePreview = rawBody.prefix(1200).replacingOccurrences(of: "\n", with: "\\n")
        RequestLogStore.log(.asr, "Meeting ASR response <- body=\(responsePreview)")
        MeetingLog.info("VibeVoice non-sse bodyPreview=\(responsePreview)")
        return .success(try decoder.decode(VibeVoiceChatCompletionResponse.self, from: rawData))
    }

    private static func makePromptText(contextInfo: String) -> String {
        let basePrompt = "Please transcribe it with these keys: Start time, End time, Speaker ID, Content. Return JSON array only."
        let normalizedContext = contextInfo
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        guard !normalizedContext.isEmpty else {
            return basePrompt
        }

        return "This audio includes these terms: \(normalizedContext). \(basePrompt)"
    }

    private static func parseSSEEvents(from rawBody: String) -> [String] {
        let normalizedBody = rawBody.replacingOccurrences(of: "\r\n", with: "\n")
        let eventBlocks = normalizedBody.components(separatedBy: "\n\n")
        return eventBlocks.compactMap { block in
            let dataLines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { return nil }
                    return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                }
            guard !dataLines.isEmpty else { return nil }
            return dataLines.joined(separator: "\n")
        }
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    private static func ensureSuccess(_ response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VibeVoiceRunnerError.processFailed("VibeVoice request returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let message = body.isEmpty
                ? "VibeVoice request failed with status \(httpResponse.statusCode)"
                : "VibeVoice request failed with status \(httpResponse.statusCode): \(body)"
            throw VibeVoiceRunnerError.processFailed(message)
        }
    }

    private static func contextLimitAdjustment(
        response: URLResponse,
        data: Data,
        requestedMaxTokens: Int
    ) -> ContextLimitAdjustment? {
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 else {
            return nil
        }

        let body = String(decoding: data, as: UTF8.self)
        guard
            let maxContextLength = firstMatch(in: body, pattern: #"maximum context length is (\d+) tokens"#),
            let inputTokens = firstMatch(in: body, pattern: #"your request has (\d+) input tokens"#)
        else {
            return nil
        }

        let remainingTokens = maxContextLength - inputTokens
        let adjustedMaxTokens = min(requestedMaxTokens - 1, remainingTokens)
        guard adjustedMaxTokens > 0, adjustedMaxTokens < requestedMaxTokens else {
            return nil
        }

        return ContextLimitAdjustment(
            requestedMaxTokens: requestedMaxTokens,
            adjustedMaxTokens: adjustedMaxTokens
        )
    }

    static func resolvedMaxTokens(
        configuredMaxTokens: Int,
        promptText: String
    ) -> Int {
        let estimatedInputTokens = estimateTokenCount(for: systemPrompt) + estimateTokenCount(for: promptText)
        let safeUpperBound = max(1, maxModelContextTokens - estimatedInputTokens - tokenSafetyBuffer)
        return max(256, min(configuredMaxTokens, safeUpperBound))
    }

    private static func estimateTokenCount(for text: String) -> Int {
        max(1, Int(ceil(Double(text.lengthOfBytes(using: .utf8)) / 4.0)))
    }

    private static func firstMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private enum ChatCompletionAttempt {
        case success(VibeVoiceChatCompletionResponse)
        case retry(ContextLimitAdjustment)
    }

    private static func formattedElapsed(since startDate: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startDate))
    }

    private static func formattedFileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func persistDebugArtifact(
        prefix: String,
        pathExtension: String,
        data: Data
    ) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neutype-vibevoice-debug", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
                .appendingPathExtension(pathExtension)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            MeetingLog.error("VibeVoice debug artifact save failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func makeDebugCurlCommand(
        requestURL: URL,
        apiKey: String,
        requestBodyFileURL: URL?
    ) -> String {
        var components = [
            "curl '\(requestURL.absoluteString)'",
            "-H 'Content-Type: application/json'",
        ]
        if !apiKey.isEmpty {
            components.append("-H 'Authorization: Bearer \(maskedAPIKey(apiKey))'")
            components.append("-H 'X-Api-Key: \(maskedAPIKey(apiKey))'")
        }
        if let requestBodyFileURL {
            components.append("--data @'\(requestBodyFileURL.path)'")
        } else {
            components.append("--data '<request-body-unavailable>'")
        }
        return components.joined(separator: " \\\n  ")
    }

    private static func maskedAPIKey(_ apiKey: String) -> String {
        guard apiKey.count > 10 else { return "***" }
        return "\(apiKey.prefix(6))***\(apiKey.suffix(4))"
    }

    private static func isTimeoutError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return urlError.code == .timedOut
    }

    private static func friendlyTimeoutMessage(
        chunk: AudioChunk,
        requestOrdinal: Int,
        totalRequests: Int
    ) -> String {
        "VibeVoice request timed out while transcribing audio chunk \(requestOrdinal) / \(max(totalRequests, 1)) (\(formattedTimestamp(chunk.timeOffset)) - \(formattedTimestamp(chunk.timeOffset + chunk.duration))). Please retry."
    }

    private static func chunkLogMessage(
        _ prefix: String,
        chunk: AudioChunk,
        recursionDepth: Int,
        requestOrdinal: Int,
        totalRequests: Int
    ) -> String {
        "\(prefix) \(requestOrdinal) / \(max(totalRequests, 1)) · \(formattedTimestamp(chunk.timeOffset)) - \(formattedTimestamp(chunk.timeOffset + chunk.duration)) · depth=\(recursionDepth)"
    }

    private static func formattedTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func decodeResult(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder(),
        timeOffset: TimeInterval = 0,
        sequenceOffset: Int = 0
    ) throws -> MeetingTranscriptionResult {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw VibeVoiceRunnerError.invalidRawTextPayload
        }

        let jsonString: String
        do {
            jsonString = try extractAssistantJSON(from: payload)
        } catch {
            if let serviceMessage = extractServiceError(from: payload) {
                throw VibeVoiceRunnerError.processFailed(serviceMessage)
            }
            throw error
        }
        let normalizedJSONString = repairMojibakeIfNeeded(jsonString)
        let jsonData = Data(normalizedJSONString.utf8)
        let segments: [VibeVoiceSegment]
        do {
            segments = try decoder.decode([VibeVoiceSegment].self, from: jsonData)
        } catch {
            if let serviceMessage = extractServiceError(from: payload) {
                throw VibeVoiceRunnerError.processFailed(serviceMessage)
            }
            throw error
        }
        let normalizedSegments = segments.enumerated().map { index, segment in
            MeetingTranscriptionSegmentPayload(
                sequence: sequenceOffset + index,
                speakerLabel: segment.speakerLabel,
                startTime: segment.start + timeOffset,
                endTime: segment.end + timeOffset,
                text: segment.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let fullText = normalizedSegments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return MeetingTranscriptionResult(fullText: fullText, segments: normalizedSegments)
    }

    static func mergeSegmentsDroppingOverlapDuplicates(
        _ segments: [MeetingTranscriptionSegmentPayload]
    ) -> [MeetingTranscriptionSegmentPayload] {
        let sortedSegments = segments.sorted {
            if $0.startTime == $1.startTime {
                return $0.sequence < $1.sequence
            }
            return $0.startTime < $1.startTime
        }

        var merged: [MeetingTranscriptionSegmentPayload] = []
        for segment in sortedSegments {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if let previous = merged.last,
               shouldMergeAsOverlapDuplicate(previous: previous, current: segment) {
                merged[merged.count - 1] = mergeOverlapDuplicate(previous: previous, current: segment)
            } else {
                merged.append(segment)
            }
        }

        return merged.enumerated().map { index, segment in
            MeetingTranscriptionSegmentPayload(
                sequence: index,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
    }

    private static func shouldMergeAsOverlapDuplicate(
        previous: MeetingTranscriptionSegmentPayload,
        current: MeetingTranscriptionSegmentPayload
    ) -> Bool {
        let overlapTolerance: TimeInterval = 0.5
        let overlaps = current.startTime <= previous.endTime + overlapTolerance
        guard overlaps else { return false }

        let previousText = normalizedDuplicateText(previous.text)
        let currentText = normalizedDuplicateText(current.text)
        guard !previousText.isEmpty, !currentText.isEmpty else { return false }

        return previousText == currentText
            || previousText.contains(currentText)
            || currentText.contains(previousText)
    }

    private static func mergeOverlapDuplicate(
        previous: MeetingTranscriptionSegmentPayload,
        current: MeetingTranscriptionSegmentPayload
    ) -> MeetingTranscriptionSegmentPayload {
        let text = current.text.count > previous.text.count ? current.text : previous.text
        let speakerLabel: String
        if previous.speakerLabel.localizedCaseInsensitiveContains("unknown"),
           !current.speakerLabel.localizedCaseInsensitiveContains("unknown") {
            speakerLabel = current.speakerLabel
        } else {
            speakerLabel = previous.speakerLabel
        }

        return MeetingTranscriptionSegmentPayload(
            sequence: previous.sequence,
            speakerLabel: speakerLabel,
            startTime: min(previous.startTime, current.startTime),
            endTime: max(previous.endTime, current.endTime),
            text: text
        )
    }

    private static func normalizedDuplicateText(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .filter { !$0.isPunctuation }
    }

    private static func sanitizedSegments(
        _ segments: [MeetingTranscriptionSegmentPayload],
        chunkStartTime: TimeInterval,
        chunkDuration: TimeInterval
    ) -> [MeetingTranscriptionSegmentPayload] {
        segments.filter { segment in
            let normalizedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty, !isPlaceholderSegmentText(normalizedText) else {
                return false
            }

            let localStart = segment.startTime - chunkStartTime
            let localEnd = segment.endTime - chunkStartTime
            guard localEnd > localStart else { return false }
            guard localStart >= -timestampGraceDuration else { return false }
            if chunkDuration > 0 {
                guard localEnd <= chunkDuration + timestampGraceDuration else { return false }
            }
            return true
        }
    }

    private static func isLikelyNonSpeechOnlyPayload(_ content: String) -> Bool {
        let extractedValues = extractContentValues(from: content)
        guard !extractedValues.isEmpty else { return false }
        let placeholderCount = extractedValues.filter(isPlaceholderSegmentText).count
        return placeholderCount == extractedValues.count
    }

    private static func extractContentValues(from content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""(?:Content|content|text)"\s*:\s*"([^"]+)""#) else {
            return []
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func isPlaceholderSegmentText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            return true
        }

        let placeholderPhrases = [
            "noise",
            "environmental sounds",
            "background noise",
            "silence",
            "music",
            "applause",
            "laughter",
            "breathing",
            "static",
            "non-speech",
        ]
        return placeholderPhrases.contains(normalized)
    }

    private static func repairMojibakeIfNeeded(_ text: String) -> String {
        guard looksLikeMojibake(text) else { return text }
        guard let repaired = repairUTF8MisdecodedAsLatin1(text), repaired != text else {
            return text
        }
        return repaired
    }

    private static func looksLikeMojibake(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.contains(where: { $0.isASCII == false && $0.unicodeScalars.contains(where: { $0.properties.isIdeographic }) }) {
            return false
        }

        let markers = [
            "ï¼", "ï½", "Ã", "â€", "â€”", "â€“", "â€¦", "å", "æ", "ç", "é", "è", "ê", "î", "ð"
        ]
        return markers.contains { text.contains($0) }
    }

    private static func repairUTF8MisdecodedAsLatin1(_ text: String) -> String? {
        guard let latin1Data = text.data(using: .isoLatin1) else {
            return nil
        }
        return String(data: latin1Data, encoding: .utf8)
    }

    private static func extractAssistantJSON(from payload: String) throws -> String {
        let assistantRange = payload.range(of: "assistant")
        let searchStart = assistantRange?.upperBound ?? payload.startIndex
        let searchSlice = payload[searchStart...]

        if let arrayIndex = searchSlice.firstIndex(of: "[") {
            return try extractBalancedJSON(in: searchSlice, startingAt: arrayIndex, open: "[", close: "]")
        }
        if let objectIndex = searchSlice.firstIndex(of: "{") {
            return try extractBalancedJSON(in: searchSlice, startingAt: objectIndex, open: "{", close: "}")
        }

        throw VibeVoiceRunnerError.invalidRawTextPayload
    }

    private static func extractBalancedJSON(
        in payload: Substring,
        startingAt startIndex: Substring.Index,
        open: Character,
        close: Character
    ) throws -> String {
        var depth = 0
        var isEscaping = false
        var isInsideString = false
        var currentIndex = startIndex

        while currentIndex < payload.endIndex {
            let character = payload[currentIndex]

            if isEscaping {
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "\"" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 {
                        let endIndex = payload.index(after: currentIndex)
                        return String(payload[startIndex..<endIndex])
                    }
                }
            }

            currentIndex = payload.index(after: currentIndex)
        }

        throw VibeVoiceRunnerError.invalidRawTextPayload
    }

    private static func extractServiceError(from payload: String) -> String? {
        let normalizedPayload = payload.replacingOccurrences(of: "\\u274c", with: "❌")

        if normalizedPayload.contains("No audio segments available.") {
            return "No audio segments available. This could happen if the model output doesn't contain valid time stamps."
        }

        if let range = normalizedPayload.range(of: "<p>❌ "),
           let closingRange = normalizedPayload[range.upperBound...].range(of: "</p>") {
            return String(normalizedPayload[range.upperBound..<closingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

private struct VibeVoiceChatCompletionRequest: Encodable {
    let model: String
    let messages: [VibeVoiceChatMessage]
    let maxTokens: Int
    let temperature: Double
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }
}

private struct VibeVoiceChatMessage: Encodable {
    let role: String
    let content: Content

    enum Content: Encodable {
        case text(String)
        case parts([VibeVoiceChatContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .parts(let value):
                try container.encode(value)
            }
        }
    }
}

private struct VibeVoiceChatContentPart: Encodable {
    let type: String
    let text: String?
    let audioURL: AudioURLPayload?

    struct AudioURLPayload: Encodable {
        let url: String

        enum CodingKeys: String, CodingKey {
            case url
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case audioURL = "audio_url"
    }

    static func text(_ value: String) -> VibeVoiceChatContentPart {
        VibeVoiceChatContentPart(type: "text", text: value, audioURL: nil)
    }

    static func audioURL(url: String) -> VibeVoiceChatContentPart {
        VibeVoiceChatContentPart(type: "audio_url", text: nil, audioURL: .init(url: url))
    }
}

private struct VibeVoiceChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
    }

    static func singleChoice(content: String, finishReason: String?) -> VibeVoiceChatCompletionResponse {
        VibeVoiceChatCompletionResponse(
            choices: [
                Choice(
                    message: Message(content: content),
                    finishReason: finishReason
                ),
            ]
        )
    }
}

private struct VibeVoiceChatCompletionStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta?
        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct VibeVoiceSegment: Decodable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int?
    let content: String

    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
        case speaker = "Speaker"
        case content = "Content"
        case startTime = "start_time"
        case endTime = "end_time"
        case speakerID = "speaker_id"
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decodeIfPresent(TimeInterval.self, forKey: .start)
            ?? container.decode(TimeInterval.self, forKey: .startTime)
        end = try container.decodeIfPresent(TimeInterval.self, forKey: .end)
            ?? container.decode(TimeInterval.self, forKey: .endTime)
        speaker = try container.decodeIfPresent(Int.self, forKey: .speaker)
            ?? container.decodeIfPresent(Int.self, forKey: .speakerID)
        content = try container.decodeIfPresent(String.self, forKey: .content)
            ?? container.decode(String.self, forKey: .text)
    }

    var speakerLabel: String {
        guard let speaker else { return "Unknown" }
        return "Speaker \(speaker + 1)"
    }
}
