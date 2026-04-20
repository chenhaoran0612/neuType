import XCTest
@testable import NeuType

final class MeetingSummaryServiceTests: XCTestCase {
    func testSubmitMeetingUploadsAssetsAndPersistsCompletedSummary() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(transcriptPreview: "hello world", status: .completed)
        try await store.insertMeeting(meeting, segments: [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 2,
                text: "hello world"
            )
        ])

        let client = StubMeetingSummaryClient(
            createResponse: .init(
                jobID: "job-123",
                taskID: "task-456",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/job-123",
                externalMeetingID: meeting.id.uuidString,
                rawResponseJSON: #"{"job_id":"job-123","task_id":"task-456","status":"queued","poll_url":"/api/integrations/neutype/meetings/job-123"}"#
            ),
            pollResponses: [
                .processing(jobID: "job-123", externalMeetingID: meeting.id.uuidString),
                .completed(
                    jobID: "job-123",
                    externalMeetingID: meeting.id.uuidString,
                    taskID: "task-456",
                    summaryText: "摘要内容",
                    fullText: "# 会议纪要",
                    result: .fixture(),
                    shareURL: "https://ai-worker.neuxnet.com/share/job-123"
                ),
            ]
        )
        let service = MeetingSummaryService(client: client, store: store, pollsInBackground: false)

        try await service.submitMeeting(meetingID: meeting.id)

        XCTAssertEqual(client.submittedMeetings.count, 1)
        XCTAssertEqual(client.submittedMeetings.first?.meetingTitle, meeting.title)

        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryStatus, .completed)
        XCTAssertEqual(saved?.summaryText, "摘要内容")
        XCTAssertEqual(saved?.summaryFullText, "# 会议纪要")
        XCTAssertEqual(saved?.summaryShareURL, "https://ai-worker.neuxnet.com/share/job-123")
        XCTAssertEqual(saved?.decodedSummaryResult?.summary, "总结内容")
        XCTAssertEqual(
            saved?.summaryLastResponseJSON,
            """
            {"job_id":"job-123","external_meeting_id":"\(meeting.id.uuidString)","task_id":"task-456","status":"completed","meeting_title":"客户周会","summary_text":"摘要内容","full_text":"# 会议纪要","share_url":"https://ai-worker.neuxnet.com/share/job-123","error_message":"","poll_url":"/api/integrations/neutype/meetings/job-123"}
            """
        )
    }

    func testResumeMeetingPollsExistingJobWithoutResubmitting() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(
            transcriptPreview: "hello world",
            status: .completed,
            summaryStatus: .queued,
            summaryJobID: "job-existing"
        )
        try await store.insertMeeting(meeting, segments: [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 2,
                text: "hello world"
            )
        ])

        let client = StubMeetingSummaryClient(
            createResponse: .init(
                jobID: "unused",
                taskID: "unused",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/unused",
                externalMeetingID: meeting.id.uuidString,
                rawResponseJSON: #"{"job_id":"unused","task_id":"unused","status":"queued","poll_url":"/api/integrations/neutype/meetings/unused"}"#
            ),
            pollResponses: [
                .completed(
                    jobID: "job-existing",
                    externalMeetingID: meeting.id.uuidString,
                    taskID: "task-456",
                    summaryText: "摘要内容",
                    fullText: "# 会议纪要",
                    result: .fixture(),
                    shareURL: "https://ai-worker.neuxnet.com/share/job-existing"
                ),
            ]
        )
        let service = MeetingSummaryService(client: client, store: store, pollsInBackground: false)

        try await service.resumeMeeting(meetingID: meeting.id)

        XCTAssertEqual(client.submittedMeetings.count, 0)
        XCTAssertEqual(client.fetchedJobIDs, ["job-existing"])
        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryStatus, .completed)
    }

    func testCompletedPollDoesNotFallbackSummaryTextIntoFullText() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(transcriptPreview: "hello world", status: .completed)
        try await store.insertMeeting(meeting, segments: [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 2,
                text: "hello world"
            )
        ])

        let client = StubMeetingSummaryClient(
            createResponse: .init(
                jobID: "job-empty-full",
                taskID: "task-empty-full",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/job-empty-full",
                externalMeetingID: meeting.id.uuidString,
                rawResponseJSON: #"{"job_id":"job-empty-full","task_id":"task-empty-full","status":"queued","poll_url":"/api/integrations/neutype/meetings/job-empty-full"}"#
            ),
            pollResponses: [
                .completed(
                    jobID: "job-empty-full",
                    externalMeetingID: meeting.id.uuidString,
                    taskID: "task-empty-full",
                    summaryText: "兼容摘要",
                    fullText: "",
                    result: .fixture(),
                    shareURL: "https://ai-worker.neuxnet.com/share/job-empty-full"
                )
            ]
        )
        let service = MeetingSummaryService(client: client, store: store, pollsInBackground: false)

        try await service.submitMeeting(meetingID: meeting.id)

        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryText, "兼容摘要")
        XCTAssertEqual(saved?.summaryFullText, "")
    }

    func testResumeMeetingStartsOnlyOneBackgroundPollPerMeeting() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(
            transcriptPreview: "hello world",
            status: .completed,
            summaryStatus: .queued,
            summaryJobID: "job-existing"
        )
        try await store.insertMeeting(meeting, segments: [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 2,
                text: "hello world"
            )
        ])

        let client = SlowStubMeetingSummaryClient(
            response: .completed(
                jobID: "job-existing",
                externalMeetingID: meeting.id.uuidString,
                taskID: "task-456",
                summaryText: "摘要内容",
                fullText: "# 会议纪要",
                result: .fixture(),
                shareURL: "https://ai-worker.neuxnet.com/share/job-existing"
            )
        )
        let service = MeetingSummaryService(client: client, store: store, pollInterval: .zero, pollsInBackground: true)

        try await service.resumeMeeting(meetingID: meeting.id)
        try await service.resumeMeeting(meetingID: meeting.id)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(client.fetchCount, 1)
        let saved = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(saved?.summaryStatus, .completed)
    }

    func testFailedMeetingRetryUsesFreshSubmissionIdentity() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = makeMeeting(
            transcriptPreview: "hello world",
            status: .completed,
            summaryStatus: .failed,
            summaryJobID: "job-failed"
        )
        try await store.insertMeeting(meeting, segments: [
            makeSegment(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 2,
                text: "hello world"
            )
        ])

        let client = StubMeetingSummaryClient(
            createResponse: .init(
                jobID: "job-retry",
                taskID: "task-retry",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/job-retry",
                externalMeetingID: "\(meeting.id.uuidString)-retry",
                rawResponseJSON: #"{"job_id":"job-retry","task_id":"task-retry","status":"queued","poll_url":"/api/integrations/neutype/meetings/job-retry"}"#
            ),
            pollResponses: [
                .processing(jobID: "job-retry", externalMeetingID: "\(meeting.id.uuidString)-retry")
            ]
        )
        let service = MeetingSummaryService(
            client: client,
            store: store,
            pollInterval: .zero,
            maxPollCount: 1,
            pollsInBackground: false
        )

        do {
            try await service.submitMeeting(meetingID: meeting.id)
        } catch {
            // Expected: no poll responses were supplied.
        }

        let submission = try XCTUnwrap(client.submittedMeetings.first)
        XCTAssertTrue(submission.externalMeetingID.hasPrefix("\(meeting.id.uuidString)-retry-"))
        XCTAssertTrue(submission.idempotencyKey.hasPrefix("neutype-\(meeting.id.uuidString)-summary-retry-"))
    }

    func testConcurrentSubmissionsOnSharedServiceKeepMeetingSummariesSeparated() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meetingA = makeMeeting(id: UUID(), title: "Meeting A", transcriptPreview: "alpha", status: .completed)
        let meetingB = makeMeeting(id: UUID(), title: "Meeting B", transcriptPreview: "beta", status: .completed)
        try await store.insertMeeting(meetingA, segments: [
            makeSegment(meetingID: meetingA.id, sequence: 0, speakerLabel: "Speaker 1", text: "alpha")
        ])
        try await store.insertMeeting(meetingB, segments: [
            makeSegment(meetingID: meetingB.id, sequence: 0, speakerLabel: "Speaker 1", text: "beta")
        ])

        let client = ConcurrentStubMeetingSummaryClient(meetingA: meetingA, meetingB: meetingB)
        let service = MeetingSummaryService(client: client, store: store, pollInterval: .zero, pollsInBackground: false)

        async let submitA = service.submitMeeting(meetingID: meetingA.id)
        async let submitB = service.submitMeeting(meetingID: meetingB.id)
        _ = try await (submitA, submitB)

        let savedA = try await store.fetchMeeting(id: meetingA.id)
        let savedB = try await store.fetchMeeting(id: meetingB.id)

        XCTAssertEqual(savedA?.summaryText, "summary-a")
        XCTAssertEqual(savedB?.summaryText, "summary-b")
        XCTAssertEqual(savedA?.summaryShareURL, "https://ai-worker.neuxnet.com/share/job-a")
        XCTAssertEqual(savedB?.summaryShareURL, "https://ai-worker.neuxnet.com/share/job-b")
    }

    func testPollResponseDecodesFailedPayloadWithEmptyResultObject() throws {
        let payload = Data(
            """
            {
              "job_id": "job-123",
              "external_meeting_id": "meeting-123",
              "task_id": "task-456",
              "status": "failed",
              "meeting_title": "客户周会",
              "summary_text": null,
              "full_text": "",
              "result_json": {},
              "share_url": null,
              "error_message": "Experiment Tracker 执行失败",
              "poll_url": "/api/integrations/neutype/meetings/job-123"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(MeetingSummaryPollResponse.self, from: payload)

        XCTAssertEqual(response.status, .failed)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.errorMessage, "Experiment Tracker 执行失败")
        XCTAssertEqual(response.summaryText, "")
        XCTAssertEqual(response.fullText, "")
        XCTAssertEqual(response.shareURL, "")
    }

    func testPollResponseDecodesCompletedPayloadWithFullText() throws {
        let payload = Data(
            """
            {
              "job_id": "job-789",
              "external_meeting_id": "meeting-789",
              "task_id": "task-789",
              "status": "completed",
              "meeting_title": "客户周会",
              "summary_text": "摘要内容",
              "full_text": "# 完整纪要\\n\\n- 要点",
              "share_url": "https://ai-worker.neuxnet.com/share/job-789",
              "error_message": null,
              "poll_url": "/api/integrations/neutype/meetings/job-789"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(MeetingSummaryPollResponse.self, from: payload)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.summaryText, "摘要内容")
        XCTAssertEqual(response.fullText, "# 完整纪要\n\n- 要点")
        XCTAssertEqual(response.shareURL, "https://ai-worker.neuxnet.com/share/job-789")
    }

    func testCreateResponseDebugSummaryContainsKeyInterfaceFields() {
        let response = MeetingSummaryCreateResponse(
            jobID: "job-123",
            taskID: "task-456",
            status: .queued,
            pollURL: "/api/integrations/neutype/meetings/job-123",
            externalMeetingID: "meeting-123",
            rawResponseJSON: #"{"job_id":"job-123"}"#
        )

        let summary = response.debugSummary

        XCTAssertTrue(summary.contains("jobID=job-123"))
        XCTAssertTrue(summary.contains("taskID=task-456"))
        XCTAssertTrue(summary.contains("status=queued"))
        XCTAssertTrue(summary.contains("pollURL=/api/integrations/neutype/meetings/job-123"))
        XCTAssertTrue(summary.contains("externalMeetingID=meeting-123"))
    }

    func testPollResponseDebugSummaryContainsKeyInterfaceFields() {
        let response = MeetingSummaryPollResponse(
            jobID: "job-789",
            externalMeetingID: "meeting-789",
            taskID: "task-789",
            status: .completed,
            meetingTitle: "客户周会",
            summaryText: "摘要内容",
            fullText: "# 完整纪要\n\n- 要点",
            result: .fixture(),
            shareURL: "https://ai-worker.neuxnet.com/share/job-789",
            errorMessage: "",
            pollURL: "/api/integrations/neutype/meetings/job-789",
            rawResponseJSON: #"{"job_id":"job-789"}"#
        )

        let summary = response.debugSummary

        XCTAssertTrue(summary.contains("jobID=job-789"))
        XCTAssertTrue(summary.contains("status=completed"))
        XCTAssertTrue(summary.contains("meetingTitle=客户周会"))
        XCTAssertTrue(summary.contains("summaryTextLength=4"))
        XCTAssertTrue(summary.contains("fullTextLength=12"))
        XCTAssertTrue(summary.contains("shareURL=https://ai-worker.neuxnet.com/share/job-789"))
        XCTAssertTrue(summary.contains("pollURL=/api/integrations/neutype/meetings/job-789"))
    }
}

