import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';
import '../services/doc_export_service.dart';
import '../services/storage_service.dart';
import '../widgets/app_shell.dart';
import 'book_notes_screen.dart';
import 'memo_list_screen.dart';
import 'reader_screen.dart';

/// 切换到「笔记」Tab 时自增，通知 NotesScreen 重新加载。
/// IndexedStack 让各 Tab 常驻，initState 只跑一次——不加这个，在阅读器里
/// 新加的笔记在笔记中心永远看不到（用户反馈「笔记中心无笔记」的根因）。
final notesRefreshProvider = StateProvider<int>((ref) => 0);

/// Global notes centre — search, filter, swipe-to-edit, tap-to-jump, export.
///
/// Rewritten S6:
/// - Top search bar (debounced DB full-text search via searchAnnotations)
/// - Filter chips: by book, by type (highlight/note), by tag
/// - Entry card: quoted text with left colour bar + grey bg, note body,
///   bottom metadata row (书名 · 位置 · 日期)
/// - Swipe left: delete; swipe right: edit note text
/// - Tap → jump to book (ReaderScreen with initialAnchor), if book is local
/// - Export: current filtered results, grouped by book, Markdown with > quotes,
///   written to Documents/ in addition to system share sheet
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  // ── Data ────────────────────────────────────────────────────────────

  List<Annotation>? _allAnnotations;
  final Map<String, String> _bookTitles = {}; // bookId → title (fallback cache)
  List<String> _allTags = [];
  bool _loading = true;

  /// readest 引擎书内标注（高亮/划线/波浪线 + 笔记正文）。
  List<ReadestNote> _allReadestNotes = [];

  /// AI 笔记（阅读器 AI 对话框确认过的内容）。
  List<AiNote> _allAiNotes = [];

  /// Word（DOCX）批注（Phase 4）。
  List<DocxNote> _allDocxNotes = [];

  // ── Search & filter state ───────────────────────────────────────────

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _searchQuery = '';
  String? _filterBookId;
  AnnotationType? _filterType;
  String? _filterTag;

  /// 载体分类：'pdf' / 'epub' / 'other'（按锚点类型推断文件类型）。
  String? _filterCarrier;

  /// 只看 PDF 手写批注（source='ink' 的合成条目）。
  bool _filterInk = false;

  // Two view modes: grouped by book (default) or flat chronological.
  bool _chronological = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────

  StorageService get _storage => ref.read(storageServiceProvider);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final annotations = _searchQuery.isNotEmpty
          ? await _storage.searchAnnotations(_searchQuery)
          : await _storage.getAllAnnotations();
      if (!mounted) return;
      _allAnnotations = annotations;
      _allTags = await _storage.allTags();
      if (!mounted) return;
      // readest 书内标注（书签除外）：笔记中心按书分组要算进来。
      try {
        _allReadestNotes = (await _storage.getAllReadestNotes())
            .where((n) => n.style != 'bookmark')
            .toList();
      } catch (e) {
        debugPrint('[Anno] readest notes load failed: $e');
        _allReadestNotes = [];
      }
      if (!mounted) return;
      // AI 笔记：同样并入按书分组统计。
      try {
        _allAiNotes = await _storage.getAllAiNotes();
      } catch (e) {
        debugPrint('[Anno] ai notes load failed: $e');
        _allAiNotes = [];
      }
      if (!mounted) return;
      // Word（DOCX）批注：并入按书分组统计（Phase 4）。
      try {
        _allDocxNotes = await _storage.getAllDocxNotes();
      } catch (e) {
        debugPrint('[Anno] docx notes load failed: $e');
        _allDocxNotes = [];
      }
      if (!mounted) return;

      // Fill in missing book titles from the bookshelf table.
      await _resolveBookTitles(annotations);
      if (!mounted) return;
      await _resolveReadestBookTitles();
    } catch (e) {
      debugPrint('[Anno] notes screen load failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// readest 标注没有书名字段——逐个查书架补齐。
  Future<void> _resolveReadestBookTitles() async {
    final missing = <String>{};
    for (final n in _allReadestNotes) {
      if (!_bookTitles.containsKey(n.bookId)) missing.add(n.bookId);
    }
    for (final id in missing) {
      try {
        final book = await _storage.getBook(id);
        if (book != null) _bookTitles[id] = book.title;
      } catch (_) {}
    }
  }

  /// Look up book titles for annotations that don't have one cached.
  ///
  /// Old (pre-S3) annotations have `bookTitle == null`. We query the
  /// bookshelf table once per unique bookId and cache the result.
  Future<void> _resolveBookTitles(List<Annotation> annotations) async {
    final missing = <String>{};
    for (final a in annotations) {
      if ((a.bookTitle == null || a.bookTitle!.isEmpty) &&
          !_bookTitles.containsKey(a.bookId)) {
        missing.add(a.bookId);
      }
    }
    if (missing.isEmpty) return;

    for (final id in missing) {
      try {
        final book = await _storage.getBook(id);
        if (book != null) {
          _bookTitles[id] = book.title;
        }
      } catch (_) {}
    }
  }

  String _bookLabel(Annotation a) {
    if (a.bookTitle != null && a.bookTitle!.isNotEmpty) return a.bookTitle!;
    return _bookTitles[a.bookId] ?? a.bookId;
  }

  // ── Search ──────────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (_searchQuery != value) {
        _searchQuery = value;
        _load();
      }
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchCtrl.clear();
    if (_searchQuery.isNotEmpty) {
      _searchQuery = '';
      _load();
    }
  }

  // ── Filters ─────────────────────────────────────────────────────────

  /// Computed list: master data → in-memory filters.
  List<Annotation> get _displayed {
    if (_allAnnotations == null) return [];
    var list = _allAnnotations!;
    if (_filterBookId != null) {
      list = list.where((a) => a.bookId == _filterBookId).toList();
    }
    if (_filterType != null) {
      list = list.where((a) => a.type == _filterType).toList();
    }
    if (_filterTag != null) {
      list = list
          .where((a) => a.tags.any((t) => t == _filterTag))
          .toList();
    }
    if (_filterCarrier != null) {
      list = list.where((a) {
        switch (_filterCarrier!) {
          case 'pdf':
            return a.anchor.kind == AnchorKind.pdf;
          case 'epub':
            return a.anchor.kind == AnchorKind.epub;
          default:
            return a.anchor.kind == AnchorKind.plain;
        }
      }).toList();
    }
    if (_filterInk) {
      list = list.where((a) => a.source == 'ink').toList();
    }
    // Sort: by book (alphabetical by label) then position, or by time.
    if (_chronological) {
      list = List.from(list)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else {
      list = List.from(list)
        ..sort((a, b) {
          final cmp = _bookLabel(a).compareTo(_bookLabel(b));
          if (cmp != 0) return cmp;
          return a.location.compareTo(b.location);
        });
    }
    return list;
  }

  /// Unique book entries for the book filter chip.
  List<({String id, String title})> get _filterableBooks {
    if (_allAnnotations == null) return [];
    final seen = <String>{};
    final result = <({String id, String title})>[];
    for (final a in _allAnnotations!) {
      if (seen.add(a.bookId)) {
        result.add((id: a.bookId, title: _bookLabel(a)));
      }
    }
    for (final n in _allDocxNotes) {
      if (seen.add(n.bookId)) {
        result.add(
            (id: n.bookId, title: _bookTitles[n.bookId] ?? n.bookId));
      }
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return result;
  }

  bool get _anyFilterActive =>
      _filterBookId != null ||
      _filterType != null ||
      _filterTag != null ||
      _filterCarrier != null ||
      _filterInk;

  void _clearFilters() {
    setState(() {
      _filterBookId = null;
      _filterType = null;
      _filterTag = null;
      _filterCarrier = null;
      _filterInk = false;
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Future<void> _deleteAnnotation(Annotation a) async {
    if (a.id == null) return;
    await _storage.deleteAnnotation(a.id!);
    setState(() {
      _allAnnotations?.removeWhere((x) => x.id == a.id);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _editNote(Annotation a) async {
    final ctrl = TextEditingController(text: a.note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑笔记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (a.quotedText.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  border: const Border(
                      left: BorderSide(color: Colors.grey, width: 3)),
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                ),
                child: Text(a.quotedText,
                    style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ),
            TextField(
              controller: ctrl,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入笔记内容…',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final updated = a.copyWith(note: ctrl.text.trim());
    await _storage.updateAnnotationFull(updated);
    setState(() {
      final idx = _allAnnotations?.indexWhere((x) => x.id == a.id);
      if (idx != null && idx >= 0) {
        _allAnnotations![idx] = updated;
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('笔记已更新'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// Jump to the book and annotation position.
  ///
  /// Looks up the [Book] from the bookshelf; if not found locally the user
  /// sees a message instead of a broken reader screen.
  Future<void> _jumpToBook(Annotation a) async {
    final book = await _storage.getBook(a.bookId);
    if (!mounted) return;
    if (book == null || book.localPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('《${_bookLabel(a)}》未下载到本地，请先导入该书'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          initialAnchor: a.anchor,
          initialAnnotationId: a.id,
        ),
      ),
    );
  }

  // ── Export ──────────────────────────────────────────────────────────

  /// 导出当前筛选结果：md / txt / docx / pdf / 原书文件。
  ///
  /// 笔记导出先弹「勾选笔记」面板（可全选/全不选），再生成文件 →
  /// 保存到系统下载目录（文件 App 可见）→ 分享 → 成功弹窗。
  /// 「导出原书文件」弹「选书」面板，把所选书的原文件复制到下载目录并分享。
  Future<void> _exportNotes(String format) async {
    // 原书文件导出：先让用户勾选要导出哪几本书。
    if (format == 'original') {
      await _exportOriginalFiles();
      return;
    }

    final all = _displayed;
    if (all.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导出的笔记')),
        );
      }
      return;
    }

    final selected = await _pickNotesToExport(all);
    if (selected == null || !mounted) return;
    if (selected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有勾选任何笔记，已取消导出')),
        );
      }
      return;
    }

    final list = selected;
    try {
      final String path;
      switch (format) {
        case 'txt':
          path = await DocExportService.instance.notesToTxt(list, _bookLabel);
        case 'docx':
          path = await DocExportService.instance.notesToDocx(list, _bookLabel);
        case 'pdf':
          path = await DocExportService.instance.notesToPdf(list, _bookLabel);
        default:
          path = await _writeMarkdownFile(list);
      }
      if (!mounted) return;
      await _finishExport(path,
          successTitle: '导出成功（${list.length} 条笔记）');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), duration: const Duration(seconds: 4)),
        );
      }
    }
  }

  /// 导出收尾：存到系统下载目录（文件 App 可见）→ 弹出分享/完成面板。
  Future<void> _finishExport(String path, {String successTitle = '导出成功'}) async {
    final export = ref.read(fileExportServiceProvider);
    final fileName = p.basename(path);
    String? savedTo;
    try {
      savedTo = await export.saveToDownloads(filePath: path, fileName: fileName);
    } catch (e) {
      debugPrint('[Export] saveToDownloads failed: $e');
    }
    if (!mounted) return;
    final shareNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 40),
        title: Text('✅ $successTitle'),
        content: Text(
          savedTo == null || savedTo.isEmpty
              ? '文件已生成：$fileName\n\n'
                  '（保存到系统下载目录失败，但你仍可直接分享或稍后从 App 内再次导出）'
              : '文件已保存到本机下载目录（系统「文件」App 可见）：\n$fileName',
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('完成'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('分享'),
          ),
        ],
      ),
    );
    if (shareNow == true && mounted) {
      try {
        await export.shareFile(filePath: path, text: 'Libranote 导出：$fileName');
      } catch (e) {
        debugPrint('[Export] share failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('分享失败: $e'), duration: const Duration(seconds: 3)),
          );
        }
      }
    }
  }

  /// 勾选要导出的原书文件（默认勾选当前筛选结果涉及的、已下载到本地的书）。
  /// 返回选中的 Book 列表；取消返回 null。
  Future<List<Book>?> _pickBooksToExport(List<Book> candidates) {
    final checked = <String>{
      for (final b in candidates)
        if (b.localPath != null && b.localPath!.isNotEmpty) b.id,
    };

    return showModalBottomSheet<List<Book>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setLocal) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                    child: Row(
                      children: [
                        Text('选择要导出的原书文件',
                            style: Theme.of(ctx).textTheme.titleMedium),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setLocal(() {
                            if (checked.length == candidates.length) {
                              checked.clear();
                            } else {
                              checked
                                ..clear()
                                ..addAll(candidates.map((b) => b.id));
                            }
                          }),
                          child: Text(checked.length == candidates.length
                              ? '全不选'
                              : '全选'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (ctx, i) {
                        final b = candidates[i];
                        final ext = (b.extension ?? '').toUpperCase();
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: checked.contains(b.id),
                          onChanged: (v) => setLocal(() {
                            if (v == true) {
                              checked.add(b.id);
                            } else {
                              checked.remove(b.id);
                            }
                          }),
                          title: Text(
                            b.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            ext.isEmpty ? '未知格式' : ext,
                            style: TextStyle(
                                fontSize: 11, color: colors.onSurfaceVariant),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx, null),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final selected = candidates
                                  .where((b) => checked.contains(b.id))
                                  .toList();
                              Navigator.pop(ctx, selected);
                            },
                            child: Text('导出已选 ${checked.length} 本'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 把所选**原书文件**复制到系统下载目录并分享。
  Future<void> _exportOriginalFiles() async {
    final storage = ref.read(storageServiceProvider);
    // 候选 = 书架里已下载到本地的全部书。
    final shelf = await storage.getBookshelf();
    final candidates = shelf
        .where((b) =>
            (b.localPath != null && b.localPath!.isNotEmpty) &&
            File(b.localPath!).existsSync())
        .toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('书架里还没有已下载到本地的书，无法导出原文件'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    final selected = await _pickBooksToExport(candidates);
    if (selected == null || !mounted) return;
    if (selected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有勾选任何书，已取消导出')),
        );
      }
      return;
    }

    final export = ref.read(fileExportServiceProvider);
    final saved = <String>[];
    final failed = <String>[];
    for (final b in selected) {
      try {
        final name = p.basename(b.localPath!);
        await export.saveToDownloads(filePath: b.localPath!, fileName: name);
        saved.add(name);
      } catch (e) {
        failed.add('《${b.title}》: $e');
      }
    }
    if (!mounted) return;
    final shareNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          saved.isNotEmpty ? Icons.check_circle : Icons.error_outline,
          color: saved.isNotEmpty ? const Color(0xFF16A34A) : Colors.red,
          size: 40,
        ),
        title: Text(saved.isNotEmpty ? '✅ 原书导出成功' : '导出失败'),
        content: Text(
          [
            if (saved.isNotEmpty)
              '已导出 ${saved.length} 本到本机下载目录（系统「文件」App 可见）：\n'
                  '${saved.join('、')}',
            if (failed.isNotEmpty) '失败：${failed.join('；')}',
          ].join('\n\n'),
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('完成'),
          ),
          if (saved.isNotEmpty)
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('分享'),
            ),
        ],
      ),
    );
    if (shareNow == true && mounted && saved.isNotEmpty) {
      // 逐本调系统分享（多选时连续弹分享面板）。
      for (final b in selected) {
        try {
          await export.shareFile(filePath: b.localPath!, text: '《${b.title}》');
        } catch (e) {
          debugPrint('[Export] share original failed: $e');
        }
      }
    }
  }

  /// 勾选导出面板：列出当前筛选结果，可勾选任意一个或多个（默认全选）。
  /// 返回选中的笔记列表；取消返回 null。
  Future<List<Annotation>?> _pickNotesToExport(List<Annotation> all) {
    final checked = all.map((a) => a.id).whereType<int>().toSet();
    final anonymousCount = all.where((a) => a.id == null).length;

    return showModalBottomSheet<List<Annotation>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setLocal) => SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                    child: Row(
                      children: [
                        Text('勾选要导出的笔记',
                            style: Theme.of(ctx).textTheme.titleMedium),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setLocal(() {
                            if (checked.length == all.length) {
                              checked.clear();
                            } else {
                              checked
                                ..clear()
                                ..addAll(all.map((a) => a.id).whereType<int>());
                            }
                          }),
                          child: Text(checked.length == all.length
                              ? '全不选'
                              : '全选'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: all.length,
                      itemBuilder: (ctx, i) {
                        final a = all[i];
                        final id = a.id;
                        final isChecked = id != null && checked.contains(id);
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: isChecked,
                          onChanged: (v) => setLocal(() {
                            if (id == null) return;
                            if (v == true) {
                              checked.add(id);
                            } else {
                              checked.remove(id);
                            }
                          }),
                          title: Text(
                            a.quotedText.isNotEmpty
                                ? a.quotedText
                                : a.note,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${_bookLabel(a)} · ${a.location}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: colors.onSurfaceVariant),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx, null),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final selected = all
                                  .where((a) =>
                                      a.id != null && checked.contains(a.id))
                                  .toList();
                              Navigator.pop(ctx, selected);
                            },
                            child: Text(
                                '导出已选 ${checked.length + anonymousCount} 条'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 把当前结果写成 Markdown 文件到 Documents，返回路径。
  Future<String> _writeMarkdownFile(List<Annotation> list) async {
    final md = _toMarkdown(list);
    final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final filename = 'libranote-notes-$date.md';
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(md, encoding: utf8);
    return file.path;
  }

  String _toMarkdown(List<Annotation> annotations) {
    final buf = StringBuffer();
    buf.writeln('# Libranote 笔记导出');
    buf.writeln();
    buf.writeln(
        '导出时间: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buf.writeln('共 ${annotations.length} 条笔记');
    buf.writeln();

    // Group by book (preserve sorted order).
    final grouped = <String, List<Annotation>>{};
    final bookOrder = <String>[];
    for (final a in annotations) {
      final label = _bookLabel(a);
      if (grouped.containsKey(label)) {
        grouped[label]!.add(a);
      } else {
        grouped[label] = [a];
        bookOrder.add(label);
      }
    }

    for (final label in bookOrder) {
      final entries = grouped[label]!;
      buf.writeln('## $label');
      buf.writeln();
      for (final a in entries) {
        buf.writeln('> ${a.quotedText}');
        buf.writeln();
        if (a.note.isNotEmpty) {
          buf.writeln(a.note);
          buf.writeln();
        }
        final date =
            DateFormat('yyyy-MM-dd HH:mm').format(a.createdAt);
        final type =
            a.type == AnnotationType.highlight ? '📌 高亮' : '📝 笔记';
        buf.writeln('— $type · ${a.location} · $date');
        buf.writeln();
      }
      buf.writeln('---');
      buf.writeln();
    }
    return buf.toString();
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    // 每次切到本 Tab（或任何触发点）都重新加载，避免显示旧数据。
    ref.listen(notesRefreshProvider, (_, __) => _load());

    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sticky_note_2_outlined),
            tooltip: '备忘录',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MemoListScreen()),
              );
            },
          ),
          if (_anyFilterActive)
            TextButton(
              onPressed: _clearFilters,
              child: const Text('清除筛选'),
            ),
          IconButton(
            icon: Icon(_chronological
                ? Icons.menu_book
                : Icons.access_time),
            tooltip: _chronological ? '按书名分组' : '按时间排序',
            onPressed: () =>
                setState(() => _chronological = !_chronological),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '导出',
            onSelected: _exportNotes,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'md', child: Text('导出笔记 Markdown (.md)')),
              PopupMenuItem(value: 'txt', child: Text('导出笔记 文本 (.txt)')),
              PopupMenuItem(value: 'docx', child: Text('导出笔记 Word (.docx)')),
              PopupMenuItem(value: 'pdf', child: Text('导出笔记 PDF (.pdf)')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'original', child: Text('导出原书文件（选书）')),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppAvatar()),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索笔记…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: _clearSearch,
                      )
                    : null,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999)),
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 18),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
          ),
          // ── Filter chips ───────────────────────────────────────
          if (_allTags.isNotEmpty || _filterableBooks.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                children: [
                  // Type filter
                  _FilterChip(
                    label: '高亮',
                    selected: _filterType == AnnotationType.highlight,
                    onTap: () => setState(() => _filterType =
                        _filterType == AnnotationType.highlight
                            ? null
                            : AnnotationType.highlight),
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: '笔记',
                    selected: _filterType == AnnotationType.note,
                    onTap: () => setState(() => _filterType =
                        _filterType == AnnotationType.note
                            ? null
                            : AnnotationType.note),
                  ),
                  const SizedBox(width: 6),
                  // 载体分类（什么类型的文件）。
                  _FilterChip(
                    label: 'PDF 笔记',
                    selected: _filterCarrier == 'pdf',
                    onTap: () => setState(() => _filterCarrier =
                        _filterCarrier == 'pdf' ? null : 'pdf'),
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: 'EPUB 笔记',
                    selected: _filterCarrier == 'epub',
                    onTap: () => setState(() => _filterCarrier =
                        _filterCarrier == 'epub' ? null : 'epub'),
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: '手写批注',
                    selected: _filterInk,
                    onTap: () =>
                        setState(() => _filterInk = !_filterInk),
                  ),
                  // Tag filters (top 8 most-used tags)
                  ..._allTags.take(8).map((tag) {
                    final sel = _filterTag == tag;
                    return Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _FilterChip(
                        label: tag,
                        selected: sel,
                        onTap: () =>
                            setState(() => _filterTag = sel ? null : tag),
                      ),
                    );
                  }),
                  // Book filter dropdown
                  if (_filterableBooks.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    ActionChip(
                      avatar: Icon(
                        _filterBookId == null
                            ? Icons.filter_list
                            : Icons.check,
                        size: 16,
                      ),
                      label: Text(_filterBookId == null
                          ? '按书'
                          : _filterableBooks
                              .firstWhere(
                                  (b) => b.id == _filterBookId,
                                  orElse: () =>
                                      (id: '', title: '按书'))
                              .title),
                      onPressed: () => _showBookFilterPicker(),
                    ),
                  ],
                ],
              ),
            ),
          // ── Note list ──────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _showBookList
                    ? _buildBookList(colors)
                    : _displayed.isEmpty
                        ? _buildEmpty(colors)
                        : _buildList(colors),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ColorScheme colors) {
    final hasQuery =
        _searchQuery.isNotEmpty || _anyFilterActive;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasQuery ? Icons.search_off : Icons.note_outlined,
            size: 64,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            hasQuery ? '没有匹配的笔记' : '暂无笔记',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (!hasQuery) ...[
            const SizedBox(height: 4),
            Text('阅读时添加的批注和笔记会汇集到这里',
                style: TextStyle(
                    fontSize: 13, color: colors.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme colors) {
    final displayed = _displayed;

    if (_chronological) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: displayed.length,
        itemBuilder: (_, i) => _NoteCard(
          annotation: displayed[i],
          bookLabel: _bookLabel(displayed[i]),
          colors: colors,
          onTap: () => _jumpToBook(displayed[i]),
          onEdit: () => _editNote(displayed[i]),
          onDelete: () => _deleteAnnotation(displayed[i]),
        ),
      );
    }

    // Grouped by book: insert headers between groups.
    final groups = <({String label, List<Annotation> items})>[];
    String? currentLabel;
    for (final a in displayed) {
      final label = _bookLabel(a);
      if (label != currentLabel) {
        currentLabel = label;
        groups.add((label: label, items: [a]));
      } else {
        groups.last.items.add(a);
      }
    }

    final entries = <Widget>[];
    for (final g in groups) {
      entries.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.menu_book,
                  size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  g.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${g.items.length} 条',
                  style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant)),
            ],
          ),
        ),
      );
      for (final a in g.items) {
        entries.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _NoteCard(
              annotation: a,
              bookLabel: g.label,
              colors: colors,
              onTap: () => _jumpToBook(a),
              onEdit: () => _editNote(a),
              onDelete: () => _deleteAnnotation(a),
            ),
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: entries,
    );
  }

  // ── 按书分组（两级导航第一级：书本列表） ──────────────────────────

  /// 每本书的笔记汇总（annotations + readest 标注 + AI 笔记 + Word 批注合并）。
  List<
      ({
        String id,
        String title,
        int annos,
        int marks,
        int ink,
        int ai,
        int docx
      })> get _bookGroups {
    final map = <String,
        ({
          String id,
          String title,
          int annos,
          int marks,
          int ink,
          int ai,
          int docx
        })>{};
    for (final a in _allAnnotations ?? <Annotation>[]) {
      final cur = map[a.bookId];
      map[a.bookId] = (
        id: a.bookId,
        title: cur?.title ?? _bookLabel(a),
        annos: (cur?.annos ?? 0) + 1,
        marks: cur?.marks ?? 0,
        ink: (cur?.ink ?? 0) + (a.source == 'ink' ? 1 : 0),
        ai: cur?.ai ?? 0,
        docx: cur?.docx ?? 0,
      );
    }
    for (final n in _allReadestNotes) {
      final cur = map[n.bookId];
      map[n.bookId] = (
        id: n.bookId,
        title: cur?.title ?? _bookTitles[n.bookId] ?? n.bookId,
        annos: cur?.annos ?? 0,
        marks: (cur?.marks ?? 0) + 1,
        ink: cur?.ink ?? 0,
        ai: cur?.ai ?? 0,
        docx: cur?.docx ?? 0,
      );
    }
    for (final a in _allAiNotes) {
      final cur = map[a.bookId];
      map[a.bookId] = (
        id: a.bookId,
        title: cur?.title ?? _bookTitles[a.bookId] ?? a.bookId,
        annos: cur?.annos ?? 0,
        marks: cur?.marks ?? 0,
        ink: cur?.ink ?? 0,
        ai: (cur?.ai ?? 0) + 1,
        docx: cur?.docx ?? 0,
      );
    }
    for (final n in _allDocxNotes) {
      final cur = map[n.bookId];
      map[n.bookId] = (
        id: n.bookId,
        title: cur?.title ?? _bookTitles[n.bookId] ?? n.bookId,
        annos: cur?.annos ?? 0,
        marks: cur?.marks ?? 0,
        ink: cur?.ink ?? 0,
        ai: cur?.ai ?? 0,
        docx: (cur?.docx ?? 0) + 1,
      );
    }
    final list = map.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return list;
  }

  /// 默认视图 = 书本列表；有搜索/筛选或时间排序时退回笔记平铺列表。
  bool get _showBookList =>
      _searchQuery.isEmpty && !_anyFilterActive && !_chronological;

  Widget _buildBookList(ColorScheme colors) {
    final groups = _bookGroups;
    if (groups.isEmpty) return _buildEmpty(colors);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: groups.length,
      itemBuilder: (_, i) {
        final g = groups[i];
        final parts = <String>[
          if (g.annos > 0) '高亮/批注 ${g.annos}',
          if (g.marks > 0) '书内标注 ${g.marks}',
          if (g.docx > 0) 'Word 批注 ${g.docx}',
          if (g.ai > 0) 'AI 笔记 ${g.ai}',
          if (g.ink > 0) '手写 ${g.ink}',
        ];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: colors.primaryContainer,
              child: Icon(Icons.menu_book, size: 20, color: colors.primary),
            ),
            title: Text(g.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              parts.join(' · '),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BookNotesScreen(
                    bookId: g.id,
                    bookTitle: g.title,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showBookFilterPicker() {
    final books = _filterableBooks;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_filterBookId != null)
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('全部书籍'),
                onTap: () {
                  setState(() => _filterBookId = null);
                  Navigator.pop(ctx);
                },
              ),
            ...books.map((b) => ListTile(
                  leading: Icon(
                    _filterBookId == b.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(b.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    setState(() => _filterBookId = b.id);
                    Navigator.pop(ctx);
                  },
                )),
          ],
        ),
      ),
    );
  }
}

