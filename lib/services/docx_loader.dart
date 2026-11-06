import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// Word 高亮色名（ST_HighlightColor）→ 'RRGGBB'。
const Map<String, String> _highlightNamed = {
  'black': '000000',
  'blue': '0000FF',
  'cyan': '00FFFF',
  'green': '00FF00',
  'magenta': 'FF00FF',
  'red': 'FF0000',
  'yellow': 'FFFF00',
  'white': 'FFFFFF',
  'darkBlue': '000080',
  'darkCyan': '008080',
  'darkGreen': '008000',
  'darkMagenta': '800080',
  'darkRed': '800000',
  'darkYellow': '808000',
  'darkGray': '808080',
  'lightGray': 'C0C0C0',
};

/// 清洗 DOCX 颜色字符串：只接受 6 位十六进制（去 # 前缀，转大写）；
/// 'auto'、空串、色名、非法值一律返回 null，避免 `int.parse('0xFFauto')`
/// 之类的 FormatException 把整个页面打崩。
String? docxCleanColorHex(String? raw) {
  if (raw == null) return null;
  var v = raw.trim().replaceFirst('#', '');
  if (v.length == 8 && v.substring(0, 2).toUpperCase() == 'FF') {
    v = v.substring(2); // ARGB 的 FF 前缀
  }
  if (v.length != 6 || !RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(v)) return null;
  return v.toUpperCase();
}

/// 把 DOCX 颜色安全转成 [Color]；缺失/非法（如 'auto'）时退回 [fallback]。
Color docxColorOr(String? hex, Color fallback) {
  final v = docxCleanColorHex(hex);
  if (v == null) return fallback;
  return Color(0xFF000000 | int.parse(v, radix: 16));
}

/// 一个文本 run（Word 中格式变化的最小单元）。
class DocxRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 字号（pt）；null = 继承段落/阅读器默认字号。
  final double? fontSize;

  /// 文字颜色，如 'FF0000'（无 # 前缀）；null = 继承。
  final String? colorHex;

  /// 西文字体名（w:rFonts 的 ascii/hAnsi）；null = 继承。
  final String? fontFamily;

  /// 东亚字体名（w:rFonts 的 eastAsia）；中文等 CJK 文本用它。
  final String? eastAsiaFont;

  /// 高亮色（w:highlight / w:shd 已转成 'RRGGBB'）；null = 无高亮。
  final String? highlight;

  /// 上下标：'superscript' / 'subscript'；null = 正常。
  final String? vertAlign;

  const DocxRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSize,
    this.colorHex,
    this.fontFamily,
    this.eastAsiaFont,
    this.highlight,
    this.vertAlign,
  });

  /// 该 run 是否含 CJK 字符（选字体时优先 eastAsiaFont）。
  bool get hasCjk => _cjkRe.hasMatch(text);
  static final RegExp _cjkRe =
      RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

  /// 渲染用字体：中文优先东亚字体，否则西文字体。
  String? get effectiveFontFamily =>
      hasCjk ? (eastAsiaFont ?? fontFamily) : fontFamily;
}

/// 一侧边框（段落框线 / 表格框线）：保留线宽、颜色与线型。
class DocxBorderSide {
  /// 颜色 'RRGGBB'；null = 默认黑。
  final String? colorHex;

  /// 线宽（pt，按 w:sz 的 1/8 pt 换算），0.5~4 之间钳制。
  final double width;

  /// Word 线型（single/double/dashed/dotted/thick/thinThickSmallGap…）。
  final String style;

  const DocxBorderSide({
    this.colorHex,
    this.width = 0.75,
    this.style = 'single',
  });
}

/// 段落边框（w:pPr/w:pBdr）——每侧独立线宽/颜色/线型。
class DocxParaBorder {
  final DocxBorderSide? top;
  final DocxBorderSide? bottom;
  final DocxBorderSide? left;
  final DocxBorderSide? right;

  const DocxParaBorder({this.top, this.bottom, this.left, this.right});

  bool get any => top != null || bottom != null || left != null || right != null;
}

/// 表格框线（w:tblBorders）：外框四侧 + 内部横/竖线。
class DocxTableBorders {
  final DocxBorderSide? top;
  final DocxBorderSide? left;
  final DocxBorderSide? bottom;
  final DocxBorderSide? right;
  final DocxBorderSide? insideH;
  final DocxBorderSide? insideV;

  const DocxTableBorders({
    this.top,
    this.left,
    this.bottom,
    this.right,
    this.insideH,
    this.insideV,
  });

  bool get any =>
      top != null ||
      left != null ||
      bottom != null ||
      right != null ||
      insideH != null ||
      insideV != null;

