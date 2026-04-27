# Server Segment Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate each server-generated meeting transcript segment into English, Chinese, and Arabic, then let the macOS transcript page display, search, and export the selected language.

**Architecture:** Preserve the existing meeting transcription pipeline and attach translations to the per-chunk normalized segment payload immediately after chunk normalization. The session API returns optional per-segment translations, and the macOS app stores those translations on local transcript segment rows while projecting display text through a selected transcript language.

**Tech Stack:** Python 3.12, FastAPI, SQLAlchemy, Pydantic, httpx, pytest, Swift, SwiftUI, GRDB, XCTest.

---

## File Structure

**Server files**

- Create `server/meeting_transcription/translation.py`
  - Owns translation value objects, translator protocol, no-op translator, OpenAI-compatible HTTP translator, JSON coercion, and helpers that attach translations to normalized segment payloads.
- Modify `server/meeting_transcription/anchor_audio.py`
  - Preserve optional `translations` when decoding and encoding segment payloads.
- Modify `server/meeting_transcription/schemas.py`
  - Add `SegmentTranslationsResponse` and optional `translations` to `TranscriptSegmentResponse`.
- Modify `server/meeting_transcription/repositories.py`
  - Include translations when reconstructing completed transcript segments from chunk JSON.
- Modify `server/meeting_transcription/worker.py`
  - Accept a `SegmentTranslator`, translate normalized segments immediately after normalization, and persist translated segment payloads.
- Modify `server/meeting_transcription/runtime.py`
  - Load translation environment variables and create the configured translator.
- Modify `server/meeting_transcription/background_worker.py` and `server/meeting_transcription/app.py`
  - Pass the translator into the in-process worker loop.
- Modify `server/README.md` and `deploy/meeting-transcription/neutype-meeting-transcription.env.example`
  - Document translation configuration.
- Test in `server/tests/test_worker_processing.py`, `server/tests/test_session_routes.py`, and new `server/tests/test_translation.py`.

**Client files**

- Modify `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift`
  - Decode optional `translations` for each remote segment.
- Modify `NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift`
  - Carry translated text fields in `MeetingTranscriptionSegmentPayload`.
- Modify `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
  - Map remote `en/zh/ar` values into local payloads.
- Modify `NeuType/Meetings/Models/MeetingTranscriptSegment.swift`
  - Add `textEN`, `textZH`, and `textAR` persisted fields plus display helpers.
- Modify `NeuType/Meetings/Store/MeetingRecordStore.swift`
  - Add a migration for translation columns and write translations during `updateTranscription`.
- Modify `NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift`
  - Add selected transcript language and projected filtered/display segments.
- Modify `NeuType/Meetings/Views/MeetingDetailView.swift`
  - Add the segmented picker next to "下载文字记录" and render/export selected-language text.
- Modify `NeuType/Meetings/Exporting/MeetingExportFormatter.swift`
  - Support a custom segment text selector and language-aware filenames.
- Test in `NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift`, `NeuTypeTests/MeetingRecordStoreTests.swift`, `NeuTypeTests/MeetingDetailViewModelTests.swift`, `NeuTypeTests/MeetingExportFormatterTests.swift`, and `NeuTypeTests/MeetingTranscriptionServiceTests.swift`.

---

## Task 1: Server Segment Translation Payload Plumbing

**Files:**
- Modify: `server/meeting_transcription/anchor_audio.py`
- Modify: `server/meeting_transcription/schemas.py`
- Modify: `server/meeting_transcription/repositories.py`
- Test: `server/tests/test_session_routes.py`
- Test: `server/tests/test_worker_processing.py`

- [ ] **Step 1: Write failing tests for existing payloads with translations**

Modify the existing `test_completed_status_includes_transcript_segments` in `server/tests/test_session_routes.py` so the first seeded segment includes `translations`, then assert the response preserves them:

```python
normalized_segments_json=(
    "["
    '{"text":"hello","start_ms":0,"end_ms":1000,"speaker_label":"Speaker 1","speaker_key":"speaker_1",'
    '"translations":{"en":"Hello","zh":"你好","ar":"مرحبا"}},'
    '{"text":"world","start_ms":1000,"end_ms":2000,"speaker_label":"Speaker 2","speaker_key":"speaker_2"}'
    "]"
)
```

Update the first expected response segment:

```python
{
    "sequence": 0,
    "speaker_label": "Speaker 1",
    "start_ms": 0,
    "end_ms": 1000,
    "text": "hello",
    "translations": {"en": "Hello", "zh": "你好", "ar": "مرحبا"},
}
```

Add an anchor helper test to `server/tests/test_worker_processing.py` or `server/tests/test_anchor_audio.py` proving `segments_from_payload` plus `segments_to_payload` preserves translations.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd server
pytest tests/test_session_routes.py::test_completed_status_includes_transcript_segments tests/test_anchor_audio.py -q
```

