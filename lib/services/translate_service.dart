import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_models.dart';
import 'ai_provider_config.dart';
import 'ai_service.dart';

/// 翻译设置（网页翻译接口 + API 翻译），SharedPreferences 持久化。
class TranslateStore {
  TranslateStore._();
  static final TranslateStore instance = TranslateStore._();

  static const _kEnabled = 'translate.enabled';
  static const _kTarget = 'translate.target';
  static const _kApiEnabled = 'translate.api_enabled';
  static const _kApiProviderId = 'translate.api_provider_id';

  /// 网页翻译开关（免费接口，默认开）。
  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;

  Future<void> setEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kEnabled, v);

  /// 默认目标语言（默认中文）。
  Future<String> getTarget() async =>
      (await SharedPreferences.getInstance()).getString(_kTarget) ?? 'zh-CN';

  Future<void> setTarget(String v) async =>
      (await SharedPreferences.getInstance()).setString(_kTarget, v);

  /// API 翻译开关：开启后优先用 AI 供应商（与 AI 配置共用同一套 API）翻译。
  Future<bool> isApiEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kApiEnabled) ?? false;

  Future<void> setApiEnabled(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kApiEnabled, v);

  /// API 翻译使用的供应商 id（null = 用 AI 当前生效的供应商）。
  Future<String?> getApiProviderId() async =>
      (await SharedPreferences.getInstance()).getString(_kApiProviderId);

  Future<void> setApiProviderId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null || id.isEmpty) {
      await prefs.remove(_kApiProviderId);
    } else {
      await prefs.setString(_kApiProviderId, id);
    }
  }
}

/// 拍照翻译/选中翻译的文字翻译服务。
///
/// 引擎顺序：
/// 1. **API 翻译**（设置里开启后优先）：走 AI 供应商（与 AI 配置同一套
///    API/Key，模型负责翻译，质量最高；DeepSeek/Kimi/Qwen 均可）。
/// 2. Google 翻译 gtx 端点（免费，个别网络不可达时自动切换）
/// 3. MyMemory 免费接口（兜底）
class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  /// 支持的目标语言（自动检测源语言）。
  static const targets = <(String code, String label)>[
    ('zh-CN', '中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
  ];

  static String targetLabel(String code) {
    for (final t in targets) {
      if (t.$1 == code) return t.$2;
    }
    return code;
  }

  /// 翻译一段文字。[target] 省略时用设置页里的默认目标语言。
  /// 翻译功能在设置页被关闭时抛中文异常（UI 直接展示）。
  Future<String> translate(String text, [String? target]) async {
    if (!await TranslateStore.instance.isEnabled()) {
      throw const TranslateException('翻译功能已在设置里关闭'
          '（更多设置 → 翻译设置）');
    }
    final q = text.trim();
    if (q.isEmpty) return '';
    final tl = target ?? await TranslateStore.instance.getTarget();

    // 1) API 翻译（AI 供应商，与 AI 配置共用同一套 API）。
    if (await TranslateStore.instance.isApiEnabled()) {
      final provider = await _resolveProvider();
      if (provider != null) {
        final key = await AiProviderStore.instance.getApiKey(provider.id);
        if (key != null && key.isNotEmpty) {
          try {
            final result = await _translateViaAi(provider, key, q, tl);
            if (result.isNotEmpty) return result;
          } catch (e) {
            debugPrint('[Translate] AI translation failed, '
                'falling back to free endpoints: $e');
          }
        }
      }
    }

    // 2) Google gtx。
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (s) => s != null && s < 500,
      ));
      final resp = await dio.get<String>(
        'https://translate.googleapis.com/translate_a/single',
        queryParameters: {
          'client': 'gtx',
          'sl': 'auto',
          'tl': tl,
          'dt': 't',
          'q': q,
        },
      );
      dio.close();
      if (resp.statusCode == 200 && resp.data != null) {
        final result = _parseGoogle(resp.data!);
        if (result.isNotEmpty) return result;
      }
    } catch (e) {
      debugPrint('[Translate] google failed: $e');
    }

    // 3) MyMemory 兜底。
    final dio2 = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (s) => s != null && s < 500,
    ));
    final resp2 = await dio2.get<String>(
      'https://api.mymemory.translated.net/get',
      queryParameters: {'q': q, 'langpair': 'auto|$tl'},
    );
    dio2.close();
    if (resp2.statusCode == 200 && resp2.data != null) {
      final map = jsonDecode(resp2.data!) as Map<String, dynamic>;
      final data = map['responseData'] as Map<String, dynamic>?;
      final translated = data?['translatedText'] as String?;
      if (translated != null && translated.isNotEmpty) return translated;
    }
    throw Exception('翻译服务不可用，请稍后重试');
  }

  /// API 翻译实际使用的供应商：设置里指定的优先，否则 AI 当前生效的。
  Future<AiProviderConfig?> _resolveProvider() async {
    final explicitId = await TranslateStore.instance.getApiProviderId();
    if (explicitId != null && explicitId.isNotEmpty) {
      final p = await AiProviderStore.instance.findById(explicitId);
      if (p != null && p.enabled) return p;
    }
    return AiProviderStore.instance.getActive();
  }

  /// 用 OpenAI 兼容 chat 接口做翻译：系统提示词约束「只输出译文」，
  /// 温度最低，避免模型加解释/前后缀。
  Future<String> _translateViaAi(
      AiProviderConfig provider, String apiKey, String text, String target) async {
    final result = await AiService.instance.chatOnce(
      provider: provider,
      apiKey: apiKey,
      messages: [
        {'role': 'user', 'content': text},
      ],
      systemPrompt: '你是专业的翻译引擎。请把用户发送的内容翻译成'
          '${targetLabel(target)}。只输出译文本身，不要加任何解释、'
          '引号、前后缀或注释。原文是单一语言时自动检测；混合语言时'
          '全部翻译成目标语言。保持原有的段落和换行结构。',
    );
    return result.content.trim();
  }

  /// 解析 Google gtx 返回：[[["译文","原文",...],...],...]
  String _parseGoogle(String raw) {
    final list = jsonDecode(raw) as List;
    if (list.isEmpty || list.first is! List) return '';
    final segments = list.first as List;
    final buf = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] is String) {
        buf.write(seg[0] as String);
      }
    }
    return buf.toString();
  }
}

/// 翻译异常（中文文案，UI 直接展示）。
class TranslateException implements Exception {
  final String message;
  const TranslateException(this.message);

  @override
  String toString() => message;
}
