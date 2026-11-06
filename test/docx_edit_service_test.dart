import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libranote/services/docx_edit_service.dart';
import 'package:libranote/services/docx_loader.dart';

Uint8List _docxBytes(String bodyXml) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
      'word/document.xml',
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>$bodyXml</w:body>
</w:document>''',
    ));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docx_edit_test');
    path = '${tmp.path}/test.docx';
    File(path).writeAsBytesSync(_docxBytes('''
    <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>标题</w:t></w:r></w:p>
    <w:p><w:r><w:t>正文一</w:t></w:r></w:p>
    <w:p><w:r><w:t>正文二</w:t></w:r></w:p>'''));
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('改段落文字写回后：新文字生效、其他段落与格式保留', () async {
    var doc = await DocxLoader.openFile(path);
    expect(doc.paragraphs, ['标题', '正文一', '正文二']);

    await DocxEditService.setParagraphText(
      doc: doc,
      paraIndex: 1,
      newText: '改过的文字\n第二行',
      docxPath: path,
    );

    doc = await DocxLoader.openFile(path);
    expect(doc.paragraphs, ['标题', '改过的文字\n第二行', '正文二']);
    // 标题段落的对齐（pPr）在写回后保留。
    expect(doc.richParagraphs[0].alignment, 'center');
  });

  test('前插/后插段落写回后：顺序正确、批注锚点迁移由调用方负责', () async {
    var doc = await DocxLoader.openFile(path);

    await DocxEditService.insertParagraph(
      doc: doc,
      paraIndex: 1,
      newText: '插在正文一之前',
      docxPath: path,
    );
    doc = await DocxLoader.openFile(path);
    expect(doc.paragraphs[1], '插在正文一之前');
    expect(doc.paragraphs[2], '正文一');

    await DocxEditService.insertParagraph(
      doc: doc,
      paraIndex: 0,
      newText: '插在标题之后',
      docxPath: path,
      after: true,
    );
    doc = await DocxLoader.openFile(path);
    expect(doc.paragraphs[1], '插在标题之后');
    expect(doc.paragraphs[2], '插在正文一之前');
  });

  test('删除段落写回后：仅目标段消失', () async {
    var doc = await DocxLoader.openFile(path);
    await DocxEditService.deleteParagraph(
        doc: doc, paraIndex: 1, docxPath: path);
    doc = await DocxLoader.openFile(path);
    expect(doc.paragraphs, ['标题', '正文二']);

    // 只剩一段时拒绝删除。
    await DocxEditService.deleteParagraph(
        doc: doc, paraIndex: 0, docxPath: path);
    await DocxEditService.deleteParagraph(
        doc: doc, paraIndex: 1, docxPath: path);
    expect(
      () => DocxEditService.deleteParagraph(
          doc: doc, paraIndex: 0, docxPath: path),
      throwsA(isA<FormatException>()),
    );
  });

  test('文末追加段落：追加在 sectPr 之前、正文末尾', () async {
    final path2 = '${tmp.path}/with_sectpr.docx';
    File(path2).writeAsBytesSync(_docxBytes('''
    <w:p><w:r><w:t>唯一一段</w:t></w:r></w:p>
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>'''));

    var doc = await DocxLoader.openFile(path2);
    await DocxEditService.appendParagraph(
        doc: doc, newText: '文末新段落', docxPath: path2);
    doc = await DocxLoader.openFile(path2);
    expect(doc.paragraphs, ['唯一一段', '文末新段落']);
  });

  test('编辑包含文本框的段落：文本框保留、文字被替换', () async {
    final path3 = '${tmp.path}/with_txbx.docx';
    File(path3).writeAsBytesSync(_docxBytes('''
    <w:p><w:r><w:t>外层旧文字</w:t></w:r><w:r><w:drawing>
      <w:txbxContent><w:p><w:r><w:t>文本框内容</w:t></w:r></w:p></w:txbxContent>
    </w:drawing></w:r></w:p>'''));

    var doc = await DocxLoader.openFile(path3);
    expect(doc.paragraphs, ['外层旧文字', '文本框内容']);

    await DocxEditService.setParagraphText(
        doc: doc, paraIndex: 0, newText: '外层新文字', docxPath: path3);
    doc = await DocxLoader.openFile(path3);
    expect(doc.paragraphs, ['外层新文字', '文本框内容'],
        reason: '文本框不能被误删或文字丢失');
  });
}
