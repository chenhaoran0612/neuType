"""Segment translation helpers for meeting transcript chunks."""

from __future__ import annotations

import json
import re
from typing import Protocol

import httpx

from meeting_transcription.anchor_audio import Segment

LANGUAGE_KEYS = ("en", "zh", "ar")
SegmentTranslations = dict[str, str]


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
        client: httpx.Client | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key.strip()
        self.model = model.strip()
        self.timeout_seconds = timeout_seconds
        self.client = client

    def translate_segments(
        self, segments: list[Segment]
    ) -> dict[int, SegmentTranslations]:
        if not segments:
            return {}

        payload = {
            "model": self.model,
            "temperature": 0,
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
            f"{self.base_url}/chat/completions",
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

    def _client(self) -> httpx.Client:
        if self.client is not None:
            return self.client
        self.client = httpx.Client(timeout=httpx.Timeout(self.timeout_seconds))
        return self.client

    def _system_prompt(self) -> str:
        return (
            "Translate each transcript segment into English, Simplified Chinese, "
            "and Arabic. Preserve meaning, names, numbers, and technical terms. "
            "Do not summarize. Return only JSON with shape "
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