  /// 第一个非空侧（兼容旧 borderColorHex/borderWidth 字段）。
  DocxBorderSide? get first => top ?? left ?? bottom ?? right ?? insideH ?? insideV;
}

/// 一个段落（保留对齐 + 段落样式 + runs 富文本 + 段落边框 + 段距/缩进）。
class DocxPara {
  final List<DocxRun> runs;

  /// 'left' / 'center' / 'right' / 'justify'。
  final String alignment;

  /// `w:pStyle` 的样式名（Heading1/2/3 或「标题」类样式识别用）。
  final String? styleName;

  /// 段落边框（w:pBdr）；null = 无框线。
  final DocxParaBorder? pBdr;

  /// 段前/段后间距（pt，w:spacing 的 before/after 换算）。
  final double spacingBeforePt;
  final double spacingAfterPt;

  /// 行距倍数（w:line + lineRule=auto，240 = 1 倍）；null = 阅读器行距。
  final double? lineSpacingMultiple;

  /// 固定行距（pt，lineRule=exact/atLeast）；null = 无。
  final double? lineSpacingPt;

  /// 左/右缩进（pt，w:ind 换算）。
  final double indentLeftPt;
  final double indentRightPt;

  /// 段落底纹（w:pPr/w:shd 的 fill 'RRGGBB'）；null = 无。
  final String? shadingHex;

  const DocxPara({
    this.runs = const [],
    this.alignment = 'left',
    this.styleName,
    this.pBdr,
    this.spacingBeforePt = 0,
    this.spacingAfterPt = 0,
    this.lineSpacingMultiple,
    this.lineSpacingPt,
    this.indentLeftPt = 0,
    this.indentRightPt = 0,
    this.shadingHex,
  });

  /// 段落纯文本 = 所有 runs 的 text 拼接（与 LoadedDocx.paragraphs 一一对应）。
  String get plainText => runs.map((r) => r.text).join();

  /// 段落基准字号 = 第一个显式设字号的 run；其余 run 渲染时按比例缩放，
  /// 这样阅读器字号设置只影响整体大小，段落内部的大小对比保持不变。
  double? get baseFontSize {
    for (final r in runs) {
      if (r.fontSize != null) return r.fontSize;
    }
    return null;
  }

  /// 标题识别：pStyle 以 Heading/标题 开头，或 run 加粗且字号 ≥ 14pt 且段落较短。
  bool get isTitle {
    final s = styleName;
    if (s != null) {
      final lower = s.toLowerCase();
      if (lower.startsWith('heading') || s.startsWith('标题')) return true;
    }
    final text = plainText;
    if (text.length >= 60) return false;
    return runs.any((r) => r.bold && (r.fontSize ?? 0) >= 14);
  }
}

/// 内容块的类型（按文档顺序渲染）。
enum DocxBlockType { para, table, textbox }

/// 一个内容块：段落 / 表格 / 文本框。
///
/// 段落仍然全部平铺在 [LoadedDocx.paragraphs] / [richParagraphs] 里
/// （与旧版一致，批注的 paraIndex 锚点不漂移）；块只是引用它们的下标
/// 区间并附带结构信息（表格的行列 / 框线），让渲染器按原始版式输出。
class DocxBlock {
  final DocxBlockType type;

  /// 块内第一个段落在扁平列表里的下标。
  final int paraStart;

  /// 块内段落的个数（para 块恒为 1）。
  final int paraCount;

  /// type=table：行 × 单元格（每个单元格 = 若干扁平段落下标）。
  final List<List<List<int>>>? cells;

  /// type=table：各侧框线（w:tblBorders / 表格样式）；null = 无显式框线。
  final DocxTableBorders? tableBorders;

  /// type=table：各列宽度比例（tblGrid 归一化）；null = 均分。
  final List<double>? colWidths;

  /// type=table：单元格底纹（与 cells 形状一致）'RRGGBB' 或 null。
  final List<List<String?>>? cellFills;

  /// type=table：单元格垂直对齐 'top'/'center'/'bottom'。
  final List<List<String>>? cellVAligns;

  /// type=table：表格对齐 'left'/'center'/'right'。
  final String? tableAlign;

  /// type=table：表格宽度百分比（tblW type=pct）；null = 占满可用宽度。
  final double? tableWidthPct;

  /// type=textbox：文本框描边颜色（v:shape 的 strokecolor）；null = 默认灰。
  final String? textboxStrokeColorHex;

  /// type=textbox：文本框描边宽度（pt，v:shape 的 strokeweight）；null = 1pt。
  final double? textboxStrokeWidthPt;

  /// type=textbox：文本框填充色（v:shape 的 fillcolor）；null = 透明。
  final String? textboxFillHex;

