import AVFoundation
import CoreMedia
import Foundation

enum LiveMeetingAudioFrameConverterError: LocalizedError, Equatable {
    case invalidSampleBuffer
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSampleBuffer:
            return "Unable to read audio sample buffer."
        case .conversionFailed(let message):
            return "Unable to convert audio sample buffer: \(message)"
        }
    }
}

enum LiveMeetingAudioCaptureError: LocalizedError, Equatable {
    case noMicrophoneAvailable
    case alreadyRunning
    case sessionSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophoneAvailable:
            return "No microphone input device is available."
        case .alreadyRunning:
            return "Audio capture is already running."
        case .sessionSetupFailed(let message):
            return message
        }
    }
}

struct LiveMeetingAudioChunker {
    private let chunkByteSize: Int
    private var buffer = Data()

    var pendingByteCount: Int { buffer.count }
    var targetChunkByteSize: Int { chunkByteSize }

    init(chunkDurationMS: Int, sampleRate: Int = 16_000, bytesPerSample: Int = 2, channelCount: Int = 1) {
        let normalizedChunkDuration = max(1, chunkDurationMS)
        let bytesPerSecond = sampleRate * bytesPerSample * channelCount
        self.chunkByteSize = max(1, bytesPerSecond * normalizedChunkDuration / 1_000)
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var chunks: [Data] = []
        while buffer.count >= chunkByteSize {
            let chunk = buffer.prefix(chunkByteSize)
            chunks.append(Data(chunk))
            buffer.removeFirst(chunkByteSize)
        }
        return chunks
    }

    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll(keepingCapacity: true) }
        return buffer
    }
}

final class LiveMeetingAudioFrameConverter {
    private let targetFormat: AVAudioFormat

    init(targetSampleRate: Double = 16_000, targetChannelCount: AVAudioChannelCount = 1) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: false
        ) else {
            preconditionFailure("Unable to create target audio format.")
        }
        self.targetFormat = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw LiveMeetingAudioFrameConverterError.conversionFailed("Unable to create AVAudioConverter.")
        }

        let estimatedFrameCount = AVAudioFrameCount(
            max(1, (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up))
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: estimatedFrameCount + 16
        ) else {
            throw LiveMeetingAudioFrameConverterError.conversionFailed("Unable to allocate output buffer.")
        }

        var didProvideInput = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            throw LiveMeetingAudioFrameConverterError.conversionFailed(
                error?.localizedDescription ?? "unknown conversion error"
            )
        }

        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0, let channelData = outputBuffer.int16ChannelData?.pointee else {
            return Data()
        }

        return Data(bytes: channelData, count: frameLength * MemoryLayout<Int16>.size)
    }

    func convert(sampleBuffer: CMSampleBuffer) throws -> Data {
        let pcmBuffer = try makePCMBuffer(from: sampleBuffer)
        return try convert(pcmBuffer)
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbdPointer)
        else {
            throw LiveMeetingAudioFrameConverterError.invalidSampleBuffer
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw LiveMeetingAudioFrameConverterError.invalidSampleBuffer
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw LiveMeetingAudioFrameConverterError.invalidSampleBuffer
        }

        return pcmBuffer
    }
}

final class SystemMicrophoneAudioCapture: NSObject, LiveMeetingAudioCapturing, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "ai.neuxnet.neutype.live-caption.capture")
    private let stateQueue = DispatchQueue(label: "ai.neuxnet.neutype.live-caption.state")
    private let converter = LiveMeetingAudioFrameConverter()

    private var captureSession: AVCaptureSession?
    private var frameHandler: (@Sendable (Data) -> Void)?
    private var sampleBufferCount = 0

    func start(frameHandler: @escaping @Sendable (Data) -> Void) async throws {
        if stateQueue.sync(execute: { captureSession != nil }) {
            throw LiveMeetingAudioCaptureError.alreadyRunning
        }

        guard let device = MicrophoneService.shared.getAVCaptureDevice() else {
            throw LiveMeetingAudioCaptureError.noMicrophoneAvailable
        }
        RequestLogStore.log(.usage, "Live caption audio capture selected device: \(device.localizedName) id=\(device.uniqueID)")

        let session = AVCaptureSession()
        session.beginConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw LiveMeetingAudioCaptureError.sessionSetupFailed("Unable to add microphone input.")
            }
            session.addInput(input)
        } catch let error as LiveMeetingAudioCaptureError {
            throw error
        } catch {
            throw LiveMeetingAudioCaptureError.sessionSetupFailed("Unable to configure microphone input: \(error.localizedDescription)")
        }

        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            throw LiveMeetingAudioCaptureError.sessionSetupFailed("Unable to add microphone output.")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        session.commitConfiguration()

        self.frameHandler = frameHandler
        sampleBufferCount = 0
        try await startCaptureSession(session)
        guard session.isRunning else {
            RequestLogStore.log(.usage, "Live caption audio capture failed: session did not start running")
            throw LiveMeetingAudioCaptureError.sessionSetupFailed("音频采集会话未能启动，请检查麦克风权限和输入设备。")
        }
        RequestLogStore.log(.usage, "Live caption audio capture session running inputs=\(session.inputs.count) outputs=\(session.outputs.count)")
        stateQueue.sync {
            captureSession = session
        }
    }

    func stop() async {
        let session = stateQueue.sync {
            let session = captureSession
            captureSession = nil
            return session
        }
        frameHandler = nil
        guard let session else { return }
        await stopCaptureSession(session)
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
}

extension SystemMicrophoneAudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let frameHandler else { return }

        do {
            let data = try converter.convert(sampleBuffer: sampleBuffer)
            sampleBufferCount += 1
            if sampleBufferCount <= 3 || sampleBufferCount.isMultiple(of: 50) {
                RequestLogStore.log(
                    .usage,
                    "Live caption audio sample #\(sampleBufferCount): samples=\(CMSampleBufferGetNumSamples(sampleBuffer)) convertedBytes=\(data.count)"
                )
            }
            if !data.isEmpty {
                frameHandler(data)
            } else if sampleBufferCount <= 3 {
                RequestLogStore.log(.usage, "Live caption audio sample #\(sampleBufferCount) converted to empty PCM data")
            }
        } catch {
            RequestLogStore.log(.usage, "Live caption audio conversion failed: \(error.localizedDescription)")
        }
    }
}
