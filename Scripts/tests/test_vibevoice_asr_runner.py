import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import vibevoice_asr_runner as runner


class VibeVoiceAsrRunnerTests(unittest.TestCase):
    def test_build_prompt_from_hotwords(self) -> None:
        prompt = runner.build_prompt(["NeuType", "AI workforce"])

        self.assertEqual(prompt, "Important meeting terms: NeuType, AI workforce")

    def test_normalize_segments_maps_vibevoice_shape(self) -> None:
        normalized = runner.normalize_segments(
            [
                {
                    "Start": 1.25,
                    "End": 2.5,
                    "Speaker": 2,
                    "Content": "hello world",
                }
            ]
        )

        self.assertEqual(
            normalized,
            [
                {
                    "sequence": 0,
                    "speaker_label": "Speaker 3",
                    "start_time": 1.25,
                    "end_time": 2.5,
                    "text": "hello world",
                }
            ],
        )

    def test_mock_backend_returns_structured_json(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".wav") as audio_file:
            request = {
                "audio_path": audio_file.name,
                "model_id": "microsoft/VibeVoice-ASR-HF",
                "hotwords": ["NeuType"],
            }

            completed = subprocess.run(
                [sys.executable, str(SCRIPT_DIR / "vibevoice_asr_runner.py")],
                input=json.dumps(request),
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "VIBEVOICE_RUNNER_BACKEND": "mock",
                },
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["full_text"], "Mock transcript for NeuType")
        self.assertEqual(payload["segments"][0]["speaker_label"], "Speaker 1")


if __name__ == "__main__":
    unittest.main()
