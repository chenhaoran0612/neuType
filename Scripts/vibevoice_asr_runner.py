#!/usr/bin/env python3
import json
import sys


def main() -> int:
    request = json.load(sys.stdin)
    audio_path = request.get("audio_path")
    model_id = request.get("model_id", "microsoft/VibeVoice-ASR-HF")

    if not audio_path:
        print("missing audio_path", file=sys.stderr)
        return 1

    # The real VibeVoice inference implementation will be added in a later task.
    # This contract is stable now so the Swift client can integrate against it.
    output = {
        "full_text": "",
        "segments": [],
        "meta": {
            "audio_path": audio_path,
            "model_id": model_id,
        },
    }
    json.dump(output, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
