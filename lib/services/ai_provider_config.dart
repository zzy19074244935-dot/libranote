import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_models.dart';

/// AI 供应商配置的存取。
///
/// 分层存储（重要）：
/// - 配置本体（名称/地址/模型/温度/开关）→ shared_preferences 的 JSON 数组，
///   导出同步配置时只导出它；
/// - API Key → flutter_secure_storage（Windows=DPAPI、Android=加密 SharedPrefs），
///   永不落明文、永不随配置导出。
class AiProviderStore {
  AiProviderStore._();
  static final AiProviderStore instance = AiProviderStore._();

  static const _prefsKey = 'ai_providers_v1';
  static const _activeKey = 'ai_active_provider_v1';
  static const _fontKey = 'ai_chat_font_size_v1';

  // 与 auth_service 保持同一构造方式（不带 AndroidOptions），避免同一
  // key 在不同实例间因加密后端不一致读不到。
  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  /// 预置三家（全部 OpenAI 兼容协议）。
  /// 默认关：没有用户自己的 key，任何一家都调不通，避免误触发空请求。
  static List<AiProviderConfig> defaultProviders() => [
        const AiProviderConfig(
          id: 'deepseek',
          name: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com/v1',
          // 2026-08-17 实测 /models 返回 deepseek-v4-flash 与
          // deepseek-v4-pro（deepseek-chat 已不在官方列表，仅别名兼容）。
          model: 'deepseek-v4-flash',
          enabled: false,
          preset: true,
          tutorialUrl: 'https://platform.deepseek.com/',
        ),
        const AiProviderConfig(
          id: 'kimi',
          name: 'Kimi（月之暗面）',
          baseUrl: 'https://api.moonshot.cn/v1',
          // kimi-latest = 官方「始终指向最新指令跟随模型」的别名，不会
          // 因具体模型下线而失效（moonshot-v1-8k/32k 与 kimi-k2.5 系列
          // 已于 2026-08 陆续下线，老用户预置值会 400 报错）。
          // 新平台（platform.kimi.com / kimi-k3）接入后可在设置页用
          // 「获取模型列表」重新选择。
          model: 'kimi-latest',
          // 推理模型（k2/k3）只接受 temperature=1，预置直接固定；
          // 万一用户选了老模型，固定成 1 也完全合法。
          fixedTemperature: true,
          enabled: false,
          preset: true,
          tutorialUrl: 'https://platform.moonshot.cn/',
        ),
        const AiProviderConfig(
          id: 'qwen',
          name: 'Qwen（阿里云百炼）',
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          model: 'qwen-plus',
          enabled: false,
          preset: true,
          tutorialUrl: 'https://bailian.console.aliyun.com/',
        ),
      ];

  /// 读全部供应商：用户存过的 + 补上新增的预置项。
  ///
  /// 合并而不是直接返回存储值：未来版本加新的预置供应商时，老用户也能
  /// 自动看到；自定义供应商带 preset:false 原样保留。
  Future<List<AiProviderConfig>> loadAll() async {
    final defaults = defaultProviders();
    final saved = await _loadSaved();
    if (saved.isEmpty) return defaults;

    final byId = <String, AiProviderConfig>{
      for (final p in saved) p.id: p,
    };
    // 预置项优先用存储值（用户改过名字/模型/开关）；存储里没有的补默认。
    final merged = <AiProviderConfig>[
      for (final d in defaults) byId.remove(d.id) ?? d,
      ...byId.values,
    ];
    return merged;
  }

  Future<List<AiProviderConfig>> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => AiProviderConfig.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      debugPrint('[AI] load providers failed: $e');
      return [];
    }
  }

  /// 按 id 查单个（不存在返回 null）。
  Future<AiProviderConfig?> findById(String id) async {
    final all = await loadAll();
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 保存（按 id upsert）。
  Future<void> save(AiProviderConfig p) async {
    final all = await _loadSaved();
    final idx = all.indexWhere((e) => e.id == p.id);
    if (idx >= 0) {
      all[idx] = p;
    } else {
      all.add(p);
    }
    await _writeAll(all);
  }

  /// 删除自定义供应商（预置不可删）；同时清掉它存过的 API Key。
  Future<void> delete(String id) async {
    final all = await _loadSaved();
    all.removeWhere((e) => e.id == id);
    await _writeAll(all);
    await _secure.delete(key: _keyStorageName(id));
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_activeKey) == id) {
      await prefs.remove(_activeKey);
    }
  }

  Future<void> _writeAll(List<AiProviderConfig> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode([for (final p in list) p.toJson()]));
  }

  // ── API Key（secure storage） ──────────────────────────────────────

  static String _keyStorageName(String providerId) => 'ai_key_$providerId';

  Future<String?> getApiKey(String providerId) async {
    try {
      return await _secure.read(key: _keyStorageName(providerId));
    } catch (e) {
      debugPrint('[AI] read key failed: $e');
      return null;
    }
  }

  Future<void> setApiKey(String providerId, String key) async {
    if (key.isEmpty) {
      await _secure.delete(key: _keyStorageName(providerId));
    } else {
      await _secure.write(key: _keyStorageName(providerId), value: key.trim());
    }
  }

  // ── 当前供应商 ─────────────────────────────────────────────────────

  Future<String?> getActiveId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  Future<void> setActiveId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
  }

  /// 当前生效的供应商：显式选中优先；否则第一个已开启且有 key 的；
  /// 都没有则返回第一个已开启的（让 UI 显示「未配 key」引导）。
  Future<AiProviderConfig?> getActive() async {
    final all = await loadAll();
    final enabled = all.where((p) => p.enabled).toList();
    if (enabled.isEmpty) return null;

    final activeId = await getActiveId();
    AiProviderConfig? match;
    for (final p in enabled) {
      if (p.id == activeId) match = p;
    }
    if (match != null) {
      final key = await getApiKey(match.id);
      if (key != null && key.isNotEmpty) return match;
    }
    for (final p in enabled) {
      final key = await getApiKey(p.id);
      if (key != null && key.isNotEmpty) return p;
    }
    return match ?? enabled.first;
  }

  // ── AI 中心字体大小 ───────────────────────────────────────────────

  Future<double> getChatFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_fontKey) ?? 16;
  }

  Future<void> setChatFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontKey, size);
  }
}
