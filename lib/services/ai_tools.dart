import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'ai_service.dart';
import 'docx_loader.dart';
import 'epub_loader.dart';
import 'pdf_ocr_service.dart';
import 'storage_service.dart';

/// AI 工具调用的运行时上下文：工具执行时需要的一切本地资源。
///
/// 由调用方（AI 中心 / 阅读器 AI 对话框）构造——不同入口能提供的信息
/// 不一样（阅读器能给「当前章节文本」，AI 中心只能读书架文件）。
class AiToolContext {
  final StorageService storage;

  /// 当前对话绑定的书（书内对话时非空）。
  String? fileId;
  String? fileType;
  String? fileName;

  /// 阅读器提供的「当前章节纯文本」回调（readest 引擎桥），没有则 null。
  Future<String> Function()? currentSectionText;

  /// 阅读器提供的「当前章节序号/名称」回调。
  Future<String> Function()? currentSectionInfo;

  /// 当前章节序号（阅读器 AI 对话框给；AI 中心没有）。
  int? currentSectionIndex;

  /// 附件列表（AI 中心「+」上传的书库书籍 / 笔记中心笔记）。
  /// 工具 list_attached_files / read_attached_file / search_attached_files
  /// 读取它们。
  final List<AiAttachment> attachments;

  AiToolContext({
    required this.storage,
    this.fileId,
    this.fileType,
    this.fileName,
    this.currentSectionText,
    this.currentSectionInfo,
    this.currentSectionIndex,
    this.attachments = const [],
  });

  Book? _book;
  LoadedEpub? _epub;

  /// 当前书（书架查询）。缓存一次。
  Future<Book?> book() async {
    if (_book != null) return _book;
    if (fileId == null || fileId!.isEmpty) return null;
    try {
      _book = await storage.getBook(fileId!);
    } catch (_) {
      _book = null;
    }
    return _book;
  }

  /// 当前 EPUB（懒加载一次，工具用完即弃——大书不常驻内存）。
  Future<LoadedEpub?> epub() async {
    if (_epub != null) return _epub;
    final b = await book();
    if (b == null || b.extension?.toLowerCase() != 'epub') return null;
    final path = b.localPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return null;
    try {
      _epub = await EpubLoader.openFile(path);
    } catch (e) {
      debugPrint('[AI] open epub for tools failed: $e');
      _epub = null;
    }
    return _epub;
  }

  /// 按 href 片段 / 章节序号（1-based 文本）找章节对象。
  EpubSection? sectionByRef(String ref) {
    final idx = int.tryParse(ref);
    if (idx != null) {
      final sections = _epub?.sections;
      if (sections == null) return null;
      if (idx >= 1 && idx <= sections.length) return sections[idx - 1];
      return null;
    }
    final sections = _epub?.sections;
    if (sections == null) return null;
    for (final s in sections) {
      if (s.href.toLowerCase().contains(ref.toLowerCase())) return s;
    }
    return sections
        .where((s) => s.title.contains(ref))
        .firstOrNull;
  }

  /// 按 href 片段 / 章节序号（1-based 文本）找章节。
  Future<String?> sectionTextByRef(String ref) async {
    final epub = await this.epub();
    if (epub == null) return null;
    final section = sectionByRef(ref);
    if (section == null) return null;
    return '【${section.title}】（第 ${epub.sections.indexOf(section) + 1} 节）\n'
        '${_cap(section.plain.text)}';
  }

  /// 打开当前 PDF 执行 [action]，用完立即释放（pdfium 句柄不常驻）。
  Future<T?> withPdf<T>(Future<T> Function(PdfDocument doc) action) async {
    final b = await book();
    if (b == null) return null;
    return withBookPdf(b, action);
  }

