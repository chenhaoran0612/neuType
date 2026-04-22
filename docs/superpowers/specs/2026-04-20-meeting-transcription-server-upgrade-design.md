# Meeting transcription server upgrade design

Date: 2026-04-20
Status: Approved for planning
Scope: Meeting recording / VibeVoice transcription pipeline only

## Summary

Upgrade the meeting transcription experience so that meeting audio is uploaded and processed through a dedicated server-side session pipeline instead of the current client-direct model call path. The new flow should:

1. Move model interaction to server-side code so model/API traffic is no longer directly coupled to the macOS client network path.
2. During meeting recording, seal and upload audio chunks every 5 minutes so the server can process work early and improve GPU utilization.
3. Preserve stable speaker identity across chunk boundaries by persisting per-speaker "anchor" audio and prepending those anchors to later chunks before transcription.
4. Keep a robust fallback path: if live chunk upload or processing fails, the client can upload the full local meeting audio, and the server will internally split and process it with the same pipeline.
5. Only show the final transcript after recording stops and the server finalizes the session.

This design explicitly does **not** change the generic `TranscriptionService/WhisperEngine` path.

## Goals

- Improve reliability by moving model-facing transcription logic to a dedicated server.
- Let the server begin processing before recording ends.
- Keep speaker labels stable across hard chunk boundaries.
- Support recovery across client restart, server restart, upload retry, and chunk processing failure.
- Preserve the full local audio file for playback/export even when live chunks are used.

## Non-goals

- No changes to the non-meeting transcription path (`TranscriptionService/WhisperEngine`).
- No real-time partial transcript UI in v1.
- No websocket push in v1; polling is sufficient.
- No mixed final transcript assembled from some live chunks and some fallback chunks.
- No attempt to make the server stream raw audio continuously; chunk upload is the primary path.

## Context in the current codebase

The current codebase already contains:

- A meeting-specific recording pipeline built around `MeetingRecorder`, `MeetingRecorderViewModel`, and `MeetingSessionController`.
- A meeting-specific remote transcription path using `MeetingTranscriptionService` and `VibeVoiceRunnerClient`.
- Existing audio chunking logic in `VibeVoiceRunnerClient` with a default 5 minute chunk duration and overlap-based dedupe.
- Speaker-labeled transcript segments for meetings.

Today, meeting transcription starts only after recording ends. Chunking exists in the current client-side VibeVoice runner, but speaker continuity state is not persisted as a recoverable server session and the server is not the single source of orchestration.

## Approaches considered

### Approach A — Client seals 5 minute chunks, uploads immediately, server owns session orchestration (recommended)

- Client records continuously and keeps the final full audio.
- Client seals 5 minute chunk files during recording and uploads them asynchronously.
- Server owns session state, chunk state, speaker anchors, retries, and final assembly.
- If chunk upload fails, client can later upload full audio into the same session.

**Why recommended**

- Best fit for the requested UX: upload and process early, show final result only after stop.
- Clear server-side source of truth for session recovery and speaker continuity.
- Natural evolution of the existing meeting/VibeVoice code without touching the generic path.

### Approach B — Stream raw audio to server continuously and let server cut chunks

- Server performs all chunking from a live audio stream.

**Why not recommended for v1**

- Higher complexity around streaming transport, reconnect, buffering, and backpressure.
- Larger client/server protocol change than needed.

### Approach C — Keep one growing local recording file and periodically derive chunks from it while recording

**Why not recommended**

- More fragile concurrency around reading from a file while it is still growing.
- Harder to reason about than an explicit chunk sealing model.

## Approved architecture

### End-to-end flow

1. Client starts meeting recording.
2. Client creates a remote transcription session and stores the returned `session_id` locally.
3. Recording continues normally, preserving the full local meeting audio.
4. Every 5 minutes the client seals a chunk file and submits it to an upload queue.
5. Server accepts live chunks, persists them, and starts chunk processing ahead of recording completion.
6. If live upload or chunk processing becomes incomplete, the client can upload the full local audio as fallback into the same session.
7. When the user stops recording, client sends `finalize`.
8. Server finalizes the session using either the complete live-chunk path or the full-audio fallback path.
9. Client polls for completion and then writes the final transcript into `MeetingRecordStore`.

### Ownership boundaries

#### Client responsibilities

- Capture meeting audio.
- Preserve the final local full recording for playback/export.
- Seal chunk files every 5 minutes.
- Upload chunks opportunistically.
- Persist enough local session state to recover after restart.
- Trigger fallback full-audio upload when needed.
- Poll the remote session and apply final results locally.

#### Server responsibilities

- Persist transcription session state.
- Persist chunk upload/processing state.
- Persist speaker anchors.
- Serialize final chunk commitment order by `chunk_index`.
- Execute the transcription model interaction.
- Maintain speaker continuity through anchor prefixing and label remapping.
- Retry failures and support recovery across restart.
- Produce the final transcript as the single source of truth.

## Session model

A remote transcription session represents one meeting transcription lifecycle.

### Session lifecycle states

