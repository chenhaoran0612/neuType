# Meeting Minutes Design

Date: 2026-04-11
Project: NeuType
Status: Draft approved in conversation, pending written-spec review

## Summary

NeuType currently provides a short-form voice-to-text input workflow:

- hold a modifier key or use a shortcut
- record a short audio clip
- transcribe it
- paste text into the current input target

This feature remains unchanged.

This design adds a second, separate workflow: a local-first meeting recording system. The first version introduces a dedicated meeting area in the app, records microphone audio plus system audio, generates a structured transcript with speaker labels and time ranges, supports timeline playback, and stores meeting history separately from existing short-form recordings.

The first version explicitly does not generate a screen recording video and does not submit meetings to AI workforce yet.

## Goals

- Add a dedicated meeting recording experience without changing the existing voice-to-text input behavior.
- Record microphone audio and system audio together into a meeting audio file.
- Generate structured meeting transcripts instead of plain text only.
- Support speaker-labeled transcript segments.
- Support timeline playback by clicking transcript segments.
- Provide a dedicated meeting history list.
- Keep meeting data, UI, shortcuts, and recording pipeline isolated from the existing short-form recording system.

## Non-Goals

- No screen video capture file.
- No remote submission to AI workforce in this version.
- No local AI summary generation in this version.
- No word-level highlighting.
- No editing workflow for meeting titles or transcript content in the first version.
- No merge of meeting history into the existing transcription history view.

## Product Direction

NeuType will have two distinct product surfaces:

1. Voice-to-text input
Used for quick dictation and text insertion into the current focused app. This is the current workflow and must keep working as-is.

2. Meeting Minutes
Used for long-form meeting recording, transcript generation, speaker-aware transcript browsing, and timeline playback.

These two surfaces must be separate in:

- page structure
- shortcuts
- recording pipeline
- data model
- persistence

## User Experience

### Entry Points

- Add a dedicated `Meeting Minutes` entry in the main app UI.
- Add a dedicated meeting shortcut, separate from the current voice-to-text shortcut.
- Default meeting shortcut: `Option + Shift + M`.
- Prevent conflicts with the existing shortcut system when saving shortcut settings.

### Main Pages

The meeting feature introduces three primary views:

1. `MeetingListView`
- Shows historical meetings in reverse chronological order.
- Displays title, created time, duration, status, and transcript preview.
- Supports navigating into a meeting detail page.
- Includes an action to start a new meeting.

2. `MeetingRecorderView`
- Dedicated page for creating and recording a meeting.
- Displays permission state, recording controls, current duration, and recording status.
- After stop, shows processing state while the meeting transcript is generated.

3. `MeetingDetailView`
- Displays meeting metadata and audio playback controls.
- Displays speaker-aware transcript segments with timestamps.
- Supports clicking a segment to seek to its start time and play audio.
- Highlights the currently active segment while audio is playing.

### States

Recorder flow:

`Idle -> Recording -> Processing -> Completed`

Failure transitions:

- `Idle -> PermissionBlocked`
- `Recording -> Failed`
- `Processing -> Failed`

In failure state, the user can retry transcription or discard the meeting.

## Permissions

The meeting recording workflow requires:

- microphone permission
- screen recording permission for system-audio capture

Important clarification:

- the app will not save or export a screen video
- screen recording permission is used only because macOS system-audio capture typically depends on that permission path

Permission behavior:

- Existing voice-to-text flow keeps its current permission requirements.
- Meeting pages are responsible for their own permission gating.
- If microphone permission is missing, the meeting recorder blocks start and offers a system settings entry point.
- If screen recording permission is missing, the meeting recorder blocks start and offers a system settings entry point.

## Architecture

### Separation from Existing Recording

Current short-form recording relies on:

- [AudioRecorder.swift](/Users/chenhaoran/code/NeuType/NeuType/AudioRecorder.swift)
- [TranscriptionService.swift](/Users/chenhaoran/code/NeuType/NeuType/TranscriptionService.swift)
- [Recording.swift](/Users/chenhaoran/code/NeuType/NeuType/Models/Recording.swift)

The new meeting workflow must not overload those types with meeting-specific behavior.

New meeting-specific components:

- `MeetingRecorder`
- `MeetingPermissionManager` or meeting-specific permission extensions on `PermissionsManager`
- `MeetingTranscriptionService`
- `MeetingRecord`
- `MeetingTranscriptSegment`
- `MeetingRecordStore`
- `MeetingAudioPlayerViewModel` or equivalent playback coordinator

### Audio Capture Strategy

Recommended implementation:

- Use `ScreenCaptureKit` to capture system audio.
- Use a separate microphone capture pipeline for mic input.
- Normalize both streams into a shared sample format.
- Mix them into one meeting audio file locally.
- Save the final audio file into a meeting-specific storage directory.

Rationale:

- This preserves the current `AudioRecorder` behavior for voice-to-text input.
- It matches the requirement to capture both system audio and microphone audio.
- It keeps the meeting feature extensible for longer sessions and playback.

### Audio Output

Store a single meeting audio file for each meeting session.

First version constraints:

- audio only
- no video file
- no separate export UI

## Data Model

### MeetingRecord

Meeting-level model:

- `id: UUID`
- `createdAt: Date`
- `title: String`
- `audioFileName: String`
- `transcriptPreview: String`
- `duration: TimeInterval`
- `status: MeetingRecordStatus`
- `progress: Float`

Suggested first-version title format:

- `Meeting YYYY-MM-DD HH:mm`

