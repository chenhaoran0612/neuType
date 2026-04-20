# NeuType Refactor Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the maintenance cost of the highest-risk NeuType files by splitting UI, orchestration, persistence, and network responsibilities into smaller units without changing user-visible behavior.

**Architecture:** Refactor from the outside in. First carve out stable seams around giant UI files, then separate workflow orchestration from infrastructure-heavy clients and stores. Each phase must preserve behavior, add or move targeted tests first, and keep unrelated changes out of scope.

**Tech Stack:** Swift, SwiftUI, AppKit, Foundation, GRDB, XCTest, xcodebuild

---

## Refactor goals

- Shrink the biggest files that currently mix unrelated responsibilities.
- Make state flow easier to reason about.
- Make targeted tests possible without booting the whole app surface.
- Avoid large behavioral rewrites during structural refactors.
- Keep every phase independently mergeable.

## Non-goals

- No visual redesign.
- No API/protocol redesign unless required to extract a stable seam.
- No database schema changes unless a later bug requires them.
- No “rewrite everything” branch.

## Success criteria

- No single hot-spot file continues to own UI + business logic + infrastructure at once.
- New logic lands in focused files with one clear purpose.
- Each refactor phase has targeted tests or smoke coverage.
- Phases can be paused after any checkpoint with the app still buildable.

---

### Phase 0: Baseline, safety rails, and test layout cleanup

**Why first:** The codebase already has a few unrelated failing or environment-sensitive tests. Refactoring without narrower checks will turn every move into guesswork.

**Primary files:**
- Modify: `NeuTypeTests/NeuTypeTests.swift`
- Create: `NeuTypeTests/ContentViewModelTests.swift`
- Create: `NeuTypeTests/SettingsViewModelTests.swift`
- Create: `NeuTypeTests/WhisperEngineTests.swift`
- Create: `NeuTypeTests/MicrophoneServiceTests.swift`
- Create: `NeuTypeTests/ClipboardUtilTests.swift`

- [ ] Split `NeuTypeTests/NeuTypeTests.swift` into domain-focused test files, preserving existing assertions first.
- [ ] Mark environment-sensitive tests clearly, or isolate them behind dedicated commands instead of blocking structural refactors.
- [ ] Create a small set of refactor-safe targeted commands, for example:
  - `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/ContentViewModelTests`
  - `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/SettingsViewModelTests`
  - `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/MeetingDetailViewModelTests`
- [ ] Write down which tests are “structural safety net” tests for each upcoming phase.

**Exit condition:** You can run narrow tests for one subsystem without pulling in unrelated flaky or environment-dependent suites.

---

### Phase 1: Split `ContentView.swift` into page orchestration plus focused UI sections

**Why next:** `NeuType/ContentView.swift` is the biggest general-app file and mixes page state, recording workflow, search/pagination, permission UI, and visual components.

**Primary files:**
- Modify: `NeuType/ContentView.swift`
- Create: `NeuType/ViewModels/ContentViewModel.swift`
- Create: `NeuType/Views/Home/PermissionsView.swift`
- Create: `NeuType/Views/Home/RecordingRow.swift`
- Create: `NeuType/Views/Home/TranscriptionView.swift`
- Create: `NeuType/Views/Home/MicrophonePickerIconView.swift`
- Create: `NeuType/Views/Home/MainRecordButton.swift`
- Create: `NeuType/Views/Home/ThemePalette.swift`
- Optional create: `NeuType/UseCases/CompleteRecordingUseCase.swift`
- Test: `NeuTypeTests/ContentViewModelTests.swift`

- [ ] Move `ContentViewModel` out of `ContentView.swift` without behavior changes.
- [ ] Extract pure visual components first: `MainRecordButton`, `MicrophonePickerIconView`, `ShimmerOverlay`, `PermissionRow`, `RecordingRow`.
- [ ] Extract `PermissionsView` and related helper methods from the main file.
- [ ] Isolate search/pagination logic inside `ContentViewModel` and remove view-owned data mutation where possible.
- [ ] Extract the “recording completed -> transcribe -> persist -> prepend to list” workflow into a dedicated use-case or helper owned by the view model.
- [ ] Keep `ContentView` as the page composition root only.

