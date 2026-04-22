import Foundation

typealias MeetingRecordingArtifactHandler = @Sendable (MeetingRecordingArtifact) async -> Void

struct MeetingRecordingChunkArtifact: Equatable, Sendable {
    let chunkIndex: Int
    let startMS: Int
    let endMS: Int
    let fileURL: URL
}

struct MeetingRecordingFinalAudioArtifact: Equatable, Sendable {
    let fileURL: URL
    let durationMS: Int
}

enum MeetingRecordingArtifact: Equatable, Sendable {
    case sealedChunk(MeetingRecordingChunkArtifact)
    case finalAudio(MeetingRecordingFinalAudioArtifact)
}

protocol MeetingRecordingArtifactProducing: AnyObject {
    var artifactHandler: MeetingRecordingArtifactHandler? { get set }
}