// ── Filter chip ─────────────────────────────────────────────────────────

/// 统一筛选 chip：白底 + 描边 + 深色字（未选中）/ 主题色淡底 + 主题色字
/// （选中）。白色风格下不再与纸色背景融为一体。
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? colors.primary : colors.onSurface,
          )),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      backgroundColor: colors.surface,
      selectedColor: colors.primaryContainer,
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
        width: selected ? 1.4 : 1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      showCheckmark: false,
    );
  }
}

// ── Note card ────────────────────────────────────────────────────────────

class _NoteCard extends StatelessWidget {
  final Annotation annotation;
  final String bookLabel;
  final ColorScheme colors;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _NoteCard({
    required this.annotation,
    required this.bookLabel,
    required this.colors,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  String get _date {
    final d = annotation.createdAt;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Color? get _highlightColor {
    final c = annotation.color;
    if (c == null || c.isEmpty) return null;
    return Color(int.parse(c.replaceFirst('#', '0xFF')));
  }

  @override
  Widget build(BuildContext context) {
    final color = _highlightColor;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Slidable(
        // Swipe left (end) → delete
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          children: [
            SlidableAction(
              onPressed: (_) => onDelete(),
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
              icon: Icons.delete_outline,
              label: '删除',
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
          ],
        ),
        // Swipe right (start) → edit
        startActionPane: ActionPane(
          motion: const BehindMotion(),
          children: [
            SlidableAction(
              onPressed: (_) => onEdit(),
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              icon: Icons.edit_outlined,
              label: '编辑',
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Quoted text with left colour bar.
                if (annotation.quotedText.isNotEmpty)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left colour bar (or grey for notes without colour).
                        Container(
                          width: 3,
                          decoration: BoxDecoration(
                            color: color ?? colors.outline.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            annotation.quotedText,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Note body (for notes — shown in normal text colour).
                if (annotation.note.isNotEmpty) ...[
                  if (annotation.quotedText.isNotEmpty)
                    const SizedBox(height: 8),
                  Text(
                    annotation.note,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurface,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 6),
                // Metadata row.
                Row(
                  children: [
                    if (annotation.source == 'ink')
                      Icon(Icons.gesture, size: 14, color: colors.primary)
                    else if (annotation.type == AnnotationType.highlight)
                      Icon(Icons.format_quote,
                          size: 14, color: color ?? colors.primary)
                    else
                      Icon(Icons.edit_note,
                          size: 14, color: colors.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '$bookLabel · ${annotation.location} · $_date',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