  /// 打开任意一本书的 PDF 执行 [action]，用完立即释放。
  Future<T?> withBookPdf<T>(
      Book b, Future<T> Function(PdfDocument doc) action) async {
    if (b.extension?.toLowerCase() != 'pdf') return null;
    final path = b.localPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return null;
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(path);
      return await action(doc);
    } catch (e) {
      debugPrint('[AI] pdf operation failed: $e');
      return null;
    } finally {
      try {
        doc?.dispose();
      } catch (_) {}
    }
  }

  /// 把 ref（页码 / 书签目录标题）解析成 PDF 页码（1-based）。
  Future<int?> pdfPageByRef(PdfDocument doc, String ref) async {
    final wanted = ref.trim();
    if (wanted.isEmpty) return null;
    final total = doc.pages.length;
    final idx = int.tryParse(wanted);
    if (idx != null && idx >= 1 && idx <= total) return idx;
    // 目录标题匹配（取第一个包含关键词的节点）。
    PdfOutlineNode? matched;
    void walk(List<PdfOutlineNode> nodes) {
      for (final n in nodes) {
        if (matched != null) return;
        if (n.title.toLowerCase().contains(wanted.toLowerCase())) {
          matched = n;
          return;
        }
        walk(n.children);
      }
    }

    final outline = await doc.loadOutline();
    walk(outline);
    final pageNo = matched?.dest?.pageNumber;
    if (pageNo != null && pageNo >= 1 && pageNo <= total) return pageNo;
    return null;
  }

  /// 按页码（如 "3"）或目录标题取 PDF 某一页的文本。
  /// 文字层为空（扫描版）返回 null——调用方可走 OCR 兜底。
  Future<String?> pdfTextByRef(String ref) async {
    final wanted = ref.trim();
    if (wanted.isEmpty) return null;
    return withPdf<String?>((doc) async {
      final pageNo = await pdfPageByRef(doc, wanted);
      if (pageNo == null) return null;
      final text = (await doc.pages[pageNo - 1].loadText())?.fullText ?? '';
      if (text.trim().isEmpty) return null;
      return '【第 $pageNo 页】\n${_cap(text)}';
    });
  }

  /// OCR 一页扫描版 PDF（渲染 + 离线识别 + 缓存）。失败/不支持返回 null。
  Future<String?> ocrPdfPage(Book b, int pageNo) async {
    final path = b.localPath;
    if (path == null || path.isEmpty) return null;
    return PdfOcrService.instance.ocrPage(path, b.id, pageNo);
  }

  /// 探测 PDF 是否有文字层：前 [probePages] 页任一有文本即视为文字版。
  /// 返回 (hasTextLayer, totalPages)。
  Future<(bool, int)> pdfTextLayerProbe(Book b, {int probePages = 3}) async {
    final result = await withBookPdf<(bool, int)>(b, (doc) async {
      final total = doc.pages.length;
      var hasLayer = false;
      for (var i = 0; i < math.min(probePages, total); i++) {
        final t = (await doc.pages[i].loadText())?.fullText ?? '';
        if (t.trim().isNotEmpty) {
          hasLayer = true;
          break;
        }
      }
      return (hasLayer, total);
    });
    return result ?? (true, 0);
  }

  // ── 附件 & 书库读取（AI 中心「+」上传 & 全库检索） ─────────────

  /// 附件里的书（保持附件顺序）。
  Future<List<Book>> attachedBooks() async {
    final out = <Book>[];
    for (final a in attachments) {
      if (!a.isBook) continue;
      try {
        final b = await storage.getBook(a.ref);
        if (b != null) out.add(b);
      } catch (_) {}
    }
    return out;
  }

  /// 按书名关键词找书：附件优先，其次整个书架。
  Future<Book?> findBook(String q) async {
    final wanted = q.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    final attached = await attachedBooks();
    for (final b in attached) {
      if (b.title.toLowerCase().contains(wanted)) return b;
    }
    final shelf = await storage.getBookshelf();
    for (final b in shelf) {
      if (b.title.toLowerCase().contains(wanted)) return b;
    }
    return null;
  }

  /// 读一本书的内容。ref 支持（不传 = 全文，自动截断）：
  /// - EPUB：章节序号（"3"）/ 标题关键词 / href 片段；
  /// - PDF：页码（"3"）/ 书签目录标题；
  /// - DOCX：段落号（"3"）或范围（"3-10"）；
  /// - TXT/Markdown：行号或范围。
  Future<String> readBookContent(Book b, {String? ref, int maxChars = 12000}) async {
    final ext = (b.extension ?? '').toLowerCase();
    final path = b.localPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return '《${b.title}》的文件不在本地，无法读取内容';
    }
    final refNorm = (ref ?? '').trim();
    final readAll = refNorm.isEmpty || refNorm.toLowerCase() == 'all';
    try {
      if (ext == 'epub') {
        final epub = await EpubLoader.openFile(path);
        if (epub.sections.isEmpty) return '《${b.title}》没有可读章节';
        if (!readAll) {
          final sec = _epubSectionIn(epub, refNorm);
          if (sec == null) {
            return '《${b.title}》里没找到章节「$refNorm」'
                '（可用章节序号如 "3"，或标题关键词）';
          }
          return '《${b.title}》第 ${epub.sections.indexOf(sec) + 1} 节'
              '「${sec.title}」：\n${_cap(sec.plain.text, max: maxChars)}';
        }
        final buf = StringBuffer();
        var used = 0;
        for (var i = 0; i < epub.sections.length && used < maxChars; i++) {
          final s = epub.sections[i];
          final text = _cap(s.plain.text, max: 3000);
          buf.write('【${i + 1} ${s.title}】\n$text\n\n');
          used += text.length;
        }
        return '《${b.title}》全文（共 ${epub.sections.length} 节，'
            '超出部分已截断）：\n$buf';
      }
      if (ext == 'pdf') {
        // 先探测有没有文字层：扫描版整本书 loadText 都是空的。
        final (hasLayer, total) = await pdfTextLayerProbe(b);
        if (!hasLayer) {
          if (!PdfOcrService.supported) {
            return '《${b.title}》是扫描版 PDF（没有文字层），'
                '当前设备不支持离线 OCR，无法提取文字（请在安卓手机上使用）';
          }
          if (!readAll) {
            final pageNo = await withBookPdf<int?>(
                b, (doc) => pdfPageByRef(doc, refNorm));
            if (pageNo == null) {
              return '《${b.title}》里没找到「$refNorm」对应的页'
                  '（可用页码如 "3"）';
            }
            final ocr = await ocrPdfPage(b, pageNo);
            if (ocr == null || ocr.trim().isEmpty) {
              return '《${b.title}》第 $pageNo 页 OCR 识别为空（可能太模糊）';
            }
            return '《${b.title}》第 $pageNo 页（扫描版，已 OCR 识别）：\n'
                '${_cap(ocr, max: maxChars)}';
          }
          // 整本 OCR：识别前 20 页（较慢，更多页可用 ocr_pdf_pages 工具）。
          final maxOcr = math.min(total, 20);
          final buf = StringBuffer('《${b.title}》是扫描版 PDF（共 $total 页），'
              '已 OCR 识别前 $maxOcr 页：\n');
          for (var i = 1; i <= maxOcr; i++) {
            final ocr = await ocrPdfPage(b, i);
            if (ocr == null || ocr.trim().isEmpty) continue;
            buf.write('\n【第 $i 页】\n${_cap(ocr, max: 1500)}');
          }
          buf.write('\n…（后续页可用 ocr_pdf_pages 工具按页码范围继续识别）');
          return buf.toString();
        }
        // 文字版：原有逻辑（个别混合扫描页在单页读取时 OCR 兜底）。
        return await withBookPdf<String>(b, (doc) async {
          if (!readAll) {
            final pageNo = await pdfPageByRef(doc, refNorm);
            if (pageNo == null) {
              return '《${b.title}》里没找到「$refNorm」对应的内容'
                  '（可用页码如 "3"，或书签目录标题）';
            }
            final text =
                (await doc.pages[pageNo - 1].loadText())?.fullText ?? '';
            if (text.trim().isEmpty) {
              final ocr = await PdfOcrService.instance
                  .ocrPage(b.localPath!, b.id, pageNo);
              if (ocr != null && ocr.trim().isNotEmpty) {
                return '《${b.title}》第 $pageNo 页（该页是扫描图，已 OCR 识别）：\n'
                    '${_cap(ocr, max: maxChars)}';
              }
              return '《${b.title}》第 $pageNo 页没有可提取的文字';
            }
            return '《${b.title}》第 $pageNo 页：\n${_cap(text, max: maxChars)}';
          }
          final buf = StringBuffer('《${b.title}》全文（共 $total 页，'
              '最多读前 200 页，超出部分已截断）：\n');
          var used = 0;
          final maxPages = math.min(total, 200);
          for (var i = 0; i < maxPages && used < maxChars; i++) {
            final text = (await doc.pages[i].loadText())?.fullText ?? '';
            if (text.isEmpty) continue;
            final piece = _cap(text, max: 2000);
            buf.write('\n【第 ${i + 1} 页】\n$piece');
            used += piece.length;
          }
          return buf.toString();
        }) ?? '《${b.title}》PDF 打开失败';
      }
      if (ext == 'docx') {
        final loaded = await DocxLoader.openFile(path);
        final paras = loaded.paragraphs;
        if (paras.isEmpty) return '《${b.title}》没有可读段落';
        if (!readAll) {
          final range = _parseRange(refNorm, paras.length);
          if (range == null) {
            return '《${b.title}》的段落范围「$refNorm」无效'
                '（可用 "3" 或 "3-10"）';
          }
          final buf = StringBuffer();
          for (var i = range.$1; i <= range.$2; i++) {
            buf.writeln('第 ${i + 1} 段：${paras[i].trim()}');
          }
          return '《${b.title}》第 ${range.$1 + 1}~${range.$2 + 1} 段：\n'
              '${_cap(buf.toString(), max: maxChars)}';
        }
        final buf = StringBuffer();
        var used = 0;
        for (var i = 0; i < paras.length && used < maxChars; i++) {
          final line = '第 ${i + 1} 段：${paras[i].trim()}';
          buf.writeln(line);
          used += line.length;
        }
        return '《${b.title}》全文（共 ${paras.length} 段，'
            '超出部分已截断）：\n$buf';
      }
      if (ext == 'txt' || ext == 'md' || ext == 'markdown') {
        final size = File(path).lengthSync();
        if (size > 20 * 1024 * 1024) return '《${b.title}》文件过大（>20MB），无法读取';
        final content = await File(path).readAsString();
        final lines = content.split('\n');
        if (!readAll) {
          final range = _parseRange(refNorm, lines.length);
          if (range == null) {
            return '《${b.title}》的行号范围「$refNorm」无效'
                '（可用 "3" 或 "3-10"）';
          }
          final buf = StringBuffer();
          for (var i = range.$1; i <= range.$2; i++) {
            buf.writeln('第 ${i + 1} 行：${lines[i].trim()}');
          }
          return '《${b.title}》第 ${range.$1 + 1}~${range.$2 + 1} 行：\n'
              '${_cap(buf.toString(), max: maxChars)}';
        }
        return '《${b.title}》全文：\n${_cap(content, max: maxChars)}';
      }
      return '「${ext.toUpperCase()}」格式暂不支持直接读取'
          '（支持 EPUB/PDF/DOCX/TXT/Markdown）';
    } catch (e) {
      return '读取《${b.title}》失败：$e';
    }
  }

  /// 在一本书里全文搜索关键词（EPUB 扫前 60 节 / PDF 扫前 60 页）。
  Future<String> searchBookContent(Book b, String kw,
      {int maxHits = 6}) async {
    final ext = (b.extension ?? '').toLowerCase();
    final path = b.localPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return '书文件不在本地（${b.title}），无法搜索内容';
    }
    final hits = <String>[];
    try {
      if (ext == 'epub') {
        final epub = await EpubLoader.openFile(path);
        var scanned = 0;
        for (var i = 0;
            i < epub.sections.length && scanned < 60 && hits.length < maxHits;
            i++) {
          final section = epub.sections[i];
          final text = section.plain.text;
          scanned++;
          final lower = text.toLowerCase();
          var pos = lower.indexOf(kw.toLowerCase());
          var shown = 0;
          while (pos >= 0 && shown < 2 && hits.length < maxHits) {
            final start = pos - 40 < 0 ? 0 : pos - 40;
            final end = (pos + kw.length + 60).clamp(0, text.length);
            hits.add('第 ${i + 1} 节「${section.title}」：'
                '…${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}…');
            pos = lower.indexOf(kw.toLowerCase(), pos + kw.length);
            shown++;
          }
        }
      } else if (ext == 'txt' || ext == 'md' || ext == 'markdown') {
        final size = File(path).lengthSync();
        if (size > 20 * 1024 * 1024) {
          return '《${b.title}》文件过大（>20MB），无法全文搜索';
        }
        final content = await File(path).readAsString();
        final lines = content.split('\n');
        for (var i = 0; i < lines.length && hits.length < maxHits; i++) {
          if (!lines[i].toLowerCase().contains(kw.toLowerCase())) continue;
          hits.add('第 ${i + 1} 行：${lines[i].trim()}');
        }
      } else if (ext == 'docx') {
        final loaded = await DocxLoader.openFile(path);
        final lines = loaded.paragraphs;
        for (var i = 0; i < lines.length && hits.length < maxHits; i++) {
          if (!lines[i].toLowerCase().contains(kw.toLowerCase())) continue;
          hits.add('第 ${i + 1} 段：${lines[i].trim()}');
        }
      } else if (ext == 'pdf') {
        final (hasLayer, _) = await pdfTextLayerProbe(b);
        if (!hasLayer) {
          return '《${b.title}》是扫描版 PDF（没有文字层），无法直接全文检索。'
              '可以用 ocr_pdf_pages 工具先 OCR 指定页码范围，'
              '或让我直接「读第 N 页」（会自动 OCR 该页）。';
        }
        final opened = await withBookPdf<bool>(b, (doc) async {
          final total = doc.pages.length;
          final lowerKw = kw.toLowerCase();
          var scanned = 0;
          for (var i = 0;
              i < total && scanned < 60 && hits.length < maxHits;
              i++) {
            final text = (await doc.pages[i].loadText())?.fullText ?? '';
            if (text.isEmpty) continue;
            scanned++;
            final lower = text.toLowerCase();
            var pos = lower.indexOf(lowerKw);
            var shown = 0;
            while (pos >= 0 && shown < 2 && hits.length < maxHits) {
              final start = pos - 40 < 0 ? 0 : pos - 40;
              final end = (pos + kw.length + 60).clamp(0, text.length);
              hits.add('第 ${i + 1} 页：'
                  '…${text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}…');
              pos = lower.indexOf(lowerKw, pos + kw.length);
              shown++;
            }
          }
          return true;
        });
        if (opened == null) return '《${b.title}》PDF 打开失败，无法全文搜索';
      } else {
        return '「${ext.toUpperCase()}」格式暂不支持全文搜索'
            '（支持 EPUB/TXT/Markdown/DOCX/PDF）';
      }
    } catch (e) {
      return '搜索《${b.title}》失败：$e';
    }
    if (hits.isEmpty) return '《${b.title}》里没有找到「$kw」';
    return '《${b.title}》中找到 ${hits.length} 处：\n${hits.join('\n')}';
  }

  /// 一个笔记附件 → 文本块（找不到返回空串）。
  Future<String> noteText(AiAttachment a) async {
    try {
      final id = int.tryParse(a.ref);
      switch (a.kind) {
        case 'annotation':
          if (id == null) break;
          for (final n in await storage.getAllAnnotations()) {
            if (n.id == id) {
              return '【批注 · ${n.bookTitle ?? n.bookId} · ${n.location}】'
                  '\n原文：${n.quotedText}'
                  '${n.note.isNotEmpty ? '\n笔记：${n.note}' : ''}';
            }
          }
        case 'readest_note':
          if (id == null) break;
          for (final n in await storage.getAllReadestNotes()) {
            if (n.id == id) {
              return '【书内标注 · ${n.bookId}】'
                  '\n原文：${n.text}'
                  '${n.note.isNotEmpty ? '\n笔记：${n.note}' : ''}';
            }
          }
        case 'ai_note':
          if (id == null) break;
          for (final n in await storage.getAllAiNotes()) {
            if (n.id == id) {
              return '【AI 笔记 · ${n.bookId}】'
                  '\n原文：${n.quotedText}\nAI 内容：${n.content}';
            }
          }
        case 'docx_note':
          if (id == null) break;
          for (final n in await storage.getAllDocxNotes()) {
            if (n.id == id) {
              return '【Word 批注 · ${n.bookId} · 第 ${n.paraIndex + 1} 段】'
                  '\n原文：${n.quotedText}'
                  '${n.note.isNotEmpty ? '\n笔记：${n.note}' : ''}';
            }
          }
      }
    } catch (e) {
      debugPrint('[AI] resolve note attachment failed: $e');
    }
    return '';
  }

  /// 全部笔记附件的文本（编号列出，供模型阅读）。
  Future<String> attachmentNotesText() async {
    final buf = StringBuffer();
    var idx = 0;
    for (final a in attachments) {
      if (a.isBook) continue;
      final text = await noteText(a);
      if (text.isEmpty) continue;
      idx++;
      buf.write('【笔记附件 $idx】$text\n\n');
    }
    return buf.toString();
  }

  /// "3" / "3-10" → (0-based 起, 0-based 止)；非法返回 null。
  static (int, int)? _parseRange(String ref, int total) {
    if (total <= 0) return null;
    final m = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(ref.trim());
    if (m != null) {
      final a = int.tryParse(m.group(1)!);
      final b = int.tryParse(m.group(2)!);
      if (a == null || b == null || a < 1) return null;
      return ((a - 1).clamp(0, total - 1), (b - 1).clamp(0, total - 1));
    }
    final n = int.tryParse(ref.trim());
    if (n == null || n < 1 || n > total) return null;
    return (n - 1, n - 1);
  }

  static EpubSection? _epubSectionIn(LoadedEpub epub, String ref) {
    final idx = int.tryParse(ref);
    if (idx != null) {
      if (idx >= 1 && idx <= epub.sections.length) return epub.sections[idx - 1];
      return null;
    }
    for (final s in epub.sections) {
      if (s.href.toLowerCase().contains(ref.toLowerCase())) return s;
    }
    return epub.sections.where((s) => s.title.contains(ref)).firstOrNull;
  }

  static String _cap(String s, {int max = 8000}) =>
      s.length <= max ? s : '${s.substring(0, max)}\n…（已截断）';
}

