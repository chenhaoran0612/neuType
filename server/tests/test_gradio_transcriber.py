from __future__ import annotations

import pytest
import httpx

from meeting_transcription import gradio_transcriber
from meeting_transcription.gradio_transcriber import GradioChunkTranscriber


class RecordingClient:
    def __init__(self, result):
        self.result = result
        self.calls: list[dict[str, object]] = []

    def predict(self, **kwargs):
        self.calls.append(kwargs)
        return self.result


class DummySession:
    session_id = "mts_test"


class DummyChunk:
    chunk_index = 3
    start_ms = 300000
    end_ms = 600000


def test_gradio_transcriber_calls_transcribe_wrapper_with_uploaded_audio_path(tmp_path):
    client = RecordingClient(
        (
            "--- ✅ Transcription Complete ---\n"
            "⏱️ Time: 0.51s | 🎵 Audio: 11.00s\n"
            "📊 Tokens: 143 (prompt) + 51 (completion) = 194 (total)\n"
            "⚡ Speed: 99.1 tokens/s\n"
            "---\n"
            '[{"Start":0.0,"End":1.5,"Speaker":0,"Content":"hello"}]',
            "",
            "",
            None,
        )
    )
    transcriber = GradioChunkTranscriber(
        base_url="https://546463aae3e7327f37.gradio.live/",
        max_tokens=8192,
        temperature=0.2,
        top_p=0.9,
        do_sample=True,
        context_info="NeuType, AI",
        client=client,
    )

    audio_path = tmp_path / "chunk.wav"
    audio_path.write_bytes(b"RIFF")

    result = transcriber.transcribe_chunk(
        session=DummySession(),
        chunk=DummyChunk(),
        audio_path=str(audio_path),
        prefix_plan=None,
    )

    assert result == {
        "text": "hello",
        "segment_count": 1,
        "segments": [
            {
                "text": "hello",
                "start_ms": 0,
                "end_ms": 1500,
                "speaker_label": "Speaker 1",
            }
        ],
    }

    assert client.calls == [
        {
            "file_input": None,
            "audio_rec": {
                "path": str(audio_path),
                "meta": {"_type": "gradio.FileData"},
                "orig_name": "chunk.wav",
            },
            "video_rec": None,
            "audio_prev": {
                "path": str(audio_path),
                "meta": {"_type": "gradio.FileData"},
                "orig_name": "chunk.wav",
            },
            "video_prev": None,
            "max_tokens": 8192,
            "temp": 0.2,
            "top_p": 0.9,
            "do_sample": True,
            "context_info": "NeuType, AI",
            "api_name": "/transcribe_wrapper",
        }
    ]


def test_gradio_transcriber_drops_placeholder_only_segments(tmp_path):
    client = RecordingClient(
        (
            "--- ✅ Transcription Complete ---\n"
            "---\n"
            '[{"Start":0.0,"End":2.0,"Content":"[Silence]"}]',
            "",
            "",
            None,
        )
    )
    transcriber = GradioChunkTranscriber(
        base_url="https://546463aae3e7327f37.gradio.live/",
        client=client,
    )

    audio_path = tmp_path / "chunk.wav"
    audio_path.write_bytes(b"RIFF")

    result = transcriber.transcribe_chunk(
        session=DummySession(),
        chunk=DummyChunk(),
        audio_path=str(audio_path),
        prefix_plan=None,
    )

    assert result == {
        "text": "",
        "segment_count": 0,
        "segments": [],
    }


def test_gradio_transcriber_rejects_unparseable_raw_output(tmp_path):
    client = RecordingClient(("model returned plain text only", "", "", None))
    transcriber = GradioChunkTranscriber(
        base_url="https://546463aae3e7327f37.gradio.live/",
        client=client,
    )

    audio_path = tmp_path / "chunk.wav"
    audio_path.write_bytes(b"RIFF")

    with pytest.raises(ValueError, match="JSON segment array"):
        transcriber.transcribe_chunk(
            session=DummySession(),
            chunk=DummyChunk(),
            audio_path=str(audio_path),
            prefix_plan=None,
        )


def test_gradio_transcriber_builds_client_with_unbounded_http_timeout(monkeypatch):
    captured: dict[str, object] = {}

    class FakeClient:
        def __init__(self, *args, **kwargs):
            captured["args"] = args
            captured["kwargs"] = kwargs

    monkeypatch.setattr(gradio_transcriber, "Client", FakeClient)

    transcriber = GradioChunkTranscriber(
        base_url="https://546463aae3e7327f37.gradio.live/",
    )

    client = transcriber._client
    assert isinstance(client, FakeClient)
    assert captured["args"] == ("https://546463aae3e7327f37.gradio.live/",)
    timeout = captured["kwargs"]["httpx_kwargs"]["timeout"]
    assert isinstance(timeout, httpx.Timeout)
    assert timeout.read is None
    assert timeout.connect is None
    assert timeout.write is None
    assert timeout.pool is None
