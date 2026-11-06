import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';

/// 自建版本更新（方案：TOS 存 JSON + APK → DownloadManager 下载 →
/// FileProvider 安装）。
///
/// 服务器上放两个文件（同一目录，公开读）：
///   update.json：
///     {
///       "versionCode": 2,            // 数字，比 App 当前大才会提示更新
///       "versionName": "1.0.1",      // 展示用
///       "apkUrl": "https://.../app-arm64-v8a-release.apk",
///       "message": "更新说明...",     // 可选
///       "force": false               // 可选：true = 强制更新
///     }
///   app-arm64-v8a-release.apk —— 与 update.json 同目录。
///
/// App 端：启动后延时检查（24h 节流）+ 设置页「检查更新」手动触发。
/// 有新版本 → 弹窗 → DownloadManager 后台下载（通知栏进度）→ 完成后
/// 弹「安装」确认 → FileProvider 安装（Android 8+ 首次需要「未知来源」授权，
/// App 会自动跳到授权页）。
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const MethodChannel _channel = MethodChannel('io.github.zzy19074244935.libranote/update');
  static const MethodChannel _appInfo = MethodChannel('io.github.zzy19074244935.libranote/app_info');

  int _currentVersionCode = -1;
  String _currentVersionName = '';

  /// 当前 App 版本（原生 PackageManager 读取，Android）。
  Future<({int code, String name})> currentVersion() async {
    if (_currentVersionCode >= 0 && _currentVersionName.isNotEmpty) {
      return (code: _currentVersionCode, name: _currentVersionName);
    }
    try {
      if (Platform.isAndroid) {
        final map = await _appInfo.invokeMethod<Map>('version');
        final code = (map?['versionCode'] as num?)?.toInt() ?? 0;
        final name = (map?['versionName'] as String?) ?? '';
        if (code > 0) {
          _currentVersionCode = code;
          _currentVersionName = name;
        }
      } else {
        _currentVersionCode = 1;
        _currentVersionName = '1.0.0';
      }
    } catch (e) {
      debugPrint('[Update] read version failed: $e');
      _currentVersionCode = 1;
      _currentVersionName = '1.0.0';
    }
    return (code: _currentVersionCode, name: _currentVersionName);
  }

  /// 拉取 update.json 并比对版本。返回 null = 已是最新/未配置/检查失败。
  Future<UpdateInfo?> checkForUpdate() async {
    final url = AppConfig.instance.updateJsonUrl;
    if (url.isEmpty) return null;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
        validateStatus: (s) => s != null && s < 500,
      ));
      final r = await dio.get<dynamic>(url);
      dio.close();
      final map = r.data is Map ? Map<String, dynamic>.from(r.data as Map) : null;
      if (map == null) return null;
      final remoteCode = (map['versionCode'] as num?)?.toInt();
      final apkUrl = (map['apkUrl'] as String?) ?? '';
      if (remoteCode == null || apkUrl.isEmpty) return null;
      final cur = await currentVersion();
      if (remoteCode <= cur.code) return null;
      AppConfig.instance.lastUpdateCheckMs =
          DateTime.now().millisecondsSinceEpoch;
      return UpdateInfo(
        versionCode: remoteCode,
        versionName: (map['versionName'] as String?) ?? '',
        apkUrl: apkUrl,
        message: (map['message'] as String?) ?? '',
        force: map['force'] == true,
      );
    } catch (e) {
      debugPrint('[Update] check failed: $e');
      return null;
    }
  }

  /// 启动后延时自动检查（24 小时节流，静默：有更新才弹窗）。
  Future<void> autoCheckOnLaunch() async {
    await Future<void>.delayed(const Duration(seconds: 8));
    if (!AppConfig.instance.autoUpdateEnabled) return;
    final last = AppConfig.instance.lastUpdateCheckMs;
    if (last != null &&
        DateTime.now().millisecondsSinceEpoch - last <
            const Duration(hours: 24).inMilliseconds) {
      return;
    }
    // 先拿到 navigator 再 await（跨 async 使用 context 的 lint 防线）。
    final nav = UpdateService.navigatorKey.currentState;
    final info = await checkForUpdate();
    if (info == null || nav == null || !nav.mounted) return;
    _promptUpdate(nav.context, info);
  }

  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  /// main.dart / app.dart 里把 MaterialApp.navigatorKey 指过来，用于启动时弹更新。
  static GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;

  /// 手动检查（设置页按钮）：alwaysPrompt = true 时即使已是最新也给提示。
  Future<void> manualCheck(BuildContext context,
      {bool alwaysPrompt = true}) async {
    UpdateInfo? info;
    try {
      info = await checkForUpdate();
    } catch (e) {
      debugPrint('[Update] manual check failed: $e');
    }
    if (!context.mounted) return;
    if (info == null) {
      if (alwaysPrompt) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已是最新版本（或检查服务未配置）')),
        );
      }
      return;
    }
    _promptUpdate(context, info);
  }

  /// 更新弹窗 → 下载 → 安装。
  void _promptUpdate(BuildContext context, UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: !info.force,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 ${info.versionName}'),
        content: Text(
          info.message.isEmpty
              ? '新版本已发布，建议更新到最新版。'
              : info.message,
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          if (!info.force)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('以后再说'),
            ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () async {
              Navigator.pop(ctx);
              await downloadAndInstall(context, info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  /// DownloadManager 下载 → 轮询进度 → 完成弹「安装」确认 → FileProvider 安装。
  Future<void> downloadAndInstall(BuildContext context, UpdateInfo info) async {
    if (!Platform.isAndroid) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自动更新仅支持 Android：\n${info.apkUrl}')),
        );
      }
      return;
    }
    final fileName = info.apkUrl.split('/').last.contains('.apk')
        ? info.apkUrl.split('/').last
        : 'libranote-update-${info.versionCode}.apk';
    String downloadId;
    try {
      final id = await _channel.invokeMethod<String>('download', {
        'url': info.apkUrl,
        'fileName': fileName,
      });
      if (id == null || id.isEmpty) throw Exception('下载任务创建失败');
      downloadId = id;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('开始下载失败: $e')),
        );
      }
      return;
    }

    // 进度弹层（轮询 DownloadManager）。
    if (!context.mounted) return;
    var done = false;
    final downloaded = await showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        // 轮询进度：每 800ms 一次，直到成功/失败/弹层被关。
        Future<void> poll() async {
          while (ctx.mounted && !done) {
            await Future<void>.delayed(const Duration(milliseconds: 800));
            try {
              final map = await _channel.invokeMethod<Map>('queryStatus', {
                'downloadId': downloadId,
              });
              final status = (map?['status'] as String?) ?? '';
              if (status == 'success') {
                done = true;
                if (ctx.mounted) Navigator.pop(ctx, true);
                return;
              }
              if (status == 'failed' || status == 'not_found') {
                done = true;
                if (ctx.mounted) Navigator.pop(ctx, false);
                return;
              }
            } catch (_) {}
          }
        }

        poll();
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在下载新版本'),
            content: const Row(
              children: [
                CircularProgressIndicator(strokeWidth: 3),
                SizedBox(width: 18),
                Expanded(
                  child: Text('新版本正在后台下载（通知栏可看进度），\n下载完成后会自动弹出安装。',
                      style: TextStyle(fontSize: 14, height: 1.5)),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  done = true;
                  Navigator.pop(ctx, null);
                },
                child: const Text('后台下载'),
              ),
            ],
          ),
        );
      },
    );
    if (downloaded != true) {
      if (context.mounted && downloaded == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下载失败，请稍后重试')),
        );
      }
      return;
    }
    // 下载完成 → 确认安装。
    if (!context.mounted) return;
    final install = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('新版本已下载完成'),
        content: const Text('点击「安装」开始升级（安装期间 App 会退出）。',
            style: TextStyle(fontSize: 14, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('立即安装'),
          ),
        ],
      ),
    );
    if (install != true) return;
    try {
      final map = await _channel.invokeMethod<Map>('install', {
        'downloadId': downloadId,
      });
      if (map?['needsPermission'] == true && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已打开「允许安装未知应用」设置，授权后回到 App 重新点「检查更新」即可安装'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('安装失败: $e')),
        );
      }
    }
  }
}

/// update.json 解析结果。
class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String message;
  final bool force;

  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.message = '',
    this.force = false,
  });
}
