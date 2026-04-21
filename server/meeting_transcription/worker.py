"""Background worker loop for meeting transcription chunks."""

from __future__ import annotations

import json
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from meeting_transcription import repositories
from meeting_transcription.anchor_audio import (
    PersistedAnchor,
    PrefixManifest,
    PrefixPlan,
    Segment,
    build_prefix_plan,
    build_speaker_label_map,
    manifest_from_dict,
    remap_real_chunk_segments,
    segments_from_payload,
    segments_to_payload,
    strip_prefix_segments,
)
from meeting_transcription.audio_chunks import split_full_audio_into_chunks
from meeting_transcription.models import TranscriptionSession
from meeting_transcription.storage import LocalArtifactStorage
from meeting_transcription.transcriber import ChunkTranscriber


def run_pending_chunk_once(
    db: Session,
    transcriber: ChunkTranscriber,
    *,
    storage: LocalArtifactStorage,
) -> bool:
    """Run one worker step: advance commits, split fallback audio, or process a chunk."""
    if repositories.advance_commit_frontier(db, storage=storage):
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
    prefix_plan = _prepare_prefix_plan(db, session)
    transcription_audio_path, effective_prefix_manifest = _prepare_transcription_audio(
        storage,
        session_id=session.session_id,
        chunk=chunk,
        prefix_plan=prefix_plan,
    )
    try:
        result = transcriber.transcribe_chunk(
            session=session,
            chunk=chunk,
            audio_path=transcription_audio_path,
            prefix_plan=prefix_plan,
        )
        normalized_segments, effective_manifest = _normalize_result_segments(
            chunk_start_ms=chunk.start_ms,
            chunk_end_ms=chunk.end_ms,
            result=result,
            fallback_manifest=effective_prefix_manifest,
        )
        repositories.mark_chunk_processed(
            db,
            chunk,
            segment_count=(
                len(normalized_segments)
                if normalized_segments is not None
                else int(result.get("segment_count", 0))
            ),
            prepared_prefix_manifest_json=_manifest_json(
                effective_manifest
                or (prefix_plan.manifest if prefix_plan is not None else None)
            ),
            normalized_segments_json=(
                json.dumps(segments_to_payload(normalized_segments))
                if normalized_segments is not None
                else None
            ),
        )
    except Exception as exc:
        repositories.reset_chunk_after_processing_failure(
            db, chunk, error_message=str(exc)
        )
        return True

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

        written_artifact_paths: list[str] = []
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
                written_artifact_paths.append(storage_path)
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
            session_id = session.id
            db.rollback()
            for logical_path in reversed(written_artifact_paths):
                artifact_path = storage.resolve(logical_path)
                if artifact_path.exists():
                    artifact_path.unlink()
                    _remove_empty_parents(artifact_path.parent, storage.root)
            reloaded_session = db.get(TranscriptionSession, session_id)
            repositories.mark_session_failed(
                db,
                reloaded_session,
                error_message=f"fallback wav materialization failed: {exc}",
            )
        return True

    return False


def _prepare_prefix_plan(db: Session, session: TranscriptionSession) -> PrefixPlan | None:
    persisted_anchors = [
        PersistedAnchor(
            speaker_key=anchor.speaker_key,
            anchor_order=anchor.anchor_order,
            anchor_text=anchor.anchor_text,
            anchor_duration_ms=anchor.anchor_duration_ms,
            anchor_storage_path=anchor.anchor_storage_path,
        )
        for anchor in repositories.list_speaker_anchors(db, session)
    ]
    return build_prefix_plan(persisted_anchors)


def _prepare_transcription_audio(
    storage: LocalArtifactStorage,
    *,
    session_id: str,
    chunk,
    prefix_plan: PrefixPlan | None,
) -> tuple[str, PrefixManifest | None]:
    raw_audio_path = str(storage.resolve(chunk.storage_path))
    if prefix_plan is None:
        return raw_audio_path, None

    prefixed_storage_path = storage.session_path(
        session_id, "artifacts", "prefix", f"{chunk.chunk_index}.wav"
    )
    payload_parts: list[bytes] = []
    for anchor in prefix_plan.anchors:
        payload_parts.append(storage.read_bytes(anchor.anchor_storage_path))
        payload_parts.append(b"|GAP|")
    payload_parts.append(b"|REAL|")
    payload_parts.append(storage.read_bytes(chunk.storage_path))
    storage.write_bytes(prefixed_storage_path, b"".join(payload_parts))
    return str(storage.resolve(prefixed_storage_path)), prefix_plan.manifest


def _normalize_result_segments(
    *,
    chunk_start_ms: int,
    chunk_end_ms: int,
    result: dict[str, object],
    fallback_manifest: PrefixManifest | None,
) -> tuple[list[Segment] | None, PrefixManifest | None]:
    manifest_payload = result.get("prefix_manifest")
    segments_payload = result.get("segments")

    if manifest_payload is None and segments_payload is None:
        return None, fallback_manifest
    if segments_payload is None:
        raise ValueError("prefix metadata included manifest without segments")
    if not isinstance(segments_payload, list):
        raise ValueError("segments payload must be a list")

    segments = segments_from_payload(segments_payload)
    manifest = _coerce_manifest_payload(manifest_payload, fallback_manifest)
    if manifest is None:
        return (
            remap_real_chunk_segments(
                _normalize_segments_without_prefix(
                    segments,
                    chunk_start_ms=chunk_start_ms,
                    chunk_end_ms=chunk_end_ms,
                ),
                {},
                chunk_start_ms=0,
                real_chunk_offset_ms=0,
            ),
            None,
        )

    label_map = build_speaker_label_map(segments, manifest)
    kept_segments = strip_prefix_segments(segments, manifest)
    return (
        remap_real_chunk_segments(
            kept_segments,
            label_map,
            chunk_start_ms=chunk_start_ms,
            real_chunk_offset_ms=manifest.real_chunk_offset_ms,
        ),
        manifest,
    )


def _coerce_manifest_payload(
    manifest_payload: object,
    fallback_manifest: PrefixManifest | None,
) -> PrefixManifest | None:
    if manifest_payload is None:
        return fallback_manifest
    if not isinstance(manifest_payload, dict):
        raise ValueError("prefix_manifest must be an object")
    return manifest_from_dict(manifest_payload)


def _manifest_json(manifest: PrefixManifest | None) -> str | None:
    if manifest is None:
        return None
    return json.dumps(manifest.as_dict())


def _normalize_segments_without_prefix(
    segments: list[Segment],
    *,
    chunk_start_ms: int,
    chunk_end_ms: int,
) -> list[Segment]:
    normalized: list[Segment] = []
    for segment in segments:
        if segment.start_ms >= chunk_start_ms and segment.end_ms <= chunk_end_ms:
            normalized.append(segment)
            continue
        normalized.extend(
            remap_real_chunk_segments(
                [segment],
                {},
                chunk_start_ms=chunk_start_ms,
                real_chunk_offset_ms=0,
            )
        )
    return normalized


def _remove_empty_parents(start: Path, root: Path) -> None:
    current = start
    while current != root:
        try:
            current.rmdir()
        except OSError:
            break
        current = current.parent
