# Meeting Transcription Server Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a recoverable server-backed meeting transcription pipeline that uploads 5-minute chunks during recording, falls back to full-audio upload when needed, and preserves stable speakers across chunks with anchor-prefix processing.

**Architecture:** Keep the existing meeting UI and recording flow, but replace post-stop direct VibeVoice transcription with a remote session orchestration flow. Add a Python/FastAPI service with PostgreSQL-backed session state, chunk state, speaker anchors, and worker-based transcription processing, while Swift owns recording, chunk sealing, upload recovery, polling, and local meeting persistence.

**Tech Stack:** Swift, SwiftUI, AVFoundation, ScreenCaptureKit, XCTest, Python 3, FastAPI, SQLAlchemy, Alembic, PostgreSQL, pytest

---

## Assumptions

- The server code will live in this repository under `server/meeting_transcription/`.
- The first release uses one FastAPI process plus one in-process background worker loop; no external queue is required.
- The existing `MeetingVibeVoiceConfig` remains the configuration entry point on macOS and will be extended to target the new server APIs.
- The existing direct `VibeVoiceRunnerClient` remains useful for model request construction logic, but session orchestration and speaker-state persistence move to the server.
- The generic dictation path (`TranscriptionService/WhisperEngine`) stays untouched.

## File Structure

### Create

- `server/meeting_transcription/__init__.py`
  Python package marker.
- `server/meeting_transcription/app.py`
  FastAPI app composition and route registration.
- `server/meeting_transcription/config.py`
  Environment-driven server settings.
- `server/meeting_transcription/db.py`
  SQLAlchemy engine/session setup.
- `server/meeting_transcription/models.py`
  ORM models for sessions, chunks, anchors, transcript segments, and processing runs.
- `server/meeting_transcription/schemas.py`
  Pydantic request/response models.
- `server/meeting_transcription/storage.py`
  Audio/blob storage abstraction for local disk-backed artifacts.
- `server/meeting_transcription/repositories.py`
  Data access helpers for sessions, chunks, anchors, and transcript rows.
- `server/meeting_transcription/audio_chunks.py`
  Server-side chunk splitting and overlap helpers for fallback full-audio flow.
- `server/meeting_transcription/anchor_audio.py`
  Anchor selection, prefix composition, manifest generation, and timestamp remapping.
- `server/meeting_transcription/transcriber.py`
  Adapter from server worker to model request execution.
- `server/meeting_transcription/worker.py`
  Chunk selection loop, processing orchestration, commit ordering, and recovery.
- `server/meeting_transcription/routes.py`
  Session create/upload/finalize/status routes.
- `server/meeting_transcription/errors.py`
  Structured API error codes.
- `server/alembic.ini`
  Alembic configuration.
- `server/alembic/env.py`
  Alembic environment.
- `server/alembic/versions/20260420_01_create_meeting_transcription_tables.py`
  Initial schema migration.
- `server/tests/test_session_routes.py`
  API contract tests for create/upload/finalize/status.
- `server/tests/test_worker_processing.py`
  Worker processing and commit-order tests.
- `server/tests/test_anchor_audio.py`
  Anchor selection, prefix stripping, and label-remap tests.
- `server/tests/conftest.py`
  Test fixtures for app, DB, and storage.
- `server/requirements.txt`
  Python dependencies.
- `server/README.md`
  Server run/test instructions.
- `NeuType/Meetings/Recorder/MeetingRecordingArtifact.swift`
  Strongly typed recorder output events for chunks and final full audio.
- `NeuType/Meetings/Recorder/MeetingChunkSealer.swift`
  Rolling 5-minute chunk sealing helper for meeting recording.
- `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift`
  Codable request/response models for remote session APIs.
- `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionClient.swift`
  Swift HTTP client for create/upload/finalize/status calls.
- `NeuType/Meetings/Transcription/MeetingUploadLedger.swift`
  Local persisted ledger of chunk uploads, fallback strategy, and restart recovery.
- `NeuType/Meetings/Transcription/MeetingRemoteSessionCoordinator.swift`
  Stateful orchestration layer for session lifecycle, upload queue, fallback, and polling.
- `NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift`
- `NeuTypeTests/MeetingUploadLedgerTests.swift`
- `NeuTypeTests/MeetingRemoteSessionCoordinatorTests.swift`
- `NeuTypeTests/MeetingChunkSealerTests.swift`

