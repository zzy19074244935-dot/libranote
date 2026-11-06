import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'docx_loader.dart';

/// Word（DOCX）段落级编辑 + 写回原文件。
///
/// 编辑基于 [DocxLoader] 解析时保留的 XML 文档树与段落元素映射
/// （[LoadedDocx.document] / [LoadedDocx.paraElements]）：
/// - 改文字 = 替换该 `<w:p>` 的文本 run（保留 pPr 与 drawing/pict 等
///   非文本内容，文本框/图片不会被误删）；
/// - 插入 = 在目标段落前/后新建一个 `<w:p>`；
/// - 删除 = 把 `<w:p>` 从父节点摘除。
/// 每次操作后把 document.xml 重新序列化，写回原 DOCX zip（其余条目
/// 原样保留），再原子替换原文件。
class DocxEditService {
  DocxEditService._();

  /// 把 [paraIndex] 段落的文字替换为 [newText]（换行 → w:br），写回
  /// [docxPath] 指向的 DOCX 文件。
  static Future<void> setParagraphText({
    required LoadedDocx doc,
    required int paraIndex,
    required String newText,
    required String docxPath,
  }) async {
    final wp = _paraElement(doc, paraIndex);

    // 摘掉文本承载子节点（r / hyperlink / sdt 等），保留 pPr、drawing、
    // pict、书签等非文本内容——文本框和图片不能被误删。注意：w:drawing /
    // w:pict / w:object 包在 w:r 里（文本框就是这么存的），含这些内容的
    // run 必须保留。
    bool hasNonTextContent(XmlElement el) =>
        el.findAllElements('w:drawing').isNotEmpty ||
        el.findAllElements('w:pict').isNotEmpty ||
        el.findAllElements('w:object').isNotEmpty;
    final toRemove = <XmlNode>[];
    for (final child in wp.children) {
      if (child is XmlElement) {
        final name = child.name.local;
        if (name == 'r') {
          if (!hasNonTextContent(child)) toRemove.add(child);
        } else if (name == 'hyperlink' ||
            name == 'sdt' ||
            name == 'smartTag' ||
            name == 'ins' ||
            name == 'del') {
          if (!hasNonTextContent(child)) toRemove.add(child);
        }
      }
    }
    for (final n in toRemove) {
      wp.children.remove(n);
    }

    // 新 run（换行拆成 w:br），插到 pPr 之后。
    final run = _buildRun(newText);
    var insertAt = 0;
    for (var i = 0; i < wp.children.length; i++) {
      final c = wp.children[i];
      if (c is XmlElement && c.name.local == 'pPr') {
        insertAt = i + 1;
        break;
      }
    }
    wp.children.insert(insertAt, run);

    await _writeBack(doc, docxPath);
  }

  /// 在 [paraIndex] 段落之前（[after]=false）或之后（true）插入一个新
  /// 段落，写回文件。段落基本样式继承邻近段落（pPr 原样复制）。
  static Future<void> insertParagraph({
    required LoadedDocx doc,
    required int paraIndex,
    required String newText,
    required String docxPath,
    bool after = false,
  }) async {
    final anchor = _paraElement(doc, paraIndex);
    final parent = anchor.parent;
    if (parent == null) {
      throw const FormatException('找不到段落容器，无法插入');
    }

    final newP = XmlElement(XmlName('p', 'w'));
    // 继承锚点段落的 pPr（对齐/样式），让新段落格式协调。
    for (final child in anchor.childElements) {
      if (child.name.local == 'pPr') {
        newP.children.add(child.copy());
        break;
      }
    }
    newP.children.add(_buildRun(newText));

    final siblings = parent.children;
    final idx = siblings.indexOf(anchor);
    if (idx < 0) {
      throw const FormatException('段落不在容器内，无法插入');
    }
    siblings.insert(after ? idx + 1 : idx, newP);

    await _writeBack(doc, docxPath);
  }

