import AVFoundation
import Foundation

@MainActor
final class MeetingPlaybackCoordinator: NSObject, ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var activeSegmentSequence: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0

    let audioURL: URL

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var segments: [MeetingTranscriptSegment] = []

    init(audioURL: URL) {
        self.audioURL = audioURL
        super.init()
        preparePlayerIfNeeded()
    }

    func play() {
        preparePlayerIfNeeded()
        audioPlayer?.play()
        isPlaying = audioPlayer?.isPlaying ?? false
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func seek(to time: TimeInterval) {
        preparePlayerIfNeeded()
        let clampedTime = min(max(time, 0), duration)
        currentTime = clampedTime
        audioPlayer?.currentTime = clampedTime
        updateActiveSegment(for: clampedTime)
    }

    func updateCurrentTime(_ time: TimeInterval, segments: [MeetingTranscriptSegment]) {
        self.segments = segments
        currentTime = time
        updateActiveSegment(for: time)
    }

    func setSegments(_ segments: [MeetingTranscriptSegment]) {
        self.segments = segments
        updateActiveSegment(for: currentTime)
    }

    private func preparePlayerIfNeeded() {
        guard audioPlayer == nil else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: audioURL)
        audioPlayer?.prepareToPlay()
        duration = audioPlayer?.duration ?? 0
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                self.updateActiveSegment(for: player.currentTime)
                if !player.isPlaying {
                    if player.currentTime >= player.duration {
                        self.currentTime = player.duration
                    }
                    self.isPlaying = false
                    self.stopProgressTimer()
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateActiveSegment(for time: TimeInterval) {
        activeSegmentSequence = segments.first(where: { segment in
            segment.startTime <= time && time < segment.endTime
        })?.sequence
    }
}
