import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App 内截图库：阅读器截图统一存 `Documents/shots/`，支持列出与相册选图。
///
/// 截图文件本体放在 App 私有 Documents 目录（随云同步备份，见
/// sync_service.dart 对 `shots` 目录的导出/导入）。
///
/// 注意：阅读时「选区截图 / 随笔记保存的截图」历史上落在 `ai_shots/`，
/// 不在 `shots/`。以前列表只扫 `shots/`，用户截了一堆图，插入图片时
/// 截图库却是空的（用户反馈「没有截图库图片的选项」）。现在两个目录
/// 一起扫，按时间倒序合并。
class ShotLibrary {
  ShotLibrary._();
  static final ShotLibrary instance = ShotLibrary._();

  final ImagePicker _picker = ImagePicker();

  /// 截图库扫描的目录（相对 Documents）。`shots` 是主目录，新截图都进这里。
  static const List<String> shotDirNames = ['shots', 'ai_shots'];

  /// 认得的图片扩展名（相册插入的可能是 jpg/webp，不能只认 png）。
  static const Set<String> _imageExts = {
    '.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp',
  };

  /// 把 PNG 字节存到 `Documents/shots/<prefix>_<时间戳>.png`，返回绝对路径。
  Future<String?> savePng(Uint8List bytes, {String? prefix}) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'shots'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final name = '${prefix ?? 'shot'}_'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      final path = p.join(dir.path, name);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('[ShotLibrary] savePng failed: $e');
      return null;
    }
  }

  /// 按修改时间倒序（新的在前）列出截图库里的所有图片。
  Future<List<File>> listShots() async {
    final docs = await getApplicationDocumentsDirectory();
    final files = <File>[];
    for (final name in shotDirNames) {
      final dir = Directory(p.join(docs.path, name));
      if (!dir.existsSync()) continue;
      try {
        files.addAll(dir
            .listSync()
            .whereType<File>()
            .where((f) =>
                _imageExts.contains(p.extension(f.path).toLowerCase())));
      } catch (e) {
        debugPrint('[ShotLibrary] list $name failed: $e');
      }
    }
    files.sort((a, b) => _mtime(b).compareTo(_mtime(a)));
    return files;
  }

  DateTime _mtime(File f) {
    try {
      return f.statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// 用 image_picker 从相册选一张图片，返回其本地路径；取消返回 null。
  Future<String?> pickLocalImage() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      return file?.path;
    } catch (e) {
      debugPrint('[ShotLibrary] pickLocalImage failed: $e');
      return null;
    }
  }
}