private final class StubMeetingSummaryClient: MeetingSummaryClientProtocol, @unchecked Sendable {
    var submittedMeetings: [MeetingSummarySubmissionPayload] = []
    var fetchedJobIDs: [String] = []
    private let createResponse: MeetingSummaryCreateResponse
    private var pollResponses: [MeetingSummaryPollResponse]

    init(
        createResponse: MeetingSummaryCreateResponse,
        pollResponses: [MeetingSummaryPollResponse]
    ) {
        self.createResponse = createResponse
        self.pollResponses = pollResponses
    }

    func submitMeeting(_ payload: MeetingSummarySubmissionPayload) async throws -> MeetingSummaryCreateResponse {
        submittedMeetings.append(payload)
        return createResponse
    }

    func fetchMeeting(jobID: String) async throws -> MeetingSummaryPollResponse {
        fetchedJobIDs.append(jobID)
        return pollResponses.removeFirst()
    }
}

private final class SlowStubMeetingSummaryClient: MeetingSummaryClientProtocol, @unchecked Sendable {
    private let response: MeetingSummaryPollResponse
    private(set) var fetchCount = 0

    init(response: MeetingSummaryPollResponse) {
        self.response = response
    }

    func submitMeeting(_ payload: MeetingSummarySubmissionPayload) async throws -> MeetingSummaryCreateResponse {
        fatalError("submitMeeting should not be called in this test")
    }