/// 工具危险性分级（任务式 Agent 的两级放行策略用）：
/// - read：只读，自动执行；
/// - write：改用户数据（批注/标签/Word 编辑等），需用户确认（或用户
///   在设置里开了「后台写操作自动放行」）；
/// - dangerous：删除/覆盖类，永远需要确认。
enum AiToolDanger { read, write, dangerous }

/// 一个 AI 工具（OpenAI function calling 定义 + 本地执行）。
class AiToolDefinition {
  final String name;
  final String label; // UI 显示名
  final String description; // 给模型看的中文描述（何时用/参数含义）
  final Map<String, dynamic> parameters; // JSON Schema
  final String example; // 手动触发时填进输入框的示例问题

  /// 危险性分级（默认 read）。
  final AiToolDanger danger;

  final Future<String> Function(Map<String, dynamic> args, AiToolContext ctx)
      execute;

  const AiToolDefinition({
    required this.name,
    required this.label,
    required this.description,
    required this.parameters,
    required this.example,
    required this.execute,
    this.danger = AiToolDanger.read,
  });

  /// OpenAI 协议需要的 tools 条目。
  Map<String, dynamic> toToolJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// 14 个 AI 工具（方案 Phase 6 清单，与 Anx Reader 同构）。
///
/// 说明：
/// - 「整理书架」= 把书架数据喂给模型、由模型产出**重组建议文本**
///   （诚实声明 §7.3：不是一键自动改书架）；
/// - 「书内搜索/按章节取内容/当前书籍目录」支持 EPUB/TXT/Markdown/DOCX
///   与 PDF（PDF 走 pdfrx 逐页 loadText 提取 + 书签目录 outline）；
/// - 「当前章节内容」优先用阅读器注入的引擎桥（sectionText），
///   拿不到时读 EPUB/PDF 文件兜底。
class AiTools {
  AiTools._();

