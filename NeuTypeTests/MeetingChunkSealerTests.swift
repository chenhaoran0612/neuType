import AVFoundation
import XCTest
@testable import NeuType

final class MeetingChunkSealerTests: XCTestCase {
    func testChunkSealerEmitsFiveMinuteArtifact() throws {
        let sourceURL = makeSourceAudioURL(duration: 301)
        let sealer = MeetingChunkSealer(chunkDuration: 300, overlapDuration: 2.5)

        let artifacts = try sealer.sealChunksIfNeeded(totalDuration: 301, sourceURL: sourceURL)

        XCTAssertEqual(artifacts.map(\.chunkIndex), [0])
        XCTAssertEqual(artifacts.first?.startMS, 0)
        XCTAssertEqual(artifacts.first?.endMS, 300_000)

        let sealedFile = try AVAudioFile(forReading: try XCTUnwrap(artifacts.first?.fileURL))
        let sealedDuration = Double(sealedFile.length) / sealedFile.processingFormat.sampleRate
        XCTAssertEqual(sealedDuration, 300, accuracy: 0.05)
    }

    func testChunkSealerUsesConfiguredOverlapForSubsequentChunks() throws {
        let sourceURL = makeSourceAudioURL(duration: 598)
        let sealer = MeetingChunkSealer(chunkDuration: 300, overlapDuration: 2.5)

        let artifacts = try sealer.sealChunksIfNeeded(totalDuration: 598, sourceURL: sourceURL)

        XCTAssertEqual(artifacts.map(\.chunkIndex), [0, 1])
        XCTAssertEqual(artifacts.map(\.startMS), [0, 297_500])
        XCTAssertEqual(artifacts.map(\.endMS), [300_000, 597_500])
    }

    func testChunkSealerFinalizationIncludesTrailingPartialChunk() throws {
        let sourceURL = makeSourceAudioURL(duration: 301)
        let sealer = MeetingChunkSealer(chunkDuration: 300, overlapDuration: 2.5)

        let artifacts = try sealer.sealChunksForFinalization(
            totalDuration: 301,
            sourceURL: sourceURL
        )

        XCTAssertEqual(artifacts.map(\.chunkIndex), [0, 1])
        XCTAssertEqual(artifacts.map(\.startMS), [0, 297_500])
        XCTAssertEqual(artifacts.map(\.endMS), [300_000, 301_000])
    }
}

private func makeSourceAudioURL(duration: TimeInterval) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    if let channel = buffer.int16ChannelData?.pointee {
        for index in 0 ..< Int(frameCount) {
            channel[index] = Int16((index * 7) % Int(Int16.max))
        }
    }

    let file = try? AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
    try? file?.write(from: buffer)
    return url
}
