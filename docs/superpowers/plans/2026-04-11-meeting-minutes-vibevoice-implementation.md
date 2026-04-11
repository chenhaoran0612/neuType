# Meeting Minutes VibeVoice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a separate Meeting Minutes product surface in NeuType that records microphone + system audio, transcribes meetings with VibeVoice ASR, stores speaker-aware segments, supports timeline playback, and shows meeting history without changing the existing dictation workflow.

**Architecture:** Keep the current dictation stack intact. Add a parallel meeting stack with dedicated models, persistence, recorder, playback coordinator, permissions, and UI. Integrate VibeVoice ASR through a meeting-specific adapter boundary: Swift owns orchestration and persistence, while a small Python runner handles local VibeVoice inference and returns structured JSON.

**Tech Stack:** SwiftUI, AVFoundation, ScreenCaptureKit, GRDB, KeyboardShortcuts, Python 3, Hugging Face Transformers, VibeVoice ASR

---

## Assumptions

- Meeting mode uses `VibeVoice ASR` and does not reuse the existing `WhisperEngine`.
- The first implementation runs VibeVoice locally through a Python helper script launched from the app with `Process`.
- If the team later provides a hosted VibeVoice endpoint, only the meeting ASR adapter layer should change.
- The existing dictation flow continues to use the current ASR stack unchanged.

## File Structure

### Create

- `NeuType/Meetings/Models/MeetingRecord.swift`
  Meeting-level metadata, status enum, file-path helpers, and transcript preview logic.
- `NeuType/Meetings/Models/MeetingTranscriptSegment.swift`
  Segment-level persistence model for speaker-aware transcript rows.
- `NeuType/Meetings/Store/MeetingRecordStore.swift`
  GRDB-backed meeting persistence, schema migration, record/segment CRUD, and query helpers.
- `NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift`
  In-memory structured meeting transcription result types.
- `NeuType/Meetings/Transcription/VibeVoiceRunnerClient.swift`
  Swift adapter that launches the Python runner, passes audio path/config, and decodes JSON output.
- `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
  Meeting-specific orchestration that converts runner output into persisted `MeetingRecord` + segments.
- `NeuType/Meetings/Recorder/MeetingRecorder.swift`
  Meeting audio capture coordinator for microphone + system audio.
- `NeuType/Meetings/Recorder/MeetingRecorderState.swift`
  Explicit state machine types for idle, blocked, recording, processing, completed, and failed states.
- `NeuType/Meetings/Playback/MeetingPlaybackCoordinator.swift`
  Audio player state, seek handling, and active-segment tracking.
- `NeuType/Meetings/ViewModels/MeetingListViewModel.swift`
  Loads history list, creates new meetings, handles navigation state.
- `NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift`
  Recorder page state, permissions gating, start/stop logic, and processing handoff.
- `NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift`
  Detail page metadata, segment loading, and playback interaction.
- `NeuType/Meetings/Views/MeetingListView.swift`
- `NeuType/Meetings/Views/MeetingRecorderView.swift`
- `NeuType/Meetings/Views/MeetingDetailView.swift`
- `NeuType/Meetings/Views/MeetingRootView.swift`
  Meeting product surface entry and internal navigation shell.
- `Scripts/vibevoice_asr_runner.py`
  Local Python entrypoint that loads VibeVoice ASR, runs inference on an audio file, and prints structured JSON.
- `NeuTypeTests/MeetingRecordStoreTests.swift`
- `NeuTypeTests/VibeVoiceRunnerClientTests.swift`
- `NeuTypeTests/MeetingTranscriptionServiceTests.swift`
- `NeuTypeTests/MeetingPlaybackCoordinatorTests.swift`
- `NeuTypeTests/MeetingRecorderViewModelTests.swift`
- `NeuTypeTests/MeetingShortcutValidationTests.swift`
- `NeuTypeTests/MeetingListViewModelTests.swift`

### Modify

- `NeuType/NeuTypeApp.swift`
  Route into the new meeting surface from the main app shell if needed.
- `NeuType/ContentView.swift`
  Add a Meeting Minutes entry point while preserving the existing dictation UI.
- `NeuType/PermissionsManager.swift`
  Extend permission coverage for screen recording checks and settings deep links.
- `NeuType/Settings.swift`
  Add meeting shortcut controls and VibeVoice runner configuration.
- `NeuType/ShortcutManager.swift`
  Register a dedicated meeting shortcut and keep it isolated from dictation shortcuts.
- `NeuType/Utils/AppPreferences.swift`
  Persist meeting shortcut and VibeVoice runner configuration values.
- `NeuType/Utils/NotificationName+App.swift`
  Add meeting-related notifications only if shared event wiring is needed.
- `NeuType.xcodeproj/project.pbxproj`
  Add new Swift sources, tests, and the Python runner resource if bundled.
- `docs/superpowers/specs/2026-04-11-meeting-minutes-design.md`
  Already updated to lock in VibeVoice ASR as the meeting transcription core.

## Task 1: Add Meeting Persistence Models

**Files:**
- Create: `NeuType/Meetings/Models/MeetingRecord.swift`
- Create: `NeuType/Meetings/Models/MeetingTranscriptSegment.swift`
- Create: `NeuType/Meetings/Store/MeetingRecordStore.swift`
- Test: `NeuTypeTests/MeetingRecordStoreTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing persistence tests**