  static const _noArgs = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  /// 全部工具定义（开关由 AiToolsStore 控制，这里永远返回全集）。
  static List<AiToolDefinition> all() => [
        // 1 ── 计算器
        AiToolDefinition(
          name: 'calculator',
          label: '计算器',
          description: '计算数学表达式。用户问算术题/换算时调用。'
              '支持 + - * / ^ % 括号与常见函数（sin/cos/sqrt/pow 等）。',
          parameters: {
            'type': 'object',
            'properties': {
              'expression': {
                'type': 'string',
                'description': '数学表达式，如 "3.14*2^5" 或 "sqrt(144)+12"',
              },
            },
            'required': ['expression'],
          },
          example: '帮我算 3.14 × 2 的 5 次方',
          execute: (args, ctx) async {
            final expr = (args['expression'] ?? '').toString().trim();
            if (expr.isEmpty) return '表达式为空';
            try {
              final parsed = ShuntingYardParser().parse(expr);
              final value = parsed.evaluate(EvaluationType.REAL, ContextModel());
              return '计算结果：$expr = $value';
            } catch (e) {
              return '计算失败：$e（请把表达式改写成纯数学形式）';
            }
          },
        ),

        // 2 ── 当前时间
        AiToolDefinition(
          name: 'current_time',
          label: '当前时间',
          description: '获取当前的日期和时间。用户问「现在几点/今天几号/星期几」时调用。',
          parameters: _noArgs,
          example: '现在几点了？',
          execute: (args, ctx) async {
            final now = DateTime.now();
            const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
            return '现在是 ${now.year} 年 ${now.month} 月 ${now.day} 日 '
                '星期${weekdays[now.weekday - 1]} '
                '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}:'
                '${now.second.toString().padLeft(2, '0')}';
          },
        ),

        // 3 ── 思维导图
        AiToolDefinition(
          name: 'mind_map',
          label: '思维导图',
          description: '把分层内容整理成思维导图。当用户要求「做思维导图/脑图/'
              '梳理结构」时，先把内容整理成层级树再调用本工具。',
          parameters: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '思维导图主题'},
              'nodes': {
                'type': 'array',
                'description': '根节点列表，每个节点 {text, children:[...]}',
                'items': {
                  'type': 'object',
                  'properties': {
                    'text': {'type': 'string'},
                    'children': {'type': 'array', 'items': {'type': 'object'}},
                  },
                  'required': ['text'],
                },
              },
            },
            'required': ['title', 'nodes'],
          },
          example: '把这本书的目录整理成思维导图',
          execute: (args, ctx) async {
            final title = (args['title'] ?? '').toString();
            final nodes = (args['nodes'] as List?) ?? [];
            if (nodes.isEmpty) return '思维导图节点为空';
            // 归一化成 {text, children} 结构并做深度限制。
            Map<String, dynamic> norm(dynamic n, int depth) {
              final m = n is Map ? n : <String, dynamic>{};
              final text = (m['text'] ?? '').toString();
              final kids = <Map<String, dynamic>>[];
              if (depth < 6) {
                for (final c in ((m['children'] as List?) ?? [])) {
                  kids.add(norm(c, depth + 1));
                }
              }
              return {'text': text, 'children': kids};
            }

            final root = <Map<String, dynamic>>[
              for (final n in nodes) norm(n, 0),
            ];
            return jsonEncode({
              'mindmap': true,
              'title': title,
              'nodes': root,
            });
          },
        ),

        // 4 ── 书内搜索
        AiToolDefinition(
          name: 'book_search',
          label: '书内搜索',
          description: '在当前打开的这本书里搜索关键词，返回包含该词的段落和'
              '章节位置。用户问「书里哪里讲了 X」时调用。'
              'EPUB/TXT/Markdown/DOCX/PDF 均支持。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '要搜索的词'},
            },
            'required': ['keyword'],
          },
          example: '在这本书里搜索「神经网络」',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            if (kw.isEmpty) return '关键词为空';
            final b = await ctx.book();
            if (b == null) {
              return '没有当前书籍。若用户想搜索书库里的书，用 search_bookshelf '
                  '工具（全文检索书架）；若用户上传了附件，用 '
                  'search_attached_files 搜索附件。';
            }
            return ctx.searchBookContent(b, kw, maxHits: 8);
          },
        ),

        // 5 ── 查看书架
        AiToolDefinition(
          name: 'bookshelf_list',
          label: '查看书架',
          description: '列出用户书架上的全部书籍（书名/作者/格式/阅读进度/'
              '文件夹/标签）。用户问「书架上有哪些书」时调用。',
          parameters: _noArgs,
          example: '我书架上有哪些书？',
          execute: (args, ctx) async {
            final books = await ctx.storage.getBookshelf();
            final tagsByBook = await ctx.storage.getTagsByBook();
            if (books.isEmpty) return '书架是空的（没有导入任何书）';
            final lines = <String>[];
            for (final b in books) {
              final tags = tagsByBook[b.id] ?? [];
              final tagStr =
                  tags.isEmpty ? '' : '；标签：${tags.map((t) => t.name).join('、')}';
              final authorStr = b.author.isEmpty ? '' : '· ${b.author}';
              final folderStr =
                  b.folder.isEmpty ? '' : ' · 文件夹：${b.folder}';
              lines.add('- 《${b.title}》 $authorStr'
                  ' · ${(b.extension ?? '未知').toUpperCase()}'
                  ' · 进度 ${b.progressPercent ?? 0}%$folderStr$tagStr');
            }
            return '书架共 ${books.length} 本：\n${lines.join('\n')}';
          },
        ),

        // 6 ── 整理书架
        AiToolDefinition(
          name: 'organize_bookshelf',
          label: '整理书架',
          description: '用户要求「整理书架/给书架分类/推荐书单」时调用：'
              '拿到书架数据后，**直接给出整理方案文本**（按题材/用途分组建议，'
              '不要声称已自动改好书架——本工具只提供数据，实际整理由用户手动操作）。',
          parameters: _noArgs,
          example: '帮我整理一下书架',
          execute: (args, ctx) async {
            final books = await ctx.storage.getBookshelf();
            if (books.isEmpty) return '书架是空的，没有可整理的书籍';
            final folders = await ctx.storage.getFolders();
            final lines = <String>[];
            for (final b in books) {
              final authorStr = b.author.isEmpty ? '' : '· ${b.author}';
              final folderName = b.folder.isEmpty ? '未分类' : b.folder;
              lines.add('- 《${b.title}》 $authorStr'
                  ' · ${(b.extension ?? '未知').toUpperCase()}'
                  ' · 文件夹：$folderName');
            }
            return '书架数据（${books.length} 本）：\n${lines.join('\n')}\n'
                '现有文件夹：${folders.isEmpty ? '（无）' : folders.join('、')}\n\n'
                '请基于以上数据给用户一份书架的整理/分组建议（纯文本，'
                '说明哪些书适合归到哪类，以及可新建哪些文件夹）。';
          },
        ),

        // 7 ── 搜索笔记
        AiToolDefinition(
          name: 'search_notes',
          label: '搜索笔记',
          description: '在用户的全部读书笔记（高亮/批注/AI 笔记/Word 批注）里'
              '搜索关键词，返回匹配的原文引用和笔记内容。用户问'
              '「我记过什么关于 X 的笔记」时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '搜索词'},
            },
            'required': ['keyword'],
          },
          example: '我记过关于「熵」的笔记吗？',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            if (kw.isEmpty) return '关键词为空';
            final results = <String>[];
            final anns = await ctx.storage.searchAnnotations(kw);
            for (final a in anns.take(8)) {
              final quotePart =
                  a.quotedText.isEmpty ? '' : '\n原文：${a.quotedText}';
              final notePart = a.note.isEmpty ? '' : '\n笔记：${a.note}';
              results.add('【${a.bookTitle ?? a.bookId} · ${a.location}】'
                  '$quotePart$notePart');
            }
            final docx = await ctx.storage.getAllDocxNotes();
            for (final n in docx) {
              if (!n.quotedText.contains(kw) && !n.note.contains(kw)) continue;
              final notePart = n.note.isEmpty ? '' : '\n笔记：${n.note}';
              results.add('【Word 批注 · 第 ${n.paraIndex + 1} 段】'
                  '\n原文：${n.quotedText}$notePart');
              if (results.length >= 10) break;
            }
            if (results.length < 10) {
              final aiNotes = await ctx.storage.getAllAiNotes();
              for (final n in aiNotes) {
                if (!n.quotedText.contains(kw) && !n.content.contains(kw)) {
                  continue;
                }
                results.add('【AI 笔记 · ${n.bookId}】'
                    '\n原文：${n.quotedText}'
                    '\nAI 内容：${n.content}');
                if (results.length >= 10) break;
              }
            }
            if (results.isEmpty) return '笔记里没有找到「$kw」';
            return '找到 ${results.length} 条与「$kw」相关的笔记：\n'
                '${results.join('\n\n')}';
          },
        ),

        // 8 ── 阅读历史
        AiToolDefinition(
          name: 'reading_history',
          label: '阅读历史',
          description: '查询用户最近每天的阅读时长与登录次数。'
              '用户问「我最近读了多少/今天读了几分钟」时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'days': {
                'type': 'integer',
                'description': '往回查几天（默认 14，最多 90）',
              },
            },
          },
          example: '我最近一周读了多少分钟？',
          execute: (args, ctx) async {
            final days = ((args['days'] as num?)?.toInt() ?? 14).clamp(1, 90);
            final now = DateTime.now();
            final start = now.subtract(Duration(days: days - 1));
            final usage = await ctx.storage.getUsageDays(start, now);
            final total = usage.fold<int>(
                0, (sum, d) => sum + d.seconds);
            final logins =
                usage.fold<int>(0, (sum, d) => sum + d.logins);
            if (usage.isEmpty) {
              return '最近 $days 天没有阅读记录';
            }
            final lines = usage.map((d) {
              // date 是 'yyyy-MM-dd' 字符串键，解析回日期展示。
              final parts = d.date.split('-');
              final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
              final day = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
              final minutes = (d.seconds / 60).round();
              final loginStr = d.logins > 0 ? '，打开 $d.logins 次' : '';
              return '- $m 月 $day 日：$minutes 分钟$loginStr';
            }).join('\n');
            return '最近 $days 天共阅读 ${(total / 60).round()} 分钟、'
                '打开 $logins 次：\n$lines';
          },
        ),

        // 9 ── 当前书籍目录
        AiToolDefinition(
          name: 'current_book_toc',
          label: '当前书籍目录',
          description: '获取当前打开书籍的目录（章节列表）。'
              '用户问「这本书有哪些章节/目录是什么」时调用。',
          parameters: _noArgs,
          example: '这本书的目录是什么？',
          execute: (args, ctx) async {
            final b = await ctx.book();
            if (b == null) {
              return '没有当前书籍（请在书内 AI 对话里使用）';
            }
            final ext = b.extension?.toLowerCase() ?? '';
            if (ext == 'epub') {
              final epub = await ctx.epub();
              if (epub == null) return 'EPUB 解析失败';
              final lines = <String>[];
              for (var i = 0; i < epub.sections.length; i++) {
                lines.add('${i + 1}. ${epub.sections[i].title}');
                if (lines.length >= 100) {
                  lines.add('…（共 ${epub.sections.length} 节，截取前 100 条）');
                  break;
                }
              }
              return '《${b.title}》目录（共 ${epub.sections.length} 节）：\n'
                  '${lines.join('\n')}';
            }
            if (ext == 'pdf') {
              // PDF：优先书签目录（outline），没有就提示按页码读。
              final lines = await ctx.withPdf((doc) async {
                final outline = await doc.loadOutline();
                if (outline.isEmpty) return null;
                final out = <String>[];
                void walk(List<PdfOutlineNode> nodes, int depth) {
                  for (final n in nodes) {
                    if (out.length >= 100) return;
                    final page = n.dest?.pageNumber ?? 0;
                    out.add('${'  ' * depth}${n.title}'
                        '${page > 0 ? '（第 $page 页）' : ''}');
                    walk(n.children, depth + 1);
                  }
                }

                walk(outline, 0);
                return out;
              });
              final pages = b.pages;
              final pageStr = pages != null ? '，共 $pages 页' : '';
              if (lines != null && lines.isNotEmpty) {
                return '《${b.title}》目录（共 ${lines.length} 条）$pageStr：\n'
                    '${lines.join('\n')}';
              }
              return '《${b.title}》没有书签目录$pageStr。'
                  '可以按页码读取内容（如「读一下第 3 页」），'
                  '或用「书内搜索」找关键词。';
            }
            return '《${b.title}》是 ${ext.toUpperCase()} 格式，'
                '没有章节目录（纯文本/Word 文档按段落阅读）。';
          },
        ),

        // 10 ── 当前章节内容
        AiToolDefinition(
          name: 'current_chapter_content',
          label: '当前章节内容',
          description: '获取当前正在阅读的章节正文。用户问「这段在讲什么/'
              '结合上下文解释」时调用，先拿正文再回答。',
          parameters: _noArgs,
          example: '结合上下文解释一下我读到的地方',
          execute: (args, ctx) async {
            final cb = ctx.currentSectionText;
            if (cb != null) {
              final text = await cb();
              if (text.trim().isNotEmpty) {
                return '当前章节内容：\n${AiToolContext._cap(text)}';
              }
            }
            final epub = await ctx.epub();
            if (epub != null) {
              final idx = (ctx.currentSectionIndex ?? 0)
                  .clamp(0, epub.sections.length - 1);
              final section = epub.sections[idx];
              return '当前章节「${section.title}」（第 ${idx + 1} 节）：\n'
                  '${AiToolContext._cap(section.plain.text)}';
            }
            final b = await ctx.book();
            if (b != null && (b.extension?.toLowerCase() ?? '') == 'pdf') {
              // PDF：按当前页码取对应页文本（书内 AI 对话框传入当前页）。
              final idx = (ctx.currentSectionIndex ?? 0).clamp(0, 9999);
              final text = await ctx.pdfTextByRef('${idx + 1}');
              if (text != null) return text;
              // 扫描版：当前页没有文字层 → 自动 OCR。
              final ocr = await ctx.ocrPdfPage(b, idx + 1);
              if (ocr != null && ocr.trim().isNotEmpty) {
                return '当前页（第 ${idx + 1} 页）是扫描图，已 OCR 识别：\n'
                    '${AiToolContext._cap(ocr)}';
              }
              return '当前是《${b.title}》（PDF），读不到当前页文本'
                  '（${PdfOcrService.supported ? '该页可能是空白或扫描质量太差' : '当前设备不支持 OCR'}）；'
                  '可以让我用「按章节取内容」按页码读取指定页。';
            }
            if (b != null) {
              return '当前是《${b.title}》（${(b.extension ?? '').toUpperCase()}），'
                  '未在阅读器里打开，无法取章节正文。请在阅读器里选中文字后'
                  '用 AI 提问，或在 AI 中心里用「当前书籍目录」定位章节。';
            }
            return '没有当前书籍，无法取章节内容';
          },
        ),

        // 11 ── 按 Href 获取章节
        AiToolDefinition(
          name: 'get_chapter_by_href',
          label: '按章节取内容',
          description: '按章节序号（如 "3"）或标题/href（如 "part0005"）'
              '获取该书某一章的正文。用户要求「读一下第 N 章/讲一讲 X 章」时调用。'
              'PDF 支持按页码（如 "12"）或书签目录标题取对应页文本。',
          parameters: {
            'type': 'object',
            'properties': {
              'ref': {
                'type': 'string',
                'description': '章节序号或标题关键词/href 片段',
              },
            },
            'required': ['ref'],
          },
          example: '帮我看看第 3 章讲了什么',
          execute: (args, ctx) async {
            final ref = (args['ref'] ?? '').toString().trim();
            if (ref.isEmpty) return '没有指定章节';
            final b = await ctx.book();
            // PDF：按页码或书签目录标题取对应页文本。
            if (b != null && (b.extension?.toLowerCase() ?? '') == 'pdf') {
              final text = await ctx.pdfTextByRef(ref);
              if (text == null) {
                return '没找到「$ref」对应的 PDF 内容'
                    '（可用页码如 "3"，或书签目录里的标题；'
                    '可先用「当前书籍目录」查看）';
              }
              return text;
            }
            final text = await ctx.sectionTextByRef(ref);
            if (text == null) {
              return '没找到章节「$ref」'
                  '${b != null ? '（《${b.title}》，可先用「当前书籍目录」查编号）' : ''}';
            }
            return text;
          },
        ),

        // 12 ── 列出标签
        AiToolDefinition(
          name: 'list_tags',
          label: '列出标签',
          description: '列出书架的全部标签。用户问「有哪些标签」时调用。',
          parameters: _noArgs,
          example: '我的书架有哪些标签？',
          execute: (args, ctx) async {
            final tags = await ctx.storage.listTags();
            if (tags.isEmpty) return '还没有创建过标签（可在书详情页给书打标签）';
            return '全部标签（${tags.length} 个）：'
                '${tags.map((t) => t.name).join('、')}';
          },
        ),

        // 13 ── 列出书籍标签
        AiToolDefinition(
          name: 'list_book_tags',
          label: '列出书籍标签',
          description: '查某一本书打了哪些标签。用户问「这本书有什么标签」时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'book_title': {
                'type': 'string',
                'description': '书名（可选：书内对话默认当前这本书）',
              },
            },
          },
          example: '这本书打了什么标签？',
          execute: (args, ctx) async {
            var bookId = ctx.fileId;
            String? title;
            if (bookId == null || bookId.isEmpty) {
              title = (args['book_title'] ?? '').toString().trim();
              if (title.isNotEmpty) {
                final books = await ctx.storage.getBookshelf();
                for (final b in books) {
                  if (b.title.contains(title)) {
                    bookId = b.id;
                    break;
                  }
                }
              }
            }
            if (bookId == null || bookId.isEmpty) {
              return '没有指定书（书内对话自动查当前书；纯 AI 对话请带上书名参数）';
            }
            final tags = await ctx.storage.getBookTags(bookId);
            final b = await ctx.storage.getBook(bookId);
            final name = b?.title ?? bookId;
            if (tags.isEmpty) return '《$name》还没有标签';
            return '《$name》的标签：${tags.map((t) => t.name).join('、')}';
          },
        ),

        // 14 ── 应用书籍标签（唯一写工具：改用户数据，需要放行确认）
        AiToolDefinition(
          name: 'apply_book_tags',
          label: '应用书籍标签',
          danger: AiToolDanger.write,
          description: '给一本书设置标签（覆盖式：传完整标签列表）。'
              '用户说「把这本书标记为 X / 打上 X 标签」时调用。'
              '不存在的标签会自动创建。',
          parameters: {
            'type': 'object',
            'properties': {
              'book_title': {
                'type': 'string',
                'description': '书名（可选：书内对话默认当前这本书）',
              },
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '要应用的标签名列表',
              },
            },
            'required': ['tags'],
          },
          example: '把这本书标记为「计算机」「教材」',
          execute: (args, ctx) async {
            var bookId = ctx.fileId;
            final title = (args['book_title'] ?? '').toString().trim();
            if (bookId == null || bookId.isEmpty) {
              if (title.isNotEmpty) {
                final books = await ctx.storage.getBookshelf();
                for (final b in books) {
                  if (b.title.contains(title)) {
                    bookId = b.id;
                    break;
                  }
                }
              }
            }
            if (bookId == null || bookId.isEmpty) {
              return '没有找到要打标签的书（书内对话自动打当前书；'
                  '纯 AI 对话请带上书名参数）';
            }
            final names = ((args['tags'] as List?) ?? [])
                .map((t) => t.toString().trim())
                .where((t) => t.isNotEmpty)
                .toSet()
                .toList();
            if (names.isEmpty) return '标签列表为空';
            final ids = <int>[];
            for (final name in names.take(8)) {
              ids.add(await ctx.storage.insertTag(name));
            }
            await ctx.storage.setBookTags(bookId, ids);
            final b = await ctx.storage.getBook(bookId);
            return '已给《${b?.title ?? bookId}》应用标签：${names.join('、')}'
                '（共 ${names.length} 个）';
          },
        ),

        // 15 ── 列出附件
        AiToolDefinition(
          name: 'list_attached_files',
          label: '列出附件',
          description: '列出用户上传到本次对话的附件（书库书籍 + 笔记中心笔记，'
              '编号、名称与类型）。用户问「我上传了哪些文件/附件里有什么」时调用。',
          parameters: _noArgs,
          example: '看看我上传了哪些文件',
          execute: (args, ctx) async {
            if (ctx.attachments.isEmpty) {
              return '本次对话没有上传附件。用户可点输入框左侧的「+」按钮，'
                  '从书库或笔记中心上传资料。';
            }
            final buf = StringBuffer('本次对话共 ${ctx.attachments.length} 个附件：\n');
            for (var i = 0; i < ctx.attachments.length; i++) {
              final a = ctx.attachments[i];
              buf.writeln('${i + 1}. [${a.isBook ? '书' : '笔记'}] ${a.label}'
                  '${a.detail.isNotEmpty ? ' · ${a.detail}' : ''}');
            }
            return buf.toString();
          },
        ),

        // 16 ── 读取附件
        AiToolDefinition(
          name: 'read_attached_file',
          label: '读取附件',
          description: '读取某个附件的内容。附件可以是书（支持按章节序号/标题、'
              '页码、段落号或段落范围读一部分，不传 ref 读全文）或笔记（直接返回'
              '全文）。用户要求「读一下我上传的 X / 结合我上传的资料回答」时调用；'
              '先不确定附件名时可先调 list_attached_files。',
          parameters: {
            'type': 'object',
            'properties': {
              'file': {
                'type': 'string',
                'description': '附件名/书名关键词（如「三体」「关于熵的笔记」）',
              },
              'ref': {
                'type': 'string',
                'description': '可选：书的章节序号/标题、页码、段落号或'
                    '范围（如 "3" 或 "3-10"）',
              },
              'limit': {
                'type': 'integer',
                'description': '可选：最大返回字符数（默认 12000）',
              },
            },
            'required': ['file'],
          },
          example: '读一下我上传的《三体》第 3 章',
          execute: (args, ctx) async {
            final q = (args['file'] ?? '').toString().trim();
            if (q.isEmpty) return '没有指定要读的附件';
            final ref = (args['ref'] ?? '').toString().trim();
            final limit =
                ((args['limit'] as num?)?.toInt() ?? 12000).clamp(500, 40000);
            // 书附件优先（按书名匹配），其次笔记附件（按 label 匹配）。
            final books = await ctx.attachedBooks();
            for (final b in books) {
              if (b.title.toLowerCase().contains(q.toLowerCase())) {
                return ctx.readBookContent(b,
                    ref: ref.isEmpty ? null : ref, maxChars: limit);
              }
            }
            for (final a in ctx.attachments) {
              if (a.isBook) continue;
              if (a.label.toLowerCase().contains(q.toLowerCase())) {
                final text = await ctx.noteText(a);
                if (text.isNotEmpty) return text;
              }
            }
            return '附件里没有找到「$q」。可先用 list_attached_files 看附件列表。';
          },
        ),

        // 17 ── 搜索附件
        AiToolDefinition(
          name: 'search_attached_files',
          label: '搜索附件',
          description: '在用户上传的全部附件（书库书籍全文 + 笔记中心笔记）里'
              '全文搜索关键词。用户问「我上传的资料里哪里讲了 X / 帮我从上传的'
              '文件里找 X」时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '搜索词'},
            },
            'required': ['keyword'],
          },
          example: '在我上传的资料里搜索「三体」',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            if (kw.isEmpty) return '关键词为空';
            if (ctx.attachments.isEmpty) {
              return '本次对话没有上传附件。用户可点输入框左侧的「+」按钮上传'
                  '书库书籍或笔记中心笔记；若想直接搜整个书架，用 '
                  'search_bookshelf 工具。';
            }
            final buf = StringBuffer();
            final books = await ctx.attachedBooks();
            for (final b in books.take(8)) {
              final result = await ctx.searchBookContent(b, kw, maxHits: 3);
              buf.writeln(result);
            }
            // 笔记附件里过滤关键词。
            for (final a in ctx.attachments) {
              if (a.isBook) continue;
              final text = await ctx.noteText(a);
              if (text.isEmpty) continue;
              if (text.toLowerCase().contains(kw.toLowerCase())) {
                buf.writeln(text);
              }
            }
            final out = buf.toString().trim();
            if (out.isEmpty) return '附件里没有找到「$kw」';
            return '在附件中搜索「$kw」的结果：\n${AiToolContext._cap(out, max: 10000)}';
          },
        ),

        // 18 ── 读取书库任意书籍
        AiToolDefinition(
          name: 'read_bookshelf_book',
          label: '读取书库书籍',
          description: '读取用户书架上任意一本书的内容（无需先上传附件，按书名'
              '定位）。EPUB 支持章节序号/标题（ref），PDF 支持页码/书签标题'
              '（ref），DOCX/TXT/Markdown 支持段落号/行号或范围（如 "3" 或 '
              '"3-10"）；不传 ref 读全文（自动截断）。用户要求读某本书、'
              '某章、某页时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'book_title': {
                'type': 'string',
                'description': '书名关键词（在书架上按标题匹配）',
              },
              'ref': {
                'type': 'string',
                'description': '可选：章节序号/标题、页码、段落号或范围',
              },
              'limit': {
                'type': 'integer',
                'description': '可选：最大返回字符数（默认 12000）',
              },
            },
            'required': ['book_title'],
          },
          example: '帮我读一下书架上的《三体》第三章',
          execute: (args, ctx) async {
            final q = (args['book_title'] ?? '').toString().trim();
            if (q.isEmpty) return '没有指定书名';
            final b = await ctx.findBook(q);
            if (b == null) {
              return '书架上没有找到「$q」。可先用 bookshelf_list 看书架书单。';
            }
            final ref = (args['ref'] ?? '').toString().trim();
            final limit =
                ((args['limit'] as num?)?.toInt() ?? 12000).clamp(500, 40000);
            return ctx.readBookContent(b,
                ref: ref.isEmpty ? null : ref, maxChars: limit);
          },
        ),

        // 19 ── 检索书库
        AiToolDefinition(
          name: 'search_bookshelf',
          label: '检索书库',
          description: '在用户书架的全部书籍里全文搜索关键词（EPUB/PDF/DOCX/'
              'TXT/Markdown）。用户问「我的书库/哪本书里讲了 X」时调用。'
              '为避免超时最多扫 8 本书、每本返回前几处命中，找不到时提示。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '搜索词'},
            },
            'required': ['keyword'],
          },
          example: '我的书库里哪些书讲了「人工智能」？',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            if (kw.isEmpty) return '关键词为空';
            final shelf = await ctx.storage.getBookshelf();
            final local = shelf.where((b) =>
                b.localPath != null && b.localPath!.isNotEmpty).toList();
            if (local.isEmpty) return '书架上没有已下载到本地的书（远程书目无法全文检索）';
            final buf = StringBuffer();
            var scanned = 0;
            for (final b in local) {
              if (scanned >= 8) {
                buf.writeln('…（书太多，只扫了前 8 本；可指定书名后用 '
                    'read_bookshelf_book 单独读）');
                break;
              }
              scanned++;
              final result = await ctx.searchBookContent(b, kw, maxHits: 2);
              buf.writeln(result);
            }
            final out = buf.toString().trim();
            if (out.isEmpty) return '书库里没有找到「$kw」';
            return '书库全文检索「$kw」（共扫 $scanned 本）：\n'
                '${AiToolContext._cap(out, max: 10000)}';
          },
        ),

        // 20 ── OCR 扫描页
        AiToolDefinition(
          name: 'ocr_pdf_pages',
          label: 'OCR 扫描页',
          description: '对扫描版 PDF（图片版、没有文字层，loadText 为空）'
              '做本地 OCR 文字识别。书是图片版 PDF、读不出文字时调用。'
              'pages 支持单页（如 "3"）或范围（如 "3-8"），一次最多 10 页；'
              '书内对话默认当前书，纯 AI 对话用 book_title 指定书架上的书。',
          parameters: {
            'type': 'object',
            'properties': {
              'book_title': {
                'type': 'string',
                'description': '书名关键词（书内对话可省略，默认当前书）',
              },
              'pages': {
                'type': 'string',
                'description': '页码或范围，如 "3" 或 "3-8"',
              },
            },
            'required': ['pages'],
          },
          example: '把这本书第 3 到 8 页 OCR 识别出来',
          execute: (args, ctx) async {
            if (!PdfOcrService.supported) {
              return '当前设备不支持离线 OCR（请在安卓手机上使用）';
            }
            Book? b;
            if (ctx.fileId != null && ctx.fileId!.isNotEmpty) {
              b = await ctx.book();
            } else {
              b =
                  await ctx.findBook((args['book_title'] ?? '').toString().trim());
            }
            if (b == null) {
              return '没有找到要 OCR 的书（纯 AI 对话请带上 book_title 参数）';
            }
            if ((b.extension?.toLowerCase() ?? '') != 'pdf') {
              return '《${b.title}》不是 PDF，只有扫描版 PDF 需要 OCR';
            }
            final pagesRaw = (args['pages'] ?? '').toString().trim();
            final range = AiToolContext._parseRange(pagesRaw, 99999);
            if (range == null) {
              return '页码「$pagesRaw」无效（用 "3" 或 "3-8"）';
            }
            final buf = StringBuffer();
            var count = 0;
            for (var p = range.$1 + 1;
                p <= range.$2 + 1 && count < 10;
                p++) {
              count++;
              final ocr = await ctx.ocrPdfPage(b, p);
              if (ocr == null || ocr.trim().isEmpty) {
                buf.writeln('【第 $p 页】OCR 识别为空');
                continue;
              }
              buf.writeln('【第 $p 页】$ocr');
            }
            if (count == 0) return '没有要识别的页';
            return '《${b.title}》OCR 结果（第 ${range.$1 + 1}~${range.$2 + 1} 页）：\n'
                '${AiToolContext._cap(buf.toString(), max: 10000)}';
          },
        ),

        // 21 ── 保存 AI 笔记（写）
        AiToolDefinition(
          name: 'save_note',
          label: '保存笔记',
          danger: AiToolDanger.write,
          description: '把 AI 生成的内容保存成一条 AI 笔记（挂在某本书下，笔记中心可见）。'
              '用户说「把总结/这段内容存成笔记/保存下来」时调用。'
              '书内对话默认存到当前书；纯 AI 对话用 book_title 指定书架上的书。',
          parameters: {
            'type': 'object',
            'properties': {
              'book_title': {
                'type': 'string',
                'description': '书名关键词（书内对话可省略，默认当前书）',
              },
              'content': {'type': 'string', 'description': '要保存的笔记正文'},
              'quote': {
                'type': 'string',
                'description': '可选：原文引用（默认「AI 生成」）',
              },
            },
            'required': ['content'],
          },
          example: '把上面的总结保存成笔记',
          execute: (args, ctx) async {
            final content = (args['content'] ?? '').toString().trim();
            if (content.isEmpty) return '笔记内容为空';
            Book? b;
            if (ctx.fileId != null && ctx.fileId!.isNotEmpty) {
              b = await ctx.book();
            } else {
              b = await ctx.findBook(
                  (args['book_title'] ?? '').toString().trim());
            }
            if (b == null) {
              return '没有找到要挂笔记的书（书内对话默认当前书；'
                  '纯 AI 对话请带 book_title 参数，或让用户先上传附件）';
            }
            final quote = (args['quote'] ?? '').toString().trim();
            await ctx.storage.insertAiNote(AiNote(
              bookId: b.id,
              fileType: (b.extension ?? 'pdf').toLowerCase(),
              anchor: jsonEncode({'source': 'ai_assistant'}),
              quotedText: quote.isEmpty ? 'AI 生成' : quote,
              content: content,
            ));
            return '已把内容保存为《${b.title}》的 AI 笔记（笔记中心可见）';
          },
        ),

        // 22 ── 修改笔记（写）
        AiToolDefinition(
          name: 'edit_note',
          label: '修改笔记',
          danger: AiToolDanger.write,
          description: '按关键词找到用户已有的笔记（高亮批注 / Word 批注 / AI 笔记 / '
              '书内标注），把它的正文改成 new_content。用户说'
              '「把关于 X 的笔记改成…」时调用。找到多条时会列出候选，'
              '让用户说得更具体（比如带上书名）。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '笔记里的关键词'},
              'new_content': {'type': 'string', 'description': '新的笔记正文'},
            },
            'required': ['keyword', 'new_content'],
          },
          example: '把我关于「熵」的笔记改成更详细的版本',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            final newContent = (args['new_content'] ?? '').toString().trim();
            if (kw.isEmpty || newContent.isEmpty) return '关键词或新内容为空';
            final list = await _noteCandidates(ctx.storage, kw);
            if (list.isEmpty) return '没有找到与「$kw」相关的笔记';
            if (list.length > 1) {
              return '找到 ${list.length} 条相关笔记，请用户说得更具体'
                  '（比如带上书名）：\n${_candidateLines(list)}';
            }
            final c = list.first;
            final ok = await _updateNote(ctx.storage, c.id, c.type, newContent);
            if (!ok) return '笔记不存在或已被删除';
            return '已更新笔记（${c.type}）：${AiToolContext._cap(c.text, max: 60)}';
          },
        ),

        // 23 ── 删除笔记（危险）
        AiToolDefinition(
          name: 'delete_note',
          label: '删除笔记',
          danger: AiToolDanger.dangerous,
          description: '按关键词找到用户已有的笔记并删除。用户明确说'
              '「删除关于 X 的笔记」时调用。只在**恰好一条**匹配时删除；'
              '多条匹配时列出候选让用户指定，绝不批量删除。',
          parameters: {
            'type': 'object',
            'properties': {
              'keyword': {'type': 'string', 'description': '笔记里的关键词'},
            },
            'required': ['keyword'],
          },
          example: '删除我关于「熵」的笔记',
          execute: (args, ctx) async {
            final kw = (args['keyword'] ?? '').toString().trim();
            if (kw.isEmpty) return '关键词为空';
            final list = await _noteCandidates(ctx.storage, kw);
            if (list.isEmpty) return '没有找到与「$kw」相关的笔记';
            if (list.length > 1) {
              return '找到 ${list.length} 条相关笔记，为避免误删请用户说得更具体：\n'
                  '${_candidateLines(list)}';
            }
            final c = list.first;
            final ok = await _deleteNote(ctx.storage, c.id, c.type);
            if (!ok) return '笔记不存在或已被删除';
            return '已删除笔记（${c.type}）：${AiToolContext._cap(c.text, max: 60)}';
          },
        ),

        // 24 ── 创建备忘录（写）
        AiToolDefinition(
          name: 'create_memo',
          label: '创建备忘录',
          danger: AiToolDanger.write,
          description: '把 AI 生成的内容创建成一条备忘录（备忘列表页可见）。'
              '用户说「写成备忘录/记到备忘录里」时调用。'
              'content 里按空行分段，第一段作为标题块。',
          parameters: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '备忘录标题'},
              'content': {'type': 'string', 'description': '备忘录正文（按空行分段）'},
            },
            'required': ['content'],
          },
          example: '把这份计划写成备忘录',
          execute: (args, ctx) async {
            final title = (args['title'] ?? '').toString().trim();
            final content = (args['content'] ?? '').toString().trim();
            if (title.isEmpty && content.isEmpty) return '备忘录标题和内容都为空';
            final paragraphs =
                content.split(RegExp(r'\n\s*\n')).where((p) => p.trim().isNotEmpty).toList();
            final blocks = <MemoBlock>[
              for (var i = 0; i < paragraphs.length; i++)
                MemoBlock(
                  type: i == 0 && title.isEmpty ? 'h1' : 'p',
                  text: paragraphs[i].trim(),
                ),
            ];
            if (blocks.isEmpty) blocks.add(MemoBlock(type: 'p', text: content));
            final t = title.isEmpty ? (paragraphs.isEmpty ? 'AI 备忘录' : paragraphs.first.trim()) : title;
            await ctx.storage.insertMemo(
                Memo(title: t.length > 40 ? t.substring(0, 40) : t, blocks: blocks));
            return '已创建备忘录「$t」（备忘列表页可见）';
          },
        ),

        // 25 ── 列出备忘录（读）
        AiToolDefinition(
          name: 'list_memos',
          label: '列出备忘录',
          description: '列出用户的全部备忘录（标题/更新时间/正文开头）。'
              '用户问「我的备忘录里有什么」时调用。',
          parameters: _noArgs,
          example: '我的备忘录里有什么？',
          execute: (args, ctx) async {
            final memos = await ctx.storage.getMemos();
            if (memos.isEmpty) return '还没有备忘录';
            final lines = <String>[];
            for (final m in memos.take(20)) {
              final body = m.blocks
                  .map((b) => b.text)
                  .join(' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim();
              lines.add('- 《${m.title}》：${AiToolContext._cap(body, max: 60)}');
            }
            return '共 ${memos.length} 条备忘录：\n${lines.join('\n')}';
          },
        ),

        // 26 ── 移动书到文件夹（写）
        AiToolDefinition(
          name: 'move_books_to_folder',
          label: '移动书到文件夹',
          danger: AiToolDanger.write,
          description: '把书架上的若干本书移到指定文件夹（文件夹不存在会自动创建）。'
              '用户说「把 X 书放到 Y 文件夹」时调用。',
          parameters: {
            'type': 'object',
            'properties': {
              'folder': {'type': 'string', 'description': '目标文件夹名'},
              'book_titles': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': '要移动的书名关键词列表',
              },
            },
            'required': ['folder', 'book_titles'],
          },
          example: '把《三体》和《球状闪电》移到「科幻」文件夹',
          execute: (args, ctx) async {
            final folder = (args['folder'] ?? '').toString().trim();
            if (folder.isEmpty) return '文件夹名为空';
            final titles = ((args['book_titles'] as List?) ?? [])
                .map((t) => t.toString().trim())
                .where((t) => t.isNotEmpty)
                .toList();
            if (titles.isEmpty) return '没有指定要移动的书';
            final books = await ctx.storage.getBookshelf();
            final moved = <String>[];
            final missing = <String>[];
            for (final t in titles) {
              Book? match;
              for (final b in books) {
                if (b.title.toLowerCase().contains(t.toLowerCase())) {
                  match = b;
                  break;
                }
              }
              if (match == null) {
                missing.add(t);
                continue;
              }
              await ctx.storage.updateBookFolder(match.id, folder);
              moved.add(match.title);
            }
            return '已把 ${moved.length} 本书移到文件夹「$folder」：${moved.join('、')}'
                '${missing.isEmpty ? '' : '\n未找到：${missing.join('、')}'}';
          },
        ),
      ];

  /// 按名字查工具定义。
  static AiToolDefinition? byName(String name) {
    for (final t in all()) {
      if (t.name == name) return t;
    }
    return null;
  }

  // ── 笔记工具的内部实现（edit_note / delete_note 共用） ───────────

  /// 跨四张表（批注 / Word 批注 / AI 笔记 / 书内标注）按关键词找候选。
  static Future<List<({String type, int id, String text})>> _noteCandidates(
      StorageService storage, String kw) async {
    final out = <({String type, int id, String text})>[];
    final q = kw.toLowerCase();
    for (final a in await storage.getAllAnnotations()) {
      if (a.id == null) continue;
      final hay = '${a.quotedText}\n${a.note}'.toLowerCase();
      if (hay.contains(q)) {
        out.add((type: '批注', id: a.id!, text: a.quotedText));
      }
    }
    for (final n in await storage.getAllDocxNotes()) {
      if (n.id == null) continue;
      final hay = '${n.quotedText}\n${n.note}'.toLowerCase();
      if (hay.contains(q)) {
        out.add((type: 'Word 批注', id: n.id!, text: n.quotedText));
      }
    }
    for (final n in await storage.getAllAiNotes()) {
      if (n.id == null) continue;
      final hay = '${n.quotedText}\n${n.content}'.toLowerCase();
      if (hay.contains(q)) {
        out.add((type: 'AI 笔记', id: n.id!, text: n.quotedText));
      }
    }
    for (final n in await storage.getAllReadestNotes()) {
      if (n.id == null) continue;
      final hay = '${n.text}\n${n.note}'.toLowerCase();
      if (hay.contains(q)) {
        out.add((type: '书内标注', id: n.id!, text: n.text));
      }
    }
    return out;
  }

  static String _candidateLines(
      List<({String type, int id, String text})> list) {
    final buf = StringBuffer();
    for (var i = 0; i < math.min(list.length, 8); i++) {
      final c = list[i];
      buf.writeln(
          '${i + 1}. [${c.type}] ${AiToolContext._cap(c.text, max: 40)}');
    }
    return buf.toString();
  }

  static Future<bool> _updateNote(
      StorageService storage, int id, String type, String content) async {
    try {
      switch (type) {
        case '批注':
          final all = await storage.getAllAnnotations();
          final a = all.where((x) => x.id == id).firstOrNull;
          if (a == null) return false;
          await storage.updateAnnotationFull(a.copyWith(note: content));
        case 'Word 批注':
          final all = await storage.getAllDocxNotes();
          final n = all.where((x) => x.id == id).firstOrNull;
          if (n == null) return false;
          await storage.upsertDocxNote(n.copyWith(note: content));
        case 'AI 笔记':
          final all = await storage.getAllAiNotes();
          if (!all.any((x) => x.id == id)) return false;
          await storage.updateAiNoteContent(id, content);
        case '书内标注':
          final all = await storage.getAllReadestNotes();
          final n = all.where((x) => x.id == id).firstOrNull;
          if (n == null) return false;
          await storage.upsertReadestNote(n.copyWith(note: content));
        default:
          return false;
      }
      return true;
    } catch (e) {
      debugPrint('[AI] update note failed: $e');
      return false;
    }
  }

  static Future<bool> _deleteNote(
      StorageService storage, int id, String type) async {
    try {
      switch (type) {
        case '批注':
          await storage.deleteAnnotation(id);
        case 'Word 批注':
          await storage.deleteDocxNote(id);
        case 'AI 笔记':
          await storage.deleteAiNote(id);
        case '书内标注':
          await storage.deleteReadestNote(id);
        default:
          return false;
      }
      return true;
    } catch (e) {
      debugPrint('[AI] delete note failed: $e');
      return false;
    }
  }

  /// 执行一个工具调用（runToolLoop 的回调；未知工具名返回错误文本）。
  ///
  /// 工具内部存储/文件访问抛异常时统一兜底成中文提示回给模型——
  /// 不能让原始异常（如 SQLite 损坏）直接出现在对话里。
  static Future<String> executeCall(
      AiToolCall call, AiToolContext context) async {
    final tool = byName(call.name);
    if (tool == null) return '未知工具：${call.name}';
    Map<String, dynamic> args = {};
    try {
      final decoded = jsonDecode(call.arguments);
      if (decoded is Map<String, dynamic>) args = decoded;
    } catch (_) {
      // 参数不是合法 JSON——按空参数执行，工具内部会兜底报错。
    }
    try {
      return await tool.execute(args, context);
    } catch (e) {
      return '工具「${tool.label}」执行失败（本地数据暂不可用）：$e';
    }
  }
}

