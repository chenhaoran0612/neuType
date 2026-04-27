import httpx

from meeting_transcription.anchor_audio import Segment
from meeting_transcription.translation import (
    NoopSegmentTranslator,
    OpenAICompatibleSegmentTranslator,
    apply_translations,
    segments_with_empty_translations,
)


def test_noop_translator_returns_empty_translations():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translations = NoopSegmentTranslator().translate_segments(segments)

    assert translations == {0: {"en": "", "zh": "", "ar": ""}}


def test_apply_translations_preserves_original_segment_text():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translated = apply_translations(
        segments,
        {0: {"en": "Hello", "zh": "你好", "ar": "مرحبا"}},
    )

    assert translated[0].text == "你好"
    assert translated[0].translations == {
        "en": "Hello",
        "zh": "你好",
        "ar": "مرحبا",
    }


def test_apply_translations_fills_missing_language_keys_with_empty_strings():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translated = apply_translations(segments, {0: {"en": "Hello"}})

    assert translated[0].translations == {"en": "Hello", "zh": "", "ar": ""}


def test_segments_with_empty_translations_adds_empty_language_values():
    segments = [Segment(text="你好", start_ms=0, end_ms=1000)]

    translated = segments_with_empty_translations(segments)

    assert translated[0].translations == {"en": "", "zh": "", "ar": ""}


def test_openai_compatible_translator_parses_json_response():
    captured_requests = []

    def handler(request):
        captured_requests.append(request)
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": '{"segments":[{"index":0,"en":"Hello","zh":"你好","ar":"مرحبا"}]}'
                        }
                    }
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    translator = OpenAICompatibleSegmentTranslator(
        base_url="https://llm.example.com/v1",
        api_key="key",
        model="model",
        client=client,
    )

    translations = translator.translate_segments(
        [Segment(text="你好", start_ms=0, end_ms=1)]
    )

    assert translations == {0: {"en": "Hello", "zh": "你好", "ar": "مرحبا"}}
    assert captured_requests[0].url == "https://llm.example.com/v1/chat/completions"
    assert captured_requests[0].headers["authorization"] == "Bearer key"
