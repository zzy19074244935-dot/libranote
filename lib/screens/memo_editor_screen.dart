import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import '../providers/app_providers.dart';
import '../services/doc_export_service.dart';

/// 块级富文本备忘录编辑器。
///
/// 每篇备忘录 = 标题 + 一组「块」。每块有自己的文字样式：
///   标题 / 小标题 / 副标题 / 正文 / 等宽。
/// 顶部样式工具条作用于「当前聚焦的块」；整篇可用一个全局字体（系统/衬线/等宽）。
///
/// 纯自研、无第三方富文本依赖（flutter_quill 依赖重、有冲 image/pdfrx 版本的风险，
/// 见 DEV_PLAN 硬约束 13），所以这里用「块列表 + 每块一个 TextField」的轻量方案。
class MemoEditorScreen extends ConsumerStatefulWidget {
  final Memo? memo; // null = 新建
  const MemoEditorScreen({super.key, this.memo});

  @override
  ConsumerState<MemoEditorScreen> createState() => _MemoEditorScreenState();
}

class _MemoEditorScreenState extends ConsumerState<MemoEditorScreen> {
  late final TextEditingController _titleCtrl;
  late List<MemoBlock> _blocks;
  late List<TextEditingController> _controllers;
  late List<FocusNode> _focusNodes;
  late String _fontFamily;
  int _focusedIndex = 0;
  bool _saving = false;

  static const _typeLabels = <String, String>{
    'h1': '标题',
    'h2': '小标题',
    'h3': '副标题',
    'p': '正文',
    'code': '等宽',
  };

  static const _typeOrder = ['h1', 'h2', 'h3', 'p', 'code'];

  @override
  void initState() {
    super.initState();
    final memo = widget.memo;
    _titleCtrl = TextEditingController(text: memo?.title ?? '');
    _fontFamily = memo?.fontFamily ?? 'default';
    _blocks = memo != null
        ? memo.blocks.map((b) => MemoBlock(type: b.type, text: b.text)).toList()
        : [MemoBlock(type: 'p', text: '')];
    if (_blocks.isEmpty) _blocks.add(MemoBlock(type: 'p', text: ''));
    _controllers = [];
    _focusNodes = [];
    for (var i = 0; i < _blocks.length; i++) {
      _controllers.add(TextEditingController(text: _blocks[i].text));
      final node = FocusNode();
      final index = i;
      node.addListener(() {
        if (node.hasFocus) {
          setState(() => _focusedIndex = index);
        }
      });
      _focusNodes.add(node);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  // ── Block management ──────────────────────────────────────────────

  void _addBlock() {
    setState(() {
      _blocks.add(MemoBlock(type: 'p', text: ''));
      _controllers.add(TextEditingController());
      final node = FocusNode();
      final index = _blocks.length - 1;
      node.addListener(() {
        if (node.hasFocus) setState(() => _focusedIndex = index);
      });
      _focusNodes.add(node);
      _focusedIndex = index;
    });
    // 让新块自动获得焦点，方便连续输入。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes.last.requestFocus();
    });
  }

  void _removeBlock(int index) {
    if (_blocks.length <= 1) return; // 至少保留一个块
    setState(() {
      _blocks.removeAt(index);
      _controllers.removeAt(index).dispose();
      _focusNodes.removeAt(index).dispose();
      if (_focusedIndex >= _blocks.length) _focusedIndex = _blocks.length - 1;
    });
  }

  void _setBlockType(String type) {
    if (_focusedIndex < 0 || _focusedIndex >= _blocks.length) return;
    setState(() => _blocks[_focusedIndex].type = type);
  }

  // ── Save ───────────────────────────────────────────────────────────

