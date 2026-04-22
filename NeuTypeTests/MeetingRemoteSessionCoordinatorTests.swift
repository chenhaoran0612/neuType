import Foundation
import XCTest
@testable import NeuType

final class MeetingRemoteSessionCoordinatorTests: XCTestCase {
    func testCoordinatorUploadsFallbackWhenChunksAreMissing() async throws {
        let client = StubMeetingRemoteTranscriptionClient()
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        try ledger.recordChunk(.fixture(index: 0))
        try ledger.markChunkUploadFailed(index: 0)

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 1
        )

        XCTAssertEqual(client.createSessionCalls, 1)
        XCTAssertEqual(client.uploadFullAudioCalls, 1)
        XCTAssertEqual(client.finalizeCalls.count, 1)
        XCTAssertEqual(client.finalizeCalls.first?.preferredInputMode, "full_audio_fallback")
    }

    func testCoordinatorUploadsFallbackWhenNoChunksExist() async throws {
        let client = StubMeetingRemoteTranscriptionClient()
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_empty")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 0
        )

        XCTAssertEqual(client.uploadFullAudioCalls, 1)
        XCTAssertEqual(client.finalizeCalls.first?.preferredInputMode, "full_audio_fallback")
    }

    func testHandleSealedChunkUploadsChunkAndMarksLedgerUploaded() async throws {
        let client = StubMeetingRemoteTranscriptionClient()
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })
        let chunkURL = makeTemporaryAudioURL(named: "chunk.wav", contents: Data("chunk".utf8))

        await coordinator.handleSealedChunk(.fixture(index: 2, fileURL: chunkURL))

        XCTAssertEqual(client.createSessionCalls, 1)
        XCTAssertEqual(client.uploadChunkCalls.count, 1)
        XCTAssertEqual(client.uploadChunkCalls.first?.chunkIndex, 2)
        XCTAssertEqual(ledger.snapshot.chunks.first?.uploadStatus, .uploaded)
        XCTAssertEqual(ledger.snapshot.remoteSessionID, "mts_created")
    }

    func testHandleSealedChunkMarksNonUploadedResponseAsFailed() async throws {
        let client = StubMeetingRemoteTranscriptionClient(chunkUploadStatus: "failed_conflict")
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })
        let chunkURL = makeTemporaryAudioURL(named: "chunk.wav", contents: Data("chunk".utf8))

        await coordinator.handleSealedChunk(.fixture(index: 3, fileURL: chunkURL))

        XCTAssertEqual(ledger.snapshot.chunks.first?.uploadStatus, .failedConflict)
        XCTAssertTrue(ledger.requiresFullAudioFallback)
    }

    func testConcurrentChunkUploadsShareOneCreatedSession() async throws {
        let client = StubMeetingRemoteTranscriptionClient(
            createdSessionID: "mts_shared",
            createSessionDelayNS: 50_000_000
        )
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_concurrent")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        async let first: Void = coordinator.handleSealedChunk(
            .fixture(index: 0, fileURL: makeTemporaryAudioURL(named: "chunk-0.wav", contents: Data("0".utf8)))
        )
        async let second: Void = coordinator.handleSealedChunk(
            .fixture(index: 1, fileURL: makeTemporaryAudioURL(named: "chunk-1.wav", contents: Data("1".utf8)))
        )
        async let third: Void = coordinator.handleSealedChunk(
            .fixture(index: 2, fileURL: makeTemporaryAudioURL(named: "chunk-2.wav", contents: Data("2".utf8)))
        )
        _ = await (first, second, third)

        XCTAssertEqual(client.createSessionCalls, 1)
        XCTAssertEqual(Set(client.uploadChunkCalls.map(\.sessionID)), ["mts_shared"])
        XCTAssertEqual(ledger.snapshot.remoteSessionID, "mts_shared")
    }

    func testFinalizeChecksRemoteStatusBeforeSkippingAfterRestartRecovery() async throws {
        let client = StubMeetingRemoteTranscriptionClient()
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123", remoteSessionID: "mts_existing")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })
        try ledger.markFinalizeRequested()
        client.queuedStatuses = [.processing(sessionID: "mts_existing")]

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 0
        )

        XCTAssertEqual(client.statusPollCount, 1)
        XCTAssertEqual(client.createSessionCalls, 0)
        XCTAssertEqual(client.uploadFullAudioCalls, 0)
        XCTAssertTrue(client.finalizeCalls.isEmpty)
    }

    func testFinalizeCreatesFreshSessionWhenRecoveredSessionAlreadyFailed() async throws {
        let client = StubMeetingRemoteTranscriptionClient(
            createdSessionID: "mts_retry",
            statusResponses: [
                .failed(sessionID: "mts_failed", errorMessage: "fallback wav materialization failed"),
            ]
        )
        let ledger = MeetingUploadLedger.inMemory(
            clientSessionToken: "client_original",
            remoteSessionID: "mts_failed",
            meetingRecordID: UUID(uuidString: "00000000-0000-0000-0000-000000000321")
        )
        try ledger.recordChunk(.fixture(index: 0))
        try ledger.markChunkUploaded(index: 0)
        try ledger.setSelectedStrategy(.liveChunks)
        try ledger.markFinalizeRequested()

        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 0
        )

        XCTAssertEqual(client.statusPollCount, 1)
        XCTAssertEqual(client.createSessionCalls, 1)
        XCTAssertEqual(client.uploadFullAudioCalls, 1)
        XCTAssertEqual(client.finalizeCalls.count, 1)
        XCTAssertEqual(client.finalizeCalls.first?.preferredInputMode, "full_audio_fallback")
        XCTAssertEqual(client.createSessionRequests.first?.clientSessionToken.hasPrefix("00000000-0000-0000-0000-000000000321-retry-"), true)
        XCTAssertEqual(ledger.snapshot.remoteSessionID, "mts_retry")
        XCTAssertTrue(ledger.snapshot.chunks.isEmpty)
        XCTAssertTrue(ledger.snapshot.finalizeRequested)
    }

    func testFinalizeCreatesFreshSessionWhenRecoveredSessionIsMissing() async throws {
        let client = StubMeetingRemoteTranscriptionClient(
            createdSessionID: "mts_retry",
            statusError: MeetingRemoteTranscriptionClientError.apiError(
                statusCode: 404,
                requestID: "req_missing",
                code: "session_not_found",
                message: "session does not exist"
            )
        )
        let ledger = MeetingUploadLedger.inMemory(
            clientSessionToken: "client_original",
            remoteSessionID: "mts_missing",
            meetingRecordID: UUID(uuidString: "00000000-0000-0000-0000-000000000654")
        )
        try ledger.markFinalizeRequested()

        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 0
        )

        XCTAssertEqual(client.statusPollCount, 1)
        XCTAssertEqual(client.createSessionCalls, 1)
        XCTAssertEqual(client.createSessionRequests.first?.clientSessionToken.hasPrefix("00000000-0000-0000-0000-000000000654-retry-"), true)
        XCTAssertEqual(ledger.snapshot.remoteSessionID, "mts_retry")
        XCTAssertTrue(ledger.snapshot.finalizeRequested)
    }

    func testFinalizeFallsBackWhenServerReportsMissingChunks() async throws {
        let client = StubMeetingRemoteTranscriptionClient(firstFinalizeMissingChunkIndexes: [0])
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_missing", remoteSessionID: "mts_missing")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })
        try ledger.recordChunk(.fixture(index: 0))
        try ledger.markChunkUploaded(index: 0)

        try await coordinator.finalizeWithRecording(
            fullAudioURL: makeTemporaryAudioURL(named: "meeting.wav", contents: Data("meeting".utf8)),
            expectedChunkCount: 1
        )

        XCTAssertEqual(client.uploadFullAudioCalls, 1)
        XCTAssertEqual(client.finalizeCalls.count, 2)
        XCTAssertEqual(client.finalizeCalls[0].preferredInputMode, "live_chunks")
        XCTAssertEqual(client.finalizeCalls[1].preferredInputMode, "full_audio_fallback")
        XCTAssertEqual(ledger.snapshot.selectedStrategy, .fullAudioFallback)
    }

    func testPollUntilCompletedReturnsTranscriptResult() async throws {
        let client = StubMeetingRemoteTranscriptionClient(
            statusResponses: [
                .processing(sessionID: "mts_done"),
                .completed(sessionID: "mts_done", fullText: "hello world"),
            ]
        )
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        try ledger.updateRemoteSessionID("mts_done")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        let result = try await coordinator.pollUntilCompleted()

        XCTAssertEqual(result.fullText, "hello world")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.speakerLabel, "Speaker 1")
        XCTAssertEqual(client.statusPollCount, 2)
    }

    func testPollUntilCompletedThrowsReadableErrorWhenSessionFails() async throws {
        let client = StubMeetingRemoteTranscriptionClient(
            statusResponses: [
                .failed(sessionID: "mts_failed", errorMessage: "GPU worker exhausted retries"),
            ]
        )
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        try ledger.updateRemoteSessionID("mts_failed")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        do {
            _ = try await coordinator.pollUntilCompleted()
            XCTFail("Expected failed session error")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "GPU worker exhausted retries"
            )
        }
    }

    @MainActor
    func testPollUntilCompletedLogsServerChunkResults() async throws {
        RequestLogStore.shared.clear()

        let client = StubMeetingRemoteTranscriptionClient(
            statusResponses: [
                .processing(
                    sessionID: "mts_chunks",
                    chunks: [
                        .init(
                            chunkIndex: 0,
                            sourceType: "server_split_from_full_audio",
                            startMS: 0,
                            endMS: 300_000,
                            uploadStatus: "uploaded",
                            processStatus: "processing",
                            retryCount: 0,
                            resultSegmentCount: nil,
                            errorMessage: nil
                        ),
                    ]
                ),
                .completed(
                    sessionID: "mts_chunks",
                    fullText: "hello world",
                    chunks: [
                        .init(
                            chunkIndex: 0,
                            sourceType: "server_split_from_full_audio",
                            startMS: 0,
                            endMS: 300_000,
                            uploadStatus: "uploaded",
                            processStatus: "completed",
                            retryCount: 1,
                            resultSegmentCount: 2,
                            errorMessage: nil
                        ),
                    ]
                ),
            ]
        )
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        try ledger.updateRemoteSessionID("mts_chunks")
        let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger, pollInterval: { _ in 0 })

        _ = try await coordinator.pollUntilCompleted()

        let messages = RequestLogStore.shared.entries.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("服务端会话 mts_chunks -> processing") })
        XCTAssertTrue(messages.contains { $0.contains("服务端 chunk #0 [server_split_from_full_audio] -> processing") })
        XCTAssertTrue(messages.contains { $0.contains("服务端 chunk #0 [server_split_from_full_audio] -> completed") })
        XCTAssertTrue(messages.contains { $0.contains("segments=2") })
    }

    private func makeTemporaryAudioURL(named name: String, contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? contents.write(to: url)
        return url
    }
}