/// AI 工具开关存储（默认全开；用户在「AI 工具」设置页关掉的工具
/// 不会出现在模型可用的 tools 列表里）。
class AiToolsStore {
  AiToolsStore._();
  static final AiToolsStore instance = AiToolsStore._();

  static const _kDisabled = 'ai_tools_disabled_v1';

  Future<Set<String>> disabledNames() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kDisabled) ?? [];
    return list.toSet();
  }

  Future<void> setDisabled(String name, bool disabled) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await disabledNames();
    if (disabled) {
      set.add(name);
    } else {
      set.remove(name);
    }
    await prefs.setStringList(_kDisabled, set.toList());
  }

  /// 当前启用的工具定义列表（按注册顺序）。
  Future<List<AiToolDefinition>> enabledTools() async {
    final disabled = await disabledNames();
    return [
      for (final t in AiTools.all())
        if (!disabled.contains(t.name)) t,
    ];
  }

  /// 当前启用的系统提示词 id（提示词管理页「设为系统提示」）。
  Future<int?> systemPromptId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('ai_system_prompt_id');
  }

  Future<void> setSystemPromptId(int? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('ai_system_prompt_id');
    } else {
      await prefs.setInt('ai_system_prompt_id', id);
    }
  }

  static const _kAutoApproveWrite = 'ai_agent_auto_approve_write_v1';

  /// Agent 后台任务遇到写操作时是否自动放行（默认 false = 暂停等确认）。
  Future<bool> autoApproveWrite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoApproveWrite) ?? false;
  }

  Future<void> setAutoApproveWrite(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoApproveWrite, v);
  }
}
