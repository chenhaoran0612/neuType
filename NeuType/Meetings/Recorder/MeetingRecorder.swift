@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol MeetingRecording: AnyObject, Sendable {
    func startRecording() async throws
    func stopRecording() async throws -> URL?
    func cancelRecording()
}

enum MeetingRecorderError: LocalizedError {
    case alreadyRecording
    case noDisplayAvailable
    case noMicrophoneAvailable
    case invalidAudioSample
    case sourceSetupFailed(String)
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Meeting recording is already in progress."
        case .noDisplayAvailable:
            return "No display is available for system audio capture."
        case .noMicrophoneAvailable:
            return "No microphone is available for meeting capture."
        case .invalidAudioSample:
            return "Unable to process captured audio."
        case .sourceSetupFailed(let message):
            return message
        case .noAudioCaptured:
            return "Meeting recording finished without any captured audio."
        }
    }
}

final class MeetingRecorder: NSObject, MeetingRecording, MeetingRecordingArtifactProducing, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "ai.neuxnet.neutype.meeting.capture")
    private let stateQueue = DispatchQueue(label: "ai.neuxnet.neutype.meeting.state")
    private let chunkSealer: MeetingChunkSealer
    private let chunkSealCheckInterval: TimeInterval

    private var activeSession: ActiveSession?
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private var sealingTask: Task<Void, Never>?
    var artifactHandler: MeetingRecordingArtifactHandler?

    init(
        chunkSealer: MeetingChunkSealer = MeetingChunkSealer(),
        chunkSealCheckInterval: TimeInterval = 30
    ) {
        self.chunkSealer = chunkSealer
        self.chunkSealCheckInterval = chunkSealCheckInterval
        super.init()
    }

    func startRecording() async throws {
        let isRecording = withActiveSession { $0 != nil }
        guard !isRecording else { throw MeetingRecorderError.alreadyRecording }

        let session = try ActiveSession()
        updateActiveSession(session)

        do {
            try await configureSystemAudioCapture()
            try await configureMicrophoneCapture()
            startSealingLoop()
        } catch {
            await stopSealingLoop()
            await stopSources()
            cleanup(session: session, removeFinalOutput: true)
            updateActiveSession(nil)
            throw error
        }
    }

    func stopRecording() async throws -> URL? {
        guard let session = withActiveSession({ $0 }) else {
            return nil
        }

        await stopSealingLoop()
        await stopSources()
        captureQueue.sync {}
        updateActiveSession(nil)

        defer {
            cleanup(session: session, removeFinalOutput: false)
        }

        let resultURL = try mixCapturedAudio(for: session)
        try await emitArtifactsIfNeeded(for: resultURL, session: session)
        return resultURL
    }

    func cancelRecording() {
        guard let session = withActiveSession({ $0 }) else { return }

        Task {
            await self.stopSealingLoop()
            await stopSources()
            captureQueue.sync {}
            self.updateActiveSession(nil)
            cleanup(session: session, removeFinalOutput: true)
        }
    }

    private func configureSystemAudioCapture() async throws {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = preferredDisplay(from: shareableContent) else {
            throw MeetingRecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 3
        configuration.width = 2
        configuration.height = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func configureMicrophoneCapture() async throws {
        guard let microphoneDevice = MicrophoneService.shared.getAVCaptureDevice() else {
            throw MeetingRecorderError.noMicrophoneAvailable
        }

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: microphoneDevice)
            guard captureSession.canAddInput(input) else {
                throw MeetingRecorderError.sourceSetupFailed("Unable to add microphone input.")
            }
            captureSession.addInput(input)
        } catch {
            captureSession.commitConfiguration()
            throw MeetingRecorderError.sourceSetupFailed("Unable to configure microphone input: \(error.localizedDescription)")
        }

        let output = AVCaptureAudioDataOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            throw MeetingRecorderError.sourceSetupFailed("Unable to add microphone output.")
        }
        captureSession.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        captureSession.commitConfiguration()

        try await startCaptureSession(captureSession)
        self.microphoneSession = captureSession
    }

    private func stopSources() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        if let microphoneSession {
            await stopCaptureSession(microphoneSession)
            self.microphoneSession = nil
        }
    }

    private func startCaptureSession(_ session: AVCaptureSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    private func stopCaptureSession(_ session: AVCaptureSession) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    private func preferredDisplay(from shareableContent: SCShareableContent) -> SCDisplay? {
        let mainDisplayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value

        if let mainDisplayID,
           let display = shareableContent.displays.first(where: { $0.displayID == mainDisplayID }) {
            return display
        }

        return shareableContent.displays.first
    }

    private func mixCapturedAudio(
        for session: ActiveSession,
        outputURL: URL? = nil
    ) throws -> URL {
        let sourceURLs = session.availableSourceURLs()
        guard !sourceURLs.isEmpty else { throw MeetingRecorderError.noAudioCaptured }

        let outputFormat = Self.makeFinalOutputFormat()
        let outputURL = outputURL ?? session.finalOutputURL
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        var maximumDuration: TimeInterval = 0

        for sourceURL in sourceURLs {
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let duration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
            maximumDuration = max(maximumDuration, duration)

            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: sourceFile.processingFormat)
            player.scheduleFile(sourceFile, at: nil)
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: 4_096
        )

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        try engine.start()
        engine.attachedNodes
            .compactMap { $0 as? AVAudioPlayerNode }
            .forEach { $0.play() }

        let totalFrames = AVAudioFramePosition(ceil(maximumDuration * outputFormat.sampleRate))
        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        )!

        while engine.manualRenderingSampleTime < totalFrames {
            let remainingFrames = totalFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(
                min(Int64(engine.manualRenderingMaximumFrameCount), remainingFrames)
            )

            switch try engine.renderOffline(framesToRender, to: renderBuffer) {
            case .success:
                try outputFile.write(from: renderBuffer)
            case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                continue
            case .error:
                throw MeetingRecorderError.sourceSetupFailed("Offline audio mix failed.")
            @unknown default:
                throw MeetingRecorderError.sourceSetupFailed("Offline audio mix returned an unknown status.")
            }
        }

        engine.stop()
        return outputURL
    }

    static func makeFinalOutputFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    private func cleanup(session: ActiveSession, removeFinalOutput: Bool) {
        session.cleanup(removeFinalOutput: removeFinalOutput)
    }

    private func startSealingLoop() {
        sealingTask?.cancel()
        sealingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let intervalNS = UInt64(max(chunkSealCheckInterval, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: intervalNS)
                guard !Task.isCancelled else { break }
                await self.emitRollingChunksIfNeeded()
            }
        }
    }

    private func stopSealingLoop() async {
        sealingTask?.cancel()
        await sealingTask?.value
        sealingTask = nil
    }

    private func emitRollingChunksIfNeeded() async {
        guard let session = withActiveSession({ $0 }) else { return }
        captureQueue.sync {}

        do {
            let snapshotURL = session.nextSnapshotOutputURL()
            let sourceURL = try mixCapturedAudio(for: session, outputURL: snapshotURL)
            try await emitSealedChunksIfNeeded(sourceURL: sourceURL, session: session, includeTrailingPartialChunk: false)
        } catch {
            MeetingLog.error("Meeting rolling chunk sealing failed: \(error.localizedDescription)")
        }
    }

    private func emitArtifactsIfNeeded(for audioURL: URL, session: ActiveSession) async throws {
        guard let artifactHandler else { return }

        try await emitSealedChunksIfNeeded(sourceURL: audioURL, session: session, includeTrailingPartialChunk: true)

        let finalAudio = MeetingRecordingFinalAudioArtifact(
            fileURL: audioURL,
            durationMS: max(Int((Self.duration(of: audioURL) * 1_000).rounded()), 0)
        )
        await artifactHandler(.finalAudio(finalAudio))
    }

    private func emitSealedChunksIfNeeded(
        sourceURL: URL,
        session: ActiveSession,
        includeTrailingPartialChunk: Bool
    ) async throws {
        guard let artifactHandler else { return }

        let duration = Self.duration(of: sourceURL)
        let sealedChunks: [MeetingRecordingChunkArtifact]
        if includeTrailingPartialChunk {
            sealedChunks = try chunkSealer.sealChunksForFinalization(
                totalDuration: duration,
                sourceURL: sourceURL,
                outputDirectory: session.chunkArtifactsDirectory
            )
        } else {
            sealedChunks = try chunkSealer.sealChunksIfNeeded(
                totalDuration: duration,
                sourceURL: sourceURL,
                outputDirectory: session.chunkArtifactsDirectory,
                includeTrailingPartialChunk: false
            )
        }
        let newChunks = session.claimUnemittedChunks(sealedChunks)
        for artifact in newChunks {
            await artifactHandler(.sealedChunk(artifact))
        }
    }

    private func withActiveSession<T>(_ block: (ActiveSession?) -> T) -> T {
        stateQueue.sync {
            block(activeSession)
        }
    }

    private func updateActiveSession(_ session: ActiveSession?) {
        stateQueue.sync {
            activeSession = session
        }
    }

    static func duration(of audioURL: URL) -> TimeInterval {
        guard let audioFile = try? AVAudioFile(forReading: audioURL),
              audioFile.processingFormat.sampleRate > 0 else {
            return 0
        }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }
}