Expected: FAIL because translations are currently dropped or not present in schema output.

- [ ] **Step 3: Add translation fields to server segment payload objects**

In `server/meeting_transcription/anchor_audio.py`, extend `Segment`:

```python
@dataclass(frozen=True, slots=True)
class Segment:
    text: str
    start_ms: int
    end_ms: int
    speaker_label: str | None = None
    speaker_key: str | None = None
    translations: dict[str, str] | None = None
```

Update `segments_from_payload`:

```python
raw_translations = item.get("translations")
translations = (
    {
        key: str(value)
        for key, value in raw_translations.items()
        if key in {"en", "zh", "ar"} and value is not None
    }
    if isinstance(raw_translations, dict)
    else None
)
```

Pass `translations=translations` to `Segment(...)`.

Update `segments_to_payload` to include translations only when present:

```python
payload = {
    "text": segment.text,
    "start_ms": segment.start_ms,
    "end_ms": segment.end_ms,
    "speaker_label": segment.speaker_label,
    "speaker_key": segment.speaker_key,
}
if segment.translations:
    payload["translations"] = {
        key: value
        for key, value in segment.translations.items()
        if key in {"en", "zh", "ar"} and value
    }
return payload
```

In `server/meeting_transcription/schemas.py`, add:

```python
class SegmentTranslationsResponse(BaseModel):
    en: str | None = None
    zh: str | None = None
    ar: str | None = None
```

Then add to `TranscriptSegmentResponse`:

```python
translations: SegmentTranslationsResponse | None = None
```

In `server/meeting_transcription/repositories.py`, when building `TranscriptSegmentResponse`, pass:

```python
translations=(
    SegmentTranslationsResponse(**segment.translations)
    if segment.translations
    else None
)
```

Import `SegmentTranslationsResponse`.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
cd server
pytest tests/test_session_routes.py::test_completed_status_includes_transcript_segments tests/test_anchor_audio.py tests/test_worker_processing.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/anchor_audio.py server/meeting_transcription/schemas.py server/meeting_transcription/repositories.py server/tests/test_session_routes.py server/tests/test_anchor_audio.py server/tests/test_worker_processing.py
git commit -m "feat: return segment translations in session API"
```

---

## Task 2: Server Translator Component

**Files:**
- Create: `server/meeting_transcription/translation.py`
- Modify: `server/requirements.txt` only if httpx is not already available
- Test: `server/tests/test_translation.py`

- [ ] **Step 1: Write failing translator tests**

Create `server/tests/test_translation.py`:

```python
import httpx

from meeting_transcription.anchor_audio import Segment
from meeting_transcription.translation import (
    NoopSegmentTranslator,
    OpenAICompatibleSegmentTranslator,
    apply_translations,
    segments_with_empty_translations,
)


def test_noop_translator_returns_empty_translations():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translations = NoopSegmentTranslator().translate_segments(segments)

    assert translations == {0: {"en": "", "zh": "", "ar": ""}}


def test_apply_translations_preserves_original_segment_text():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translated = apply_translations(
        segments,
        {0: {"en": "Hello", "zh": "你好", "ar": "مرحبا"}},
    )

    assert translated[0].text == "你好"
    assert translated[0].translations == {
        "en": "Hello",
        "zh": "你好",
        "ar": "مرحبا",
    }


def test_apply_translations_fills_missing_language_keys_with_empty_strings():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translated = apply_translations(segments, {0: {"en": "Hello"}})

    assert translated[0].translations == {"en": "Hello", "zh": "", "ar": ""}
