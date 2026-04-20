import Foundation

protocol MeetingTranscribing: Sendable {
    func transcribe(meetingID: UUID, audioURL: URL) async throws
}

final class MeetingTranscriptionService: MeetingTranscribing, Sendable {
    private let runner: VibeVoiceRunning
    private let store: MeetingRecordStore

    init(
        runner: VibeVoiceRunning = VibeVoiceRunnerClient(),
        store: MeetingRecordStore = .shared
    ) {
        self.runner = runner
        self.store = store
    }

    func transcribe(meetingID: UUID, audioURL: URL) async throws {
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
}