extension MeetingRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let session = withActiveSession({ $0 }) else { return }

        do {
            let buffer = try Self.makePCMBuffer(from: sampleBuffer)
            try session.systemAudioWriter.append(buffer)
        } catch {
            RequestLogStore.log(.usage, "Meeting system audio write failed: \(error.localizedDescription)")
        }
    }
}

extension MeetingRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let session = withActiveSession({ $0 }) else { return }

        do {
            let buffer = try Self.makePCMBuffer(from: sampleBuffer)
            try session.microphoneAudioWriter.append(buffer)
        } catch {
            RequestLogStore.log(.usage, "Meeting microphone audio write failed: \(error.localizedDescription)")
        }
    }
}

private extension MeetingRecorder {
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbdPointer)
        else {
            throw MeetingRecorderError.invalidAudioSample
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw MeetingRecorderError.invalidAudioSample
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw MeetingRecorderError.invalidAudioSample
        }

        return pcmBuffer
    }
}

private final class ActiveSession {
    private let lock = NSLock()
    private let tempDirectory: URL
    let chunkArtifactsDirectory: URL
    let systemAudioWriter: MeetingSourceAudioWriter
    let microphoneAudioWriter: MeetingSourceAudioWriter
    let finalOutputURL: URL
    private var emittedChunkIndexes = Set<Int>()
    private var snapshotCounter = 0

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        chunkArtifactsDirectory = tempDirectory.appendingPathComponent("sealed-chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkArtifactsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MeetingRecord.meetingsDirectory, withIntermediateDirectories: true)

        systemAudioWriter = MeetingSourceAudioWriter(
            url: tempDirectory.appendingPathComponent("system.caf")
        )
        microphoneAudioWriter = MeetingSourceAudioWriter(
            url: tempDirectory.appendingPathComponent("microphone.caf")
        )
        finalOutputURL = MeetingRecord.meetingsDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    func availableSourceURLs() -> [URL] {
        [systemAudioWriter, microphoneAudioWriter]
            .compactMap { writer in
                writer.hasAudioData ? writer.url : nil
            }
    }

    func nextSnapshotOutputURL() -> URL {
        lock.lock()
        defer { lock.unlock() }

        let outputURL = tempDirectory
            .appendingPathComponent("snapshot-\(snapshotCounter)")
            .appendingPathExtension("wav")
        snapshotCounter += 1
        return outputURL
    }

    func claimUnemittedChunks(_ artifacts: [MeetingRecordingChunkArtifact]) -> [MeetingRecordingChunkArtifact] {
        lock.lock()
        defer { lock.unlock() }

        let newArtifacts = artifacts.filter { emittedChunkIndexes.insert($0.chunkIndex).inserted }
        return newArtifacts.sorted { $0.chunkIndex < $1.chunkIndex }
    }

    func cleanup(removeFinalOutput: Bool) {
        try? systemAudioWriter.removeIfExists()
        try? microphoneAudioWriter.removeIfExists()
        try? FileManager.default.removeItem(at: tempDirectory)

        if removeFinalOutput {
            try? FileManager.default.removeItem(at: finalOutputURL)
        }
    }
}

private final class MeetingSourceAudioWriter {
    let url: URL

    private var audioFile: AVAudioFile?
    private(set) var hasAudioData = false

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if audioFile == nil {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
        }

        try audioFile?.write(from: buffer)
        hasAudioData = true
    }

    func removeIfExists() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
