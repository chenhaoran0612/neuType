# Server segment translation design

Date: 2026-04-27
Status: Approved for planning
Scope: Meeting transcription server and meeting transcript display only

## Summary

Add server-side transcript translation for meeting recordings. The existing audio upload server remains the single place that handles audio processing. As each chunk is transcribed and normalized into transcript segments, the server immediately translates every generated segment into English, Chinese, and Arabic. The completed session API returns the original transcript plus per-segment translations. The macOS client stores those translations locally and lets the user choose which language to display and export from the meeting transcript page.

The selected product behavior is:

1. The server translates each segment right after that segment is generated.
2. Final transcript assembly still follows the existing committed chunk order.
3. The client adds a single-choice selector next to "下载文字记录": original, English, Chinese, Arabic.
4. Transcript list display, search, and download use the selected language.
5. If a translation for a segment is missing, that segment falls back to original text instead of rendering empty content.

## Goals

- Move translation into the existing audio upload server backend.
- Preserve the current speaker labels, timestamps, playback seek behavior, and chunk commit ordering.
- Make language switching instant on the client once a session is completed.
- Keep translated text attached to the same transcript segment IDs/timestamps as the original text.
- Keep transcription completion robust if the translation backend is temporarily unavailable or unconfigured.

## Non-goals

- No real-time partial transcript display in the client.
- No separate translation service or client-side translation model.
- No translation selector for meeting summaries in this change.
- No attempt to translate speaker labels.
- No automatic language detection UI; "原始" means the text returned by ASR.

## Current context

The current server pipeline is:

1. Upload full audio or live chunks into a meeting transcription session.
2. Worker processes pending chunks through `ChunkTranscriber`.
3. Worker normalizes model segments into absolute meeting timestamps.
4. Repository stores normalized segments on `SessionChunk.normalized_segments_json`.
5. Commit frontier marks chunks completed in order.
6. `GET /api/meeting-transcription/sessions/{id}` returns final `full_text` and `segments` only when the session reaches `completed`.

The current client pipeline is:

1. `MeetingRemoteSessionCoordinator` polls the session endpoint.
2. `MeetingRemoteTranscriptionModels.swift` decodes `full_text` and `segments`.
3. `MeetingTranscriptionService` maps remote segments to `MeetingTranscriptionSegmentPayload`.
4. `MeetingRecordStore.updateTranscription` saves one text value per local segment.
5. `MeetingDetailView` displays and exports `viewModel.segments`.

## Approved architecture

### Server flow

For each processed chunk:

1. Transcribe chunk audio through the existing transcriber.
2. Normalize result segments exactly as today.
3. Pass the normalized segments to a new translation component.
4. Translate each segment text into:
   - `en`: English
   - `zh`: Chinese
   - `ar`: Arabic
5. Persist the translations with the normalized segment payload for that chunk.
6. Mark the chunk processed.
7. Commit the chunk in order through the existing commit frontier.

This keeps translation close to segment generation and avoids a separate full-session translation pass at the end.

### Server persistence

The lowest-risk persistence change is to extend `SessionChunk.normalized_segments_json` so each segment can include a nested `translations` object:

```json
{
  "text": "Original ASR text",
  "start_ms": 1000,
  "end_ms": 2500,
  "speaker_label": "Speaker 1",
  "speaker_key": "speaker-1",
  "translations": {
    "en": "English translation",
    "zh": "Chinese translation",
    "ar": "Arabic translation"
  }
}
```

The existing JSON field is already the source of final segment reconstruction, so this avoids adding a separate transcript table on the server. Existing rows without `translations` remain valid.

### Server API contract

`TranscriptSegmentResponse` gains an optional `translations` object:

```json
{
  "sequence": 0,
  "speaker_label": "Speaker 1",
  "start_ms": 1000,
  "end_ms": 2500,
  "text": "Original ASR text",
  "translations": {
    "en": "English translation",
    "zh": "Chinese translation",
    "ar": "Arabic translation"
  }
}
```

`SessionStatusResponse.full_text` remains original text. If needed later, a `translated_full_text` object can be derived from segment translations, but v1 only requires per-segment display and export.

### Translation component

Add a server-side translator interface:

```python
class SegmentTranslator(Protocol):
    def translate_segments(self, segments: list[Segment]) -> dict[int, SegmentTranslations]:
        ...
```

The concrete implementation should use an OpenAI-compatible chat completions endpoint configured by environment variables:

- `MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL`
- `MEETING_TRANSCRIPTION_TRANSLATION_API_KEY`
- `MEETING_TRANSCRIPTION_TRANSLATION_MODEL`
- `MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS`

The translator should request structured JSON output keyed by segment index. It should preserve meaning, not summarize, and should keep technical terms/names intact.

If the translation config is missing, the app uses a no-op translator that returns empty translations. If a translation request fails for a chunk, the chunk should still be processed with empty translations and an error logged. The transcription path must not fail solely because translation failed.

### Client local persistence

Extend local transcript segment storage with three optional text columns:

- `textEN`
- `textZH`
- `textAR`

Existing local records migrate with empty defaults. The original `text` column remains the source for "原始".

`MeetingTranscriptionSegmentPayload` and `MeetingTranscriptSegment` gain matching fields. `MeetingRecordStore.updateTranscription` writes all four text variants.

### Client UI

On the transcript tab, next to "下载文字记录", add a single-choice control with:

- `原始`
- `英文`
- `中文`
- `阿语`

The selected language is UI state in `MeetingDetailViewModel`.

For a segment, display text is:

1. Selected translated text if non-empty.
2. Original text as fallback.

Search should match the currently displayed segment text and speaker label. Export should write the currently selected language, using the same fallback behavior as display.

### Export behavior

`MeetingExportFormatter.transcriptText` should support a display text selector or receive already-projected segments. The output format stays the same:

```text
[00:01] Speaker 1
Selected-language segment text
```

Suggested filename can include the selected language suffix, for example:

- `Meeting title.txt` for original
- `Meeting title-en.txt`
- `Meeting title-zh.txt`
- `Meeting title-ar.txt`

## Error handling

- Missing translation config: return original transcript and empty translations.
- Translation API error for one chunk: log the error, persist empty translations for that chunk, continue transcription.
- Malformed translation JSON: keep original text, ignore malformed translations, log a concise diagnostic.
- Empty translated segment: fallback to original in client display/export.
- Existing sessions completed before this change: client selector still works, translated choices fall back to original text.

## Testing plan

### Server tests

- Worker translates normalized segments before marking a chunk processed.
- Completed session response includes per-segment translations.
- No-op translator leaves translations empty and does not block completion.
- Translator failure does not fail the chunk or session.
- Existing normalized segment JSON without translations still reconstructs correctly.

### Client tests

- Remote segment decoding accepts `translations`.
- Local store migrates and persists translated segment fields.
- View model returns selected-language display text with fallback to original.
- Search uses selected-language text.
- Transcript export writes the selected language.

## Implementation notes

- Keep the original ASR text untouched.
- Keep translation field names stable across server and client: `en`, `zh`, `ar`.
- Prefer one batched translation request per chunk instead of one HTTP request per segment.
- Avoid translating timestamps, speaker labels, or JSON keys.
- Do not change the summary generation path in this feature.