```swift
func testInsertMeetingAndFetchSegments() async throws {
    let store = try MeetingRecordStore.inMemory()
    let meeting = MeetingRecord.fixture(status: .processing)
    let segments = [
        MeetingTranscriptSegment.fixture(meetingID: meeting.id, sequence: 0, speakerLabel: "Speaker 1"),
        MeetingTranscriptSegment.fixture(meetingID: meeting.id, sequence: 1, speakerLabel: "Speaker 2")
    ]

    try await store.insertMeeting(meeting, segments: segments)

    let loaded = try await store.fetchMeeting(id: meeting.id)
    let loadedSegments = try await store.fetchSegments(meetingID: meeting.id)

    XCTAssertEqual(loaded?.id, meeting.id)
    XCTAssertEqual(loadedSegments.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRecordStoreTests`

Expected: `** TEST FAILED **` because the meeting types and store do not exist yet.

- [ ] **Step 3: Implement minimal meeting models and store**

```swift
enum MeetingRecordStatus: String, Codable {
    case recording
    case processing
    case completed
    case failed
}
```

```swift
struct MeetingTranscriptSegment: Identifiable, Codable, FetchableRecord, PersistableRecord {
    let id: UUID
    let meetingID: UUID
    let sequence: Int
    let speakerLabel: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRecordStoreTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Models/MeetingRecord.swift NeuType/Meetings/Models/MeetingTranscriptSegment.swift NeuType/Meetings/Store/MeetingRecordStore.swift NeuTypeTests/MeetingRecordStoreTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting persistence models"
```

## Task 2: Add Meeting Preferences and Shortcut Validation

**Files:**
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/Settings.swift`
- Modify: `NeuType/ShortcutManager.swift`
- Test: `NeuTypeTests/MeetingShortcutValidationTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing shortcut validation tests**

```swift
func testMeetingShortcutRejectsDictationShortcutCollision() {
    let validator = MeetingShortcutValidator(
        dictationShortcut: .init(.backtick, modifiers: .option)
    )

    XCTAssertFalse(validator.canUse(.init(.backtick, modifiers: .option)))
    XCTAssertTrue(validator.canUse(.init(.m, modifiers: [.option, .shift])))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingShortcutValidationTests`

Expected: `** TEST FAILED **` because meeting shortcut configuration does not exist yet.

- [ ] **Step 3: Implement minimal meeting preferences and validator**

```swift
@UserDefault(key: "meetingShortcutKey", defaultValue: "m")
var meetingShortcutKey: String

@UserDefault(key: "meetingShortcutModifiers", defaultValue: Int(NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue))
var meetingShortcutModifiers: Int
```