- `created`
- `receiving_chunks`
- `processing`
- `awaiting_finalize`
- `awaiting_fallback`
- `finalizing`
- `completed`
- `failed`

### Input modes

- `live_chunks`
- `full_audio_fallback`

A session can begin in `live_chunks`. If the live path is incomplete but the client later uploads the full audio, finalization can switch to `full_audio_fallback` while keeping the same `session_id`.

## Data model

### `TranscriptionSession`

Fields:

- `session_id`
- `client_session_token` for idempotent session creation
- `client_meeting_id` (optional)
- `status`
- `input_mode`
- `chunk_duration_ms` (300000)
- `chunk_overlap_ms` (recommend 2500)
- `expected_chunk_count` (nullable until finalize)
- `final_audio_uploaded`
- `final_audio_sha256` (nullable)
- `created_at`
- `updated_at`
- `finalized_at` (nullable)
- `last_error` (nullable)

### `SessionChunk`

Fields:

- `session_id`
- `chunk_index`
- `start_ms`
- `end_ms`
- `source_type` (`live_chunk` or `server_split_from_full_audio`)
- `audio_file_path`
- `sha256`
- `upload_status`
- `process_status` (`pending`, `processing`, `completed`, `failed`)
- `retry_count`
- `result_segment_count`
- `error_message` (nullable)

### `SpeakerAnchor`

Each known speaker contributes exactly one anchor sample, chosen as the first **qualified** utterance rather than blindly the first detected fragment.

Fields:

- `session_id`
- `speaker_key` (server-stable internal speaker identity)
- `first_seen_chunk_index`
- `anchor_order` (order of first appearance)
- `anchor_audio_path`
- `anchor_text`
- `anchor_duration_ms`
- `is_confirmed`

### `TranscriptSegment`

Fields:

- `session_id`
- `chunk_index`
- `sequence`
- `speaker_key`
- `speaker_label`
- `start_ms`
- `end_ms`
- `text`
- `is_from_prefix_anchor`
- `is_final`

## Database design

### Storage choice

Recommended production storage:

- relational database: PostgreSQL
- audio/blob storage:
  - v1 acceptable: local disk mounted on the server
  - recommended if deployment grows: S3-compatible object storage

Reasoning:

- PostgreSQL gives durable recovery, constraints, indexing, and safe worker coordination.
- SQLite is acceptable for local development, but not recommended for the deployed service because restart recovery and concurrent worker coordination are core requirements.

### File storage layout

If using local disk in v1, store files under a deterministic layout:

- `sessions/{session_id}/live-chunks/{chunk_index}.wav`
- `sessions/{session_id}/fallback/full_audio.wav`
- `sessions/{session_id}/fallback/split/{chunk_index}.wav`
- `sessions/{session_id}/anchors/{speaker_key}.wav`
- `sessions/{session_id}/artifacts/prefix/{chunk_index}.wav`
- `sessions/{session_id}/artifacts/manifests/{chunk_index}.json`

The database should store logical file paths/URLs, not absolute machine-local paths.

### Table: `transcription_sessions`

Suggested columns:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | internal primary key |
| `session_id` | `text` | public session identifier, unique |
| `client_session_token` | `text` | unique, for idempotent create |
| `client_meeting_id` | `uuid null` | optional client meeting reference |
| `source` | `text` | e.g. `neutype-macos` |
| `app_version` | `text null` | optional observability field |
| `status` | `text` | constrained enum-like value |
| `input_mode` | `text` | `live_chunks` or `full_audio_fallback` |
| `chunk_duration_ms` | `integer` | expected 300000 |
| `chunk_overlap_ms` | `integer` | expected 2000-3000 |
| `audio_format` | `text` | e.g. `wav` |
| `sample_rate_hz` | `integer` | expected 16000 |
| `channel_count` | `integer` | expected 1 |
| `expected_chunk_count` | `integer null` | set at finalize |
| `selected_final_input_mode` | `text null` | actual chosen source path |
| `final_audio_uploaded` | `boolean` | fallback uploaded or not |
| `final_audio_sha256` | `text null` | dedupe key |
| `final_audio_storage_path` | `text null` | object key or logical path |
| `last_committed_chunk_index` | `integer` | ordering checkpoint |
| `last_error_code` | `text null` | machine readable |
| `last_error_message` | `text null` | human readable |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |
| `finalized_at` | `timestamptz null` | |
| `completed_at` | `timestamptz null` | |

Constraints:

- unique(`session_id`)
- unique(`client_session_token`)
- check `status` in allowed values
- check `input_mode` in allowed values

Indexes:

- index on `status`
- index on `updated_at`
- index on `client_meeting_id`

### Table: `session_chunks`