  /// type=table：是否有真实框线（w:tblBorders 显式定义或表格样式带边框）。
  /// false 时渲染器画淡色网格兜底（表格结构仍可见）。
  final bool bordered;

  /// 框线颜色 'RRGGBB'（取第一条非空侧）；null = 默认灰/黑。
  final String? borderColorHex;

  /// 框线宽度（pt，取第一条非空侧）。
  final double borderWidth;

  const DocxBlock({
    required this.type,
    required this.paraStart,
    required this.paraCount,
    this.cells,
    this.tableBorders,
    this.colWidths,
    this.cellFills,
    this.cellVAligns,
    this.tableAlign,
    this.tableWidthPct,
    this.textboxStrokeColorHex,
    this.textboxStrokeWidthPt,
    this.textboxFillHex,
    this.bordered = false,
    this.borderColorHex,
    this.borderWidth = 0.75,
  });
}

/// Parsed DOCX content, ready to render.
///
/// A DOCX file is a ZIP archive. We extract `word/document.xml` and collect
/// both the plain text of every `<w:p>` (paragraph) element and a rich
/// representation (runs with bold/italic/alignment/styles) so the reader can
/// preserve Word formatting.
class LoadedDocx {
  /// Paragraphs in reading order.  Empty paragraphs are preserved as empty
  /// strings so the renderer can insert blank-line spacing.
  final List<String> paragraphs;

  /// Rich paragraphs, same length and order as [paragraphs]; `paragraphs[i]`
  /// equals `richParagraphs[i].plainText`.
  final List<DocxPara> richParagraphs;

  /// 内容块（段落/表格/文本框，按文档顺序）。没有表格/文本框时就是
  /// 与段落一一对应的 para 块。
  final List<DocxBlock> blocks;

  /// 解析出的 word/document.xml 文档树（段落级编辑写回时使用）。
  final XmlDocument? document;

  /// 与 [paragraphs] 一一对应的 `<w:p>` 元素（段落级编辑定位用）。
  final List<XmlElement> paraElements;

  /// The author name from `docProps/core.xml`, if present.
  final String? author;

  const LoadedDocx({
    required this.paragraphs,
    this.richParagraphs = const [],
    this.blocks = const [],
    this.document,
    this.paraElements = const [],
    this.author,
  });
}

/// 表格样式（styles.xml 里 w:style[type=table] 的边框信息）。
class _TblStyle {
  final DocxTableBorders borders;
  const _TblStyle(this.borders);
  bool get bordered => borders.any;
}

/// Reads a .docx file and extracts paragraphs (plain + rich) plus tables,
/// textboxes and paragraph borders.
///
/// Uses [archive] (already in the dependency tree for EPUB) to unzip, then
/// [xml] to parse `word/document.xml`.
///
/// MS Word splits a single paragraph into multiple `<w:r>` (run) elements
/// whenever formatting changes, so each run keeps its own formatting.
class DocxLoader {
  const DocxLoader._();

