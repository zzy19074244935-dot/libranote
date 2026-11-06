import 'package:flutter/material.dart';

import '../services/ai_tools.dart';

/// AI 工具开关页：14 个工具默认全开，关掉的工具模型将不可见。
class AiToolsSettingsScreen extends StatefulWidget {
  const AiToolsSettingsScreen({super.key});

  @override
  State<AiToolsSettingsScreen> createState() => _AiToolsSettingsScreenState();
}

class _AiToolsSettingsScreenState extends State<AiToolsSettingsScreen> {
  Set<String> _disabled = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _disabled = await AiToolsStore.instance.disabledNames();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _toggle(AiToolDefinition tool, bool enabled) async {
    await AiToolsStore.instance.setDisabled(tool.name, !enabled);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 工具')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '对话时模型会自动判断并调用这些工具（如「帮我算 3.14×2^5」→'
                      '调用计算器）。关掉的工具模型看不到；全部工具执行都在本机，'
                      '只把结果回传给模型。',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final tool in AiTools.all())
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: SwitchListTile(
                      title: Text(tool.label,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '示例：${tool.example}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      value: !_disabled.contains(tool.name),
                      onChanged: (v) => _toggle(tool, v),
                    ),
                  ),
              ],
            ),
    );
  }
}
