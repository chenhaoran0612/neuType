import AVFoundation
import Foundation

@MainActor
final class MeetingPlaybackCoordinator: NSObject, ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var activeSegmentSequence: Int?
    @Published private(set) var isPlaying = false

    let audioURL: URL

    private var audioPlayer: AVAudioPlayer?

    init(audioURL: URL) {
        self.audioURL = audioURL
    }

    func play() {
        if audioPlayer == nil {
            audioPlayer = try? AVAudioPlayer(contentsOf: audioURL)
        }
        audioPlayer?.play()
        isPlaying = audioPlayer?.isPlaying ?? false
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        audioPlayer?.currentTime = time
    }

    func updateCurrentTime(_ time: TimeInterval, segments: [MeetingTranscriptSegment]) {
        currentTime = time
        activeSegmentSequence = segments.first(where: { segment in
            segment.startTime <= time && time < segment.endTime
        })?.sequence
    }
}
