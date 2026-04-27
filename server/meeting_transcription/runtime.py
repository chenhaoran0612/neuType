"""Runtime settings and factory helpers for meeting transcription workers."""

from __future__ import annotations

from dataclasses import dataclass
import os

from meeting_transcription.gradio_transcriber import GradioChunkTranscriber
from meeting_transcription.transcriber import ChunkTranscriber
from meeting_transcription.translation import (
    NoopSegmentTranslator,
    OpenAICompatibleSegmentTranslator,
    SegmentTranslator,
)

DEFAULT_GRADIO_BASE_URL = "https://546463aae3e7327f37.gradio.live/"


@dataclass(frozen=True, slots=True)
class WorkerRuntimeSettings:
    gradio_base_url: str
    max_tokens: int
    temperature: float
    top_p: float
    do_sample: bool
    context_info: str
    idle_sleep_seconds: float
    translation_base_url: str
    translation_api_key: str
    translation_model: str
    translation_timeout_seconds: float


def load_worker_runtime_settings() -> WorkerRuntimeSettings:
    return WorkerRuntimeSettings(
        gradio_base_url=_env_str(
            "MEETING_TRANSCRIPTION_GRADIO_BASE_URL",
            default=DEFAULT_GRADIO_BASE_URL,
        ),
        max_tokens=_env_int("MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS", default=8192),
        temperature=_env_float("MEETING_TRANSCRIPTION_GRADIO_TEMPERATURE", default=0.0),
        top_p=_env_float("MEETING_TRANSCRIPTION_GRADIO_TOP_P", default=1.0),
        do_sample=_env_bool("MEETING_TRANSCRIPTION_GRADIO_DO_SAMPLE", default=False),
        context_info=_env_str("MEETING_TRANSCRIPTION_GRADIO_CONTEXT_INFO", default=""),
        idle_sleep_seconds=_env_float(
            "MEETING_TRANSCRIPTION_WORKER_IDLE_SLEEP_SECONDS", default=1.0
        ),
        translation_base_url=_env_str(
            "MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL", default=""
        ),
        translation_api_key=_env_str(
            "MEETING_TRANSCRIPTION_TRANSLATION_API_KEY", default=""
        ),
        translation_model=_env_str(
            "MEETING_TRANSCRIPTION_TRANSLATION_MODEL", default=""
        ),
        translation_timeout_seconds=_env_float(
            "MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS", default=60.0
        ),
    )


def create_chunk_transcriber_from_settings(
    settings: WorkerRuntimeSettings,
) -> ChunkTranscriber:
    if not settings.gradio_base_url:
        raise RuntimeError("MEETING_TRANSCRIPTION_GRADIO_BASE_URL must not be empty")
    return GradioChunkTranscriber(
        base_url=settings.gradio_base_url,
        max_tokens=settings.max_tokens,
        temperature=settings.temperature,
        top_p=settings.top_p,
        do_sample=settings.do_sample,
        context_info=settings.context_info,
    )


def create_segment_translator_from_settings(
    settings: WorkerRuntimeSettings,
) -> SegmentTranslator:
    if (
        not settings.translation_base_url
        or not settings.translation_api_key
        or not settings.translation_model
    ):
        return NoopSegmentTranslator()

    return OpenAICompatibleSegmentTranslator(
        base_url=settings.translation_base_url,
        api_key=settings.translation_api_key,
        model=settings.translation_model,
        timeout_seconds=settings.translation_timeout_seconds,
    )


def _env_str(name: str, *, default: str) -> str:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip()


def _env_int(name: str, *, default: int) -> int:
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    return int(value)


def _env_float(name: str, *, default: float) -> float:
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    return float(value)


def _env_bool(name: str, *, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be a boolean-like value")