private final class StubMeetingRemoteTranscriptionClient: MeetingRemoteTranscriptionServing, @unchecked Sendable {
    private let lock = NSLock()
    private let createdSessionID: String
    private let chunkUploadStatus: String
    private let createSessionDelayNS: UInt64
    private let firstFinalizeMissingChunkIndexes: [Int]
    private let statusError: Error?
    var queuedStatuses: [MeetingRemoteTranscriptionSessionStatusResponse]

    private var _createSessionCalls = 0
    private var _createSessionRequests: [CreateMeetingTranscriptionSessionRequest] = []
    private var _uploadChunkCalls: [MeetingRemoteTranscriptionChunkUploadRequest] = []
    private var _uploadFullAudioCalls = 0
    private var _finalizeCalls: [FinalizeMeetingTranscriptionSessionRequest] = []
    private var _statusPollCount = 0

    var createSessionCalls: Int { withLock { _createSessionCalls } }
    var createSessionRequests: [CreateMeetingTranscriptionSessionRequest] { withLock { _createSessionRequests } }
    var uploadChunkCalls: [MeetingRemoteTranscriptionChunkUploadRequest] { withLock { _uploadChunkCalls } }
    var uploadFullAudioCalls: Int { withLock { _uploadFullAudioCalls } }
    var finalizeCalls: [FinalizeMeetingTranscriptionSessionRequest] { withLock { _finalizeCalls } }
    var statusPollCount: Int { withLock { _statusPollCount } }

