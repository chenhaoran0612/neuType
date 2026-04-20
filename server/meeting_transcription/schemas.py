"""Pydantic schemas for meeting transcription session APIs."""

from __future__ import annotations

from typing import Generic, TypeVar
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field

DataT = TypeVar("DataT")


class APIError(BaseModel):
    """Structured API error payload."""

    code: str
    message: str


class Envelope(BaseModel, Generic[DataT]):
    """Standard response envelope for API responses."""

    request_id: str
    data: DataT | None
    error: APIError | None


def envelope(
    data: BaseModel | dict[str, object] | None = None,
    *,
    error: APIError | None = None,
    request_id: str | None = None,
) -> dict[str, object | None]:
    """Return a JSON-serializable response envelope."""
    encoded_data: object | None
    if isinstance(data, BaseModel):
        encoded_data = data.model_dump(mode="json")
    else:
        encoded_data = data

    return {
        "request_id": request_id or f"req_{uuid4().hex}",
        "data": encoded_data,
        "error": error.model_dump(mode="json") if error is not None else None,
    }


class CreateSessionRequest(BaseModel):
    """Request body for creating or resuming a transcription session."""

    client_session_token: str = Field(min_length=1)
    source: str = Field(min_length=1)
    chunk_duration_ms: int = Field(gt=0)
    chunk_overlap_ms: int = Field(ge=0)
    audio_format: str = Field(min_length=1)
    sample_rate_hz: int = Field(gt=0)
    channel_count: int = Field(gt=0)


class CreateSessionResponse(BaseModel):
    """Response payload for a created or reused session."""

    model_config = ConfigDict(from_attributes=True)

    session_id: str
    status: str
    input_mode: str
    chunk_duration_ms: int
    chunk_overlap_ms: int


class UploadChunkResponse(BaseModel):
    """Response payload for live chunk uploads."""

    session_id: str
    chunk_index: int
    status: str
    upload_status: str
    process_status: str


class FinalizeSessionRequest(BaseModel):
    """Request payload for marking a session finalized."""

    expected_chunk_count: int | None = Field(default=None, ge=0)
    preferred_input_mode: str = "live_chunks"
    allow_full_audio_fallback: bool = True
    recording_ended_at_ms: int | None = Field(default=None, ge=0)


class FinalizeSessionResponse(BaseModel):
    """Response payload for finalize requests."""

    session_id: str
    status: str
    selected_input_mode: str
    missing_chunk_indexes: list[int] = Field(default_factory=list)


class SessionStatusResponse(BaseModel):
    """Response payload for polling session state."""

    session_id: str
    status: str
    input_mode: str
    chunk_duration_ms: int
    chunk_overlap_ms: int
    expected_chunk_count: int | None
    uploaded_chunk_count: int
