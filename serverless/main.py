# -*- coding: utf-8 -*-
"""拍照生成单词卡片 — 火山函数计算（veFaaS）Web 函数入口。

数据流（全程 BytesIO，不落盘；函数临时磁盘请求结束即销毁）：
  校验 Token → 抠图 → 图像标签(中文名) → 机器翻译(英文) → DeepSeek(音标释义)
  → TTS(英/美 mp3) → Pillow 内存合成卡片 → 全部上传 TOS → 返回 JSON。

环境变量（函数控制台配置，绝不下发到 App）：
  VOLC_ACCESSKEY / VOLC_SECRETKEY   火山 AK/SK（抠图、翻译、TOS 用）
  ARK_API_KEY                       方舟（豆包视觉理解）API Key，图像标签用
                                    （console.volcengine.com/ark → API Key 管理）
  ARK_VISION_MODEL                  可选，默认 doubao-seed-1-6-250615，
                                    需按方舟控制台实际开通的模型名调整
  VOLC_TTS_API_KEY                  豆包语音大模型 X-Api-Key，TTS 用
                                    （豆包语音新版控制台 → API Key 管理）
  VOLC_TTS_RESOURCE_ID              可选，默认 seed-tts-2.0
  TTS_SPEAKER_US / TTS_SPEAKER_UK   音色 ID；英音需按控制台音色列表填写
  DEEPSEEK_API_KEY                  DeepSeek 开放平台 Key
  APP_TOKEN                         自定 App 鉴权 Token（与 App 设置一致）
  TOS_BUCKET / TOS_ENDPOINT         桶名 + 内网 endpoint
                                    （默认 tos-cn-guangzhou.ivolces.com）
  TOS_REGION                        cn-guangzhou
  TOS_PUBLIC_BASE                   可选，自定义公网访问前缀
"""
import base64
import hashlib
import io
import json
import os
import time
import traceback
import uuid
from datetime import datetime

from flask import Flask, request, jsonify
from flask_cors import CORS
from PIL import Image, ImageDraw, ImageFont

import requests

# 火山 SDK（volcengine）：视觉智能 cv（通用分割）、机器翻译（TranslateText）。
from volcengine.visual.VisualService import VisualService
from volcengine.ApiInfo import ApiInfo
from volcengine.Credentials import Credentials
from volcengine.ServiceInfo import ServiceInfo
from volcengine.base.Service import Service

app = Flask(__name__)
CORS(app)

# ── 配置 ──────────────────────────────────────────────────────────────
VOLC_ACCESSKEY = os.environ.get('VOLC_ACCESSKEY', '')
VOLC_SECRETKEY = os.environ.get('VOLC_SECRETKEY', '')
DEEPSEEK_API_KEY = os.environ.get('DEEPSEEK_API_KEY', '')
APP_TOKEN = os.environ.get('APP_TOKEN', '')
TOS_BUCKET = os.environ.get('TOS_BUCKET', '')
# 内网 endpoint（函数与 TOS 同地域时走内网，省流量费）；公网 URL 自动转外网。
TOS_ENDPOINT = os.environ.get('TOS_ENDPOINT', 'tos-cn-guangzhou.ivolces.com')
TOS_REGION = os.environ.get('TOS_REGION', 'cn-guangzhou')
TOS_PUBLIC_BASE = os.environ.get('TOS_PUBLIC_BASE', '').rstrip('/')

# 字体：打包进 zip 的 NotoSansSC（中文）+ 系统 DejaVu（英文兜底）。
_FONT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts')
_FONT_CJK_CANDIDATES = [
    os.path.join(_FONT_DIR, 'NotoSansSC.ttf'),
    '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
    '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
]
_FONT_LATIN_CANDIDATES = [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
]

_FONT_CJK = None
_FONT_LATIN = None
for _p in _FONT_CJK_CANDIDATES:
    if os.path.exists(_p):
        _FONT_CJK = _p
        break
