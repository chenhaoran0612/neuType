"""Repository helpers for meeting transcription session APIs."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from datetime import timedelta
import hashlib
import json
from pathlib import Path
import wave
from uuid import uuid4

from sqlalchemy import Select, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from meeting_transcription.anchor_audio import (
    Segment,
    segments_from_payload,
    select_anchor_candidate,
    stable_speaker_key,
)
from meeting_transcription.models import (
    SessionChunk,
    SpeakerAnchor,
    TranscriptionSession,
    utcnow,
)
from meeting_transcription.schemas import (
    CreateSessionRequest,
    CreateSessionResponse,
    FinalizeSessionRequest,
    FinalizeSessionResponse,
    SessionStatusResponse,
    UploadChunkResponse,
)
from meeting_transcription.storage import LocalArtifactStorage

LIVE_CHUNKS_INPUT_MODE = "live_chunks"
FULL_AUDIO_FALLBACK_INPUT_MODE = "full_audio_fallback"
LIVE_CHUNK_SOURCE_TYPE = "live_chunk"
FALLBACK_SPLIT_SOURCE_TYPE = "server_split_from_full_audio"
UPLOAD_STATUS_PENDING = "pending_upload"
UPLOAD_STATUS_UPLOADED = "uploaded"
CHUNK_PROCESS_PENDING = "pending"
CHUNK_PROCESS_PROCESSING = "processing"
CHUNK_PROCESS_PROCESSED = "processed"
CHUNK_PROCESS_COMPLETED = "completed"
CHUNK_PROCESS_FAILED = "failed"
TERMINAL_SESSION_STATUSES = {"completed", "failed"}
AWAITING_FINALIZE_STATUS = "awaiting_finalize"
AWAITING_FALLBACK_STATUS = "awaiting_fallback"
MAX_CHUNK_PROCESSING_RETRIES = 3
STALE_PROCESSING_THRESHOLD_SECONDS = 300


class SessionNotFoundError(Exception):
    """Raised when a public session identifier does not exist."""


class ChunkHashConflictError(Exception):
    """Raised when a live chunk index already exists with a different hash."""


class InvalidChunkMetadataError(Exception):
    """Raised when client-supplied chunk metadata mismatches the uploaded bytes."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(slots=True)
class SessionRecord:
    session: TranscriptionSession
    reused: bool

    def response_model(self) -> CreateSessionResponse:
        return CreateSessionResponse.model_validate(self.session)


@dataclass(slots=True)
class ChunkRecord:
    session: TranscriptionSession
    chunk: SessionChunk
    reused: bool

    def response_model(self) -> UploadChunkResponse:
        return UploadChunkResponse(
            session_id=self.session.session_id,
            chunk_index=self.chunk.chunk_index,
            status="accepted",
            upload_status=self.chunk.upload_status,
            process_status=self.chunk.process_status,
        )


def create_or_get_session(db: Session, payload: CreateSessionRequest) -> SessionRecord:
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
        input_mode=LIVE_CHUNKS_INPUT_MODE,
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
    del mime_type

    actual_sha256 = hashlib.sha256(audio_bytes).hexdigest()
    actual_file_size = len(audio_bytes)
    if sha256 != actual_sha256:
        raise InvalidChunkMetadataError(
            "chunk_sha256_mismatch",
            "client sha256 does not match uploaded audio bytes",
        )
    if file_size_bytes != actual_file_size:
        raise InvalidChunkMetadataError(
            "chunk_size_mismatch",
            "client file_size_bytes does not match uploaded audio bytes",
        )

    session = _get_session_by_public_id(db, public_session_id)
    existing = db.scalar(_live_chunk_select(session, chunk_index))
    if existing is not None:
        return _handle_existing_live_chunk(
            db=db,
            storage=storage,
            session=session,
            chunk=existing,
            chunk_index=chunk_index,
            actual_sha256=actual_sha256,
            audio_bytes=audio_bytes,
        )

    suffix = Path(filename).suffix or ".bin"
    storage_path = storage.session_path(
        session.session_id, "live-chunks", f"{chunk_index}{suffix}"
    )

    chunk = SessionChunk(
        session_id=session.id,
        chunk_index=chunk_index,
        source_type=LIVE_CHUNK_SOURCE_TYPE,
        start_ms=start_ms,
        end_ms=end_ms,
        duration_ms=end_ms - start_ms,
        sha256=actual_sha256,
        storage_path=storage_path,
        upload_status=UPLOAD_STATUS_PENDING,
        process_status=CHUNK_PROCESS_PENDING,
    )
    db.add(chunk)

    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        existing = db.scalar(_live_chunk_select(session, chunk_index))
        if existing is None:
            raise
        return _handle_existing_live_chunk(
            db=db,
            storage=storage,
            session=session,
            chunk=existing,
            chunk_index=chunk_index,
            actual_sha256=actual_sha256,
            audio_bytes=audio_bytes,
        )

    try:
        storage.write_bytes(storage_path, audio_bytes)
    except Exception:
        _delete_chunk_and_restore_session_state(db=db, session=session, chunk=chunk)
        raise

    chunk.upload_status = UPLOAD_STATUS_UPLOADED
    session.status = "receiving_chunks"
    db.commit()
    db.refresh(session)
    db.refresh(chunk)
    return ChunkRecord(session=session, chunk=chunk, reused=False)


