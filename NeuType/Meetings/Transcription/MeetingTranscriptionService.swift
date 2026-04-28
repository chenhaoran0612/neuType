import Foundation

protocol MeetingTranscribing: Sendable {
    func transcribe(meetingID: UUID, audioURL: URL) async throws
}

protocol MeetingTranscriptTranslationRefreshing: Sendable {
    func refreshCompletedTranslationsIfNeeded(
        meetingID: UUID,
        existingSegments: [MeetingTranscriptSegment]
    ) async throws -> Bool
}

final class MeetingTranscriptionService: MeetingTranscribing, Sendable {
    private enum Backend: Sendable {
        case local(any VibeVoiceRunning)
        case remote(@Sendable (UUID) -> any MeetingRemoteSessionCoordinating)
    }

    private let backend: Backend
    private let store: MeetingRecordStore

    init(
        remoteClient: MeetingRemoteTranscriptionServing = MeetingRemoteTranscriptionClient(),
        store: MeetingRecordStore = .shared
    ) {
        self.backend = .remote { meetingID in
            let ledger: MeetingUploadLedger
            do {
                ledger = try MeetingUploadLedger.persisted(
                    fileURL: Self.remoteLedgerURL(meetingID: meetingID),
                    clientSessionToken: meetingID.uuidString,
                    meetingRecordID: meetingID
                )
            } catch {
                MeetingLog.error("Meeting remote upload ledger load failed meetingID=\(meetingID) error=\(error.localizedDescription)")
                ledger = MeetingUploadLedger.inMemory(clientSessionToken: meetingID.uuidString, meetingRecordID: meetingID)
            }
            return MeetingRemoteSessionCoordinator(client: remoteClient, ledger: ledger)
        }
        self.store = store
    }

    init(
        runner: VibeVoiceRunning,
        store: MeetingRecordStore = .shared
    ) {
        self.backend = .local(runner)
        self.store = store
    }

    init(
        coordinator: some MeetingRemoteSessionCoordinating,
        store: MeetingRecordStore = .shared
    ) {
        self.backend = .remote { _ in coordinator }
        self.store = store
    }

    func transcribe(meetingID: UUID, audioURL: URL) async throws {
        do {
            switch backend {
            case .local(let runner):
                try await transcribeLocally(meetingID: meetingID, audioURL: audioURL, runner: runner)
            case .remote(let makeCoordinator):
                try await transcribeRemotely(meetingID: meetingID, audioURL: audioURL, coordinator: makeCoordinator(meetingID))
            }
        } catch {
            try? await store.updateMeetingStatus(
                meetingID: meetingID,
                status: .failed,
                progress: 0,
                transcriptPreview: error.localizedDescription
            )
            throw error
        }
    }

    private func transcribeLocally(
        meetingID: UUID,
        audioURL: URL,
        runner: any VibeVoiceRunning
    ) async throws {
        let result = try await RequestLogContext.$meetingID.withValue(meetingID) {
            try await runner.transcribe(audioURL: audioURL, hotwords: []) { [store] progress in
                try? await store.updateMeetingStatus(
                    meetingID: meetingID,
                    status: .processing,
                    progress: progress.fractionCompleted,
                    transcriptPreview: progress.message
                )
            }
        }
        try await store.updateTranscription(
            meetingID: meetingID,
            fullText: result.fullText,
            segments: result.segments
        )
    }