for _p in _FONT_LATIN_CANDIDATES:
    if os.path.exists(_p):
        _FONT_LATIN = _p
        break


def _log(msg):
    print('[card]', msg, flush=True)


# ── 通用工具 ──────────────────────────────────────────────────────────

def _retry(fn, attempts=2, delay=2.0, label=''):
    """网络层重试：对异常做 attempts 次尝试（指数退避）。"""
    last = None
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001
            last = e
            _log('%s attempt %d/%d failed: %s' % (label, i + 1, attempts, e))
            if i < attempts - 1:
                time.sleep(delay * (2 ** i))
    raise last


def check_token():
    token = request.headers.get('Authorization', '')
    return APP_TOKEN and token == 'Bearer %s' % APP_TOKEN


# ── 火山 API：抠图 / 图像标签 / 翻译 / TTS ──────────────────────────
# 鉴权要点（调研核实）：
#   · 抠图（视觉智能 cv GeneralSegment）、翻译（TranslateText）、TOS —— 火山 AK/SK
#   · 图像标签 —— 经典 cv 服务无「通用打标」接口，改用豆包视觉理解（方舟 Ark，
#     Bearer ARK_API_KEY，与 AK/SK 无关）
#   · TTS —— 豆包语音大模型 V3，X-Api-Key（也不是 AK/SK）

# ── 环境变量补充 ─────────────────────────────────────────────────────
ARK_API_KEY = os.environ.get('ARK_API_KEY', '')
ARK_VISION_MODEL = os.environ.get('ARK_VISION_MODEL', 'doubao-seed-1-6-250615')
TTS_API_KEY = os.environ.get('VOLC_TTS_API_KEY', '')
TTS_RESOURCE_ID = os.environ.get('VOLC_TTS_RESOURCE_ID', 'seed-tts-2.0')
# 音色：美音已核实可用；英音官方无稳定 ID，需在豆包语音控制台「音色列表」
# 按账号实际开通音色填入 TTS_SPEAKER_UK（留空则英音回退用美音音色）。
TTS_SPEAKER_US = os.environ.get('TTS_SPEAKER_US', 'en_male_tim_uranus_bigtts')
TTS_SPEAKER_UK = os.environ.get('TTS_SPEAKER_UK', '')

ARK_URL = 'https://ark.cn-beijing.volces.com/api/v3/chat/completions'
TTS_URL = 'https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse'


def call_background_removal(image_bytes):
    """① 通用分割抠图 → 透明 PNG bytes（视觉智能 cv GeneralSegment）。

    GeneralSegment 只接受 image_base64（base64 字符串）或 image_url，
    不接受裸二进制。优先取返回的 foreground_image；没有则用 mask 与原图
    合成透明 PNG（火山 mask 约定主体为白/背景为黑）。
    """
    def _do():
        v = VisualService()
        v.set_ak(VOLC_ACCESSKEY)
        v.set_sk(VOLC_SECRETKEY)
        resp = v.general_segment({
            'image_base64': base64.b64encode(image_bytes).decode('utf-8'),
            'return_foreground_image': 1,
        })
        if resp.get('code') != 0:
            raise RuntimeError('general_segment code=%s msg=%s'
                               % (resp.get('code'), resp.get('message')))
        data = resp.get('data') or {}

        if data.get('foreground_image'):
            return base64.b64decode(data['foreground_image'])

        mask_b64 = data.get('mask')
        if not mask_b64:
            raise RuntimeError('响应中没有 mask 也没有 foreground_image')
        original = Image.open(io.BytesIO(image_bytes)).convert('RGBA')
        mask = Image.open(io.BytesIO(base64.b64decode(mask_b64))).convert('L')
        mask = mask.resize(original.size, Image.LANCZOS)
        original.putalpha(mask)

        buf = io.BytesIO()
        original.save(buf, 'PNG')
        return buf.getvalue()

    return _retry(_do, attempts=2, label='GeneralSegment')


