"""FastAPI application scaffold for the meeting transcription service."""

from fastapi import APIRouter, FastAPI, HTTPException


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(title="Meeting Transcription Service")
    sessions_router = APIRouter(prefix="/api/meeting-transcription/sessions")

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @sessions_router.post(
        "",
        status_code=501,
        responses={501: {"description": "Not implemented"}},
    )
    def create_session() -> None:
        raise HTTPException(status_code=501, detail="Not implemented")

    @sessions_router.get(
        "/{session_id}",
        status_code=501,
        responses={501: {"description": "Not implemented"}},
    )
    def get_session(session_id: str) -> None:
        del session_id
        raise HTTPException(status_code=501, detail="Not implemented")

    app.include_router(sessions_router)
    return app