    init(
        createdSessionID: String = "mts_created",
        chunkUploadStatus: String = "uploaded",
        createSessionDelayNS: UInt64 = 0,
        firstFinalizeMissingChunkIndexes: [Int] = [],
        statusError: Error? = nil,
        statusResponses: [MeetingRemoteTranscriptionSessionStatusResponse] = []
    ) {
        self.createdSessionID = createdSessionID
        self.chunkUploadStatus = chunkUploadStatus
        self.createSessionDelayNS = createSessionDelayNS
        self.firstFinalizeMissingChunkIndexes = firstFinalizeMissingChunkIndexes
        self.statusError = statusError
        self.queuedStatuses = statusResponses
    }

    func createSession(
        _ requestPayload: CreateMeetingTranscriptionSessionRequest
    ) async throws -> CreateMeetingTranscriptionSessionResponse {
        if createSessionDelayNS > 0 {
            try await Task.sleep(nanoseconds: createSessionDelayNS)
        }
        withLock {
            _createSessionCalls += 1
            _createSessionRequests.append(requestPayload)
        }
        return .init(
            sessionID: createdSessionID,
            status: "created",
            inputMode: "live_chunks",
            chunkDurationMS: 300_000,
            chunkOverlapMS: 2_500
        )
    }

    func uploadChunk(
        _ requestPayload: MeetingRemoteTranscriptionChunkUploadRequest
    ) async throws -> MeetingRemoteTranscriptionChunkUploadResponse {
        withLock { _uploadChunkCalls.append(requestPayload) }
        return .init(
            sessionID: requestPayload.sessionID,
            chunkIndex: requestPayload.chunkIndex,
            status: "upload_received",
            uploadStatus: chunkUploadStatus,
            processStatus: "pending"
        )
    }