```swift
extension KeyboardShortcuts.Name {
    static let toggleMeetingRecord = Self("toggleMeetingRecord", default: .init(.m, modifiers: [.option, .shift]))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingShortcutValidationTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Utils/AppPreferences.swift NeuType/Settings.swift NeuType/ShortcutManager.swift NeuTypeTests/MeetingShortcutValidationTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting shortcut settings"
```

## Task 3: Add VibeVoice Runner Integration

**Files:**
- Create: `NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoiceRunnerClient.swift`
- Create: `Scripts/vibevoice_asr_runner.py`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/Settings.swift`
- Test: `NeuTypeTests/VibeVoiceRunnerClientTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing runner decoding test**

```swift
func testDecodeStructuredRunnerOutput() throws {
    let data = """
    {
      "full_text": "hello world",
      "segments": [
        {"sequence": 0, "speaker_label": "Speaker 1", "start_time": 0.0, "end_time": 1.2, "text": "hello"},
        {"sequence": 1, "speaker_label": "Speaker 2", "start_time": 1.2, "end_time": 2.0, "text": "world"}
      ]
    }
    """.data(using: .utf8)!

    let result = try VibeVoiceRunnerClient.decodeResult(from: data)
    XCTAssertEqual(result.segments.count, 2)
    XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/VibeVoiceRunnerClientTests`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement the minimal runner contract**

```swift
struct MeetingTranscriptionResult: Decodable {
    let fullText: String
    let segments: [MeetingTranscriptionSegmentPayload]
}
```

```python
def main() -> int:
    request = json.load(sys.stdin)
    output = run_vibevoice_asr(request["audio_path"], request.get("hotwords", []))
    json.dump(output, sys.stdout, ensure_ascii=False)
    return 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/VibeVoiceRunnerClientTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift NeuType/Meetings/Transcription/VibeVoiceRunnerClient.swift Scripts/vibevoice_asr_runner.py NeuType/Utils/AppPreferences.swift NeuType/Settings.swift NeuTypeTests/VibeVoiceRunnerClientTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add vibevoice runner integration"
```

## Task 4: Add Meeting Transcription Orchestration

**Files:**
- Create: `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
- Modify: `NeuType/Meetings/Store/MeetingRecordStore.swift`
- Test: `NeuTypeTests/MeetingTranscriptionServiceTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing service orchestration test**

