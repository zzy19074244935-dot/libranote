import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../providers/providers.dart';
import '../services/sync_service.dart';

/// 同步设置（坚果云 WebDAV）。
///
/// 用户需求 2.1 逐条落点：配置信息 / 配置教程 / 导出导入配置 / 三个自动
/// 同步开关 / 同步范围（书籍默认关、与下载路径设置联动）/ 立即同步。
/// 隐私：应用密码只存 flutter_secure_storage，配置导出不含密码。
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() =>
      _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  late final TextEditingController _serverCtrl;
  late final TextEditingController _accountCtrl;
  late final TextEditingController _passwordCtrl;

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _syncing = false;
  final List<String> _syncLog = [];
  String? _lastSyncText;
  bool _passwordDirty = false;

  SyncConfig get _config => SyncService.instance.config;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: _config.server);
    _accountCtrl = TextEditingController(text: _config.username);
    _passwordCtrl = TextEditingController(text: '');
    _refreshLastSyncText();
    // 同步服务要读书架/笔记做导出，这里把 StorageService 挂上去。
    SyncService.instance.attachStorage(ref.read(storageServiceProvider));
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _refreshLastSyncText() {
    final at = SyncService.instance.lastSyncAt;
    setState(() {
      _lastSyncText = at == null
          ? '从未同步'
          : '上次同步：${DateFormat('MM-dd HH:mm').format(at)}'
              ' · ${SyncService.instance.lastReport?.summary() ?? ''}';
    });
  }

  Future<void> _save() async {
    final server = _serverCtrl.text.trim();
    if (server.isEmpty) {
      _toast('请填写服务器地址');
      return;
    }
    final cfg = _config.copyWith(
      server: server.endsWith('/') ? server : '$server/',
      username: _accountCtrl.text.trim(),
    );
    await SyncService.instance.saveConfig(
      cfg,
      newPassword: _passwordDirty ? _passwordCtrl.text : null,
    );
    _passwordDirty = false;
    _testResult = null;
    _toast('配置已保存');
    setState(() {});
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      // 先落盘再测，保证测试的就是界面上的值。
      await _save();
      await SyncService.instance.testConnection();
      setState(() {
        _testResult = '✅ 连接成功';
        _testOk = true;
      });
    } catch (e) {
      setState(() {
        _testResult = '❌ $e';
        _testOk = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncLog.clear();
    });
    try {
      await SyncService.instance.syncNow(onMessage: (m) {
        if (!mounted) return;
        setState(() => _syncLog.add(m));
      });
      if (mounted) _toast('同步完成');
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
        _refreshLastSyncText();
      }
    }
  }

  Future<void> _importCloudData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入云端数据'),
        content: const Text('把云端同步下来的画布/备忘录/笔记/AI 对话恢复到'
            '本机（只补不删，已有数据不受影响；书不在书架上的笔记会跳过）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始导入')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await SyncService.instance.importCloudData();
      _toast(result);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _exportConfig() async {
    try {
      final json = await SyncService.instance.exportConfigJson();
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'libranote-sync-config.json'));
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'Libranote 同步配置');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _importConfig() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择同步配置文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null || picked.files.isEmpty) return;
    try {
      final raw = await File(picked.files.single.path!).readAsString();
      final result = await SyncService.instance.importConfigJson(raw);
      _serverCtrl.text = _config.server;
      _accountCtrl.text = _config.username;
      _passwordCtrl.clear();
      _passwordDirty = false;
      _toast(result);
      setState(() {});
    } catch (e) {
      _toast('导入失败：文件不是有效的同步配置（$e）');
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择要云同步的本地文件夹');
    if (path == null || path.isEmpty) return;
    await SyncService.instance
        .saveConfig(_config.copyWith(userFolderPath: path));
    setState(() {});
  }

  Future<void> _openTutorial() async {
    const url = 'https://help.jianguoyun.com/?p=2064';
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('launchUrl failed');
    } catch (_) {
      await Clipboard.setData(const ClipboardData(text: url));
      _toast('无法打开浏览器，教程链接已复制');
    }
  }

  Future<void> _setSwitch(SyncConfig Function(SyncConfig) mutate) async {
    await SyncService.instance.saveConfig(mutate(_config));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cfg = _config;
    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 配置 ──────────────────────────────────────────────
          Text('坚果云 WebDAV 配置', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '凭证 = 坚果云账号（邮箱）+ 应用专属密码。\n'
            '应用密码在坚果云网页 → 账户信息 → 安全选项 → 第三方应用管理 里生成，'
            '不是登录密码。密码只保存在本机加密存储。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serverCtrl,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.jianguoyun.com/dav/',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _accountCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
                labelText: '坚果云账号（邮箱）'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            onChanged: (_) => _passwordDirty = true,
            decoration: InputDecoration(
              labelText: '应用密码（${SyncService.instance.password == null || SyncService.instance.password!.isEmpty ? '未设置' : '已保存，留空不变'}）',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find, size: 18),
                  label: const Text('测试连接'),
                  onPressed: _testing ? null : _test,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: _save,
                ),
              ),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            Text(
              _testResult!,
              style: TextStyle(
                fontSize: 13,
                color: _testOk ? Colors.green : colors.error,
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _openTutorial,
              icon: const Icon(Icons.help_outline, size: 16),
              label: const Text('坚果云 WebDAV 配置教程', style: TextStyle(fontSize: 12.5)),
            ),
          ),
          const Divider(height: 28),

          // ── 立即同步 ──────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(_lastSyncText ?? '从未同步',
                    style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant)),
              ),
              FilledButton.icon(
                icon: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: Text(_syncing ? '同步中…' : '立即同步'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: _syncing ? null : _syncNow,
              ),
            ],
          ),
          if (_syncLog.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final line in _syncLog)
                    Text(line,
                        style: const TextStyle(fontSize: 11.5, height: 1.5)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _importCloudData,
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('导入云端数据到本机（换机恢复）'),
          ),
          const Divider(height: 28),

          // ── 自动同步 ──────────────────────────────────────────
          Text('自动同步', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            title: const Text('启动 App 时同步'),
            subtitle: const Text('打开 App 约 6 秒后后台同步一次'),
            value: cfg.autoOnStartup,
            onChanged: (v) => _setSwitch((c) => c.copyWith(autoOnStartup: v)),
          ),
          SwitchListTile(
            title: const Text('回到前台时同步'),
            subtitle: const Text('从后台切回 App 时同步一次'),
            value: cfg.autoOnForeground,
            onChanged: (v) => _setSwitch((c) => c.copyWith(autoOnForeground: v)),
          ),
          SwitchListTile(
            title: const Text('文件变更后同步'),
            subtitle: const Text('笔记/画布/备忘录保存后 3 秒防抖同步'),
            value: cfg.autoOnFileChange,
            onChanged: (v) =>
                _setSwitch((c) => c.copyWith(autoOnFileChange: v)),
          ),
          const Divider(height: 28),

          // ── 同步范围 ──────────────────────────────────────────
          Text('同步范围', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('画布 / 备忘录 / 笔记 / AI 对话 / 设置配置默认总是同步（云端 '
              'Libranote/data/）。以下两项按需打开：',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant)),
          SwitchListTile(
            title: const Text('同步书籍文件'),
            subtitle: const Text('书籍上传到云端 Libranote/books/\n'
                '⚠ 坚果云免费版每月上传 1GB / 下载 3GB，'
                '一本 PDF 几十 MB，建议按需打开'),
            value: cfg.syncBooks,
            onChanged: (v) => _setSwitch((c) => c.copyWith(syncBooks: v)),
          ),
          SwitchListTile(
            title: const Text('同步指定本地文件夹'),
            subtitle: Text(cfg.userFolderPath.isEmpty
                ? '未选择（与「下载路径设置」联动）'
                : cfg.userFolderPath),
            value: cfg.syncUserFolder,
            onChanged: (v) => _setSwitch((c) => c.copyWith(syncUserFolder: v)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open),
            title: const Text('选择文件夹', style: TextStyle(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickFolder,
          ),
          const Divider(height: 28),

          // ── 导出 / 导入配置 ───────────────────────────────────
          Text('配置备份', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('导出配置后可在另一台设备导入（应用密码不随配置导出，'
              '需在新设备重新填写——这是刻意的安全边界）。',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('导出配置'),
                  onPressed: _exportConfig,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导入配置'),
                  onPressed: _importConfig,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
