import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';
import 'memo_editor_screen.dart';

/// 备忘录列表 —— 独立的记事本（区别于读书批注）。
///
/// 每篇备忘录是一组带样式（标题/小标题/副标题/正文/等宽）的文本块，
/// 存在 SQLite 的 `memo` 表里。列表按最近更新排序，点开进编辑器。
class MemoListScreen extends ConsumerStatefulWidget {
  const MemoListScreen({super.key});

  @override
  ConsumerState<MemoListScreen> createState() => _MemoListScreenState();
}

class _MemoListScreenState extends ConsumerState<MemoListScreen> {
  List<Memo>? _memos;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final memos = await ref.read(storageServiceProvider).getMemos();
      if (mounted) setState(() => _memos = memos);
    } catch (e) {
      debugPrint('[Memo] load failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 打开编辑器；返回后刷新列表（可能新建或改了内容）。
  Future<void> _openEditor([Memo? memo]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MemoEditorScreen(memo: memo)),
    );
    _load();
  }

  Future<void> _delete(Memo memo) async {
    if (memo.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(memo.title.isEmpty ? '删除备忘录' : '删除《${memo.title}》'),
        content: const Text('确定要删除这篇备忘录吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(storageServiceProvider).deleteMemo(memo.id!);
    _load();
  }

  String _preview(Memo memo) {
    final text = memo.blocks
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' · ');
    return text.isEmpty ? '（空白备忘录）' : text;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final memos = _memos;

    return Scaffold(
      appBar: AppBar(title: const Text('备忘录')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新建备忘录'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : memos == null || memos.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sticky_note_2_outlined,
                          size: 64, color: colors.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text('暂无备忘录',
                          style: TextStyle(color: colors.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text('点右下角「新建备忘录」开始记录',
                          style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: memos.length,
                  itemBuilder: (_, i) {
                    final memo = memos[i];
                    return ListTile(
                      leading: const Icon(Icons.sticky_note_2_outlined),
                      title: Text(
                        memo.title.isEmpty ? '未命名' : memo.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _preview(memo),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            DateFormat('MM-dd')
                                .format(memo.updatedAt),
                            style: TextStyle(
                                fontSize: 11, color: colors.onSurfaceVariant),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _delete(memo),
                          ),
                        ],
                      ),
                      onTap: () => _openEditor(memo),
                    );
                  },
                ),
    );
  }
}