### MeetingTranscriptSegment

Segment-level model:

- `id: UUID`
- `meetingID: UUID`
- `sequence: Int`
- `speakerLabel: String`
- `startTime: TimeInterval`
- `endTime: TimeInterval`
- `text: String`

### Persistence

Meeting storage must be separate from the current recording storage.

- Meeting audio files in a dedicated directory such as `Application Support/<bundle-id>/meetings/`
- Meeting metadata in dedicated database tables
- Meeting transcript segments in their own table keyed by `meetingID`

This separation avoids mixing short-form text input recordings with long-form meeting content.

## Structured Transcription

### Current Limitation

Current transcription only returns a plain string even though the ASR request asks for `verbose_json`.

That is insufficient for:

- speaker separation
- transcript timeline
- segment playback

### New Meeting Transcription Result

Add a meeting-specific structured transcription result:

- `MeetingTranscriptionResult`
  - `fullText: String`
  - `segments: [MeetingTranscriptSegmentPayload]`

Meeting segment payload:

- `sequence`
- `speakerLabel`
- `startTime`
- `endTime`
- `text`

### Meeting Transcription Pipeline

Meeting transcription flow:

1. `MeetingRecorder` saves the mixed meeting audio file.
2. `MeetingTranscriptionService` submits the audio for ASR.
3. The service parses structured ASR output instead of plain text only.
4. The service resolves speaker labels for segments.
5. `MeetingRecordStore` persists the meeting and its transcript segments.
6. The UI updates from processing state to completed state.

### Speaker Separation

First-version requirement includes speaker separation.

Design implication:

- the meeting transcript data model must store per-segment speaker labels from day one
- even if ASR/diarization quality changes later, the UI and persistence schema stay stable

Implementation expectation:

- Prefer an ASR backend or post-processing path that can yield speaker-aware segments.
- If the backend cannot produce perfect labels initially, the UI still renders generic labels such as `Speaker 1`, `Speaker 2`, or `Unknown`.
- Do not block the feature on perfect diarization accuracy.

## Playback and Timeline UX

### Player Requirements

Each meeting detail page includes:

- play/pause controls
- current time display
- duration display
- seek bar

### Segment Interaction

Each transcript segment row shows:

- speaker label
- start/end time
- text

Behavior:

- Clicking a segment seeks playback to `startTime`.
- Playback starts immediately after segment click.
- The active segment is highlighted when the current playback time falls within its range.

First version does not require:

- word-level sync
- transcript editing
- speaker relabeling UI

## Meeting History

### Meeting List

The list page displays:

- title
- created time
- duration
- processing status
- preview text

Statuses:

- recording
- processing
- completed
- failed

The list is sorted by newest first.

### Navigation

- Main meeting page opens the meeting list.
- Tapping `New Meeting` opens the recorder page.
- Completing or stopping a recording transitions to processing, then into the detail page for that meeting.
- Historical meetings can always be reopened from the list page.

## Shortcut Design

Existing shortcut behavior must remain intact for voice-to-text input.

New meeting shortcut behavior:

- independent shortcut registration
- separate settings surface
- default `Option + Shift + M`
- validation against collisions with the current shortcut and other reserved shortcuts

The meeting shortcut toggles:

- start meeting recording when idle
- stop meeting recording when actively recording

It must not trigger the mini recorder UI used by the existing input workflow.

## Error Handling

Key failure cases:

- microphone permission denied
- screen recording permission denied
- system audio capture initialization failure
- microphone capture initialization failure
- audio mix/write failure
- transcription request failure
- malformed structured ASR response
- playback file missing

Expected UX:

- show clear status and action
- allow retry where possible
- keep failed meetings visible in history when helpful for debugging or retry

## Testing Strategy

### Automated Tests

Add unit coverage for:

- meeting state transitions
- permission gating logic
- meeting record persistence
- meeting transcript segment persistence
- meeting transcription result parsing
- shortcut conflict validation
- playback segment selection logic

Where platform frameworks are hard to unit test directly, isolate them behind protocols and test the stateful logic around them.

### Manual Verification

Manual QA is required for:

- microphone + system audio capture together
- screen recording permission request flow
- denied permission recovery path
- long meeting audio generation
- segment click-to-seek playback
- active segment highlighting
- history list updates after success/failure

## Implementation Notes

### Recommended Increment Order

1. Add meeting data models and persistence.
2. Add structured meeting transcription service and parsing.
3. Add meeting list and detail views backed by mock or fixture data.
4. Add meeting player and segment-seek interaction.
5. Add meeting recorder state machine and permission UI.
6. Integrate real microphone + system audio capture and mixing.
7. Add shortcut wiring and settings integration.
8. End-to-end verify recording to transcript to playback.

### Compatibility

- Existing voice-to-text input functionality must continue working unchanged.
- Existing transcription history must remain scoped to current `Recording`.
- Meeting features must be additive, not invasive.

## Open Risks

- System-audio capture on macOS can be permission-sensitive and framework-sensitive.
- Speaker diarization quality depends on backend capabilities and may require a post-processing stage.
- Long recordings may expose memory and file I/O edge cases.
- Structured ASR responses can vary between providers even when they claim OpenAI compatibility.

## Decisions Locked In

- Meeting Minutes is a separate product surface from voice-to-text input.
- First version records audio only, not screen video.
- First version includes speaker separation.
- First version includes timeline playback.
- First version includes meeting history.
- First version uses a dedicated shortcut that does not conflict with the current one.
- First version does not submit to AI workforce yet.