```

Add an HTTP translator test with a stub transport:

```python
def test_openai_compatible_translator_parses_json_response():
    def handler(request):
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": '{"segments":[{"index":0,"en":"Hello","zh":"你好","ar":"مرحبا"}]}'
                        }
                    }
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    translator = OpenAICompatibleSegmentTranslator(
        base_url="https://llm.example.com",
        api_key="key",
        model="model",
        client=client,
    )

    assert translator.translate_segments([Segment(text="你好", start_ms=0, end_ms=1)]) == {
        0: {"en": "Hello", "zh": "你好", "ar": "مرحبا"}
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd server
pytest tests/test_translation.py -q
```

Expected: FAIL because `meeting_transcription.translation` does not exist.

- [ ] **Step 3: Implement `translation.py`**

Create `server/meeting_transcription/translation.py` with:

```python
from __future__ import annotations

import json
import re
from typing import Protocol

import httpx

from meeting_transcription.anchor_audio import Segment

LANGUAGE_KEYS = ("en", "zh", "ar")
SegmentTranslations = dict[str, str]


class SegmentTranslator(Protocol):
    def translate_segments(self, segments: list[Segment]) -> dict[int, SegmentTranslations]:
        ...


class NoopSegmentTranslator:
    def translate_segments(self, segments: list[Segment]) -> dict[int, SegmentTranslations]:
        return {index: empty_translations() for index, _ in enumerate(segments)}


class OpenAICompatibleSegmentTranslator:
    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        timeout_seconds: float = 60.0,
        client: httpx.Client | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key.strip()
        self.model = model.strip()
        self.timeout_seconds = timeout_seconds
        self.client = client

    def translate_segments(self, segments: list[Segment]) -> dict[int, SegmentTranslations]:
        if not segments:
            return {}
        payload = {
            "model": self.model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": self._system_prompt()},
                {"role": "user", "content": json.dumps(self._segments_payload(segments), ensure_ascii=False)},
            ],
        }
        response = self._client().post(
            f"{self.base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
        response.raise_for_status()
        body = response.json()
        content = body["choices"][0]["message"]["content"]
        return coerce_translation_response(content, segment_count=len(segments))

    def _client(self) -> httpx.Client:
        if self.client is not None:
            return self.client
        self.client = httpx.Client(timeout=httpx.Timeout(self.timeout_seconds))
        return self.client

    def _system_prompt(self) -> str:
        return (
            "Translate each transcript segment into English, Simplified Chinese, and Arabic. "
            "Preserve meaning, names, numbers, and technical terms. Do not summarize. "
            "Return only JSON with shape {\"segments\":[{\"index\":0,\"en\":\"...\",\"zh\":\"...\",\"ar\":\"...\"}]}."
        )

    def _segments_payload(self, segments: list[Segment]) -> dict[str, object]:
        return {
            "segments": [
                {"index": index, "text": segment.text}
                for index, segment in enumerate(segments)
            ]
        }


def apply_translations(
    segments: list[Segment],
    translations_by_index: dict[int, SegmentTranslations],
) -> list[Segment]:
    return [
        segment.copy_with(
            translations=normalized_translations(translations_by_index.get(index, {}))
        )
        for index, segment in enumerate(segments)
    ]


def segments_with_empty_translations(segments: list[Segment]) -> list[Segment]:
    return apply_translations(segments, {})


def empty_translations() -> SegmentTranslations:
    return {key: "" for key in LANGUAGE_KEYS}


def normalized_translations(raw: dict[str, object] | SegmentTranslations) -> SegmentTranslations:
    values = empty_translations()
    for key in LANGUAGE_KEYS:
        value = raw.get(key)
        values[key] = str(value).strip() if value is not None else ""
    return values


def coerce_translation_response(content: str, *, segment_count: int) -> dict[int, SegmentTranslations]:
    payload = _json_object_from_content(content)
    raw_segments = payload.get("segments", [])
    if not isinstance(raw_segments, list):
        return {}
    translations: dict[int, SegmentTranslations] = {}
    for item in raw_segments:
        if not isinstance(item, dict):
            continue
        try:
            index = int(item["index"])
        except (KeyError, TypeError, ValueError):
            continue
        if 0 <= index < segment_count:
            translations[index] = normalized_translations(item)
    return translations


def _json_object_from_content(content: str) -> dict[str, object]:
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", content, flags=re.DOTALL)
        if match is None:
            return {}
        try:
            parsed = json.loads(match.group(0))
        except json.JSONDecodeError:
            return {}
    return parsed if isinstance(parsed, dict) else {}
```

Check `server/requirements.txt`. If `httpx` is already present through the current service dependencies, do not add a duplicate requirement.

- [ ] **Step 4: Run translator tests**

Run:

```bash
cd server
pytest tests/test_translation.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/translation.py server/tests/test_translation.py server/requirements.txt
git commit -m "feat: add segment translation component"
```

---

## Task 3: Translate Segments During Chunk Processing

**Files:**
- Modify: `server/meeting_transcription/worker.py`
- Modify: `server/tests/test_worker_processing.py`

- [ ] **Step 1: Write failing worker tests**

In `server/tests/test_worker_processing.py`, add stubs:

```python
class RecordingTranslator:
    def __init__(self) -> None:
        self.calls = []

    def translate_segments(self, segments):
        self.calls.append([segment.text for segment in segments])
        return {
            index: {
                "en": f"en:{segment.text}",
                "zh": f"zh:{segment.text}",
                "ar": f"ar:{segment.text}",
            }
            for index, segment in enumerate(segments)
        }


class FailingTranslator:
    def translate_segments(self, segments):
        raise RuntimeError("translation outage")
```

Add tests:

```python
def test_worker_translates_normalized_segments_before_marking_processed(tmp_path):
    harness = WorkerHarness(tmp_path)
    try:
        session = harness.seed_session_with_chunks([0])
        translator = RecordingTranslator()

        assert harness.run_once(translator=translator)

        chunk = harness.fetch_chunk(session.session_id, 0, "live_chunk")
        payload = json.loads(chunk.normalized_segments_json)
        assert payload[0]["translations"] == {
            "en": "en:chunk-0",
            "zh": "zh:chunk-0",
            "ar": "ar:chunk-0",
        }
        assert translator.calls == [["chunk-0"]]
    finally:
        harness.close()


def test_worker_keeps_chunk_processed_when_translation_fails(tmp_path):
    harness = WorkerHarness(tmp_path)
    try:
        session = harness.seed_session_with_chunks([0])

        assert harness.run_once(translator=FailingTranslator())

        chunk = harness.fetch_chunk(session.session_id, 0, "live_chunk")
        payload = json.loads(chunk.normalized_segments_json)
        assert chunk.process_status == "processed"
        assert payload[0]["translations"] == {"en": "", "zh": "", "ar": ""}
    finally:
        harness.close()
```

Extend `WorkerHarness.run_once`:

```python
def run_once(self, transcriber=None, translator=None) -> bool:
    db = self.session_factory()
    try:
        return run_pending_chunk_once(
            db,
            transcriber or self.transcriber,
            storage=self.storage,
            translator=translator,
        )
    finally:
        db.close()
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd server
pytest tests/test_worker_processing.py::test_worker_translates_normalized_segments_before_marking_processed tests/test_worker_processing.py::test_worker_keeps_chunk_processed_when_translation_fails -q
```

Expected: FAIL because `run_pending_chunk_once` does not accept or use a translator.

- [ ] **Step 3: Wire translator into worker**

In `server/meeting_transcription/worker.py`, import:

```python
from meeting_transcription.translation import (
    NoopSegmentTranslator,
    SegmentTranslator,
    apply_translations,
    segments_with_empty_translations,
)
```

Change signature:

```python
def run_pending_chunk_once(
    db: Session,
    transcriber: ChunkTranscriber,
    *,
    storage: LocalArtifactStorage,
    translator: SegmentTranslator | None = None,
) -> bool:
```

After `_normalize_result_segments`, before `mark_chunk_processed`, add:

```python
if normalized_segments is not None:
    segment_translator = translator or NoopSegmentTranslator()
    try:
        translations_by_index = segment_translator.translate_segments(normalized_segments)
        normalized_segments = apply_translations(normalized_segments, translations_by_index)
    except Exception:
        normalized_segments = segments_with_empty_translations(normalized_segments)
```

Keep this `try` scoped only to translation so ASR failures still use the existing retry behavior, while translation failures do not fail the chunk.

- [ ] **Step 4: Run worker tests**

Run:

```bash
cd server
pytest tests/test_worker_processing.py tests/test_translation.py -q
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/worker.py server/tests/test_worker_processing.py
git commit -m "feat: translate transcript segments during chunk processing"
```

---

## Task 4: Runtime Translation Configuration

**Files:**
- Modify: `server/meeting_transcription/runtime.py`
- Modify: `server/meeting_transcription/background_worker.py`
- Modify: `server/meeting_transcription/app.py`
- Modify: `server/README.md`
- Modify: `deploy/meeting-transcription/neutype-meeting-transcription.env.example`
- Test: `server/tests/test_runtime.py`

- [ ] **Step 1: Write failing runtime tests**

In `server/tests/test_runtime.py`, add:

```python
def test_load_worker_runtime_settings_includes_translation_env(monkeypatch):
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL", "https://llm.example.com/v1")
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_API_KEY", "secret")
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_MODEL", "gpt-4.1-mini")
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS", "12.5")

    settings = load_worker_runtime_settings()

    assert settings.translation_base_url == "https://llm.example.com/v1"
    assert settings.translation_api_key == "secret"
    assert settings.translation_model == "gpt-4.1-mini"
    assert settings.translation_timeout_seconds == 12.5
```

Add:

```python
def test_create_segment_translator_uses_noop_when_unconfigured():
    settings = WorkerRuntimeSettings(
        gradio_base_url="https://gradio.example.com",
        max_tokens=8192,
        temperature=0.0,
        top_p=1.0,
        do_sample=False,
        context_info="",
        idle_sleep_seconds=1.0,
        translation_base_url="",
        translation_api_key="",
        translation_model="",
        translation_timeout_seconds=60.0,
    )

    translator = create_segment_translator_from_settings(settings)

    assert isinstance(translator, NoopSegmentTranslator)
```

- [ ] **Step 2: Run runtime tests to verify they fail**

Run:

```bash
cd server
pytest tests/test_runtime.py -q
```

Expected: FAIL because runtime settings do not include translation fields.

- [ ] **Step 3: Add runtime settings and factories**

In `server/meeting_transcription/runtime.py`, extend `WorkerRuntimeSettings`:

```python
translation_base_url: str
translation_api_key: str
translation_model: str
translation_timeout_seconds: float
```

Load env vars:

```python
translation_base_url=_env_str("MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL", default=""),
translation_api_key=_env_str("MEETING_TRANSCRIPTION_TRANSLATION_API_KEY", default=""),
translation_model=_env_str("MEETING_TRANSCRIPTION_TRANSLATION_MODEL", default=""),
translation_timeout_seconds=_env_float("MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS", default=60.0),
```

Add:

```python
def create_segment_translator_from_settings(settings: WorkerRuntimeSettings) -> SegmentTranslator:
    if not settings.translation_base_url or not settings.translation_api_key or not settings.translation_model:
        return NoopSegmentTranslator()
    return OpenAICompatibleSegmentTranslator(
        base_url=settings.translation_base_url,
        api_key=settings.translation_api_key,
        model=settings.translation_model,
        timeout_seconds=settings.translation_timeout_seconds,
    )
```

In `background_worker.py`, update the loop constructor to accept/pass translator. In `app.py`, where runtime settings and transcriber are created, also create `translator = create_segment_translator_from_settings(settings)` and pass it to worker execution.

- [ ] **Step 4: Update docs**

In `server/README.md`, under worker env vars, add:

```bash
export MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL="https://api.openai.com/v1"
export MEETING_TRANSCRIPTION_TRANSLATION_API_KEY=""
export MEETING_TRANSCRIPTION_TRANSLATION_MODEL=""
export MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS=60
```

In `deploy/meeting-transcription/neutype-meeting-transcription.env.example`, add the same variables with empty API key/model defaults.

- [ ] **Step 5: Run runtime and server tests**

Run:

```bash
cd server
pytest tests/test_runtime.py tests/test_worker_processing.py tests/test_session_routes.py tests/test_translation.py -q
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/meeting_transcription/runtime.py server/meeting_transcription/background_worker.py server/meeting_transcription/app.py server/tests/test_runtime.py server/README.md deploy/meeting-transcription/neutype-meeting-transcription.env.example
git commit -m "feat: configure server segment translation"
```

---

## Task 5: Client Decode and Persist Translations

**Files:**
- Modify: `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift`
- Modify: `NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift`
- Modify: `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
- Modify: `NeuType/Meetings/Models/MeetingTranscriptSegment.swift`
- Modify: `NeuType/Meetings/Store/MeetingRecordStore.swift`
- Test: `NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift`
- Test: `NeuTypeTests/MeetingRecordStoreTests.swift`
- Test: `NeuTypeTests/MeetingTranscriptionServiceTests.swift`

- [ ] **Step 1: Write failing Swift decoding and persistence tests**

In `NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift`, add to the session status decode test or create a dedicated test where a completed status response includes:

```json
"segments":[{
  "sequence":0,
  "speaker_label":"Speaker 1",
  "start_ms":0,
  "end_ms":1000,
  "text":"你好",
  "translations":{"en":"Hello","zh":"你好","ar":"مرحبا"}
}]
```

Assert:

```swift
XCTAssertEqual(status.segments?.first?.translations?.en, "Hello")
XCTAssertEqual(status.segments?.first?.translations?.zh, "你好")
XCTAssertEqual(status.segments?.first?.translations?.ar, "مرحبا")
```

In `NeuTypeTests/MeetingRecordStoreTests.swift`, add:

```swift
func testUpdateTranscriptionPersistsSegmentTranslations() async throws {
    let store = try MeetingRecordStore.inMemory()
    let meeting = makeMeeting(status: .processing)
    try await store.insertMeeting(meeting, segments: [])

    try await store.updateTranscription(
        meetingID: meeting.id,
        fullText: "你好",
        segments: [
            MeetingTranscriptionSegmentPayload(
                sequence: 0,
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: 1,
                text: "你好",
                textEN: "Hello",
                textZH: "你好",
                textAR: "مرحبا"
            )
        ]
    )

    let saved = try await store.fetchSegments(meetingID: meeting.id)
    XCTAssertEqual(saved.first?.textEN, "Hello")
    XCTAssertEqual(saved.first?.textZH, "你好")
    XCTAssertEqual(saved.first?.textAR, "مرحبا")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests -only-testing:NeuTypeTests/MeetingRecordStoreTests
```

Expected: FAIL because translation fields do not exist.

- [ ] **Step 3: Add remote and local translation fields**

In `MeetingRemoteTranscriptionModels.swift`, add:

```swift
struct RemoteMeetingTranscriptSegmentTranslations: Codable, Equatable, Sendable {
    let en: String?
    let zh: String?
    let ar: String?
}
```

Add `let translations: RemoteMeetingTranscriptSegmentTranslations?` to `RemoteMeetingTranscriptSegment`.

In `MeetingTranscriptionResult.swift`, add:

```swift
let textEN: String
let textZH: String
let textAR: String
```

with default initializer values if needed to reduce fixture churn:

```swift
init(
    sequence: Int,
    speakerLabel: String,
    startTime: TimeInterval,
    endTime: TimeInterval,
    text: String,
    textEN: String = "",
    textZH: String = "",
    textAR: String = ""
) {
    self.sequence = sequence
    self.speakerLabel = speakerLabel
    self.startTime = startTime
    self.endTime = endTime
    self.text = text
    self.textEN = textEN
    self.textZH = textZH
    self.textAR = textAR
}
```

In `MeetingTranscriptionService.swift`, map:

```swift
textEN: $0.translations?.en ?? "",
textZH: $0.translations?.zh ?? "",
textAR: $0.translations?.ar ?? ""
```

In `MeetingTranscriptSegment.swift`, add stored properties and columns:

```swift
let textEN: String
let textZH: String
let textAR: String
```

In `MeetingRecordStore.setupDatabase`, add migration `v5_add_transcript_translation_columns`:

```swift
let columns = try db.columns(in: MeetingTranscriptSegment.databaseTableName).map(\.name)
for name in ["textEN", "textZH", "textAR"] where !columns.contains(name) {
    try db.alter(table: MeetingTranscriptSegment.databaseTableName) { table in
        table.add(column: name, .text).notNull().defaults(to: "")
    }
}
```

Update `updateTranscription` insertion to write `textEN`, `textZH`, `textAR`.

- [ ] **Step 4: Update fixtures and compile failures**

Update all direct `MeetingTranscriptSegment(...)` initializers in tests to either pass the new fields or add an explicit initializer with default empty values on the model. Prefer a model initializer with defaults if Codable/GRDB compatibility remains clean.

Update all direct `MeetingTranscriptionSegmentPayload(...)` call sites to rely on defaults or pass translation fields.

- [ ] **Step 5: Run targeted Swift tests**

Run:

```bash
xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests -only-testing:NeuTypeTests/MeetingRecordStoreTests -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift NeuType/Meetings/Transcription/MeetingTranscriptionResult.swift NeuType/Meetings/Transcription/MeetingTranscriptionService.swift NeuType/Meetings/Models/MeetingTranscriptSegment.swift NeuType/Meetings/Store/MeetingRecordStore.swift NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift NeuTypeTests/MeetingRecordStoreTests.swift NeuTypeTests/MeetingTranscriptionServiceTests.swift
git commit -m "feat: persist meeting transcript translations"
```

---

## Task 6: Client Language Selection, Display, Search, and Export

**Files:**
- Modify: `NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift`
- Modify: `NeuType/Meetings/Views/MeetingDetailView.swift`
- Modify: `NeuType/Meetings/Exporting/MeetingExportFormatter.swift`
- Test: `NeuTypeTests/MeetingDetailViewModelTests.swift`
- Test: `NeuTypeTests/MeetingExportFormatterTests.swift`

- [ ] **Step 1: Write failing view model and export tests**

In `MeetingDetailViewModelTests.swift`, add:

```swift
@MainActor
func testSelectedTranscriptLanguageProjectsDisplayTextAndSearch() async throws {
    let meeting = MeetingRecord.fixture(status: .completed)
    let store = try MeetingRecordStore.inMemory()
    try await store.insertMeeting(meeting, segments: [
        MeetingTranscriptSegment.fixture(
            meetingID: meeting.id,
            sequence: 0,
            speakerLabel: "Speaker 1",
            text: "你好",
            textEN: "Hello",
            textZH: "你好",
            textAR: "مرحبا"
        )
    ])
    let viewModel = MeetingDetailViewModel(meetingID: meeting.id, audioURL: meeting.audioURL, store: store)

    try await viewModel.load()
    viewModel.selectedTranscriptLanguage = .english
    viewModel.searchText = "Hello"

    XCTAssertEqual(viewModel.filteredTranscriptRows.map(\.displayText), ["Hello"])
}
```

Add fallback assertion:

```swift
viewModel.selectedTranscriptLanguage = .arabic
XCTAssertEqual(viewModel.transcriptRows.first?.displayText, "你好")
```

when `textAR` is empty.

In `MeetingExportFormatterTests.swift`, add:

```swift
func testTranscriptTextCanUseSelectedSegmentText() {
    let meetingID = UUID()
    let meetingDate = Date(timeIntervalSince1970: 0)
    let segments = [
        MeetingTranscriptSegment(
            id: UUID(),
            meetingID: meetingID,
            sequence: 0,
            speakerLabel: "Speaker 1",
            startTime: 0,
            endTime: 1,
            text: "第一段内容",
            textEN: "Hello",
            textZH: "第一段内容",
            textAR: "مرحبا"
        )
    ]
    let text = MeetingExportFormatter.transcriptText(
        meetingTitle: "Meeting",
        meetingDate: meetingDate,
        segments: segments,
        textProvider: { _ in "Hello" }
    )
    XCTAssertTrue(text.contains("Hello"))
    XCTAssertFalse(text.contains("第一段内容"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/MeetingDetailViewModelTests -only-testing:NeuTypeTests/MeetingExportFormatterTests
```

Expected: FAIL because selected language and text provider APIs do not exist.

- [ ] **Step 3: Add transcript language domain model and view model projection**

In `MeetingDetailViewModel.swift`, add:

```swift
enum MeetingTranscriptLanguage: String, CaseIterable, Identifiable {
    case original
    case english
    case chinese
    case arabic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原始"
        case .english: return "英文"
        case .chinese: return "中文"
        case .arabic: return "阿语"
        }
    }
    var fileSuffix: String? {
        switch self {
        case .original: return nil
        case .english: return "en"
        case .chinese: return "zh"
        case .arabic: return "ar"
        }
    }
}
```

Add:

```swift
@Published var selectedTranscriptLanguage: MeetingTranscriptLanguage = .original
```

Add a lightweight display row:

```swift
struct MeetingTranscriptDisplayRow: Identifiable, Equatable {
    let segment: MeetingTranscriptSegment
    let displayText: String
    var id: UUID { segment.id }
    var sequence: Int { segment.sequence }
    var speakerLabel: String { segment.speakerLabel }
    var startTime: TimeInterval { segment.startTime }
}
```

Add:

```swift
var transcriptRows: [MeetingTranscriptDisplayRow] {
    segments.map { segment in
        MeetingTranscriptDisplayRow(
            segment: segment,
            displayText: segment.displayText(for: selectedTranscriptLanguage)
        )
    }
}

var filteredTranscriptRows: [MeetingTranscriptDisplayRow] {
    let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return transcriptRows }
    return transcriptRows.filter {
        $0.speakerLabel.localizedCaseInsensitiveContains(trimmedQuery)
            || $0.displayText.localizedCaseInsensitiveContains(trimmedQuery)
    }
}
```

Keep existing `filteredSegments` temporarily if needed for compatibility, but switch the view to `filteredTranscriptRows`.

In `MeetingTranscriptSegment.swift`, add:

```swift
func displayText(for language: MeetingTranscriptLanguage) -> String {
    let candidate: String
    switch language {
    case .original: candidate = text
    case .english: candidate = textEN
    case .chinese: candidate = textZH
    case .arabic: candidate = textAR
    }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? text : candidate
}
```

- [ ] **Step 4: Update SwiftUI transcript view**

In `MeetingDetailView.swift`, change the completed header HStack:

```swift
Picker("", selection: $viewModel.selectedTranscriptLanguage) {
    ForEach(MeetingTranscriptLanguage.allCases) { language in
        Text(language.title).tag(language)
    }
}
.pickerStyle(.segmented)
.frame(width: 220)
```

Place it next to `Button("下载文字记录")`.

Update list loop:

```swift
ForEach(viewModel.filteredTranscriptRows) { row in
    Button {
        viewModel.playSegment(row.segment)
    } label: {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 26, height: 26)
                .overlay(Text(speakerBadge(for: row.speakerLabel)))
            VStack(alignment: .leading, spacing: 8) {
                Text(row.speakerLabel)
                Text(row.displayText)
            }
        }
    }
    .id(row.sequence)
}
```

Update export:

```swift
let transcript = MeetingExportFormatter.transcriptText(
    meetingTitle: meeting.title,
    meetingDate: meeting.createdAt,
    segments: viewModel.segments,
    textProvider: { $0.displayText(for: viewModel.selectedTranscriptLanguage) }
)
```

Update suggested filename:

```swift
let suffix = viewModel.selectedTranscriptLanguage.fileSuffix.map { "-\($0)" } ?? ""
let suggestedName = "\(meeting.title)\(suffix).txt"
```

- [ ] **Step 5: Update export formatter**

Change signature with a default parameter:

```swift
static func transcriptText(
    meetingTitle: String,
    meetingDate: Date,
    segments: [MeetingTranscriptSegment],
    textProvider: (MeetingTranscriptSegment) -> String = { $0.text }
) -> String
```

Use `textProvider(segment)` in the body.

- [ ] **Step 6: Run targeted Swift tests**

Run:

```bash
xcodebuild test -scheme NeuType -only-testing:NeuTypeTests/MeetingDetailViewModelTests -only-testing:NeuTypeTests/MeetingExportFormatterTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add NeuType/Meetings/ViewModels/MeetingDetailViewModel.swift NeuType/Meetings/Views/MeetingDetailView.swift NeuType/Meetings/Exporting/MeetingExportFormatter.swift NeuType/Meetings/Models/MeetingTranscriptSegment.swift NeuTypeTests/MeetingDetailViewModelTests.swift NeuTypeTests/MeetingExportFormatterTests.swift
git commit -m "feat: add transcript language selector"
```

---

## Task 7: Final Integration Verification

**Files:**
- No expected source edits unless verification reveals issues.

- [ ] **Step 1: Run server focused tests**

Run:

```bash
cd server
pytest tests/test_translation.py tests/test_worker_processing.py tests/test_session_routes.py tests/test_runtime.py tests/test_anchor_audio.py -q
```

Expected: PASS.

- [ ] **Step 2: Run Swift focused tests**

Run:

```bash
xcodebuild test -scheme NeuType \
  -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests \
  -only-testing:NeuTypeTests/MeetingRecordStoreTests \
  -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests \
  -only-testing:NeuTypeTests/MeetingDetailViewModelTests \
  -only-testing:NeuTypeTests/MeetingExportFormatterTests
```

Expected: PASS.

- [ ] **Step 3: Run broader existing regression tests if time allows**

Run:

```bash
cd server
pytest -q
```

Run:

```bash
xcodebuild test -scheme NeuType
```

Expected: PASS or document any pre-existing unrelated failures.

- [ ] **Step 4: Inspect git diff for accidental unrelated edits**

Run:

```bash
git status --short
git diff --stat HEAD
```

Expected: only planned feature files are changed after the final task commit sequence.

- [ ] **Step 5: Final commit if verification required fixes**

If verification required small fixes:

```bash
git add <fixed-files>
git commit -m "fix: stabilize transcript translation integration"
```

---

## Notes for Implementers

- Do not overwrite or revert existing user changes in the working tree. The repository currently had unrelated modified files before this plan was created.
- Keep the translation failure behavior non-blocking. ASR failure should still fail/retry chunks; translation failure should not.
- Preserve original ASR text exactly.
- Use language keys `en`, `zh`, and `ar` across server JSON, Swift models, and persisted columns.
- Keep the client selector state local to the transcript page unless product asks for persistence later.
- Avoid adding a separate server transcript table in this implementation; the approved design uses `normalized_segments_json`.
