from fastapi.testclient import TestClient
from meeting_transcription.app import create_app


def test_health_route_and_session_routes_exist():
    client = TestClient(create_app())

    response = client.get("/openapi.json")

    assert response.status_code == 200
    paths = response.json()["paths"]
    assert "/api/meeting-transcription/sessions" in paths
    assert "/api/meeting-transcription/sessions/{session_id}" in paths
