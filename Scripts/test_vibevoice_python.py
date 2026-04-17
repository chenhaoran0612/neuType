#!/usr/bin/env python3
import argparse
import base64
import json
import mimetypes
import subprocess
import sys
from pathlib import Path

import requests


def guess_mime(audio_path: Path) -> str:
    mime, _ = mimetypes.guess_type(str(audio_path))
    if mime:
        return mime
    suffix = audio_path.suffix.lower()
    if suffix == '.wav':
        return 'audio/wav'
    if suffix == '.mp3':
        return 'audio/mpeg'
    if suffix == '.m4a':
        return 'audio/mp4'
    return 'application/octet-stream'


def read_default_api_key() -> str:
    try:
        result = subprocess.run(
            ['defaults', 'read', 'ai.neuxnet.neutype.test', 'meetingVibeVoiceAPIKey'],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout.strip()
    except Exception:
        return ''


def mask_key(key: str) -> str:
    if len(key) <= 10:
        return '***'
    return f'{key[:6]}***{key[-4:]}'


def print_section(title: str) -> None:
    print(f'\n===== {title} =====')


def looks_like_mojibake(text: str) -> bool:
    markers = ['ï¼', 'ï½', 'Ã', 'â€', 'â€”', 'â€“', 'â€¦', 'å', 'æ', 'ç', 'é', 'è', 'ê', 'î', 'ð']
    if any('\u4e00' <= ch <= '\u9fff' for ch in text):
        return False
    return any(marker in text for marker in markers)


def repair_mojibake(text: str) -> str:
    if not text or not looks_like_mojibake(text):
        return text
    try:
        return text.encode('latin1').decode('utf-8')
    except Exception:
        return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--audio',
        default=str(Path.home() / 'Library/Application Support/ai.neuxnet.neutype.test/meetings/工作进展与项目安排.wav'),
        help='本地音频文件路径'
    )
    parser.add_argument(
        '--url',
        default='https://tokenhubpro.com/v1/chat/completions',
        help='API URL'
    )
    parser.add_argument(
        '--api-key',
        default=read_default_api_key(),
        help='tokenhub API key，默认读取 ai.neuxnet.neutype.test 的 meetingVibeVoiceAPIKey'
    )
    parser.add_argument(
        '--model',
        default='vibevoice',
        help='模型名'
    )
    parser.add_argument(
        '--max-tokens',
        type=int,
        default=8192,
        help='max_tokens'
    )
    parser.add_argument(
        '--timeout',
        type=int,
        default=1800,
        help='请求超时秒数'
    )
    parser.add_argument(
        '--output',
        default='/tmp/vibevoice_response.json',
        help='保存响应的文件路径'
    )
    args = parser.parse_args()

    audio_path = Path(args.audio).expanduser().resolve()
    if not audio_path.exists():
        raise FileNotFoundError(f'音频文件不存在: {audio_path}')

    if not args.api_key:
        raise RuntimeError('缺少 API key，请传 --api-key 或先配置 defaults write ai.neuxnet.neutype.test meetingVibeVoiceAPIKey "your-key"')

    mime_type = guess_mime(audio_path)
    audio_bytes = audio_path.read_bytes()
    audio_b64 = base64.b64encode(audio_bytes).decode()

    payload = {
        'model': args.model,
        'messages': [
            {
                'role': 'system',
                'content': 'You are a helpful assistant that transcribes audio input into text output in JSON format.'
            },
            {
                'role': 'user',
                'content': [
                    {
                        'type': 'audio_url',
                        'audio_url': {
                            'url': f'data:{mime_type};base64,{audio_b64}'
                        }
                    },
                    {
                        'type': 'text',
                        'text': 'Please transcribe it with these keys: Start time, End time, Speaker ID, Content'
                    }
                ]
            }
        ],
        'max_tokens': args.max_tokens,
        'temperature': 0.0,
        'stream': True
    }

    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {args.api_key}',
        'X-Api-Key': args.api_key,
    }

    request_json = json.dumps(payload, ensure_ascii=False)
    out_path = Path(args.output).expanduser().resolve()

    print_section('REQUEST INFO')
    print(f'audio_path      : {audio_path}')
    print(f'audio_size      : {len(audio_bytes)} bytes')
    print(f'audio_mime      : {mime_type}')
    print(f'url             : {args.url}')
    print(f'model           : {args.model}')
    print(f'max_tokens      : {args.max_tokens}')
    print(f'timeout         : {args.timeout}')
    print(f'api_key         : {mask_key(args.api_key)}')
    print(f'base64_length   : {len(audio_b64)}')
    print(f'request_json_len: {len(request_json)}')
    print(f'output_file     : {out_path}')

    print_section('REQUEST HEADERS')
    for key, value in headers.items():
        if key.lower() in {'authorization', 'x-api-key'}:
            value = mask_key(args.api_key)
        print(f'{key}: {value}')

    print_section('REQUEST PAYLOAD PREVIEW')
    preview_payload = {
        **payload,
        'messages': [
            payload['messages'][0],
            {
                'role': 'user',
                'content': [
                    {
                        'type': 'audio_url',
                        'audio_url': {
                            'url': f'data:{mime_type};base64,<base64 length={len(audio_b64)}>'
                        }
                    },
                    payload['messages'][1]['content'][1],
                ]
            },
        ],
    }
    print(json.dumps(preview_payload, ensure_ascii=False, indent=2))

    print_section('REQUEST START')
    print('sending request...')

    try:
        resp = requests.post(args.url, headers=headers, json=payload, timeout=args.timeout, stream=True)
    except requests.RequestException as exc:
        print_section('REQUEST ERROR')
        print(repr(exc))
        raise

    response_lines = []
    assembled_content_parts = []
    finish_reason = None

    print_section('STREAM EVENTS')
    for raw_line in resp.iter_lines(decode_unicode=True):
        line = raw_line or ''
        response_lines.append(line)
        print(line)

        if not line.startswith('data:'):
            continue

        event_data = line[5:].strip()
        if event_data == '[DONE]':
            continue

        try:
            event_json = json.loads(event_data)
        except Exception as exc:
            print(f'[stream-parse-error] {exc!r}')
            continue

        for choice in event_json.get('choices', []):
            delta = choice.get('delta') or {}
            message = choice.get('message') or {}
            content = delta.get('content') or message.get('content')
            if content:
                assembled_content_parts.append(content)
            if choice.get('finish_reason'):
                finish_reason = choice.get('finish_reason')

    response_text = '\n'.join(response_lines)
    out_path.write_text(response_text, encoding='utf-8')

    print_section('RESPONSE STATUS')
    print(f'status_code : {resp.status_code}')
    print(f'reason      : {resp.reason}')
    print(f'ok          : {resp.ok}')
    print(f'elapsed     : {resp.elapsed.total_seconds():.3f}s')
    print(f'final_url   : {resp.url}')

    print_section('RESPONSE HEADERS')
    for key, value in resp.headers.items():
        print(f'{key}: {value}')

    print_section('RESPONSE CONTENT')
    print(response_text)

    print_section('OUTPUT FILE')
    print(str(out_path))

    assembled_content = repair_mojibake(''.join(assembled_content_parts))
    if assembled_content:
        print_section('ASSEMBLED CONTENT')
        print(assembled_content)
        print(f'finish_reason: {finish_reason}')

    try:
        data = resp.json()
        print_section('PARSED JSON')
        print(json.dumps(data, ensure_ascii=False, indent=2))
    except Exception as exc:
        print_section('PARSE ERROR')
        print(repr(exc))

    print_section('DONE')
    print('request finished')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print('\n===== FATAL ERROR =====')
        print(repr(exc))
        sys.exit(1)
