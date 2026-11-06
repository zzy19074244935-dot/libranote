import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/translate_service.dart';

/// 拍照翻译历史记录：保存在 App 内（照片存 Documents/photo_translate/，
/// 记录在本地数据库）。可查看原文/译文、删除单条或全部清空。
class TranslateHistoryScreen extends ConsumerStatefulWidget {
  const TranslateHistoryScreen({super.key});

  @override
  ConsumerState<TranslateHistoryScreen> createState() =>
      _TranslateHistoryScreenState();
}

class _TranslateHistoryScreenState
    extends ConsumerState<TranslateHistoryScreen> {
  List<TranslateRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await ref.read(storageServiceProvider).getTranslateRecords();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _delete(TranslateRecord r) async {
    if (r.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录'),
        content: const Text('记录与保存的照片会一起删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(storageServiceProvider).deleteTranslateRecord(r.id!);
    _load();
  }

  Future<void> _clearAll() async {
    if (_records.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部记录'),
        content: const Text('将删除全部拍照翻译记录和保存的照片，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final storage = ref.read(storageServiceProvider);
    for (final r in _records) {
      if (r.id != null) await storage.deleteTranslateRecord(r.id!);
    }
    _load();
  }

  void _openDetail(TranslateRecord r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (ctx, scrollCtrl) => ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              DateFormat('yyyy-MM-dd HH:mm').format(r.createdAt),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            if (r.imagePath != null && File(r.imagePath!).existsSync()) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(r.imagePath!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Text('原文',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            SelectableText(r.sourceText,
                style: const TextStyle(fontSize: 14, height: 1.6)),
            const Divider(height: 24),
            Text('译文 · ${TranslateService.targetLabel(r.target)}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            SelectableText(r.translatedText,
                style: const TextStyle(fontSize: 14, height: 1.6)),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('翻译历史'),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              tooltip: '清空全部',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Text('还没有翻译记录。\n去拍照翻译一次，记录会自动保存在这里。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _records.length,
                  itemBuilder: (ctx, i) {
                    final r = _records[i];
                    return Card(
                      child: ListTile(
                        onTap: () => _openDetail(r),
                        leading: r.imagePath != null &&
                                File(r.imagePath!).existsSync()
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Image.file(
                                    File(r.imagePath!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                        Icons.image_outlined,
                                        color: Colors.grey.shade400),
                                  ),
                                ),
                              )
                            : const Icon(Icons.translate),
                        title: Text(
                          r.sourceText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5),
                        ),
                        subtitle: Text(
                          '→ ${r.translatedText}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF64748B)),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              DateFormat('MM-dd HH:mm').format(r.createdAt),
                              style: TextStyle(
                                  fontSize: 10, color: Colors.grey.shade500),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              onPressed: () => _delete(r),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
