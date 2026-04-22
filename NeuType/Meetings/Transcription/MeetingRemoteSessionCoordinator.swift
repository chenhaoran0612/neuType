import AVFoundation
import CryptoKit
import Foundation

protocol MeetingRemoteTranscriptionServing: Sendable {
    func createSession(
        _ requestPayload: CreateMeetingTranscriptionSessionRequest
    ) async throws -> CreateMeetingTranscriptionSessionResponse
    func uploadChunk(
        _ requestPayload: MeetingRemoteTranscriptionChunkUploadRequest
    ) async throws -> MeetingRemoteTranscriptionChunkUploadResponse
    func uploadFullAudio(
        _ requestPayload: MeetingRemoteTranscriptionFullAudioUploadRequest
    ) async throws -> MeetingRemoteTranscriptionFullAudioUploadResponse
    func finalizeSession(
        sessionID: String,
        request requestPayload: FinalizeMeetingTranscriptionSessionRequest
    ) async throws -> FinalizeMeetingTranscriptionSessionResponse
    func getSessionStatus(sessionID: String) async throws -> MeetingRemoteTranscriptionSessionStatusResponse
}

extension MeetingRemoteTranscriptionClient: MeetingRemoteTranscriptionServing {}

protocol MeetingRemoteSessionCoordinating: Sendable {
    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async
    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws
    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult
}

enum MeetingRemoteSessionCoordinatorError: LocalizedError, Equatable {
    case sessionFailed(String)
    case missingTranscript(String)
    case sessionNotInitialized

    var errorDescription: String? {
        switch self {
        case .sessionFailed(let message):
            message
        case .missingTranscript(let sessionID):
            "Meeting transcription session \(sessionID) completed without transcript data."
        case .sessionNotInitialized:
            "Meeting transcription session has not been created yet."
        }
    }
}

final class MeetingRemoteSessionCoordinator: MeetingRemoteSessionCoordinating, Sendable {
    private enum Defaults {
        static let chunkDurationMS = 300_000
        static let chunkOverlapMS = 2_500
        static let audioFormat = "wav"
        static let sampleRateHZ = 16_000
        static let channelCount = 1
        static let source = "macos_meeting"
    }

    private let client: MeetingRemoteTranscriptionServing
    private let ledger: MeetingUploadLedger
    private let pollInterval: @Sendable (Int) -> UInt64
    private let sessionCreationGate = SessionCreationGate()
    private let statusLogTracker = RemoteStatusLogTracker()

