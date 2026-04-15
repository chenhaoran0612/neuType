import XCTest
@testable import NeuType

final class MeetingRecordStoreTests: XCTestCase {
    func testInsertMeetingAndFetchSegments() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(status: .processing)
        let segments = [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1"
            ),
            makeSegment(
                meetingID: meeting.id,
                sequence: 1,
                speakerLabel: "Speaker 2"
            ),
        ]

        try await store.insertMeeting(meeting, segments: segments)

        let loaded = try await store.fetchMeeting(id: meeting.id)
        let loadedSegments = try await store.fetchSegments(meetingID: meeting.id)

        XCTAssertEqual(loaded?.id, meeting.id)
        XCTAssertEqual(loadedSegments.map { $0.speakerLabel }, ["Speaker 1", "Speaker 2"])
    }

    func testUpdateMeetingStatusPersistsStatusProgressAndPreview() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(status: .unprocessed, progress: 0)
        try await store.insertMeeting(meeting, segments: [])

        try await store.updateMeetingStatus(
            meetingID: meeting.id,
            status: .failed,
            progress: 0,
            transcriptPreview: "service unavailable"
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.status, .failed)
        XCTAssertEqual(saved?.transcriptPreview, "service unavailable")
    }

    func testFetchMeetingsKeepsProcessingMeetingMarkedDuringCurrentSession() async throws {
        let store = try MeetingRecordStore.inMemory()
        let stale = makeMeeting(
            createdAt: Date(timeIntervalSince1970: 100),
            title: "stale",
            status: .unprocessed,
            progress: 0
        )
        try await store.insertMeeting(stale, segments: [])
        try await store.updateMeetingStatus(
            meetingID: stale.id,
            status: .processing,
            progress: 0,
            transcriptPreview: ""
        )

        let meetings = try await store.fetchMeetings()

        XCTAssertEqual(meetings.first?.status, .processing)
        XCTAssertEqual(meetings.first?.progress, 0)
        XCTAssertEqual(meetings.first?.transcriptPreview, "")
    }

    func testFetchMeetingKeepsProcessingMeetingMarkedDuringCurrentSession() async throws {
        let store = try MeetingRecordStore.inMemory()
        let stale = makeMeeting(
            createdAt: Date(timeIntervalSince1970: 100),
            title: "stale",
            status: .unprocessed,
            progress: 0
        )
        try await store.insertMeeting(stale, segments: [])
        try await store.updateMeetingStatus(
            meetingID: stale.id,
            status: .processing,
            progress: 0,
            transcriptPreview: ""
        )

        let meeting = try await store.fetchMeeting(id: stale.id)

        XCTAssertEqual(meeting?.status, .processing)
        XCTAssertEqual(meeting?.progress, 0)
        XCTAssertEqual(meeting?.transcriptPreview, "")
    }

    func testUpdateSummarySubmissionPersistsRemoteJobMetadata() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(transcriptPreview: "hello world", status: .completed)
        try await store.insertMeeting(meeting, segments: [])

        try await store.updateSummarySubmission(
            meetingID: meeting.id,
            status: .queued,
            externalMeetingID: "meeting-\(meeting.id.uuidString)",
            jobID: "job-123",
            taskID: "task-456",
            pollURL: "/api/integrations/neutype/meetings/job-123"
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryStatus, .queued)
        XCTAssertEqual(saved?.summaryExternalMeetingID, "meeting-\(meeting.id.uuidString)")
        XCTAssertEqual(saved?.summaryJobID, "job-123")
        XCTAssertEqual(saved?.summaryTaskID, "task-456")
        XCTAssertEqual(saved?.summaryPollURL, "/api/integrations/neutype/meetings/job-123")
    }

    func testUpdateSummaryResultPersistsCompletedPayload() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(transcriptPreview: "hello world", status: .completed)
        try await store.insertMeeting(meeting, segments: [])
        let result = MeetingSummaryResult(
            meetingTitle: "客户周会",
            meetingStartedAt: Date(timeIntervalSince1970: 100),
            meetingEndedAt: Date(timeIntervalSince1970: 200),
            summary: "总结内容",
            keyPoints: ["要点 1"],
            actionItems: [
                MeetingSummaryActionItem(owner: "我方团队", task: "跟进 Demo", dueAt: "本周")
            ],
            risks: ["风险 1"],
            shareSummary: "一句话摘要"
        )

        try await store.updateSummaryResult(
            meetingID: meeting.id,
            summaryText: "摘要内容",
            fullText: "# 会议纪要",
            result: result,
            shareURL: "https://ai-worker.neuxnet.com/share/abc"
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryStatus, .completed)
        XCTAssertEqual(saved?.summaryText, "摘要内容")
        XCTAssertEqual(saved?.summaryFullText, "# 会议纪要")
        XCTAssertEqual(saved?.summaryShareURL, "https://ai-worker.neuxnet.com/share/abc")
        XCTAssertEqual(saved?.decodedSummaryResult, result)
    }
}

private func makeMeeting(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    title: String = "Meeting",
    audioFileName: String = "meeting.wav",
    transcriptPreview: String = "",
    duration: TimeInterval = 0,
    status: MeetingRecordStatus = .recording,
    progress: Float = 0,
    summaryStatus: MeetingSummaryStatus = .unsubmitted
) -> MeetingRecord {
    MeetingRecord(
        id: id,
        createdAt: createdAt,
        title: title,
        audioFileName: audioFileName,
        transcriptPreview: transcriptPreview,
        duration: duration,
        status: status,
        progress: progress,
        summaryStatus: summaryStatus
    )
}

private func makeSegment(
    id: UUID = UUID(),
    meetingID: UUID,
    sequence: Int,
    speakerLabel: String,
    startTime: TimeInterval = 0,
    endTime: TimeInterval = 1,
    text: String = "segment"
) -> MeetingTranscriptSegment {
    MeetingTranscriptSegment(
        id: id,
        meetingID: meetingID,
        sequence: sequence,
        speakerLabel: speakerLabel,
        startTime: startTime,
        endTime: endTime,
        text: text
    )
}
