import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../services/sync_service.dart';
import '../services/webdav_service.dart';

/// 缓存设置：本地缓存大小 / 坚果云云空间 / 清除缓存。
///
/// 「清除缓存」只删可再生资源（临时目录、图片缓存），**绝不动**书、笔记、
/// AI 数据（那些在 Documents 与 SQLite 里）。
class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

  @override
  ConsumerState<CacheSettingsScreen> createState() =>
      _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  bool _scanning = false;
  int _cacheBytes = 0;
  String? _quotaText;
  bool _loadingQuota = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _scanCache();
    _loadQuota();
  }

  Future<void> _scanCache() async {
    setState(() => _scanning = true);
    var total = 0;
    // 扫描临时目录（封顶 5000 个文件防止极端情况卡死）。
    var count = 0;
    Future<void> scanDir(Directory dir) async {
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (count++ > 5000) return;
          if (entity is File) {
            total += await entity.length();
          } else if (entity is Directory) {
            await scanDir(entity);
          }
        }
      } catch (_) {}
    }

    try {
      await scanDir(await getTemporaryDirectory());
    } catch (_) {}
    if (mounted) {
      setState(() {
        _cacheBytes = total;
        _scanning = false;
      });
    }
  }

  Future<void> _loadQuota() async {
    setState(() => _loadingQuota = true);
    try {
      if (!SyncService.instance.configured) {
        setState(() => _quotaText = '未配置坚果云（在「同步设置」里配置后显示）');
        return;
      }
      final quota = await SyncService.instance.fetchQuota();
      setState(() =>
          _quotaText = quota?.describe() ?? '云端未返回配额信息');
    } catch (e) {
      setState(() => _quotaText = '读取失败：$e');
    } finally {
      if (mounted) setState(() => _loadingQuota = false);
    }
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除缓存'),
        content: Text('将删除约 ${WebdavQuota.formatBytes(_cacheBytes)} 的'
            '临时文件与图片缓存。\n书、笔记、AI 对话、云同步配置不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    var removed = 0;
    try {
      final tmp = await getTemporaryDirectory();
      for (final entity in tmp.listSync(followLinks: false)) {
        try {
          if (entity is Directory) {
            await entity.delete(recursive: true);
          } else {
            await entity.delete();
          }
          removed++;
        } catch (_) {}
      }
      // 图片缓存（cached_network_image 默认目录）。
      try {
        final cacheDir = await getApplicationCacheDirectory();
        for (final entity in cacheDir.listSync(followLinks: false)) {
          try {
            if (entity is Directory) {
              await entity.delete(recursive: true);
            } else {
              await entity.delete();
            }
          } catch (_) {}
        }
      } catch (_) {}
    } catch (e) {
      debugPrint('[Cache] clear failed: $e');
    }
    await _scanCache();
    if (mounted) {
      setState(() => _clearing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清除 $removed 个缓存项')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('缓存设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('本地缓存'),
              subtitle: Text(
                _scanning
                    ? '计算中…'
                    : WebdavQuota.formatBytes(_cacheBytes),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('坚果云空间'),
              subtitle: Text(_loadingQuota ? '读取中…' : (_quotaText ?? '')),
              trailing: IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _loadingQuota ? null : _loadQuota,
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: _clearing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.cleaning_services_outlined),
            label: const Text('清除缓存'),
            onPressed: _clearing ? null : _clearCache,
          ),
          const SizedBox(height: 12),
          Text(
            '说明：清除缓存不影响书架、笔记、AI 对话与云同步配置；'
            '只是删掉临时文件和图片缓存，需要时 App 会自动重新下载。',
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
