import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Agent 任务的前台通知（Android）：任务运行期间通知栏常驻并显示进度；
/// 需要用户确认写操作时把通知文案改成「任务需要确认」。
/// 其它平台不做事（任务照常跑，只是没有系统通知）。
class AgentTaskNotifier {
  AgentTaskNotifier._();

  static const MethodChannel _channel = MethodChannel('io.github.zzy19074244935.libranote/agent_task');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static void start(String goal) {
    if (!_supported) return;
    try {
      _channel.invokeMethod('start', {'goal': goal});
    } catch (_) {}
  }

  static void updateProgress(String goal, String text, int step, int total) {
    if (!_supported) return;
    try {
      _channel.invokeMethod('updateProgress', {
        'goal': goal,
        'text': text,
        'step': step,
        'total': total,
      });
    } catch (_) {}
  }

  static void stop() {
    if (!_supported) return;
    try {
      _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
