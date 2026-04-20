"""Repository helpers for meeting transcription session APIs."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from sqlalchemy import Select, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from meeting_transcription.models import SessionChunk, TranscriptionSession, utcnow
from meeting_transcription.schemas import (
    CreateSessionRequest,
    CreateSessionResponse,
    FinalizeSessionRequest,
    FinalizeSessionResponse,
    SessionStatusResponse,
    UploadChunkResponse,
)
from meeting_transcription.storage import LocalArtifactStorage

LIVE_CHUNK_SOURCE_TYPE = "live_chunk"


class SessionNotFoundError(Exception):
    """Raised when a public session identifier does not exist."""


class ChunkHashConflictError(Exception):
    """Raised when a live chunk index already exists with a different hash."""


@dataclass(slots=True)
class SessionRecord:
    """Created or reused transcription session."""

    session: TranscriptionSession
    reused: bool

    def response_model(self) -> CreateSessionResponse:
        """Convert the ORM session to its API response payload."""
        return CreateSessionResponse.model_validate(self.session)


@dataclass(slots=True)
class ChunkRecord:
    """Stored or reused live chunk result."""

    session: TranscriptionSession
    chunk: SessionChunk
    reused: bool

    def response_model(self) -> UploadChunkResponse:
        """Convert the stored chunk to its API response payload."""
        return UploadChunkResponse(
            session_id=self.session.session_id,
            chunk_index=self.chunk.chunk_index,
            status="accepted",
            upload_status=self.chunk.upload_status,
            process_status=self.chunk.process_status,
        )


def create_or_get_session(db: Session, payload: CreateSessionRequest) -> SessionRecord:
    """Create a new transcription session or reuse an existing one."""
    existing = db.scalar(
        select(TranscriptionSession).where(
            TranscriptionSession.client_session_token == payload.client_session_token
        )
    )
    if existing is not None:
        return SessionRecord(session=existing, reused=True)

    session = TranscriptionSession(
        session_id=f"mts_{uuid4().hex[:12]}",
        client_session_token=payload.client_session_token,
        status="created",
        input_mode="live_chunks",
        chunk_duration_ms=payload.chunk_duration_ms,
        chunk_overlap_ms=payload.chunk_overlap_ms,
    )
    db.add(session)

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        existing = db.scalar(
            select(TranscriptionSession).where(
                TranscriptionSession.client_session_token == payload.client_session_token
            )
        )
        if existing is None:
            raise
        return SessionRecord(session=existing, reused=True)

    db.refresh(session)
    return SessionRecord(session=session, reused=False)


def store_live_chunk(
    db: Session,
    *,
    storage: LocalArtifactStorage,
    public_session_id: str,
    chunk_index: int,
    start_ms: int,
    end_ms: int,
    sha256: str,
    mime_type: str,
    file_size_bytes: int,
    filename: str,
    audio_bytes: bytes,
) -> ChunkRecord:
    """Persist a live chunk upload with idempotent conflict handling."""
    del mime_type, file_size_bytes

    session = _get_session_by_public_id(db, public_session_id)
    existing = db.scalar(_live_chunk_select(session, chunk_index))
    if existing is not None:
        if existing.sha256 != sha256:
            raise ChunkHashConflictError(
                f"chunk {chunk_index} already exists with a different sha256"
            )
        return ChunkRecord(session=session, chunk=existing, reused=True)

    suffix = Path(filename).suffix or ".bin"
    storage_path = storage.session_path(
        session.session_id, "live-chunks", f"{chunk_index}{suffix}"
    )
    storage.write_bytes(storage_path, audio_bytes)

    chunk = SessionChunk(
        session_id=session.id,
        chunk_index=chunk_index,
        source_type=LIVE_CHUNK_SOURCE_TYPE,
        start_ms=start_ms,
        end_ms=end_ms,
        duration_ms=end_ms - start_ms,
        sha256=sha256,
        storage_path=storage_path,
        upload_status="uploaded",
        process_status="pending",
    )
    session.status = "receiving_chunks"

    db.add(chunk)
    db.commit()
    db.refresh(session)
    db.refresh(chunk)
    return ChunkRecord(session=session, chunk=chunk, reused=False)


def get_session_status(db: Session, public_session_id: str) -> SessionStatusResponse:
    """Return the current session status payload."""
    session = _get_session_by_public_id(db, public_session_id)
    uploaded_chunk_count = len(
        [
            chunk
            for chunk in session.chunks
            if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE
            and chunk.upload_status == "uploaded"
        ]
    )
    return SessionStatusResponse(
        session_id=session.session_id,
        status=session.status,
        input_mode=session.input_mode,
        chunk_duration_ms=session.chunk_duration_ms,
        chunk_overlap_ms=session.chunk_overlap_ms,
        expected_chunk_count=session.expected_chunk_count,
        uploaded_chunk_count=uploaded_chunk_count,
    )


def finalize_session(
    db: Session,
    public_session_id: str,
    payload: FinalizeSessionRequest,
) -> FinalizeSessionResponse:
    """Finalize a session with minimal completeness tracking."""
    session = _get_session_by_public_id(db, public_session_id)
    uploaded_indexes = {
        chunk.chunk_index
        for chunk in session.chunks
        if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE
        and chunk.upload_status == "uploaded"
    }
    expected_count = payload.expected_chunk_count
    missing_chunk_indexes: list[int] = []
    if expected_count is not None:
        session.expected_chunk_count = expected_count
        missing_chunk_indexes = sorted(
            set(range(expected_count)) - uploaded_indexes
        )

    if missing_chunk_indexes:
        session.status = "awaiting_finalize"
    else:
        session.status = "finalizing"
        session.finalized_at = utcnow()

    db.commit()
    db.refresh(session)

    return FinalizeSessionResponse(
        session_id=session.session_id,
        status=session.status,
        selected_input_mode=payload.preferred_input_mode,
        missing_chunk_indexes=missing_chunk_indexes,
    )


def _get_session_by_public_id(
    db: Session, public_session_id: str
) -> TranscriptionSession:
    session = db.scalar(
        select(TranscriptionSession).where(
            TranscriptionSession.session_id == public_session_id
        )
    )
    if session is None:
        raise SessionNotFoundError(public_session_id)
    return session


def _live_chunk_select(
    session: TranscriptionSession, chunk_index: int
) -> Select[tuple[SessionChunk]]:
    return select(SessionChunk).where(
        SessionChunk.session_id == session.id,
        SessionChunk.chunk_index == chunk_index,
        SessionChunk.source_type == LIVE_CHUNK_SOURCE_TYPE,
    )
