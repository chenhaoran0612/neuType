from datetime import datetime, timezone
import hashlib
from io import BytesIO
import os
from pathlib import Path
import pytest
import sqlite3
import subprocess
import sys
from fastapi.testclient import TestClient
from meeting_transcription.app import create_app
from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription import repositories
from meeting_transcription.models import Base, SessionChunk, TranscriptionSession
from meeting_transcription.storage import LocalArtifactStorage
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from uuid import uuid4


def test_health_route_and_session_routes_exist(client):
    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    assert "/api/meeting-transcription/sessions" in paths
    assert "/api/meeting-transcription/sessions/{session_id}" in paths
    assert "/api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}" in paths
    assert "/api/meeting-transcription/sessions/{session_id}/finalize" in paths


def test_session_routes_advertise_api_contract_responses(client):
    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    create_session_responses = paths["/api/meeting-transcription/sessions"]["post"][
        "responses"
    ]
    get_session_responses = paths["/api/meeting-transcription/sessions/{session_id}"][
        "get"
    ]["responses"]
    upload_chunk_responses = paths[
        "/api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}"
    ]["put"]["responses"]
    upload_chunk_request_body = paths[
        "/api/meeting-transcription/sessions/{session_id}/chunks/{chunk_index}"
    ]["put"].get("requestBody", {})

    assert "201" in create_session_responses
    assert "200" in create_session_responses
    assert "200" in get_session_responses
    assert "201" in upload_chunk_responses
    assert "200" in upload_chunk_responses
    assert "400" in upload_chunk_responses
    assert "409" in upload_chunk_responses
    assert "multipart/form-data" in upload_chunk_request_body["content"]


@pytest.fixture
def db_session():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    session_factory = create_session_factory(engine)
    session = session_factory()

    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture
def client(tmp_path):
    database_path = tmp_path / "meeting-transcription-test.db"
    engine = create_engine(f"sqlite+pysqlite:///{database_path}")
    Base.metadata.create_all(engine)
    session_factory = create_session_factory(engine)
    storage = LocalArtifactStorage(tmp_path / "artifacts")

    with TestClient(create_app(session_factory=session_factory, storage=storage)) as app:
        yield app

    engine.dispose()


@pytest.fixture
def created_session(client):
    payload = {
        "client_session_token": "created-session-token",
        "source": "neutype-macos",
        "chunk_duration_ms": 300000,
        "chunk_overlap_ms": 2500,
        "audio_format": "wav",
        "sample_rate_hz": 16000,
        "channel_count": 1,
    }

    response = client.post("/api/meeting-transcription/sessions", json=payload)

    assert response.status_code == 201
    return response.json()["data"]["session_id"]


@pytest.fixture
def wav_file():
    return BytesIO(b"RIFFtestWAVEfmt " + (b"\x00" * 120))


def _wav_bytes(tag: bytes = b"") -> bytes:
    return b"RIFFtestWAVEfmt " + tag + (b"\x00" * 120)


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


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


def test_chunk_upload_returns_200_when_same_bytes_are_replayed(client, created_session):
    payload = _wav_bytes(b"same")
    digest = _sha256(payload)

    first = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(payload), "audio/wav")},
        data={
            "start_ms": 0,
            "end_ms": 300000,
            "sha256": digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(payload),
        },
    )
    second = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(payload), "audio/wav")},
        data={
            "start_ms": 0,
            "end_ms": 300000,
            "sha256": digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(payload),
        },
    )

    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["data"]["chunk_index"] == second.json()["data"]["chunk_index"]


def test_chunk_upload_rejects_same_index_different_bytes(client, created_session):
    first_payload = _wav_bytes(b"first")
    second_payload = _wav_bytes(b"second")
    first_digest = _sha256(first_payload)
    second_digest = _sha256(second_payload)

    first = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(first_payload), "audio/wav")},
        data={
            "start_ms": 0,
            "end_ms": 300000,
            "sha256": first_digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(first_payload),
        },
    )
    second = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(second_payload), "audio/wav")},
        data={
            "start_ms": 0,
            "end_ms": 300000,
            "sha256": second_digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(second_payload),
        },
    )

    assert first.status_code == 201
    assert second.status_code == 409
    assert second.json()["error"]["code"] == "chunk_hash_conflict"


