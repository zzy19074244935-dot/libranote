import 'dart:io';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// 把书导出到公共存储（系统「文件」App 可见）+ 分享到其它 App。
///
/// - Android：通过原生 MethodChannel 走 MediaStore，保存到系统 Downloads
///   （Android 10+ 的 scoped storage 下这是唯一能在文件管理器看到的做法）。
/// - 桌面端：走 [FileSaver.saveFile]，保存到 Downloads。
class FileExportService {
  FileExportService();

  static const MethodChannel _channel = MethodChannel('io.github.zzy19074244935.libranote/file_export');
  static const MethodChannel _shareChannel = MethodChannel('io.github.zzy19074244935.libranote/share');

  /// 把 [filePath] 复制到系统 Downloads（文件 App 可见）。
  ///
  /// 返回保存后的 URI/路径，失败返回 null。Android 走 MediaStore，
  /// 其它平台走 file_saver（桌面 Downloads / iOS Documents）。
  Future<String?> saveToDownloads({
    required String filePath,
    required String fileName,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      debugPrint('[Export] file not found: $filePath');
      return null;
    }
    try {
      if (Platform.isAndroid) {
        final uri = await _channel.invokeMethod<String>('saveToDownloads', {
          'filePath': filePath,
          'fileName': fileName,
          'mimeType': _mimeFor(fileName),
        });
        debugPrint('[Export] MediaStore → $uri');
        return uri;
      }
      // 桌面/iOS 兜底：file_saver.saveFile 存到 Downloads（桌面）或
      // Documents（iOS，Files App 可见）。
      final saved = await FileSaver.instance.saveFile(
        name: fileName,
        filePath: filePath,
      );
      debugPrint('[Export] file_saver → $saved');
      return saved;
    } catch (e) {
      debugPrint('[Export] saveToDownloads failed: $e');
      return null;
    }
  }

  /// 分享文件到其它 App（QQ / 微信 / WPS 走系统分享面板）。
  ///
  /// Android 走自建 FileProvider 通道：chooser 带 FLAG_ACTIVITY_NEW_TASK，
  /// 目标 App 不会并进本 App 任务栈——修复「分享到微信后 App 页面停在
  /// 微信、重开 App 也是微信」的任务串台问题。
  Future<void> shareFile({
    required String filePath,
    String? text,
  }) async {
    if (Platform.isAndroid) {
      try {
        final ok = await _shareChannel.invokeMethod<bool>('shareFile', {
          'filePath': filePath,
          'fileName': filePath.split(Platform.pathSeparator).last,
          'mimeType': _mimeFor(filePath),
          'text': text,
        });
        if (ok == true) return;
        debugPrint('[Export] native share returned false — fallback to share_plus');
      } catch (e) {
        debugPrint('[Export] native share failed ($e) — fallback to share_plus');
      }
    }
    await Share.shareXFiles(
      [XFile(filePath, mimeType: _mimeFor(filePath))],
      text: text,
    );
  }

  /// 根据文件名推断 MIME 类型（MediaStore 需要，决定文件 App 里怎么归类）。
  static String _mimeFor(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'epub':
        return 'application/epub+zip';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      case 'azw3':
      case 'azw':
        return 'application/vnd.amazon.ebook';
      case 'txt':
        return 'text/plain';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'djvu':
        return 'image/vnd.djvu';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }
}