    func fetchMeeting(jobID: String) async throws -> MeetingSummaryPollResponse {
        fetchCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        return response
    }
}

private actor ConcurrentStubMeetingSummaryClient: MeetingSummaryClientProtocol {
    private let responsesByMeetingID: [String: MeetingSummaryCreateResponse]
    private let pollsByJobID: [String: MeetingSummaryPollResponse]

    init(meetingA: MeetingRecord, meetingB: MeetingRecord) {
        responsesByMeetingID = [
            meetingA.id.uuidString: MeetingSummaryCreateResponse(
                jobID: "job-a",
                taskID: "task-a",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/job-a",
                externalMeetingID: meetingA.id.uuidString
            ),
            meetingB.id.uuidString: MeetingSummaryCreateResponse(
                jobID: "job-b",
                taskID: "task-b",
                status: .queued,
                pollURL: "/api/integrations/neutype/meetings/job-b",
                externalMeetingID: meetingB.id.uuidString
            ),
        ]
        pollsByJobID = [
            "job-a": .completed(
                jobID: "job-a",
                externalMeetingID: meetingA.id.uuidString,
                taskID: "task-a",
                summaryText: "summary-a",
                fullText: "# Summary A",
                result: .fixture(),
                shareURL: "https://ai-worker.neuxnet.com/share/job-a"
            ),
            "job-b": .completed(
                jobID: "job-b",
                externalMeetingID: meetingB.id.uuidString,
                taskID: "task-b",
                summaryText: "summary-b",
                fullText: "# Summary B",
                result: .fixture(),
                shareURL: "https://ai-worker.neuxnet.com/share/job-b"
            ),
        ]
    }

    func submitMeeting(_ payload: MeetingSummarySubmissionPayload) async throws -> MeetingSummaryCreateResponse {
        try? await Task.sleep(for: .milliseconds(payload.meetingTitle == "Meeting A" ? 30 : 10))
        return try XCTUnwrap(
            responsesByMeetingID[payload.externalMeetingID],
            "Missing create response for \(payload.externalMeetingID)"
        )
    }

    func fetchMeeting(jobID: String) async throws -> MeetingSummaryPollResponse {
        try? await Task.sleep(for: .milliseconds(jobID == "job-a" ? 10 : 30))
        return try XCTUnwrap(pollsByJobID[jobID], "Missing poll response for \(jobID)")
    }
}