    init(
        client: MeetingRemoteTranscriptionServing = MeetingRemoteTranscriptionClient(),
        ledger: MeetingUploadLedger,
        pollInterval: @escaping @Sendable (Int) -> UInt64 = { attempt in
            attempt < 5 ? 2_000_000_000 : 5_000_000_000
        }
    ) {
        self.client = client
        self.ledger = ledger
        self.pollInterval = pollInterval
    }

    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async {
        do {
            let audioData = try Data(contentsOf: artifact.fileURL)
            let record = MeetingUploadChunkRecord(
                index: artifact.chunkIndex,
                startMS: artifact.startMS,
                endMS: artifact.endMS,
                sha256: Self.sha256Hex(for: audioData),
                localFilePath: artifact.fileURL.path
            )
            try ledger.recordChunk(record)
            let sessionID = try await ensureSessionID()
            let request = MeetingRemoteTranscriptionChunkUploadRequest(
                sessionID: sessionID,
                chunkIndex: artifact.chunkIndex,
                audioData: audioData,
                fileName: artifact.fileURL.lastPathComponent,
                startMS: artifact.startMS,
                endMS: artifact.endMS,
                sha256: record.sha256,
                mimeType: Self.mimeType(for: artifact.fileURL.pathExtension),
                fileSizeBytes: audioData.count
            )
            let response = try await client.uploadChunk(request)
            try updateLedger(index: artifact.chunkIndex, for: response)
            RequestLogStore.log(
                .asr,
                "服务端 chunk #\(artifact.chunkIndex) 上传完成 -> upload=\(response.uploadStatus), process=\(response.processStatus)"
            )
        } catch let error as MeetingRemoteTranscriptionClientError {
            let isConflict: Bool
            switch error {
            case .apiError(_, _, let code, _):
                isConflict = code.localizedCaseInsensitiveContains("conflict")
            default:
                isConflict = false
            }
            try? ledger.markChunkUploadFailed(index: artifact.chunkIndex, conflict: isConflict)
            MeetingLog.error("Meeting chunk upload failed chunkIndex=\(artifact.chunkIndex) error=\(error.localizedDescription)")
        } catch {
            try? ledger.markChunkUploadFailed(index: artifact.chunkIndex)
            MeetingLog.error("Meeting chunk upload failed chunkIndex=\(artifact.chunkIndex) error=\(error.localizedDescription)")
        }
    }

    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws {
        if try await shouldResumePollingOnlyForExistingSession() {
            return
        }

        try ledger.updateFullAudioLocalPath(fullAudioURL.path)
        let sessionID = try await ensureSessionID()

        let strategy: MeetingUploadLedger.Strategy
        if ledger.requiresFullAudioFallback(expectedChunkCount: expectedChunkCount) {
            strategy = .fullAudioFallback
            try await uploadFullAudio(fullAudioURL: fullAudioURL, sessionID: sessionID)
        } else {
            strategy = .liveChunks
        }

        try ledger.setSelectedStrategy(strategy)

        let response = try await client.finalizeSession(
            sessionID: sessionID,
            request: .init(
                expectedChunkCount: expectedChunkCount,
                preferredInputMode: strategy.rawValue,
                allowFullAudioFallback: true,
                recordingEndedAtMS: nil
            )
        )
        RequestLogStore.log(
            .asr,
            "服务端 finalize -> session=\(sessionID), strategy=\(response.selectedInputMode), missing=\(response.missingChunkIndexes)"
        )

        if strategy == .liveChunks, !response.missingChunkIndexes.isEmpty {
            try ledger.setSelectedStrategy(.fullAudioFallback)
            try await uploadFullAudio(fullAudioURL: fullAudioURL, sessionID: sessionID)
            let fallbackResponse = try await client.finalizeSession(
                sessionID: sessionID,
                request: .init(
                    expectedChunkCount: expectedChunkCount,
                    preferredInputMode: MeetingUploadLedger.Strategy.fullAudioFallback.rawValue,
                    allowFullAudioFallback: true,
                    recordingEndedAtMS: nil
                )
            )
            RequestLogStore.log(
                .asr,
                "服务端 fallback finalize -> session=\(sessionID), strategy=\(fallbackResponse.selectedInputMode), missing=\(fallbackResponse.missingChunkIndexes)"
            )
        }
        try ledger.markFinalizeRequested()
    }

    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult {
        let sessionID = try existingSessionID()
        var attempt = 0

        while true {
            let status = try await client.getSessionStatus(sessionID: sessionID)
            for message in await statusLogTracker.messages(for: status) {
                RequestLogStore.log(.asr, message)
            }
            switch status.status.lowercased() {
            case "completed":
                guard let result = status.transcriptResult else {
                    throw MeetingRemoteSessionCoordinatorError.missingTranscript(sessionID)
                }
                return result
            case "failed":
                let message = status.errorMessage?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let failureMessage: String
                if let message, !message.isEmpty {
                    failureMessage = message
                } else {
                    failureMessage = "Meeting transcription session \(sessionID) failed on remote server."
                }
                throw MeetingRemoteSessionCoordinatorError.sessionFailed(
                    failureMessage
                )
            default:
                attempt += 1
                let sleepNS = pollInterval(attempt)
                if sleepNS > 0 {
                    try await Task.sleep(nanoseconds: sleepNS)
                }
            }
        }
    }

    private func ensureSessionID() async throws -> String {
        let request = CreateMeetingTranscriptionSessionRequest(
            clientSessionToken: ledger.snapshot.clientSessionToken,
            source: Defaults.source,
            chunkDurationMS: Defaults.chunkDurationMS,
            chunkOverlapMS: Defaults.chunkOverlapMS,
            audioFormat: Defaults.audioFormat,
            sampleRateHZ: Defaults.sampleRateHZ,
            channelCount: Defaults.channelCount
        )
        return try await sessionCreationGate.sessionID(
            ledger: ledger,
            client: client,
            request: request
        )
    }

    private func existingSessionID() throws -> String {
        guard let remoteSessionID = ledger.snapshot.remoteSessionID, !remoteSessionID.isEmpty else {
            throw MeetingRemoteSessionCoordinatorError.sessionNotInitialized
        }
        return remoteSessionID
    }

    private func uploadFullAudio(fullAudioURL: URL, sessionID: String) async throws {
        let audioData = try Data(contentsOf: fullAudioURL)
        let response = try await client.uploadFullAudio(
            .init(
                sessionID: sessionID,
                audioData: audioData,
                fileName: fullAudioURL.lastPathComponent,
                sha256: Self.sha256Hex(for: audioData),
                durationMS: Self.durationMS(of: fullAudioURL),
                mimeType: Self.mimeType(for: fullAudioURL.pathExtension),
                fileSizeBytes: audioData.count
            )
        )
        RequestLogStore.log(
            .asr,
            "服务端 full audio 上传完成 -> session=\(sessionID), status=\(response.status), input=\(response.inputMode), bytes=\(audioData.count)"
        )
    }