def call_image_tagging(image_bytes):
    """② 豆包视觉理解 → 置信度最高的中文标签（经典 cv 无通用打标接口）。"""
    def _do():
        prompt = ('识别这张图片的主体内容，给出5个中文标签及置信度。'
                  '只输出JSON数组，不要其他文字，格式：'
                  '[{"label":"苹果","confidence":0.98}]')
        resp = requests.post(
            ARK_URL,
            headers={
                'Authorization': 'Bearer %s' % ARK_API_KEY,
                'Content-Type': 'application/json',
            },
            json={
                'model': ARK_VISION_MODEL,
                'messages': [{
                    'role': 'user',
                    'content': [
                        {'type': 'text', 'text': prompt},
                        {'type': 'image_url', 'image_url': {
                            'url': 'data:image/png;base64,'
                                   + base64.b64encode(image_bytes).decode()}},
                    ],
                }],
            },
            timeout=(5, 60),
        )
        if resp.status_code != 200:
            raise RuntimeError('Ark HTTP %s: %s'
                               % (resp.status_code, resp.text[:200]))
        content = resp.json()['choices'][0]['message']['content']
        tags = _parse_json(content)
        if isinstance(tags, dict):
            tags = tags.get('tags') or tags.get('labels') or [tags]
        if not isinstance(tags, list) or not tags:
            raise RuntimeError('视觉模型未返回标签列表: %s' % str(tags)[:200])

        best = None
        for t in tags:
            if not isinstance(t, dict):
                continue
            label = t.get('label') or t.get('name')
            if not label:
                continue
            try:
                conf = float(t.get('confidence') or t.get('score') or 0)
            except (TypeError, ValueError):
                conf = 0
            if best is None or conf > best[1]:
                best = (str(label), conf)
        if best is None:
            raise RuntimeError('标签列表为空: %s' % str(tags)[:200])
        return best[0]

    if not ARK_API_KEY:
        _log('image tagging skipped: ARK_API_KEY not set')
        return None
    return _retry(_do, attempts=2, label='ImageTagging')


def translate_to_english(chinese_word):
    """③ 机器翻译 中文 → 英文单词（open.volcengineapi.com TranslateText）。"""
    def _do():
        service_info = ServiceInfo(
            'open.volcengineapi.com',
            {'Content-Type': 'application/json'},
            Credentials(VOLC_ACCESSKEY, VOLC_SECRETKEY,
                        'translate', 'cn-north-1'),
            5, 5,
        )
        query = {'Action': 'TranslateText', 'Version': '2020-06-01'}
        api_info = {'translate': ApiInfo('POST', '/', query, {}, {})}
        svc = Service(service_info, api_info)

        body = {'SourceLanguage': 'zh', 'TargetLanguage': 'en',
                'TextList': [chinese_word]}
        res = svc.json('translate', {}, json.dumps(body))
        data = json.loads(res)
        if data.get('ResponseMetadata', {}).get('Error'):
            raise RuntimeError('翻译API错误: %s'
                               % data['ResponseMetadata']['Error'].get('Message'))
        translations = data.get('TranslationList') or []
        if not translations or not translations[0].get('Translation'):
            raise RuntimeError('翻译结果为空: %s' % res[:300])
        # 翻译可能返回短语，单词卡片只取第一个词。
        word = translations[0]['Translation'].strip().split()[0]
        return word.strip('.,;:!?()[]"\' ')

    return _retry(_do, attempts=2, label='Translate')


