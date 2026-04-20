"""FastAPI application composition for the meeting transcription service."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from sqlalchemy.orm import Session, sessionmaker

from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base
from meeting_transcription.routes import router as sessions_router
from meeting_transcription.storage import LocalArtifactStorage

DEFAULT_DATABASE_URL = "sqlite+pysqlite:///./meeting_transcription.db"
DEFAULT_STORAGE_ROOT = "./artifacts"


def create_app(
    *,
    session_factory: sessionmaker[Session] | None = None,
    storage: LocalArtifactStorage | None = None,
) -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(title="Meeting Transcription Service")

    if session_factory is None:
        database_url = os.environ.get(
            "MEETING_TRANSCRIPTION_DATABASE_URL", DEFAULT_DATABASE_URL
        )
        engine = create_engine(database_url)
        Base.metadata.create_all(engine)
        session_factory = create_session_factory(engine)

    if storage is None:
        storage_root = Path(
            os.environ.get("MEETING_TRANSCRIPTION_STORAGE_ROOT", DEFAULT_STORAGE_ROOT)
        )
        storage = LocalArtifactStorage(storage_root)

    app.state.session_factory = session_factory
    app.state.storage = storage

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(sessions_router)
    return app
