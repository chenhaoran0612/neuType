from __future__ import annotations

from meeting_transcription.runtime import (
    WorkerRuntimeSettings,
    create_segment_translator_from_settings,
    load_worker_runtime_settings,
)
from meeting_transcription.translation import (
    NoopSegmentTranslator,
    OpenAICompatibleSegmentTranslator,
)


def test_worker_runtime_defaults_to_app_recommended_gradio_max_tokens(monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIPTION_GRADIO_MAX_TOKENS", raising=False)

    settings = load_worker_runtime_settings()

    assert settings.max_tokens == 8192


def test_load_worker_runtime_settings_includes_translation_env(monkeypatch):
    monkeypatch.setenv(
        "MEETING_TRANSCRIPTION_TRANSLATION_BASE_URL",
        "https://llm.example.com/v1",
    )
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_API_KEY", "secret")
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_MODEL", "gpt-4.1-mini")
    monkeypatch.setenv("MEETING_TRANSCRIPTION_TRANSLATION_TIMEOUT_SECONDS", "12.5")

    settings = load_worker_runtime_settings()

    assert settings.translation_base_url == "https://llm.example.com/v1"
    assert settings.translation_api_key == "secret"
    assert settings.translation_model == "gpt-4.1-mini"
    assert settings.translation_timeout_seconds == 12.5


def test_create_segment_translator_uses_noop_when_unconfigured():
    settings = WorkerRuntimeSettings(
        gradio_base_url="https://gradio.example.com",
        max_tokens=8192,
        temperature=0.0,
        top_p=1.0,
        do_sample=False,
        context_info="",
        idle_sleep_seconds=1.0,
        translation_base_url="",
        translation_api_key="",
        translation_model="",
        translation_timeout_seconds=60.0,
    )

    translator = create_segment_translator_from_settings(settings)

    assert isinstance(translator, NoopSegmentTranslator)


def test_create_segment_translator_uses_openai_compatible_translator_when_configured():
    settings = WorkerRuntimeSettings(
        gradio_base_url="https://gradio.example.com",
        max_tokens=8192,
        temperature=0.0,
        top_p=1.0,
        do_sample=False,
        context_info="",
        idle_sleep_seconds=1.0,
        translation_base_url="https://llm.example.com/v1",
        translation_api_key="secret",
        translation_model="gpt-4.1-mini",
        translation_timeout_seconds=12.5,
    )

    translator = create_segment_translator_from_settings(settings)

    assert isinstance(translator, OpenAICompatibleSegmentTranslator)