def generate_tts(text, accent='us'):
    """⑤ 豆包语音大模型 V3（SSE 流式）→ mp3 bytes。

    X-Api-Key 鉴权（豆包语音新版控制台 → API Key 管理，不是 AK/SK）。
    失败返回 None（TTS 不阻断主流程，卡片仍可生成）。
    """
    if not TTS_API_KEY:
        _log('TTS skipped: VOLC_TTS_API_KEY not set')
        return None
    speaker = TTS_SPEAKER_UK if accent == 'uk' and TTS_SPEAKER_UK \
        else TTS_SPEAKER_US
    try:
        def _do():
            headers = {
                'Content-Type': 'application/json',
                'X-Api-Resource-Id': TTS_RESOURCE_ID,
                'X-Api-Request-Id': str(uuid.uuid4()),
                'X-Api-Key': TTS_API_KEY,
            }
            body = {
                'user': {'uid': 'wordcard_user'},
                'req_params': {
                    'text': text,
                    'speaker': speaker,
                    'sample_rate': 24000,
                    'audio_params': {
                        'format': 'mp3', 'speech_rate': 0, 'loudness_rate': 0},
                    'additions':
                        json.dumps({'disable_markdown_filter': True}),
                },
            }
            audio = b''
            resp = requests.post(
                TTS_URL, headers=headers, json=body,
                stream=True, timeout=(5, 60),
            )
            if resp.status_code != 200:
                raise RuntimeError('TTS HTTP %s: %s'
                                   % (resp.status_code, resp.text[:200]))
            for raw in resp.iter_lines():
                if not raw:
                    continue
                line = raw.decode('utf-8', errors='ignore')
                if not line.startswith('data:'):
                    continue
                payload = line[5:].strip()
                if not payload or payload == '[DONE]':
                    continue
                d = json.loads(payload)
                if d.get('code') not in (0, 20000000):
                    raise RuntimeError('TTS code=%s msg=%s'
                                       % (d.get('code'), d.get('message')))
                if d.get('data'):
                    audio += base64.b64decode(d['data'])
            if not audio:
                raise RuntimeError('TTS 未返回音频')
            return audio
        return _retry(_do, attempts=2, label='TTS(%s)' % accent)
    except Exception as e:  # noqa: BLE001
        _log('TTS %s failed: %s' % (accent, e))
        return None


def _parse_json(content):
    """容错解析模型返回的 JSON（剥离 ```json 围栏）。"""
    c = content.strip()
    if c.startswith('```'):
        c = c.split('\n', 1)[-1].rsplit('```', 1)[0].strip()
    return json.loads(c)


# ── DeepSeek：音标 + 释义 ─────────────────────────────────────────────

DEEPSEEK_URL = 'https://api.deepseek.com/chat/completions'


def call_deepseek(chinese_word, english_word):
    """DeepSeek 生成英美音标 + 简短释义（JSON 输出）。"""
    def _do():
        prompt = (
            '请为单词 "%s"（中文意思：%s）提供信息，'
            '只输出一个 JSON 对象，不要任何多余文字：\n'
            '{"uk_phonetic": "英式音标", "us_phonetic": "美式音标", '
            '"definition": "英文释义(适合初学者的一句话)", '
            '"chinese_definition": "中文释义"}' % (english_word, chinese_word)
        )
        resp = requests.post(
            DEEPSEEK_URL,
            headers={
                'Authorization': 'Bearer %s' % DEEPSEEK_API_KEY,
                'Content-Type': 'application/json',
            },
            json={
                'model': 'deepseek-v4-flash',
                'messages': [
                    {'role': 'system',
                     'content': '你是专业的英语词典助手，只输出 JSON。'},
                    {'role': 'user', 'content': prompt},
                ],
                'temperature': 0.3,
            },
            timeout=(5, 20),
        )
        if resp.status_code != 200:
            raise RuntimeError('DeepSeek HTTP %s: %s'
                               % (resp.status_code, resp.text[:200]))
        content = resp.json()['choices'][0]['message']['content']
        start, end = content.find('{'), content.rfind('}')
        if start == -1 or end == -1:
            raise RuntimeError('DeepSeek 未返回 JSON: %s' % content[:200])
        return json.loads(content[start:end + 1])
    return _retry(_do, attempts=2, label='DeepSeek')


# ── Pillow 卡片合成（内存流） ─────────────────────────────────────────

def _load_font(size, bold=False):
    try:
        if bold and _FONT_LATIN:
            return ImageFont.truetype(_FONT_LATIN, size)
        if _FONT_CJK:
            return ImageFont.truetype(_FONT_CJK, size)
    except Exception:  # noqa: BLE001
        pass
    return ImageFont.load_default()