  /// Open a .docx file from disk and extract its text content.
  static Future<LoadedDocx> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return open(bytes);
  }

  /// Parse raw bytes as a DOCX archive.
  static LoadedDocx open(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);

    // ── Main document ──────────────────────────────────────────────────
    final docXml = _readString(archive, 'word/document.xml');
    if (docXml == null) {
      throw const FormatException(
        '该文件不是有效的 DOCX（缺少 word/document.xml）',
      );
    }

    final document = XmlDocument.parse(docXml);
    final paragraphs = <String>[];
    final richParagraphs = <DocxPara>[];
    final paraElements = <XmlElement>[];
    final blocks = <DocxBlock>[];

    // 表格样式边框（styles.xml）：表格只引用样式时也认得出框线。
    final tblStyles = _parseTableStyles(_readString(archive, 'word/styles.xml'));

    final body = document.findAllElements('w:body').firstOrNull;
    if (body != null) {
      _walkBlocks(
          body, paragraphs, richParagraphs, paraElements, blocks, tblStyles);
    }

    if (paragraphs.isEmpty) {
      // Some minimal docx files have no <w:p> elements — unlikely but
      // handle gracefully.
      debugPrint('[Docx] no <w:p> elements in word/document.xml');
    }

    // 没有表格/文本框时，块 = 与段落一一对应的 para 块（渲染等价于旧版）。
    final effectiveBlocks = blocks.isEmpty
        ? <DocxBlock>[
            for (var i = 0; i < paragraphs.length; i++)
              DocxBlock(type: DocxBlockType.para, paraStart: i, paraCount: 1),
          ]
        : blocks;

    // ── Optional metadata ──────────────────────────────────────────────
    String? author;
    final coreXml = _readString(archive, 'docProps/core.xml');
    if (coreXml != null) {
      try {
        final core = XmlDocument.parse(coreXml);
        author = core
            .findAllElements('dc:creator')
            .map((e) => e.innerText.trim())
            .firstWhere((v) => v.isNotEmpty, orElse: () => '');
        if (author.isEmpty) author = null;
      } catch (_) {
        // Metadata is best-effort — never fail the whole parse for it.
      }
    }

    debugPrint('[Docx] ${paragraphs.length} paragraphs, ${blocks.length} blocks'
        '${author != null ? ', author: $author' : ''}');

    return LoadedDocx(
      paragraphs: paragraphs,
      richParagraphs: richParagraphs,
      blocks: effectiveBlocks,
      document: document,
      paraElements: paraElements,
      author: author,
    );
  }

  // ── 按文档顺序走块 ─────────────────────────────────────────────────

  /// 递归走某个容器（body / sdtContent / ins / del…）的直接子元素，
  /// 按文档顺序把 w:p / w:tbl 转成块；所有 w:p（含表格单元格、文本框
  /// 里的）都追加进扁平 paragraphs —— 与旧版 findAllElements 的顺序
  /// 完全一致，批注的 paraIndex 锚点不漂移。
  static void _walkBlocks(
    XmlElement container,
    List<String> paragraphs,
    List<DocxPara> richParagraphs,
    List<XmlElement> paraElements,
    List<DocxBlock> blocks,
    Map<String, _TblStyle> tblStyles,
  ) {
    for (final child in container.childElements) {
      final name = child.name.local;
      if (name == 'p') {
        final idx = _addPara(child, paragraphs, richParagraphs, paraElements);
        blocks.add(DocxBlock(
            type: DocxBlockType.para, paraStart: idx, paraCount: 1));
        // 段落里的文本框（w:drawing → w:txbxContent）：段落块之后
        // 紧接着放一个文本框块，里面的 w:p 同样进扁平列表。
        final txbxs = child.findAllElements('w:txbxContent').toList();
        if (txbxs.isNotEmpty) {
          final start = paragraphs.length;
          String? strokeHex;
          double? strokePt;
          String? fillHex;
          for (final txbx in txbxs) {
            final shape = _textboxShape(txbx);
            if (shape != null) {
              strokeHex ??= shape.colorHex;
              strokePt ??= shape.widthPt;
              fillHex ??= shape.fillHex;
            }
            for (final inner in txbx.childElements) {
              if (inner.name.local == 'p') {
                _addPara(inner, paragraphs, richParagraphs, paraElements);
              }
            }
          }
          if (paragraphs.length > start) {
            blocks.add(DocxBlock(
              type: DocxBlockType.textbox,
              paraStart: start,
              paraCount: paragraphs.length - start,
              textboxStrokeColorHex: strokeHex,
              textboxStrokeWidthPt: strokePt,
              textboxFillHex: fillHex,
            ));
          }
        }
      } else if (name == 'tbl') {
        blocks.add(_parseTable(
            child, paragraphs, richParagraphs, paraElements, tblStyles));
      } else if (name == 'sdt' ||
          name == 'sdtContent' ||
          name == 'ins' ||
          name == 'del' ||
          name == 'customXml' ||
          name == 'altChunk') {
        // 包装容器：继续往下一层找块。
        _walkBlocks(child, paragraphs, richParagraphs, paraElements, blocks,
            tblStyles);
      }
      // w:sectPr / w:bookmarkStart 等元数据直接忽略。
    }
  }

  /// 把一个 w:p 解析成 DocxPara 并追加进扁平列表，返回其下标。
  static int _addPara(
    XmlElement wp,
    List<String> paragraphs,
    List<DocxPara> richParagraphs,
    List<XmlElement> paraElements,
  ) {
    final para = _parsePara(wp);
    richParagraphs.add(para);
    paragraphs.add(para.plainText);
    paraElements.add(wp);
    return paragraphs.length - 1;
  }

  /// 解析一个 `<w:tbl>`：单元格文本按「行 × 单元格」组织，每个单元格的
  /// w:p 进扁平列表；框线来自 w:tblPr/w:tblBorders 或表格样式。
  ///
  /// 每行会归一化成**完全相同的列数**（Flutter Table 的硬性要求）：
  /// 合并单元格（w:gridSpan）展开成占位空格、行尾补空单元格——否则
  /// 行格子数参差不齐会抛 RangeError（RenderTable.setFlatChildren）。
  static DocxBlock _parseTable(
    XmlElement tbl,
    List<String> paragraphs,
    List<DocxPara> richParagraphs,
    List<XmlElement> paraElements,
    Map<String, _TblStyle> tblStyles,
  ) {
    final start = paragraphs.length;

    // 原始行：每个单元格 = （段落下标列表, 栅格跨度 gridSpan, 底纹, 垂直对齐）。
    final rawRows =
        <List<({List<int> paras, int span, String? fill, String vAlign})>>[];
    for (final tr in tbl.childElements) {
      if (tr.name.local != 'tr') continue;
      final rawRow = <({List<int> paras, int span, String? fill, String vAlign})>[];
      for (final tc in tr.childElements) {
        if (tc.name.local != 'tc') continue;
        final cell = <int>[];
        // 单元格内所有 w:p（含嵌套表格里的，与旧版扁平顺序一致）。
        for (final wp in tc.findAllElements('w:p')) {
          cell.add(_addPara(wp, paragraphs, richParagraphs, paraElements));
        }
        var span = 1;
        String? fill;
        var vAlign = 'center';
        final tcPr = _firstChild(tc, 'tcPr');
        if (tcPr != null) {
          final gridSpan = _firstChild(tcPr, 'gridSpan');
          if (gridSpan != null) {
            final v = int.tryParse(gridSpan.getAttribute('w:val') ?? '');
            if (v != null) span = v.clamp(1, 64);
          }
          final shd = _firstChild(tcPr, 'shd');
          if (shd != null) {
            final raw = shd.getAttribute('w:fill');
            if (raw != null && raw != 'auto') fill = docxCleanColorHex(raw);
          }
          final va = _firstChild(tcPr, 'vAlign')?.getAttribute('w:val');
          if (va != null &&
              (va == 'top' || va == 'bottom' || va == 'center')) {
            vAlign = va;
          }
        }
        rawRow.add((paras: cell, span: span, fill: fill, vAlign: vAlign));
      }
      if (rawRow.isNotEmpty) rawRows.add(rawRow);
    }

    // 列数 = 各行栅格跨度之和的最大值。
    var colCount = 0;
    for (final row in rawRows) {
      var total = 0;
      for (final c in row) {
        total += c.span;
      }
      if (total > colCount) colCount = total;
    }
    if (colCount < 1) colCount = 1;

    // 归一化：每行展开成恰好 colCount 格——合并单元格占位（内容放第一格，
    // 其余为空）、行尾不足补空单元格。这样 Flutter Table 每行格子数一致。
    final rows = <List<List<int>>>[];
    final fills = <List<String?>>[];
    final vAligns = <List<String>>[];
    for (final rawRow in rawRows) {
      final row = <List<int>>[];
      final fillRow = <String?>[];
      final vaRow = <String>[];
      for (final c in rawRow) {
        row.add(c.paras);
        fillRow.add(c.fill);
        vaRow.add(c.vAlign);
        for (var s = 1; s < c.span; s++) {
          row.add(const <int>[]);
          fillRow.add(null);
          vaRow.add('center');
        }
      }
      while (row.length < colCount) {
        row.add(const <int>[]);
        fillRow.add(null);
        vaRow.add('center');
      }
      rows.add(row);
      fills.add(fillRow);
      vAligns.add(vaRow);
    }

    // 列宽比例（w:tblGrid 的 gridCol w:w，dxa 归一化）。
    List<double>? colWidths;
    final grid = _firstChild(tbl, 'tblGrid');
    if (grid != null) {
      final ws = <double>[];
      for (final gc in grid.childElements) {
        if (gc.name.local != 'gridCol') continue;
        final v = double.tryParse(gc.getAttribute('w:w') ?? '');
        ws.add(v != null && v > 0 ? v : 0);
      }
      if (ws.isNotEmpty && ws.any((w) => w > 0)) {
        final sum = ws.fold<double>(0, (a, b) => a + b);
        var flexes = ws.map((w) => w > 0 ? w / sum : 0.0).toList();
        // 0 宽列给个极小值，避免渲染异常。
        flexes = flexes.map((w) => w <= 0 ? 0.001 : w).toList();
        if (flexes.length < colCount) {
          flexes = [
            ...flexes,
            for (var i = flexes.length; i < colCount; i++) 0.001,
          ];
        } else if (flexes.length > colCount) {
          flexes = flexes.sublist(0, colCount);
        }
        colWidths = flexes;
      }
    }

    // 框线解析：显式 tblBorders 优先，其次表格样式里的边框定义。
    DocxTableBorders? borders;
    final directSides = _parseBorderSides(_tblBordersElement(tbl));
    if (directSides.isNotEmpty) {
      borders = _tableBordersFrom(directSides);
    } else {
      final tblPr = _firstChild(tbl, 'tblPr');
      final styleId = tblPr == null
          ? null
          : _firstChild(tblPr, 'tblStyle')?.getAttribute('w:val');
      final style = styleId != null ? tblStyles[styleId] : null;
      if (style != null && style.bordered) {
        borders = style.borders;
      }
    }
    final bordered = borders != null && borders.any;
    final first = borders?.first;

    // 表格对齐（tblPr/jc）与宽度百分比（tblW type=pct）。
    String? tableAlign;
    double? tableWidthPct;
    final tblPr = _firstChild(tbl, 'tblPr');
    if (tblPr != null) {
      final jc = _firstChild(tblPr, 'jc')?.getAttribute('w:val');
      if (jc == 'center' || jc == 'right' || jc == 'left') tableAlign = jc;
      final tblW = _firstChild(tblPr, 'tblW');
      if (tblW != null && tblW.getAttribute('w:type') == 'pct') {
        final v = double.tryParse(tblW.getAttribute('w:w') ?? '');
        if (v != null) tableWidthPct = (v / 100.0).clamp(10.0, 100.0);
      }
    }

    return DocxBlock(
      type: DocxBlockType.table,
      paraStart: start,
      paraCount: paragraphs.length - start,
      cells: rows,
      tableBorders: borders,
      colWidths: colWidths,
      cellFills: fills,
      cellVAligns: vAligns,
      tableAlign: tableAlign,
      tableWidthPct: tableWidthPct,
      bordered: bordered,
      borderColorHex: first?.colorHex,
      borderWidth: first?.width ?? 0.75,
    );
  }

  static XmlElement? _firstChild(XmlElement el, String local) {
    for (final c in el.childElements) {
      if (c.name.local == local) return c;
    }
    return null;
  }

  /// 深度优先找第一个 local 名匹配的后代元素。
  static XmlElement? _firstDescendant(XmlElement el, String local) {
    for (final c in el.childElements) {
      if (c.name.local == local) return c;
      final inner = _firstDescendant(c, local);
      if (inner != null) return inner;
    }
    return null;
  }

  /// 文本框的 VML 形状（v:shape）：从 w:txbxContent 向上找所属的
  /// w:drawing，再取其下的 v:shape，读描边色/描边宽/填充色。
  static ({String? colorHex, double widthPt, String? fillHex})?
      _textboxShape(XmlElement txbx) {
    XmlNode? cur = txbx.parent;
    XmlElement? drawing;
    while (cur != null) {
      if (cur is XmlElement && cur.name.local == 'drawing') {
        drawing = cur;
        break;
      }
      cur = cur.parent;
    }
    if (drawing == null) return null;
    final shape = _firstDescendant(drawing, 'shape');
    if (shape == null) return null;
    final color = docxCleanColorHex(shape.getAttribute('strokecolor'));
    final fill = docxCleanColorHex(shape.getAttribute('fillcolor'));
    var width = 1.0;
    final wRaw = shape.getAttribute('strokeweight');
    if (wRaw != null) {
      final v = double.tryParse(wRaw.replaceAll('pt', '').trim());
      if (v != null && v > 0) width = v.clamp(0.5, 4.0);
    }
    return (colorHex: color, widthPt: width, fillHex: fill);
  }

  static XmlElement? _tblBordersElement(XmlElement tbl) {
    final tblPr = _firstChild(tbl, 'tblPr');
    return tblPr == null ? null : _firstChild(tblPr, 'tblBorders');
  }

  /// 边框集合（w:tblBorders / w:pBdr）→ 侧名 → 边框定义。
  /// val=none/nil 或缺失的侧不算；颜色经 [docxCleanColorHex] 清洗，
  /// 'auto' 等非法值不会流到渲染层。
  static Map<String, DocxBorderSide> _parseBorderSides(
      XmlElement? container) {
    final out = <String, DocxBorderSide>{};
    if (container == null) return out;
    for (final side in container.childElements) {
      final val = side.getAttribute('w:val');
      if (val == null || val == 'none' || val == 'nil') continue;
      final color = docxCleanColorHex(side.getAttribute('w:color'));
      var width = 0.75;
      final sz = int.tryParse(side.getAttribute('w:sz') ?? '');
      if (sz != null) width = (sz / 8.0).clamp(0.5, 4.0);
      out[side.name.local] = DocxBorderSide(
        colorHex: color,
        width: width,
        style: val,
      );
    }
    return out;
  }

  /// 侧名映射 → [DocxTableBorders]。
  static DocxTableBorders _tableBordersFrom(Map<String, DocxBorderSide> sides) {
    return DocxTableBorders(
      top: sides['top'],
      left: sides['left'],
      bottom: sides['bottom'],
      right: sides['right'],
      insideH: sides['insideH'],
      insideV: sides['insideV'],
    );
  }

  /// styles.xml → styleId → 表格样式边框（w:style[type=table] 的
  /// tblPr/tblBorders 或第一个 tblStylePr 的 tblBorders）。
  static Map<String, _TblStyle> _parseTableStyles(String? stylesXml) {
    final map = <String, _TblStyle>{};
    if (stylesXml == null || stylesXml.isEmpty) return map;
    try {
      final doc = XmlDocument.parse(stylesXml);
      for (final style in doc.findAllElements('w:style')) {
        if (style.getAttribute('w:type') != 'table') continue;
        final id = style.getAttribute('w:styleId');
        if (id == null) continue;
        DocxTableBorders? borders;
        // 直接在 style 下的 tblBorders。
        final direct = _parseBorderSides(_firstChild(style, 'tblBorders'));
        if (direct.isNotEmpty) borders = _tableBordersFrom(direct);
        // style → tblPr → tblBorders。
        final prSides =
            _parseBorderSides(_firstChild(_firstChild(style, 'tblPr') ?? style, 'tblBorders'));
        if (borders == null && prSides.isNotEmpty) {
          borders = _tableBordersFrom(prSides);
        }
        // 第一个 tblStylePr 的 tblBorders。
        if (borders == null) {
          for (final pr in style.findAllElements('w:tblStylePr')) {
            final s = _parseBorderSides(_firstChild(pr, 'tblBorders'));
            if (s.isNotEmpty) {
              borders = _tableBordersFrom(s);
              break;
            }
          }
        }
        if (borders != null && borders.any) {
          map[id] = _TblStyle(borders);
        }
      }
    } catch (e) {
      debugPrint('[Docx] parse styles.xml failed: $e');
    }
    return map;
  }

  /// 解析单个 `<w:p>`：读 pPr 的 jc/pStyle/pBdr/spacing/ind/shd，
  /// 再把 run 子节点收集成 [DocxRun]。
  static DocxPara _parsePara(XmlElement wp) {
    String? alignment;
    String? styleName;
    DocxParaBorder? pBdr;
    var spacingBeforePt = 0.0;
    var spacingAfterPt = 0.0;
    double? lineSpacingMultiple;
    double? lineSpacingPt;
    var indentLeftPt = 0.0;
    var indentRightPt = 0.0;
    String? shadingHex;

    XmlElement? pPr;
    for (final child in wp.childElements) {
      if (child.name.local == 'pPr') {
        pPr = child;
        break;
      }
    }

    if (pPr != null) {
      for (final child in pPr.childElements) {
        final name = child.name.local;
        if (name == 'jc') {
          final v = child.getAttribute('w:val');
          switch (v) {
            case 'center':
            case 'right':
            case 'justify':
              alignment = v;
              break;
            default:
              alignment = 'left';
          }
        } else if (name == 'pStyle') {
          styleName = child.getAttribute('w:val');
        } else if (name == 'pBdr') {
          // 段落框线（w:pBdr）：每侧独立线宽/颜色/线型。
          final sides = _parseBorderSides(child);
          if (sides.isNotEmpty) {
            pBdr = DocxParaBorder(
              top: sides['top'],
              bottom: sides['bottom'],
              left: sides['left'],
              right: sides['right'],
            );
          }
        } else if (name == 'spacing') {
          // before/after 单位是 1/20 pt；line 单位是 1/240 行。
          final before = int.tryParse(child.getAttribute('w:before') ?? '');
          if (before != null) spacingBeforePt = (before / 20.0).clamp(0, 200);
          final after = int.tryParse(child.getAttribute('w:after') ?? '');
          if (after != null) spacingAfterPt = (after / 20.0).clamp(0, 200);
          final line = int.tryParse(child.getAttribute('w:line') ?? '');
          if (line != null && line > 0) {
            final rule = child.getAttribute('w:lineRule');
            if (rule == 'exact' || rule == 'atLeast') {
              lineSpacingPt = line / 20.0;
            } else {
              lineSpacingMultiple = (line / 240.0).clamp(0.5, 5.0);
            }
          }
        } else if (name == 'ind') {
          // w:ind 单位 1/20 pt；left/start 与 right/end 兼容中英文版式。
          final left = int.tryParse(
                  child.getAttribute('w:left') ?? child.getAttribute('w:start') ?? '');
          if (left != null) indentLeftPt = (left / 20.0).clamp(0, 600);
          final right = int.tryParse(
                  child.getAttribute('w:right') ?? child.getAttribute('w:end') ?? '');
          if (right != null) indentRightPt = (right / 20.0).clamp(0, 600);
        } else if (name == 'shd') {
          final fill = child.getAttribute('w:fill');
          if (fill != null && fill != 'auto') {
            shadingHex = docxCleanColorHex(fill);
          }
        }
      }
    }

    final runs = <DocxRun>[];
    // 从 w:p 本身开始递归收集：w:p 的直接子元素 w:r 走 _parseRun，
    // w:hyperlink / sdt / smartTag 等包装再往下一层找 w:r；drawing /
    // txbxContent（文本框）与 tbl（内嵌表格）不收集——它们的 w:p 由
    // 块级遍历单独处理，避免文本框文字被重复收集进外层段落。
    _collectRuns(wp, runs);

    return DocxPara(
      runs: runs,
      alignment: alignment ?? 'left',
      styleName: styleName,
      pBdr: pBdr,
      spacingBeforePt: spacingBeforePt,
      spacingAfterPt: spacingAfterPt,
      lineSpacingMultiple: lineSpacingMultiple,
      lineSpacingPt: lineSpacingPt,
      indentLeftPt: indentLeftPt,
      indentRightPt: indentRightPt,
      shadingHex: shadingHex,
    );
  }

  /// 递归收集子树里的 `<w:r>`（含 hyperlink / sdt / smartTag 等包装）。
  static void _collectRuns(XmlElement el, List<DocxRun> out) {
    for (final child in el.childElements) {
      final name = child.name.local;
      if (name == 'r') {
        out.add(_parseRun(child));
      } else if (name == 'pPr' ||
          name == 'rPr' ||
          name == 'pPrChange' ||
          name == 'rPrChange' ||
          name == 'proofErr' ||
          name == 'bookmarkStart' ||
          name == 'bookmarkEnd' ||
          name == 'drawing' ||
          name == 'pict' ||
          name == 'txbxContent' ||
          name == 'tbl' ||
          name == 'object') {
        // 属性/书签/文本框/内嵌表格等：不含本段可见文本。
      } else {
        _collectRuns(child, out);
      }
    }
  }

  /// 解析单个 `<w:r>`：读 rPr 属性 + 拼接可见文本（t / tab / br / cr）。
  static DocxRun _parseRun(XmlElement wr) {
    var bold = false;
    var italic = false;
    var underline = false;
    var strike = false;
    double? fontSize;
    String? colorHex;
    String? fontFamily;
    String? eastAsiaFont;
    String? highlight;
    String? vertAlign;
    final buf = StringBuffer();

    for (final child in wr.childElements) {
      switch (child.name.local) {
        case 'rPr':
          for (final p in child.childElements) {
            final name = p.name.local;
            final val = p.getAttribute('w:val');
            if (name == 'b' || name == 'bCs') {
              if (val == null || (val != 'false' && val != '0')) bold = true;
            } else if (name == 'i' || name == 'iCs') {
              if (val == null || (val != 'false' && val != '0')) italic = true;
            } else if (name == 'u') {
              // val 非 none（含无 val 的裸 <w:u/>）视为下划线。
              if (val == null || (val != 'none' && val != 'false' && val != '0')) {
                underline = true;
              }
            } else if (name == 'strike') {
              if (val == null || (val != 'false' && val != '0')) strike = true;
            } else if (name == 'sz') {
              final hv = int.tryParse(val ?? '');
              if (hv != null) fontSize = hv / 2.0;
            } else if (name == 'color') {
              // 'auto'、色名、非法值都会被清洗成 null，不再进渲染层。
              colorHex = docxCleanColorHex(val);
            } else if (name == 'rFonts') {
              fontFamily =
                  p.getAttribute('w:ascii') ?? p.getAttribute('w:hAnsi');
              eastAsiaFont = p.getAttribute('w:eastAsia');
            } else if (name == 'highlight') {
              if (val != null && val != 'none') {
                highlight = _highlightNamed[val] ?? docxCleanColorHex(val);
              }
            } else if (name == 'shd') {
              final fill = p.getAttribute('w:fill');
              if (fill != null && fill != 'auto') {
                highlight = docxCleanColorHex(fill);
              }
            } else if (name == 'vertAlign') {
              if (val == 'superscript' || val == 'subscript') vertAlign = val;
            }
          }
          break;
        case 't':
          buf.write(child.innerText);
          break;
        case 'tab':
          buf.write('\t');
          break;
        case 'br':
        case 'cr':
          buf.write('\n');
          break;
      }
    }

    return DocxRun(
      text: buf.toString(),
      bold: bold,
      italic: italic,
      underline: underline,
      strike: strike,
      fontSize: fontSize,
      colorHex: colorHex,
      fontFamily: fontFamily,
      eastAsiaFont: eastAsiaFont,
      highlight: highlight,
      vertAlign: vertAlign,
    );
  }

  /// Read a UTF-8 string from a ZIP entry, returning null if absent.
  static String? _readString(Archive archive, String path) {
    final file = archive.findFile(path) ??
        archive.findFile(Uri.decodeComponent(path));
    if (file == null) return null;
    final content = file.content;
    final bytes =
        content is Uint8List ? content : Uint8List.fromList(content as List<int>);
    // DOCX XML is always UTF-8.
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }
}
