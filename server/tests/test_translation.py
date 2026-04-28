import json

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


def test_openai_compatible_translator_accepts_full_chat_completions_url():
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
        base_url="https://tokenhubpro.com/v1/chat/completions",
        api_key="key",
        model="Qwen/Qwen3.5-9B",
        client=client,
    )

    translator.translate_segments([Segment(text="你好", start_ms=0, end_ms=1)])

    assert captured_requests[0].url == "https://tokenhubpro.com/v1/chat/completions"


def test_openai_compatible_translator_splits_segments_into_batches():
    captured_batch_sizes = []

    def handler(request):
        payload = json.loads(request.content)
        batch = json.loads(payload["messages"][1]["content"])["segments"]
        captured_batch_sizes.append(len(batch))
        response_segments = [
            {
                "index": item["index"],
                "en": f"en:{item['text']}",
                "zh": f"zh:{item['text']}",
                "ar": f"ar:{item['text']}",
            }
            for item in batch
        ]
        return httpx.Response(
            200,
            json={
                "choices": [
                    {"message": {"content": json.dumps({"segments": response_segments})}}
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    translator = OpenAICompatibleSegmentTranslator(
        base_url="https://llm.example.com/v1",
        api_key="key",
        model="model",
        batch_size=5,
        client=client,
    )

    translations = translator.translate_segments(
        [
            Segment(text=f"segment-{index}", start_ms=index, end_ms=index + 1)
            for index in range(12)
        ]
    )

    assert captured_batch_sizes == [5, 5, 2]
    assert translations[0] == {
        "en": "en:segment-0",
        "zh": "zh:segment-0",
        "ar": "ar:segment-0",
    }
    assert translations[11] == {
        "en": "en:segment-11",
        "zh": "zh:segment-11",
        "ar": "ar:segment-11",
    }


def test_openai_compatible_translator_keeps_other_batches_when_one_batch_fails():
    request_count = 0

    def handler(request):
        nonlocal request_count
        request_count += 1
        if request_count == 2:
            return httpx.Response(502, json={"error": "temporary provider outage"})

        payload = json.loads(request.content)
        batch = json.loads(payload["messages"][1]["content"])["segments"]
        response_segments = [
            {
                "index": item["index"],
                "en": f"en:{item['text']}",
                "zh": f"zh:{item['text']}",
                "ar": f"ar:{item['text']}",
            }
            for item in batch
        ]
        return httpx.Response(
            200,
            json={
                "choices": [
                    {"message": {"content": json.dumps({"segments": response_segments})}}
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    translator = OpenAICompatibleSegmentTranslator(
        base_url="https://llm.example.com/v1",
        api_key="key",
        model="model",
        batch_size=1,
        max_attempts=1,
        client=client,
    )

    translations = translator.translate_segments(
        [
            Segment(text=f"segment-{index}", start_ms=index, end_ms=index + 1)
            for index in range(3)
        ]
    )

    assert translations == {
        0: {"en": "en:segment-0", "zh": "zh:segment-0", "ar": "ar:segment-0"},
        2: {"en": "en:segment-2", "zh": "zh:segment-2", "ar": "ar:segment-2"},
    }


def test_openai_compatible_translator_retries_failed_batch():
    request_count = 0

    def handler(request):
        nonlocal request_count
        request_count += 1
        if request_count == 1:
            return httpx.Response(502, json={"error": "temporary provider outage"})

        payload = json.loads(request.content)
        batch = json.loads(payload["messages"][1]["content"])["segments"]
        response_segments = [
            {
                "index": item["index"],
                "en": f"en:{item['text']}",
                "zh": f"zh:{item['text']}",
                "ar": f"ar:{item['text']}",
            }
            for item in batch
        ]
        return httpx.Response(
            200,
            json={
                "choices": [
                    {"message": {"content": json.dumps({"segments": response_segments})}}
                ]
            },
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    translator = OpenAICompatibleSegmentTranslator(
        base_url="https://llm.example.com/v1",
        api_key="key",
        model="model",
        batch_size=1,
        max_attempts=2,
        client=client,
    )

    translations = translator.translate_segments(
        [Segment(text="segment-0", start_ms=0, end_ms=1)]
    )

    assert request_count == 2
    assert translations == {
        0: {"en": "en:segment-0", "zh": "zh:segment-0", "ar": "ar:segment-0"}
    }


def test_openai_compatible_translator_requests_json_object_response_format():
    captured_payloads = []

    def handler(request):
        payload = json.loads(request.content)
        captured_payloads.append(payload)
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

    translator.translate_segments([Segment(text="你好", start_ms=0, end_ms=1)])

    assert captured_payloads[0]["response_format"] == {"type": "json_object"}
