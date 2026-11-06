import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_models.dart';
import '../services/ai_provider_config.dart';
import '../services/ai_tools.dart';
import 'ai_prompts_screen.dart';
import 'ai_provider_detail_screen.dart';
import 'ai_tools_settings_screen.dart';
import 'mcp_servers_screen.dart';

/// AI 配置：供应商开关列表 + 添加自定义供应商。
///
/// 点击供应商 → 详情页（名称/协议/地址/模型拉取/推理强度/API Key/教程）；
/// 右侧圆圈按钮 = 设为当前使用。
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  List<AiProviderConfig> _providers = [];
  String? _activeId;
  bool _autoApprove = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _providers = await AiProviderStore.instance.loadAll();
    _activeId = await AiProviderStore.instance.getActiveId();
    _autoApprove = await AiToolsStore.instance.autoApproveWrite();
    if (mounted) setState(() {});
  }

  Future<void> _toggle(AiProviderConfig p, bool value) async {
    await AiProviderStore.instance.save(p.copyWith(enabled: value));
    _load();
  }

  Future<void> _setActive(AiProviderConfig p) async {
    await AiProviderStore.instance.setActiveId(p.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '支持 DeepSeek / Kimi / Qwen 及任何 OpenAI 兼容服务。\n'
                'API Key 只保存在本机加密存储，不会上传到任何第三方服务器；'
                '供应商配置教程见各供应商详情页。',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final p in _providers)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  ListTile(
                    title: Text(p.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      '${p.baseUrl}\n${p.model}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    trailing: Switch(
                      value: p.enabled,
                      onChanged: (v) => _toggle(p, v),
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              AiProviderDetailScreen(providerId: p.id),
                        ),
                      );
                      _load();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '设为当前使用',
                          icon: Icon(
                            p.id == _activeId
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: p.id == _activeId
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          onPressed: p.enabled ? () => _setActive(p) : null,
                        ),
                        TextButton(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    AiProviderDetailScreen(providerId: p.id),
                              ),
                            );
                            _load();
                          },
                          child: const Text('编辑'),
                        ),
                        const Spacer(),
                        if (!p.preset)
                          TextButton(
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('删除供应商'),
                                  content: Text(
                                      '确定删除「${p.name}」吗？已保存的 API Key 会一并清除。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        // 同 ai_center 删除弹窗：Row 里必须
                                        // 覆盖全局 (∞,52) 的 minimumSize。
                                        style: FilledButton.styleFrom(
                                            minimumSize: const Size(0, 40)),
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('删除')),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await AiProviderStore.instance.delete(p.id);
                                _load();
                              }
                            },
                            child: Text('删除',
                                style: TextStyle(color: colors.error)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加供应商'),
              subtitle: const Text('任何 OpenAI 兼容的服务都可以加'),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AiProviderDetailScreen(providerId: null),
                  ),
                );
                _load();
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.text_snippet_outlined),
                  title: const Text('AI 提示词'),
                  subtitle: const Text('自定义预设提示词 / 设为系统提示'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AiPromptsScreen()),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.build_outlined),
                  title: const Text('AI 工具'),
                  subtitle: const Text('计算器 / 书内搜索 / 笔记搜索 / 保存修改笔记 / 备忘录 / 标签 等工具开关'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AiToolsSettingsScreen()),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('MCP 服务器'),
                  subtitle: const Text('接入 MCP 生态：HTTP / 本地命令，工具并入 AI 助手'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const McpServersScreen()),
                    );
                  },
                ),
                const Divider(height: 1),
                // Agent 任务（任务式 AI）的后台写操作放行策略。
                SwitchListTile(
                  secondary: const Icon(Icons.rocket_launch_outlined),
                  title: const Text('Agent 后台自动放行写操作'),
                  subtitle: const Text('任务在后台执行遇到改数据操作时自动放行；'
                      '关闭则暂停任务等你回任务页确认（更安全）'),
                  value: _autoApprove,
                  onChanged: (v) async {
                    setState(() => _autoApprove = v);
                    await AiToolsStore.instance.setAutoApproveWrite(v);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
