import 'package:flutter/material.dart';

import '../models/ai_models.dart';
import '../services/ai_provider_config.dart';
import '../services/translate_service.dart';

/// 翻译设置：
/// · 网页翻译接口（免费接口开关 + 默认目标语言）；
/// · **API 翻译**（与 AI 配置共用同一套供应商/API Key——阅读器里的选中翻译、
///   拍照翻译、AI 翻译都用它；质量比免费接口高，配置方式与 AI 功能相同）。
class TranslationSettingsScreen extends StatefulWidget {
  const TranslationSettingsScreen({super.key});

  @override
  State<TranslationSettingsScreen> createState() =>
      _TranslationSettingsScreenState();
}

class _TranslationSettingsScreenState
    extends State<TranslationSettingsScreen> {
  bool _enabled = true;
  String _target = 'zh-CN';
  bool _apiEnabled = false;
  String? _apiProviderId;
  List<AiProviderConfig> _providers = const [];
  bool _loaded = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _enabled = await TranslateStore.instance.isEnabled();
    _target = await TranslateStore.instance.getTarget();
    _apiEnabled = await TranslateStore.instance.isApiEnabled();
    _apiProviderId = await TranslateStore.instance.getApiProviderId();
    _providers = await AiProviderStore.instance.loadAll();
    if (mounted) setState(() => _loaded = true);
  }

  /// 测试 API 翻译：翻译一句固定样例，成功显示译文。
  Future<void> _testApi() async {
    setState(() => _testing = true);
    try {
      final provider = await _resolveProvider();
      if (provider == null) {
        _toast('还没有可用的 AI 供应商，请先在 AI 设置里开启一个并填 API Key');
        return;
      }
      final key = await AiProviderStore.instance.getApiKey(provider.id);
      if (key == null || key.isEmpty) {
        _toast('供应商「${provider.name}」还没有 API Key，请到 AI 设置里填写');
        return;
      }
      // 直连测试（不受本页开关影响）：样例中→英。
      final before = await TranslateStore.instance.isApiEnabled();
      final savedId = await TranslateStore.instance.getApiProviderId();
      try {
        await TranslateStore.instance.setApiEnabled(true);
        await TranslateStore.instance
            .setApiProviderId(provider.id);
        final result = await TranslateService.instance
            .translate('你好，世界。这是一条翻译测试。', 'en');
        if (mounted) _toast('✅ 翻译成功：$result');
      } finally {
        await TranslateStore.instance.setApiEnabled(before);
        await TranslateStore.instance.setApiProviderId(savedId);
      }
    } catch (e) {
      if (mounted) _toast('测试失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<AiProviderConfig?> _resolveProvider() async {
    if (_apiProviderId != null && _apiProviderId!.isNotEmpty) {
      final p = await AiProviderStore.instance.findById(_apiProviderId!);
      if (p != null && p.enabled) return p;
    }
    return AiProviderStore.instance.getActive();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabledProviders =
        _providers.where((p) => p.enabled).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('翻译设置')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('翻译总开关'),
                  subtitle: const Text('关闭后阅读器选中翻译 / 拍照翻译均不可用'),
                  value: _enabled,
                  onChanged: (v) async {
                    await TranslateStore.instance.setEnabled(v);
                    setState(() => _enabled = v);
                  },
                ),
                const Divider(height: 8),
                Text('默认目标语言',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('选中文字翻译时默认翻成这种语言（拍照翻译页里可临时改）',
                    style: TextStyle(
                        fontSize: 12.5, color: colors.onSurfaceVariant)),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: _target,
                  onChanged: (v) async {
                    if (v == null) return;
                    await TranslateStore.instance.setTarget(v);
                    setState(() => _target = v);
                  },
                  child: Column(
                    children: [
                      for (final (code, label) in TranslateService.targets)
                        RadioListTile<String>(
                          value: code,
                          title: Text(label),
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
                const Divider(height: 28),
                // ── API 翻译（与 AI 配置共用同一套 API） ─────────────
                Text('API 翻译', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '开启后优先用 AI 模型翻译（阅读器选中翻译、拍照翻译共用）。'
                  '供应商与 API Key 和 AI 功能是同一套——到「AI 配置设置」里管理，'
                  '这里只选择用哪一家；没配 Key 时自动退回下面的免费接口。',
                  style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('启用 API 翻译'),
                        subtitle: const Text('优先使用 AI 供应商翻译（质量更高）'),
                        value: _apiEnabled,
                        onChanged: (v) async {
                          await TranslateStore.instance.setApiEnabled(v);
                          setState(() => _apiEnabled = v);
                        },
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('翻译供应商'),
                        subtitle: Text(
                          enabledProviders.isEmpty
                              ? '还没有开启的供应商（先到 AI 设置里开启一个）'
                              : '当前：${_currentProviderName(enabledProviders)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _enabledProviderCount(enabledProviders) > 1
                            ? const Icon(Icons.chevron_right)
                            : null,
                        onTap: _enabledProviderCount(enabledProviders) > 1
                            ? () => _pickProvider(enabledProviders)
                            : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('测试 API 翻译'),
                        subtitle: const Text('发送一句测试文本，验证 Key 与模型可用'),
                        trailing: _testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : TextButton(
                                onPressed: _testApi,
                                child: const Text('测试')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '提示：免费接口（Google gtx / MyMemory）不需要任何配置，'
                  '但个别网络下质量或可达性不如 API 翻译；两者可随时切换。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: colors.onSurfaceVariant),
                ),
              ],
            ),
    );
  }

  int _enabledProviderCount(List<AiProviderConfig> enabled) =>
      enabled.length;

  String _currentProviderName(List<AiProviderConfig> enabled) {
    if (_apiProviderId != null) {
      for (final p in enabled) {
        if (p.id == _apiProviderId) return '${p.name} · ${p.model}';
      }
    }
    return enabled.isNotEmpty
        ? '${enabled.first.name} · ${enabled.first.model}（跟随 AI 当前模型）'
        : '—';
  }

  Future<void> _pickProvider(List<AiProviderConfig> enabled) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择翻译供应商',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('跟随 AI 当前模型（推荐）'),
              subtitle: Text(
                  '使用 AI 设置里的当前供应商：${enabled.first.name}'),
              trailing: _apiProviderId == null
                  ? Icon(Icons.check,
                      color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final p in enabled)
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: Text('${p.name} · ${p.model}'),
                subtitle: Text(p.baseUrl,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: _apiProviderId == p.id
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, p.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await TranslateStore.instance.setApiProviderId(chosen.isEmpty ? null : chosen);
    if (mounted) setState(() => _apiProviderId = chosen.isEmpty ? null : chosen);
  }
}
