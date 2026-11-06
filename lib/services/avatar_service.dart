import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

/// 用户头像：拍照/相册选图 → 缩放成 256px 方图 → 存到
/// `Documents/avatar/avatar.png`（App 私有目录，随云同步备份），
/// 路径写进 AppConfig，全局 AppAvatar 即时生效。
class AvatarService {
  AvatarService._();
  static final AvatarService instance = AvatarService._();

  final ImagePicker _picker = ImagePicker();

  /// 拍照/相册选一张新头像并保存。返回新头像路径；取消返回 null。
  Future<String?> pickAndSave({required bool fromCamera}) async {
    try {
      final file = await _picker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 90,
      );
      if (file == null) return null;
      final bytes = await File(file.path).readAsBytes();
      return saveAvatarBytes(bytes);
    } catch (e) {
      debugPrint('[Avatar] pick failed: $e');
      rethrow;
    }
  }

  /// 把图片字节缩放成 256×256（居中裁方）保存为头像，返回路径。
  Future<String> saveAvatarBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ui.Image img = frame.image;
    final side = img.width < img.height ? img.width : img.height;
    final left = (img.width - side) ~/ 2;
    final top = (img.height - side) ~/ 2;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const target = 256.0;
    final src = ui.Rect.fromLTWH(
        left.toDouble(), top.toDouble(), side.toDouble(), side.toDouble());
    const dst = ui.Rect.fromLTWH(0, 0, target, target);
    canvas.drawImageRect(img, src, dst, ui.Paint());
    final picture = recorder.endRecording();
    final resized = await picture.toImage(target.toInt(), target.toInt());
    picture.dispose();
    img.dispose();
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    if (byteData == null) throw Exception('头像图片处理失败');

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'avatar'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = p.join(dir.path, 'avatar.png');
    await File(path).writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    AppConfig.instance.avatarPath = path;
    return path;
  }

  /// 移除头像（回到默认首字母头像）。
  Future<void> remove() async {
    final path = AppConfig.instance.avatarPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    AppConfig.instance.avatarPath = null;
  }
}
