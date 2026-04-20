from pathlib import Path
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from meeting_transcription.app import create_app


def test_health_route_and_session_routes_exist():
    client = TestClient(create_app())

    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    assert "/api/meeting-transcription/sessions" in paths
    assert "/api/meeting-transcription/sessions/{session_id}" in paths