@pytest.mark.parametrize(
    ("overrides", "expected_code"),
    [
        ({"sha256": "not-the-real-hash"}, "chunk_sha256_mismatch"),
        ({"file_size_bytes": 1}, "chunk_size_mismatch"),
    ],
)
def test_chunk_upload_rejects_mismatched_client_hash_or_size(
    client, created_session, overrides, expected_code
):
    payload = _wav_bytes(b"mismatch")
    digest = _sha256(payload)
    data = {
        "start_ms": 0,
        "end_ms": 300000,
        "sha256": digest,
        "mime_type": "audio/wav",
        "file_size_bytes": len(payload),
    }
    data.update(overrides)

    response = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(payload), "audio/wav")},
        data=data,
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == expected_code


def test_finalize_selected_input_mode_matches_persisted_session_state(client, created_session):
    response = client.post(
        f"/api/meeting-transcription/sessions/{created_session}/finalize",
        json={
            "expected_chunk_count": 2,
            "preferred_input_mode": "full_audio_fallback",
            "allow_full_audio_fallback": True,
        },
    )
    status_response = client.get(f"/api/meeting-transcription/sessions/{created_session}")

    assert response.status_code == 200
    assert status_response.status_code == 200
    assert response.json()["data"]["status"] == "awaiting_fallback"
    assert response.json()["data"]["selected_input_mode"] == "live_chunks"
    assert status_response.json()["data"]["input_mode"] == "live_chunks"