  /// 删除 [paraIndex] 段落，写回文件。整个文档只剩这一段时拒绝删除。
  static Future<void> deleteParagraph({
    required LoadedDocx doc,
    required int paraIndex,
    required String docxPath,
  }) async {
    if (doc.paragraphs.length <= 1) {
      throw const FormatException('至少保留一个段落');
    }
    final wp = _paraElement(doc, paraIndex);
    final parent = wp.parent;
    if (parent == null) {
      throw const FormatException('找不到段落容器，无法删除');
    }
    parent.children.remove(wp);
    await _writeBack(doc, docxPath);
  }

  /// 在文档正文末尾（sectPr 之前）追加一个新段落，写回文件。
  /// 保证插在顶层，不会插进表格单元格或文本框里。
  static Future<void> appendParagraph({
    required LoadedDocx doc,
    required String newText,
    required String docxPath,
  }) async {
    final document = doc.document;
    if (document == null) {
      throw const FormatException('文档树缺失，无法写回');
    }
    final body = document.findAllElements('w:body').firstOrNull;
    if (body == null) {
      throw const FormatException('找不到 body，无法追加');
    }
    final newP = XmlElement(XmlName('p', 'w'));
    newP.children.add(_buildRun(newText));
    final children = body.children;
    var insertAt = children.length;
    for (var i = children.length - 1; i >= 0; i--) {
      final c = children[i];
      if (c is XmlElement && c.name.local == 'sectPr') {
        insertAt = i;
      }
    }
    children.insert(insertAt, newP);
    await _writeBack(doc, docxPath);
  }

  /// 设置 [paraIndex] 段落的段落格式（对齐 / 段前段后间距 / 左右缩进），
  /// 写回文件。传 null 的项保持原样；alignment='left' 表示清除对齐。
  static Future<void> setParagraphFormat({
    required LoadedDocx doc,
    required int paraIndex,
    required String docxPath,
    String? alignment,
    double? spacingBeforePt,
    double? spacingAfterPt,
    double? indentLeftPt,
    double? indentRightPt,
  }) async {
    final wp = _paraElement(doc, paraIndex);
    final pPr = _ensurePPr(wp);

    if (alignment != null) {
      _removeByName(pPr, 'jc');
      if (alignment != 'left') {
        pPr.children.add(XmlElement(XmlName('jc', 'w'),
            [XmlAttribute(XmlName('val', 'w'), alignment)]));
      }
    }

    if (spacingBeforePt != null || spacingAfterPt != null) {
      XmlElement? spacing = _firstChild(pPr, 'spacing');
      if (spacing == null) {
        spacing = XmlElement(XmlName('spacing', 'w'));
        pPr.children.add(spacing);
      }
      _setAttr(spacing, 'before',
          spacingBeforePt != null ? '${(spacingBeforePt * 20).round()}' : null);
      _setAttr(spacing, 'after',
          spacingAfterPt != null ? '${(spacingAfterPt * 20).round()}' : null);
    }

    if (indentLeftPt != null || indentRightPt != null) {
      XmlElement? ind = _firstChild(pPr, 'ind');
      if (ind == null) {
        ind = XmlElement(XmlName('ind', 'w'));
        pPr.children.add(ind);
      }
      // left/start、right/end 同时写，中英文版式都生效。
      _setAttr(ind, 'left',
          indentLeftPt != null ? '${(indentLeftPt * 20).round()}' : null);
      _setAttr(ind, 'start',
          indentLeftPt != null ? '${(indentLeftPt * 20).round()}' : null);
      _setAttr(ind, 'right',
          indentRightPt != null ? '${(indentRightPt * 20).round()}' : null);
      _setAttr(ind, 'end',
          indentRightPt != null ? '${(indentRightPt * 20).round()}' : null);
    }

    await _writeBack(doc, docxPath);
  }