### Modify

- `NeuType/Meetings/Recorder/MeetingRecorder.swift`
  Emit sealed chunks during recording while still producing final full audio.
- `NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift`
  Replace direct post-stop transcription with remote session orchestration and polling.
- `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
  Re-scope into remote orchestration entry point for meeting recording.
- `NeuType/Meetings/Transcription/MeetingVibeVoiceConfig.swift`
  Add remote session endpoint helpers and server auth reuse.
- `NeuType/Meetings/Transcription/MeetingTranscriptionProgress.swift`
  Add progress messaging for upload, fallback, polling, and finalization.
- `NeuType/Settings.swift`
  Add server endpoint/API key settings if any are missing for the new session service.
- `NeuType/Utils/AppPreferences.swift`
  Persist remote service base URL, auth token, and any polling/upload tuning values.
- `NeuTypeTests/MeetingRecorderViewModelTests.swift`
  Update to assert remote session flow instead of direct local transcription.
- `NeuTypeTests/MeetingTranscriptionServiceTests.swift`
  Update to cover remote-service-backed behavior or reduce to thin entry-point tests.
- `NeuType.xcodeproj/project.pbxproj`
  Add new Swift sources and tests.
- `docs/superpowers/specs/2026-04-20-meeting-transcription-server-upgrade-design.md`
  Reference implementation follow-ups only if plan-driven clarifications are needed.

## Task 1: Scaffold the Python server package and dependency entrypoints

**Files:**
- Create: `server/meeting_transcription/__init__.py`
- Create: `server/meeting_transcription/app.py`
- Create: `server/meeting_transcription/config.py`
- Create: `server/meeting_transcription/errors.py`
- Create: `server/requirements.txt`
- Create: `server/README.md`
- Test: `server/tests/test_session_routes.py`

- [ ] **Step 1: Write the failing route smoke test**

```python
from fastapi.testclient import TestClient
from meeting_transcription.app import create_app


def test_health_route_and_session_routes_exist():
    client = TestClient(create_app())

    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    assert "/api/meeting-transcription/sessions" in paths
    assert "/api/meeting-transcription/sessions/{session_id}" in paths
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && pytest tests/test_session_routes.py::test_health_route_and_session_routes_exist -q`
Expected: FAIL because the `meeting_transcription` package and app do not exist yet.

- [ ] **Step 3: Implement the minimal FastAPI app scaffold**

```python
from fastapi import FastAPI


def create_app() -> FastAPI:
    app = FastAPI(title="Meeting Transcription Service")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && pytest tests/test_session_routes.py::test_health_route_and_session_routes_exist -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/__init__.py server/meeting_transcription/app.py server/meeting_transcription/config.py server/meeting_transcription/errors.py server/requirements.txt server/README.md server/tests/test_session_routes.py
git commit -m "feat: scaffold meeting transcription server"
```

## Task 2: Add persistent server schema and storage abstraction

**Files:**
- Create: `server/meeting_transcription/db.py`
- Create: `server/meeting_transcription/models.py`
- Create: `server/meeting_transcription/storage.py`
- Create: `server/alembic.ini`
- Create: `server/alembic/env.py`
- Create: `server/alembic/versions/20260420_01_create_meeting_transcription_tables.py`
- Test: `server/tests/test_session_routes.py`

- [ ] **Step 1: Write the failing persistence test**

```python
from meeting_transcription.models import TranscriptionSession, SessionChunk


def test_schema_persists_session_and_chunk(db_session):
    session = TranscriptionSession(
        session_id="mts_test",
        client_session_token="token-1",
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
    )
    db_session.add(session)
    db_session.flush()

    chunk = SessionChunk(
        session_id=session.id,
        chunk_index=0,
        source_type="live_chunk",
        start_ms=0,
        end_ms=300000,
        duration_ms=300000,
        sha256="abc",
        storage_path="sessions/mts_test/live-chunks/0.wav",
        upload_status="uploaded",
        process_status="pending",
    )
    db_session.add(chunk)
    db_session.commit()

    assert chunk.id is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && pytest tests/test_session_routes.py::test_schema_persists_session_and_chunk -q`
Expected: FAIL because the database models and fixtures do not exist.

- [ ] **Step 3: Implement SQLAlchemy models, DB session setup, and first migration**

```python
class TranscriptionSession(Base):
    __tablename__ = "transcription_sessions"

    id = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid4)
    session_id = mapped_column(String, unique=True, nullable=False)
    client_session_token = mapped_column(String, unique=True, nullable=False)
    status = mapped_column(String, nullable=False)
    input_mode = mapped_column(String, nullable=False)