    private func updateLedger(
        index: Int,
        for response: MeetingRemoteTranscriptionChunkUploadResponse
    ) throws {
        switch response.uploadStatus.lowercased() {
        case "uploaded":
            try ledger.markChunkUploaded(index: index)
        case "failed_conflict", "conflict":
            try ledger.markChunkUploadFailed(index: index, conflict: true)
        default:
            try ledger.markChunkUploadFailed(index: index)
        }
    }

    private func shouldResumePollingOnlyForExistingSession() async throws -> Bool {
        let snapshot = ledger.snapshot
        guard snapshot.finalizeRequested,
              let remoteSessionID = snapshot.remoteSessionID,
              !remoteSessionID.isEmpty else {
            return false
        }

        do {
            let status = try await client.getSessionStatus(sessionID: remoteSessionID)
            switch status.status.lowercased() {
            case "processing", "completed":
                return true
            case "failed":
                try ledger.resetForRetry(
                    clientSessionToken: Self.retryClientSessionToken(from: snapshot)
                )
                return false
            default:
                return false
            }
        } catch let error as MeetingRemoteTranscriptionClientError {
            guard Self.shouldResetForMissingSession(error) else {
                throw error
            }
            try ledger.resetForRetry(
                clientSessionToken: Self.retryClientSessionToken(from: snapshot)
            )
            return false
        }
    }

    private static func shouldResetForMissingSession(_ error: MeetingRemoteTranscriptionClientError) -> Bool {
        switch error {
        case .apiError(let statusCode, _, let code, _):
            return statusCode == 404 || code.localizedCaseInsensitiveContains("session_not_found")
        case .requestFailed(let statusCode, _):
            return statusCode == 404
        default:
            return false
        }
    }

    private static func retryClientSessionToken(from snapshot: MeetingUploadLedger.Snapshot) -> String {
        let baseToken = snapshot.meetingRecordID ?? snapshot.clientSessionToken
        return "\(baseToken)-retry-\(UUID().uuidString)"
    }

    private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func durationMS(of audioURL: URL) -> Int {
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            return 0
        }
        let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        return max(Int((seconds * 1_000).rounded()), 0)
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        default:
            return "application/octet-stream"
        }
    }
}

private actor RemoteStatusLogTracker {
    private var lastSessionSummary: String?
    private var lastChunkSummaries: [String: String] = [:]

    func messages(for status: MeetingRemoteTranscriptionSessionStatusResponse) -> [String] {
        var messages: [String] = []

        let uploaded = status.uploadedChunkCount ?? 0
        let expected = status.expectedChunkCount.map(String.init) ?? "?"
        let sessionSummary = "服务端会话 \(status.sessionID) -> \(status.status.lowercased()), input=\(status.inputMode), uploaded=\(uploaded)/\(expected)"
        if sessionSummary != lastSessionSummary {
            messages.append(sessionSummary)
            lastSessionSummary = sessionSummary
        }

        var liveKeys = Set<String>()
        for chunk in status.chunks {
            let key = "\(chunk.sourceType)#\(chunk.chunkIndex)"
            liveKeys.insert(key)

            var chunkSummary = "服务端 chunk #\(chunk.chunkIndex) [\(chunk.sourceType)] -> \(chunk.processStatus), upload=\(chunk.uploadStatus), range=\(chunk.startMS)-\(chunk.endMS)ms, retry=\(chunk.retryCount)"
            if let resultSegmentCount = chunk.resultSegmentCount {
                chunkSummary += ", segments=\(resultSegmentCount)"
            }
            if let errorMessage = chunk.errorMessage, !errorMessage.isEmpty {
                chunkSummary += ", error=\(errorMessage)"
            }

            if lastChunkSummaries[key] != chunkSummary {
                messages.append(chunkSummary)
                lastChunkSummaries[key] = chunkSummary
            }
        }

        for key in lastChunkSummaries.keys where !liveKeys.contains(key) {
            lastChunkSummaries.removeValue(forKey: key)
        }

        return messages
    }
}

private actor SessionCreationGate {
    private var creationTask: Task<String, Error>?

    func sessionID(
        ledger: MeetingUploadLedger,
        client: MeetingRemoteTranscriptionServing,
        request: CreateMeetingTranscriptionSessionRequest
    ) async throws -> String {
        if let remoteSessionID = ledger.snapshot.remoteSessionID, !remoteSessionID.isEmpty {
            return remoteSessionID
        }

        if let creationTask {
            return try await creationTask.value
        }

        let task = Task<String, Error> {
            let created = try await client.createSession(request)
            try ledger.updateRemoteSessionID(created.sessionID)
            return created.sessionID
        }
        creationTask = task

        do {
            let sessionID = try await task.value
            creationTask = nil
            return sessionID
        } catch {
            creationTask = nil
            throw error
        }
    }
}
