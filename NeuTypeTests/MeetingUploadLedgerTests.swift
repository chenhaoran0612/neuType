import Foundation
import XCTest
@testable import NeuType

final class MeetingUploadLedgerTests: XCTestCase {
    func testLedgerMarksChunkFailureAndRequiresFallback() throws {
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        try ledger.recordChunk(.init(index: 0, startMS: 0, endMS: 300_000, sha256: "a", localFilePath: "/tmp/0.wav"))
        try ledger.markChunkUploadFailed(index: 0)

        XCTAssertTrue(ledger.requiresFullAudioFallback)
    }

    func testLedgerRequiresFallbackWhenExpectedChunkIndexesCannotBeProvenUploaded() throws {
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_123")
        try ledger.recordChunk(.init(index: 0, startMS: 0, endMS: 300_000, sha256: "a", localFilePath: "/tmp/0.wav"))
        try ledger.recordChunk(.init(index: 2, startMS: 600_000, endMS: 900_000, sha256: "c", localFilePath: "/tmp/2.wav"))
        try ledger.markChunkUploaded(index: 0)
        try ledger.markChunkUploaded(index: 2)

        XCTAssertTrue(ledger.requiresFullAudioFallback(expectedChunkCount: 2))
    }

    func testPersistedLedgerRoundTripsSessionState() throws {
        let fileURL = temporaryLedgerFileURL()
        let ledger = try MeetingUploadLedger.persisted(
            fileURL: fileURL,
            clientSessionToken: "client_456",
            meetingRecordID: UUID(uuidString: "00000000-0000-0000-0000-000000000456")
        )
        try ledger.updateRemoteSessionID("mts_456")
        try ledger.updateFullAudioLocalPath("/tmp/meeting.wav")
        try ledger.recordChunk(.init(index: 1, startMS: 10, endMS: 20, sha256: "hash", localFilePath: "/tmp/1.wav"))
        try ledger.markChunkUploaded(index: 1)
        try ledger.setSelectedStrategy(.fullAudioFallback)
        try ledger.markFinalizeRequested()

        let reloaded = try MeetingUploadLedger.persisted(fileURL: fileURL, clientSessionToken: "ignored")
        let snapshot = reloaded.snapshot

        XCTAssertEqual(snapshot.remoteSessionID, "mts_456")
        XCTAssertEqual(snapshot.clientSessionToken, "client_456")
        XCTAssertEqual(snapshot.meetingRecordID, "00000000-0000-0000-0000-000000000456")
        XCTAssertEqual(snapshot.fullAudioLocalPath, "/tmp/meeting.wav")
        XCTAssertEqual(snapshot.chunks, [
            MeetingUploadChunkRecord(
                index: 1,
                startMS: 10,
                endMS: 20,
                sha256: "hash",
                localFilePath: "/tmp/1.wav",
                uploadStatus: .uploaded
            ),
        ])
        XCTAssertEqual(snapshot.selectedStrategy, .fullAudioFallback)
        XCTAssertTrue(snapshot.finalizeRequested)
    }

    func testPersistedLedgerUsesSnakeCaseKeys() throws {
        let fileURL = temporaryLedgerFileURL()
        let ledger = try MeetingUploadLedger.persisted(fileURL: fileURL, clientSessionToken: "client_snake")
        try ledger.recordChunk(.init(index: 0, startMS: 0, endMS: 10, sha256: "a", localFilePath: "/tmp/0.wav"))
        try ledger.markChunkUploaded(index: 0)
        try ledger.updateRemoteSessionID("mts_snake")
        try ledger.updateFullAudioLocalPath("/tmp/meeting.wav")
        try ledger.setSelectedStrategy(.fullAudioFallback)
        try ledger.markFinalizeRequested()

        let contents = try String(contentsOf: fileURL)
        XCTAssertTrue(contents.contains("\"remote_session_id\""))
        XCTAssertTrue(contents.contains("\"client_session_token\""))
        XCTAssertTrue(contents.contains("\"full_audio_local_path\""))
        XCTAssertTrue(contents.contains("\"finalize_requested\""))
        XCTAssertTrue(contents.contains("\"selected_strategy\""))
        XCTAssertTrue(contents.contains("\"start_ms\""))
        XCTAssertTrue(contents.contains("\"local_file_path\""))
        XCTAssertTrue(contents.contains("\"upload_status\""))
    }

    func testLedgerRequiresFallbackWhenUploadedIndexesDoNotMatchExpectedRange() throws {
        let ledger = MeetingUploadLedger.inMemory(clientSessionToken: "client_gap")
        try ledger.recordChunk(.init(index: 0, startMS: 0, endMS: 10, sha256: "a", localFilePath: "/tmp/0.wav"))
        try ledger.recordChunk(.init(index: 2, startMS: 20, endMS: 30, sha256: "c", localFilePath: "/tmp/2.wav"))
        try ledger.markChunkUploaded(index: 0)
        try ledger.markChunkUploaded(index: 2)

        XCTAssertTrue(ledger.requiresFullAudioFallback(expectedChunkCount: 2))
    }

    func testResetForRetryClearsRemoteSessionStateAndPersistsNewToken() throws {
        let fileURL = temporaryLedgerFileURL()
        let ledger = try MeetingUploadLedger.persisted(
            fileURL: fileURL,
            clientSessionToken: "client_original",
            meetingRecordID: UUID(uuidString: "00000000-0000-0000-0000-000000000789")
        )
        try ledger.updateRemoteSessionID("mts_failed")
        try ledger.updateFullAudioLocalPath("/tmp/meeting.wav")
        try ledger.recordChunk(.init(index: 1, startMS: 10, endMS: 20, sha256: "hash", localFilePath: "/tmp/1.wav"))
        try ledger.markChunkUploaded(index: 1)
        try ledger.setSelectedStrategy(.fullAudioFallback)
        try ledger.markFinalizeRequested()

        try ledger.resetForRetry(clientSessionToken: "client_retry")

        let reloaded = try MeetingUploadLedger.persisted(fileURL: fileURL, clientSessionToken: "ignored")
        let snapshot = reloaded.snapshot

        XCTAssertNil(snapshot.remoteSessionID)
        XCTAssertEqual(snapshot.clientSessionToken, "client_retry")
        XCTAssertEqual(snapshot.meetingRecordID, "00000000-0000-0000-0000-000000000789")
        XCTAssertNil(snapshot.fullAudioLocalPath)
        XCTAssertTrue(snapshot.chunks.isEmpty)
        XCTAssertFalse(snapshot.finalizeRequested)
        XCTAssertNil(snapshot.selectedStrategy)
    }

    private func temporaryLedgerFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }
}
