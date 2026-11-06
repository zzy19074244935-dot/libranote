import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ai_models.dart';
import '../providers/providers.dart';
import '../services/ai_tools.dart';

/// 提示词管理：用户自定义提示词的增删改查。
///
/// 用途：AI 中心底部预设 chips（自定义提示词排在系统预设前）+ 可把某条
/// 设为「系统提示」（每次对话都带上的背景指令）。
class AiPromptsScreen extends ConsumerStatefulWidget {
  const AiPromptsScreen({super.key});

  @override
  ConsumerState<AiPromptsScreen> createState() => _AiPromptsScreenState();
}

class _AiPromptsScreenState extends ConsumerState<AiPromptsScreen> {
  List<AiPrompt> _prompts = [];
  int? _systemId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _prompts = await ref.read(storageServiceProvider).getAiPrompts();
    _systemId = await AiToolsStore.instance.systemPromptId();
    if (mounted) setState(() {});
  }

  Future<void> _edit([AiPrompt? prompt]) async {
    final titleCtrl = TextEditingController(text: prompt?.title ?? '');
    final contentCtrl = TextEditingController(text: prompt?.content ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(prompt == null ? '添加提示词' : '编辑提示词'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: '标题（显示在预设 chips 上）',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contentCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '提示词内容',
                  hintText: '如：你是一位严谨的学术助手，回答请分点并给出依据…',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    final content = contentCtrl.text.trim();
    if (title.isEmpty || content.isEmpty) {
      _toast('标题与内容都不能为空');
      return;
    }
    final storage = ref.read(storageServiceProvider);
    if (prompt == null) {
      await storage.insertAiPrompt(AiPrompt(title: title, content: content));
    } else {
      await storage
          .updateAiPrompt(prompt.copyWith(title: title, content: content));
    }
    _load();
  }

  Future<void> _delete(AiPrompt p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除提示词'),
        content: Text('确定删除「${p.title}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(storageServiceProvider).deleteAiPrompt(p.id!);
    if (_systemId == p.id) {
      await AiToolsStore.instance.setSystemPromptId(null);
    }
    _load();
  }

  Future<void> _setSystem(AiPrompt p) async {
    // 再点一次 = 取消系统提示。
    final next = _systemId == p.id ? null : p.id;
    await AiToolsStore.instance.setSystemPromptId(next);
    _load();
    _toast(next == null
        ? '已取消系统提示'
        : '「${p.title}」已设为系统提示（每次对话都会带上）');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 提示词')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('添加提示词'),
      ),
      body: _prompts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.text_snippet_outlined,
                        size: 48, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text(
                      '还没有自定义提示词\n'
                      '点右下角「添加提示词」创建自己的预设\n'
                      '（如：翻译成英文 / 总结成三个要点 / 扮演某个角色）',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.7,
                          color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              itemCount: _prompts.length,
              itemBuilder: (ctx, i) {
                final p = _prompts[i];
                final isSystem = _systemId == p.id;
                return Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(p.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ),
                            if (isSystem) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: colors.primary.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text('系统提示',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: colors.primary)),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          p.content,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, height: 1.5),
                        ),
                        isThreeLine: true,
                        onTap: () => _edit(p),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () => _setSystem(p),
                              icon: Icon(
                                isSystem
                                    ? Icons.remove_circle_outline
                                    : Icons.smart_toy_outlined,
                                size: 16,
                              ),
                              label: Text(isSystem ? '取消系统提示' : '设为系统提示',
                                  style: const TextStyle(fontSize: 12.5)),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () => _edit(p),
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: const Text('编辑',
                                  style: TextStyle(fontSize: 12.5)),
                            ),
                            TextButton.icon(
                              onPressed: () => _delete(p),
                              icon: Icon(Icons.delete_outline,
                                  size: 16, color: colors.error),
                              label: Text('删除',
                                  style: TextStyle(
                                      fontSize: 12.5, color: colors.error)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
