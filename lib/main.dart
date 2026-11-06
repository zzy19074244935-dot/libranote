import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'config/app_config.dart';
import 'providers/app_providers.dart';
import 'providers/usage_provider.dart';
import 'services/agent_task_engine.dart';
import 'services/screenshot_flag.dart';
import 'services/storage_service.dart';
import 'services/sync_service.dart';

/// Where uncaught errors are appended, so a crash can be reported after the
/// fact instead of relying on the user remembering the red screen.
File? _crashLogFile;

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    _installErrorHandlers();

    // The WebView reader and export font are bundled outside Pub's license registry.
    LicenseRegistry.addLicense(() async* {
      for (final name in [
        'foliate-js-MIT.txt',
        'pdfjs-5.7.284-Apache-2.0.txt',
        'NotoSansSC-OFL.txt',
        'fflate-MIT.txt',
        'zipjs-LICENSE.txt',
        'construct-style-sheets-polyfill-MIT.txt',
      ]) {
        final license =
            await rootBundle.loadString('third_party/licenses/$name');
        yield LicenseEntryWithLineBreaks([name], license);
      }
    });

    // Initialize persisted config before the app starts.
    await AppConfig.instance.init();

    final container = ProviderContainer();

    // 使用时长追踪：30s 刷一次 usage_days，App 切后台自动挂起。
    container.read(usageTrackerProvider);

    // ── 云同步（Phase 5）接线 ────────────────────────────────────
    // 1) 读配置（坚果云账号/应用密码/自动同步开关）；
    // 2) StorageService 数据写入 → 防抖触发同步（「文件变更后同步」）；
    // 3) App 启动后延迟同步一次（「启动 App 时同步」）；
    // 4) 回前台触发（WidgetsBindingObserver）。
    await SyncService.instance.init();
    StorageService.onDataChanged = SyncService.instance.notifyFileChanged;
    WidgetsBinding.instance.addObserver(_SyncLifecycleObserver());
    SyncService.instance.scheduleStartupSync();

    // 只在进程启动时恢复遗留任务，重进任务页不能中断后台活跃任务。
    await AgentTaskEngine.markStaleTasks(
        container.read(storageServiceProvider));

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: const LibranoteApp(),
      ),
    );

    // 截屏开关：启动后按设置复位 FLAG_SECURE（清除 = 允许截屏）。
    WidgetsBinding.instance.addPostFrameCallback((_) => ScreenshotFlag.apply());
  }, (error, stack) {
    _logCrash('Uncaught async error', error, stack);
  });
}

/// App 生命周期：回前台时触发一次云同步（若开关打开）+ 复位截屏开关。
///
/// 挂在全局 WidgetsBinding 上而不是某个页面里——IndexedStack 的页面
/// 常驻不重建，页面级 observer 可能永远收不到 resumed。
class _SyncLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 微任务延迟：resumed 有时与页面重建撞在一起，稍等一下再同步。
      Future<void>.microtask(() {
        SyncService.instance.onForeground();
        ScreenshotFlag.apply();
      });
    }
  }
}

void _installErrorHandlers() {
  // Framework errors (build/layout/paint) — the red-screen source.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logCrash('FlutterError', details.exception, details.stack);
  };

  // Errors from the engine that never reach the framework.
  PlatformDispatcher.instance.onError = (error, stack) {
    _logCrash('PlatformDispatcher', error, stack);
    return true;
  };

  // Replace the red screen with something the user can act on.
  ErrorWidget.builder = (details) => _FriendlyErrorWidget(details: details);
}

/// Append an error to the crash log, best-effort.
void _logCrash(String label, Object error, StackTrace? stack) {
  debugPrint('[crash] $label: $error\n$stack');
  try {
    final file = _crashLogFile;
    if (file == null) {
      // Resolve lazily; the docs dir isn't available synchronously at startup.
      getApplicationDocumentsDirectory().then((dir) {
        _crashLogFile = File(p.join(dir.path, 'crash.log'));
        _appendCrash(_crashLogFile!, label, error, stack);
      }).catchError((_) => null);
      return;
    }
    _appendCrash(file, label, error, stack);
  } catch (_) {
    // Logging must never itself crash the app.
  }
}

void _appendCrash(File file, String label, Object error, StackTrace? stack) {
  try {
    file.writeAsStringSync(
      '--- ${DateTime.now().toIso8601String()} [$label] ---\n'
      '$error\n$stack\n\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// Shown in place of the framework's red error box.
///
/// The user reported red screens but could not recall the message, so the
/// details are on screen and one tap puts them on the clipboard.
class _FriendlyErrorWidget extends StatelessWidget {
  final FlutterErrorDetails details;
  const _FriendlyErrorWidget({required this.details});

  String get _report {
    return '${details.exception}\n\n'
        '${details.library ?? ''}\n'
        '${details.stack ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    // ErrorWidget can be built before/outside a Material ancestor, so this
    // deliberately avoids Theme.of and builds its own Directionality.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFF2B1A1A),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.error_outline, color: Color(0xFFFFB4AB)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '这个页面出错了',
                        style: TextStyle(
                          color: Color(0xFFFFB4AB),
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      '${details.exception}',
                      style: const TextStyle(
                        color: Color(0xFFE7D6D4),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _report));
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制错误详情'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFFFB4AB),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
