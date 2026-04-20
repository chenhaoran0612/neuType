from fastapi.testclient import TestClient
from meeting_transcription.app import create_app


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
