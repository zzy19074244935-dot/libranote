import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart'
    show TextPainter, TextSpan, TextStyle, Color;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' hide PdfDocument, PdfPage;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../models/models.dart';
import 'docx_loader.dart';

/// 批注汇总条目（导出「编辑后的 PDF」末尾汇总页用）。
class ExportAppendixItem {
  /// 类型标签：AI 笔记 / 书内标注 / 高亮 / 笔记 / 手写批注。
  final String label;

  /// 原文引用（§2.8 铁律：导出必带原文）。
  final String quote;

  /// 笔记正文 / AI 生成内容。
  final String content;

  /// 位置（第 N 页 / 章节）。
  final String location;

  const ExportAppendixItem({
    required this.label,
    this.quote = '',
    this.content = '',
    this.location = '',
  });
}

/// 把备忘录 / 读书笔记导出为 Word(.docx) 或 PDF。
///
/// - Word：手写最小 OOXML（zip 容器），中文天然支持，零字体依赖。
/// - PDF：用 `pdf` 包（钉 3.8.4，与 image 3.3.0 兼容），中文需内嵌开源字体
///   `assets/fonts/NotoSansSC.ttf`（霞鹜/思源类；本工程内置 Noto Sans SC，OFL 许可）。
class DocExportService {
  DocExportService._();
  static final DocExportService instance = DocExportService._();

  ByteData? _fontData;

  /// 懒加载中文字体；缺失时返回 null（PDF 导出会报出明确错误）。
  Future<ByteData?> _loadFont() async {
    if (_fontData != null) return _fontData;
    try {
      _fontData = await rootBundle.load('assets/fonts/NotoSansSC.ttf');
    } catch (e) {
      debugPrint('[Export] CJK font load failed: $e');
    }
    return _fontData;
  }

  // ── 备忘录导出 ────────────────────────────────────────────────────

  Future<String> memoToDocx(Memo memo) async {
    final xml = _memoDocx(memo);
    final bytes = _zipDocx(xml);
    return _write('memo-${_stamp()}.docx', bytes);
  }

