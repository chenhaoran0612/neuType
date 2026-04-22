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
        AppRelauncher.relaunch(reason: "meeting recorder")
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
    private let summaryService: MeetingSummarizing
    private let appController: MeetingAppControlling
    private let remoteCoordinatorFactory: ((UUID) -> any MeetingRemoteSessionCoordinating)?
    private var activeRecordingSession: ActiveRecordingSession?

    private struct ActiveRecordingSession {
        let meetingID: UUID
        let remoteCoordinator: (any MeetingRemoteSessionCoordinating)?
        var sealedChunkCount: Int = 0
    }

    nonisolated private static func makeDefaultRemoteCoordinator(
        meetingID: UUID
    ) -> any MeetingRemoteSessionCoordinating {
        let ledger: MeetingUploadLedger
        do {
            ledger = try MeetingUploadLedger.persisted(
                fileURL: remoteLedgerURL(meetingID: meetingID),
                clientSessionToken: meetingID.uuidString,
                meetingRecordID: meetingID
            )
        } catch {
            MeetingLog.error("Meeting remote upload ledger load failed meetingID=\(meetingID) error=\(error.localizedDescription)")
            ledger = MeetingUploadLedger.inMemory(clientSessionToken: meetingID.uuidString, meetingRecordID: meetingID)
        }
        return MeetingRemoteSessionCoordinator(ledger: ledger)
    }

    init(
        permissions: MeetingPermissionChecking = PermissionsManager(),
        recorder: MeetingRecording = MeetingRecorder(),
        store: MeetingRecordStore = .shared,
        transcriptionService: MeetingTranscribing = MeetingTranscriptionService(),
        summaryService: MeetingSummarizing = MeetingSummaryService(),
        appController: MeetingAppControlling = MeetingAppController(),
        remoteCoordinatorFactory: ((UUID) -> any MeetingRemoteSessionCoordinating)? = MeetingRecorderViewModel.makeDefaultRemoteCoordinator
    ) {
        self.permissions = permissions
        self.recorder = recorder
        self.store = store
        self.transcriptionService = transcriptionService
        self.summaryService = summaryService
        self.appController = appController
        self.remoteCoordinatorFactory = remoteCoordinatorFactory
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
            prepareRecordingSession()
            try await recorder.startRecording()
            hasReachedRecordingLimit = false
            state = .recording
        } catch {
            teardownRecordingSession()
            MeetingLog.error("startRecording failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        MeetingLog.info("RecorderViewModel stopRecording")
        do {
            state = .processing
            guard let audioURL = try await recorder.stopRecording() else {
                teardownRecordingSession()
                state = .failed("Meeting recording did not produce an audio file.")
                return
            }

            let recordingSession = activeRecordingSession
            teardownRecordingSession()
            let meetingID = recordingSession?.meetingID ?? UUID()
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
            state = .completed(meetingID)
            if let remoteCoordinator = recordingSession?.remoteCoordinator {
                startRemotePostProcessing(
                    for: meetingID,
                    audioURL: audioURL,
                    coordinator: remoteCoordinator,
                    expectedChunkCount: recordingSession?.sealedChunkCount ?? 0
                )
            } else {
                startPostProcessing(for: meetingID, audioURL: audioURL)
            }
        } catch {
            teardownRecordingSession()
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
        hasReachedRecordingLimit = false
        recorder.cancelRecording()
        teardownRecordingSession()
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

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func duration(of audioURL: URL) -> TimeInterval {
        MeetingRecorder.duration(of: audioURL)
    }

    private func prepareRecordingSession() {
        let meetingID = UUID()
        let remoteCoordinator = remoteCoordinatorFactory?(meetingID)
        activeRecordingSession = ActiveRecordingSession(
            meetingID: meetingID,
            remoteCoordinator: remoteCoordinator,
            sealedChunkCount: 0
        )

        guard let producer = recorder as? MeetingRecordingArtifactProducing else { return }
        producer.artifactHandler = { [weak self] artifact in
            await self?.handleRecordingArtifact(artifact)
        }
    }

    private func teardownRecordingSession() {
        if let producer = recorder as? MeetingRecordingArtifactProducing {
            producer.artifactHandler = nil
        }
        activeRecordingSession = nil
    }

    private func handleRecordingArtifact(_ artifact: MeetingRecordingArtifact) async {
        guard var recordingSession = activeRecordingSession else { return }

        switch artifact {
        case .sealedChunk(let chunkArtifact):
            recordingSession.sealedChunkCount += 1
            activeRecordingSession = recordingSession
            if let remoteCoordinator = recordingSession.remoteCoordinator {
                await remoteCoordinator.handleSealedChunk(chunkArtifact)
            }
        case .finalAudio:
            activeRecordingSession = recordingSession
        }
    }

    private func startPostProcessing(for meetingID: UUID, audioURL: URL) {
        Task { [store, transcriptionService, summaryService] in
            do {
                MeetingLog.info("Meeting post-processing start meetingID=\(meetingID)")
                try await transcriptionService.transcribe(meetingID: meetingID, audioURL: audioURL)
                MeetingLog.info("Meeting transcription completed meetingID=\(meetingID)")

                if AppPreferences.shared.meetingSummaryConfig.isConfigured {
                    do {
                        try await summaryService.submitMeeting(meetingID: meetingID)
                        MeetingLog.info("Meeting summary auto-submit succeeded meetingID=\(meetingID)")
                    } catch {
                        MeetingLog.error("Meeting summary auto-submit failed after recording meetingID=\(meetingID) error=\(error.localizedDescription)")
                    }
                }
            } catch {
                let message = error.localizedDescription
                MeetingLog.error("Meeting transcription failed after recording meetingID=\(meetingID) error=\(message)")
                try? await store.updateMeetingStatus(
                    meetingID: meetingID,
                    status: .failed,
                    progress: 0,
                    transcriptPreview: message
                )
            }
        }
    }

    private func startRemotePostProcessing(
        for meetingID: UUID,
        audioURL: URL,
        coordinator: any MeetingRemoteSessionCoordinating,
        expectedChunkCount: Int
    ) {
        Task { [store, summaryService] in
            do {
                MeetingLog.info("Meeting remote post-processing start meetingID=\(meetingID) expectedChunkCount=\(expectedChunkCount)")
                try await store.updateMeetingStatus(
                    meetingID: meetingID,
                    status: .processing,
                    progress: 0.1,
                    transcriptPreview: MeetingTranscriptionProgress.uploadingAudio(
                        chunkIndex: max(expectedChunkCount, 1),
                        totalChunks: max(expectedChunkCount, 1)
                    ).message
                )
                try await coordinator.finalizeWithRecording(
                    fullAudioURL: audioURL,
                    expectedChunkCount: expectedChunkCount
                )

                try await store.updateMeetingStatus(
                    meetingID: meetingID,
                    status: .processing,
                    progress: MeetingTranscriptionProgress.waitingForRemoteResult().fractionCompleted,
                    transcriptPreview: MeetingTranscriptionProgress.waitingForRemoteResult().message
                )

                let result = try await coordinator.pollUntilCompleted()
                let segments = result.segments.map {
                    MeetingTranscriptionSegmentPayload(
                        sequence: $0.sequence,
                        speakerLabel: $0.speakerLabel ?? "Unknown Speaker",
                        startTime: TimeInterval($0.startMS) / 1_000,
                        endTime: TimeInterval($0.endMS) / 1_000,
                        text: $0.text
                    )
                }
                try await store.updateTranscription(
                    meetingID: meetingID,
                    fullText: result.fullText,
                    segments: segments
                )
                MeetingLog.info("Meeting remote transcription completed meetingID=\(meetingID)")

                if AppPreferences.shared.meetingSummaryConfig.isConfigured {
                    do {
                        try await summaryService.submitMeeting(meetingID: meetingID)
                        MeetingLog.info("Meeting summary auto-submit succeeded meetingID=\(meetingID)")
                    } catch {
                        MeetingLog.error("Meeting summary auto-submit failed after remote recording meetingID=\(meetingID) error=\(error.localizedDescription)")
                    }
                }
            } catch {
                let message = error.localizedDescription
                MeetingLog.error("Meeting remote transcription failed after recording meetingID=\(meetingID) error=\(message)")
                try? await store.updateMeetingStatus(
                    meetingID: meetingID,
                    status: .failed,
                    progress: 0,
                    transcriptPreview: message
                )
            }
        }
    }

    nonisolated private static func remoteLedgerURL(meetingID: UUID) -> URL {
        MeetingRecord.meetingsDirectory
            .appendingPathComponent("remote-session-ledgers", isDirectory: true)
            .appendingPathComponent("\(meetingID.uuidString).json")
    }
}