    func uploadFullAudio(
        _ requestPayload: MeetingRemoteTranscriptionFullAudioUploadRequest
    ) async throws -> MeetingRemoteTranscriptionFullAudioUploadResponse {
        withLock { _uploadFullAudioCalls += 1 }
        return .init(sessionID: requestPayload.sessionID, status: "full_audio_uploaded", inputMode: "full_audio_fallback")
    }

    func finalizeSession(
        sessionID: String,
        request requestPayload: FinalizeMeetingTranscriptionSessionRequest
    ) async throws -> FinalizeMeetingTranscriptionSessionResponse {
        let missingIndexes = withLock { () -> [Int] in
            _finalizeCalls.append(requestPayload)
            return _finalizeCalls.count == 1 ? firstFinalizeMissingChunkIndexes : []
        }
        return .init(
            sessionID: sessionID,
            status: "finalized",
            selectedInputMode: requestPayload.preferredInputMode,
            missingChunkIndexes: missingIndexes
        )
    }

    func getSessionStatus(sessionID: String) async throws -> MeetingRemoteTranscriptionSessionStatusResponse {
        withLock { _statusPollCount += 1 }
        if let statusError {
            throw statusError
        }
        if !queuedStatuses.isEmpty {
            return queuedStatuses.removeFirst()
        }
        return .processing(sessionID: sessionID)
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension MeetingUploadChunkRecord {
    static func fixture(index: Int) -> Self {
        .init(index: index, startMS: index * 300_000, endMS: (index + 1) * 300_000, sha256: "hash_\(index)", localFilePath: "/tmp/\(index).wav")
    }
}

private extension MeetingRecordingChunkArtifact {
    static func fixture(index: Int, fileURL: URL) -> Self {
        .init(chunkIndex: index, startMS: index * 300_000, endMS: (index + 1) * 300_000, fileURL: fileURL)
    }
}

private extension MeetingRemoteTranscriptionSessionStatusResponse {
    static func processing(
        sessionID: String,
        chunks: [MeetingRemoteTranscriptionChunkStatus] = []
    ) -> Self {
        .init(
            sessionID: sessionID,
            status: "processing",
            inputMode: "live_chunks",
            chunkDurationMS: 300_000,
            chunkOverlapMS: 2_500,
            expectedChunkCount: 1,
            uploadedChunkCount: 1,
            errorMessage: nil,
            fullText: nil,
            segments: nil,
            chunks: chunks
        )
    }

    static func completed(
        sessionID: String,
        fullText: String,
        chunks: [MeetingRemoteTranscriptionChunkStatus] = []
    ) -> Self {
        .init(
            sessionID: sessionID,
            status: "completed",
            inputMode: "live_chunks",
            chunkDurationMS: 300_000,
            chunkOverlapMS: 2_500,
            expectedChunkCount: 1,
            uploadedChunkCount: 1,
            errorMessage: nil,
            fullText: fullText,
            segments: [
                .init(sequence: 0, speakerLabel: "Speaker 1", startMS: 0, endMS: 1_000, text: "hello world"),
            ],
            chunks: chunks
        )
    }

    static func failed(sessionID: String, errorMessage: String? = nil) -> Self {
        .init(
            sessionID: sessionID,
            status: "failed",
            inputMode: "live_chunks",
            chunkDurationMS: 300_000,
            chunkOverlapMS: 2_500,
            expectedChunkCount: 1,
            uploadedChunkCount: 1,
            errorMessage: errorMessage,
            fullText: nil,
            segments: nil,
            chunks: []
        )
    }
}
