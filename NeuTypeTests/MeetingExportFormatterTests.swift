import XCTest
@testable import NeuType

final class MeetingExportFormatterTests: XCTestCase {
    func testTranscriptTextUsesRequestedSpeakerTimeFormat() {
        let meetingID = UUID()
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        components.year = 2026
        components.month = 4
        components.day = 12
        components.hour = 23
        components.minute = 3
        let meetingDate = try! XCTUnwrap(components.date)
        let segments = [
            MeetingTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 10,
                text: "第一段内容"
            ),
            MeetingTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                sequence: 1,
                speakerLabel: "Speaker 2",
                startTime: 14,
                endTime: 22,
                text: "第二段内容（）"
            ),
        ]

        let text = MeetingExportFormatter.transcriptText(
            meetingTitle: "SQL产品规划等讨论",
            meetingDate: meetingDate,
            segments: segments
        )

        XCTAssertEqual(
            text,
            """
            SQL产品规划等讨论
            会议时间：\(MeetingExportFormatter.formatMeetingDate(meetingDate))

            说话人1  00:00
            第一段内容

            说话人2  00:14
            第二段内容（）
            """
        )
    }

    func testTranscriptTextUsesProvidedSegmentTextSelector() {
        let meetingID = UUID()
        let meetingDate = Date(timeIntervalSince1970: 0)
        let segments = [
            MeetingTranscriptSegment(
                id: UUID(),
                meetingID: meetingID,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 10,
                text: "你好",
                textEN: "Hello"
            )
        ]

        let text = MeetingExportFormatter.transcriptText(
            meetingTitle: "客户会议",
            meetingDate: meetingDate,
            segments: segments,
            textProvider: { $0.displayText(for: .english) }
        )

        XCTAssertTrue(text.contains("\nHello"))
        XCTAssertFalse(text.contains("\n你好"))
    }

    func testTranscriptFileNameIncludesSelectedLanguageSuffix() {
        XCTAssertEqual(
            MeetingExportFormatter.transcriptFileName(
                meetingTitle: "客户/会议",
                language: .chinese
            ),
            "客户-会议-中文.txt"
        )
    }

    func testAudioFileNameUsesDisplayedMeetingTitleAndOriginalExtension() {
        XCTAssertEqual(
            MeetingExportFormatter.audioFileName(
                meetingTitle: "Meeting 2026-04-11 20:42",
                originalFileName: "72CAA143-39A3-49E3-BD88-76F7D138E683.wav"
            ),
            "2026-04-11 20-42.wav"
        )
    }
}