def _wrap(draw, text, font, max_width):
    """按像素宽度折行（逐字符，兼容中文）。"""
    lines, line = [], ''
    for ch in text:
        test = line + ch
        if draw.textlength(test, font=font) <= max_width:
            line = test
        else:
            if line:
                lines.append(line)
            line = ch
    if line:
        lines.append(line)
    return lines


def create_card_image(subject_png_bytes, chinese_word, english_word, info):
    """800x600 卡片：左侧抠图主体 + 右侧单词/音标/释义。全部在内存。"""
    W, H = 800, 600
    card = Image.new('RGB', (W, H), (255, 255, 255))
    draw = ImageDraw.Draw(card)

    # 左侧浅色圆角底 + 主体图（透明 PNG）。
    draw.rounded_rectangle((24, 28, 404, 572), radius=24,
                           fill=(245, 248, 252))
    try:
        subject = Image.open(io.BytesIO(subject_png_bytes)).convert('RGBA')
        # 按 340x340 框等比缩放。
        subject.thumbnail((340, 340), Image.Resampling.LANCZOS)
        cx = 214 - subject.width // 2
        cy = 300 - subject.height // 2
        card.paste(subject, (cx, cy), subject)
    except Exception as e:  # noqa: BLE001
        _log('subject paste failed: %s' % e)

    # 右侧文本。
    x = 440
    f_word = _load_font(44, bold=True)
    f_phonetic = _load_font(20)
    f_def = _load_font(20)
    f_cn = _load_font(22, bold=True)
    f_small = _load_font(15)

    y = 70
    draw.text((x, y), english_word, fill=(16, 24, 40), font=f_word)
    y += 62

    uk = info.get('uk_phonetic') or ''
    us = info.get('us_phonetic') or ''
    if uk:
        draw.text((x, y), 'UK /%s/' % uk, fill=(100, 116, 139), font=f_phonetic)
        y += 28
    if us:
        draw.text((x, y), 'US /%s/' % us, fill=(100, 116, 139), font=f_phonetic)
        y += 36

    if chinese_word:
        draw.text((x, y), chinese_word, fill=(14, 116, 144), font=f_cn)
        y += 38

    y += 6
    definition = info.get('definition') or ''
    for line in _wrap(draw, definition, f_def, 320)[:4]:
        draw.text((x, y), line, fill=(51, 65, 85), font=f_def)
        y += 30
    chinese_definition = info.get('chinese_definition') or ''
    for line in _wrap(draw, chinese_definition, f_cn, 320)[:2]:
        draw.text((x, y), line, fill=(51, 65, 85), font=f_cn)
        y += 32

    # 底部信息。
    draw.line((24, 585, 776, 585), fill=(226, 232, 240), width=1)
    draw.text((24, 590), 'Libranote · %s'
              % datetime.now().strftime('%Y-%m-%d %H:%M'),
              fill=(148, 163, 184), font=f_small)

    buf = io.BytesIO()
    card.save(buf, 'PNG')
    return buf.getvalue()


# ── TOS 上传 ──────────────────────────────────────────────────────────

_tos_client = None


def _get_tos_client():
    """惰性构造 TOS 客户端（toes 包：tos.TosClientV2）。"""
    global _tos_client
    if _tos_client is None:
        import tos
        _tos_client = tos.TosClientV2(
            ak=VOLC_ACCESSKEY,
            sk=VOLC_SECRETKEY,
            endpoint=TOS_ENDPOINT,
            region=TOS_REGION,
        )
    return _tos_client


def upload_to_tos(file_bytes, folder, file_name, content_type):
    """上传到 TOS，返回公网 URL（bucket 需公共读）。"""
    def _do():
        client = _get_tos_client()
        key = '%s/%s' % (folder, file_name)
        client.put_object(
            bucket=TOS_BUCKET,
            key=key,
            content=file_bytes,  # bytes 直传（SDK 也支持 BytesIO/文件对象）
            content_type=content_type,
        )
        return _public_url(folder, file_name)
    return _retry(_do, attempts=2, label='TOS upload')


