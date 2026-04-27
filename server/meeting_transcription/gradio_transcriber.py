"""Gradio-backed chunk transcriber for the meeting transcription worker."""

from __future__ import annotations

import ast
from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any

import httpx
from gradio_client import Client, handle_file

from meeting_transcription.transcriber import ChunkTranscriber

_PLACEHOLDER_PHRASES = {
    "",
    "noise",
    "environmental sounds",
    "background noise",
    "silence",
    "music",
    "applause",
    "laughter",
    "breathing",
    "static",
    "non-speech",
}

@dataclass(slots=True)
class GradioChunkTranscriber(ChunkTranscriber):
    base_url: str
    max_tokens: int = 8192
    temperature: float = 0.0
    top_p: float = 1.0
    do_sample: bool = False
    context_info: str = ""
    client: Any | None = None
    httpx_kwargs: dict[str, Any] | None = None

    def transcribe_chunk(
        self,
        *,
        session,
        chunk,
        audio_path: str,
        prefix_plan=None,
    ) -> dict[str, object]:
        del session, chunk, prefix_plan
        file_payload = handle_file(audio_path)
        prediction = self._client.predict(
            file_input=None,
            audio_rec=file_payload,
            video_rec=None,
            audio_prev=file_payload,
            video_prev=None,
            max_tokens=self.max_tokens,
            temp=self.temperature,
            top_p=self.top_p,
            do_sample=self.do_sample,
            context_info=self.context_info,
            api_name="/transcribe_wrapper",
        )
        return self._normalize_prediction(prediction)

    @property
    def _client(self):
        if self.client is None:
            self.client = Client(
                self.base_url,
                verbose=False,
                download_files=False,
                httpx_kwargs=self._httpx_kwargs(),
            )
        return self.client

    def _httpx_kwargs(self) -> dict[str, Any]:
        if self.httpx_kwargs is not None:
            return dict(self.httpx_kwargs)
        return {"timeout": httpx.Timeout(timeout=None)}

    def _normalize_prediction(self, prediction: Any) -> dict[str, object]:
        if not isinstance(prediction, (tuple, list)) or not prediction:
            raise ValueError("gradio prediction did not return the expected tuple payload")

        raw_output = prediction[0]
        if not isinstance(raw_output, str):
            raise ValueError("gradio prediction raw output was not a string")

        parsed_segments = self._extract_json_segments(raw_output)
        segments: list[dict[str, object]] = []
        for item in parsed_segments:
            text = str(item.get("Content", "")).strip()
            if self._is_placeholder_segment_text(text):
                continue

            start_ms = int(round(float(item.get("Start", 0.0)) * 1000))
            end_ms = int(round(float(item.get("End", 0.0)) * 1000))
            if end_ms <= start_ms:
                continue

            segment: dict[str, object] = {
                "text": text,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "speaker_label": self._speaker_label(item.get("Speaker")),
            }
            segments.append(segment)

        return {
            "text": " ".join(segment["text"] for segment in segments),
            "segment_count": len(segments),
            "segments": segments,
        }

    def _extract_json_segments(self, raw_output: str) -> list[dict[str, object]]:
        candidates = [
            *self._json_candidates(raw_output),
            *self._python_literal_candidates(raw_output),
        ]
        for candidate in candidates:
            segments = self._coerce_segments_candidate(candidate)
            if segments is not None:
                return segments

        preview = re.sub(r"\s+", " ", raw_output).strip()[:240]
        raise ValueError(
            "gradio raw output did not contain a JSON segment array"
            + (f"; preview={preview}" if preview else "")
        )

    def _json_candidates(self, raw_output: str) -> list[object]:
        decoder = json.JSONDecoder()
        candidates: list[object] = []
        seen: set[tuple[int, int]] = set()

        for index, char in enumerate(raw_output):
            if char not in "[{":
                continue
            try:
                parsed, end = decoder.raw_decode(raw_output[index:])
            except json.JSONDecodeError:
                continue
            key = (index, end)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(parsed)

        return candidates

    def _python_literal_candidates(self, raw_output: str) -> list[object]:
        candidates: list[object] = []
        seen: set[tuple[int, int]] = set()

        for index, char in enumerate(raw_output):
            if char not in "[{":
                continue

            literal_text = self._balanced_literal_text(raw_output, index)
            if literal_text is None:
                continue

            key = (index, len(literal_text))
            if key in seen:
                continue
            seen.add(key)

            try:
                candidates.append(ast.literal_eval(literal_text))
            except (SyntaxError, ValueError):
                continue

        return candidates

    def _balanced_literal_text(self, text: str, start_index: int) -> str | None:
        closing_for = {"[": "]", "{": "}"}
        stack: list[str] = []
        quote: str | None = None
        escaped = False

        for offset, char in enumerate(text[start_index:]):
            if quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue

            if char in ("'", '"'):
                quote = char
                continue

            if char in closing_for:
                stack.append(closing_for[char])
                continue

            if char in "]}":
                if not stack or char != stack[-1]:
                    return None
                stack.pop()
                if not stack:
                    return text[start_index : start_index + offset + 1]

        return None

    def _coerce_segments_candidate(
        self, candidate: object
    ) -> list[dict[str, object]] | None:
        if isinstance(candidate, list):
            if not all(isinstance(item, dict) for item in candidate):
                raise ValueError("gradio JSON segment list must contain objects")
            return candidate

        if isinstance(candidate, dict):
            segments = candidate.get("segments")
            if isinstance(segments, list):
                if not all(isinstance(item, dict) for item in segments):
                    raise ValueError("gradio JSON segment list must contain objects")
                return segments

        return None

    def _speaker_label(self, value: object) -> str | None:
        if value is None:
            return None
        if isinstance(value, int):
            return f"Speaker {value + 1}"
        if isinstance(value, float) and value.is_integer():
            return f"Speaker {int(value) + 1}"

        text = str(value).strip()
        if not text:
            return None
        if text.isdigit():
            return f"Speaker {int(text) + 1}"
        if text.lower().startswith("speaker "):
            return text
        return f"Speaker {text}"

    def _is_placeholder_segment_text(self, text: str) -> bool:
        normalized = text.strip().lower()
        if normalized.startswith("[") and normalized.endswith("]"):
            return True
        return normalized in _PLACEHOLDER_PHRASES