Suggested columns:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | primary key |
| `session_id` | `uuid` | FK to `transcription_sessions.id` |
| `chunk_index` | `integer` | zero-based or one-based, pick one and keep it consistent |
| `source_type` | `text` | `live_chunk` or `server_split_from_full_audio` |
| `start_ms` | `bigint` | original meeting timeline |
| `end_ms` | `bigint` | original meeting timeline |
| `duration_ms` | `bigint` | derived but denormalized for convenience |
| `sha256` | `text` | upload dedupe and conflict detection |
| `mime_type` | `text` | |
| `file_size_bytes` | `bigint` | |
| `storage_path` | `text` | object key / logical path |
| `upload_status` | `text` | `uploaded`, `reused`, `missing`, `superseded` |
| `process_status` | `text` | `pending`, `processing`, `completed`, `failed` |
| `retry_count` | `integer` | |
| `processing_started_at` | `timestamptz null` | |
| `processing_completed_at` | `timestamptz null` | |
| `result_segment_count` | `integer` | |
| `error_code` | `text null` | |
| `error_message` | `text null` | |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

Constraints:

- unique(`session_id`, `chunk_index`, `source_type`)
- check `end_ms > start_ms`
- check `process_status` in allowed values

Indexes:

- index on (`session_id`, `chunk_index`)
- index on (`session_id`, `process_status`)
- index on (`session_id`, `source_type`)

### Table: `speaker_anchors`

Suggested columns:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | primary key |
| `session_id` | `uuid` | FK |
| `speaker_key` | `text` | stable server-side identity like `speaker_1` |
| `speaker_label` | `text` | latest human-readable label for response |
| `anchor_order` | `integer` | first appearance order |
| `first_seen_chunk_index` | `integer` | |
| `first_seen_segment_sequence` | `integer` | deterministic tie-breaker |
| `anchor_text` | `text` | selected utterance text |
| `anchor_start_ms` | `bigint` | absolute meeting timeline |
| `anchor_end_ms` | `bigint` | absolute meeting timeline |
| `anchor_duration_ms` | `bigint` | |
| `anchor_storage_path` | `text` | file path/key |
| `selection_reason` | `text` | e.g. `first_qualified_utterance` |
| `is_confirmed` | `boolean` | |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

Constraints:

- unique(`session_id`, `speaker_key`)
- unique(`session_id`, `anchor_order`)

Indexes:

- index on (`session_id`, `anchor_order`)

### Table: `transcript_segments`

Suggested columns:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | primary key |
| `session_id` | `uuid` | FK |
| `chunk_id` | `uuid null` | FK to `session_chunks.id` |
| `sequence` | `integer` | final sequence among persisted result rows |
| `chunk_local_sequence` | `integer` | order inside one chunk result |
| `speaker_key` | `text null` | stable server speaker identity |
| `speaker_label` | `text` | final label returned to client |
| `start_ms` | `bigint` | absolute meeting time |
| `end_ms` | `bigint` | absolute meeting time |
| `text` | `text` | transcript text |
| `is_from_prefix_anchor` | `boolean` | prefix-only artifact |
| `is_boundary_discarded` | `boolean` | useful for debugging |
| `is_final` | `boolean` | enters final assembled transcript |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

Constraints:

- check `end_ms > start_ms`

Indexes:

- index on (`session_id`, `is_final`, `sequence`)
- index on (`session_id`, `chunk_id`)
- index on (`session_id`, `speaker_key`)
- index on (`session_id`, `start_ms`)

### Table: `chunk_processing_runs`

Recommended as an audit/debug table so retries and restarts remain inspectable.

Suggested columns:

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | primary key |
| `session_id` | `uuid` | FK |
| `chunk_id` | `uuid` | FK |
| `attempt_number` | `integer` | 1, 2, 3... |
| `prefix_manifest_json` | `jsonb` | anchor timing manifest |
| `request_payload_json` | `jsonb null` | optional sanitized request payload |
| `response_payload_json` | `jsonb null` | optional sanitized response payload |
| `started_at` | `timestamptz` | |
| `completed_at` | `timestamptz null` | |
| `status` | `text` | `started`, `completed`, `failed` |
| `error_code` | `text null` | |
| `error_message` | `text null` | |

Indexes:

- index on (`session_id`, `chunk_id`, `attempt_number`)

### Suggested enums

Represent as database enums or constrained text columns:

- `session_status`
  - `created`
  - `receiving_chunks`
  - `processing`
  - `awaiting_finalize`
  - `awaiting_fallback`
  - `finalizing`
  - `completed`
  - `failed`
- `input_mode`
  - `live_chunks`
  - `full_audio_fallback`
- `chunk_source_type`
  - `live_chunk`
  - `server_split_from_full_audio`
- `chunk_process_status`
  - `pending`
  - `processing`
  - `completed`
  - `failed`

### Transaction and locking rules

To keep session progression deterministic:

- processing workers may pick up uploaded chunks in any order
- but the server should only advance `last_committed_chunk_index` inside a transaction that:
  - locks the parent session row
  - confirms all lower chunk indexes are already committed
  - writes any new speaker anchors
  - writes final transcript segments for that chunk

Recommended pattern:

- `SELECT ... FOR UPDATE` on `transcription_sessions`
- commit one chunk’s durable state at a time

This avoids speaker anchor drift caused by out-of-order durable commits.

## Server APIs

### `POST /api/meeting-transcription/sessions`

