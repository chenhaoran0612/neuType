"""FastAPI routes for meeting transcription sessions."""

from __future__ import annotations

from email.parser import BytesParser
from email.policy import default
from typing import Any

from fastapi import APIRouter, Depends, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from meeting_transcription import repositories
from meeting_transcription.schemas import (
    APIError,
    CreateSessionRequest,
    CreateSessionResponse,
    Envelope,
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


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=Envelope[CreateSessionResponse],
    responses={status.HTTP_200_OK: {"model": Envelope[CreateSessionResponse]}},
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
        status.HTTP_404_NOT_FOUND: {"description": "Session not found"},
        status.HTTP_409_CONFLICT: {"description": "Chunk hash conflict"},
    },
)
async def upload_chunk(
    session_id: str,
    chunk_index: int,
    request: Request,
    db: Session = Depends(get_db),
    storage: LocalArtifactStorage = Depends(get_storage),
):
    """Upload a live chunk with idempotent dedupe and hash conflict detection."""
    try:
        form_data = await _parse_multipart_form(request)
        audio_part = form_data["audio_file"]
        start_ms = int(form_data["start_ms"])
        end_ms = int(form_data["end_ms"])
        sha256 = str(form_data["sha256"])
        mime_type = str(form_data["mime_type"])
        file_size_bytes = int(form_data["file_size_bytes"])
    except (KeyError, TypeError, ValueError):
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="invalid_multipart_payload",
                        message="multipart upload payload is invalid",
                    )
                )
            ),
        )

    if end_ms <= start_ms:
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="invalid_chunk_range",
                        message="end_ms must be greater than start_ms",
                    )
                )
            ),
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
            filename=str(audio_part["filename"]) or f"{chunk_index}.bin",
            audio_bytes=bytes(audio_part["content"]),
        )
    except repositories.SessionNotFoundError:
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="session_not_found",
                        message=f"session {session_id} does not exist",
                    )
                )
            ),
        )
    except repositories.ChunkHashConflictError as exc:
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=jsonable_encoder(
                envelope(
                    error=APIError(code="chunk_hash_conflict", message=str(exc))
                )
            ),
        )

    status_code = status.HTTP_200_OK if stored_chunk.reused else status.HTTP_201_CREATED
    return JSONResponse(
        status_code=status_code,
        content=jsonable_encoder(envelope(stored_chunk.response_model())),
    )


@router.post(
    "/{session_id}/finalize",
    response_model=Envelope[FinalizeSessionResponse],
    responses={status.HTTP_404_NOT_FOUND: {"description": "Session not found"}},
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
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="session_not_found",
                        message=f"session {session_id} does not exist",
                    )
                )
            ),
        )

    return JSONResponse(content=jsonable_encoder(envelope(finalized)))


@router.get(
    "/{session_id}",
    response_model=Envelope[SessionStatusResponse],
    responses={status.HTTP_404_NOT_FOUND: {"description": "Session not found"}},
)
def get_session(session_id: str, db: Session = Depends(get_db)):
    """Return current session status."""
    try:
        session_status = repositories.get_session_status(db, session_id)
    except repositories.SessionNotFoundError:
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=jsonable_encoder(
                envelope(
                    error=APIError(
                        code="session_not_found",
                        message=f"session {session_id} does not exist",
                    )
                )
            ),
        )

    return JSONResponse(content=jsonable_encoder(envelope(session_status)))


async def _parse_multipart_form(request: Request) -> dict[str, Any]:
    """Parse a multipart request body without python-multipart."""
    content_type = request.headers.get("content-type", "")
    if "multipart/form-data" not in content_type:
        raise ValueError("Expected multipart/form-data payload")

    body = await request.body()
    message = BytesParser(policy=default).parsebytes(
        (
            f"Content-Type: {content_type}\r\n"
            "MIME-Version: 1.0\r\n"
            "\r\n"
        ).encode("utf-8")
        + body
    )
    if not message.is_multipart():
        raise ValueError("Payload is not multipart")

    parsed: dict[str, Any] = {}
    for part in message.iter_parts():
        field_name = part.get_param("name", header="content-disposition")
        if field_name is None:
            continue

        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename is None:
            parsed[field_name] = payload.decode("utf-8")
        else:
            parsed[field_name] = {"filename": filename, "content": payload}

    return parsed
