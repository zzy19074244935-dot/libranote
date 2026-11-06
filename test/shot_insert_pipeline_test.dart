import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:libranote/models/models.dart';
import 'package:libranote/services/shot_library.dart';
import 'package:libranote/widgets/pick_image_source_sheet.dart';
import 'package:libranote/widgets/txt_reader_view.dart';

/// 复现「截图 → 插入当前文件 / 从 App 截图库插入」管线：
/// 截图字节（region_crop 同款引擎 PNG）→ 截图库 → 读取 → 解码 →
/// 三种插入目标的公共转换。全部在真实引擎上跑。
class _FakePathProvider extends Fake with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String base;
  _FakePathProvider(this.base);

  @override
  Future<String?> getApplicationDocumentsPath() async => p.join(base, 'docs');

  @override
  Future<String?> getTemporaryPath() async => p.join(base, 'tmp');
}

/// 用引擎画一张纯色 PNG（与 region_crop._confirm 相同的编码路径）。
Future<Uint8List> makePng(int w, int h, {int color = 0xFF3366CC}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = ui.Color(color));
  final picture = recorder.endRecording();
  final img = await picture.toImage(w, h);
  picture.dispose();
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  expect(data, isNotNull);
  return data!.buffer.asUint8List();
}

void main() {
  late Directory base;

  setUpAll(() async {
    base = Directory.systemTemp.createTempSync('shot_test');
    PathProviderPlatform.instance = _FakePathProvider(base.path);
  });

  tearDownAll(() {
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('截图 PNG → 截图库 → 读取 → 解码全链路', (tester) async {
    String? imgPath;

    // 真实异步部分（引擎 toImage / 文件 IO / 平台通道）必须脱离 FakeAsync。
    await tester.runAsync(() async {
      // 模拟「框选截图」结果：与真实截屏同量级的 PNG（1080×2400）。
      final shot = await makePng(1080, 2400);

      // 保存到 App 截图库（保存功能一直正常，这里确认它仍正常）。
      final saved = await ShotLibrary.instance.savePng(shot, prefix: 'pdf');
      expect(saved, isNotNull);
      expect(File(saved!).existsSync(), isTrue);

      // 截图库能列出它（用户能在选择器里看到这张图）。
      final shots = await ShotLibrary.instance.listShots();
      expect(shots.any((f) => f.path == saved), isTrue,
          reason: 'listShots 应包含刚保存的截图');

      // 选择器返回的路径 → 读取字节（Word/画布插入共用 readImageBytes）。
      final read = await readImageBytes(saved);
      expect(read, isNotNull, reason: 'readImageBytes 读截图库文件应成功');
      expect(read!.isEmpty, isFalse);
      expect(read.length, greaterThan(1000));

      // PDF 插入路径：按字节解码。
      final codec = await ui.instantiateImageCodec(read);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1080);
      expect(frame.image.height, 2400);
      frame.image.dispose();

      // 画布插入路径：解码后重编码 PNG。
      final codec2 = await ui.instantiateImageCodec(read);
      final frame2 = await codec2.getNextFrame();
      final pngData =
          await frame2.image.toByteData(format: ui.ImageByteFormat.png);
      frame2.image.dispose();
      expect(pngData, isNotNull);

      // Word 插入路径：把字节落成 docx_images 文件 + style='image' 批注。
      final docs = await getApplicationDocumentsDirectory();
      final imgDir = Directory(p.join(docs.path, 'docx_images', 'book_test'));
      if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
      final path2 = p.join(imgDir.path, 'img_test.png');
      imgPath = path2;
      File(path2).writeAsBytesSync(read, flush: true);
      expect(File(path2).existsSync(), isTrue);
    });

    // Widget 渲染部分（FakeAsync 下即可）：style='image' 批注应渲染出
    // Image 组件。
    final note = DocxNote(
      id: 1,
      bookId: 'book_test',
      paraIndex: 0,
      startOffset: 0,
      endOffset: 0,
      quotedText: '插入图片',
      note: '',
      style: 'image',
      source: 'manual',
      imagePath: imgPath,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TxtReaderView(
          paragraphs: const ['第一段'],
          annotations: [note],
          onParagraphTap: (_) {},
          onSelectionAction: (_, __) {},
          onAnnotate: (_, __, ___, ____) {},
          onHighlightTap: (_) {},
          onTextBoxChanged: (_) {},
          onTextBoxEdit: (_) {},
        ),
      ),
    ));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget,
        reason: 'style=image 的批注应渲染出 Image');
    expect(tester.takeException(), isNull);
  });
}