  /// 先把各 TextField 的当前文本写回块，再落库。
  Future<void> _save() async {
    for (var i = 0; i < _blocks.length; i++) {
      _blocks[i].text = _controllers[i].text;
    }
    final title = _titleCtrl.text.trim();
    final memo = Memo(
      id: widget.memo?.id,
      title: title,
      blocks: _blocks,
      fontFamily: _fontFamily,
      createdAt: widget.memo?.createdAt,
    );

    setState(() => _saving = true);
    try {
      final storage = ref.read(storageServiceProvider);
      if (memo.id == null) {
        await storage.insertMemo(memo);
      } else {
        await storage.updateMemo(memo);
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('[Memo] save failed: $e');
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  /// 把当前编辑器状态导出为 Word(.docx) 或 PDF，并分享/存本地。
  Future<void> _exportMemo(String format) async {
    for (var i = 0; i < _blocks.length; i++) {
      _blocks[i].text = _controllers[i].text;
    }
    final memo = Memo(
      title: _titleCtrl.text.trim(),
      blocks: _blocks,
      fontFamily: _fontFamily,
    );
    try {
      final service = DocExportService.instance;
      final path = format == 'pdf'
          ? await service.memoToPdf(memo)
          : await service.memoToDocx(memo);
      if (!mounted) return;
      await _shareAndSave(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  Future<void> _shareAndSave(String path) async {
    final export = ref.read(fileExportServiceProvider);
    await export.saveToDownloads(filePath: path, fileName: p.basename(path));
    try {
      await export.shareFile(filePath: path);
    } catch (_) {
      // 桌面端分享面板可能不可用，Documents/Downloads 的副本兜底。
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出到 $path')),
      );
    }
  }

  // ── Styling helpers ────────────────────────────────────────────────

  String? _family(String fontFamily) => switch (fontFamily) {
        'serif' => 'serif',
        'mono' => 'monospace',
        _ => null,
      };

  TextStyle _blockStyle(String type, ColorScheme colors) {
    final base = _family(_fontFamily);
    switch (type) {
      case 'h1':
        return TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            height: 1.3,
            fontFamily: base,
            color: colors.onSurface);
      case 'h2':
        return TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.bold,
            height: 1.3,
            fontFamily: base,
            color: colors.onSurface);
      case 'h3':
        return TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.4,
            fontFamily: base,
            color: colors.onSurfaceVariant);
      case 'code':
        return TextStyle(
            fontSize: 15,
            height: 1.5,
            fontFamily: 'monospace',
            color: colors.onSurface);
      case 'p':
      default:
        return TextStyle(
            fontSize: 16,
            height: 1.6,
            fontFamily: base,
            color: colors.onSurface);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isNew = widget.memo == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '新建备忘录' : '编辑备忘录'),
        actions: [
          // 全局字体选择（开源中文字体体积大，先提供系统内置字体族，
          // 后续可在此扩展 assets 内置的思源/霞鹜字体）。
          PopupMenuButton<String>(
            icon: const Icon(Icons.font_download_outlined),
            tooltip: '字体',
            initialValue: _fontFamily,
            onSelected: (v) => setState(() => _fontFamily = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'default', child: Text('系统默认')),
              PopupMenuItem(value: 'serif', child: Text('衬线（宋体类）')),
              PopupMenuItem(value: 'mono', child: Text('等宽（monospace）')),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出',
            onSelected: _exportMemo,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'docx', child: Text('导出 Word (.docx)')),
              PopupMenuItem(value: 'pdf', child: Text('导出 PDF')),
            ],
          ),
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check, size: 18),
            label: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Title ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _titleCtrl,
              textInputAction: TextInputAction.next,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: colors.onSurface,
              ),
              decoration: InputDecoration(
                hintText: '标题',
                hintStyle: TextStyle(color: colors.onSurfaceVariant),
                border: InputBorder.none,
              ),
            ),
          ),
          const Divider(height: 1),
          // ── Style toolbar ──────────────────────────────────────────
          // 作用于当前聚焦的块（块内点击即聚焦，右侧有灰色样式标签提示）。
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final t in _typeOrder) ...[
                  ChoiceChip(
                    label: Text(_typeLabels[t]!,
                        style: const TextStyle(fontSize: 12)),
                    selected: _blocks[_focusedIndex].type == t,
                    onSelected: (_) => _setBlockType(t),
                    visualDensity: VisualDensity.compact,
                    selectedColor: colors.primaryContainer,
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Blocks ─────────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _blocks.length + 1, // 最后一项是「添加段落」
              itemBuilder: (context, i) {
                if (i == _blocks.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextButton.icon(
                      onPressed: _addBlock,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加段落'),
                    ),
                  );
                }
                return _buildBlockRow(i, colors);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockRow(int index, ColorScheme colors) {
    final block = _blocks[index];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 样式标签（灰色小字），让当前块样式可见。
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _typeLabels[block.type] ?? '正文',
                style: TextStyle(
                  fontSize: 10,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _controllers[index],
              focusNode: _focusNodes[index],
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              style: _blockStyle(block.type, colors),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            tooltip: '删除该段',
            onPressed: () => _removeBlock(index),
          ),
        ],
      ),
    );
  }
}