Creates a session.

Request:

```json
{
  "client_meeting_id": "uuid-or-null",
  "client_session_token": "client-generated-stable-token",
  "source": "neutype-macos",
  "chunk_duration_ms": 300000,
  "chunk_overlap_ms": 2500
}
```

Response:

```json
{
  "session_id": "srv_session_xxx",
  "status": "created"
}
```

### `PUT /api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}`

Uploads one live chunk.

Multipart form fields:

- `audio_file`
- `start_ms`
- `end_ms`
- `sha256`
- `is_last_chunk=false`

Semantics:

- Idempotent on `session_id + chunk_index + sha256`.
- Same index + different hash is a conflict.

### `PUT /api/meeting-transcription/sessions/{session_id}/full-audio`

Uploads the full local meeting audio for fallback processing.

Multipart form fields:

- `audio_file`
- `sha256`
- `duration_ms`

Semantics:

- Idempotent on `session_id + full_audio_sha256`.
- Server internally performs chunking and reuses the same processing pipeline as live chunks.

### `POST /api/meeting-transcription/sessions/{session_id}/finalize`

Marks recording complete and requests final transcript production.

Request:

```json
{
  "expected_chunk_count": 7,
  "preferred_input_mode": "live_chunks",
  "allow_full_audio_fallback": true
}
```

Semantics:

- Repeated calls are safe.
- If live chunks are complete, finalize uses them.
- If live chunks are incomplete but full audio exists, finalize switches to fallback.

### `GET /api/meeting-transcription/sessions/{session_id}`

Returns session status, progress, and final result when ready.

## Detailed API contract

The first server release should expose a simple authenticated HTTP API over FastAPI.

### Common conventions

- Authentication: `Authorization: Bearer <token>`
- Content type:
  - JSON endpoints use `application/json`
  - audio upload endpoints use `multipart/form-data`
- Time unit: all timeline fields use `ms`
- File integrity: audio uploads always include `sha256`
- Idempotency:
  - session create uses `client_session_token`
  - chunk upload uses `session_id + chunk_index + sha256`
  - full-audio upload uses `session_id + sha256`
- Correlation:
  - every response includes `request_id`
  - every log line should include `session_id`

### Response envelope

Recommend a consistent envelope:

```json
{
  "request_id": "req_123",
  "data": {},
  "error": null
}
```

Error example:

```json
{
  "request_id": "req_124",
  "data": null,
  "error": {
    "code": "chunk_hash_conflict",
    "message": "chunk 3 already exists with a different sha256"
  }
}
```

### `POST /api/meeting-transcription/sessions`

Purpose:

- create or resume a transcription session before recording starts

Request:

```json
{
  "client_session_token": "meeting-20260420-abc123",
  "client_meeting_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source": "neutype-macos",
  "app_version": "0.0.11",
  "chunk_duration_ms": 300000,
  "chunk_overlap_ms": 2500,
  "audio_format": "wav",
  "sample_rate_hz": 16000,
  "channel_count": 1
}
```

Success response:

```json
{
  "request_id": "req_create_1",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "created",
    "input_mode": "live_chunks",
    "chunk_duration_ms": 300000,
    "chunk_overlap_ms": 2500
  },
  "error": null
}
```

Status codes:

- `200` when the same `client_session_token` already exists and is reused
- `201` when a new session is created
- `400` when required fields are invalid
- `401/403` when auth fails

### `PUT /api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}`

Purpose:

- upload one sealed live chunk during recording

Multipart fields:

- `audio_file`
- `start_ms`
- `end_ms`
- `sha256`
- `mime_type`
- `file_size_bytes`

Success response:

```json
{
  "request_id": "req_chunk_3",
  "data": {
    "session_id": "mts_01JXYZ",
    "chunk_index": 3,
    "status": "accepted",
    "upload_status": "uploaded",
    "process_status": "pending"
  },
  "error": null
}
```

Conflict example:

```json
{
  "request_id": "req_chunk_conflict",
  "data": null,
  "error": {
    "code": "chunk_hash_conflict",
    "message": "chunk 3 already exists with a different sha256"
  }
}
```

Status codes:

- `200` for idempotent re-upload of the same chunk
- `201` when a new chunk is stored
- `409` when the same `chunk_index` has a different `sha256`
- `404` when `session_id` does not exist

Server-side validations:

- `end_ms > start_ms`
- chunk file duration should approximately match `end_ms - start_ms`
- audio format should be accepted and normalized if needed

### `PUT /api/meeting-transcription/sessions/{session_id}/full-audio`

Purpose:

- upload final full audio when live chunk path is incomplete or needs fallback

Multipart fields:

- `audio_file`
- `sha256`
- `duration_ms`
- `mime_type`
- `file_size_bytes`

Success response:

```json
{
  "request_id": "req_full_audio_1",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "full_audio_uploaded",
    "input_mode": "full_audio_fallback"
  },
  "error": null
}
```

Status codes:

- `200` for idempotent re-upload of the same file
- `201` for first successful upload
- `404` when `session_id` does not exist

