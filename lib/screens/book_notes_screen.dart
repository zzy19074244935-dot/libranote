import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';
import '../services/doc_export_service.dart';
import '../services/docx_loader.dart';
import '../services/storage_service.dart';
import '../widgets/app_shell.dart';
import 'readest_reader_screen.dart';
import 'reader_screen.dart';

/// 某一本书的笔记区（笔记中心按书分组后的第二级页面）。
///
/// 汇总两种笔记来源：
///   · readest 引擎的书内标注（高亮/下划线/波浪线 + 笔记正文，CFI 锚点）；
///   · 旧引擎批注（annotations 表：高亮/笔记，含 PDF 手写批注合成条目）。
/// PDF 书额外提供「导出编辑后的 PDF」（把手写笔迹烘焙进页面）。
class BookNotesScreen extends ConsumerStatefulWidget {
  final String bookId;
  final String bookTitle;

  const BookNotesScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
  });

  @override
  ConsumerState<BookNotesScreen> createState() => _BookNotesScreenState();
}

class _BookNotesScreenState extends ConsumerState<BookNotesScreen> {
  Book? _book;
  List<ReadestNote> _readestNotes = [];
  List<Annotation> _annotations = [];
  List<AiNote> _aiNotes = [];
  List<DocxNote> _docxNotes = [];
  int _inkPages = 0;
  bool _hasPdfEdits = false;
  bool _loading = true;
  bool _exporting = false;

  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _book = await _storage.getBook(widget.bookId);
      final readest = await _storage.getReadestNotes(widget.bookId);
      _readestNotes =
          readest.where((n) => n.style != 'bookmark').toList();
      final annos = await _storage.getAnnotations(widget.bookId);
      _annotations = annos;
      _aiNotes = await _storage.getAiNotes(widget.bookId);
      _docxNotes = await _storage.getDocxNotes(widget.bookId);
      _inkPages =
          (await _storage.getAllPdfInkPages(widget.bookId)).length;
      _hasPdfEdits = _inkPages > 0 ||
          _annotations.any((a) =>
              a.anchor.kind == AnchorKind.pdf && a.anchor.rects.isNotEmpty);
    } catch (e) {
      debugPrint('[BookNotes] load failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _isPdf =>
      (_book?.extension ?? '').toLowerCase() == 'pdf' ||
      _annotations.any((a) => a.anchor.kind == AnchorKind.pdf);

  bool get _isDocx => (_book?.extension ?? '').toLowerCase() == 'docx';

  // ── 跳转 ───────────────────────────────────────────────────────────

  void _openReadestNote(ReadestNote n) {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadestReaderScreen(book: book, initialCfi: n.cfi),
      ),
    );
  }

  /// AI 笔记 → 打开书并跳到对应位置（anchor 存 `{"cfi": ...}`、
  /// `{"page": N}` 或 `{"para": N}`：CFI 走 readest 引擎，页码走 pdfrx，
  /// 段落走 DOCX 阅读器）。
  void _openAiNote(AiNote n) {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    var cfi = '';
    int? page;
    int? para;
    try {
      final map = jsonDecode(n.anchor);
      if (map is Map) {
        cfi = (map['cfi'] as String?) ?? '';
        page = (map['page'] as num?)?.toInt();
        para = (map['para'] as num?)?.toInt();
      }
    } catch (_) {}
    if (para != null) {
      // DOCX 锚点：ReaderScreen 的 plain 锚点 startOffset = 段落索引。
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(
            book: book,
            initialAnchor:
                TextAnchor(kind: AnchorKind.plain, startOffset: para),
          ),
        ),
      );
      return;
    }
    if (page != null) {
      // 旧引擎（pdfrx）锚点：ReaderScreen 带 initialAnchor 自动走旧引擎。
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(
            book: book,
            initialAnchor: TextAnchor(kind: AnchorKind.pdf, pageIndex: page),
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReadestReaderScreen(
          book: book,
          initialCfi: cfi.isEmpty ? null : cfi,
        ),
      ),
    );
  }

  /// Word 批注 → 打开书跳到对应段落（plain 锚点 startOffset = 段落索引）。
  void _openDocxNote(DocxNote n) {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          initialAnchor: TextAnchor(
              kind: AnchorKind.plain, startOffset: n.paraIndex),
        ),
      ),
    );
  }

  Future<void> _deleteDocxNote(DocxNote n) async {
    if (n.id == null) return;
    await _storage.deleteDocxNote(n.id!);
    if (mounted) {
      setState(() => _docxNotes.removeWhere((a) => a.id == n.id));
    }
    _toast('已删除这条 Word 批注');
  }

  Future<void> _deleteAiNote(AiNote n) async {
    if (n.id == null) return;
    await _storage.deleteAiNote(n.id!);
    if (mounted) {
      setState(() => _aiNotes.removeWhere((a) => a.id == n.id));
    }
    _toast('已删除这条 AI 笔记');
  }

  void _openAnnotation(Annotation a) {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
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

  void _openBook() {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── 勾选标注导出（md / txt / docx / pdf） ─────────────────────────

  /// 这本书的全部标注条目（AI 笔记 + 书内标注 + Word 批注 + 旧批注合并）。
  List<ExportAppendixItem> _allAppendixItems() {
    return [
      for (final n in _aiNotes)
        ExportAppendixItem(
          label: 'AI 笔记',
          quote: n.quotedText,
          content: n.content,
          location: _aiNoteLocation(n),
        ),
      for (final n in _readestNotes)
        ExportAppendixItem(
          label: switch (n.style) {
            'underline' => '下划线',
            'squiggly' => '波浪线',
            _ => '高亮',
          },
          quote: n.text,
          content: n.note,
        ),
      for (final n in _docxNotes)
        ExportAppendixItem(
          label: n.source == 'ai'
              ? 'AI 标注'
              : n.style == 'image'
                  ? '插入图片'
                  : switch (n.style) {
                      'underline' => '下划线',
                      'squiggly' => '波浪线',
                      'plain' => '复制摘录',
                      _ => '高亮',
                    },
          quote: n.quotedText,
          content: n.note,
          location: '第 ${n.paraIndex + 1} 段',
        ),
      for (final a in _annotations)
        ExportAppendixItem(
          label: a.source == 'ink'
              ? '手写批注'
              : a.type == AnnotationType.highlight
                  ? '高亮'
                  : '笔记',
          quote: a.quotedText,
          content: a.note,
          location: a.location,
        ),
    ];
  }

  /// 勾选标注面板（可全选/全不选）→ 格式菜单 → 导出 → 保存+分享+弹窗。
  Future<void> _exportSelectedNotes() async {
    final items = _allAppendixItems();
    if (items.isEmpty) {
      _toast('这本书还没有任何标注，无法导出');
      return;
    }
    final selected = await _pickItemsToExport(items);
    if (selected == null || !mounted) return;
    if (selected.isEmpty) {
      _toast('没有勾选任何标注，已取消导出');
      return;
    }
    final format = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择导出格式（已选 ${selected.length} 条）',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            for (final (label, value, icon) in const [
              ('Markdown (.md)', 'md', Icons.notes),
              ('文本 (.txt)', 'txt', Icons.text_snippet_outlined),
              ('Word (.docx)', 'docx', Icons.description_outlined),
              ('PDF (.pdf)', 'pdf', Icons.picture_as_pdf_outlined),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(ctx, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;

    setState(() => _exporting = true);
    try {
      final svc = DocExportService.instance;
      final title = widget.bookTitle;
      String path;
      switch (format) {
        case 'txt':
          path = await svc.reportToTxt('$title 笔记', selected);
        case 'docx':
          path = await svc.reportToDocx('$title 笔记', selected);
        case 'pdf':
          path = await svc.reportToPdf('$title 笔记', selected);
        default:
          final buf = StringBuffer();
          buf.writeln('# $title 笔记');
          buf.writeln('导出时间：${_fmt(DateTime.now())}');
          buf.writeln();
          for (final it in selected) {
            buf.writeln('---');
            buf.writeln('**${it.label}**'
                '${it.location.isNotEmpty ? ' · ${it.location}' : ''}');
            if (it.quote.isNotEmpty) {
              buf.writeln();
              buf.writeln('> ${it.quote}');
            }
            if (it.content.isNotEmpty) {
              buf.writeln();
              buf.writeln(it.content);
            }
            buf.writeln();
          }
          final dir = await getTemporaryDirectory();
          final file = File(p.join(dir.path, '${title}_笔记.md'));
          await file.writeAsString(buf.toString());
          path = file.path;
      }
      if (!mounted) return;
      await _finishExport(path, successTitle: '导出成功（${selected.length} 条标注）');
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 勾选标注面板：返回选中的条目；取消返回 null。
  Future<List<ExportAppendixItem>?> _pickItemsToExport(
      List<ExportAppendixItem> items) {
    final checked = List<bool>.filled(items.length, true);
    return showModalBottomSheet<List<ExportAppendixItem>>(
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
                        Text('勾选要导出的标注',
                            style: Theme.of(ctx).textTheme.titleMedium),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setLocal(() {
                            final allChecked =
                                checked.every((c) => c);
                            for (var i = 0; i < checked.length; i++) {
                              checked[i] = !allChecked;
                            }
                          }),
                          child: Text(
                              checked.every((c) => c) ? '全不选' : '全选'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (ctx, i) {
                        final it = items[i];
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: checked[i],
                          onChanged: (v) => setLocal(() => checked[i] = v ?? false),
                          title: Text(
                            it.quote.isNotEmpty ? it.quote : it.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${it.label}${it.location.isNotEmpty ? ' · ${it.location}' : ''}',
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
                              final selected = <ExportAppendixItem>[
                                for (var i = 0; i < items.length; i++)
                                  if (checked[i]) items[i],
                              ];
                              Navigator.pop(ctx, selected);
                            },
                            child: const Text('下一步（选格式）'),
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

  /// 导出收尾：保存到系统下载目录（文件 App 可见）→ 分享/完成弹窗。
  Future<void> _finishExport(String path,
      {String successTitle = '导出成功'}) async {
    final export = ref.read(fileExportServiceProvider);
    final fileName = p.basename(path);
    String? savedTo;
    try {
      savedTo = await export.saveToDownloads(filePath: path, fileName: fileName);
    } catch (e) {
      debugPrint('[BookNotes] saveToDownloads failed: $e');
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
              ? '文件已生成：$fileName\n\n（保存到系统下载目录失败，但你仍可直接分享）'
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
        debugPrint('[BookNotes] share failed: $e');
      }
    }
  }

  /// 导出原书文件：保存到下载目录 + 分享 + 弹窗。
  Future<void> _exportOriginalFile() async {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    final export = ref.read(fileExportServiceProvider);
    final name = p.basename(book.localPath!);
    try {
      await export.saveToDownloads(filePath: book.localPath!, fileName: name);
    } catch (e) {
      _toast('保存失败: $e');
      return;
    }
    if (!mounted) return;
    final shareNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 40),
        title: const Text('✅ 原书导出成功'),
        content: Text(
          '已保存到本机下载目录（系统「文件」App 可见）：\n$name',
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
        await export.shareFile(filePath: book.localPath!, text: '《${book.title}》');
      } catch (e) {
        debugPrint('[BookNotes] share original failed: $e');
      }
    }
  }

  // ── 导出编辑后的 PDF（手写批注 + 文本框 + AI 页边文字烘焙 + 批注汇总页） ──

  Future<void> _exportEditedPdf() async {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    setState(() => _exporting = true);
    // 大书导出耗时：进度弹层实时反馈（页面合成走 JPEG，速度大幅提升）。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(strokeWidth: 3),
            SizedBox(width: 18),
            Expanded(
              child: Text('正在合并图层、烘焙笔迹…\n大文件需要一点时间，请稍候',
                  style: TextStyle(fontSize: 14, height: 1.5)),
            ),
          ],
        ),
      ),
    );
    try {
      final inkPages = await _storage.getAllPdfInkPages(book.id);
      final strokesByPage = <int, List<InkStroke>>{
        for (final e in inkPages.entries)
          if (e.value.strokes.isNotEmpty) e.key: e.value.strokes,
      };
      final textsByPage = <int, List<PdfTextItem>>{
        for (final e in inkPages.entries)
          if (e.value.texts.isNotEmpty) e.key: e.value.texts,
      };
      final imagesByPage = <int, List<PdfImageItem>>{
        for (final e in inkPages.entries)
          if (e.value.images.isNotEmpty) e.key: e.value.images,
      };
      final highlights = _annotations
          .where((a) =>
              a.anchor.kind == AnchorKind.pdf && a.anchor.rects.isNotEmpty)
          .toList();
      if (strokesByPage.isEmpty &&
          textsByPage.isEmpty &&
          imagesByPage.isEmpty &&
          highlights.isEmpty) {
        _toast('这本书没有手写批注、页边文字、插入图片或高亮，无需导出编辑版');
        setState(() => _exporting = false);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // 批注汇总页：AI 笔记 / 书内标注 / 旧批注（每条必带原文，§2.8 铁律）。
      final appendix = <ExportAppendixItem>[
        for (final n in _aiNotes)
          ExportAppendixItem(
            label: 'AI 笔记',
            quote: n.quotedText,
            content: n.content,
            location: _aiNoteLocation(n),
          ),
        for (final n in _readestNotes)
          ExportAppendixItem(
            label: switch (n.style) {
              'underline' => '下划线',
              'squiggly' => '波浪线',
              _ => '高亮',
            },
            quote: n.text,
            content: n.note,
          ),
        for (final a in _annotations)
          ExportAppendixItem(
            label: a.source == 'ink'
                ? '手写批注'
                : a.type == AnnotationType.highlight
                    ? '高亮'
                    : '笔记',
            quote: a.quotedText,
            content: a.note,
            location: a.location,
          ),
      ];
      final path = await DocExportService.instance.exportEditedPdf(
        pdfPath: book.localPath!,
        inkByPage: strokesByPage,
        textsByPage: textsByPage,
        imagesByPage: imagesByPage,
        highlights: highlights,
        appendixItems: appendix,
        outName: book.title,
        bookId: book.id,
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // 关进度弹层
      setState(() => _exporting = false);
      await _finishExport(path, successTitle: '导出成功（编辑后的 PDF）');
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关进度弹层
      setState(() => _exporting = false);
      _toast('导出失败: $e');
    }
  }

  /// AI 笔记的位置文案（页码锚点 / CFI 锚点 / 段落锚点）。
  static String _aiNoteLocation(AiNote n) {
    try {
      final map = jsonDecode(n.anchor);
      if (map is Map) {
        if (map['page'] is num) {
          return '第 ${(map['page'] as num).toInt()} 页';
        }
        if (map['para'] is num) {
          return '第 ${(map['para'] as num).toInt() + 1} 段';
        }
      }
    } catch (_) {}
    return '';
  }

  /// Word 批注报告条目：原文引用（必含）+ 用户笔记 + AI 内容（§2.8）。
  List<ExportAppendixItem> _docxReportItems() {
    return [
      for (final n in _docxNotes)
        ExportAppendixItem(
          label: n.source == 'ai'
              ? 'AI 标注'
              : switch (n.style) {
                  'underline' => '下划线',
                  'squiggly' => '波浪线',
                  'plain' => '复制摘录',
                  _ => '高亮',
                },
          quote: n.quotedText,
          content: n.note,
          location: '第 ${n.paraIndex + 1} 段',
        ),
      for (final n in _aiNotes)
        ExportAppendixItem(
          label: 'AI 笔记',
          quote: n.quotedText,
          content: n.content,
          location: _aiNoteLocation(n),
        ),
    ];
  }

  /// Word 批注报告导出（md / docx / pdf），每条必带原文引用。
  Future<void> _exportDocxReport(String format) async {
    final items = _docxReportItems();
    if (items.isEmpty) {
      _toast('这本书还没有批注，无需导出报告');
      return;
    }
    setState(() => _exporting = true);
    try {
      final svc = DocExportService.instance;
      String path;
      if (format == 'md') {
        final buf = StringBuffer();
        buf.writeln('# ${widget.bookTitle} 批注报告');
        buf.writeln('导出时间：${_fmt(DateTime.now())}');
        buf.writeln();
        for (final it in items) {
          buf.writeln('---');
          buf.writeln('**${it.label}**'
              '${it.location.isNotEmpty ? ' · ${it.location}' : ''}');
          if (it.quote.isNotEmpty) {
            buf.writeln();
            buf.writeln('> ${it.quote}');
          }
          if (it.content.isNotEmpty) {
            buf.writeln();
            buf.writeln(it.content);
          }
          buf.writeln();
        }
        final dir = await getTemporaryDirectory();
        final file =
            File(p.join(dir.path, '${widget.bookTitle}_批注报告.md'));
        await file.writeAsString(buf.toString());
        path = file.path;
      } else if (format == 'docx') {
        path = await svc.reportToDocx(
            '${widget.bookTitle} 批注报告', items);
      } else {
        path = await svc.reportToPdf(
            '${widget.bookTitle} 批注报告', items);
      }
      if (!mounted) return;
      setState(() => _exporting = false);
      await _finishExport(path, successTitle: '批注报告导出成功');
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _toast('导出失败: $e');
    }
  }

  /// 分享原 DOCX 文件（不破坏原文件，批注与原文分离存储）。
  Future<void> _shareOriginalFile() async {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    try {
      final export = ref.read(fileExportServiceProvider);
      await export.shareFile(filePath: book.localPath!);
    } catch (e) {
      _toast('分享失败: $e');
    }
  }

  /// 导出「编辑版 DOCX」：保留 Word 格式并把批注烘焙进正文，末尾附批注汇总。
  Future<void> _exportEditedDocx() async {
    final book = _book;
    if (book == null || book.localPath == null) {
      _toast('这本书还没有下载到本地');
      return;
    }
    setState(() => _exporting = true);
    try {
      final docx = await DocxLoader.openFile(book.localPath!);
      final notes = await _storage.getDocxNotes(book.id);
      final path = await DocExportService.instance.exportEditedDocx(
        docx: docx,
        title: book.title,
        notes: notes,
        outName: book.title,
      );
      if (!mounted) return;
      setState(() => _exporting = false);
      await _finishExport(path, successTitle: '编辑版 DOCX 导出成功');
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _toast('导出失败: $e');
    }
  }

  String _fmt(DateTime t) => DateFormat('yyyy-MM-dd HH:mm').format(t);

  Color _colorOf(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFFFACC15);
    return Color(int.parse(hex.replaceFirst('#', '0xFF')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_annotations.isNotEmpty ||
              _readestNotes.isNotEmpty ||
              _docxNotes.isNotEmpty ||
              _aiNotes.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share),
              tooltip: '导出笔记（勾选标注，md/txt/docx/pdf）',
              onSelected: (v) {
                if (v == 'picked') {
                  _exportSelectedNotes();
                } else if (v == 'original') {
                  _exportOriginalFile();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'picked', child: Text('勾选标注导出（md/txt/docx/pdf）')),
                PopupMenuItem(value: 'original', child: Text('导出原书文件')),
              ],
            ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppAvatar()),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // 书信息 + 打开按钮
                  Card(
                    child: ListTile(
                      leading: Icon(
                        _isPdf ? Icons.picture_as_pdf : Icons.menu_book,
                        color: colors.primary,
                      ),
                      title: Text(widget.bookTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '高亮/批注 ${_annotations.length} · 书内标注 '
                        '${_readestNotes.length}'
                        '${_docxNotes.isNotEmpty ? ' · Word 批注 ${_docxNotes.length}' : ''}'
                        '${_aiNotes.isNotEmpty ? ' · AI 笔记 ${_aiNotes.length}' : ''}'
                        '${_inkPages > 0 ? ' · 手写 $_inkPages 页' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: FilledButton(
                        // ListTile trailing 里必须覆盖全局 minimumSize=(∞,52)，
                        // 否则按钮被挤压、文字竖排（用户反馈的 bug）。
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: _openBook,
                        child: const Text('打开书'),
                      ),
                    ),
                  ),

                  // PDF：导出编辑后的 PDF（含手写批注）
                  if (_isPdf) ...[
                    const SizedBox(height: 4),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.draw_outlined),
                        title: const Text('编辑后的 PDF'),
                        subtitle: Text(
                          _hasPdfEdits
                              ? '把手写笔迹 / 页边文字 / 插入图片 / 高亮烘焙进 PDF，末尾附批注汇总页（含原文），导出后分享/保存'
                              : '暂无手写批注（在 PDF 手写模式下画的才算）',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _exporting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  // trailing 里覆盖全局 minimumSize=(∞,52)，
                                  // 否则文字被挤成竖排。
                                  minimumSize: const Size(0, 40),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14),
                                ),
                                icon: const Icon(Icons.picture_as_pdf,
                                    size: 18),
                                label: const Text('导出'),
                                onPressed: _hasPdfEdits ? _exportEditedPdf : null,
                              ),
                      ),
                    ),
                  ],

                  // Word（DOCX）：批注报告导出 + 分享原文件（不破坏原文件）。
                  if (_isDocx) ...[
                    const SizedBox(height: 4),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.description_outlined,
                                    size: 20),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text('Word 批注报告',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14)),
                                ),
                                if (_exporting)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '原 DOCX + 批注报告（每条必含原文引用 + 笔记 + AI 内容，'
                              '类 WPS 批注打印）；批注与原文分离存储，原文件不被修改。',
                              style: TextStyle(
                                  fontSize: 12, height: 1.5),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 36)),
                                  icon: const Icon(Icons.description,
                                      size: 16),
                                  label: const Text('报告 DOCX',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: () =>
                                      _exportDocxReport('docx'),
                                ),
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 36)),
                                  icon: const Icon(Icons.picture_as_pdf,
                                      size: 16),
                                  label: const Text('报告 PDF',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: () =>
                                      _exportDocxReport('pdf'),
                                ),
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 36)),
                                  icon: const Icon(Icons.notes, size: 16),
                                  label: const Text('报告 Markdown',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: () =>
                                      _exportDocxReport('md'),
                                ),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 36)),
                                  icon: const Icon(Icons.ios_share,
                                      size: 16),
                                  label: const Text('分享原文件',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: _shareOriginalFile,
                                ),
                                FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 36)),
                                  icon: const Icon(Icons.edit_document,
                                      size: 16),
                                  label: const Text('导出编辑版 DOCX',
                                      style: TextStyle(fontSize: 12)),
                                  onPressed: _exportEditedDocx,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),
                  if (_annotations.isEmpty &&
                      _readestNotes.isEmpty &&
                      _docxNotes.isEmpty &&
                      _aiNotes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 48),
                      child: Center(
                        child: Text('这本书还没有笔记。\n阅读时长按文字即可添加高亮和批注。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey)),
                      ),
                    ),

                  // ── AI 笔记（阅读器 AI 对话框确认过的内容） ────────
                  if (_aiNotes.isNotEmpty) ...[
                    _sectionHeader(colors, 'AI 笔记', _aiNotes.length),
                    for (final n in _aiNotes)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _openAiNote(n),
                          leading: const Icon(Icons.auto_awesome,
                              color: Color(0xFF7C3AED)),
                          title: Text(
                            n.content,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (n.quotedText.isNotEmpty)
                                Text(
                                  '原文：${n.quotedText}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.grey.shade600),
                                ),
                              Text(
                                'AI 生成 · ${_fmt(DateTime.fromMillisecondsSinceEpoch(n.createdAt))}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: '删除这条 AI 笔记',
                            onPressed: () => _deleteAiNote(n),
                          ),
                        ),
                      ),
                  ],

                  // ── 书内标注（readest 引擎：高亮/划线/波浪线） ──────
                  if (_readestNotes.isNotEmpty) ...[
                    _sectionHeader(colors, '书内标注', _readestNotes.length),
                    for (final n in _readestNotes)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _openReadestNote(n),
                          leading: Container(
                            width: 12,
                            height: 32,
                            decoration: BoxDecoration(
                              color: _colorOf(n.color),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          title: Text(
                            n.note.isNotEmpty ? n.note : (n.text.isEmpty ? '（标注）' : n.text),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: n.note.isNotEmpty
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant),
                          ),
                          subtitle: Text(
                            '${switch (n.style) {
                              'underline' => '下划线',
                              'squiggly' => '波浪线',
                              _ => '高亮',
                            }} · ${_fmt(n.createdAt)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                  ],

                  // ── Word 批注（DOCX：段落 + 偏移锚点） ──────────────
                  if (_docxNotes.isNotEmpty) ...[
                    _sectionHeader(colors, 'Word 批注', _docxNotes.length),
                    for (final n in _docxNotes)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _openDocxNote(n),
                          leading: Container(
                            width: 12,
                            height: 32,
                            decoration: BoxDecoration(
                              color: n.style == 'plain'
                                  ? colors.outlineVariant
                                  : _colorOf(n.color),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          title: Text(
                            n.note.isNotEmpty ? n.note : n.quotedText,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: n.note.isNotEmpty
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant),
                          ),
                          subtitle: Text(
                            '${n.source == 'ai' ? 'AI 标注 · ' : ''}'
                            '${switch (n.style) {
                              'underline' => '下划线',
                              'squiggly' => '波浪线',
                              'plain' => '复制摘录',
                              _ => '高亮',
                            }} · 第 ${n.paraIndex + 1} 段 · ${_fmt(n.createdAt)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: '删除这条 Word 批注',
                            onPressed: () => _deleteDocxNote(n),
                          ),
                        ),
                      ),
                  ],

                  // ── 旧引擎批注（含 PDF 手写合成条目） ───────────────
                  if (_annotations.isNotEmpty) ...[
                    _sectionHeader(colors, '批注', _annotations.length),
                    for (final a in _annotations)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _openAnnotation(a),
                          leading: Icon(
                            a.source == 'ink'
                                ? Icons.gesture
                                : a.type == AnnotationType.highlight
                                    ? Icons.format_quote
                                    : Icons.edit_note,
                            size: 20,
                            color: colors.primary,
                          ),
                          title: Text(
                            a.note.isNotEmpty
                                ? a.note
                                : (a.quotedText.isEmpty
                                    ? (a.source == 'ink' ? '手写批注' : '（高亮）')
                                    : a.quotedText),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: a.note.isNotEmpty
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant),
                          ),
                          subtitle: Text(
                            '${a.location} · ${_fmt(a.createdAt)}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _sectionHeader(ColorScheme colors, String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(width: 6),
          Text('$count 条',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
        ],
      ),
    );
  }
}