```

```python
class SessionChunk(Base):
    __tablename__ = "session_chunks"

    id = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid4)
    session_id = mapped_column(ForeignKey("transcription_sessions.id"), nullable=False)
    chunk_index = mapped_column(Integer, nullable=False)
    source_type = mapped_column(String, nullable=False)
    sha256 = mapped_column(String, nullable=False)
```

- [ ] **Step 4: Run tests and migration smoke check**

Run: `cd server && pytest tests/test_session_routes.py::test_schema_persists_session_and_chunk -q`
Expected: PASS.

Run: `cd server && alembic upgrade head`
Expected: migration applies cleanly.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/db.py server/meeting_transcription/models.py server/meeting_transcription/storage.py server/alembic.ini server/alembic/env.py server/alembic/versions/20260420_01_create_meeting_transcription_tables.py server/tests/test_session_routes.py
git commit -m "feat: add meeting transcription server schema"
```

## Task 3: Implement session create/upload/finalize/status APIs with idempotency

**Files:**
- Create: `server/meeting_transcription/schemas.py`
- Create: `server/meeting_transcription/repositories.py`
- Create: `server/meeting_transcription/routes.py`
- Modify: `server/meeting_transcription/app.py`
- Test: `server/tests/test_session_routes.py`

- [ ] **Step 1: Write the failing API contract tests**

```python
def test_create_session_is_idempotent(client):
    payload = {
        "client_session_token": "token-1",
        "source": "neutype-macos",
        "chunk_duration_ms": 300000,
        "chunk_overlap_ms": 2500,
        "audio_format": "wav",
        "sample_rate_hz": 16000,
        "channel_count": 1,
    }

    first = client.post("/api/meeting-transcription/sessions", json=payload)
    second = client.post("/api/meeting-transcription/sessions", json=payload)

    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["data"]["session_id"] == second.json()["data"]["session_id"]
```

```python
def test_chunk_upload_rejects_same_index_different_hash(client, created_session, wav_file):
    first = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", wav_file, "audio/wav")},
        data={"start_ms": 0, "end_ms": 300000, "sha256": "hash-a", "mime_type": "audio/wav", "file_size_bytes": 128},
    )
    second = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", wav_file, "audio/wav")},
        data={"start_ms": 0, "end_ms": 300000, "sha256": "hash-b", "mime_type": "audio/wav", "file_size_bytes": 128},
    )

    assert first.status_code == 201
    assert second.status_code == 409
```

- [ ] **Step 2: Run API tests to verify they fail**

Run: `cd server && pytest tests/test_session_routes.py -q`
Expected: FAIL because the route layer and repository logic are incomplete.

- [ ] **Step 3: Implement route handlers, repository helpers, and response envelope**

```python
@router.post("/api/meeting-transcription/sessions", response_model=Envelope[CreateSessionResponse])
def create_session(payload: CreateSessionRequest, db: Session = Depends(get_db)):
    session = repositories.create_or_get_session(db, payload)
    status_code = status.HTTP_200_OK if session.reused else status.HTTP_201_CREATED
    return JSONResponse(status_code=status_code, content=envelope(session.response_model()))
```

```python
@router.put("/api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}")
def upload_chunk(...):
    repositories.store_live_chunk(...)
```

- [ ] **Step 4: Run API tests to verify they pass**

Run: `cd server && pytest tests/test_session_routes.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/schemas.py server/meeting_transcription/repositories.py server/meeting_transcription/routes.py server/meeting_transcription/app.py server/tests/test_session_routes.py
git commit -m "feat: add meeting transcription session APIs"
```

## Task 4: Implement server chunk worker, fallback splitting, and recovery loop

**Files:**
- Create: `server/meeting_transcription/audio_chunks.py`
- Create: `server/meeting_transcription/transcriber.py`
- Create: `server/meeting_transcription/worker.py`
- Modify: `server/meeting_transcription/repositories.py`
- Test: `server/tests/test_worker_processing.py`

