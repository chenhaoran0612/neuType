import AVFoundation
import XCTest
@testable import NeuType

final class MeetingRecorderTests: XCTestCase {
    func testFinalOutputFormatUsesCompactInt16Mono16k() {
        let format = MeetingRecorder.makeFinalOutputFormat()

        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }
}