**Guardrails:**
- Do not redesign the screen during this phase.
- Keep environment objects and singletons stable until the file split is complete.
- Avoid touching meetings code here.

**Exit condition:** `ContentView.swift` becomes a composition file, ideally under ~400 lines.

---

### Phase 2: Split `Settings.swift` into state, transfer services, and tab-specific views

**Why next:** `NeuType/Settings.swift` mixes settings storage sync, file import/export, validation, permissions status display, and two tabs of UI.

**Primary files:**
- Modify: `NeuType/Settings.swift`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Create: `NeuType/ViewModels/SettingsViewModel.swift`
- Create: `NeuType/Settings/GeneralSettingsTabView.swift`
- Create: `NeuType/Settings/RequestLogsTabView.swift`
- Create: `NeuType/Settings/PermissionStatusRow.swift`
- Create: `NeuType/Settings/LabeledInputField.swift`
- Create: `NeuType/Settings/VisibleSettingsSnapshot.swift`
- Create: `NeuType/Settings/VisibleSettingsStore.swift`
- Create: `NeuType/Settings/SettingsTransferPanelController.swift`
- Test: `NeuTypeTests/SettingsViewModelTests.swift`

- [ ] Move `VisibleSettingsSnapshot` and `VisibleSettingsStore` out of `AppPreferences.swift`.
- [ ] Move AppKit file-panel code into `SettingsTransferPanelController` or equivalent adapter.
- [ ] Keep `SettingsViewModel` responsible for state sync and messaging only.
- [ ] Split `GeneralSettingsTabView` and `RequestLogsTabView` into separate files.
- [ ] Add targeted tests around `reloadFromPreferences`, settings import/export application, and shortcut validation.

**Guardrails:**
- Import/export behavior must remain scoped to user-visible settings only.
- Avoid introducing a second settings source of truth.

**Exit condition:** `Settings.swift` becomes a small root tab container instead of a full feature dump.

---

### Phase 3: Break `MeetingDetailView.swift` into feature panes and reusable rendering helpers

**Why this matters:** `NeuType/Meetings/Views/MeetingDetailView.swift` owns summary UI, transcript UI, export actions, playback bar, markdown rendering, and window-drag helpers in one file.

**Primary files:**
- Modify: `NeuType/Meetings/Views/MeetingDetailView.swift`
- Create: `NeuType/Meetings/Views/MeetingSummaryPane.swift`
- Create: `NeuType/Meetings/Views/MeetingTranscriptPane.swift`
- Create: `NeuType/Meetings/Views/MeetingPlaybackBar.swift`
- Create: `NeuType/Meetings/Views/MeetingSummaryHeaderActions.swift`
- Create: `NeuType/Meetings/Views/MeetingShareActionButtons.swift`
- Create: `NeuType/Meetings/Views/MeetingMarkdownTextView.swift`
- Create: `NeuType/Meetings/Rendering/MeetingMarkdownHTMLRenderer.swift`
- Create: `NeuType/Meetings/Exporting/MeetingDetailExportActions.swift`
- Test: `NeuTypeTests/MeetingDetailViewModelTests.swift`
- Test: `NeuTypeTests/MeetingExportFormatterTests.swift`

- [ ] Extract summary pane UI into its own file.
- [ ] Extract transcript pane and playback bar next.
- [ ] Move export actions out of the view body file.
- [ ] Move `MarkdownTextView` and `MarkdownHTMLRenderer` into dedicated rendering files.
- [ ] Keep `MeetingDetailView` responsible only for screen composition and bindings.

**Guardrails:**
- Preserve current markdown rendering output before optimizing it.
- Do not mix rendering cleanup with summary/transcript business-rule changes.

**Exit condition:** `MeetingDetailView.swift` holds only top-level layout and a handful of helper bindings.

---

### Phase 4: Turn `VibeVoiceRunnerClient.swift` into an orchestrator instead of a god-object

**Why this is high value:** `NeuType/Meetings/Transcription/VibeVoiceRunnerClient.swift` currently owns chunking, overlap logic, boundary search, request building, SSE parsing, token handling, payload repair, and debug artifact persistence.