- [ ] **Step 1: Write the failing worker sequencing tests**

```python
def test_worker_only_commits_next_chunk_in_order(worker_harness):
    session = worker_harness.seed_session_with_chunks(indexes=[0, 1])
    worker_harness.seed_processed_result(session, chunk_index=1)
    worker_harness.run_once()

    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.last_committed_chunk_index == -1
```

```python
def test_finalize_uses_fallback_split_when_live_chunks_missing(worker_harness, full_audio_file):
    session = worker_harness.seed_session_with_missing_live_chunks()
    worker_harness.attach_full_audio(session, full_audio_file)

    worker_harness.finalize(session.session_id)
    worker_harness.run_until_idle()

    refreshed = worker_harness.fetch_session(session.session_id)
    assert refreshed.selected_final_input_mode == "full_audio_fallback"
```

- [ ] **Step 2: Run worker tests to verify they fail**

Run: `cd server && pytest tests/test_worker_processing.py -q`
Expected: FAIL because the worker loop and fallback split logic do not exist.

- [ ] **Step 3: Implement the worker loop and fallback splitter**

```python
def run_pending_chunk_once(db: Session, transcriber: ChunkTranscriber) -> bool:
    chunk = repositories.next_pending_chunk(db)
    if chunk is None:
        return False
    process_chunk(db, chunk, transcriber)
    return True
```

```python
def split_full_audio_into_chunks(audio_path: str, chunk_duration_ms: int, overlap_ms: int) -> list[SplitChunk]:
    ...
```

- [ ] **Step 4: Run worker tests to verify they pass**

Run: `cd server && pytest tests/test_worker_processing.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/audio_chunks.py server/meeting_transcription/transcriber.py server/meeting_transcription/worker.py server/meeting_transcription/repositories.py server/tests/test_worker_processing.py
git commit -m "feat: add meeting transcription worker pipeline"
```

## Task 5: Implement anchor selection, prefix manifests, stripping, and speaker remapping

**Files:**
- Create: `server/meeting_transcription/anchor_audio.py`
- Modify: `server/meeting_transcription/worker.py`
- Test: `server/tests/test_anchor_audio.py`
- Test: `server/tests/test_worker_processing.py`

- [ ] **Step 1: Write the failing anchor logic tests**

```python
def test_select_first_qualified_anchor_skips_short_filler_segment():
    segments = [
        Segment(text="嗯", start_ms=0, end_ms=300, speaker_label="Speaker 1"),
        Segment(text="我们开始今天的周会", start_ms=500, end_ms=3600, speaker_label="Speaker 1"),
    ]

    anchor = select_anchor_candidate(segments, chunk_end_ms=300000)

    assert anchor.text == "我们开始今天的周会"
```

```python
def test_strip_prefix_segments_discards_boundary_crossing_rows():
    manifest = PrefixManifest(real_chunk_offset_ms=4000)
    segments = [
        Segment(text="anchor", start_ms=0, end_ms=1000, speaker_label="Speaker 1"),
        Segment(text="crossing", start_ms=3900, end_ms=4200, speaker_label="Speaker 1"),
        Segment(text="real", start_ms=4300, end_ms=5000, speaker_label="Speaker 2"),
    ]

    kept = strip_prefix_segments(segments, manifest, guard_band_ms=200)

    assert [segment.text for segment in kept] == ["real"]
```

- [ ] **Step 2: Run anchor tests to verify they fail**

Run: `cd server && pytest tests/test_anchor_audio.py -q`
Expected: FAIL because the anchor helper module does not exist.

- [ ] **Step 3: Implement anchor qualification and remapping helpers**

```python
def remap_real_chunk_segments(segments: list[Segment], label_map: dict[str, str], chunk_start_ms: int, real_chunk_offset_ms: int) -> list[Segment]:
    remapped = []
    for segment in segments:
        absolute_start = chunk_start_ms + (segment.start_ms - real_chunk_offset_ms)
        absolute_end = chunk_start_ms + (segment.end_ms - real_chunk_offset_ms)
        remapped.append(segment.copy_with(start_ms=absolute_start, end_ms=absolute_end, speaker_key=label_map.get(segment.speaker_label)))
    return remapped
```