private extension MeetingSummaryResult {
    static func fixture() -> MeetingSummaryResult {
        MeetingSummaryResult(
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
    }
}

private extension MeetingSummaryPollResponse {
    static func processing(jobID: String, externalMeetingID: String) -> MeetingSummaryPollResponse {
        MeetingSummaryPollResponse(
            jobID: jobID,
            externalMeetingID: externalMeetingID,
            taskID: "task-456",
            status: .processing,
            meetingTitle: "Meeting",
            summaryText: "",
            fullText: "",
            result: nil,
            shareURL: "",
            errorMessage: "",
            pollURL: "/api/integrations/neutype/meetings/\(jobID)",
            rawResponseJSON: #"{"job_id":"\#(jobID)","external_meeting_id":"\#(externalMeetingID)","task_id":"task-456","status":"processing","meeting_title":"Meeting","summary_text":"","full_text":"","share_url":"","error_message":"","poll_url":"/api/integrations/neutype/meetings/\#(jobID)"}"#
        )
    }

    static func completed(
        jobID: String,
        externalMeetingID: String,
        taskID: String,
        summaryText: String,
        fullText: String,
        result: MeetingSummaryResult,
        shareURL: String
    ) -> MeetingSummaryPollResponse {
        MeetingSummaryPollResponse(
            jobID: jobID,
            externalMeetingID: externalMeetingID,
            taskID: taskID,
            status: .completed,
            meetingTitle: result.meetingTitle,
            summaryText: summaryText,
            fullText: fullText,
            result: result,
            shareURL: shareURL,
            errorMessage: "",
            pollURL: "/api/integrations/neutype/meetings/\(jobID)",
            rawResponseJSON: """
            {"job_id":"\(jobID)","external_meeting_id":"\(externalMeetingID)","task_id":"\(taskID)","status":"completed","meeting_title":"\(result.meetingTitle)","summary_text":"\(summaryText)","full_text":"\(fullText)","share_url":"\(shareURL)","error_message":"","poll_url":"/api/integrations/neutype/meetings/\(jobID)"}
            """
        )
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
    summaryStatus: MeetingSummaryStatus = .unsubmitted,
    summaryJobID: String = ""
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
        summaryStatus: summaryStatus,
        summaryJobID: summaryJobID
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
