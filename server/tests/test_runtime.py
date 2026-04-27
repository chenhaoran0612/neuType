from __future__ import annotations

from meeting_transcription.runtime import load_worker_runtime_settings


def test_worker_runtime_defaults_to_app_recommended_gradio_max_tokens(monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS", raising=False)

    settings = load_worker_runtime_settings()

    assert settings.max_tokens == 8192
