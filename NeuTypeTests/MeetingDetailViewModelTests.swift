import XCTest
@testable import NeuType

final class MeetingDetailViewModelTests: XCTestCase {
    @MainActor
    func testTranscriptStateReflectsUnprocessedMeeting() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.transcriptState, .unprocessed)
    }

    @MainActor
    func testTranscriptStateReflectsFailedMeeting() async throws {
        let meeting = MeetingRecord.fixture(
            transcriptPreview: "remote service error",
            status: .failed
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.transcriptState, .failed(message: "remote service error"))
    }

    @MainActor
    func testProcessTranscriptTransitionsUnprocessedMeetingToCompleted() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])
        let transcriber = StubMeetingTranscriber(store: store)

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            transcriptionService: transcriber
        )

        try await viewModel.load()
        await viewModel.processTranscript()

        XCTAssertEqual(transcriber.transcribedMeetingIDs, [meeting.id])
        XCTAssertEqual(viewModel.transcriptState, .completed)
    }

    @MainActor
    func testProcessTranscriptTransitionsFailureIntoFailedState() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])
        let transcriber = StubMeetingTranscriber(error: StubError.message("network timeout"))

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            transcriptionService: transcriber
        )

        try await viewModel.load()
        await viewModel.processTranscript()

        XCTAssertEqual(viewModel.transcriptState, .failed(message: "network timeout"))
        let savedMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(savedMeeting?.status, .failed)
        XCTAssertEqual(savedMeeting?.transcriptPreview, "network timeout")
    }

    @MainActor
    func testStartTranscriptProcessingImmediatelyMarksMeetingProcessing() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])
        let transcriber = StubMeetingTranscriber(
            store: store,
            delayNanoseconds: 300_000_000
        )

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            transcriptionService: transcriber
        )

        try await viewModel.load()
        viewModel.startTranscriptProcessing()

        XCTAssertEqual(viewModel.transcriptState, .processing)
        try? await Task.sleep(for: .milliseconds(50))

        let processingMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(processingMeeting?.status, .processing)
    }

    @MainActor
    func testStartTranscriptProcessingEventuallyShowsFailure() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])
        let transcriber = StubMeetingTranscriber(
            error: StubError.message("No audio segments available. This could happen if the model output doesn't contain valid time stamps."),
            delayNanoseconds: 10_000_000
        )

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            transcriptionService: transcriber
        )

        try await viewModel.load()
        viewModel.startTranscriptProcessing()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            viewModel.transcriptState,
            .failed(message: "No audio segments available. This could happen if the model output doesn't contain valid time stamps.")
        )
    }

    @MainActor
    func testCompletedMeetingKeepsTranscriptAsDefaultUntilSummaryStarts() async throws {
        let meeting = MeetingRecord.fixture(status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "说话人A",
                startTime: 3,
                endTime: 5,
                text: "这是2.5。"
            )
        ])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.activeTab, .transcript)
        XCTAssertEqual(viewModel.segments.count, 1)
    }

    @MainActor
    func testProcessTranscriptAutoSwitchesToSummaryTabAfterSubmittingSummary() async throws {
        let meeting = MeetingRecord.fixture(status: .unprocessed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])
        let transcriber = StubMeetingTranscriber(store: store)
        let summaryService = StubMeetingSummaryService(store: store)

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            transcriptionService: transcriber,
            summaryService: summaryService,
            summaryConfigProvider: StubMeetingSummaryConfigProvider(isConfigured: true)
        )

        try await viewModel.load()
        await viewModel.processTranscript()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(viewModel.activeTab, .summary)
        XCTAssertEqual(summaryService.submittedMeetingIDs, [meeting.id])
    }

    @MainActor
    func testLoadResumesQueuedSummaryJob() async throws {
        let meeting = MeetingRecord.fixture(
            status: .completed,
            summaryStatus: .queued,
            summaryJobID: "job-queued"
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 1,
                text: "hello world"
            )
        ])
        let summaryService = StubMeetingSummaryService(store: store)

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            summaryService: summaryService,
            summaryConfigProvider: StubMeetingSummaryConfigProvider(isConfigured: true)
        )

        try await viewModel.load()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(summaryService.resumedMeetingIDs, [meeting.id])
        XCTAssertEqual(viewModel.summaryState, .completed)
    }

    @MainActor
    func testReloadDoesNotResumeSameSummaryJobMoreThanOnce() async throws {
        let meeting = MeetingRecord.fixture(
            status: .completed,
            summaryStatus: .queued,
            summaryJobID: "job-queued"
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 1,
                text: "hello world"
            )
        ])
        let summaryService = DelayedStubMeetingSummaryService()

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            summaryService: summaryService,
            summaryConfigProvider: StubMeetingSummaryConfigProvider(isConfigured: true)
        )

        try await viewModel.load()
        try await viewModel.reload()
        try await viewModel.reload()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(summaryService.resumedMeetingIDs, [meeting.id])
    }

    @MainActor
    func testSummaryStateReflectsUnsubmittedCompletedMeeting() async throws {
        let meeting = MeetingRecord.fixture(status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 1.5,
                text: "hello world"
            )
        ])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store,
            summaryConfigProvider: StubMeetingSummaryConfigProvider(isConfigured: true)
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.summaryState, .unsubmitted)
    }

    @MainActor
    func testSummaryFullTextDoesNotFallbackToSummaryText() async throws {
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "这是旧 summary",
            summaryFullText: "",
            summaryResultJSON: "",
            summaryShareURL: "",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(viewModel.summaryText, "这是旧 summary")
        XCTAssertEqual(viewModel.summaryFullText, "")
    }

    @MainActor
    func testSummaryFullTextStripsLegacyDeliverableWrapperAndUsesFullTextOnly() async throws {
        let wrappedFullText = """
        I've completed the meeting notes. Here's the deliverable and summary:

        ---

        ## 📄 Deliverable: Meeting Notes File

        **File**: `workspace/meeting_notes_20260415.md`

        The full Markdown file includes:
        - Meeting Brief

        ---

        ## 📋 Summary Message

        ### Meeting Brief
        真正的总结正文
        """
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "这是旧 summary",
            summaryFullText: wrappedFullText,
            summaryResultJSON: "",
            summaryShareURL: "",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.summaryFullText.hasPrefix("## 📋 Summary Message"))
        XCTAssertFalse(viewModel.summaryFullText.contains("## 📄 Deliverable: Meeting Notes File"))
        XCTAssertFalse(viewModel.summaryFullText.contains("这是旧 summary"))
        XCTAssertTrue(viewModel.summaryFullText.contains("真正的总结正文"))
    }

    @MainActor
    func testSummaryFullTextStripsDoneDeliverableWrapperAndUsesSummarySection() async throws {
        let wrappedFullText = """
        Done. Here's the deliverable and summary:

        ---

        ## 📄 Deliverable

        **File:** `workspace/meeting_minutes_2026-04-16_18-16.md`

        ---

        ## 📋 Summary

        ### Meeting Brief
        真正的 full_text 正文
        """
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "这是旧 summary",
            summaryFullText: wrappedFullText,
            summaryResultJSON: "",
            summaryShareURL: "",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.summaryFullText.hasPrefix("## 📋 Summary"))
        XCTAssertFalse(viewModel.summaryFullText.contains("## 📄 Deliverable"))
        XCTAssertTrue(viewModel.summaryFullText.contains("真正的 full_text 正文"))
    }

    @MainActor
    func testSummaryFullTextStripsIndexedDeliverableWrapperAndUsesSummarySection() async throws {
        let wrappedFullText = """
        Here are the results:

        ---

        ## 1. Deliverable

        The full meeting notes Markdown file has been saved to:
        **`workspace/meeting_notes/2026-04-16_0904_hermes_agent_closed_loop.md`**

        ---

        ## 2. Summary Message

        ### 📋 Meeting Brief
        真正的 full_text 正文
        """
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "这是旧 summary",
            summaryFullText: wrappedFullText,
            summaryResultJSON: "",
            summaryShareURL: "",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.summaryFullText.hasPrefix("## 2. Summary Message"))
        XCTAssertFalse(viewModel.summaryFullText.contains("## 1. Deliverable"))
        XCTAssertTrue(viewModel.summaryFullText.contains("真正的 full_text 正文"))
    }

    @MainActor
    func testSummaryLogButtonStillShowsForHistoricalCompletedSummaryWithoutRawJSON() async throws {
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "旧 summary",
            summaryFullText: "# 会议纪要",
            summaryResultJSON: "",
            summaryShareURL: "https://ai-worker.neuxnet.com/share/legacy",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.shouldShowSummaryLogButton)
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("日志采集上线之前"))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("重新生成一次总结"))
    }

    @MainActor
    func testSummaryLogDisplayTextUsesPrettyPrintedRawJSONWhenAvailable() async throws {
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "Meeting",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryJobID: "",
            summaryText: "旧 summary",
            summaryFullText: "# 会议纪要",
            summaryResultJSON: "",
            summaryLastResponseJSON: #"{"job_id":"job-123","status":"completed"}"#,
            summaryShareURL: "https://ai-worker.neuxnet.com/share/legacy",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.shouldShowSummaryLogButton)
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"job_id\" : \"job-123\""))
        XCTAssertFalse(viewModel.summaryLogDisplayText.contains("日志采集上线之前"))
    }

    @MainActor
    func testSummaryLogDisplayTextSynthesizesRemoteSnapshotWhenRawJSONMissing() async throws {
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "客户周会",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .completed,
            summaryExternalMeetingID: "meeting-123",
            summaryJobID: "job-456",
            summaryTaskID: "task-789",
            summaryPollURL: "/api/integrations/neutype/meetings/job-456",
            summaryText: "摘要内容",
            summaryFullText: "# 完整纪要",
            summaryResultJSON: #"{"meeting_title":"客户周会","summary":"摘要内容","key_points":[],"action_items":[],"risks":[],"share_summary":""}"#,
            summaryLastResponseJSON: "",
            summaryShareURL: "https://ai-worker.neuxnet.com/share/job-456",
            summaryErrorMessage: ""
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.shouldShowSummaryLogButton)
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"job_id\" : \"job-456\""))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"full_text\" : \"# 完整纪要\""))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"share_url\" : "))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("job-456"))
        XCTAssertFalse(viewModel.summaryLogDisplayText.contains("日志采集上线之前"))
    }

    @MainActor
    func testSummaryLogDisplayTextSynthesizesFailedRemoteErrorWhenRawJSONMissing() async throws {
        let meeting = MeetingRecord(
            id: UUID(),
            createdAt: Date(),
            title: "工作进展与项目安排",
            audioFileName: "meeting.wav",
            transcriptPreview: "",
            duration: 0,
            status: .completed,
            progress: 0,
            summaryStatus: .failed,
            summaryJobID: "",
            summaryText: "",
            summaryFullText: "",
            summaryResultJSON: "",
            summaryLastResponseJSON: "",
            summaryShareURL: "",
            summaryErrorMessage: #"ai-worker 请求失败（404）：{"detail":"Not Found"}"#
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertTrue(viewModel.shouldShowSummaryLogButton)
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"status\" : \"failed\""))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\n  \"error_message\" : "))
        XCTAssertTrue(viewModel.summaryLogDisplayText.contains("\"detail\" : \"Not Found\""))
        XCTAssertFalse(viewModel.summaryLogDisplayText.contains("日志采集上线之前"))
    }

    @MainActor
    func testTranscriptSearchFiltersSegments() async throws {
        let meeting = MeetingRecord.fixture(status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 0,
                speakerLabel: "说话人A",
                startTime: 3,
                endTime: 5,
                text: "这是2.5。"
            ),
            MeetingTranscriptSegment.fixture(
                meetingID: meeting.id,
                sequence: 1,
                speakerLabel: "说话人B",
                startTime: 9,
                endTime: 12,
                text: "但是我知道一个秘密。"
            )
        ])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        viewModel.searchText = "秘密"

        XCTAssertEqual(viewModel.filteredSegments.map(\.sequence), [1])
    }

    @MainActor
    func testTranscriptRequestLogsExposeMostRecentASREntries() async throws {
        RequestLogStore.shared.clear()
        RequestLogStore.shared.add(.usage, "Meeting: something else")

        let meeting = MeetingRecord.fixture(status: .processing)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        RequestLogContext.$meetingID.withValue(meeting.id) {
            RequestLogStore.shared.add(.asr, "Meeting ASR chunk started 1 / 3")
            RequestLogStore.shared.add(.asr, "Meeting ASR chunk timeout 2 / 3")
        }

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()

        XCTAssertEqual(
            viewModel.transcriptRequestLogs.map(\.message),
            [
                "Meeting ASR chunk timeout 2 / 3",
                "Meeting ASR chunk started 1 / 3",
            ]
        )
    }

    @MainActor
    func testTranscriptRequestLogsAreScopedToCurrentMeeting() async throws {
        RequestLogStore.shared.clear()

        let meetingA = MeetingRecord.fixture(status: .processing)
        let meetingB = MeetingRecord.fixture(status: .processing)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meetingA, segments: [])
        try await store.insertMeeting(meetingB, segments: [])

        RequestLogContext.$meetingID.withValue(meetingA.id) {
            RequestLogStore.shared.add(.asr, "Meeting A started")
            RequestLogStore.shared.add(.asr, "Meeting A finished")
        }
        RequestLogContext.$meetingID.withValue(meetingB.id) {
            RequestLogStore.shared.add(.asr, "Meeting B started")
            RequestLogStore.shared.add(.asr, "Meeting B finished")
        }

        let viewModelA = MeetingDetailViewModel(
            meetingID: meetingA.id,
            audioURL: meetingA.audioURL,
            store: store
        )
        let viewModelB = MeetingDetailViewModel(
            meetingID: meetingB.id,
            audioURL: meetingB.audioURL,
            store: store
        )

        try await viewModelA.load()
        try await viewModelB.load()

        XCTAssertEqual(
            viewModelA.transcriptRequestLogs.map(\.message),
            ["Meeting A finished", "Meeting A started"]
        )
        XCTAssertEqual(
            viewModelB.transcriptRequestLogs.map(\.message),
            ["Meeting B finished", "Meeting B started"]
        )
    }

    @MainActor
    func testRenameMeetingPersistsUpdatedTitle() async throws {
        let meeting = MeetingRecord.fixture(title: "2026-04-12 10:41", status: .completed)
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        try await viewModel.renameMeeting(to: "客户周会")

        XCTAssertEqual(viewModel.meeting?.title, "客户周会")
        let savedMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(savedMeeting?.title, "客户周会")
    }

    @MainActor
    func testRenameMeetingFallsBackToDefaultTitleWhenEmpty() async throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Shanghai")
        components.year = 2026
        components.month = 4
        components.day = 12
        components.hour = 10
        components.minute = 41
        let createdAt = try XCTUnwrap(components.date)
        let meeting = MeetingRecord.fixture(
            createdAt: createdAt,
            title: "2026-04-12 10:41",
            status: .completed
        )
        let store = try MeetingRecordStore.inMemory()
        try await store.insertMeeting(meeting, segments: [])

        let viewModel = MeetingDetailViewModel(
            meetingID: meeting.id,
            audioURL: meeting.audioURL,
            store: store
        )

        try await viewModel.load()
        try await viewModel.renameMeeting(to: "   ")

        XCTAssertEqual(viewModel.meeting?.title, "2026-04-12 10:41")
        let savedMeeting = try await store.fetchMeeting(id: meeting.id)
        XCTAssertEqual(savedMeeting?.title, "2026-04-12 10:41")
    }
}

