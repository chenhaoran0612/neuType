"""ORM models for meeting transcription persistence."""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID, uuid4

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    false,
    text,
)
from sqlalchemy.types import TypeDecorator
from sqlalchemy.orm import Mapped, mapped_column, relationship

from meeting_transcription.db import Base


def utcnow() -> datetime:
    """Return a timezone-aware timestamp in UTC."""
    return datetime.now(timezone.utc)


class UTCDateTime(TypeDecorator[datetime]):
    """Persist UTC datetimes while returning timezone-aware UTC values."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is None:
            return None

        if value.tzinfo is None:
            raise ValueError("Datetime values must be timezone-aware")

        normalized = value.astimezone(timezone.utc)
        if dialect.name == "sqlite":
            return normalized.replace(tzinfo=None)
        return normalized

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        del dialect
        if value is None:
            return None

        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


class TranscriptionSession(Base):
    """Represents one server-side meeting transcription session."""

    __tablename__ = "transcription_sessions"

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    session_id: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    client_session_token: Mapped[str] = mapped_column(
        String(255), unique=True, nullable=False
    )
    status: Mapped[str] = mapped_column(String(64), nullable=False)
    input_mode: Mapped[str] = mapped_column(String(64), nullable=False)
    chunk_duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    chunk_overlap_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    expected_chunk_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    selected_final_input_mode: Mapped[str | None] = mapped_column(
        String(64), nullable=True
    )
    final_audio_uploaded: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=false()
    )
    final_audio_sha256: Mapped[str | None] = mapped_column(String(128), nullable=True)
    final_audio_storage_path: Mapped[str | None] = mapped_column(
        String(512), nullable=True
    )
    last_committed_chunk_index: Mapped[int] = mapped_column(
        Integer, nullable=False, default=-1, server_default=text("-1")
    )
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        nullable=False,
        default=utcnow,
        server_default=text("CURRENT_TIMESTAMP"),
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        nullable=False,
        default=utcnow,
        onupdate=utcnow,
        server_default=text("CURRENT_TIMESTAMP"),
    )
    finalized_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)

    chunks: Mapped[list["SessionChunk"]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        order_by=lambda: (SessionChunk.chunk_index, SessionChunk.source_type),
    )
    speaker_anchors: Mapped[list["SpeakerAnchor"]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        order_by=lambda: SpeakerAnchor.anchor_order,
    )


class SessionChunk(Base):
    """Represents an uploaded or derived audio chunk for a session."""

    __tablename__ = "session_chunks"
    __table_args__ = (
        UniqueConstraint(
            "session_id",
            "chunk_index",
            "source_type",
            name="uq_session_chunks_session_id_chunk_index_source_type",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    session_id: Mapped[UUID] = mapped_column(
        ForeignKey("transcription_sessions.id", ondelete="CASCADE"), nullable=False
    )
    chunk_index: Mapped[int] = mapped_column(Integer, nullable=False)
    source_type: Mapped[str] = mapped_column(String(64), nullable=False)
    start_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    end_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    sha256: Mapped[str] = mapped_column(String(128), nullable=False)
    storage_path: Mapped[str] = mapped_column(String(512), nullable=False)
    upload_status: Mapped[str] = mapped_column(String(64), nullable=False)
    process_status: Mapped[str] = mapped_column(String(64), nullable=False)
    retry_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default=text("0")
    )
    processing_started_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    processing_completed_at: Mapped[datetime | None] = mapped_column(
        UTCDateTime(), nullable=True
    )
    result_segment_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    prepared_prefix_manifest_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    normalized_segments_json: Mapped[str | None] = mapped_column(Text, nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        nullable=False,
        default=utcnow,
        server_default=text("CURRENT_TIMESTAMP"),
    )
    updated_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        nullable=False,
        default=utcnow,
        onupdate=utcnow,
        server_default=text("CURRENT_TIMESTAMP"),
    )

    session: Mapped[TranscriptionSession] = relationship(back_populates="chunks")


class SpeakerAnchor(Base):
    """Represents a persisted speaker anchor chosen from prior chunk output."""

    __tablename__ = "speaker_anchors"
    __table_args__ = (
        UniqueConstraint("session_id", "speaker_key", name="uq_speaker_anchors_session_id_speaker_key"),
        UniqueConstraint("session_id", "anchor_order", name="uq_speaker_anchors_session_id_anchor_order"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    session_id: Mapped[UUID] = mapped_column(
        ForeignKey("transcription_sessions.id", ondelete="CASCADE"), nullable=False
    )
    speaker_key: Mapped[str] = mapped_column(String(255), nullable=False)
    anchor_order: Mapped[int] = mapped_column(Integer, nullable=False)
    source_chunk_index: Mapped[int] = mapped_column(Integer, nullable=False)
    anchor_text: Mapped[str] = mapped_column(Text, nullable=False)
    anchor_start_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    anchor_end_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    anchor_duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    anchor_storage_path: Mapped[str] = mapped_column(String(512), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        UTCDateTime(),
        nullable=False,
        default=utcnow,
        server_default=text("CURRENT_TIMESTAMP"),
    )

    session: Mapped[TranscriptionSession] = relationship(back_populates="speaker_anchors")


__all__ = ["Base", "SessionChunk", "SpeakerAnchor", "TranscriptionSession"]
