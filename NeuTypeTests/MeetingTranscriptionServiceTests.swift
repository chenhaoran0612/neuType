import XCTest
@testable import NeuType

final class MeetingTranscriptionServiceTests: XCTestCase {
    @MainActor
    override func tearDown() {
        RequestLogStore.shared.clear()
        super.tearDown()
    }

    func testTranscribeMeetingPersistsSegmentsAndPreview() async throws {
        let runner = StubVibeVoiceRunnerClient(result: .fixture())
        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing)
        try await store.insertMeeting(meeting, segments: [])
        let service = MeetingTranscriptionService(runner: runner, store: store)

        try await service.transcribe(
            meetingID: meeting.id,
            audioURL: URL(fileURLWithPath: "/tmp/demo.wav")
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        let segments = try await store.fetchSegments(meetingID: meeting.id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.transcriptPreview, "hello world")
        XCTAssertEqual(segments.count, 2)
    }

    func testRemoteCoordinatorPersistsSegmentsAndPreview() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing)
        try await store.insertMeeting(meeting, segments: [])
        let coordinator = StubMeetingRemoteSessionCoordinator(result: .remoteFixture())
        let service = MeetingTranscriptionService(coordinator: coordinator, store: store)

        try await service.transcribe(
            meetingID: meeting.id,
            audioURL: URL(fileURLWithPath: "/tmp/meeting-remote.wav")
        )

        let saved = try await store.fetchMeeting(id: meeting.id)
        let segments = try await store.fetchSegments(meetingID: meeting.id)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.transcriptPreview, "hello world")
        XCTAssertEqual(segments.map(\.text), ["hello", "world"])
        XCTAssertEqual(coordinator.finalizeCalls.count, 1)
        XCTAssertEqual(coordinator.finalizeCalls.first?.expectedChunkCount, 0)
        XCTAssertEqual(coordinator.pollCalls, 1)
    }

    func testRemoteCoordinatorFailurePersistsFailedStatusAndPreview() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing, progress: 0.4)
        try await store.insertMeeting(meeting, segments: [])
        let coordinator = FailingMeetingRemoteSessionCoordinator(errorMessage: "GPU worker exhausted retries")
        let service = MeetingTranscriptionService(coordinator: coordinator, store: store)

        do {
            try await service.transcribe(
                meetingID: meeting.id,
                audioURL: URL(fileURLWithPath: "/tmp/meeting-remote-failed.wav")
            )
            XCTFail("Expected remote transcription failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GPU worker exhausted retries")
        }

        let saved = try await store.fetchMeeting(id: meeting.id)
        let segments = try await store.fetchSegments(meetingID: meeting.id)
        XCTAssertEqual(saved?.status, .failed)
        XCTAssertEqual(saved?.progress, 0)
        XCTAssertEqual(saved?.transcriptPreview, "GPU worker exhausted retries")
        XCTAssertTrue(segments.isEmpty)
    }

    @MainActor
    func testRemoteCoordinatorLogsAreScopedToMeetingContext() async throws {
        RequestLogStore.shared.clear()

        let store = try MeetingRecordStore.inMemory()
        let meeting = MeetingRecord.fixture(status: .processing)
        try await store.insertMeeting(meeting, segments: [])
        let coordinator = LoggingMeetingRemoteSessionCoordinator(result: .remoteFixture())
        let service = MeetingTranscriptionService(coordinator: coordinator, store: store)

        try await service.transcribe(
            meetingID: meeting.id,
            audioURL: URL(fileURLWithPath: "/tmp/meeting-remote-logs.wav")
        )

        let entries = RequestLogStore.shared.entries.filter { $0.kind == .asr }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.meetingID)), [meeting.id])
        XCTAssertEqual(entries.map(\.message), ["stub remote finalize", "stub remote poll"])
    }

    func testConcurrentTranscriptionsOnSharedServiceKeepMeetingResultsSeparated() async throws {
        let store = try MeetingRecordStore.inMemory()
        let meetingA = MeetingRecord.fixture(id: UUID(), title: "A", status: .processing)
        let meetingB = MeetingRecord.fixture(id: UUID(), title: "B", status: .processing)
        try await store.insertMeeting(meetingA, segments: [])
        try await store.insertMeeting(meetingB, segments: [])

        let runner = ConcurrentStubVibeVoiceRunnerClient()
        let service = MeetingTranscriptionService(runner: runner, store: store)

        async let transcribeA = service.transcribe(
            meetingID: meetingA.id,
            audioURL: URL(fileURLWithPath: "/tmp/meeting-a.wav")
        )
        async let transcribeB = service.transcribe(
            meetingID: meetingB.id,
            audioURL: URL(fileURLWithPath: "/tmp/meeting-b.wav")
        )
        _ = try await (transcribeA, transcribeB)

        let savedA = try await store.fetchMeeting(id: meetingA.id)
        let savedB = try await store.fetchMeeting(id: meetingB.id)
        let segmentsA = try await store.fetchSegments(meetingID: meetingA.id)
        let segmentsB = try await store.fetchSegments(meetingID: meetingB.id)

        XCTAssertEqual(savedA?.transcriptPreview, "alpha transcript")
        XCTAssertEqual(savedB?.transcriptPreview, "beta transcript")
        XCTAssertEqual(segmentsA.map(\.text), ["alpha"])
        XCTAssertEqual(segmentsB.map(\.text), ["beta"])
    }
}