### `POST /api/meeting-transcription/sessions/{session_id}/finalize`

Purpose:

- mark the recording as ended and request final result generation

Request:

```json
{
  "expected_chunk_count": 7,
  "preferred_input_mode": "live_chunks",
  "allow_full_audio_fallback": true,
  "recording_ended_at_ms": 1745112345000
}
```

Success response:

```json
{
  "request_id": "req_finalize_1",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "finalizing",
    "selected_input_mode": "live_chunks"
  },
  "error": null
}
```

Possible waiting response:

```json
{
  "request_id": "req_finalize_wait",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "awaiting_fallback",
    "missing_chunk_indexes": [4, 5]
  },
  "error": null
}
```

Status codes:

- `200` if finalize is accepted or already in progress
- `409` if live chunks are incomplete and fallback is not available
- `404` when `session_id` does not exist

### `GET /api/meeting-transcription/sessions/{session_id}`

Purpose:

- poll current processing state and fetch final transcript when complete

In-progress response:

```json
{
  "request_id": "req_poll_1",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "processing",
    "input_mode": "live_chunks",
    "progress": {
      "fraction_completed": 0.72,
      "message": "processing chunk 5/7",
      "completed_unit_count": 4,
      "total_unit_count": 7
    },
    "missing_chunk_indexes": []
  },
  "error": null
}
```

Completed response:

```json
{
  "request_id": "req_poll_done",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "completed",
    "input_mode": "live_chunks",
    "full_text": "完整转写文本",
    "segments": [
      {
        "sequence": 0,
        "speaker_label": "Speaker 1",
        "start_ms": 0,
        "end_ms": 3200,
        "text": "大家好，我们开始。"
      }
    ]
  },
  "error": null
}
```

Failed response:

```json
{
  "request_id": "req_poll_failed",
  "data": {
    "session_id": "mts_01JXYZ",
    "status": "failed"
  },
  "error": {
    "code": "session_processing_failed",
    "message": "chunk 6 failed after 3 retries and no fallback audio was available"
  }
}
```

### Optional internal/admin endpoints

Not required for the macOS client, but useful for operations:

- `POST /internal/meeting-transcription/sessions/{session_id}/resume`
- `POST /internal/meeting-transcription/sessions/{session_id}/retry-failed-chunks`
- `GET /internal/meeting-transcription/sessions/{session_id}/chunks`
- `GET /internal/meeting-transcription/sessions/{session_id}/anchors`

## Client changes

### `MeetingRecorder`

Upgrade `MeetingRecorder` from a final-audio-only producer to a dual-output producer:

- Continue producing the final full mixed WAV for local playback/export.
- Also seal 5 minute chunk files during recording.

Recommended event model:

- `didStartSession`
- `didSealChunk(chunkIndex, startMs, endMs, fileURL)`
- `didFinishFullAudio(fileURL, durationMs)`

The recorder should remain upload-agnostic; it only emits artifacts/events.

### `MeetingRecorderViewModel`

Expand orchestration responsibilities:

- Create remote session at recording start.
- Maintain local upload queue and per-chunk upload state.
- On stop, determine whether fallback full-audio upload is needed.
- Call finalize.
- Poll session status until completion.
- Persist final transcript into `MeetingRecordStore`.

The existing direct `MeetingTranscriptionService.transcribe(meetingID:audioURL:)` flow should be replaced for the meeting recording path with this session-driven remote workflow.

### `MeetingTranscriptionService`

Split responsibilities into:

- `MeetingRemoteTranscriptionClient` — thin HTTP client for server APIs
- `MeetingTranscriptionService` — stateful orchestration and recovery logic

### `MeetingRecordStore`

Core schema can remain mostly intact, but the meeting record should surface clearer server-backed processing states through `status` and `transcriptPreview` updates.

## Processing pipeline

The server should normalize both input paths into the same chunk pipeline.

### Path 1 — Live chunk input

- Client uploads sealed chunks.
- Server persists them as `SessionChunk` rows and files.
- Processing can start immediately.

### Path 2 — Full audio fallback input

- Client uploads final full audio.
- Server cuts it into internal 5 minute chunks.
- Server persists those chunks as `server_split_from_full_audio`.
- Remaining processing is identical to the live chunk path.

### Important final transcript rule

Only one source path may define the final transcript:

- If all live chunks are complete, final result comes entirely from the live chunk path.
- If live chunks are incomplete but fallback full audio is available, final result comes entirely from the fallback split path.
- Do **not** produce a final transcript by mixing some live chunks with some fallback chunks.

## Chunk ordering

Uploads may arrive out of order, but final session progression must be ordered.

Recommended rule:

- Chunks may be stored eagerly in any order.
- Only commit chunk results into the durable session speaker state and final transcript sequence in increasing `chunk_index` order.

This keeps speaker anchor evolution deterministic and recoverable.

## Specific calling logic

This section defines the concrete call sequence for client orchestration and server-side worker behavior.

### Client-side happy path

#### 1. User starts meeting recording

`MeetingRecorderViewModel.startRecording()` should:

