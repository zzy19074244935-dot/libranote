import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as prx;

/// 验证 AI 工具的 PDF 底层能力：pdfrx 打开 PDF → 逐页 loadText 提取、
/// 书签目录（outline）读取。用 pdf 包生成带中文字体的真实 PDF。
void main() {
  test('pdfrx extracts page text from a generated PDF', () async {
    final fontFile = File('assets/fonts/NotoSansSC.ttf');
    if (!fontFile.existsSync()) {
      markTestSkipped('assets/fonts/NotoSansSC.ttf 不存在');
      return;
    }
    final fontBytes = fontFile.readAsBytesSync();
    final font = pw.Font.ttf(ByteData.view(fontBytes.buffer));
    final theme = pw.ThemeData.withFont(base: font, bold: font);

    final doc = pw.Document(theme: theme);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('第一章 神经网络', style: const pw.TextStyle(fontSize: 20)),
          pw.Text('这一页讲神经网络的原理。'),
        ],
      ),
    ));
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('第二章 深度学习', style: const pw.TextStyle(fontSize: 20)),
          pw.Text('这一页讲深度学习的训练。'),
        ],
      ),
    ));

    final dir = Directory.systemTemp.createTempSync('pdf_ai_test');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final path = '${dir.path}/test.pdf';
    File(path).writeAsBytesSync(await doc.save());

    final pdf = await prx.PdfDocument.openFile(path);
    try {
      expect(pdf.pages.length, 2);
      final page1 = (await pdf.pages[0].loadText())?.fullText ?? '';
      final page2 = (await pdf.pages[1].loadText())?.fullText ?? '';
      expect(page1, contains('神经网络'));
      expect(page1, contains('原理'));
      expect(page2, contains('深度学习'));
    } finally {
      pdf.dispose();
    }
  });
}
