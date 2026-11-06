import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/storage_service.dart';

/// AI 中心「+」上传选择器：两个 Tab——书库（全部本地书籍）与
/// 笔记中心（批注 / Word 批注 / AI 笔记 / 书内标注）。
///
/// 确认后 pop 返回选中的 [AiAttachment] 列表；取消返回 null。
class AttachmentPickerSheet extends StatefulWidget {
  final StorageService storage;

  /// 已上传附件的 key 集合（本弹层内禁用重复勾选）。
  final Set<String> already;

  const AttachmentPickerSheet({
    super.key,
    required this.storage,
    this.already = const {},
  });

  @override
  State<AttachmentPickerSheet> createState() => _AttachmentPickerSheetState();
}

class _AttachmentPickerSheetState extends State<AttachmentPickerSheet> {
  static const int _maxBooks = 10;
  static const int _maxNotes = 20;

  List<Book> _books = [];
  List<_NoteEntry> _notes = [];
  bool _loading = true;

  final Set<String> _selected = {};
  final _bookCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String _bookQuery = '';
  String _noteQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _bookCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final books = await widget.storage.getBookshelf();
      final titles = {for (final b in books) b.id: b.title};
      final entries = <_NoteEntry>[];
      for (final a in await widget.storage.getAllAnnotations()) {
        entries.add(_NoteEntry(
          key: 'annotation:${a.id}',
          kind: 'annotation',
          ref: '${a.id}',
          label: '批注 · ${a.bookTitle ?? titles[a.bookId] ?? a.bookId}',
          detail: a.quotedText,
        ));
      }
      for (final n in await widget.storage.getAllDocxNotes()) {
        entries.add(_NoteEntry(
          key: 'docx_note:${n.id}',
          kind: 'docx_note',
          ref: '${n.id}',
          label: 'Word 批注 · ${titles[n.bookId] ?? n.bookId}',
          detail: n.quotedText,
        ));
      }
      for (final n in await widget.storage.getAllAiNotes()) {
        entries.add(_NoteEntry(
          key: 'ai_note:${n.id}',
          kind: 'ai_note',
          ref: '${n.id}',
          label: 'AI 笔记 · ${titles[n.bookId] ?? n.bookId}',
          detail: n.quotedText,
        ));
      }
      for (final n in await widget.storage.getAllReadestNotes()) {
        entries.add(_NoteEntry(
          key: 'readest_note:${n.id}',
          kind: 'readest_note',
          ref: '${n.id}',
          label: '书内标注 · ${titles[n.bookId] ?? n.bookId}',
          detail: n.text,
        ));
      }
      if (!mounted) return;
      setState(() {
        _books = books;
        _notes = entries;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[AI] attachment picker load failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Book> get _filteredBooks {
    if (_bookQuery.isEmpty) return _books;
    final q = _bookQuery.toLowerCase();
    return _books
        .where((b) =>
            b.title.toLowerCase().contains(q) ||
            b.author.toLowerCase().contains(q))
        .toList();
  }

  List<_NoteEntry> get _filteredNotes {
    if (_noteQuery.isEmpty) return _notes;
    final q = _noteQuery.toLowerCase();
    return _notes
        .where((n) =>
            n.label.toLowerCase().contains(q) ||
            n.detail.toLowerCase().contains(q))
        .toList();
  }

  void _toggle(String key, String kind) {
    setState(() {
      if (!_selected.remove(key)) {
        final bookCount = _selected.where((k) => k.startsWith('book:')).length;
        final noteCount = _selected.length - bookCount;
        if (kind == 'book' && bookCount >= _maxBooks) {
          _toast('最多上传 $_maxBooks 本书（先取消几本再选）');
          return;
        }
        if (kind != 'book' && noteCount >= _maxNotes) {
          _toast('最多上传 $_maxNotes 条笔记（先取消几条再选）');
          return;
        }
        _selected.add(key);
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  List<AiAttachment> _buildResult() {
    final out = <AiAttachment>[];
    for (final b in _books) {
      if (!_selected.contains('book:${b.id}')) continue;
      final author = b.author.isEmpty ? '' : '${b.author} · ';
      out.add(AiAttachment(
        kind: 'book',
        ref: b.id,
        label: '《${b.title}》',
        detail: '$author${(b.extension ?? '').toUpperCase()}',
      ));
    }
    for (final n in _notes) {
      if (!_selected.contains(n.key)) continue;
      out.add(AiAttachment(
        kind: n.kind,
        ref: n.ref,
        label: n.label,
        detail: n.detail,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.82;
    return SizedBox(
      height: height,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '上传资料给 AI',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '已选 ${_selected.length}',
                    style: TextStyle(
                        fontSize: 12.5, color: Colors.grey.shade600),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            TabBar(
              tabs: [
                Tab(text: '书库（${_books.length}）'),
                Tab(text: '笔记中心（${_notes.length}）'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      children: [_buildBooksTab(), _buildNotesTab()],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44)),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(_selected.isEmpty
                            ? '不添加'
                            : '添加 ${_selected.length} 个附件'),
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44)),
                        onPressed: () =>
                            Navigator.pop(context, _buildResult()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(TextEditingController ctrl, String hint,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: ctrl,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildBooksTab() {
    final books = _filteredBooks;
    if (books.isEmpty) {
      return Center(
        child: Text(
          _books.isEmpty ? '书架是空的（先导入书籍）' : '没有匹配的书',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      );
    }
    return Column(
      children: [
        _searchField(_bookCtrl, '搜索书名 / 作者', (v) {
          setState(() => _bookQuery = v.trim());
        }),
        Expanded(
          child: ListView.builder(
            itemCount: books.length,
            itemBuilder: (ctx, i) {
              final b = books[i];
              final key = 'book:${b.id}';
              final hasFile = b.localPath != null && b.localPath!.isNotEmpty;
              final already = widget.already.contains(key);
              return CheckboxListTile(
                dense: true,
                value: _selected.contains(key) || already,
                onChanged: hasFile && !already
                    ? (_) => _toggle(key, 'book')
                    : null,
                title: Text('《${b.title}》',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  hasFile
                      ? '${b.author} · ${(b.extension ?? '').toUpperCase()}'
                          '${b.folder.isEmpty ? '' : ' · ${b.folder}'}'
                      : '未下载到本地（AI 无法读取内容）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNotesTab() {
    final notes = _filteredNotes;
    if (notes.isEmpty) {
      return Center(
        child: Text(
          _notes.isEmpty ? '笔记中心还没有笔记' : '没有匹配的笔记',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      );
    }
    return Column(
      children: [
        _searchField(_noteCtrl, '搜索笔记原文 / 内容', (v) {
          setState(() => _noteQuery = v.trim());
        }),
        Expanded(
          child: ListView.builder(
            itemCount: notes.length,
            itemBuilder: (ctx, i) {
              final n = notes[i];
              final already = widget.already.contains(n.key);
              return CheckboxListTile(
                dense: true,
                value: _selected.contains(n.key) || already,
                onChanged:
                    already ? null : (_) => _toggle(n.key, n.kind),
                title: Text(n.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  n.detail.isEmpty ? '（无原文）' : n.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 笔记中心条目（跨四张表归一化）。
class _NoteEntry {
  final String key;
  final String kind;
  final String ref;
  final String label;
  final String detail;

  const _NoteEntry({
    required this.key,
    required this.kind,
    required this.ref,
    required this.label,
    required this.detail,
  });
}
