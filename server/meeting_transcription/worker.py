"""Background worker loop for meeting transcription chunks."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from meeting_transcription.audio_chunks import split_full_audio_into_chunks
from meeting_transcription.models import TranscriptionSession
from meeting_transcription import repositories
from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.transcriber import ChunkTranscriber


def run_pending_chunk_once(
    db: Session,
    transcriber: ChunkTranscriber,
    *,
    storage: LocalArtifactStorage,
) -> bool:
    """Run one worker step: advance commits, split fallback audio, or process a chunk."""
    if repositories.advance_commit_frontier(db):
        return True

    if repositories.recover_stale_processing_chunks(db):
        return True

    if _materialize_fallback_chunks_once(db, storage=storage):
        return True

    chunk = repositories.next_pending_chunk(db)
    if chunk is None:
        return False

    repositories.mark_chunk_processing(db, chunk)
    session = chunk.session
    try:
        result = transcriber.transcribe_chunk(
            session=session,
            chunk=chunk,
            audio_path=str(storage.resolve(chunk.storage_path)),
        )
    except Exception as exc:
        repositories.reset_chunk_after_processing_failure(
            db, chunk, error_message=str(exc)
        )
        return True

    repositories.mark_chunk_processed(
        db,
        chunk,
        segment_count=int(result.get("segment_count", 0)),
    )
    return True


def _materialize_fallback_chunks_once(db: Session, *, storage: LocalArtifactStorage) -> bool:
    sessions = db.scalars(
        select(TranscriptionSession)
        .where(~TranscriptionSession.status.in_(repositories.TERMINAL_SESSION_STATUSES))
        .order_by(TranscriptionSession.created_at, TranscriptionSession.session_id)
    ).all()

    for session in sessions:
        if session.selected_final_input_mode != repositories.FULL_AUDIO_FALLBACK_INPUT_MODE:
            continue
        if not session.final_audio_storage_path:
            continue
        if repositories.fallback_chunks_exist(db, session):
            continue

        try:
            split_chunks = split_full_audio_into_chunks(
                str(storage.resolve(session.final_audio_storage_path)),
                session.chunk_duration_ms,
                session.chunk_overlap_ms,
            )
            if not split_chunks:
                raise ValueError("fallback full audio split produced zero chunks")

            for split_chunk in split_chunks:
                storage_path = storage.session_path(
                    session.session_id,
                    "fallback-split-chunks",
                    f"{split_chunk.chunk_index}.wav",
                )
                storage.write_bytes(storage_path, split_chunk.audio_bytes)
                repositories.create_fallback_chunk(
                    db,
                    session=session,
                    chunk_index=split_chunk.chunk_index,
                    start_ms=split_chunk.start_ms,
                    end_ms=split_chunk.end_ms,
                    duration_ms=split_chunk.duration_ms,
                    sha256=split_chunk.sha256,
                    storage_path=storage_path,
                )
            db.commit()
        except Exception as exc:
            repositories.mark_session_failed(
                db, session, error_message=f"fallback wav materialization failed: {exc}"
            )
        return True

    return False
