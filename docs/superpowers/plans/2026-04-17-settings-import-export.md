# Settings Import Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JSON-based import/export for only the user-visible settings in the Settings page, with file pickers, validation, and UI refresh after import.

**Architecture:** Introduce a dedicated Codable snapshot type plus a small store utility responsible for serializing/deserializing visible settings to disk. Keep Settings UI orchestration in `SettingsViewModel`, which will call the store, apply imported values into `AppPreferences`, refresh published properties, and emit existing side-effect notifications like hotkey changes.

**Tech Stack:** Swift, SwiftUI, Foundation, AppKit (`NSOpenPanel`/`NSSavePanel`), XCTest, Xcode scheme `NeuType`

---

### Task 1: Add failing tests for visible settings snapshot behavior

**Files:**
- Modify: `NeuTypeTests/NeuTypeTests.swift`
- Test: `NeuTypeTests/NeuTypeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
final class VisibleSettingsStoreTests: XCTestCase {
    func testExportWritesOnlyVisibleSettingsSnapshot() throws
    func testImportAppliesVisibleSettingsToPreferences() throws
    func testImportInvalidJSONThrowsAndLeavesExistingPreferencesUntouched() throws
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/VisibleSettingsStoreTests`
Expected: FAIL because snapshot/store types and import/export APIs do not exist yet.

- [ ] **Step 3: Write minimal implementation scaffolding**

```swift
struct VisibleSettingsSnapshot: Codable { ... }
enum VisibleSettingsStore {
    static func exportVisibleSettings(to url: URL) throws
    static func importVisibleSettings(from url: URL) throws
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/VisibleSettingsStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add NeuTypeTests/NeuTypeTests.swift NeuType/Utils/VisibleSettingsStore.swift

git commit -m "feat: add visible settings import export store"
```

### Task 2: Wire import/export actions into Settings UI

**Files:**
- Modify: `NeuType/Settings.swift`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/Utils/NotificationName+App.swift` (only if a new notification becomes necessary)
- Test: `NeuTypeTests/NeuTypeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testRefreshFromPreferencesPullsImportedVisibleSettingsIntoViewModel()
func testApplyingImportedSettingsPostsHotkeyChangedNotification()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/SettingsImportViewModelTests`
Expected: FAIL because refresh/apply orchestration methods do not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
extension SettingsViewModel {
    func exportVisibleSettings() -> Result<URL, Error>
    func importVisibleSettings() -> Result<Void, Error>
    func reloadFromPreferences()
}
```

Add SwiftUI buttons in Settings and minimal success/error status display.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/SettingsImportViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add NeuType/Settings.swift NeuType/Utils/AppPreferences.swift NeuTypeTests/NeuTypeTests.swift

git commit -m "feat: wire settings import export into settings UI"
```

### Task 3: Verify end-to-end behavior and guardrails

**Files:**
- Modify: `NeuTypeTests/NeuTypeTests.swift` (if more regression coverage is needed)
- Verify: `NeuType/Settings.swift`, `NeuType/Utils/VisibleSettingsStore.swift`, `NeuType/Utils/AppPreferences.swift`

- [ ] **Step 1: Add any missing regression coverage**

```swift
func testSnapshotRoundTripPreservesIndicatorPositionAndAPISettings()
```

- [ ] **Step 2: Run focused tests**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/VisibleSettingsStoreTests -only-testing:NeuTypeTests/SettingsImportViewModelTests`
Expected: PASS with 0 failures

- [ ] **Step 3: Run build verification**

Run: `xcodebuild test -scheme NeuType -only-testing:NeuTypeTests`
Expected: PASS for the test target or surface any unrelated existing failures clearly

- [ ] **Step 4: Review UX constraints**

Check that import/export touches only these fields: `modifierOnlyHotkey`, `indicatorOriginX`, `indicatorOriginY`, `asrAPIBaseURL`, `asrAPIKey`, `asrModel`, `llmAPIBaseURL`, `llmAPIKey`, `llmModel`, `llmOptimizationPrompt`.

- [ ] **Step 5: Commit**

```bash
git add NeuTypeTests/NeuTypeTests.swift

git commit -m "test: add settings import export regressions"
```
