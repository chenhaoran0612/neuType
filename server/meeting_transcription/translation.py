"""Segment translation helpers for meeting transcript chunks."""

from __future__ import annotations

import json
import logging
import re
from typing import Protocol

import httpx

from meeting_transcription.anchor_audio import Segment

LANGUAGE_KEYS = ("en", "zh", "ar")
SegmentTranslations = dict[str, str]
logger = logging.getLogger(__name__)


class SegmentTranslator(Protocol):
    """Translate normalized transcript segments into supported languages."""

    def translate_segments(
        self, segments: list[Segment]
    ) -> dict[int, SegmentTranslations]:
        """Return translations keyed by segment index."""
        ...


class NoopSegmentTranslator:
    """Translator used when segment translation is not configured."""

    def translate_segments(
        self, segments: list[Segment]
    ) -> dict[int, SegmentTranslations]:
        return {index: empty_translations() for index, _ in enumerate(segments)}


class OpenAICompatibleSegmentTranslator:
    """Translate segments through an OpenAI-compatible chat completions endpoint."""

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model: str,
        timeout_seconds: float = 60.0,
        batch_size: int = 1,
        max_attempts: int = 2,
        client: httpx.Client | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key.strip()
        self.model = model.strip()
        self.timeout_seconds = timeout_seconds
        self.batch_size = max(1, int(batch_size))
        self.max_attempts = max(1, int(max_attempts))
        self.client = client

    def translate_segments(
        self, segments: list[Segment]
    ) -> dict[int, SegmentTranslations]:
        if not segments:
            return {}

        translations: dict[int, SegmentTranslations] = {}
        for offset in range(0, len(segments), self.batch_size):
            batch = segments[offset : offset + self.batch_size]
            try:
                batch_translations = self._translate_batch_with_retries(batch)
            except Exception:
                logger.exception(
                    "segment translation batch failed model=%s offset=%s size=%s",
                    self.model,
                    offset,
                    len(batch),
                )
                continue
            for batch_index, translation in batch_translations.items():
                translations[offset + batch_index] = translation
        return translations

    def _translate_batch_with_retries(
        self, segments: list[Segment]
    ) -> dict[int, SegmentTranslations]:
        for attempt in range(1, self.max_attempts + 1):
            try:
                return self._translate_batch(segments)
            except Exception:
                if attempt >= self.max_attempts:
                    raise
                logger.warning(
                    "segment translation batch retrying model=%s attempt=%s/%s size=%s",
                    self.model,
                    attempt + 1,
                    self.max_attempts,
                    len(segments),
                    exc_info=True,
                )
        return {}

    def _translate_batch(self, segments: list[Segment]) -> dict[int, SegmentTranslations]:
        payload = {
            "model": self.model,
            "temperature": 0,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": self._system_prompt()},
                {
                    "role": "user",
                    "content": json.dumps(
                        self._segments_payload(segments), ensure_ascii=False
                    ),
                },
            ],
        }
        response = self._client().post(
            self._chat_completions_url(),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )
        response.raise_for_status()
        body = response.json()
        content = body["choices"][0]["message"]["content"]
        return coerce_translation_response(content, segment_count=len(segments))

    def _chat_completions_url(self) -> str:
        if self.base_url.lower().endswith("/chat/completions"):
            return self.base_url
        return f"{self.base_url}/chat/completions"

    def _client(self) -> httpx.Client:
        if self.client is not None:
            return self.client
        self.client = httpx.Client(timeout=httpx.Timeout(self.timeout_seconds))
        return self.client

    def _system_prompt(self) -> str:
        return (
            "You are a strict transcript translation engine. Return only one valid "
            "JSON object. For every input segment, output index, en, zh, and ar. "
            "All three language fields are mandatory and must be non-empty. en must "
            "be English, zh must be Simplified Chinese, ar must be Arabic. If the "
            "source is already one of these languages, still fill that target "
            "language with the source meaning, cleaned if needed. Preserve meaning, "
            "names, numbers, and technical terms. Do not summarize or omit details. "
            "Return only JSON with shape "
            '{"segments":[{"index":0,"en":"...","zh":"...","ar":"..."}]}.'
        )

    def _segments_payload(self, segments: list[Segment]) -> dict[str, object]:
        return {
            "segments": [
                {"index": index, "text": segment.text}
                for index, segment in enumerate(segments)
            ]
        }


def apply_translations(
    segments: list[Segment],
    translations_by_index: dict[int, SegmentTranslations],
) -> list[Segment]:
    return [
        segment.copy_with(
            translations=normalized_translations(translations_by_index.get(index, {}))
        )
        for index, segment in enumerate(segments)
    ]


def segments_with_empty_translations(segments: list[Segment]) -> list[Segment]:
    return apply_translations(segments, {})


def empty_translations() -> SegmentTranslations:
    return {key: "" for key in LANGUAGE_KEYS}


def normalized_translations(
    raw: dict[str, object] | SegmentTranslations,
) -> SegmentTranslations:
    values = empty_translations()
    for key in LANGUAGE_KEYS:
        value = raw.get(key)
        values[key] = str(value).strip() if value is not None else ""
    return values


def coerce_translation_response(
    content: str, *, segment_count: int
) -> dict[int, SegmentTranslations]:
    payload = _json_object_from_content(content)
    raw_segments = payload.get("segments", [])
    if not isinstance(raw_segments, list):
        return {}

    translations: dict[int, SegmentTranslations] = {}
    for item in raw_segments:
        if not isinstance(item, dict):
            continue
        try:
            index = int(item["index"])
        except (KeyError, TypeError, ValueError):
            continue
        if 0 <= index < segment_count:
            translations[index] = normalized_translations(item)
    return translations


def _json_object_from_content(content: str) -> dict[str, object]:
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", content, flags=re.DOTALL)
        if match is None:
            return {}
        try:
            parsed = json.loads(match.group(0))
        except json.JSONDecodeError:
            return {}
    return parsed if isinstance(parsed, dict) else {}