- [ ] **Step 4: Run anchor and worker tests to verify they pass**

Run: `cd server && pytest tests/test_anchor_audio.py tests/test_worker_processing.py -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/meeting_transcription/anchor_audio.py server/meeting_transcription/worker.py server/tests/test_anchor_audio.py server/tests/test_worker_processing.py
git commit -m "feat: add speaker anchor processing"
```

## Task 6: Add Swift remote API models and HTTP client

**Files:**
- Create: `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift`
- Create: `NeuType/Meetings/Transcription/MeetingRemoteTranscriptionClient.swift`
- Modify: `NeuType/Meetings/Transcription/MeetingVibeVoiceConfig.swift`
- Modify: `NeuType/Utils/AppPreferences.swift`
- Modify: `NeuType/Settings.swift`
- Test: `NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing client contract tests**

```swift
func testCreateSessionReusesMeetingServerConfig() async throws {
    let session = URLSession.stub(json: [
        "request_id": "req_1",
        "data": [
            "session_id": "mts_123",
            "status": "created",
            "input_mode": "live_chunks",
            "chunk_duration_ms": 300000,
            "chunk_overlap_ms": 2500,
        ],
        "error": NSNull()
    ])
    let client = MeetingRemoteTranscriptionClient(session: session, configProvider: StubMeetingServerConfigProvider())

    let response = try await client.createSession(.fixture())

    XCTAssertEqual(response.sessionID, "mts_123")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests`
Expected: `** TEST FAILED **` because the remote models/client do not exist.

- [ ] **Step 3: Implement Codable request/response types and the HTTP client**

```swift
struct CreateMeetingTranscriptionSessionRequest: Codable {
    let clientSessionToken: String
    let clientMeetingID: UUID?
    let source: String
    let chunkDurationMS: Int
    let chunkOverlapMS: Int
}
```

```swift
final class MeetingRemoteTranscriptionClient {
    func createSession(_ request: CreateMeetingTranscriptionSessionRequest) async throws -> CreateMeetingTranscriptionSessionResponse {
        ...
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Transcription/MeetingRemoteTranscriptionModels.swift NeuType/Meetings/Transcription/MeetingRemoteTranscriptionClient.swift NeuType/Meetings/Transcription/MeetingVibeVoiceConfig.swift NeuType/Utils/AppPreferences.swift NeuType/Settings.swift NeuTypeTests/MeetingRemoteTranscriptionClientTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: add meeting remote transcription client"
```

## Task 7: Add the local upload ledger and remote session coordinator

**Files:**
- Create: `NeuType/Meetings/Transcription/MeetingUploadLedger.swift`
- Create: `NeuType/Meetings/Transcription/MeetingRemoteSessionCoordinator.swift`
- Modify: `NeuType/Meetings/Transcription/MeetingTranscriptionService.swift`
- Test: `NeuTypeTests/MeetingUploadLedgerTests.swift`
- Test: `NeuTypeTests/MeetingRemoteSessionCoordinatorTests.swift`

- [ ] **Step 1: Write the failing ledger and coordinator tests**

```swift
func testLedgerMarksChunkFailureAndRequiresFallback() throws {
    let ledger = MeetingUploadLedger.inMemory()
    try ledger.recordChunk(.init(index: 0, startMS: 0, endMS: 300000, sha256: "a", localFilePath: "/tmp/0.wav"))
    try ledger.markChunkUploadFailed(index: 0)

    XCTAssertTrue(ledger.requiresFullAudioFallback)
}
```

```swift
func testCoordinatorUploadsFallbackWhenChunksAreMissing() async throws {
    let client = StubMeetingRemoteTranscriptionClient()
    let ledger = MeetingUploadLedger.inMemory()
    let coordinator = MeetingRemoteSessionCoordinator(client: client, ledger: ledger)

    try ledger.recordChunk(.fixture(index: 0))
    try ledger.markChunkUploadFailed(index: 0)

    try await coordinator.finalizeWithRecording(fullAudioURL: URL(fileURLWithPath: "/tmp/meeting.wav"), expectedChunkCount: 1)

    XCTAssertEqual(client.uploadFullAudioCalls, 1)
    XCTAssertEqual(client.finalizeCalls, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingUploadLedgerTests -only-testing:NeuTypeTests/MeetingRemoteSessionCoordinatorTests`
Expected: `** TEST FAILED **` because the ledger and coordinator do not exist.

- [ ] **Step 3: Implement local persistence and orchestration logic**

```swift
struct MeetingUploadChunkRecord: Codable, Equatable {
    let index: Int
    let startMS: Int
    let endMS: Int
    let sha256: String
    let localFilePath: String
    var uploadStatus: UploadStatus
}
```

```swift
final class MeetingRemoteSessionCoordinator {
    func handleSealedChunk(_ artifact: MeetingRecordingChunkArtifact) async
    func finalizeWithRecording(fullAudioURL: URL, expectedChunkCount: Int) async throws
    func pollUntilCompleted() async throws -> RemoteMeetingTranscriptResult
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingUploadLedgerTests -only-testing:NeuTypeTests/MeetingRemoteSessionCoordinatorTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Transcription/MeetingUploadLedger.swift NeuType/Meetings/Transcription/MeetingRemoteSessionCoordinator.swift NeuType/Meetings/Transcription/MeetingTranscriptionService.swift NeuTypeTests/MeetingUploadLedgerTests.swift NeuTypeTests/MeetingRemoteSessionCoordinatorTests.swift
git commit -m "feat: add meeting remote session coordinator"
```

## Task 8: Add rolling chunk sealing to the recorder and wire the meeting view model to the remote pipeline

**Files:**
- Create: `NeuType/Meetings/Recorder/MeetingRecordingArtifact.swift`
- Create: `NeuType/Meetings/Recorder/MeetingChunkSealer.swift`
- Modify: `NeuType/Meetings/Recorder/MeetingRecorder.swift`
- Modify: `NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift`
- Modify: `NeuType/Meetings/Transcription/MeetingTranscriptionProgress.swift`
- Modify: `NeuTypeTests/MeetingRecorderViewModelTests.swift`
- Create: `NeuTypeTests/MeetingChunkSealerTests.swift`
- Modify: `NeuType.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing recorder/view-model tests**

```swift
func testChunkSealerEmitsFiveMinuteArtifact() throws {
    let sealer = MeetingChunkSealer(chunkDuration: 300, overlapDuration: 2.5)
    let artifacts = try sealer.sealChunksIfNeeded(totalDuration: 301, sourceURL: temporaryAudioURL())

    XCTAssertEqual(artifacts.map(\.chunkIndex), [0])
    XCTAssertEqual(artifacts.first?.startMS, 0)
    XCTAssertEqual(artifacts.first?.endMS, 300000)
}
```

```swift
@MainActor
func testStopRecordingUsesRemoteCoordinatorInsteadOfDirectTranscribe() async throws {
    let recorder = StubMeetingRecorder(stopRecordingURL: temporaryAudioURL())
    let coordinator = StubMeetingRemoteSessionCoordinator()
    let store = try MeetingRecordStore.inMemory()
    let viewModel = MeetingRecorderViewModel(
        permissions: StubMeetingPermissions(microphoneGranted: true, screenGranted: true),
        recorder: recorder,
        store: store,
        transcriptionService: MeetingTranscriptionService(coordinator: coordinator),
        summaryService: StubMeetingSummaryService()
    )

    await viewModel.startRecording()
    await viewModel.stopRecording()

    XCTAssertEqual(coordinator.finalizeCalls, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingChunkSealerTests -only-testing:NeuTypeTests/MeetingRecorderViewModelTests`
Expected: `** TEST FAILED **` because the recorder artifacts and remote coordinator wiring do not exist.

- [ ] **Step 3: Implement chunk sealing and remote wiring**

```swift
enum MeetingRecordingArtifact {
    case sealedChunk(MeetingRecordingChunkArtifact)
    case finalAudio(MeetingRecordingFinalAudioArtifact)
}
```

```swift
final class MeetingChunkSealer {
    func sealChunksIfNeeded(totalDuration: TimeInterval, sourceURL: URL) throws -> [MeetingRecordingChunkArtifact] {
        ...
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingChunkSealerTests -only-testing:NeuTypeTests/MeetingRecorderViewModelTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NeuType/Meetings/Recorder/MeetingRecordingArtifact.swift NeuType/Meetings/Recorder/MeetingChunkSealer.swift NeuType/Meetings/Recorder/MeetingRecorder.swift NeuType/Meetings/ViewModels/MeetingRecorderViewModel.swift NeuType/Meetings/Transcription/MeetingTranscriptionProgress.swift NeuTypeTests/MeetingChunkSealerTests.swift NeuTypeTests/MeetingRecorderViewModelTests.swift NeuType.xcodeproj/project.pbxproj
git commit -m "feat: wire meeting recording to remote transcription sessions"
```

## Task 9: Finish integration, regression coverage, and operational docs

**Files:**
- Modify: `server/README.md`
- Modify: `NeuTypeTests/MeetingTranscriptionServiceTests.swift`
- Modify: `server/tests/test_session_routes.py`
- Modify: `server/tests/test_worker_processing.py`
- Modify: `server/tests/test_anchor_audio.py`
- Modify: `docs/superpowers/specs/2026-04-20-meeting-transcription-server-upgrade-design.md` (only if implementation discovers a real spec gap)

- [ ] **Step 1: Write the failing end-to-end orchestration tests**

```python
def test_completed_session_status_returns_full_text_and_segments(client, processed_session):
    response = client.get(f"/api/meeting-transcription/sessions/{processed_session.session_id}")

    assert response.status_code == 200
    assert response.json()["data"]["status"] == "completed"
    assert response.json()["data"]["segments"][0]["speaker_label"] == "Speaker 1"
```

```swift
func testMeetingTranscriptionServiceWritesRemoteResultIntoStore() async throws {
    let store = try MeetingRecordStore.inMemory()
    let meeting = MeetingRecord.fixture(status: .processing)
    try await store.insertMeeting(meeting, segments: [])
    let coordinator = StubMeetingRemoteSessionCoordinator(result: .fixture())
    let service = MeetingTranscriptionService(coordinator: coordinator, store: store)

    try await service.transcribe(meetingID: meeting.id, audioURL: URL(fileURLWithPath: "/tmp/demo.wav"))

    let saved = try await store.fetchMeeting(id: meeting.id)
    XCTAssertEqual(saved?.status, .completed)
}
```

- [ ] **Step 2: Run regression tests to verify they fail**

Run: `cd server && pytest tests/test_session_routes.py tests/test_worker_processing.py tests/test_anchor_audio.py -q`
Expected: at least one FAIL before the final integration fixes land.

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests -only-testing:NeuTypeTests/MeetingRecorderViewModelTests`
Expected: at least one FAIL before final integration fixes land.

- [ ] **Step 3: Implement the final integration fixes and docs**

```text
- ensure polling completion updates MeetingRecordStore
- ensure failed remote sessions surface transcriptPreview errors
- document server setup, migration, and test commands in server/README.md
```

- [ ] **Step 4: Run the focused test suites to verify they pass**

Run: `cd server && pytest tests/test_session_routes.py tests/test_worker_processing.py tests/test_anchor_audio.py -q`
Expected: all PASS.

Run: `xcodebuild test -project NeuType.xcodeproj -scheme NeuType -destination 'platform=macOS' -only-testing:NeuTypeTests/MeetingRemoteTranscriptionClientTests -only-testing:NeuTypeTests/MeetingUploadLedgerTests -only-testing:NeuTypeTests/MeetingRemoteSessionCoordinatorTests -only-testing:NeuTypeTests/MeetingChunkSealerTests -only-testing:NeuTypeTests/MeetingRecorderViewModelTests -only-testing:NeuTypeTests/MeetingTranscriptionServiceTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add server/README.md server/tests/test_session_routes.py server/tests/test_worker_processing.py server/tests/test_anchor_audio.py NeuTypeTests/MeetingTranscriptionServiceTests.swift
git commit -m "test: finalize meeting transcription server integration"
```

## Validation Checklist

- [ ] Live chunk uploads are idempotent and hash-conflict-safe.
- [ ] Full-audio fallback works when any live chunk is missing.
- [ ] Server restart resets stranded `processing` rows back to `pending`.
- [ ] Anchor prefix stripping never leaks prefix text into final transcript rows.
- [ ] Speaker remapping uses anchor regions instead of trusting raw transient speaker labels.
- [ ] macOS restart recovery can resume polling or trigger fallback upload.
- [ ] Final meeting transcript is stored in `MeetingRecordStore` without changing local playback audio.
