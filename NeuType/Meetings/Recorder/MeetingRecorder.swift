import Foundation

protocol MeetingRecording: AnyObject {
    func startRecording() async throws
    func stopRecording() async throws -> URL?
    func cancelRecording()
}

final class MeetingRecorder: MeetingRecording {
    func startRecording() async throws {
    }

    func stopRecording() async throws -> URL? {
        nil
    }

    func cancelRecording() {
    }
}
