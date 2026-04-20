"""FastAPI application scaffold for the meeting transcription service."""

from fastapi import APIRouter, FastAPI


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(title="Meeting Transcription Service")
    sessions_router = APIRouter(prefix="/api/meeting-transcription/sessions")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @sessions_router.post("")
    def create_session() -> dict[str, str]:
        return {"status": "not_implemented"}

    @sessions_router.get("/{session_id}")
    def get_session(session_id: str) -> dict[str, str]:
        return {"session_id": session_id, "status": "not_implemented"}

    app.include_router(sessions_router)
    return app
