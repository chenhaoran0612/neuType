"""Transcriber interface for chunk worker processing."""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from meeting_transcription.models import SessionChunk, TranscriptionSession


@runtime_checkable
class ChunkTranscriber(Protocol):
    """Minimal protocol used by the worker to transcribe one chunk."""

    def transcribe_chunk(
        self, *, session: TranscriptionSession, chunk: SessionChunk, audio_path: str
    ) -> dict[str, object]:
        """Return parsed metadata for one chunk."""
        ...
