"""FastAPI application composition for the meeting transcription service."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session, sessionmaker

from meeting_transcription.background_worker import BackgroundWorkerService
from meeting_transcription.db import create_engine, create_session_factory
from meeting_transcription.models import Base
from meeting_transcription.routes import router as sessions_router
from meeting_transcription.runtime import (
    create_chunk_transcriber_from_settings,
    create_segment_translator_from_settings,
    load_worker_runtime_settings,
)
from meeting_transcription.schemas import APIError, envelope
from meeting_transcription.storage import LocalArtifactStorage

DEFAULT_DATABASE_URL = "sqlite+pysqlite:///./meeting_transcription.db"
DEFAULT_STORAGE_ROOT = "./artifacts"


def create_app(
    *,
    session_factory: sessionmaker[Session] | None = None,
    storage: LocalArtifactStorage | None = None,
    start_worker: bool | None = None,
) -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(title="Meeting Transcription Service")
    provided_session_factory = session_factory is not None
    provided_storage = storage is not None

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

    if start_worker is None:
        start_worker = not (provided_session_factory or provided_storage)

    if start_worker:
        worker_settings = load_worker_runtime_settings()
        worker_service = BackgroundWorkerService(
            session_factory=session_factory,
            storage=storage,
            transcriber=create_chunk_transcriber_from_settings(worker_settings),
            translator=create_segment_translator_from_settings(worker_settings),
            idle_sleep_seconds=worker_settings.idle_sleep_seconds,
        )
        app.state.background_worker = worker_service

        @app.on_event("startup")
        async def _start_background_worker() -> None:
            worker_service.start()

        @app.on_event("shutdown")
        async def _stop_background_worker() -> None:
            worker_service.stop()

    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(request, exc: RequestValidationError):
        del request
        del exc
        return JSONResponse(
            status_code=422,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="validation_error",
                        message="request validation failed",
                    )
                )
            ),
        )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(sessions_router)
    return app
