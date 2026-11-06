import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:libranote/services/docx_edit_service.dart';
import 'package:libranote/services/docx_loader.dart';

void main() {
  test('DocxLoader parses a minimal DOCX', () {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'mimetype',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
    ));
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/><w:jc w:val="center"/></w:pPr>
      <w:r><w:rPr><w:b/><w:sz w:val="32"/></w:rPr><w:t>标题</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:rPr><w:i/></w:rPr><w:t>正文</w:t></w:r>
      <w:r><w:t>加粗</w:t></w:r>
    </w:p>
  </w:body>
</w:document>''',
    ));
    final encoder = ZipEncoder();
    final bytes = Uint8List.fromList(encoder.encode(archive)!);

    final doc = DocxLoader.open(bytes);
    expect(doc.paragraphs.length, 2);
    expect(doc.paragraphs[0], '标题');
    expect(doc.paragraphs[1], '正文加粗');
    expect(doc.richParagraphs.length, 2);
    expect(doc.richParagraphs[0].isTitle, isTrue);
    expect(doc.richParagraphs[1].runs.first.italic, isTrue);
  });

  test('DocxLoader rejects non-zip junk', () {
    expect(
      () => DocxLoader.open(Uint8List.fromList('not a docx at all'.codeUnits)),
      throwsA(anything),
    );
  });

  test('DocxLoader normalizes merged-cell (gridSpan) table rows', () {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tblPr><w:tblBorders>
        <w:top w:val="single"/><w:left w:val="single"/>
        <w:bottom w:val="single"/><w:right w:val="single"/>
      </w:tblBorders></w:tblPr>
      <w:tr>
        <w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
          <w:p><w:r><w:t>跨两列</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>第三列</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>甲</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>乙</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>丙</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''',
    ));
    final doc = DocxLoader.open(
        Uint8List.fromList(ZipEncoder().encode(archive)!));

    expect(doc.blocks.length, 1);
    final table = doc.blocks[0];
    expect(table.type, DocxBlockType.table);
    expect(table.cells!.length, 2);
    // 归一化后每行都是 3 格（合并单元格展开占位）。
    expect(table.cells![0].length, 3);
    expect(table.cells![1].length, 3);
    expect(table.cells![0][0].isNotEmpty, isTrue); // 跨两列的内容
    expect(table.cells![0][1], isEmpty); // 占位空格
    expect(table.cells![0][2].isNotEmpty, isTrue); // 第三列
    // 扁平文本顺序不变。
    expect(doc.paragraphs, ['跨两列', '第三列', '甲', '乙', '丙']);
  });

  test('DocxLoader keeps tables/textboxes/paragraph borders as blocks', () {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>表格前一段</w:t></w:r></w:p>
    <w:tbl>
      <w:tblPr>
        <w:tblBorders>
          <w:top w:val="single" w:sz="8" w:color="FF0000"/>
          <w:left w:val="single" w:sz="8" w:color="FF0000"/>
          <w:bottom w:val="single" w:sz="8" w:color="FF0000"/>
          <w:right w:val="single" w:sz="8" w:color="FF0000"/>
        </w:tblBorders>
      </w:tblPr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>甲1</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>乙1</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>甲2</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>乙2</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:p>
      <w:pPr><w:pBdr><w:bottom w:val="single" w:sz="12" w:color="0000FF"/></w:pBdr></w:pPr>
      <w:r><w:t>带下框线的段落</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>外层段落</w:t></w:r>
      <w:r>
        <w:drawing>
          <w:txbxContent>
            <w:p><w:r><w:t>文本框里的文字</w:t></w:r></w:p>
          </w:txbxContent>
        </w:drawing>
      </w:r>
    </w:p>
    <w:p><w:r><w:t>结尾段</w:t></w:r></w:p>
  </w:body>
</w:document>''',
    ));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final doc = DocxLoader.open(bytes);

    // 扁平段落仍按文档顺序包含全部 w:p（表格单元格 + 文本框里的也算）。
    expect(doc.paragraphs, [
      '表格前一段',
      '甲1',
      '乙1',
      '甲2',
      '乙2',
      '带下框线的段落',
      '外层段落',
      '文本框里的文字',
      '结尾段',
    ]);

    // 外层段落不再把文本框文字重复收集进自己的 runs。
    expect(doc.richParagraphs[6].plainText, '外层段落');
    expect(doc.richParagraphs[6].runs.length, 2); // 第二个 run 只包 drawing，文本为空
    expect(doc.richParagraphs[6].runs.last.text, isEmpty);

    // 块结构：para / table / para / para / textbox / para。
    expect(doc.blocks.length, 6);
    expect(doc.blocks[0].type, DocxBlockType.para);
    final table = doc.blocks[1];
    expect(table.type, DocxBlockType.table);
    expect(table.bordered, isTrue);
    expect(table.borderColorHex, 'FF0000');
    expect(table.cells!.length, 2); // 两行
    expect(table.cells![0].length, 2); // 两列
    expect(table.paraStart, 1);
    expect(table.paraCount, 4);
    expect(doc.blocks[4].type, DocxBlockType.textbox);
    expect(doc.blocks[4].paraStart, 7);
    expect(doc.blocks[4].paraCount, 1);

    // 段落边框保留（新模型：每侧独立线宽/颜色/线型）。
    final bordered = doc.richParagraphs[5];
    expect(bordered.pBdr, isNotNull);
    expect(bordered.pBdr!.bottom, isNotNull);
    expect(bordered.pBdr!.top, isNull);
    expect(bordered.pBdr!.bottom!.colorHex, '0000FF');
  });

  test('DocxLoader survives "auto" border colors and keeps side widths/fonts', () {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tblPr>
        <w:tblW w:w="5000" w:type="pct"/>
        <w:jc w:val="center"/>
        <w:tblBorders>
          <w:top w:val="single" w:sz="24" w:color="auto"/>
          <w:left w:val="dashed" w:sz="16" w:color="FF00FF"/>
          <w:insideH w:val="single" w:sz="4" w:color="00FF00"/>
        </w:tblBorders>
      </w:tblPr>
      <w:tblGrid>
        <w:gridCol w:w="3000"/><w:gridCol w:w="6000"/>
      </w:tblGrid>
      <w:tr>
        <w:tc><w:tcPr><w:shd w:val="clear" w:fill="FFFF00"/><w:vAlign w:val="top"/></w:tcPr>
          <w:p>
            <w:pPr><w:spacing w:before="240" w:after="120"/><w:ind w:left="600"/></w:pPr>
            <w:r><w:rPr><w:rFonts w:ascii="Arial" w:eastAsia="宋体"/><w:sz w:val="24"/><w:highlight w:val="yellow"/></w:rPr><w:t>甲</w:t></w:r>
          </w:p></w:tc>
        <w:tc><w:p><w:r><w:t>乙</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:p>
      <w:pPr><w:pBdr>
        <w:top w:val="single" w:sz="32" w:color="auto"/>
        <w:bottom w:val="dotted" w:sz="8" w:color="123456"/>
      </w:pBdr></w:pPr>
      <w:r><w:t>带框段落</w:t></w:r>
    </w:p>
  </w:body>
</w:document>''',
    ));
    final doc = DocxLoader.open(
        Uint8List.fromList(ZipEncoder().encode(archive)!));

    final table = doc.blocks[0];
    expect(table.type, DocxBlockType.table);

    // 崩溃回归：w:color="auto" 必须被清洗为 null，不能流到渲染层。
    final tb = table.tableBorders!;
    expect(tb.top, isNotNull);
    expect(tb.top!.colorHex, isNull);
    expect(tb.left!.colorHex, 'FF00FF');
    expect(tb.left!.style, 'dashed');
    expect(tb.insideH!.colorHex, '00FF00');
    expect(table.borderColorHex, isNull); // 第一条非空侧（top）是 auto
    // 每侧线宽独立保留（sz/8 pt）。
    expect(tb.top!.width, 3.0);
    expect(tb.left!.width, 2.0);
    expect(tb.insideH!.width, 0.5);

    // 表格对齐 / 宽度百分比 / 列宽比例。
    expect(table.tableAlign, 'center');
    expect(table.tableWidthPct, 50.0);
    expect(table.colWidths, isNotNull);
    expect(table.colWidths![0], closeTo(1 / 3, 1e-6));
    expect(table.colWidths![1], closeTo(2 / 3, 1e-6));

    // 单元格底纹 + 垂直对齐。
    expect(table.cellFills![0][0], 'FFFF00');
    expect(table.cellVAligns![0][0], 'top');

    // 段距/缩进（pt）。
    final para = doc.richParagraphs[0];
    expect(para.spacingBeforePt, 12.0);
    expect(para.spacingAfterPt, 6.0);
    expect(para.indentLeftPt, 30.0);

    // run 字体/字号/高亮（色名 yellow → hex）。
    final run = para.runs.first;
    expect(run.fontFamily, 'Arial');
    expect(run.eastAsiaFont, '宋体');
    expect(run.fontSize, 12.0);
    expect(run.highlight, 'FFFF00');
    expect(run.effectiveFontFamily, '宋体'); // CJK 文本用东亚字体

    // 段落边框：auto 清洗 + 线宽钳制（32/8=4pt 顶格）。
    final pBdr = doc.richParagraphs[2].pBdr!;
    expect(pBdr.top!.colorHex, isNull);
    expect(pBdr.top!.width, 4.0);
    expect(pBdr.bottom!.colorHex, '123456');
    expect(pBdr.bottom!.style, 'dotted');
    expect(pBdr.bottom!.width, 1.0);

    // 渲染层兜底：auto → fallback 色，不抛 FormatException。
    expect(docxColorOr('auto', const Color(0xFF595959)),
        const Color(0xFF595959));
    expect(docxColorOr(null, const Color(0xFF595959)),
        const Color(0xFF595959));
    expect(docxColorOr('FFauto', const Color(0xFF595959)),
        const Color(0xFF595959));
    expect(docxColorOr('#a1b2c3', const Color(0xFF595959)),
        const Color(0xFFA1B2C3));
    expect(docxColorOr('FFa1b2c3', const Color(0xFF595959)),
        const Color(0xFFA1B2C3));
  });

  test('DocxEditService format write-back round-trips', () async {
    final dir = await Directory.systemTemp.createTemp('zlib_docx_edit_');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'roundtrip.docx');

    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:r><w:rPr><w:b/></w:rPr><w:t>第一段</w:t></w:r>
    </w:p>
    <w:p><w:r><w:t>第二段</w:t></w:r></w:p>
  </w:body>
</w:document>''',
    ));
    await File(path)
        .writeAsBytes(Uint8List.fromList(ZipEncoder().encode(archive)!));

    var doc = await DocxLoader.openFile(path);

    // 字符格式：加粗关、统一字号、文字色、高亮。
    await DocxEditService.setRunFormat(
      doc: doc,
      paraIndex: 0,
      docxPath: path,
      bold: false,
      fontSizePt: 15,
      colorHex: 'ff0000',
      highlight: '00ff00',
      fontFamily: 'SimSun',
    );
    // 段落格式：居中 + 段前 12pt。
    await DocxEditService.setParagraphFormat(
      doc: doc,
      paraIndex: 0,
      docxPath: path,
      alignment: 'center',
      spacingBeforePt: 12,
    );

    doc = await DocxLoader.openFile(path);
    final p0 = doc.richParagraphs[0];
    expect(p0.alignment, 'center');
    expect(p0.spacingBeforePt, 12.0);
    expect(p0.runs.single.bold, isFalse);
    expect(p0.runs.single.fontSize, 15.0);
    expect(p0.runs.single.colorHex, 'FF0000');
    expect(p0.runs.single.highlight, '00FF00');
    expect(p0.runs.single.fontFamily, 'SimSun');

    // 清除：颜色/高亮清掉，下划线开→关。
    await DocxEditService.setRunFormat(
      doc: doc,
      paraIndex: 0,
      docxPath: path,
      colorHex: '',
      highlight: '',
      underline: true,
    );
    doc = await DocxLoader.openFile(path);
    final cleared = doc.richParagraphs[0].runs.single;
    expect(cleared.colorHex, isNull);
    expect(cleared.highlight, isNull);
    expect(cleared.underline, isTrue);

    await DocxEditService.setRunFormat(
      doc: doc,
      paraIndex: 0,
      docxPath: path,
      underline: false,
    );
    doc = await DocxLoader.openFile(path);
    expect(doc.richParagraphs[0].runs.single.underline, isFalse);

    // 段落 1 不受影响。
    expect(doc.richParagraphs[1].plainText, '第二段');
  });
}
