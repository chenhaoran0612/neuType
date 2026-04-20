from fastapi.testclient import TestClient
import pytest
from meeting_transcription.app import create_app
from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base, SessionChunk, TranscriptionSession


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

    assert chunk.id is not None
