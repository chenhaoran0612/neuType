import AVFoundation
import Foundation

final class MeetingChunkSealer {
    private let chunkDuration: TimeInterval
    private let overlapDuration: TimeInterval

    init(
        chunkDuration: TimeInterval = 300,
        overlapDuration: TimeInterval = 2.5
    ) {
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
    }

    func sealChunksIfNeeded(
        totalDuration: TimeInterval,
        sourceURL: URL
    ) throws -> [MeetingRecordingChunkArtifact] {
        try sealChunksIfNeeded(
            totalDuration: totalDuration,
            sourceURL: sourceURL,
            outputDirectory: nil,
            includeTrailingPartialChunk: false
        )
    }

    func sealChunksForFinalization(
        totalDuration: TimeInterval,
        sourceURL: URL,
        outputDirectory: URL? = nil
    ) throws -> [MeetingRecordingChunkArtifact] {
        try sealChunksIfNeeded(
            totalDuration: totalDuration,
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            includeTrailingPartialChunk: true
        )
    }

    func sealChunksIfNeeded(
        totalDuration: TimeInterval,
        sourceURL: URL,
        outputDirectory: URL?,
        includeTrailingPartialChunk: Bool
    ) throws -> [MeetingRecordingChunkArtifact] {
        guard chunkDuration > 0, totalDuration > 0 else {
            return []
        }

        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sampleRate = sourceFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return [] }

        let outputDirectory = try makeOutputDirectory(overriding: outputDirectory)
        var artifacts: [MeetingRecordingChunkArtifact] = []
        let chunkFrames = AVAudioFramePosition(round(chunkDuration * sampleRate))
        let strideDuration = max(chunkDuration - max(overlapDuration, 0), 0.001)
        var chunkIndex = 0
        var chunkStart = 0.0

        while chunkStart + chunkDuration <= totalDuration + 0.001 {
            let startFrame = AVAudioFramePosition(round(chunkStart * sampleRate))
            let availableFrames = max(sourceFile.length - startFrame, 0)
            let framesToWrite = min(chunkFrames, availableFrames)
            guard framesToWrite > 0 else { break }

            let outputURL = outputDirectory
                .appendingPathComponent("meeting-chunk-\(chunkIndex)")
                .appendingPathExtension("wav")
            try Self.writeAudioChunk(
                sourceFile: sourceFile,
                outputURL: outputURL,
                startFrame: startFrame,
                frameCount: framesToWrite
            )
            let startMS = Int((Double(startFrame) / sampleRate * 1_000).rounded())
            let endMS = Int((Double(startFrame + framesToWrite) / sampleRate * 1_000).rounded())
            artifacts.append(
                .init(
                    chunkIndex: chunkIndex,
                    startMS: startMS,
                    endMS: endMS,
                    fileURL: outputURL
                )
            )
            chunkIndex += 1
            chunkStart += strideDuration
        }

        if includeTrailingPartialChunk {
            let trailingStart = Double(chunkIndex) * strideDuration
            if trailingStart < totalDuration {
                let startFrame = AVAudioFramePosition(round(trailingStart * sampleRate))
                let availableFrames = max(sourceFile.length - startFrame, 0)
                if availableFrames > 0 {
                    let outputURL = outputDirectory
                        .appendingPathComponent("meeting-chunk-\(chunkIndex)")
                        .appendingPathExtension("wav")
                    try Self.writeAudioChunk(
                        sourceFile: sourceFile,
                        outputURL: outputURL,
                        startFrame: startFrame,
                        frameCount: availableFrames
                    )
                    let startMS = Int((Double(startFrame) / sampleRate * 1_000).rounded())
                    let endMS = Int((Double(startFrame + availableFrames) / sampleRate * 1_000).rounded())
                    artifacts.append(
                        .init(
                            chunkIndex: chunkIndex,
                            startMS: startMS,
                            endMS: endMS,
                            fileURL: outputURL
                        )
                    )
                }
            }
        }

        return artifacts
    }

    private func makeOutputDirectory(overriding outputDirectory: URL?) throws -> URL {
        let directory = outputDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-chunks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writeAudioChunk(
        sourceFile: AVAudioFile,
        outputURL: URL,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition
    ) throws {
        let originalFramePosition = sourceFile.framePosition
        defer { sourceFile.framePosition = originalFramePosition }

        let format = sourceFile.processingFormat
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        sourceFile.framePosition = startFrame

        var remainingFrames = frameCount
        let maxBufferFrames: AVAudioFrameCount = 8_192

        while remainingFrames > 0 {
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(maxBufferFrames), remainingFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw MeetingRecorderError.sourceSetupFailed("Unable to allocate meeting chunk buffer.")
            }
            try sourceFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
            remainingFrames -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
