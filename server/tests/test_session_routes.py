from fastapi.testclient import TestClient
from datetime import datetime, timezone
import pytest
from meeting_transcription.app import create_app
from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base, SessionChunk, TranscriptionSession
from meeting_transcription.storage import LocalArtifactStorage
from sqlalchemy.exc import IntegrityError
from uuid import uuid4


def test_health_route_and_session_routes_exist():
    client = TestClient(create_app())

    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    assert "/api/meeting-transcription/sessions" in paths
    assert "/api/meeting-transcription/sessions/{session_id}" in paths


def test_placeholder_session_routes_do_not_advertise_200_success():
    client = TestClient(create_app())

    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    create_session_responses = paths["/api/meeting-transcription/sessions"]["post"][
        "responses"
    ]
    get_session_responses = paths["/api/meeting-transcription/sessions/{session_id}"][
        "get"
    ]["responses"]

    assert "200" not in create_session_responses
    assert "200" not in get_session_responses
    assert "501" in create_session_responses
    assert "501" in get_session_responses


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