    private func transcribeRemotely(
        meetingID: UUID,
        audioURL: URL,
        coordinator: any MeetingRemoteSessionCoordinating
    ) async throws {
        try await RequestLogContext.$meetingID.withValue(meetingID) {
            try await store.updateMeetingStatus(
                meetingID: meetingID,
                status: .processing,
                progress: 0.1,
                transcriptPreview: MeetingTranscriptionProgress.uploadingAudio(chunkIndex: 1, totalChunks: 1).message
            )
            try await coordinator.finalizeWithRecording(fullAudioURL: audioURL, expectedChunkCount: 0)

            try await store.updateMeetingStatus(
                meetingID: meetingID,
                status: .processing,
                progress: 0.5,
                transcriptPreview: MeetingTranscriptionProgress.finalizing().message
            )

            let result = try await coordinator.pollUntilCompleted()
            let segments = result.segments.map {
                MeetingTranscriptionSegmentPayload(
                    sequence: $0.sequence,
                    speakerLabel: $0.speakerLabel ?? "Unknown Speaker",
                    startTime: TimeInterval($0.startMS) / 1_000,
                    endTime: TimeInterval($0.endMS) / 1_000,
                    text: $0.text,
                    textEN: $0.translations?.en ?? "",
                    textZH: $0.translations?.zh ?? "",
                    textAR: $0.translations?.ar ?? ""
                )
            }
            try await store.updateTranscription(
                meetingID: meetingID,
                fullText: result.fullText,
                segments: segments
            )
        }
    }

    private static func remoteLedgerURL(meetingID: UUID) -> URL {
        MeetingRecord.meetingsDirectory
            .appendingPathComponent("remote-session-ledgers", isDirectory: true)
            .appendingPathComponent("\(meetingID.uuidString).json")
    }
}

final class MeetingRemoteTranscriptTranslationRefresher: MeetingTranscriptTranslationRefreshing, Sendable {
    private let client: MeetingRemoteTranscriptionServing
    private let store: MeetingRecordStore
    private let ledgerURL: @Sendable (UUID) -> URL

    init(
        client: MeetingRemoteTranscriptionServing = MeetingRemoteTranscriptionClient(),
        store: MeetingRecordStore = .shared,
        ledgerURL: @escaping @Sendable (UUID) -> URL = MeetingRemoteTranscriptTranslationRefresher.defaultLedgerURL
    ) {
        self.client = client
        self.store = store
        self.ledgerURL = ledgerURL
    }

    func refreshCompletedTranslationsIfNeeded(
        meetingID: UUID,
        existingSegments: [MeetingTranscriptSegment]
    ) async throws -> Bool {
        guard existingSegments.contains(where: { !$0.hasCompleteTranslations }) else {
            return false
        }

        let ledgerFileURL = ledgerURL(meetingID)
        guard FileManager.default.fileExists(atPath: ledgerFileURL.path) else {
            return false
        }

        let ledger = try MeetingUploadLedger.persisted(
            fileURL: ledgerFileURL,
            clientSessionToken: meetingID.uuidString,
            meetingRecordID: meetingID
        )
        guard let sessionID = ledger.snapshot.remoteSessionID,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let status = try await client.getSessionStatus(sessionID: sessionID)
        guard status.status.caseInsensitiveCompare("completed") == .orderedSame,
              let result = status.transcriptResult else {
            return false
        }

        let segments = result.segments.map {
            MeetingTranscriptionSegmentPayload(
                sequence: $0.sequence,
                speakerLabel: $0.speakerLabel ?? "Unknown Speaker",
                startTime: TimeInterval($0.startMS) / 1_000,
                endTime: TimeInterval($0.endMS) / 1_000,
                text: $0.text,
                textEN: $0.translations?.en ?? "",
                textZH: $0.translations?.zh ?? "",
                textAR: $0.translations?.ar ?? ""
            )
        }
        guard segments.contains(where: { !$0.textEN.isEmpty || !$0.textZH.isEmpty || !$0.textAR.isEmpty }) else {
            return false
        }

        try await store.updateTranscription(
            meetingID: meetingID,
            fullText: result.fullText,
            segments: segments
        )
        return true
    }

    private static func defaultLedgerURL(meetingID: UUID) -> URL {
        MeetingRecord.meetingsDirectory
            .appendingPathComponent("remote-session-ledgers", isDirectory: true)
            .appendingPathComponent("\(meetingID.uuidString).json")
    }
}
