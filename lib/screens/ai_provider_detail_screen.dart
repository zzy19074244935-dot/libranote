import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ai_models.dart';
import '../services/ai_service.dart';
import '../services/ai_provider_config.dart';

/// 供应商详情页：名称 / 协议类型 / API 地址 / 模型（可拉取列表）/ 推理强度 /
/// API Key / 配置教程（预置供应商）。
///
/// 字段顺序参照 anx-reader 的 ai_provider_detail_page（用户需求 1:1）。
class AiProviderDetailScreen extends ConsumerStatefulWidget {
  /// null = 新建自定义供应商。
  final String? providerId;

  const AiProviderDetailScreen({super.key, required this.providerId});

  @override
  ConsumerState<AiProviderDetailScreen> createState() =>
      _AiProviderDetailScreenState();
}

class _AiProviderDetailScreenState extends ConsumerState<AiProviderDetailScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;
  final TextEditingController _keyCtrl = TextEditingController();

  double _temperature = 0.7;
  bool _fixedTemperature = false;
  bool _enabled = true;
  bool _isPreset = false;
  String _tutorialUrl = '';
  bool _obscureKey = true;
  bool _saving = false;
  bool _fetchingModels = false;
  bool _testingChat = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _urlCtrl = TextEditingController();
    _modelCtrl = TextEditingController();
    _init();
  }

  Future<void> _init() async {
    if (widget.providerId == null) return;
    final p = await AiProviderStore.instance.findById(widget.providerId!);
    final key = await AiProviderStore.instance.getApiKey(widget.providerId!);
    if (!mounted) return;
    setState(() {
      if (p != null) {
        _nameCtrl.text = p.name;
        _urlCtrl.text = p.baseUrl;
        _modelCtrl.text = p.model;
        _temperature = p.temperature;
        _fixedTemperature = p.fixedTemperature;
        _enabled = p.enabled;
        _isPreset = p.preset;
        _tutorialUrl = p.tutorialUrl ?? '';
      }
      _keyCtrl.text = key ?? '';
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  /// 归一化 API 地址：去尾斜杠，剥掉用户可能整段粘贴的
  /// /chat/completions 或 /models 尾段。注意不剥中间的
  /// compatible-mode/v1 之类路径（Qwen 靠它定位兼容端点）。
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    for (final suffix in const ['/chat/completions', '/models']) {
      if (s.endsWith(suffix)) {
        s = s.substring(0, s.length - suffix.length);
      }
    }
    return s;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    final url = normalizeBaseUrl(_urlCtrl.text);
    final model = _modelCtrl.text.trim();
    if (name.isEmpty) {
      _toast('请填写供应商名称');
      return;
    }
    if (url.isEmpty || !url.startsWith('http')) {
      _toast('请填写有效的 API 地址（https:// 开头）');
      return;
    }
    if (model.isEmpty) {
      _toast('请填写或拉取模型名');
      return;
    }

    setState(() => _saving = true);
    try {
      final id = widget.providerId ?? 'custom_${DateTime.now().millisecondsSinceEpoch}';
      // 预置供应商的 id/协议/教程链接不可改；自定义的全部从表单取。
      final existing =
          widget.providerId != null
              ? await AiProviderStore.instance.findById(widget.providerId!)
              : null;
      final p = AiProviderConfig(
        id: id,
        name: name,
        baseUrl: url,
        model: model,
        temperature: _temperature,
        fixedTemperature: _fixedTemperature,
        enabled: existing?.enabled ?? _enabled,
        preset: existing?.preset ?? false,
        protocol: existing?.protocol ?? 'openai',
        tutorialUrl: existing?.tutorialUrl,
      );
      await AiProviderStore.instance.save(p);
      await AiProviderStore.instance.setApiKey(id, _keyCtrl.text.trim());
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      _toast('保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _fetchModels() async {
    final url = normalizeBaseUrl(_urlCtrl.text);
    final key = _keyCtrl.text.trim();
    if (url.isEmpty || key.isEmpty) {
      _toast('请先填写 API 地址和 API Key');
      return;
    }
    setState(() => _fetchingModels = true);
    try {
      final models = await AiService.instance.fetchModels(
        provider: AiProviderConfig(
          id: 'tmp',
          name: 'tmp',
          baseUrl: url,
          model: '',
        ),
        apiKey: key,
      );
      if (!mounted) return;
      if (models.isEmpty) {
        _toast('该地址没有返回模型列表，可以手动填写模型名');
        return;
      }
      final picked = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('选择模型（${models.length} 个）',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: models.length,
                  itemBuilder: (ctx, i) => ListTile(
                    dense: true,
                    title: Text(models[i], style: const TextStyle(fontSize: 14)),
                    onTap: () => Navigator.pop(ctx, models[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      if (picked != null) setState(() => _modelCtrl.text = picked);
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  /// 用当前表单里的地址/Key/模型发一句「你好」验证对话是否通。
  /// 失败时直接展示带 HTTP 状态码与服务端 error.message 的翻译文案。
  Future<void> _testChat() async {
    final url = normalizeBaseUrl(_urlCtrl.text);
    final key = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    if (url.isEmpty || key.isEmpty || model.isEmpty) {
      _toast('请先填写 API 地址、API Key 和模型名');
      return;
    }
    setState(() => _testingChat = true);
    try {
      final result = await AiService.instance.chatOnce(
        provider: AiProviderConfig(
          id: 'tmp',
          name: 'tmp',
          baseUrl: url,
          model: model,
          temperature: _temperature,
          fixedTemperature: _fixedTemperature,
        ),
        apiKey: key,
        messages: [
          {'role': 'user', 'content': '你好，请只回复「连接成功」四个字。'},
        ],
      );
      if (!mounted) return;
      _toast(result.content.isEmpty
          ? '测试完成，但模型返回为空（换个模型试试）'
          : '测试成功：${result.content}');
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _testingChat = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.providerId == null ? '添加供应商' : '供应商设置'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '供应商名称',
              hintText: '如 DeepSeek / Kimi / 我的中转站',
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
            ),
          ),
          const SizedBox(height: 16),
          // 协议类型：本版本只有 OpenAI 兼容（三家供应商都是），先禁用
          // 展示，未来加 Anthropic 风格时放开。
          DropdownButtonFormField<String>(
            initialValue: 'openai',
            items: const [
              DropdownMenuItem(
                  value: 'openai', child: Text('OpenAI 兼容（DeepSeek / Kimi / Qwen）')),
            ],
            onChanged: null,
            decoration: const InputDecoration(
              labelText: '协议类型',
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'API 地址',
              hintText: 'https://api.deepseek.com/v1',
              helperText: '可以粘贴完整的 /chat/completions 地址，保存时自动归一化',
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _modelCtrl,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    hintText: 'deepseek-chat',
                    border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: _fetchingModels
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_download_outlined),
                label: const Text('获取模型列表'),
                onPressed: _fetchingModels ? null : _fetchModels,
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: _testingChat
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chat_bubble_outline),
            label: Text(_testingChat ? '测试中…' : '测试对话（发一句「你好」）'),
            onPressed: _testingChat ? null : _testChat,
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('推理强度', style: TextStyle(fontWeight: FontWeight.w600)),
              Expanded(
                child: Slider(
                  value: _temperature.clamp(0, 2),
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: _temperature.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _temperature = v),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(_temperature.toStringAsFixed(1),
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
          Text(
            _temperature <= 0.4
                ? '低：回答更稳定、确定性高'
                : _temperature >= 1.2
                    ? '高：回答更多样、有创造性'
                    : '中：稳定性与创造性平衡（推荐）',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('温度固定为 1（推理模型）',
                style: TextStyle(fontSize: 14)),
            subtitle: const Text(
                'kimi-k2/k3 等推理模型只接受 temperature=1，'
                '报 400「invalid temperature」时勾上这个',
                style: TextStyle(fontSize: 12)),
            value: _fixedTemperature,
            onChanged: (v) => setState(() => _fixedTemperature = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-...',
              helperText: '只保存在本机加密存储，不会随配置导出',
              border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscureKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          if (_isPreset && _tutorialUrl.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.school_outlined),
                title: const Text('配置教程'),
                subtitle: const Text('怎么注册并创建 API Key（打开浏览器）'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () async {
                  // 不依赖 canLaunchUrl：Android 11+ 受 <queries> 限制，
                  // 直接 launch，失败则复制链接（历史 §30.6 的教训）。
                  final ok = await launchUrl(Uri.parse(_tutorialUrl),
                      mode: LaunchMode.externalApplication);
                  if (!ok) {
                    await Clipboard.setData(ClipboardData(text: _tutorialUrl));
                    _toast('已复制教程链接，请在浏览器打开');
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
