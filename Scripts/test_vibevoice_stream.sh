#!/usr/bin/env bash
set -euo pipefail

DEFAULT_AUDIO_FILE="$HOME/Library/Application Support/ai.neuxnet.neutype.test/meetings/工作进展与项目安排.wav"
DEFAULT_API_KEY="$(defaults read ai.neuxnet.neutype.test meetingVibeVoiceAPIKey 2>/dev/null || true)"
DEFAULT_URL="https://tokenhubpro.com/v1/chat/completions"
DEFAULT_MODEL="vibevoice"
DEFAULT_MAX_TOKENS="4096"
DEFAULT_OUTPUT="/tmp/vibevoice-sse.log"

AUDIO_FILE="${1:-$DEFAULT_AUDIO_FILE}"
API_KEY="${VIBEVOICE_API_KEY:-$DEFAULT_API_KEY}"
URL="${VIBEVOICE_URL:-$DEFAULT_URL}"
MODEL="${VIBEVOICE_MODEL:-$DEFAULT_MODEL}"
MAX_TOKENS="${VIBEVOICE_MAX_TOKENS:-$DEFAULT_MAX_TOKENS}"
OUTPUT_FILE="${VIBEVOICE_OUTPUT_FILE:-$DEFAULT_OUTPUT}"

if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "[error] audio file not found: $AUDIO_FILE" >&2
  exit 1
fi

if [[ -z "$API_KEY" ]]; then
  echo "[error] missing API key. Set VIBEVOICE_API_KEY or configure defaults write ai.neuxnet.neutype.test meetingVibeVoiceAPIKey 'your-key'" >&2
  exit 1
fi

EXT="${AUDIO_FILE##*.}"
EXT_LOWER="$(printf "%s" "$EXT" | tr "[:upper:]" "[:lower:]")"
case "$EXT_LOWER" in
  wav) AUDIO_MIME="audio/wav" ;;
  mp3) AUDIO_MIME="audio/mpeg" ;;
  m4a) AUDIO_MIME="audio/mp4" ;;
  *)
    echo "[error] unsupported audio extension: .$EXT" >&2
    exit 1
    ;;
esac

AUDIO_B64="$(base64 < "$AUDIO_FILE" | tr -d '\n')"

TMP_BODY="$(mktemp /tmp/vibevoice-request.XXXXXX.json)"
cat > "$TMP_BODY" <<JSON
{
  "model": "$MODEL",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant that transcribes audio input into text output in JSON format."
    },
    {
      "role": "user",
      "content": [
        {
          "type": "audio_url",
          "audio_url": {
            "url": "data:${AUDIO_MIME};base64,${AUDIO_B64}"
          }
        },
        {
          "type": "text",
          "text": "Please transcribe it with these keys: Start time, End time, Speaker ID, Content. Return JSON array only."
        }
      ]
    }
  ],
  "max_tokens": $MAX_TOKENS,
  "temperature": 0.0,
  "stream": true
}
JSON

MASKED_KEY="${API_KEY:0:6}***${API_KEY: -4}"

echo "[info] audio: $AUDIO_FILE"
echo "[info] url:   $URL"
echo "[info] model: $MODEL"
echo "[info] key:   $MASKED_KEY"
echo "[info] body:  $TMP_BODY"
echo "[info] log:   $OUTPUT_FILE"
echo

echo "[curl]"
echo "curl -N --max-time 650 '$URL' \\
  -H 'Content-Type: application/json' \\
  -H 'Authorization: Bearer $MASKED_KEY' \\
  -H 'X-Api-Key: $MASKED_KEY' \\
  -H 'Accept: text/event-stream' \\
  --data '@$TMP_BODY' | tee '$OUTPUT_FILE'"
echo

echo "[run]"
curl -N --max-time 650 "$URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -H "X-Api-Key: $API_KEY" \
  -H "Accept: text/event-stream" \
  --data "@$TMP_BODY" | tee "$OUTPUT_FILE"