private struct StubMeetingSummaryConfigProvider: MeetingSummaryConfigProviding {
    let isConfigured: Bool

    var meetingSummaryConfig: MeetingSummaryConfig {
        MeetingSummaryConfig(
            baseURL: isConfigured ? "https://ai-worker.neuxnet.com" : "",
            apiKey: isConfigured ? "ntm_test" : ""
        )
    }
}

private enum StubError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

private final class StubMeetingTranscriber: MeetingTranscribing, @unchecked Sendable {
    var transcribedMeetingIDs: [UUID] = []
    var error: Error?
    let store: MeetingRecordStore?
    let delayNanoseconds: UInt64

    init(store: MeetingRecordStore? = nil, error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.store = store
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(meetingID: UUID, audioURL: URL) async throws {
        transcribedMeetingIDs.append(meetingID)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }

        try await store?.updateTranscription(
            meetingID: meetingID,
            fullText: "hello world",
            segments: [
                MeetingTranscriptionSegmentPayload(
                    sequence: 0,
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: 1.5,
                    text: "hello world"
                )
            ]
        )
    }
}

private extension MeetingRecord {
    static func fixture(
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
}

private final class StubMeetingSummaryService: MeetingSummarizing, @unchecked Sendable {
    var submittedMeetingIDs: [UUID] = []
    var resumedMeetingIDs: [UUID] = []
    let store: MeetingRecordStore

    init(store: MeetingRecordStore) {
        self.store = store
    }

    func submitMeeting(meetingID: UUID) async throws {
        submittedMeetingIDs.append(meetingID)
        try await store.updateSummaryStatus(meetingID: meetingID, status: .received)
    }

    func resumeMeeting(meetingID: UUID) async throws {
        resumedMeetingIDs.append(meetingID)
        try await store.updateSummaryResult(
            meetingID: meetingID,
            summaryText: "已恢复摘要",
            fullText: "# 已恢复",
            result: .summaryFixture(),
            shareURL: "https://ai-worker.neuxnet.com/share/resumed"
        )
    }
}

private final class DelayedStubMeetingSummaryService: MeetingSummarizing, @unchecked Sendable {
    var resumedMeetingIDs: [UUID] = []

    func submitMeeting(meetingID: UUID) async throws {}

    func resumeMeeting(meetingID: UUID) async throws {
        resumedMeetingIDs.append(meetingID)
        try? await Task.sleep(for: .milliseconds(80))
    }
}

private extension MeetingSummaryResult {
    static func summaryFixture() -> MeetingSummaryResult {
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

private extension MeetingTranscriptSegment {
    static func fixture(
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
}
