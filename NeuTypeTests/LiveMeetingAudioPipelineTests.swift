import AVFoundation
import XCTest
@testable import NeuType

final class LiveMeetingAudioPipelineTests: XCTestCase {
    func testChunkerEmitsTwoHundredMillisecondPCMFrames() {
        var chunker = LiveMeetingAudioChunker(chunkDurationMS: 200)
        let firstHalf = Data(repeating: 1, count: 3_200)
        let secondHalf = Data(repeating: 2, count: 3_200)

        XCTAssertEqual(chunker.targetChunkByteSize, 6_400)
        XCTAssertTrue(chunker.append(firstHalf).isEmpty)
        XCTAssertEqual(chunker.pendingByteCount, 3_200)
        let chunks = chunker.append(secondHalf)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 6_400)
        XCTAssertEqual(chunker.pendingByteCount, 0)
        XCTAssertNil(chunker.flush())
    }

    func testChunkerFlushesResidualAudio() {
        var chunker = LiveMeetingAudioChunker(chunkDurationMS: 200)

        XCTAssertTrue(chunker.append(Data(repeating: 7, count: 1_200)).isEmpty)
        let residual = chunker.flush()

        XCTAssertEqual(residual, Data(repeating: 7, count: 1_200))
        XCTAssertNil(chunker.flush())
    }

    func testConverterOutputsSixteenKilohertzSixteenBitMonoPCM() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_600))
        inputBuffer.frameLength = 1_600
        for frame in 0..<Int(inputBuffer.frameLength) {
            inputBuffer.floatChannelData?[0][frame] = frame.isMultiple(of: 2) ? 0.25 : -0.25
        }

        let converter = LiveMeetingAudioFrameConverter()
        let data = try converter.convert(inputBuffer)

        XCTAssertEqual(data.count, 3_200)
    }
}