1. verify microphone and screen-recording permissions
2. call `POST /sessions`
3. persist local session state:
   - `session_id`
   - `client_session_token`
   - local recording start time
   - chunk upload ledger
4. start `MeetingRecorder`

Pseudo flow:

```text
MeetingRecorderViewModel.startRecording
  -> createRemoteSession()
  -> persistLocalSessionState()
  -> recorder.startRecording()
  -> state = .recording
```

#### 2. Recorder seals a chunk every 5 minutes

When `MeetingRecorder` emits `didSealChunk(chunkIndex, startMs, endMs, fileURL)`:

1. append a local chunk upload record with status `pending`
2. enqueue an async upload task
3. upload with `PUT /sessions/{session_id}/chunks/{chunk_index}`
4. on success, mark chunk as `uploaded`
5. on failure, mark chunk as `failed_to_upload`, but do **not** interrupt recording

Pseudo flow:

```text
didSealChunk
  -> localStore.insertChunk(status=pending)
  -> uploadQueue.enqueue(chunk)

uploadQueue worker
  -> PUT live chunk
  -> if success: local status = uploaded
  -> if conflict: local status = failed_conflict
  -> if network error: local status = failed_to_upload
```

#### 3. User stops meeting recording

`MeetingRecorderViewModel.stopRecording()` should:

1. stop the recorder and receive final full audio path
2. create the local `MeetingRecord`
3. inspect local chunk upload ledger
4. choose finalization strategy:
   - if all chunks uploaded successfully -> live chunk finalize
   - if any chunk missing/failed -> upload full audio fallback first
5. call `POST /finalize`
6. begin polling `GET /sessions/{session_id}`

Pseudo flow:

```text
stopRecording
  -> recorder.stopRecording()
  -> persist final full audio path
  -> create local meeting record(status=processing)
  -> if all chunks uploaded:
       finalize(preferred_input_mode=live_chunks)
     else:
       uploadFullAudioFallback()
       finalize(preferred_input_mode=full_audio_fallback)
  -> pollUntilCompleted()
```

#### 4. Polling and local store writeback

Polling rules:

- poll every 2 seconds initially
- back off to 5 seconds for long-running sessions
- stop polling when status becomes `completed` or `failed`

When status is `completed`:

1. transform server response into local `MeetingTranscriptionResult`-compatible structure
2. write transcript segments into `MeetingRecordStore`
3. keep the local audio URL unchanged for playback/export
4. trigger summary generation if configured

When status is `failed`:

1. update local meeting status to `failed`
2. write human-readable error into `transcriptPreview`

### Client-side fallback path

Fallback is triggered when at least one of the following is true:

- one or more live chunks failed to upload
- local app restarted and cannot prove all chunks were uploaded
- server reports missing chunks at finalize time
- chunk hash conflict leaves the live path unusable

Flow:

1. upload full audio with `PUT /full-audio`
2. mark local session strategy as `full_audio_fallback`
3. call `POST /finalize`
4. poll session until done

Important rule:

- once finalization selects `full_audio_fallback`, the final transcript is derived only from the fallback split path

### Client restart recovery logic

On app startup, the meeting subsystem should inspect persisted unfinished remote sessions.

For each unfinished local session:

1. call `GET /sessions/{session_id}`
2. if remote session is already `completed`, write back result locally and clear recovery state
3. if remote session is `processing/finalizing`, resume polling
4. if remote session is incomplete and full local audio still exists, re-attempt fallback upload and finalize
5. if neither chunks nor full local audio are recoverable, surface failure locally

### Server request handling logic

#### Session create handler

`POST /sessions`:

1. authenticate request
2. look up `client_session_token`
3. if existing session found, return it
4. otherwise insert new `transcription_sessions` row
5. return created session

#### Live chunk upload handler

`PUT /chunks/{chunk_index}`:

1. authenticate request
2. validate session exists and is not terminal
3. compute or verify `sha256`
4. check existing chunk with same `session_id + chunk_index + source_type=live_chunk`
5. if same hash exists, return idempotent success
6. if different hash exists, return `409`
7. store audio file
8. insert/update `session_chunks`
9. move session status to `receiving_chunks` or `processing`
10. enqueue server processing for that chunk

#### Full audio upload handler

`PUT /full-audio`:

1. authenticate request
2. validate session exists
3. verify `sha256`
4. if same fallback file already exists, return idempotent success
5. store full audio
6. update session fallback metadata
7. return success

#### Finalize handler

`POST /finalize`:

1. authenticate request
2. lock session row
3. store `expected_chunk_count`
4. inspect live chunk completeness
5. choose one path:
   - complete live chunk path -> `selected_final_input_mode = live_chunks`
   - incomplete live path + full audio exists -> `selected_final_input_mode = full_audio_fallback`
   - incomplete live path + no full audio -> return `awaiting_fallback` / `409`
6. move session to `finalizing`
7. enqueue missing internal work if fallback split is required
8. return accepted state

### Server worker logic

The first release can use a single background worker process that loops over eligible sessions/chunks.

