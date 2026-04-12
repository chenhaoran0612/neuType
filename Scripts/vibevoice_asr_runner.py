#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import io
import json
import logging
import os
import sys
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("TRANSFORMERS_NO_ADVISORY_WARNINGS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("PYTHONWARNINGS", "ignore")

warnings.filterwarnings("ignore")
logging.getLogger("transformers").setLevel(logging.ERROR)
logging.getLogger("huggingface_hub").setLevel(logging.ERROR)

DEFAULT_MODEL_ID = "microsoft/VibeVoice-ASR-HF"
MOCK_BACKEND = "mock"


@dataclass(frozen=True)
class RunnerRequest:
    audio_path: str
    model_id: str
    hotwords: list[str]


def parse_request(raw_request: dict[str, Any]) -> RunnerRequest:
    audio_path = str(raw_request.get("audio_path", "")).strip()
    model_id = str(raw_request.get("model_id", DEFAULT_MODEL_ID)).strip() or DEFAULT_MODEL_ID
    hotwords = [str(item).strip() for item in raw_request.get("hotwords", []) if str(item).strip()]

    if not audio_path:
        raise ValueError("missing audio_path")

    return RunnerRequest(
        audio_path=audio_path,
        model_id=model_id,
        hotwords=hotwords,
    )


def build_prompt(hotwords: list[str]) -> Optional[str]:
    if not hotwords:
        return None
    return f"Important meeting terms: {', '.join(hotwords)}"


def normalize_segments(parsed_segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []

    for index, segment in enumerate(parsed_segments):
        speaker = segment.get("Speaker", "Unknown")
        if isinstance(speaker, int):
            speaker_label = f"Speaker {speaker + 1}"
        else:
            speaker_label = f"Speaker {speaker}".strip() if speaker not in (None, "") else "Unknown"

        normalized.append(
            {
                "sequence": index,
                "speaker_label": speaker_label,
                "start_time": float(segment.get("Start", 0.0)),
                "end_time": float(segment.get("End", 0.0)),
                "text": str(segment.get("Content", "")).strip(),
            }
        )

    return normalized


def run_mock_backend(request: RunnerRequest) -> dict[str, Any]:
    topic = request.hotwords[0] if request.hotwords else Path(request.audio_path).stem
    segments = [
        {
            "sequence": 0,
            "speaker_label": "Speaker 1",
            "start_time": 0.0,
            "end_time": 1.5,
            "text": f"Mock transcript for {topic}",
        }
    ]
    return {
        "full_text": segments[0]["text"],
        "segments": segments,
        "meta": {
            "audio_path": request.audio_path,
            "model_id": request.model_id,
            "backend": MOCK_BACKEND,
        },
    }


def run_transformers_backend(request: RunnerRequest) -> dict[str, Any]:
    captured_stderr = io.StringIO()
    with contextlib.redirect_stderr(captured_stderr):
        try:
            import torch
            from transformers import AutoProcessor, VibeVoiceAsrForConditionalGeneration
        except ImportError as exc:
            raise RuntimeError(
                "VibeVoice runner requires Python packages `torch` and `transformers` with "
                "VibeVoice ASR support. Install them into the configured Python environment, "
                "for example: pip install 'torch' 'transformers>=5.5.3' 'accelerate' 'sentencepiece'"
            ) from exc

        if not Path(request.audio_path).exists():
            raise FileNotFoundError(f"audio file not found: {request.audio_path}")

        prompt = build_prompt(request.hotwords)
        processor = AutoProcessor.from_pretrained(request.model_id)
        model = VibeVoiceAsrForConditionalGeneration.from_pretrained(
            request.model_id,
            device_map="auto",
            torch_dtype="auto",
        )

        inputs = processor.apply_transcription_request(
            audio=request.audio_path,
            prompt=prompt,
        ).to(model.device, model.dtype)

        with torch.inference_mode():
            output_ids = model.generate(**inputs)

        generated_ids = output_ids[:, inputs["input_ids"].shape[1] :]
        parsed_segments = processor.decode(generated_ids, return_format="parsed")[0]
        transcription_only = processor.decode(generated_ids, return_format="transcription_only")[0]

        if not isinstance(parsed_segments, list):
            raise RuntimeError(
                "VibeVoice ASR did not return parsed segments. "
                "Try a newer transformers build or inspect the raw model output."
            )

        return {
            "full_text": str(transcription_only).strip(),
            "segments": normalize_segments(parsed_segments),
            "meta": {
                "audio_path": request.audio_path,
                "model_id": request.model_id,
                "backend": "transformers",
                "device": str(model.device),
                "dtype": str(model.dtype),
            },
        }


def main() -> int:
    try:
        request = parse_request(json.load(sys.stdin))
        backend = os.environ.get("VIBEVOICE_RUNNER_BACKEND", "").strip().lower()

        if backend == MOCK_BACKEND:
            output = run_mock_backend(request)
        else:
            output = run_transformers_backend(request)

        json.dump(output, sys.stdout, ensure_ascii=False)
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