@pytest.mark.parametrize(
    ("path_chunk_index", "start_ms", "expected_code"),
    [
        (-1, 0, "validation_error"),
        (0, -1, "validation_error"),
    ],
)
def test_chunk_upload_rejects_negative_chunk_index_or_start_ms(
    client, created_session, path_chunk_index, start_ms, expected_code
):
    payload = _wav_bytes(b"negative")
    digest = _sha256(payload)

    response = client.put(
        f"/api/meeting-transcription/sessions/{created_session}/chunks/{path_chunk_index}",
        files={"audio_file": ("chunk.wav", BytesIO(payload), "audio/wav")},
        data={
            "start_ms": start_ms,
            "end_ms": 300000,
            "sha256": digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(payload),
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == expected_code


def test_store_live_chunk_recovers_from_integrity_error_for_same_content(
    tmp_path, monkeypatch
):
    database_path = tmp_path / "meeting-transcription-race.db"
    engine = create_engine(f"sqlite+pysqlite:///{database_path}")
    Base.metadata.create_all(engine)
    session_factory = create_session_factory(engine)
    storage = LocalArtifactStorage(tmp_path / "artifacts")
    payload = _wav_bytes(b"race")
    digest = _sha256(payload)

    setup_session = session_factory()
    transcription_session = TranscriptionSession(
        session_id="mts_race",
        client_session_token="race-token",
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
    )
    setup_session.add(transcription_session)
    setup_session.commit()
    setup_session.refresh(transcription_session)
    setup_session.close()

    db = session_factory()
    original_commit = db.commit
    triggered = False

    def race_commit():
        nonlocal triggered
        if triggered:
            return original_commit()

        triggered = True
        competing = session_factory()
        competing_session = competing.scalar(
            select(TranscriptionSession).where(
                TranscriptionSession.session_id == "mts_race"
            )
        )
        competing.add(
            SessionChunk(
                session_id=competing_session.id,
                chunk_index=0,
                source_type="live_chunk",
                start_ms=0,
                end_ms=300000,
                duration_ms=300000,
                sha256=digest,
                storage_path="sessions/mts_race/live-chunks/0.wav",
                upload_status="uploaded",
                process_status="pending",
            )
        )
        competing.commit()
        competing.close()
        raise IntegrityError("INSERT", {}, Exception("duplicate"))

    monkeypatch.setattr(db, "commit", race_commit)

    result = repositories.store_live_chunk(
        db,
        storage=storage,
        public_session_id="mts_race",
        chunk_index=0,
        start_ms=0,
        end_ms=300000,
        sha256=digest,
        mime_type="audio/wav",
        file_size_bytes=len(payload),
        filename="chunk.wav",
        audio_bytes=payload,
    )

    assert result.reused is False
    assert result.chunk.sha256 == digest
    assert storage.exists("sessions/mts_race/live-chunks/0.wav")

    db.refresh(result.session)
    assert result.session.status == "receiving_chunks"

    db.close()
    engine.dispose()


def test_chunk_retry_repairs_missing_artifact_instead_of_returning_reused(client, tmp_path):
    payload = _wav_bytes(b"repair")
    digest = _sha256(payload)

    create_response = client.post(
        "/api/meeting-transcription/sessions",
        json={
            "client_session_token": "repair-token",
            "source": "neutype-macos",
            "chunk_duration_ms": 300000,
            "chunk_overlap_ms": 2500,
            "audio_format": "wav",
            "sample_rate_hz": 16000,
            "channel_count": 1,
        },
    )
    session_id = create_response.json()["data"]["session_id"]

    session_factory = client.app.state.session_factory
    db = session_factory()
    session = db.scalar(
        select(TranscriptionSession).where(TranscriptionSession.session_id == session_id)
    )
    db.add(
        SessionChunk(
            session_id=session.id,
            chunk_index=0,
            source_type="live_chunk",
            start_ms=0,
            end_ms=300000,
            duration_ms=300000,
            sha256=digest,
            storage_path=f"sessions/{session_id}/live-chunks/0.wav",
            upload_status="uploaded",
            process_status="pending",
        )
    )
    session.status = "receiving_chunks"
    db.commit()
    db.close()

    response = client.put(
        f"/api/meeting-transcription/sessions/{session_id}/chunks/0",
        files={"audio_file": ("chunk.wav", BytesIO(payload), "audio/wav")},
        data={
            "start_ms": 0,
            "end_ms": 300000,
            "sha256": digest,
            "mime_type": "audio/wav",
            "file_size_bytes": len(payload),
        },
    )

    assert response.status_code == 201
    assert client.app.state.storage.exists(f"sessions/{session_id}/live-chunks/0.wav")


def test_store_live_chunk_storage_failure_rolls_back_chunk_and_session_state(
    tmp_path, monkeypatch
):
    database_path = tmp_path / "meeting-transcription-storage-failure.db"
    engine = create_engine(f"sqlite+pysqlite:///{database_path}")
    Base.metadata.create_all(engine)
    session_factory = create_session_factory(engine)
    storage = LocalArtifactStorage(tmp_path / "artifacts")
    payload = _wav_bytes(b"fail-write")
    digest = _sha256(payload)

    setup_session = session_factory()
    transcription_session = TranscriptionSession(
        session_id="mts_storage_fail",
        client_session_token="storage-fail-token",
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
    )
    setup_session.add(transcription_session)
    setup_session.commit()
    setup_session.close()

    def fail_write_bytes(logical_path: str, payload_bytes: bytes):
        del logical_path, payload_bytes
        raise OSError("disk full")

    monkeypatch.setattr(storage, "write_bytes", fail_write_bytes)

    db = session_factory()
    with pytest.raises(OSError):
        repositories.store_live_chunk(
            db,
            storage=storage,
            public_session_id="mts_storage_fail",
            chunk_index=0,
            start_ms=0,
            end_ms=300000,
            sha256=digest,
            mime_type="audio/wav",
            file_size_bytes=len(payload),
            filename="chunk.wav",
            audio_bytes=payload,
        )

    reloaded_session = db.scalar(
        select(TranscriptionSession).where(
            TranscriptionSession.session_id == "mts_storage_fail"
        )
    )
    chunks = db.scalars(
        select(SessionChunk).where(SessionChunk.session_id == reloaded_session.id)
    ).all()

    assert reloaded_session.status == "created"
    assert chunks == []

    db.close()
    engine.dispose()


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
    db_session.refresh(chunk)

    assert chunk.id is not None
    assert chunk.retry_count == 0


def test_schema_round_trips_utc_aware_timestamps(db_session):
    finalized_at = datetime(2026, 4, 20, 12, 0, tzinfo=timezone.utc)
    session = TranscriptionSession(
        session_id="mts_test_timestamps",
        client_session_token="token-timestamps",
        status="completed",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
        finalized_at=finalized_at,
    )
    db_session.add(session)
    db_session.commit()
    db_session.refresh(session)

    assert session.created_at.tzinfo is timezone.utc
    assert session.updated_at.tzinfo is timezone.utc
    assert session.finalized_at == finalized_at


def test_schema_allows_same_chunk_index_for_different_source_types(db_session):
    session = TranscriptionSession(
        session_id="mts_test_sources",
        client_session_token="token-sources",
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
    )
    db_session.add(session)
    db_session.flush()

    live_chunk = SessionChunk(
        session_id=session.id,
        chunk_index=0,
        source_type="live_chunk",
        start_ms=0,
        end_ms=300000,
        duration_ms=300000,
        sha256="live",
        storage_path="sessions/mts_test_sources/live-chunks/0.wav",
        upload_status="uploaded",
        process_status="pending",
    )
    fallback_chunk = SessionChunk(
        session_id=session.id,
        chunk_index=0,
        source_type="server_split_from_full_audio",
        start_ms=0,
        end_ms=300000,
        duration_ms=300000,
        sha256="fallback",
        storage_path="sessions/mts_test_sources/fallback/split/0.wav",
        upload_status="uploaded",
        process_status="pending",
    )
    db_session.add_all([live_chunk, fallback_chunk])
    db_session.commit()

    assert live_chunk.id is not None
    assert fallback_chunk.id is not None


def test_session_relationship_orders_chunks_by_index_then_source_type(db_session):
    session = TranscriptionSession(
        session_id="mts_test_ordering",
        client_session_token="token-ordering",
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=300000,
        chunk_overlap_ms=2500,
    )
    db_session.add(session)
    db_session.flush()

    db_session.add_all(
        [
            SessionChunk(
                session_id=session.id,
                chunk_index=0,
                source_type="server_split_from_full_audio",
                start_ms=0,
                end_ms=300000,
                duration_ms=300000,
                sha256="fallback-order",
                storage_path="sessions/mts_test_ordering/fallback/split/0.wav",
                upload_status="uploaded",
                process_status="pending",
            ),
            SessionChunk(
                session_id=session.id,
                chunk_index=0,
                source_type="live_chunk",
                start_ms=0,
                end_ms=300000,
                duration_ms=300000,
                sha256="live-order",
                storage_path="sessions/mts_test_ordering/live-chunks/0.wav",
                upload_status="uploaded",
                process_status="pending",
            ),
            SessionChunk(
                session_id=session.id,
                chunk_index=1,
                source_type="live_chunk",
                start_ms=300000,
                end_ms=600000,
                duration_ms=300000,
                sha256="live-order-1",
                storage_path="sessions/mts_test_ordering/live-chunks/1.wav",
                upload_status="uploaded",
                process_status="pending",
            ),
        ]
    )
    db_session.commit()
    db_session.expunge_all()

    reloaded_session = db_session.get(TranscriptionSession, session.id)

    assert [(chunk.chunk_index, chunk.source_type) for chunk in reloaded_session.chunks] == [
        (0, "live_chunk"),
        (0, "server_split_from_full_audio"),
        (1, "live_chunk"),
    ]


def test_schema_enforces_chunk_session_foreign_key(db_session):
    orphan_chunk = SessionChunk(
        session_id=uuid4(),
        chunk_index=0,
        source_type="live_chunk",
        start_ms=0,
        end_ms=300000,
        duration_ms=300000,
        sha256="orphan",
        storage_path="sessions/missing/live-chunks/0.wav",
        upload_status="uploaded",
        process_status="pending",
    )
    db_session.add(orphan_chunk)

    with pytest.raises(IntegrityError):
        db_session.commit()


def test_local_artifact_storage_rejects_escape_paths(tmp_path):
    storage = LocalArtifactStorage(tmp_path)

    with pytest.raises(ValueError):
        storage.resolve("../escape.txt")

    with pytest.raises(ValueError):
        storage.resolve("/tmp/escape.txt")


def test_alembic_upgrade_stamps_revision_on_fresh_sqlite_db(tmp_path):
    server_dir = Path(__file__).resolve().parents[1]
    database_path = tmp_path / "migration-smoke.db"

    completed = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"],
        cwd=server_dir,
        env={
            **os.environ,
            "MEETING_TRANSCRIPTION_DATABASE_URL": f"sqlite+pysqlite:///{database_path}",
        },
        capture_output=True,
        text=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr or completed.stdout

    with sqlite3.connect(database_path) as connection:
        row = connection.execute(
            "SELECT version_num FROM alembic_version"
        ).fetchone()

    assert row == ("20260420_02",)
