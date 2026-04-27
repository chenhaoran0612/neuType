# Meeting Transcription Server

FastAPI service for NeuType meeting transcription. The macOS client streams 5-minute WAV chunks as they are sealed, uploads the final full recording for fallback, then polls this service until the transcript is complete.

## Runtime model

- **Client session**: `POST /api/meeting-transcription/sessions` creates or resumes a server session by `client_session_token`.
- **Live chunks**: `PUT /api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}` stores idempotent live chunk uploads. Replays with identical bytes return `200`; hash conflicts return `409`.
- **Full-audio fallback**: `PUT /api/meeting-transcription/sessions/{session_id}/full-audio` stores the final full recording. If live chunks are missing or failed, finalize can switch to fallback.
- **Finalize**: `POST /api/meeting-transcription/sessions/{session_id}/finalize` records `expected_chunk_count`, selects `live_chunks` or `full_audio_fallback`, and makes work visible to the worker.
- **Worker**: runs in-process with the API server by default, processes chunks in order, creates speaker anchor WAVs from each speaker's first qualified utterance, prepends anchors to later chunks, strips prefix segments from final results, and commits transcript chunks only in sequence.
- **Polling**: `GET /api/meeting-transcription/sessions/{session_id}` returns status, uploaded count, completed transcript segments, and `error_message` for failed sessions.

## Local setup

Use Python 3.12+.

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Configuration

The app can run with defaults, or these environment variables:

```bash
export MEETING_TRANSCRIPTION_DATABASE_URL="sqlite+pysqlite:///./meeting_transcription.db"
export MEETING_TRANSCRIPTION_STORAGE_ROOT="./artifacts"
```

Defaults are suitable for local development:

- Database: `sqlite+pysqlite:///./meeting_transcription.db`
- Artifact storage root: `./artifacts`

### Gradio ASR backend

The session API remains local (`http://127.0.0.1:8000`). The worker talks to the remote Gradio ASR backend behind the scenes. Do **not** point the macOS app directly at the Gradio URL because the app expects `/api/meeting-transcription/...` session routes, not Gradio's queued `/gradio_api/call/...` API.

Supported worker env vars:

```bash
export MEETING_TRANSCRIPTION_GRADIO_BASE_URL="https://546463aae3e7327f37.gradio.live/"
export MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS=8192
export MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE=0.0
export MEETING_TRANSCRIPTION_GRADIO_TOP_P=1.0
export MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE=false
export MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO=""
export MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS=1.0
```

### Segment translation backend

When configured, the worker translates each normalized transcript segment into English, Chinese, and Arabic immediately after ASR. Translation uses an OpenAI-compatible chat completions endpoint. If any translation variable is missing, transcription still completes and translations are returned as empty strings.

```bash
export MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL="https://api.openai.com/v1"
export MEETING_TRANSCRIPTION_TRANSLATION_API_KEY=""
export MEETING_TRANSCRIPTION_TRANSLATION_MODEL=""
export MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS=60
```

## Database migrations

Run Alembic migrations before starting a persistent server database:

```bash
cd server
source .venv/bin/activate
MEETING_TRANSCRIPTION_DATABASE_URL="sqlite+pysqlite:///./meeting_transcription.db" \
  python -m alembic upgrade head
```

Migration smoke test:

```bash
cd server
pytest tests/test_session_routes.py::test_alembic_upgrade_stamps_revision_on_fresh_sqlite_db -q
```

Current head is `20260420_04`.

## Run the API server

```bash
cd server
source .venv/bin/activate
uvicorn meeting_transcription.app:create_app --factory --host 127.0.0.1 --port 8000
```

That one process now serves both the HTTP API and the in-process background worker. With the defaults above, uploaded chunks will be transcribed through the configured Gradio backend automatically.

For production deployment with systemd, Nginx, persistent storage, migrations, upgrade, rollback, and security notes, see [PRODUCTION_DEPLOYMENT.md](PRODUCTION_DEPLOYMENT.md).

Health check:

```bash
curl http://127.0.0.1:8000/healthz
```

OpenAPI schema:

```bash
curl http://127.0.0.1:8000/openapi.json
```

## Worker execution

The repository currently exposes the worker as Python functions. A production deployment should run a loop that repeatedly calls `run_pending_chunk_once(db, transcriber, storage=storage)` with a concrete `ChunkTranscriber` implementation.

Minimal local skeleton:

```python
from meeting_transcription.app import DEFAULT_DATABASE_URL, DEFAULT_STORAGE_ROOT
from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.worker import run_pending_chunk_once

engine = create_engine(DEFAULT_DATABASE_URL)
session_factory = create_session_factory(engine)
storage = LocalArtifactStorage(DEFAULT_STORAGE_ROOT)
transcriber = YourChunkTranscriber()  # implements transcribe_chunk(...)

while True:
    with session_factory() as db:
        did_work = run_pending_chunk_once(db, transcriber, storage=storage)
    if not did_work:
        break
```

## Focused regression tests

Run the server integration and audio-anchor regressions:

```bash
cd server
pytest tests/test_session_routes.py tests/test_worker_processing.py tests/test_anchor_audio.py -q
```

Run only route/API contract coverage:

```bash
cd server
pytest tests/test_session_routes.py -q
```

Run only worker processing and fallback coverage:

```bash
cd server
pytest tests/test_worker_processing.py -q
```

Run only anchor-prefix normalization coverage:

```bash
cd server
pytest tests/test_anchor_audio.py -q
```

## API notes for the macOS client

- Chunk timestamps are absolute meeting times in milliseconds.
- No-prefix transcriber output is treated as chunk-local unless the transcriber result explicitly sets `timestamps_are_absolute: true`.
- Prefix artifacts are valid WAV files made from persisted speaker anchors, 500 ms silence between anchors, 800 ms silence before the real chunk, then the real chunk WAV.
- Prefix text is not returned in final transcript rows; final segments are normalized back to the absolute meeting timeline.
- Failed sessions return `status: "failed"` plus `error_message`; the macOS client should surface that message in `MeetingRecord.transcriptPreview`.
