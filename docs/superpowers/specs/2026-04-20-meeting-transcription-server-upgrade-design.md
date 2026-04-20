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
