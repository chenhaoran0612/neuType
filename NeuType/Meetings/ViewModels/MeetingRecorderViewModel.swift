import AVFoundation
import AppKit
import Foundation

protocol MeetingPermissionChecking {
    var isMicrophonePermissionGranted: Bool { get }
    var isScreenRecordingPermissionGranted: Bool { get }
    func requestMicrophonePermissionOrOpenSystemPreferences()
    func requestScreenRecordingPermissionOrOpenSystemPreferences()
}

extension PermissionsManager: MeetingPermissionChecking {}

protocol MeetingAppControlling {
    func relaunch()
}

struct MeetingAppController: MeetingAppControlling {
    func relaunch() {
        let applicationURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class MeetingRecorderViewModel: ObservableObject {
    @Published private(set) var state: MeetingRecorderState = .idle
    @Published private(set) var hasReachedRecordingLimit = false

    private let permissions: MeetingPermissionChecking
    private let recorder: MeetingRecording
    private let store: MeetingRecordStore
    private let transcriptionService: MeetingTranscribing
    private let appController: MeetingAppControlling
    private var recordingLimitTask: Task<Void, Never>?

    static let maximumRecordingDuration: TimeInterval = 3600

    init(
        permissions: MeetingPermissionChecking = PermissionsManager(),
        recorder: MeetingRecording = MeetingRecorder(),
        store: MeetingRecordStore = .shared,
        transcriptionService: MeetingTranscribing = MeetingTranscriptionService(),
        appController: MeetingAppControlling = MeetingAppController()
    ) {
        self.permissions = permissions
        self.recorder = recorder
        self.store = store
        self.transcriptionService = transcriptionService
        self.appController = appController
    }

    func startRecording() async {
        MeetingLog.info("RecorderViewModel startRecording micGranted=\(permissions.isMicrophonePermissionGranted) screenGranted=\(permissions.isScreenRecordingPermissionGranted)")
        guard permissions.isMicrophonePermissionGranted else {
            permissions.requestMicrophonePermissionOrOpenSystemPreferences()
            state = .permissionBlocked(.microphone)
            return
        }

        guard permissions.isScreenRecordingPermissionGranted else {
            permissions.requestScreenRecordingPermissionOrOpenSystemPreferences()
            state = .permissionBlocked(.screenRecording)
            return
        }

        do {
            try await recorder.startRecording()
            hasReachedRecordingLimit = false
            startRecordingLimitMonitor()
            state = .recording
        } catch {
            MeetingLog.error("startRecording failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        MeetingLog.info("RecorderViewModel stopRecording")
        do {
            invalidateRecordingLimitMonitor()
            state = .processing
            guard let audioURL = try await recorder.stopRecording() else {
                state = .failed("Meeting recording did not produce an audio file.")
                return
            }

            let meetingID = UUID()
            let createdAt = Date()
            let duration = Self.duration(of: audioURL)
            let meeting = MeetingRecord(
                id: meetingID,
                createdAt: createdAt,
                title: Self.defaultTitle(for: createdAt),
                audioFileName: audioURL.lastPathComponent,
                transcriptPreview: "",
                duration: duration,
                status: .processing,
                progress: 0
            )
            try await store.insertMeeting(meeting, segments: [])
            try await transcriptionService.transcribe(meetingID: meetingID, audioURL: audioURL)
            state = .completed(meetingID)
        } catch {
            MeetingLog.error("stopRecording failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func handleShortcut() async {
        switch state {
        case .recording:
            await stopRecording()
        case .processing:
            break
        default:
            await startRecording()
        }
    }

    func cancelRecording() {
        MeetingLog.info("RecorderViewModel cancelRecording")
        invalidateRecordingLimitMonitor()
        hasReachedRecordingLimit = false
        recorder.cancelRecording()
        state = .idle
    }

    func requestPermission(for permission: MeetingPermissionKind) {
        switch permission {
        case .microphone:
            permissions.requestMicrophonePermissionOrOpenSystemPreferences()
        case .screenRecording:
            permissions.requestScreenRecordingPermissionOrOpenSystemPreferences()
        }
    }

    func relaunchApplication() {
        appController.relaunch()
    }

    func handleRecordingElapsedTime(_ elapsedTime: TimeInterval) {
        guard state == .recording else { return }
        guard elapsedTime >= Self.maximumRecordingDuration else { return }
        guard !hasReachedRecordingLimit else { return }

        hasReachedRecordingLimit = true
        invalidateRecordingLimitMonitor()
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func duration(of audioURL: URL) -> TimeInterval {
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            return 0
        }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    private func startRecordingLimitMonitor() {
        invalidateRecordingLimitMonitor()

        recordingLimitTask = Task { @MainActor [weak self] in
            let startedAt = Date()
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.handleRecordingElapsedTime(Date().timeIntervalSince(startedAt))
            }
        }
    }

    private func invalidateRecordingLimitMonitor() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
    }
}
