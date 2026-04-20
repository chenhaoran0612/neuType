"""FastAPI routes for meeting transcription sessions."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, Path, Request, UploadFile, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from meeting_transcription import repositories
from meeting_transcription.schemas import (
    APIError,
    CreateSessionRequest,
    CreateSessionResponse,
    Envelope,
    ErrorEnvelope,
    FinalizeSessionRequest,
    FinalizeSessionResponse,
    SessionStatusResponse,
    UploadChunkResponse,
    envelope,
)
from meeting_transcription.storage import LocalArtifactStorage

router = APIRouter(prefix="/api/meeting-transcription/sessions")


def get_db(request: Request):
    """Yield a request-scoped database session."""
    session_factory = request.app.state.session_factory
    db = session_factory()
    try:
        yield db
    finally:
        db.close()


def get_storage(request: Request) -> LocalArtifactStorage:
    """Return the configured artifact storage."""
    return request.app.state.storage


def error_response(status_code: int, code: str, message: str) -> JSONResponse:
    """Return an error envelope JSON response."""
    return JSONResponse(
        status_code=status_code,
        content=jsonable_encoder(envelope(error=APIError(code=code, message=message))),
    )


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=Envelope[CreateSessionResponse],
    responses={
        status.HTTP_200_OK: {"model": Envelope[CreateSessionResponse]},
        status.HTTP_422_UNPROCESSABLE_CONTENT: {"model": ErrorEnvelope},
    },
)
def create_session(payload: CreateSessionRequest, db: Session = Depends(get_db)):
    """Create or reuse a transcription session by client token."""
    session_record = repositories.create_or_get_session(db, payload)
    status_code = (
        status.HTTP_200_OK if session_record.reused else status.HTTP_201_CREATED
    )
    return JSONResponse(
        status_code=status_code,
        content=jsonable_encoder(envelope(session_record.response_model())),
    )


@router.put(
    "/{session_id}/chunks/{chunk_index}",
    status_code=status.HTTP_201_CREATED,
    response_model=Envelope[UploadChunkResponse],
    responses={
        status.HTTP_200_OK: {"model": Envelope[UploadChunkResponse]},
        status.HTTP_400_BAD_REQUEST: {"model": ErrorEnvelope},
        status.HTTP_404_NOT_FOUND: {"model": ErrorEnvelope},
        status.HTTP_409_CONFLICT: {"model": ErrorEnvelope},
        status.HTTP_422_UNPROCESSABLE_CONTENT: {"model": ErrorEnvelope},
    },
)
async def upload_chunk(
    session_id: str,
    chunk_index: Annotated[int, Path(ge=0)],
    audio_file: Annotated[UploadFile, File(...)],
    start_ms: Annotated[int, Form(ge=0)],
    end_ms: Annotated[int, Form(gt=0)],
    sha256: Annotated[str, Form(min_length=1)],
    mime_type: Annotated[str, Form(min_length=1)],
    file_size_bytes: Annotated[int, Form(ge=0)],
    db: Session = Depends(get_db),
    storage: LocalArtifactStorage = Depends(get_storage),
):
    """Upload a live chunk with idempotent dedupe and hash conflict detection."""
    if end_ms <= start_ms:
        return error_response(
            status.HTTP_400_BAD_REQUEST,
            "invalid_chunk_range",
            "end_ms must be greater than start_ms",
        )

    try:
        stored_chunk = repositories.store_live_chunk(
            db,
            storage=storage,
            public_session_id=session_id,
            chunk_index=chunk_index,
            start_ms=start_ms,
            end_ms=end_ms,
            sha256=sha256,
            mime_type=mime_type,
            file_size_bytes=file_size_bytes,
            filename=audio_file.filename or f"{chunk_index}.bin",
            audio_bytes=await audio_file.read(),
        )
    except repositories.InvalidChunkMetadataError as exc:
        return error_response(status.HTTP_400_BAD_REQUEST, exc.code, exc.message)
    except repositories.SessionNotFoundError:
        return error_response(
            status.HTTP_404_NOT_FOUND,
            "session_not_found",
            f"session {session_id} does not exist",
        )
    except repositories.ChunkHashConflictError as exc:
        return error_response(
            status.HTTP_409_CONFLICT,
            "chunk_hash_conflict",
            str(exc),
        )

    status_code = status.HTTP_200_OK if stored_chunk.reused else status.HTTP_201_CREATED
    return JSONResponse(
        status_code=status_code,
        content=jsonable_encoder(envelope(stored_chunk.response_model())),
    )


@router.post(
    "/{session_id}/finalize",
    response_model=Envelope[FinalizeSessionResponse],
    responses={
        status.HTTP_404_NOT_FOUND: {"model": ErrorEnvelope},
        status.HTTP_422_UNPROCESSABLE_CONTENT: {"model": ErrorEnvelope},
    },
)
def finalize_session(
    session_id: str,
    payload: FinalizeSessionRequest,
    db: Session = Depends(get_db),
):
    """Finalize a session with minimal completeness tracking."""
    try:
        finalized = repositories.finalize_session(db, session_id, payload)
    except repositories.SessionNotFoundError:
        return error_response(
            status.HTTP_404_NOT_FOUND,
            "session_not_found",
            f"session {session_id} does not exist",
        )

    return JSONResponse(content=jsonable_encoder(envelope(finalized)))


@router.get(
    "/{session_id}",
    response_model=Envelope[SessionStatusResponse],
    responses={
        status.HTTP_404_NOT_FOUND: {"model": ErrorEnvelope},
        status.HTTP_422_UNPROCESSABLE_CONTENT: {"model": ErrorEnvelope},
    },
)
def get_session(session_id: str, db: Session = Depends(get_db)):
    """Return current session status."""
    try:
        session_status = repositories.get_session_status(db, session_id)
    except repositories.SessionNotFoundError:
        return error_response(
            status.HTTP_404_NOT_FOUND,
            "session_not_found",
            f"session {session_id} does not exist",
        )

    return JSONResponse(content=jsonable_encoder(envelope(session_status)))