  /// 设置 [paraIndex] 段落内所有文本 run 的字符格式（B/I/U/删除线/字号/
  /// 颜色/高亮/字体），写回文件。
  /// - bool 属性传 null = 不改变；false = 关掉；true = 打开。
  /// - fontSizePt 传值 = 统一字号；null = 不改变。
  /// - colorHex / highlight / fontFamily 传空字符串 = 清除；null = 不改变。
  static Future<void> setRunFormat({
    required LoadedDocx doc,
    required int paraIndex,
    required String docxPath,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    double? fontSizePt,
    String? colorHex,
    String? highlight,
    String? fontFamily,
  }) async {
    final wp = _paraElement(doc, paraIndex);
    // 只收集本段正文的 run：文本框（drawing/txbxContent）、图片（pict）、
    // 内嵌对象里的 run 不属于本段文字，不动它们。
    final runs = <XmlElement>[];
    _collectTextRuns(wp, runs);
    for (final r in runs) {
      final rPr = _ensureRPr(r);
      if (bold != null) _setBool(rPr, 'b', bold);
      if (italic != null) _setBool(rPr, 'i', italic);
      if (underline != null) {
        _removeByName(rPr, 'u');
        rPr.children.add(XmlElement(XmlName('u', 'w'), [
          XmlAttribute(
              XmlName('val', 'w'), underline ? 'single' : 'none'),
        ]));
      }
      if (strike != null) _setBool(rPr, 'strike', strike);
      if (fontSizePt != null) {
        final half = (fontSizePt * 2).round().clamp(2, 400);
        _removeByName(rPr, 'sz');
        _removeByName(rPr, 'szCs');
        rPr.children.add(XmlElement(XmlName('sz', 'w'),
            [XmlAttribute(XmlName('val', 'w'), '$half')]));
        rPr.children.add(XmlElement(XmlName('szCs', 'w'),
            [XmlAttribute(XmlName('val', 'w'), '$half')]));
      }
      if (colorHex != null) {
        _removeByName(rPr, 'color');
        if (colorHex.isNotEmpty) {
          rPr.children.add(XmlElement(XmlName('color', 'w'),
              [XmlAttribute(XmlName('val', 'w'), colorHex.toUpperCase())]));
        }
      }
      if (highlight != null) {
        _removeByName(rPr, 'highlight');
        _removeByName(rPr, 'shd');
        if (highlight.isNotEmpty) {
          // 用 w:shd 而不是 w:highlight：任意 RGB 都能表达。
          rPr.children.add(XmlElement(XmlName('shd', 'w'), [
            XmlAttribute(XmlName('val', 'w'), 'clear'),
            XmlAttribute(XmlName('color', 'w'), 'auto'),
            XmlAttribute(XmlName('fill', 'w'), highlight.toUpperCase()),
          ]));
        }
      }
      if (fontFamily != null) {
        _removeByName(rPr, 'rFonts');
        if (fontFamily.isNotEmpty) {
          rPr.children.add(XmlElement(XmlName('rFonts', 'w'), [
            XmlAttribute(XmlName('ascii', 'w'), fontFamily),
            XmlAttribute(XmlName('hAnsi', 'w'), fontFamily),
            XmlAttribute(XmlName('eastAsia', 'w'), fontFamily),
          ]));
        }
      }
    }
    await _writeBack(doc, docxPath);
  }

  // ── 内部工具 ───────────────────────────────────────────────────────

  static XmlElement _paraElement(LoadedDocx doc, int paraIndex) {
    if (paraIndex < 0 || paraIndex >= doc.paraElements.length) {
      throw const FormatException('段落下标越界');
    }
    return doc.paraElements[paraIndex];
  }

  /// 取（没有则创建并插到最前）w:p 的 w:pPr。
  static XmlElement _ensurePPr(XmlElement wp) {
    for (final c in wp.children) {
      if (c is XmlElement && c.name.local == 'pPr') return c;
    }
    final pPr = XmlElement(XmlName('pPr', 'w'));
    wp.children.insert(0, pPr);
    return pPr;
  }

  /// 取（没有则创建并插到最前）w:r 的 w:rPr。
  static XmlElement _ensureRPr(XmlElement run) {
    for (final c in run.children) {
      if (c is XmlElement && c.name.local == 'rPr') return c;
    }
    final rPr = XmlElement(XmlName('rPr', 'w'));
    run.children.insert(0, rPr);
    return rPr;
  }