def get_session_status(db: Session, public_session_id: str) -> SessionStatusResponse:
    session = _get_session_by_public_id(db, public_session_id)
    uploaded_chunk_count = len(
        [
            chunk
            for chunk in session.chunks
            if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE
            and chunk.upload_status == UPLOAD_STATUS_UPLOADED
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
    session = _get_session_by_public_id(db, public_session_id)
    expected_count = payload.expected_chunk_count
    missing_chunk_indexes: list[int] = []
    if expected_count is not None:
        session.expected_chunk_count = expected_count
        live_chunks_by_index = {
            chunk.chunk_index: chunk
            for chunk in session.chunks
            if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE
            and chunk.upload_status == UPLOAD_STATUS_UPLOADED
        }
        missing_chunk_indexes = sorted(
            index for index in range(expected_count) if index not in live_chunks_by_index
        )
        failed_live_indexes = sorted(
            index
            for index, chunk in live_chunks_by_index.items()
            if chunk.process_status == CHUNK_PROCESS_FAILED
        )
    else:
        failed_live_indexes = sorted(
            chunk.chunk_index
            for chunk in session.chunks
            if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE
            and chunk.upload_status == UPLOAD_STATUS_UPLOADED
            and chunk.process_status == CHUNK_PROCESS_FAILED
        )

    usable_fallback = _session_has_usable_full_audio(session)
    fallback_needed = bool(missing_chunk_indexes or failed_live_indexes)
    switching_to_fallback = (
        fallback_needed
        and payload.allow_full_audio_fallback
        and usable_fallback
        and session.selected_final_input_mode != FULL_AUDIO_FALLBACK_INPUT_MODE
    )

    if switching_to_fallback:
        session.status = "finalizing"
        session.input_mode = FULL_AUDIO_FALLBACK_INPUT_MODE
        session.selected_final_input_mode = FULL_AUDIO_FALLBACK_INPUT_MODE
        session.last_committed_chunk_index = -1
        session.finalized_at = session.finalized_at or utcnow()
    elif (
        fallback_needed
        and session.selected_final_input_mode == FULL_AUDIO_FALLBACK_INPUT_MODE
        and usable_fallback
    ):
        session.status = session.status if session.status in TERMINAL_SESSION_STATUSES else "finalizing"
        session.input_mode = FULL_AUDIO_FALLBACK_INPUT_MODE
    elif fallback_needed:
        session.status = AWAITING_FALLBACK_STATUS
        session.input_mode = LIVE_CHUNKS_INPUT_MODE
        session.selected_final_input_mode = LIVE_CHUNKS_INPUT_MODE
    elif session.selected_final_input_mode == FULL_AUDIO_FALLBACK_INPUT_MODE:
        session.status = session.status if session.status in TERMINAL_SESSION_STATUSES else "finalizing"
        session.input_mode = FULL_AUDIO_FALLBACK_INPUT_MODE
    elif expected_count is None:
        session.status = AWAITING_FINALIZE_STATUS
        session.input_mode = LIVE_CHUNKS_INPUT_MODE
        session.selected_final_input_mode = LIVE_CHUNKS_INPUT_MODE
    else:
        session.status = "finalizing"
        session.input_mode = LIVE_CHUNKS_INPUT_MODE
        session.selected_final_input_mode = LIVE_CHUNKS_INPUT_MODE
        session.finalized_at = session.finalized_at or utcnow()

    db.commit()
    db.refresh(session)
    return FinalizeSessionResponse(
        session_id=session.session_id,
        status=session.status,
        selected_input_mode=session.selected_final_input_mode or session.input_mode,
        missing_chunk_indexes=missing_chunk_indexes,
    )


def next_pending_chunk(db: Session) -> SessionChunk | None:
    for session in _active_sessions(db):
        source_type = selected_source_type_for_session(session)
        chunk = db.scalar(
            select(SessionChunk)
            .where(
                SessionChunk.session_id == session.id,
                SessionChunk.source_type == source_type,
                SessionChunk.upload_status == UPLOAD_STATUS_UPLOADED,
                SessionChunk.process_status == CHUNK_PROCESS_PENDING,
            )
            .order_by(SessionChunk.created_at, SessionChunk.chunk_index)
        )
        if chunk is not None:
            return chunk
    return None


def selected_source_type_for_session(session: TranscriptionSession) -> str:
    selected_mode = session.selected_final_input_mode or session.input_mode
    if selected_mode == FULL_AUDIO_FALLBACK_INPUT_MODE:
        return FALLBACK_SPLIT_SOURCE_TYPE
    return LIVE_CHUNK_SOURCE_TYPE


def fallback_chunks_exist(db: Session, session: TranscriptionSession) -> bool:
    return (
        db.scalar(
            select(SessionChunk.id).where(
                SessionChunk.session_id == session.id,
                SessionChunk.source_type == FALLBACK_SPLIT_SOURCE_TYPE,
            )
        )
        is not None
    )


def create_fallback_chunk(
    db: Session,
    *,
    session: TranscriptionSession,
    chunk_index: int,
    start_ms: int,
    end_ms: int,
    duration_ms: int,
    sha256: str,
    storage_path: str,
) -> SessionChunk:
    chunk = SessionChunk(
        session_id=session.id,
        chunk_index=chunk_index,
        source_type=FALLBACK_SPLIT_SOURCE_TYPE,
        start_ms=start_ms,
        end_ms=end_ms,
        duration_ms=duration_ms,
        sha256=sha256,
        storage_path=storage_path,
        upload_status=UPLOAD_STATUS_UPLOADED,
        process_status=CHUNK_PROCESS_PENDING,
    )
    db.add(chunk)
    db.flush()
    return chunk


def list_speaker_anchors(
    db: Session, session: TranscriptionSession
) -> list[SpeakerAnchor]:
    return db.scalars(
        select(SpeakerAnchor)
        .where(SpeakerAnchor.session_id == session.id)
        .order_by(SpeakerAnchor.anchor_order, SpeakerAnchor.created_at)
    ).all()


def create_speaker_anchor(
    db: Session,
    *,
    session: TranscriptionSession,
    speaker_key: str,
    source_chunk_index: int,
    anchor_text: str,
    anchor_start_ms: int,
    anchor_end_ms: int,
    anchor_duration_ms: int,
    anchor_storage_path: str,
) -> SpeakerAnchor:
    existing = db.scalar(
        select(SpeakerAnchor).where(
            SpeakerAnchor.session_id == session.id,
            SpeakerAnchor.speaker_key == speaker_key,
        )
    )
    if existing is not None:
        return existing

    anchor = SpeakerAnchor(
        session_id=session.id,
        speaker_key=speaker_key,
        anchor_order=_next_anchor_order(db, session),
        source_chunk_index=source_chunk_index,
        anchor_text=anchor_text,
        anchor_start_ms=anchor_start_ms,
        anchor_end_ms=anchor_end_ms,
        anchor_duration_ms=anchor_duration_ms,
        anchor_storage_path=anchor_storage_path,
    )
    db.add(anchor)
    db.flush()
    return anchor


def mark_chunk_processing(db: Session, chunk: SessionChunk) -> None:
    chunk.process_status = CHUNK_PROCESS_PROCESSING
    chunk.processing_started_at = utcnow()
    chunk.processing_completed_at = None
    db.commit()
    db.refresh(chunk)


def mark_chunk_processed(
    db: Session,
    chunk: SessionChunk,
    *,
    segment_count: int,
    prepared_prefix_manifest_json: str | None = None,
    normalized_segments_json: str | None = None,
) -> None:
    chunk.process_status = CHUNK_PROCESS_PROCESSED
    chunk.result_segment_count = segment_count
    chunk.prepared_prefix_manifest_json = prepared_prefix_manifest_json
    chunk.normalized_segments_json = normalized_segments_json
    chunk.error_message = None
    chunk.processing_completed_at = utcnow()
    db.commit()
    db.refresh(chunk)


def reset_chunk_after_processing_failure(
    db: Session, chunk: SessionChunk, *, error_message: str
) -> None:
    session = chunk.session
    chunk.retry_count += 1
    chunk.error_message = error_message
    chunk.processing_completed_at = utcnow()

    if chunk.retry_count >= MAX_CHUNK_PROCESSING_RETRIES:
        chunk.process_status = CHUNK_PROCESS_FAILED
        if chunk.source_type == LIVE_CHUNK_SOURCE_TYPE and _session_has_usable_full_audio(session):
            session.status = AWAITING_FALLBACK_STATUS
            session.input_mode = LIVE_CHUNKS_INPUT_MODE
            session.selected_final_input_mode = LIVE_CHUNKS_INPUT_MODE
        else:
            session.status = "failed"
        session.last_error = error_message
    else:
        chunk.process_status = CHUNK_PROCESS_PENDING
        chunk.processing_started_at = None

    db.commit()
    db.refresh(chunk)
    db.refresh(session)


def recover_stale_processing_chunks(db: Session) -> bool:
    cutoff = utcnow() - timedelta(seconds=STALE_PROCESSING_THRESHOLD_SECONDS)
    processing_chunks = db.scalars(
        select(SessionChunk).where(SessionChunk.process_status == CHUNK_PROCESS_PROCESSING)
    ).all()
    recovered = False
    for chunk in processing_chunks:
        started_at = chunk.processing_started_at
        if started_at is not None and started_at > cutoff:
            continue
        chunk.process_status = CHUNK_PROCESS_PENDING
        chunk.processing_started_at = None
        chunk.processing_completed_at = None
        chunk.error_message = chunk.error_message or "recovered stale processing chunk"
        recovered = True
    if recovered:
        db.commit()
    return recovered


def mark_session_failed(db: Session, session: TranscriptionSession, *, error_message: str) -> None:
    session.status = "failed"
    session.last_error = error_message
    db.commit()
    db.refresh(session)


def delete_fallback_chunks_for_session(db: Session, session: TranscriptionSession) -> None:
    fallback_chunks = db.scalars(
        select(SessionChunk).where(
            SessionChunk.session_id == session.id,
            SessionChunk.source_type == FALLBACK_SPLIT_SOURCE_TYPE,
        )
    ).all()
    for chunk in fallback_chunks:
        db.delete(chunk)
    db.flush()


def advance_commit_frontier(db: Session, *, storage: LocalArtifactStorage) -> bool:
    advanced = False
    for session in _active_sessions(db):
        source_type = selected_source_type_for_session(session)
        next_index = session.last_committed_chunk_index + 1
        session_advanced = False

        while True:
            chunk = db.scalar(
                select(SessionChunk).where(
                    SessionChunk.session_id == session.id,
                    SessionChunk.source_type == source_type,
                    SessionChunk.chunk_index == next_index,
                    SessionChunk.upload_status == UPLOAD_STATUS_UPLOADED,
                )
            )
            if chunk is None or chunk.process_status != CHUNK_PROCESS_PROCESSED:
                break

            _persist_committed_speaker_anchors(
                db,
                session=session,
                chunk=chunk,
                storage=storage,
            )
            chunk.process_status = CHUNK_PROCESS_COMPLETED
            session.last_committed_chunk_index = next_index
            next_index += 1
            advanced = True
            session_advanced = True

        if session_advanced:
            _maybe_complete_session(db, session, source_type)

    if advanced:
        db.commit()
    return advanced


def _get_session_by_public_id(db: Session, public_session_id: str) -> TranscriptionSession:
    session = db.scalar(
        select(TranscriptionSession).where(
            TranscriptionSession.session_id == public_session_id
        )
    )
    if session is None:
        raise SessionNotFoundError(public_session_id)
    return session


def _active_sessions(db: Session) -> list[TranscriptionSession]:
    return db.scalars(
        select(TranscriptionSession)
        .where(~TranscriptionSession.status.in_(TERMINAL_SESSION_STATUSES))
        .order_by(TranscriptionSession.created_at, TranscriptionSession.session_id)
    ).all()


def _live_chunk_select(
    session: TranscriptionSession, chunk_index: int
) -> Select[tuple[SessionChunk]]:
    return select(SessionChunk).where(
        SessionChunk.session_id == session.id,
        SessionChunk.chunk_index == chunk_index,
        SessionChunk.source_type == LIVE_CHUNK_SOURCE_TYPE,
    )


def _handle_existing_live_chunk(
    *,
    db: Session,
    storage: LocalArtifactStorage,
    session: TranscriptionSession,
    chunk: SessionChunk,
    chunk_index: int,
    actual_sha256: str,
    audio_bytes: bytes,
) -> ChunkRecord:
    if chunk.sha256 != actual_sha256:
        raise ChunkHashConflictError(
            f"chunk {chunk_index} already exists with a different sha256"
        )

    if chunk.upload_status == UPLOAD_STATUS_UPLOADED and storage.exists(chunk.storage_path):
        return ChunkRecord(session=session, chunk=chunk, reused=True)

    try:
        storage.write_bytes(chunk.storage_path, audio_bytes)
    except Exception:
        _delete_chunk_and_restore_session_state(db=db, session=session, chunk=chunk)
        raise

    chunk.upload_status = UPLOAD_STATUS_UPLOADED
    session.status = "receiving_chunks"
    db.commit()
    db.refresh(session)
    db.refresh(chunk)
    return ChunkRecord(session=session, chunk=chunk, reused=False)


def _delete_chunk_and_restore_session_state(
    *, db: Session, session: TranscriptionSession, chunk: SessionChunk
) -> None:
    if db.get(SessionChunk, chunk.id) is not None:
        db.delete(chunk)
        db.flush()

    session.status = (
        "receiving_chunks" if _session_has_uploaded_live_chunks(db, session.id) else "created"
    )
    db.commit()
    db.refresh(session)


def _session_has_uploaded_live_chunks(db: Session, session_id) -> bool:
    uploaded_chunk = db.scalar(
        select(SessionChunk.id).where(
            SessionChunk.session_id == session_id,
            SessionChunk.source_type == LIVE_CHUNK_SOURCE_TYPE,
            SessionChunk.upload_status == UPLOAD_STATUS_UPLOADED,
        )
    )
    return uploaded_chunk is not None


def _session_has_usable_full_audio(session: TranscriptionSession) -> bool:
    return bool(session.final_audio_uploaded and session.final_audio_storage_path)


def _maybe_complete_session(
    db: Session, session: TranscriptionSession, source_type: str
) -> None:
    if session.status != "finalizing":
        return

    chunks = db.scalars(
        select(SessionChunk)
        .where(
            SessionChunk.session_id == session.id,
            SessionChunk.source_type == source_type,
            SessionChunk.upload_status == UPLOAD_STATUS_UPLOADED,
        )
        .order_by(SessionChunk.chunk_index)
    ).all()
    if not chunks:
        return

    if any(chunk.process_status != CHUNK_PROCESS_COMPLETED for chunk in chunks):
        return

    if session.last_committed_chunk_index != chunks[-1].chunk_index:
        return

    if source_type == LIVE_CHUNK_SOURCE_TYPE:
        if session.expected_chunk_count is None:
            return
        if session.last_committed_chunk_index != session.expected_chunk_count - 1:
            return

    session.status = "completed"
    session.finalized_at = session.finalized_at or utcnow()


def _persist_committed_speaker_anchors(
    db: Session,
    *,
    session: TranscriptionSession,
    chunk: SessionChunk,
    storage: LocalArtifactStorage,
) -> None:
    normalized_segments = _chunk_normalized_segments(chunk)
    if not normalized_segments:
        return

    existing_keys = {anchor.speaker_key for anchor in list_speaker_anchors(db, session)}
    speaker_segments: OrderedDict[str, list[Segment]] = OrderedDict()
    for segment in sorted(normalized_segments, key=lambda item: (item.start_ms, item.end_ms)):
        speaker_key = segment.speaker_key or stable_speaker_key(segment.speaker_label)
        if not speaker_key or speaker_key in existing_keys:
            continue
        speaker_segments.setdefault(speaker_key, []).append(segment)

    for speaker_key, segments in speaker_segments.items():
        candidate = select_anchor_candidate(segments, chunk_end_ms=chunk.end_ms)
        if candidate is None:
            continue
        anchor_metadata = _write_anchor_artifact(
            storage,
            chunk=chunk,
            session_id=session.session_id,
            speaker_key=speaker_key,
            candidate=candidate,
        )
        if anchor_metadata is None:
            continue
        create_speaker_anchor(
            db,
            session=session,
            speaker_key=speaker_key,
            source_chunk_index=chunk.chunk_index,
            anchor_text=candidate.text,
            anchor_start_ms=anchor_metadata["anchor_start_ms"],
            anchor_end_ms=anchor_metadata["anchor_end_ms"],
            anchor_duration_ms=anchor_metadata["anchor_duration_ms"],
            anchor_storage_path=anchor_metadata["anchor_storage_path"],
        )
        existing_keys.add(speaker_key)


def _chunk_normalized_segments(chunk: SessionChunk) -> list[Segment]:
    if not chunk.normalized_segments_json:
        return []
    payload = json.loads(chunk.normalized_segments_json)
    if not isinstance(payload, list):
        return []
    return segments_from_payload(payload)


def _write_anchor_artifact(
    storage: LocalArtifactStorage,
    *,
    chunk: SessionChunk,
    session_id: str,
    speaker_key: str,
    candidate: Segment,
) -> dict[str, object] | None:
    storage_path = storage.session_path(session_id, "anchors", f"{speaker_key}.wav")
    anchor_start_ms = max(chunk.start_ms, candidate.start_ms - 200)
    anchor_end_ms = min(chunk.end_ms, candidate.end_ms + 300)
    duration_ms = anchor_end_ms - anchor_start_ms
    if duration_ms <= 0:
        return None

    source_path = storage.resolve(chunk.storage_path)
    destination_path = storage.resolve(storage_path)
    destination_path.parent.mkdir(parents=True, exist_ok=True)

    with wave.open(str(source_path), "rb") as source_wav:
        frame_rate = source_wav.getframerate()
        start_frame = max(0, int(anchor_start_ms - chunk.start_ms) * frame_rate // 1000)
        end_frame = max(start_frame, int(anchor_end_ms - chunk.start_ms) * frame_rate // 1000)
        frame_count = end_frame - start_frame
        source_wav.setpos(start_frame)
        frames = source_wav.readframes(frame_count)

        with wave.open(str(destination_path), "wb") as destination_wav:
            destination_wav.setnchannels(source_wav.getnchannels())
            destination_wav.setsampwidth(source_wav.getsampwidth())
            destination_wav.setframerate(frame_rate)
            destination_wav.writeframes(frames)

    return {
        "anchor_storage_path": storage_path,
        "anchor_start_ms": anchor_start_ms,
        "anchor_end_ms": anchor_end_ms,
        "anchor_duration_ms": duration_ms,
    }


def _next_anchor_order(db: Session, session: TranscriptionSession) -> int:
    anchors = list_speaker_anchors(db, session)
    if not anchors:
        return 0
    return anchors[-1].anchor_order + 1
