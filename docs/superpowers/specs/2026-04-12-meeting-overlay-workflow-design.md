# Meeting Overlay Workflow Design

Date: 2026-04-12

## Goal

Refit `Meeting Minutes` so the active meeting workflow no longer lives inside the main meeting page. Once recording starts, the main page can hide and the user interacts through independent floating overlays.

## User-Facing Flow

1. User starts a meeting from the meeting page.
2. The main meeting page hides.
3. A floating recording bar appears and stays above other windows.
4. Pressing `Stop` does not immediately finalize the meeting. It opens a floating confirmation card.
5. From the confirmation card:
   - `结束记录` finalizes the recording and starts processing.
   - `继续会议记录` returns to the recording bar and resumes the same meeting session.
6. When processing completes, the meeting is saved into history and the main meeting page can be shown again.

## Windows And State

### Main Meeting Page

- Owns meeting history and detail navigation.
- Is not responsible for active recording controls.
- Can be hidden while overlays are active.

### Floating Recording Bar

- Small always-on-top utility window.
- Shows meeting icon/avatar, `会议记录中...`, lightweight activity dots, and a stop action.
- Does not expose pause in v1.

### Floating Stop Confirmation Card

- Independent floating utility window.
- Replaces the recording bar while confirming.
- Offers:
  - `结束记录`
  - `继续会议记录`

### Coordinator State

The meeting session controller should coordinate:

- whether the main meeting page is presented
- whether the recording overlay is visible
- whether the stop-confirm overlay is visible
- which meeting record should be revealed after completion

## Technical Shape

- Add a dedicated overlay coordinator / controller for floating meeting windows.
- Keep audio recording and transcription state in `MeetingRecorderViewModel`.
- Keep overlay/window transitions in `MeetingSessionController`.
- Use one overlay window at a time.
- `继续会议记录` should resume the same live recording session rather than creating a second meeting.

## Explicit Non-Goals

- true pause / resume
- multiple simultaneous overlay windows
- real-time transcription during recording
- menu bar control flow