def _public_url(folder, unique_name):
    # 内网 endpoint（ivolces）只能内网访问，公网 URL 必须换成外网域名。
    if TOS_PUBLIC_BASE:
        base = TOS_PUBLIC_BASE
    else:
        endpoint = TOS_ENDPOINT.replace('ivolces', 'volces')
        base = 'https://%s.%s' % (TOS_BUCKET, endpoint)
    return '%s/%s/%s' % (base, folder, unique_name)


# ── 主接口 ────────────────────────────────────────────────────────────

@app.route('/create_card', methods=['POST'])
def create_card():
    if not check_token():
        return jsonify({'success': False, 'error': 'Unauthorized'}), 403

    image_file = request.files.get('image')
    if image_file is None:
        return jsonify({'success': False, 'error': 'No image uploaded'}), 400
    image_bytes = image_file.read()
    if len(image_bytes) == 0:
        return jsonify({'success': False, 'error': 'Empty image'}), 400
    _log('received image: %d bytes' % len(image_bytes))

    try:
        # ① 抠图。
        subject_bytes = call_background_removal(image_bytes)
        if not subject_bytes:
            return jsonify({'success': False,
                            'error': 'Background removal failed'}), 500

        # ② 图像标签 → 中文名。
        chinese_word = call_image_tagging(subject_bytes)
        if not chinese_word:
            return jsonify({'success': False,
                            'error': 'Image recognition failed'}), 500

        # ③ 机器翻译。
        english_word = translate_to_english(chinese_word)
        if not english_word:
            return jsonify({'success': False,
                            'error': 'Translation failed'}), 500

        # ④ DeepSeek 音标释义。
        info = call_deepseek(chinese_word, english_word)
        if not info:
            return jsonify({'success': False,
                            'error': 'DeepSeek generation failed'}), 500

        # ⑤ TTS（失败不致命：音频字段置 null，卡片仍可用）。
        uk_audio = generate_tts(english_word, 'uk')
        us_audio = generate_tts(english_word, 'us')

        # ⑥ 合成卡片。
        card_image = create_card_image(subject_bytes, chinese_word,
                                       english_word, info)
        if not card_image:
            return jsonify({'success': False,
                            'error': 'Card creation failed'}), 500

        # ⑦ 上传 TOS。
        ts = int(time.time())
        digest = hashlib.md5(card_image).hexdigest()[:8]
        card_url = upload_to_tos(card_image, 'card_img',
                                 '%s_%s_card.png' % (ts, digest),
                                 'image/png')
        if not card_url:
            return jsonify({'success': False,
                            'error': 'Upload to TOS failed'}), 500

        uk_audio_url = None
        us_audio_url = None
        if uk_audio:
            uk_audio_url = upload_to_tos(uk_audio, 'audio',
                                         '%s_%s_uk.mp3' % (ts, digest),
                                         'audio/mpeg')
        if us_audio:
            us_audio_url = upload_to_tos(us_audio, 'audio',
                                         '%s_%s_us.mp3' % (ts, digest),
                                         'audio/mpeg')

        # ⑧ 返回。
        return jsonify({
            'success': True,
            'data': {
                'card_image_url': card_url,
                'uk_audio_url': uk_audio_url,
                'us_audio_url': us_audio_url,
                'chinese_word': chinese_word,
                'english_word': english_word,
                'uk_phonetic': info.get('uk_phonetic') or '',
                'us_phonetic': info.get('us_phonetic') or '',
                'definition': info.get('definition') or '',
                'chinese_definition': info.get('chinese_definition') or '',
            },
        })
    except Exception as e:  # noqa: BLE001
        _log('pipeline error: %s\n%s' % (e, traceback.format_exc()))
        return jsonify({'success': False, 'error': str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=9000)