#### Worker queue selection

Worker should select:

- sessions not in terminal state
- chunks with `process_status = pending`
- ordered by:
  1. session priority
  2. `chunk_index`
  3. creation time

#### Chunk processing algorithm

For each selected chunk:

1. mark chunk `processing`
2. load all committed `SpeakerAnchor` rows ordered by `anchor_order`
3. generate temporary prefixed audio:
   - concatenate anchors
   - insert silence separators
   - append real chunk audio
4. generate prefix manifest JSON
5. call model endpoint
6. parse raw segments
7. detect dominant speaker labels inside each anchor region
8. derive transient-label -> `speaker_key` mapping
9. strip prefix-only segments
10. discard boundary-crossing segments
11. remap retained real-chunk segments to absolute meeting timestamps
12. upsert any newly qualified `SpeakerAnchor` records discovered in this chunk
13. write `TranscriptSegment` rows for retained segments
14. mark chunk `completed`

#### Commit ordering rule

Even if a chunk is transcribed early, durable speaker state and final transcript order should only advance if all lower chunk indexes are already committed.

Recommended durable commit flow:

```text
process chunk result in memory
  -> open DB transaction
  -> lock session row
  -> verify chunk_index == last_committed_chunk_index + 1
  -> persist new anchors
  -> persist final transcript segments for this chunk
  -> set last_committed_chunk_index = chunk_index
  -> commit transaction
```

If `chunk_index` is ahead of the current commit frontier:

- keep the parsed result in durable chunk/run tables
- retry final commit later after earlier chunks are committed

### Fallback full-audio internal split logic

If finalization selects `full_audio_fallback`, the server should:

1. load the fallback full audio artifact
2. cut it into 5 minute internal chunks using the same configured overlap
3. insert `session_chunks` with `source_type = server_split_from_full_audio`
4. mark live chunk path as non-final for transcript assembly
5. run normal chunk processing over the fallback split chunks

This guarantees one unified processing pipeline even though ingestion differed.

### Final transcript assembly logic

When session reaches `finalizing` and all chosen-path chunks are committed:

1. fetch `TranscriptSegment` rows where `is_final = true`
2. order by `start_ms`, then `sequence`
3. perform overlap dedupe pass
4. normalize final speaker labels for response
5. concatenate `full_text`
6. mark session `completed`

Recommended overlap dedupe rule:

- if two adjacent final segments overlap slightly and one text is contained within the other, merge them
- prefer the longer text span
- preserve the more specific non-unknown speaker label

### Server restart recovery logic

At worker startup:

1. scan for sessions in `processing`, `awaiting_finalize`, or `finalizing`
2. scan for chunks in `processing` without `processing_completed_at`
3. reset stranded chunk rows back to `pending`
4. resume queue processing

At API startup:

- read-only polling should continue to work against persisted DB state even before workers catch up

### Recommended local persistence on macOS

To support restart recovery, the client should persist a lightweight session ledger, for example in app support storage:

- `remote_session_id`
- `client_session_token`
- `meeting_record_id` if already created
- `full_audio_local_path`
- array of chunks:
  - `chunk_index`
  - `start_ms`
  - `end_ms`
  - `local_file_path`
  - `sha256`
  - `upload_status`
- `finalize_requested`
- `selected_strategy`

This ledger is enough to reconstruct retry/fallback decisions after a crash or restart.

## Speaker anchor mechanism

The speaker-stability design is based on a server-side "speaker anchor prefix" strategy.

### Why anchors are needed

Hard chunk boundaries can cause the model to relabel speakers inconsistently from one chunk to the next. To reduce that drift, the server prepends one representative anchor utterance per already-known speaker before transcribing later chunks.

### Anchor selection

Each speaker should contribute one **qualified first utterance**, not just the first raw segment seen.

Recommended qualification rules:

- Taken from the speaker’s first appearance chunk.
- Prefer the first complete utterance attributed to that speaker.
- Target duration range: **1.5s to 8s**, with a preference for **2s to 6s**.
- Text must not be only a filler phrase like “嗯”, “啊”, “好”, “对”.
- Avoid anchors too close to the chunk end; require at least about **2s** of margin from the chunk boundary.
- When slicing the anchor audio, include padding: about **200ms pre-roll** and **300ms post-roll**.

If the earliest utterance is too weak or too boundary-adjacent, delay anchor creation until the first qualified utterance appears later.

### Prefix composition

When processing chunk `N`, construct a temporary audio file:

`[speaker1 anchor][500ms silence][speaker2 anchor][500ms silence]...[800ms silence][real chunk audio]`

Rules:

- Anchors are ordered by speaker first appearance (`anchor_order`).
- Insert **500ms silence** between anchors.
- Insert a stronger **800ms silence** boundary between the anchor prefix and the real chunk.

### Keep chunk overlap as well

In addition to speaker anchors, keep a real chunk overlap of about **2s to 3s** between adjacent chunks. The overlap handles speech continuity and hard-cut losses; anchors handle speaker identity continuity. They solve different problems and should coexist.

