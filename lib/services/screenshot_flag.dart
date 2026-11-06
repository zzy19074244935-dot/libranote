import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';

/// 截屏/录屏开关。
///
/// 为什么会出现「涉及版权、隐私的页面不能截屏」：
/// Android 的 FLAG_SECURE 窗口标志会让系统截屏/录屏一片黑并弹该提示。
/// 本 App 的代码（含所用插件：pdfrx、flutter_inappwebview 等）**都不设置**
/// 这个标志——但个别厂商 ROM（如企业管控模式/工作资料空间）或第三方
/// 悬浮/录屏工具会把它加上。为了可操作，这里提供显式通道：
/// · 设置页「允许截屏」开关；
/// · 每次回到前台按开关复位标志（清除或加上）。
class ScreenshotFlag {
  ScreenshotFlag._();

  static const MethodChannel _channel = MethodChannel('io.github.zzy19074244935.libranote/secure_flag');

  /// 按当前设置应用截屏标志（非 Android 平台是 no-op）。
  static Future<void> apply() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final allow = AppConfig.instance.allowScreenshot;
    try {
      await _channel.invokeMethod<bool>('set', {'secure': !allow});
    } catch (e) {
      debugPrint('[ScreenshotFlag] apply failed: $e');
    }
  }
}