  static XmlElement? _firstChild(XmlElement el, String local) {
    for (final c in el.children) {
      if (c is XmlElement && c.name.local == local) return c;
    }
    return null;
  }

  static void _removeByName(XmlElement parent, String local) {
    final toRemove = <XmlNode>[];
    for (final c in parent.children) {
      if (c is XmlElement && c.name.local == local) toRemove.add(c);
    }
    for (final n in toRemove) {
      parent.children.remove(n);
    }
  }

  /// 设置/删除属性；[value] 为 null 时删除该属性。
  static void _setAttr(XmlElement el, String name, String? value) {
    el.attributes.removeWhere((a) => a.name.local == name);
    if (value != null) {
      el.attributes.add(XmlAttribute(XmlName(name, 'w'), value));
    }
  }

  /// 开 = 裸 <w:b/>，关 = <w:b w:val="false"/>（压过样式表里的粗体）。
  static void _setBool(XmlElement rPr, String name, bool on) {
    _removeByName(rPr, name);
    final el = XmlElement(XmlName(name, 'w'));
    if (!on) el.attributes.add(XmlAttribute(XmlName('val', 'w'), 'false'));
    rPr.children.add(el);
  }

  /// 收集段落正文里的文本 run（跳过 drawing/pict/txbxContent/object 里
  /// 的 run——文本框和图片内容不属于本段文字）。
  static void _collectTextRuns(XmlElement el, List<XmlElement> out) {
    for (final child in el.childElements) {
      final name = child.name.local;
      if (name == 'r') {
        out.add(child);
      } else if (name == 'pPr' ||
          name == 'rPr' ||
          name == 'proofErr' ||
          name == 'bookmarkStart' ||
          name == 'bookmarkEnd' ||
          name == 'drawing' ||
          name == 'pict' ||
          name == 'txbxContent' ||
          name == 'object') {
        continue;
      } else {
        _collectTextRuns(child, out);
      }
    }
  }

  /// 把一段文字编码成单个 `<w:r>`（换行 → `<w:br/>`）。
  static XmlElement _buildRun(String text) {
    final run = XmlElement(XmlName('r', 'w'));
    final pieces = text.split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) {
        run.children.add(XmlElement(XmlName('br', 'w')));
      }
      run.children.add(XmlElement(XmlName('t', 'w'), [], [XmlText(pieces[i])]));
    }
    return run;
  }

  /// 把（可能已修改的）document.xml 重新序列化，写回 DOCX zip，
  /// 原子替换原文件。
  static Future<void> _writeBack(LoadedDocx doc, String docxPath) async {
    final document = doc.document;
    if (document == null) {
      throw const FormatException('文档树缺失，无法写回');
    }
    final src = File(docxPath);
    if (!await src.exists()) {
      throw const FormatException('原文件不存在，无法写回');
    }
    final original = await src.readAsBytes();
    final archive = ZipDecoder().decodeBytes(original);

    final out = Archive();
    for (final entry in archive.files) {
      final name = entry.name;
      if (name == 'word/document.xml' ||
          name == Uri.decodeComponent('word/document.xml')) {
        out.addFile(ArchiveFile.string(
          'word/document.xml',
          document.toXmlString(),
        ));
      } else {
        out.addFile(entry);
      }
    }

    final data = Uint8List.fromList(ZipEncoder().encode(out)!);
    final dir = p.dirname(docxPath);
    final tmp = File(p.join(dir,
        '.${p.basename(docxPath)}.editing_${DateTime.now().millisecondsSinceEpoch}.tmp'));
    await tmp.writeAsBytes(data, flush: true);
    try {
      await tmp.rename(docxPath);
    } catch (_) {
      // 个别平台 rename 覆盖已有文件受限 → 直接覆盖写。
      await src.writeAsBytes(data, flush: true);
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
    debugPrint('[DocxEdit] wrote back $docxPath (${data.length} bytes)');
  }
}