  Future<String> memoToPdf(Memo memo) async {
    final font = await _requireFont();
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (_) => _memoPdf(memo),
    ));
    return _write('memo-${_stamp()}.pdf', await doc.save());
  }

  // ── 读书笔记导出 ─────────────────────────────────────────────────

  Future<String> notesToDocx(
    List<Annotation> notes,
    String Function(Annotation) bookLabel,
  ) async {
    final xml = _notesDocx(notes, bookLabel);
    final bytes = _zipDocx(xml);
    return _write('libranote-notes-${_stamp()}.docx', bytes);
  }

  /// 纯文本导出（.txt）：原文引用 + 笔记正文 + 位置，UTF-8。
  Future<String> notesToTxt(
    List<Annotation> notes,
    String Function(Annotation) bookLabel,
  ) async {
    final buf = StringBuffer();
    buf.writeln('Libranote 笔记导出');
    buf.writeln(
        '导出时间: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buf.writeln('共 ${notes.length} 条笔记');
    buf.writeln();

    final grouped = <String, List<Annotation>>{};
    final order = <String>[];
    for (final a in notes) {
      final label = bookLabel(a);
      (grouped[label] ??= []).add(a);
      if (!order.contains(label)) order.add(label);
    }

    for (final label in order) {
      buf.writeln('━━━ $label ━━━');
      buf.writeln();
      for (final a in grouped[label]!) {
        if (a.quotedText.isNotEmpty) {
          buf.writeln('原文：${a.quotedText}');
        }
        if (a.note.isNotEmpty) {
          buf.writeln('笔记：${a.note}');
        }
        final type = a.type == AnnotationType.highlight ? '高亮' : '笔记';
        final date =
            DateFormat('yyyy-MM-dd HH:mm').format(a.createdAt);
        buf.writeln('— $type · ${a.location} · $date');
        buf.writeln();
      }
      buf.writeln();
    }
    return _write('libranote-notes-${_stamp()}.txt',
        Uint8List.fromList(utf8.encode(buf.toString())));
  }

  Future<String> notesToPdf(
    List<Annotation> notes,
    String Function(Annotation) bookLabel,
  ) async {
    final font = await _requireFont();
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (_) => _notesPdf(notes, bookLabel),
    ));
    return _write('libranote-notes-${_stamp()}.pdf', await doc.save());
  }

  // ── 批注报告（Phase 4 Word 导出：每条必含原文引用 + 笔记 + AI 内容） ──

  Future<String> reportToDocx(
      String title, List<ExportAppendixItem> items) async {
    final buf = StringBuffer('<w:body>');
    buf.write(_p(title, bold: true, size: 18, after: 200));
    buf.write(_p('导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
        size: 10, color: '808080', after: 240));
    for (final it in items) {
      buf.write(_p('${it.label}${it.location.isNotEmpty ? ' · ${it.location}' : ''}',
          bold: true, size: 12, after: 80));
      if (it.quote.isNotEmpty) {
        buf.write(_p('原文：${it.quote}', italic: true, size: 10,
            color: '808080', after: 60));
      }
      if (it.content.isNotEmpty) {
        buf.write(_p(it.content, size: 11, after: 140));
      }
    }
    buf.write('</w:body>');
    final bytes = _zipDocx(buf.toString());
    return _write('report-${_stamp()}.docx', bytes);
  }

  Future<String> reportToPdf(
      String title, List<ExportAppendixItem> items) async {
    final font = await _requireFont();
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      theme: pw.ThemeData.withFont(base: font, bold: font),
      build: (_) => [
        pw.Text(title,
            style:
                pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        for (final it in items) ...[
          pw.Text(
              '${it.label}${it.location.isNotEmpty ? ' · ${it.location}' : ''}',
              style: pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)),
          if (it.quote.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFF3F4F6),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Text('原文：${it.quote}',
                  style: const pw.TextStyle(fontSize: 10.5)),
            ),
          ],
          if (it.content.isNotEmpty) ...[
            pw.SizedBox(height: 6),
            pw.Text(it.content, style: const pw.TextStyle(fontSize: 12)),
          ],
          pw.SizedBox(height: 10),
        ],
      ],
    ));
    return _write('report-${_stamp()}.pdf', await doc.save());
  }

  /// 批注报告纯文本版（.txt，UTF-8）。
  Future<String> reportToTxt(
      String title, List<ExportAppendixItem> items) async {
    final buf = StringBuffer();
    buf.writeln(title);
    buf.writeln(
        '导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buf.writeln();
    for (final it in items) {
      buf.writeln('---');
      buf.writeln(
          '【${it.label}${it.location.isNotEmpty ? ' · ${it.location}' : ''}】');
      if (it.quote.isNotEmpty) {
        buf.writeln('原文：${it.quote}');
      }
      if (it.content.isNotEmpty) {
        buf.writeln(it.content);
      }
      buf.writeln();
    }
    return _write('report-${_stamp()}.txt',
        Uint8List.fromList(utf8.encode(buf.toString())));
  }

  /// 导出「编辑版 DOCX」：保留 Word 格式（对齐/加粗/斜体/字号/颜色），
  /// 并把段落批注区间烘焙成 Word 高亮/下划线；style='image' 的批注
  /// （插入的照片/截图）作为内嵌图片烘焙进正文；末尾附「批注汇总」节。
  Future<String> exportEditedDocx({
    required LoadedDocx docx,
    required String title,
    required List<DocxNote> notes,
    String? outName,
  }) async {
    // 图片批注：paraIndex → 图片文件路径（文件存在才收录）。
    final imagesByPara = <int, String>{};
    for (final n in notes) {
      if (n.style == 'image' &&
          n.imagePath != null &&
          n.imagePath!.isNotEmpty &&
          await File(n.imagePath!).exists()) {
        imagesByPara[n.paraIndex] = n.imagePath!;
      }
    }
    final media = <Uint8List>[];
    final imageRelIndex = <int, ({int rel, int w, int h})>{}; // paraIndex → 关系/尺寸
    for (final entry in imagesByPara.entries) {
      final bytes = await File(entry.value).readAsBytes();
      media.add(bytes);
      var w = 320;
      var h = 240;
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null && decoded.width > 0 && decoded.height > 0) {
          w = decoded.width;
          h = decoded.height;
        }
      } catch (_) {}
      imageRelIndex[entry.key] = (rel: media.length, w: w, h: h);
    }

    final xml = _editedDocx(docx, title, notes, imageRelIndex);
    final bytes = _zipDocx(xml, media: media);
    final name = outName == null || outName.isEmpty
        ? 'edited-${_stamp()}.docx'
        : '${outName}_编辑版.docx';
    return _write(name, bytes);
  }

  // ── 通用落盘 / 分享 ──────────────────────────────────────────────

  /// 导出「编辑后的 PDF」：把阅读器里的手写笔迹 + 文本框（pdf_ink v2）烘焙
  /// 进页面渲染图，合成一份新的 PDF（每页一张图）。笔迹与阅读器同款渲染
  /// （同路径/笔刷/压感），视觉一致。逐页渲染 → JPEG → 及时释放，控制峰值
  /// 内存。末尾附「批注汇总」页（方案 §2.8：导出必须带原文）。
  Future<String> exportEditedPdf({
    required String pdfPath,
    required Map<int, List<InkStroke>> inkByPage,
    String? outName,
    Map<int, List<PdfTextItem>> textsByPage = const {},
    Map<int, List<PdfImageItem>> imagesByPage = const {},
    List<Annotation> highlights = const [],
    List<ExportAppendixItem> appendixItems = const [],
    String? bookId,
    void Function(int done, int total)? onProgress,
  }) async {
    final doc = await PdfDocument.openFile(pdfPath);
    try {
      // 渲染清晰度：1.5×（108dpi）导出偏糊 → 2.5×（180dpi）。
      // 页面是位图合成，分辨率直接决定导出 PDF 的清晰度。
      const scale = 2.5;
      final pwDoc = pw.Document();
      final pages = doc.pages;
      final totalPages = pages.length;

      // 图片目录（有图片才解析一次）。
      Directory? imagesDir;
      if (imagesByPage.isNotEmpty) {
        final docs = await getApplicationDocumentsDirectory();
        imagesDir = Directory(p.join(docs.path, 'pdf_images', bookId ?? ''));
      }

      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];

        // 不可见文字层：渲染前提取该页原文（pdfrx loadText 自带字符坐标），
        // 以白色文字垫在页面图片**下方**——肉眼看不到，但重新导入后
        // 能选中/复制/全文检索（修复「编辑导出后的 PDF 无法选中内容」）。
        // 扫描版 PDF 本来就没有文字层，跳过即可（导入后走 OCR）。
        List<(Rect, String)> invisibleLines = const [];
        try {
          final pageText = await page.loadText();
          if (pageText != null &&
              pageText.fullText.trim().isNotEmpty &&
              pageText.charRects.isNotEmpty &&
              pageText.fullText.length <= 60000) {
            invisibleLines = _pageTextLines(page, pageText);
          }
        } catch (e) {
          debugPrint('[Export] extract text layer failed: $e');
        }

        final w = page.width * scale;
        final h = page.height * scale;
        final pdfImg = await page.render(
          fullWidth: w,
          fullHeight: h,
          backgroundColor: 0xffffffff,
          annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
          flags: PdfPageRenderFlags.none,
        );
        if (pdfImg == null) continue;
        final base = await pdfImg.createImage();
        pdfImg.dispose();

        // 把该页高亮 + 笔迹 + 文本框 + 图片画到渲染图上。
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(
            recorder, ui.Rect.fromLTWH(0, 0, w, h));
        canvas.drawImage(base, ui.Offset.zero, ui.Paint());
        base.dispose();
        // 文本高亮矩形（批注烘焙）。
        _drawHighlights(canvas, highlights, page.pageNumber,
            page.width, page.height, scale);
        final strokes = inkByPage[page.pageNumber] ?? [];
        final pageRect = ui.Rect.fromLTWH(0, 0, page.width, page.height);
        for (final s in strokes) {
          if (s.points.isEmpty) continue;
          canvas.drawPath(
              _inkPath(s.points, pageRect, scale), _inkPaint(s, scale));
        }
        // 文本框烘焙（含 AI 页边解释文字；系统字体兜底中文渲染；
        // 带旋转——与阅读器渲染一致）。
        final texts = textsByPage[page.pageNumber] ?? [];
        for (final t in texts) {
          final tp = TextPainter(
            text: TextSpan(
              text: t.text,
              style: TextStyle(
                color: Color(t.color),
                fontSize: t.fontSize * scale,
                height: 1.35,
              ),
            ),
            textDirection: ui.TextDirection.ltr,
            maxLines: 300,
          );
          tp.layout(maxWidth: t.width * page.width * scale);
          final pos =
              ui.Offset(t.x * page.width * scale, t.y * page.height * scale);
          final center =
              ui.Offset(pos.dx + tp.width / 2, pos.dy + tp.height / 2);
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(t.rotation * math.pi / 180);
          canvas.translate(-center.dx, -center.dy);
          tp.paint(canvas, pos);
          canvas.restore();
        }
        // 图片烘焙（截图/本地图片插入批注图层；文件缺失则跳过）。
        final images = imagesByPage[page.pageNumber] ?? [];
        for (final img in images) {
          if (img.fileName.isEmpty || imagesDir == null) continue;
          final file = File(p.join(imagesDir.path, img.fileName));
          if (!await file.exists()) continue;
          try {
            final bytes = await file.readAsBytes();
            final codec = await ui.instantiateImageCodec(bytes);
            final frame = await codec.getNextFrame();
            final bitmap = frame.image;
            final destRect = ui.Rect.fromLTWH(
              img.x * page.width * scale,
              img.y * page.height * scale,
              img.w * page.width * scale,
              img.h * page.height * scale,
            );
            canvas.save();
            canvas.translate(destRect.center.dx, destRect.center.dy);
            canvas.rotate(img.rotation * math.pi / 180);
            canvas.translate(-destRect.center.dx, -destRect.center.dy);
            canvas.drawImageRect(
              bitmap,
              ui.Rect.fromLTWH(
                  0, 0, bitmap.width.toDouble(), bitmap.height.toDouble()),
              destRect,
              ui.Paint(),
            );
            canvas.restore();
            bitmap.dispose();
            codec.dispose();
          } catch (e) {
            debugPrint('[Export] draw image failed: $e');
          }
        }
        final picture = recorder.endRecording();
        final composed = await picture.toImage(w.round(), h.round());
        picture.dispose();
        // JPEG 压缩：页面是位图合成，JPEG q85 视觉无损、体积比 PNG 小一个
        // 数量级——大书导出从「几分钟/内存爆」降到十几秒内。
        final byteData = await composed.toByteData(
            format: ui.ImageByteFormat.rawRgba);
        composed.dispose();
        if (byteData == null) continue;
        final jpeg = _encodeJpeg(byteData.buffer.asUint8List(),
            w.round(), h.round());

        // 页面 = 不可见文字层（先画，垫底）+ 整页位图（后画，盖住文字）。
        List<pw.Widget> invisibleLayer = const [];
        if (invisibleLines.isNotEmpty) {
          try {
            final font = await _requireFont();
            invisibleLayer = [
              for (final (rect, line) in invisibleLines)
                if (line.isNotEmpty && rect.width > 0 && rect.height > 0)
                  pw.Positioned(
                    left: rect.left,
                    top: rect.top,
                    child: pw.Text(
                      line,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: rect.height.clamp(2.0, 60.0),
                        color: PdfColors.white,
                      ),
                    ),
                  ),
            ];
          } catch (e) {
            debugPrint('[Export] invisible text layer failed: $e');
          }
        }

        pwDoc.addPage(pw.Page(
          pageFormat: PdfPageFormat(page.width, page.height),
          build: (_) => invisibleLayer.isEmpty
              ? pw.Image(
                  pw.MemoryImage(jpeg),
                  fit: pw.BoxFit.contain,
                )
              : pw.Stack(
                  children: [
                    ...invisibleLayer,
                    pw.Positioned.fill(
                      child: pw.Image(
                        pw.MemoryImage(jpeg),
                        fit: pw.BoxFit.fill,
                      ),
                    ),
                  ],
                ),
        ));
        if ((i + 1) % 10 == 0 || i == pages.length - 1) {
          onProgress?.call(i + 1, totalPages);
          debugPrint('[Export] edited pdf: ${i + 1}/$totalPages');
        }
      }
      if (pages.isEmpty) {
        throw Exception('PDF 渲染失败（没有可导出的页面）');
      }
      // ── 批注汇总页：每条必带原文引用（§2.8 铁律） ──────────────
      if (appendixItems.isNotEmpty) {
        final font = await _requireFont();
        pwDoc.addPage(pw.MultiPage(
          pageTheme: pw.PageTheme(
            theme: pw.ThemeData.withFont(base: font, bold: font),
          ),
          build: (_) => [
            pw.Text('批注汇总',
                style: pw.TextStyle(
                    fontSize: 22, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Text('共 ${appendixItems.length} 条',
                style: const pw.TextStyle(
                    fontSize: 11, color: PdfColor.fromInt(0xFF9CA3AF))),
            pw.SizedBox(height: 12),
            for (final item in appendixItems)
              pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 10),
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(
                      color: const PdfColor.fromInt(0xFFD1D5DB), width: 0.8),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Row(
                      children: [
                        pw.Text(item.label,
                            style: pw.TextStyle(
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 13)),
                        if (item.location.isNotEmpty)
                          pw.Text(' · ${item.location}',
                              style: const pw.TextStyle(
                                  fontSize: 10,
                                  color: PdfColor.fromInt(0xFF9CA3AF))),
                      ],
                    ),
                    if (item.quote.isNotEmpty) ...[
                      pw.SizedBox(height: 6),
                      pw.Container(
                        width: double.infinity,
                        padding: const pw.EdgeInsets.all(8),
                        decoration: pw.BoxDecoration(
                          color: const PdfColor.fromInt(0xFFF3F4F6),
                          borderRadius: pw.BorderRadius.circular(4),
                        ),
                        child: pw.Text('原文：${item.quote}',
                            style: const pw.TextStyle(fontSize: 10.5)),
                      ),
                    ],
                    if (item.content.isNotEmpty) ...[
                      pw.SizedBox(height: 6),
                      pw.Text(item.content,
                          style: const pw.TextStyle(fontSize: 12)),
                    ],
                  ],
                ),
              ),
          ],
        ));
      }
      final bytes = await pwDoc.save();
      final name = outName == null || outName.isEmpty
          ? 'edited-${_stamp()}.pdf'
          : '${outName}_编辑版.pdf';
      return _write(name, bytes);
    } finally {
      await doc.dispose();
    }
  }

  /// RGBA 原始像素 → JPEG（质量 85）。页面合成图用 JPEG 体积小、导出快。
  static Uint8List _encodeJpeg(Uint8List rgba, int width, int height) {
    final image = img.Image.fromBytes(width, height, rgba,
        format: img.Format.rgba);
    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  /// 笔迹路径（阅读器 `_inkPath` 同款：二次贝塞尔平滑）。
  ui.Path _inkPath(List<WhiteboardPoint> pts, ui.Rect pageRect, double scale) {
    final path = ui.Path();
    final first = pts.first;
    path.moveTo(
      pageRect.left + first.x * pageRect.width * scale,
      pageRect.top + first.y * pageRect.height * scale,
    );
    for (var i = 1; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      path.quadraticBezierTo(
        pageRect.left + a.x * pageRect.width * scale,
        pageRect.top + a.y * pageRect.height * scale,
        pageRect.left + ((a.x + b.x) / 2) * pageRect.width * scale,
        pageRect.top + ((a.y + b.y) / 2) * pageRect.height * scale,
      );
    }
    final last = pts.last;
    path.lineTo(
      pageRect.left + last.x * pageRect.width * scale,
      pageRect.top + last.y * pageRect.height * scale,
    );
    return path;
  }

  /// 笔刷（阅读器 `_inkPaintFor` 同款：荧光笔 12pt/0.35 透明，笔 2.2pt 默认）。
  ui.Paint _inkPaint(InkStroke s, double scale) {
    final isHl = s.brush == BrushType.highlighter;
    final widthPoints = s.width ?? (isHl ? 12.0 : 2.2);
    final opacity = isHl ? 0.35 : 1.0;
    return ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..strokeWidth = widthPoints * scale
      ..color = ui.Color(s.color).withValues(alpha: opacity);
  }

  /// 把文本高亮（kind==pdf 且 rects 非空）画到已渲染的位图上。
  /// 算法参考 reader_screen 的 `_pdfPaintHighlights`。
  void _drawHighlights(ui.Canvas canvas, List<Annotation> highlights,
      int pageNumber, double pageWidth, double pageHeight, double scale) {
    for (final ann in highlights) {
      if (ann.anchor.kind != AnchorKind.pdf ||
          ann.anchor.pageIndex != pageNumber ||
          ann.anchor.rects.isEmpty) {
        continue;
      }
      final color = ui.Color(
        int.parse((ann.color ?? '#FFEB3B').replaceFirst('#', '0xFF')),
      );
      for (final nr in ann.anchor.rects) {
        // min/max 兜底：旧版本保存的 rects 的 t/b 可能反了。
        final top = nr.t < nr.b ? nr.t : nr.b;
        final bottom = nr.t < nr.b ? nr.b : nr.t;
        final r = ui.Rect.fromLTRB(
          nr.l * pageWidth * scale,
          top * pageHeight * scale,
          nr.r * pageWidth * scale,
          bottom * pageHeight * scale,
        );
        switch (ann.style) {
          case 'underline':
            canvas.drawLine(
              r.bottomLeft,
              r.bottomRight,
              ui.Paint()
                ..color = color
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = 1.6 * scale
                ..strokeCap = ui.StrokeCap.round,
            );
            break;
          case 'squiggly':
            final wave = ui.Path();
            final seg = 3.5 * scale;
            final dx = r.width > 0 ? r.width : 1.0;
            final count = math.max(2, (dx / seg).ceil());
            wave.moveTo(r.left, r.bottom);
            for (var i = 1; i <= count; i++) {
              final x = r.left + dx * i / count;
              final y = r.bottom + (i.isOdd ? -2.2 * scale : 2.2 * scale);
              wave.lineTo(x, y);
            }
            canvas.drawPath(
              wave,
              ui.Paint()
                ..color = color
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = 1.3 * scale
                ..strokeCap = ui.StrokeCap.round,
            );
            break;
          default:
            canvas.drawRect(
              r,
              ui.Paint()
                ..color = color.withValues(alpha: 0.35)
                ..style = ui.PaintingStyle.fill,
            );
        }
      }
    }
  }

  /// 写入 Documents 并返回路径；顺带拷一份到系统 Downloads（文件 App 可见）。
  Future<String> _write(String filename, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 内置中文字体缓存（导出时逐页垫文字层，不能每页都重新解析 TTF）。
  pw.Font? _cachedFont;

  Future<pw.Font> _requireFont() async {
    if (_cachedFont != null) return _cachedFont!;
    final data = await _loadFont();
    if (data == null) {
      throw Exception('PDF 导出需要内置中文字体（assets/fonts/NotoSansSC.ttf），但字体缺失');
    }
    _cachedFont = pw.Font.ttf(data);
    return _cachedFont!;
  }

  /// 把一页原文按行拆成「(左上原点矩形, 行文本)」——垫不可见文字层用。
  ///
  /// pdfrx 的 charRects 是 PDF 坐标系（左下原点、Y 向上），这里换算成
  /// PDF 输出页的左上原点坐标（单位 pt，与 pw.Page 一致）。行按 fullText
  /// 里的换行符切分，每行取字符矩形的包围盒做定位。
  static List<(Rect, String)> _pageTextLines(
      PdfPage page, PdfPageRawText pageText) {
    final out = <(Rect, String)>[];
    final text = pageText.fullText;
    final rects = pageText.charRects;
    if (text.isEmpty || rects.isEmpty) return out;
    var start = 0;
    for (var i = 0; i <= text.length; i++) {
      final atEnd = i == text.length;
      if (!atEnd && text.codeUnitAt(i) != 0x0A) continue;
      final lineText = text.substring(start, i).trim();
      if (lineText.isNotEmpty && start < rects.length) {
        final end = math.min(i, rects.length);
        var l = double.infinity;
        var t = double.negativeInfinity;
        var r = double.negativeInfinity;
        var b = double.infinity;
        for (var k = start; k < end; k++) {
          final c = rects[k];
          if (c.left >= c.right || c.top <= c.bottom) continue; // 空矩形
          if (c.left < l) l = c.left;
          if (c.top > t) t = c.top;
          if (c.right > r) r = c.right;
          if (c.bottom < b) b = c.bottom;
        }
        if (l < r && b < t) {
          out.add((
            Rect.fromLTRB(l, page.height - t, r, page.height - b),
            lineText,
          ));
        }
      }
      start = i + 1;
    }
    // 超大页（>3000 行）文字层会显著增大导出文件体积，放弃该页。
    if (out.length > 3000) return const [];
    return out;
  }

  String _stamp() => DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());

  // ── DOCX 生成 ─────────────────────────────────────────────────────

  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// 一个段落 = 单个 run + 样式；换行用 <w:br/>。
  String _p(
    String text, {
    bool bold = false,
    bool italic = false,
    double size = 11,
    String? color,
    String? font,
    int after = 120,
  }) {
    final rpr = StringBuffer();
    if (bold) rpr.write('<w:b/>');
    if (italic) rpr.write('<w:i/>');
    rpr.write('<w:sz w:val="${(size * 2).round()}"/>'
        '<w:szCs w:val="${(size * 2).round()}"/>');
    if (color != null) rpr.write('<w:color w:val="$color"/>');
    if (font != null) {
      rpr.write('<w:rFonts w:ascii="$font" w:hAnsi="$font" '
          'w:eastAsia="$font" w:cs="$font"/>');
    }

    final lines = text.split('\n');
    final body = StringBuffer('<w:r><w:rPr>$rpr</w:rPr>');
    for (var i = 0; i < lines.length; i++) {
      body.write('<w:t xml:space="preserve">${_xmlEscape(lines[i])}</w:t>');
      if (i < lines.length - 1) body.write('<w:br/>');
    }
    body.write('</w:r>');

    return '<w:p><w:pPr><w:spacing w:after="$after"/></w:pPr>$body</w:p>';
  }

  String _editedDocx(LoadedDocx docx, String title, List<DocxNote> notes,
      Map<int, ({int rel, int w, int h})> imageByPara) {
    final buf = StringBuffer('<w:body>');
    buf.write(_p(title, bold: true, size: 18, after: 200));
    buf.write(_p('导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
        size: 10, color: '808080', after: 240));

    final rich = docx.richParagraphs;
    final count = rich.isNotEmpty ? rich.length : docx.paragraphs.length;
    for (var i = 0; i < count; i++) {
      // 该段插入的图片先输出（style='image' 批注烘焙成内嵌图）。
      final imgInfo = imageByPara[i];
      if (imgInfo != null) {
        buf.write(_imageParagraph(imgInfo.rel, imgInfo.w, imgInfo.h));
      }
      final para = i < rich.length ? rich[i] : null;
      final plain = para != null ? para.plainText : docx.paragraphs[i];
      final paraNotes = notes
          .where((n) =>
              n.paraIndex == i && n.style != 'image' && n.style != 'textbox')
          .toList();
      buf.write(_editedPara(para, plain, paraNotes));
    }

    // ── 浮动文本框烘焙（style='textbox'）：导出成「文本框」节，内容
    //    完整保留（Word 里作为普通段落，可复制/编辑）。 ──────────────
    final textBoxes = notes.where((n) => n.style == 'textbox').toList();
    if (textBoxes.isNotEmpty) {
      buf.write(_p('文本框', bold: true, size: 16, after: 160));
      for (final n in textBoxes) {
        buf.write(_p('文本框 · 第 ${n.paraIndex + 1} 段', bold: true, size: 11, after: 40));
        if (n.quotedText.isNotEmpty) {
          buf.write(_p('原文：${n.quotedText}', italic: true, size: 10,
              color: '808080', after: 60));
        }
        buf.write(_p(n.note.isEmpty ? '（空文本框）' : n.note,
            size: 11, color: '404040', after: 140));
      }
    }

    // ── 批注汇总 ────────────────────────────────────────────────────
    if (notes.isNotEmpty) {
      buf.write(_p('批注汇总', bold: true, size: 16, after: 160));
      for (final n in notes) {
        if (n.style == 'image') {
          buf.write(
              _p('第 ${n.paraIndex + 1} 段', bold: true, size: 11, after: 40));
          buf.write(_p('（本段插入了图片，已烘焙进正文对应段落）',
              italic: true, size: 10, color: '808080', after: 60));
          continue;
        }
        if (n.style == 'textbox') continue; // 已在「文本框」节烘焙
        buf.write(_p('第 ${n.paraIndex + 1} 段', bold: true, size: 11, after: 40));
        if (n.quotedText.isNotEmpty) {
          buf.write(_p('原文：${n.quotedText}', italic: true, size: 10,
              color: '808080', after: 60));
        }
        if (n.note.isNotEmpty) {
          buf.write(_p(n.note, size: 10, color: '404040', after: 140));
        }
      }
    }
    buf.write('</w:body>');
    return buf.toString();
  }

  /// 内嵌图片段落（WPS / Word 通用 inline drawing，EMU 换算 9525/px，
  /// 按原图宽高比显示，最大宽 340px）。
  String _imageParagraph(int relIdx, int width, int height) {
    const emuPerPx = 9525;
    var w = width.toDouble();
    var h = height.toDouble();
    if (w > 340) {
      final ratio = 340 / w;
      w = 340;
      h = h * ratio;
    }
    final cx = (w * emuPerPx).round();
    final cy = (h * emuPerPx).round();
    return '<w:p><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/>'
        '<wp:docPr id="$relIdx" name="图片$relIdx"/>'
        '<a:graphic><a:graphicData '
        'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic>'
        '<pic:nvPicPr><pic:cNvPr id="$relIdx" name="img$relIdx"/>'
        '<pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rIdImg$relIdx"/>'
        '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/>'
        '<a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>';
  }

  String _editedPara(DocxPara? para, String plain, List<DocxNote> notes) {
    final jcVal = para != null && para.alignment != 'left'
        ? para.alignment
        : null;
    final ppr = StringBuffer();
    ppr.write('<w:spacing w:after="120"/>');
    if (jcVal != null) ppr.write('<w:jc w:val="$jcVal"/>');

    final len = plain.length;
    if (len == 0) {
      return '<w:p><w:pPr>$ppr</w:pPr></w:p>';
    }

    // runs → 基础区间（无 runs 时把整段当一个无格式 run）。
    var segs = <_DocxSeg>[];
    var offset = 0;
    if (para != null && para.runs.isNotEmpty) {
      for (final r in para.runs) {
        if (r.text.isEmpty) continue;
        segs.add(_DocxSeg(offset, offset + r.text.length, r, null));
        offset += r.text.length;
      }
    }
    if (segs.isEmpty) {
      segs.add(_DocxSeg(0, len, null, null));
    }

    // 批注区间切分（与渲染层相同的光标裁剪）。
    var cursor = 0;
    for (final n in notes) {
      var s = n.startOffset.clamp(0, len).toInt();
      var e = n.endOffset.clamp(0, len).toInt();
      if (e < s) e = s;
      if (s < cursor) s = cursor;
      if (e <= s) continue;
      segs = _splitDocxSegs(segs, s);
      segs = _splitDocxSegs(segs, e);
      for (final seg in segs) {
        if (seg.start >= s && seg.end <= e) seg.note = n;
      }
      cursor = e;
    }

    final body = StringBuffer();
    for (final seg in segs) {
      body.write(_docxRunXml(
          plain.substring(seg.start, seg.end), seg.run, seg.note));
    }
    return '<w:p><w:pPr>$ppr</w:pPr>$body</w:p>';
  }

  String _docxRunXml(String text, DocxRun? run, DocxNote? note) {
    final rpr = StringBuffer();
    if (run != null) {
      if (run.bold) rpr.write('<w:b/>');
      if (run.italic) rpr.write('<w:i/>');
      if (run.underline) rpr.write('<w:u w:val="single"/>');
      if (run.strike) rpr.write('<w:strike/>');
      if (run.fontSize != null) {
        final sz = (run.fontSize! * 2).round();
        rpr.write('<w:sz w:val="$sz"/><w:szCs w:val="$sz"/>');
      }
      if (run.colorHex != null) rpr.write('<w:color w:val="${run.colorHex}"/>');
    }
    if (note != null) {
      final hex =
          (note.color ?? '#FACC15').replaceFirst('#', '').toUpperCase();
      switch (note.style) {
        case 'underline':
          rpr.write('<w:u w:val="single"/><w:color w:val="$hex"/>');
          break;
        case 'squiggly':
          rpr.write('<w:u w:val="wave"/><w:color w:val="$hex"/>');
          break;
        case 'plain':
          break;
        default:
          rpr.write('<w:highlight w:val="${_wordHighlightColor(note.color)}"/>');
      }
    }

    final body = StringBuffer();
    if (rpr.isNotEmpty) {
      body.write('<w:r><w:rPr>$rpr</w:rPr>');
    } else {
      body.write('<w:r>');
    }
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '\n') {
        body.write('<w:br/>');
        i++;
      } else if (ch == '\t') {
        body.write('<w:tab/>');
        i++;
      } else {
        final start = i;
        while (i < text.length && text[i] != '\n' && text[i] != '\t') {
          i++;
        }
        body.write(
            '<w:t xml:space="preserve">${_xmlEscape(text.substring(start, i))}</w:t>');
      }
    }
    body.write('</w:r>');
    return body.toString();
  }

  List<_DocxSeg> _splitDocxSegs(List<_DocxSeg> segs, int x) {
    final out = <_DocxSeg>[];
    for (final seg in segs) {
      if (seg.end <= x || seg.start >= x) {
        out.add(seg);
      } else {
        out.add(_DocxSeg(seg.start, x, seg.run, seg.note));
        out.add(_DocxSeg(x, seg.end, seg.run, seg.note));
      }
    }
    return out;
  }

  /// 把批注颜色映射到 Word 高亮色名（yellow/green/cyan/magenta/blue/red）。
  static const _wordHighlightRgb = <String, List<int>>{
    'yellow': [255, 255, 0],
    'green': [0, 255, 0],
    'cyan': [0, 255, 255],
    'magenta': [255, 0, 255],
    'blue': [0, 0, 255],
    'red': [255, 0, 0],
  };

  String _wordHighlightColor(String? hex) {
    int? r;
    int? g;
    int? b;
    if (hex != null) {
      final c = hex.replaceFirst('#', '');
      if (c.length == 6) {
        r = int.tryParse(c.substring(0, 2), radix: 16);
        g = int.tryParse(c.substring(2, 4), radix: 16);
        b = int.tryParse(c.substring(4, 6), radix: 16);
      }
    }
    final rr = r;
    final gg = g;
    final bb = b;
    if (rr == null || gg == null || bb == null) return 'yellow';
    var best = 'yellow';
    var bestDist = double.infinity;
    _wordHighlightRgb.forEach((name, rgb) {
      final dr = rr - rgb[0];
      final dg = gg - rgb[1];
      final db = bb - rgb[2];
      final d = (dr * dr + dg * dg + db * db).toDouble();
      if (d < bestDist) {
        bestDist = d;
        best = name;
      }
    });
    return best;
  }

  String _memoDocx(Memo memo) {
    final buf = StringBuffer('<w:body>');
    if (memo.title.isNotEmpty) {
      buf.write(_p(memo.title, bold: true, size: 18, after: 200));
    }
    for (final b in memo.blocks) {
      switch (b.type) {
        case 'h1':
          buf.write(_p(b.text, bold: true, size: 18));
        case 'h2':
          buf.write(_p(b.text, bold: true, size: 14));
        case 'h3':
          buf.write(_p(b.text, bold: true, size: 12, color: '808080'));
        case 'code':
          buf.write(_p(b.text, size: 10, font: 'Courier New', color: '333333'));
        default:
          buf.write(_p(b.text, size: 11));
      }
    }
    buf.write('</w:body>');
    return buf.toString();
  }

  String _notesDocx(
    List<Annotation> notes,
    String Function(Annotation) bookLabel,
  ) {
    final buf = StringBuffer('<w:body>');
    buf.write(_p('读书笔记导出', bold: true, size: 18, after: 200));
    buf.write(_p('导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
        size: 10, color: '808080', after: 240));

    final grouped = <String, List<Annotation>>{};
    final order = <String>[];
    for (final a in notes) {
      final label = bookLabel(a);
      (grouped[label] ??= []).add(a);
      if (!order.contains(label)) order.add(label);
    }

    for (final label in order) {
      buf.write(_p(label, bold: true, size: 14, after: 120));
      for (final a in grouped[label]!) {
        if (a.quotedText.isNotEmpty) {
          buf.write(_p('「${a.quotedText}」', italic: true, size: 10,
              color: '808080', after: 60));
        }
        if (a.note.isNotEmpty) {
          buf.write(_p(a.note, size: 11, after: 60));
        }
        final type = a.type == AnnotationType.highlight ? '高亮' : '笔记';
        buf.write(_p('— $type · ${a.location} · ${DateFormat('yyyy-MM-dd').format(a.createdAt)}',
            size: 9, color: 'A0A0A0', after: 160));
      }
    }
    buf.write('</w:body>');
    return buf.toString();
  }

  Uint8List _zipDocx(String bodyXml, {List<Uint8List> media = const []}) {
    final buf = StringBuffer();
    buf.write(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>');
    if (media.isNotEmpty) {
      buf.write('<Default Extension="png" ContentType="image/png"/>');
    }
    buf.write('</Types>');
    final ct = buf.toString();

    const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';

    // word/_rels/document.xml.rels：图片关系（rId 从 100 起，避免与文档关系冲突）。
    final docRels = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    for (var i = 0; i < media.length; i++) {
      docRels.write(
          '<Relationship Id="rIdImg${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image${i + 1}.png"/>');
    }
    docRels.write('</Relationships>');

    final docXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document '
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '$bodyXml</w:document>';

    final archive = Archive();
    archive.addFile(ArchiveFile(
        '[Content_Types].xml', utf8.encode(ct).length, utf8.encode(ct)));
    archive.addFile(
        ArchiveFile('_rels/.rels', utf8.encode(rels).length, utf8.encode(rels)));
    archive.addFile(ArchiveFile(
        'word/document.xml', utf8.encode(docXml).length, utf8.encode(docXml)));
    if (media.isNotEmpty) {
      archive.addFile(ArchiveFile('word/_rels/document.xml.rels',
          utf8.encode(docRels.toString()).length,
          utf8.encode(docRels.toString())));
      for (var i = 0; i < media.length; i++) {
        final bytes = media[i];
        archive.addFile(
            ArchiveFile('word/media/image${i + 1}.png', bytes.length, bytes));
      }
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw Exception('DOCX 打包失败');
    }
    return Uint8List.fromList(encoded);
  }

  // ── PDF 生成 ─────────────────────────────────────────────────────

  List<pw.Widget> _memoPdf(Memo memo) {
    final widgets = <pw.Widget>[];
    if (memo.title.isNotEmpty) {
      widgets.add(pw.Text(memo.title,
          style: pw.TextStyle(
              fontSize: 20, fontWeight: pw.FontWeight.bold)));
      widgets.add(pw.SizedBox(height: 10));
    }
    for (final b in memo.blocks) {
      switch (b.type) {
        case 'h1':
          widgets.add(pw.Text(b.text,
              style: pw.TextStyle(
                  fontSize: 18, fontWeight: pw.FontWeight.bold)));
        case 'h2':
          widgets.add(pw.Text(b.text,
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)));
        case 'h3':
          widgets.add(pw.Text(b.text,
              style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.grey700)));
        case 'code':
          widgets.add(pw.Container(
            padding: const pw.EdgeInsets.all(6),
            decoration: const pw.BoxDecoration(color: PdfColors.grey300),
            child: pw.Text(b.text, style: const pw.TextStyle(fontSize: 10)),
          ));
        default:
          widgets.add(pw.Text(b.text,
              style: const pw.TextStyle(fontSize: 12)));
      }
      widgets.add(pw.SizedBox(height: 5));
    }
    return widgets;
  }

  List<pw.Widget> _notesPdf(
    List<Annotation> notes,
    String Function(Annotation) bookLabel,
  ) {
    final widgets = <pw.Widget>[
      pw.Text('读书笔记导出',
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text('导出时间：${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
      pw.SizedBox(height: 12),
    ];

    final grouped = <String, List<Annotation>>{};
    final order = <String>[];
    for (final a in notes) {
      final label = bookLabel(a);
      (grouped[label] ??= []).add(a);
      if (!order.contains(label)) order.add(label);
    }

    for (final label in order) {
      widgets.add(pw.Text(label,
          style:
              pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)));
      widgets.add(pw.SizedBox(height: 6));
      for (final a in grouped[label]!) {
        if (a.quotedText.isNotEmpty) {
          widgets.add(pw.Text('「${a.quotedText}」',
              style: const pw.TextStyle(
                  fontSize: 10, color: PdfColors.grey700)));
        }
        if (a.note.isNotEmpty) {
          widgets.add(pw.SizedBox(height: 2));
          widgets.add(
              pw.Text(a.note, style: const pw.TextStyle(fontSize: 12)));
        }
        final type = a.type == AnnotationType.highlight ? '高亮' : '笔记';
        widgets.add(pw.Text(
            '— $type · ${a.location} · ${DateFormat('yyyy-MM-dd').format(a.createdAt)}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500)));
        widgets.add(pw.SizedBox(height: 8));
      }
    }
    return widgets;
  }
}

/// Word 编辑版导出中间态：一段 [start,end) 区间及其源 run 与批注标记。
class _DocxSeg {
  int start;
  int end;
  DocxRun? run;
  DocxNote? note;

  _DocxSeg(this.start, this.end, this.run, this.note);
}
