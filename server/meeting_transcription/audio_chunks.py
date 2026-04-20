"""Server-side fallback full-audio chunk splitting helpers."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import io
import wave


@dataclass(slots=True)
class SplitChunk:
    """One server-generated chunk derived from a full-audio fallback artifact."""

    chunk_index: int
    start_ms: int
    end_ms: int
    duration_ms: int
    audio_bytes: bytes
    sha256: str


def split_full_audio_into_chunks(
    audio_path: str, chunk_duration_ms: int, overlap_ms: int
) -> list[SplitChunk]:
    """Split a WAV file into overlapped chunks for fallback processing."""
    if overlap_ms < 0:
        raise ValueError("overlap_ms must be non-negative")
    if chunk_duration_ms <= 0:
        raise ValueError("chunk_duration_ms must be positive")
    if overlap_ms >= chunk_duration_ms:
        raise ValueError("overlap_ms must be smaller than chunk_duration_ms")

    with wave.open(audio_path, "rb") as wav_file:
        params = wav_file.getparams()
        frame_rate = wav_file.getframerate()
        sample_width = wav_file.getsampwidth()
        channel_count = wav_file.getnchannels()
        total_frames = wav_file.getnframes()
        raw_frames = wav_file.readframes(total_frames)

    frame_size = sample_width * channel_count
    total_duration_ms = (total_frames * 1000) // frame_rate
    if total_duration_ms <= 0:
        return []

    chunks: list[SplitChunk] = []
    start_ms = 0
    chunk_index = 0
    stride_ms = chunk_duration_ms - overlap_ms

    while start_ms < total_duration_ms:
        end_ms = min(total_duration_ms, start_ms + chunk_duration_ms)
        start_frame = (start_ms * frame_rate) // 1000
        end_frame = (end_ms * frame_rate) // 1000
        audio_bytes = _build_wav_bytes(
            params,
            raw_frames[start_frame * frame_size : end_frame * frame_size],
        )
        chunks.append(
            SplitChunk(
                chunk_index=chunk_index,
                start_ms=start_ms,
                end_ms=end_ms,
                duration_ms=end_ms - start_ms,
                audio_bytes=audio_bytes,
                sha256=hashlib.sha256(audio_bytes).hexdigest(),
            )
        )
        if end_ms >= total_duration_ms:
            break
        chunk_index += 1
        start_ms += stride_ms

    return chunks


def _build_wav_bytes(params: tuple, frames: bytes) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setparams(params)
        wav_file.writeframes(frames)
    return buffer.getvalue()