### Prefix manifest

When the server constructs the prefixed temporary audio, it must also create a precise manifest with:

- each anchor’s `start_ms` / `end_ms` within the temporary file
- `prefix_total_ms`
- `real_chunk_offset_ms`

This manifest is required for later segment stripping and label remapping.

### Result stripping

After transcription returns:

- Segments fully inside the anchor prefix are **not** final transcript content.
- Segments fully inside the real chunk are retained.
- Segments crossing the prefix/real boundary are discarded and allowed to be recovered by real chunk overlap.

Recommended rules using a 200ms guard band:

- If `segment.end_ms <= real_chunk_offset_ms - 200`, treat it as prefix-only and drop it from final transcript content.
- If `segment.start_ms >= real_chunk_offset_ms + 200`, treat it as real-chunk content and keep it.
- If the segment crosses the boundary guard band, discard it.

### Timestamp remapping

For retained real chunk segments:

- `absolute_start_ms = chunk.start_ms + (segment.start_ms - real_chunk_offset_ms)`
- `absolute_end_ms = chunk.start_ms + (segment.end_ms - real_chunk_offset_ms)`

This preserves the original meeting timeline and removes any time shift introduced by prefixing.

### Speaker label remapping

Prefix anchors are not only for audio conditioning; they are also used to infer a stable speaker mapping.

For each anchor region in the manifest:

1. Inspect which model speaker label dominates that anchor’s returned segment(s).
2. Map that transient model label back to the server’s persisted `speaker_key`.
3. Apply the resulting label remap to the real chunk segments.

Example:

- Anchor for persisted `speaker_A` is labeled by the model as `Speaker 2` in this transcription pass.
- Then any real chunk segment labeled `Speaker 2` should be remapped to `speaker_A`.

This is the core mechanism that keeps a real person’s identity stable across chunks even if the raw model speaker IDs drift.

## Error recovery

### Client upload failure

- Mark the failed live chunk locally.
- Do not interrupt recording.
- Continue chunk sealing and local full-audio preservation.
- On stop, if the session is incomplete, upload the full meeting audio and proceed through fallback.

### Server chunk processing failure

- Mark chunk `failed` with error details.
- Retry automatically a bounded number of times (recommend 2–3).
- If retries still fail and full audio fallback exists, allow the session to switch to fallback finalization.
- If no fallback path exists, mark the session failed.

### Restart recovery

Client persists:

- `session_id`
- local chunk metadata and upload state
- final full-audio path

Server persists:

- session
- chunk
- speaker anchor
- transcript segment state

After restart:

- Client can resume uploads/fallback/finalize.
- Server workers can resume `pending` or interrupted processing.

## Idempotency rules

### Session creation

- Client sends a stable `client_session_token`.
- Server returns the same `session_id` on repeated create attempts with the same token.

### Chunk upload

Idempotency key:

- `session_id + chunk_index + sha256`

Rules:

- same index + same hash => safe retry, return success
- same index + different hash => conflict

### Full audio upload

Idempotency key:

- `session_id + full_audio_sha256`

Repeat uploads of the exact same fallback audio should reuse the stored artifact.

### Finalize

- `finalize` must be repeat-safe.
- If already processing, return processing state.
- If already completed, return completed state.
- If already failed, return failed state and reason.

## Testing strategy

### Unit tests

Cover:

- chunk ordering rules
- prefix manifest generation
- qualified anchor selection
- anchor prefix stripping rules
- timestamp remapping
- overlap dedupe
- speaker label remapping

### Server integration tests

Cover:

- create session idempotency
- chunk upload idempotency/conflict behavior
- finalize while chunks are incomplete
- fallback full-audio completion path
- recovery after simulated service restart

### Client integration tests

Cover:

- chunk sealing triggers upload attempts
- failed chunk upload triggers fallback at stop time
- polling completed remote result writes correct local meeting state

### End-to-end regression tests

Use representative recordings for:

- single speaker long-form audio
- two-speaker alternating dialogue
- rapid interruptions
- speaker changes near chunk boundaries
- interrupted upload followed by fallback recovery

Validate:

- final time order
- reduced speaker drift
- no prefix-anchor transcript pollution
- reliable completion through fallback

## Success criteria for v1

- Under normal networking, chunks upload during recording and server processing begins before stop.
- When recording stops, the session finalizes into a complete transcript without requiring the user to retry recording.
- If live upload becomes incomplete, full-audio fallback succeeds and still produces a final transcript.
- Speaker labels drift less across chunk boundaries than the current hard-cut-only behavior.
- Client and server restarts do not force the user to abandon the meeting transcript session.

## Implementation notes for planning

For the next planning step, prefer:

1. Carving the current meeting transcription flow into recorder artifact production vs remote session orchestration.
2. Introducing a thin server HTTP client on macOS before deeper local UI changes.
3. Reusing the existing chunk/overlap logic concepts from `VibeVoiceRunnerClient` where possible, but moving orchestration and speaker-state persistence to the server.
4. Keeping the first server release single-worker and polling-based to reduce rollout risk.
