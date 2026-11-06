import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/models.dart';
import '../providers/app_providers.dart';
import 'whiteboard_screen.dart';

final whiteboardRefreshProvider = StateProvider<int>((ref) => 0);

/// Local Flutter drawing documents; no external canvas SDK is required.
class WhiteboardListScreen extends ConsumerStatefulWidget {
  const WhiteboardListScreen({super.key});
  @override
  ConsumerState<WhiteboardListScreen> createState() =>
      _WhiteboardListScreenState();
}

class _WhiteboardListScreenState extends ConsumerState<WhiteboardListScreen> {
  List<Whiteboard> _boards = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(storageServiceProvider).getWhiteboardRows();
      final boards = rows.map(Whiteboard.fromJson).toList();
      if (mounted) {
        setState(() {
          _boards = boards;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '画布加载失败：$error');
    }
  }

  Future<void> _open([Whiteboard? board]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WhiteboardScreen(board: board),
    ));
    if (mounted) await _load();
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null) throw const FormatException('无法读取文件');
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (envelope['format'] != 'libranote-canvas-v1' ||
          envelope['document'] is! Map) {
        throw const FormatException('请选择 Libranote 导出的画布 JSON');
      }
      final document = Map<String, dynamic>.from(envelope['document'] as Map);
      document.remove('id');
      final board = Whiteboard.fromJson(document);
      if (board.isTldraw) throw const FormatException('此版本仅支持原生画布');
      if (mounted) await _open(board);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$error')),
        );
      }
    }
  }

  Future<void> _export(Whiteboard board) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'libranote-canvas-${board.id}.json'));
      await file.writeAsString(jsonEncode({
        'format': 'libranote-canvas-v1',
        'document': board.toJson(),
      }));
      await Share.shareXFiles([XFile(file.path)], subject: board.title);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$error')),
        );
      }
    }
  }

  Future<void> _delete(Whiteboard board) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除画布'),
              content: Text('确定删除“${board.title}”吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'))
              ],
            ));
    if (confirmed != true || !mounted || board.id == null) return;
    await ref.read(storageServiceProvider).deleteWhiteboard(board.id!);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(whiteboardRefreshProvider, (_, __) => _load());
    return Scaffold(
      appBar: AppBar(title: const Text('画布'), actions: [
        IconButton(
            tooltip: '导入画布',
            onPressed: _import,
            icon: const Icon(Icons.file_open_outlined)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add),
        label: const Text('新建画布'),
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _boards.isEmpty
              ? const Center(child: Text('创建一张画布，记录你的思路'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: _boards.length,
                  itemBuilder: (context, index) {
                    final board = _boards[index];
                    return Card(
                        child: ListTile(
                      leading: const Icon(Icons.draw_outlined),
                      title: Text(board.title.isEmpty ? '未命名画布' : board.title),
                      subtitle: Text(
                          '${board.strokes.length} 笔迹 · ${board.texts.length} 文本'),
                      onTap: () => _open(board),
                      trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'export') _export(board);
                            if (value == 'delete') _delete(board);
                          },
                          itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'export', child: Text('导出')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('删除')),
                              ]),
                    ));
                  }),
    );
  }
}