private struct StubVibeVoiceRunnerClient: VibeVoiceRunning {
    let result: MeetingTranscriptionResult

    func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: (@Sendable (MeetingTranscriptionProgress) async -> Void)?
    ) async throws -> MeetingTranscriptionResult {
        result
    }
}

private struct ConcurrentStubVibeVoiceRunnerClient: VibeVoiceRunning {
    func transcribe(
        audioURL: URL,
        hotwords: [String],
        progress: (@Sendable (MeetingTranscriptionProgress) async -> Void)?
    ) async throws -> MeetingTranscriptionResult {
        if audioURL.lastPathComponent == "meeting-a.wav" {
            await progress?(.transcribing(chunkIndex: 1, totalChunks: 2, chunkStartTime: 0, chunkEndTime: 1))
            try? await Task.sleep(for: .milliseconds(30))
            return MeetingTranscriptionResult(
                fullText: "alpha transcript",
                segments: [
                    MeetingTranscriptionSegmentPayload(
                        sequence: 0,
                        speakerLabel: "Speaker 1",
                        startTime: 0,
                        endTime: 1,
                        text: "alpha"
                    )
                ]
            )
        }

        await progress?(.transcribing(chunkIndex: 2, totalChunks: 2, chunkStartTime: 1, chunkEndTime: 2))
        try? await Task.sleep(for: .milliseconds(10))
        return MeetingTranscriptionResult(
            fullText: "beta transcript",
            segments: [
                MeetingTranscriptionSegmentPayload(
                    sequence: 0,
                    speakerLabel: "Speaker 2",
                    startTime: 0,
                    endTime: 1,
                    text: "beta"
                )
            ]
        )
    }
}

private final class StubMeetingRemoteSessionCoordinator: MeetingRemoteSessionCoordinating {
    let result: RemoteMeetingTranscriptResult
    private(set) var finalizeCalls: [(fullAudioURL: URL, expectedChunkCount: Int)] = []
    private(set) var pollCalls = 0

    init(result: RemoteMeetingTranscriptResult) {
        self.result = result
    }

    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async {}

    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws {
        finalizeCalls.append((fullAudioURL, expectedChunkCount))
    }

    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult {
        pollCalls += 1
        return result
    }
}

private final class FailingMeetingRemoteSessionCoordinator: MeetingRemoteSessionCoordinating {
    let errorMessage: String

    init(errorMessage: String) {
        self.errorMessage = errorMessage
    }

    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async {}

    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws {}

    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult {
        throw MeetingRemoteSessionCoordinatorError.sessionFailed(errorMessage)
    }
}

private final class LoggingMeetingRemoteSessionCoordinator: MeetingRemoteSessionCoordinating {
    let result: RemoteMeetingTranscriptResult

    init(result: RemoteMeetingTranscriptResult) {
        self.result = result
    }

    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async {}

    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws {
        RequestLogStore.log(.asr, "stub remote finalize")
    }

    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult {
        RequestLogStore.log(.asr, "stub remote poll")
        return result
    }
}

private extension MeetingTranscriptionResult {
    static func fixture() -> MeetingTranscriptionResult {
        MeetingTranscriptionResult(
            fullText: "hello world",
            segments: [
                MeetingTranscriptionSegmentPayload(
                    sequence: 0,
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: 1,
                    text: "hello"
                ),
                MeetingTranscriptionSegmentPayload(
                    sequence: 1,
                    speakerLabel: "Speaker 2",
                    startTime: 1,
                    endTime: 2,
                    text: "world"
                ),
            ]
        )
    }
}

private extension RemoteMeetingTranscriptResult {
    static func remoteFixture() -> RemoteMeetingTranscriptResult {
        .init(
            fullText: "hello world",
            segments: [
                .init(sequence: 0, speakerLabel: "Speaker 1", startMS: 0, endMS: 1_000, text: "hello"),
                .init(sequence: 1, speakerLabel: "Speaker 2", startMS: 1_000, endMS: 2_000, text: "world"),
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
        progress: Float = 0
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            createdAt: createdAt,
            title: title,
            audioFileName: audioFileName,
            transcriptPreview: transcriptPreview,
            duration: duration,
            status: status,
            progress: progress
        )
    }
}