```swift
func testTranscribeMeetingPersistsSegmentsAndPreview() async throws {
    let runner = StubVibeVoiceRunnerClient(result: .fixture())
    let store = try MeetingRecordStore.inMemory()
    let service = MeetingTranscriptionService(runner: runner, store: store)
    let meeting = MeetingRecord.fixture(status: .processing)

    try await service.transcribe(meetingID: meeting.id, audioURL: URL(fileURLWithPath: "/tmp/demo.wav"))

    let saved = try await store.fetchMeeting(id: meeting.id)
    let segments = try await store.fetchSegments(meetingID: meeting.id)
    XCTAssertEqual(saved?.status, .completed)
    XCTAssertFalse(saved?.transcriptPreview.isEmpty ?? true)
    XCTAssertFalse(segments.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement minimal orchestration**

```swift
final class MeetingTranscriptionService {
    func transcribe(meetingID: UUID, audioURL: URL) async throws {
        let result = try await runner.transcribe(audioURL: audioURL)
        try await store.updateTranscription(
            meetingID: meetingID,
            fullText: result.fullText,
            segments: result.segments
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Transcription/MeetingTranscriptionService.swift NeuType/Meetings/Store/MeetingRecordStore.swift NeuTypeTests/MeetingTranscriptionServiceTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting transcription orchestration"
```

## Task 5: Add Playback Coordinator and Segment Seeking

**Files:**
- Create: `NeuType/Meetings/Playback/MeetingPlaybackCoordinator.swift`
- Create: `NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift`
- Test: `NeuTypeTests/MeetingPlaybackCoordinatorTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing playback-selection test**

```swift
func testActiveSegmentMatchesPlaybackTime() {
    let segments = [
        MeetingTranscriptSegment.fixture(sequence: 0, startTime: 0, endTime: 2),
        MeetingTranscriptSegment.fixture(sequence: 1, startTime: 2, endTime: 5)
    ]
    let coordinator = MeetingPlaybackCoordinator(audioURL: URL(fileURLWithPath: "/tmp/demo.wav"))

    coordinator.updateCurrentTime(3.0, segments: segments)

    XCTAssertEqual(coordinator.activeSegmentSequence, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingPlaybackCoordinatorTests`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement minimal playback coordinator**

```swift
final class MeetingPlaybackCoordinator: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var activeSegmentSequence: Int?

    func seek(to time: TimeInterval) { /* AVAudioPlayer seek */ }
    func updateCurrentTime(_ time: TimeInterval, segments: [MeetingTranscriptSegment]) { /* set active segment */ }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingPlaybackCoordinatorTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Playback/MeetingPlaybackCoordinator.swift NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift NeuTypeTests/MeetingPlaybackCoordinatorTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting playback coordination"
```

## Task 6: Add Meeting Recorder State Machine and Permissions

**Files:**
- Create: `NeuType/Meetings/Recorder/MeetingRecorderState.swift`
- Create: `NeuType/Meetings/Recorder/MeetingRecorder.swift`
- Create: `NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift`
- Modify: `NeuType/PermissionsManager.swift`
- Test: `NeuTypeTests/MeetingRecorderViewModelTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing permission-gating test**

```swift
func testStartRecordingMovesToPermissionBlockedWhenScreenRecordingMissing() async {
    let permissions = StubMeetingPermissions(microphoneGranted: true, screenGranted: false)
    let viewModel = MeetingRecorderViewModel(permissions: permissions, recorder: StubMeetingRecorder())

    await viewModel.startRecording()

    XCTAssertEqual(viewModel.state, .permissionBlocked(.screenRecording))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRecorderViewModelTests`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement minimal recorder state machine and permission checks**

```swift
enum MeetingRecorderState: Equatable {
    case idle
    case permissionBlocked(MeetingPermissionKind)
    case recording
    case processing
    case completed(UUID)
    case failed(String)
}
```

```swift
final class MeetingRecorderViewModel: ObservableObject {
    @Published private(set) var state: MeetingRecorderState = .idle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRecorderViewModelTests`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Recorder/MeetingRecorderState.swift NeuType/Meetings/Recorder/MeetingRecorder.swift NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift NeuType/PermissionsManager.swift NeuTypeTests/MeetingRecorderViewModelTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting recorder state machine"
```

## Task 7: Add Meeting List and Detail UI

**Files:**
- Create: `NeuType/Meetings/ViewModels/MeetingListViewModel.swift`
- Create: `NeuType/Meetings/Views/MeetingListView.swift`
- Create: `NeuType/Meetings/Views/MeetingRecorderView.swift`
- Create: `NeuType/Meetings/Views/MeetingDetailView.swift`
- Create: `NeuType/Meetings/Views/MeetingRootView.swift`
- Modify: `NeuType/ContentView.swift`
- Modify: `NeuType/NeuTypeApp.swift`
- Test: `NeuTypeTests/MeetingListViewModelTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing list-view-model test**

```swift
func testListLoadsMeetingsNewestFirst() async throws {
    let store = try MeetingRecordStore.inMemory(seed: [.fixture(createdAt: .distantPast), .fixture(createdAt: .now)])
    let viewModel = MeetingListViewModel(store: store)

    await viewModel.load()

    XCTAssertEqual(viewModel.meetings.first?.createdAt, .now)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingListViewModelTests/testListLoadsMeetingsNewestFirst`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement minimal meeting views**

```swift
struct MeetingRootView: View {
    var body: some View {
        NavigationStack {
            MeetingListView()
        }
    }
}
```

- [ ] **Step 4: Run the focused test and a smoke UI build**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingListViewModelTests/testListLoadsMeetingsNewestFirst`

Run: `xcodebuild build -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS'`

Expected: test pass, build pass

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/ViewModels/MeetingListViewModel.swift NeuType/Meetings/Views/MeetingListView.swift NeuType/Meetings/Views/MeetingRecorderView.swift NeuType/Meetings/Views/MeetingDetailView.swift NeuType/Meetings/Views/MeetingRootView.swift NeuType/ContentView.swift NeuType/NeuTypeApp.swift NeuTypeTests/MeetingListViewModelTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting minutes UI"
```

## Task 8: Integrate Real Recording, Shortcut Wiring, and End-to-End Flow

**Files:**
- Modify: `NeuType/Meetings/Recorder/MeetingRecorder.swift`
- Modify: `NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift`
- Modify: `NeuType/ShortcutManager.swift`
- Modify: `NeuType/Settings.swift`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/Meetings/Views/MeetingRecorderView.swift`
- Modify: `NeuType/Meetings/Views/MeetingDetailView.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing end-to-end coordinator test**

```swift
func testStopRecordingTransitionsToProcessingAndThenCompleted() async throws {
    let recorder = StubMeetingRecorder(stopURL: URL(fileURLWithPath: "/tmp/demo.wav"))
    let service = StubMeetingTranscriptionService()
    let viewModel = MeetingRecorderViewModel(recorder: recorder, transcriptionService: service)

    await viewModel.startRecording()
    await viewModel.stopRecording()

    XCTAssertEqual(viewModel.state, .completed(service.completedMeetingID))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRecorderViewModelTests/testStopRecordingTransitionsToProcessingAndThenCompleted`

Expected: `** TEST FAILED **`

- [ ] **Step 3: Implement the real integration**

```swift
KeyboardShortcuts.onKeyDown(for: .toggleMeetingRecord) { [weak self] in
    Task { @MainActor in
        await self?.toggleMeetingRecording()
    }
}
```

```swift
func stopRecording() async {
    state = .processing
    let output = try await recorder.stopRecording()
    try await transcriptionService.transcribe(meetingID: currentMeetingID, audioURL: output.audioURL)
}
```

- [ ] **Step 4: Run targeted tests plus full suite**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS'`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Recorder/MeetingRecorder.swift NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift NeuType/ShortcutManager.swift NeuType/Settings.swift NeuType/Utils/AppPreferences.swift NeuType/Meetings/Views/MeetingRecorderView.swift NeuType/Meetings/Views/MeetingDetailView.swift NeuTypeTests/MeetingRecorderViewModelTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: complete meeting minutes flow"
```

## Manual Verification Checklist

- [ ] Launch the app and confirm the existing dictation workflow still opens the mini recorder and pastes text.
- [ ] Open the new Meeting Minutes surface and confirm it is visually separate from dictation history.
- [ ] Deny microphone permission and confirm the recorder blocks start with a clear recovery action.
- [ ] Deny screen recording permission and confirm the recorder blocks start with a clear recovery action.
- [ ] Start a meeting, play system audio and speak into the microphone, then stop recording.
- [ ] Confirm the meeting transitions into processing and then into a completed detail view.
- [ ] Confirm the meeting history list shows the new meeting with status, duration, and transcript preview.
- [ ] Confirm transcript rows show speaker labels and time ranges.
- [ ] Click multiple transcript segments and confirm playback seeks to the clicked timestamp.
- [ ] Confirm the active segment highlight moves as playback time changes.
- [ ] Confirm the meeting shortcut toggles meeting recording and does not interfere with the dictation shortcut.

## Risks to Watch During Execution

- Bundling or invoking Python reliably on end-user macOS machines is the main integration risk.
- VibeVoice model load time and memory footprint may require explicit UX for cold-start processing.
- ScreenCaptureKit system-audio capture can fail silently if permission state is stale.
- Structured VibeVoice output shape must be locked behind one decoder layer to avoid UI churn.

## Plan Review Notes

- The prescribed plan-document-reviewer subagent is not available in this environment, so this plan must be reviewed manually before execution.
- Before implementation starts, re-open the spec and this plan together and confirm the VibeVoice runner assumption still matches deployment expectations.