**Primary files:**
- Modify: `NeuType/Meetings/Transcription/VibeVoiceRunnerClient.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceAudioChunker.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceRequestBuilder.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceAPIClient.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceSSEParser.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceSegmentMerger.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoicePayloadRepair.swift`
- Create: `NeuType/Meetings/Transcription/VibeVoice/VibeVoiceDebugArtifactStore.swift`
- Test: `NeuTypeTests/VibeVoiceRunnerClientTests.swift`

- [ ] Extract pure functions first, especially chunk calculations, overlap merge, payload parsing, and mojibake repair.
- [ ] Add focused unit tests around those pure helpers before moving HTTP orchestration.
- [ ] Split streaming transport from transcript post-processing.
- [ ] Leave `VibeVoiceRunnerClient` as a coordinator over smaller collaborators.

**Guardrails:**
- Keep request/response payload shapes exactly stable during extraction.
- Do not change chunk defaults unless tests prove no regression.
- Preserve current debug artifact behavior until after the split is done.

**Exit condition:** The main client file becomes readable and mostly orchestration glue.

---

### Phase 5: Decompose `MeetingRecordStore.swift` into repository, bootstrap, and notification concerns

**Why this matters:** The store currently mixes schema setup, recovery, CRUD, and change broadcasting. That is manageable now, but it will get ugly fast as meetings features keep growing.

**Primary files:**
- Modify: `NeuType/Meetings/Store/MeetingRecordStore.swift`
- Create: `NeuType/Meetings/Store/MeetingDatabaseBootstrap.swift`
- Create: `NeuType/Meetings/Store/MeetingRecordRepository.swift`
- Create: `NeuType/Meetings/Store/MeetingTranscriptRepository.swift`
- Create: `NeuType/Meetings/Store/MeetingStoreNotifier.swift`
- Test: `NeuTypeTests/MeetingRecordStoreTests.swift`

- [ ] Move DB bootstrap and stale-processing repair into a bootstrap helper.
- [ ] Separate record CRUD from transcript-segment access where possible.
- [ ] Isolate notification posting behind a notifier helper or event publisher.
- [ ] Keep the public API stable while internals move.

**Guardrails:**
- No schema rewrite in this phase.
- No simultaneous UI refactor of meetings list/detail screens here.

**Exit condition:** The store no longer does bootstrap + repository + notifier work in one class.

---

### Phase 6: App-shell cleanup and boundary tightening

**Why last:** Once the worst hotspots are split, clean up the app shell and leftover boundary leaks so the codebase stays clean.

**Primary files:**
- Modify: `NeuType/NeuTypeApp.swift`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/ShortcutManager.swift`
- Create: `NeuType/App/AppDelegate.swift`
- Create: `NeuType/App/AppMenuBuilder.swift`
- Create: `NeuType/App/AppNavigationController.swift`
- Create: `NeuType/App/AppState.swift`

- [ ] Split app bootstrapping, menu building, and app delegate responsibilities into separate files.
- [ ] Remove feature-specific helper types from generic utility files.
- [ ] Revisit singleton usage and make dependencies injectable where tests benefit.
- [ ] Document final module boundaries after the refactor settles.

**Exit condition:** Entry-point files are mostly assembly and no longer feature-heavy.

---

## Recommended execution order

1. Phase 0, establish narrow test commands.
2. Phase 1, split `ContentView.swift`.
3. Phase 2, split `Settings.swift` and move settings transfer types out of `AppPreferences.swift`.
4. Phase 3, split `MeetingDetailView.swift`.
5. Phase 4, decompose `VibeVoiceRunnerClient.swift`.
6. Phase 5, decompose `MeetingRecordStore.swift`.
7. Phase 6, clean up app shell and leftover cross-boundary leaks.

## Suggested checkpoint policy

After each phase:
- Run only the targeted tests for that subsystem first.
- Build the app.
- Do one manual smoke pass for the touched surface.
- Commit before starting the next phase.

## What to avoid

- Do not refactor two giant files in the same commit.
- Do not mix structure changes with product changes.
- Do not “clean up everything nearby.” That is how refactors sprawl.
- Do not start with `VibeVoiceRunnerClient.swift` unless the UI files are already under control.

