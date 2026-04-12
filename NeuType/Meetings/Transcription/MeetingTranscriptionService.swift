import Foundation

protocol MeetingTranscribing {
    func transcribe(meetingID: UUID, audioURL: URL) async throws
}

final class MeetingTranscriptionService: MeetingTranscribing {
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
        let result = try await runner.transcribe(audioURL: audioURL, hotwords: [])
        try await store.updateTranscription(
            meetingID: meetingID,
            fullText: result.fullText,
            segments: result.segments
        )
    }
}
