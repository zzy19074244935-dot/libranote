import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 整屏截图：Android 走 MediaProjection（系统弹一次「开始录制或投射」
/// 授权后截取整块屏幕——分屏 / 小窗时连另一侧的 B 站一起截进来），返回
/// PNG 字节。其它平台暂不支持，返回 null（调用方回退到 App 内截图）。
///
/// 原生侧返回 `{"path": ..., "error": ...}`：失败原因记在 [lastError]，
/// 调用方可以据此提示用户（例如「授权被拒绝」），而不是默默只截 App。
class ScreenCapture {
  ScreenCapture._();

  static const MethodChannel _channel = MethodChannel('io.github.zzy19074244935.libranote/shot');

  /// 最近一次整屏截图失败的原因（成功时为 null）。
  static String? lastError;

  /// 是否可能支持整屏截图（仅 Android）。
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// 回退到「只截 App 内容」时给用户看的提示；没有可说的原因返回 null。
  static String? get fallbackNotice {
    final e = lastError;
    if (!isSupported || e == null || e.isEmpty) return null;
    return '整屏截图未生效（$e），本次只截到 App 内容';
  }

  /// 截取整块屏幕。授权被拒绝 / 失败 / 平台不支持 → null。
  /// 注意：系统授权弹窗由原生侧发起，本调用会一直等到授权结果。
  static Future<Uint8List?> captureFullScreen() async {
    lastError = null;
    if (!isSupported) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>('captureScreen');
      String? path;
      if (raw is String) {
        path = raw;
      } else if (raw is Map) {
        path = raw['path'] as String?;
        lastError = raw['error'] as String?;
      }
      if (path == null || path.isEmpty) {
        debugPrint('[ScreenCapture] no frame: $lastError');
        return null;
      }
      final file = File(path);
      if (!await file.exists()) {
        lastError = '截屏文件丢失';
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        lastError = '截屏文件为空';
        return null;
      }
      return bytes;
    } catch (e) {
      lastError = '$e';
      debugPrint('[ScreenCapture] capture failed: $e');
      return null;
    }
  }
}
