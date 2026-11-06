import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libranote/models/models.dart';
import 'package:libranote/services/docx_loader.dart';
import 'package:libranote/widgets/txt_reader_view.dart';

Uint8List _minimalDocx() {
  final archive = Archive();
  archive.addFile(ArchiveFile.string(
    'word/document.xml',
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>第一章 标题</w:t></w:r></w:p>
    <w:p><w:r><w:t>这是正文第一段。</w:t></w:r></w:p>
  </w:body>
</w:document>''',
  ));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  testWidgets('TxtReaderView 渲染 DOCX 富文本 + 浮动文本框',
      (WidgetTester tester) async {
    final doc = DocxLoader.open(_minimalDocx());
    final textBox = DocxNote(
      id: 1,
      bookId: 'b1',
      paraIndex: 1,
      startOffset: 0,
      endOffset: 0,
      quotedText: '正文',
      note: 'AI 生成的文本框内容',
      color: '#4C1D95',
      style: 'textbox',
      x: 0.2,
      y: 0.3,
      w: 0.5,
      fontSize: 13,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TxtReaderView(
          paragraphs: doc.paragraphs,
          richParagraphs: doc.richParagraphs,
          annotations: [textBox],
          onTextBoxChanged: (n) {},
          onTextBoxEdit: (n) {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('第一章 标题'), findsOneWidget);
    expect(find.text('这是正文第一段。'), findsOneWidget);
    expect(find.text('AI 生成的文本框内容'), findsOneWidget);

    // 单击文本框 → 选中（蓝色边框状态，不崩溃）。
    await tester.tap(find.text('AI 生成的文本框内容'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('TxtReaderView 渲染合并单元格表格不崩溃', (tester) async {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:tbl>
      <w:tr>
        <w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
          <w:p><w:r><w:t>标题行合并</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>3</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>4</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>5</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''',
    ));
    final doc =
        DocxLoader.open(Uint8List.fromList(ZipEncoder().encode(archive)!));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TxtReaderView(
          paragraphs: doc.paragraphs,
          richParagraphs: doc.richParagraphs,
          blocks: doc.blocks,
          onParagraphTap: (_) {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(Table), findsOneWidget);
    expect(find.text('标题行合并'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不规则行数不得抛 RangeError');
  });

  testWidgets('TxtReaderView 按块渲染 DOCX 表格与文本框', (tester) async {
    final archive = Archive();
    archive.addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>正文一段</w:t></w:r></w:p>
    <w:tbl>
      <w:tblPr><w:tblBorders>
        <w:top w:val="single"/><w:left w:val="single"/>
        <w:bottom w:val="single"/><w:right w:val="single"/>
      </w:tblBorders></w:tblPr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>单元格一</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>单元格二</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:p>
      <w:r><w:t>外层</w:t></w:r>
      <w:r><w:drawing><w:txbxContent>
        <w:p><w:r><w:t>文本框文字</w:t></w:r></w:p>
      </w:txbxContent></w:drawing></w:r>
    </w:p>
  </w:body>
</w:document>''',
    ));
    final doc =
        DocxLoader.open(Uint8List.fromList(ZipEncoder().encode(archive)!));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TxtReaderView(
          paragraphs: doc.paragraphs,
          richParagraphs: doc.richParagraphs,
          blocks: doc.blocks,
          onParagraphTap: (_) {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('正文一段'), findsOneWidget);
    expect(find.text('单元格一'), findsOneWidget);
    expect(find.text('单元格二'), findsOneWidget);
    expect(find.text('文本框文字'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    // 外层段落不得重复收集文本框文字。
    expect(find.text('外层文本框文字'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
