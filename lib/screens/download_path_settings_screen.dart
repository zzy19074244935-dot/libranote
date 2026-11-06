import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/sync_service.dart';

/// 下载路径设置：
/// - 应用内书籍目录（Documents/books，只读展示）；
/// - 「下载后保存到」的用户文件夹（file_picker 选择，持久化）；
/// - 与云同步联动：勾选后该文件夹作为 `Libranote/files/` 云同步
///   （同一份开关，在同步设置页也能改）。
class DownloadPathSettingsScreen extends ConsumerStatefulWidget {
  const DownloadPathSettingsScreen({super.key});

  @override
  ConsumerState<DownloadPathSettingsScreen> createState() =>
      _DownloadPathSettingsScreenState();
}

class _DownloadPathSettingsScreenState
    extends ConsumerState<DownloadPathSettingsScreen> {
  static const _kUserFolder = 'download.user_folder';

  String? _userFolder;
  String _booksDir = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    if (mounted) {
      setState(() {
        _userFolder = prefs.getString(_kUserFolder);
        _booksDir = p.join(docs.path, 'books');
      });
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择保存文件夹');
    if (path == null || path.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserFolder, path);
    // 与云同步联动：选了文件夹后把它设为同步服务里「用户文件夹」的路径。
    await SyncService.instance
        .saveConfig(SyncService.instance.config.copyWith(userFolderPath: path));
    _load();
  }

  Future<void> _clearFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserFolder);
    // 同步联动：清掉下载文件夹时一并清掉同步配置里的路径。
    await SyncService.instance
        .saveConfig(SyncService.instance.config.copyWith(userFolderPath: ''));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cfg = SyncService.instance.config;
    return Scaffold(
      appBar: AppBar(title: const Text('下载路径设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('应用书籍目录（固定）'),
              subtitle: Text(_booksDir, style: const TextStyle(fontSize: 11.5)),
              trailing: const Text('只读', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('下载后保存到（可选文件夹）'),
                  subtitle: Text(
                    _userFolder ?? '未设置（导出/分享默认存系统下载目录）',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: _userFolder == null
                          ? colors.onSurfaceVariant
                          : colors.primary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: _pickFolder,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('选择文件夹'),
                      ),
                      if (_userFolder != null)
                        TextButton.icon(
                          onPressed: _clearFolder,
                          icon: const Icon(Icons.close, size: 18),
                          label: Text('取消选择',
                              style: TextStyle(color: colors.error)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('云同步这个文件夹'),
            subtitle: const Text('勾选后同步到坚果云 Libranote/files/'
                '（与同步设置页是同一个开关）'),
            value: cfg.syncUserFolder,
            onChanged: (v) => SyncService.instance
                .saveConfig(cfg.copyWith(syncUserFolder: v)),
          ),
          const SizedBox(height: 12),
          Text(
            '建议：把写好的文件（画布导出、笔记导出、下载的书）都存到同一个'
            '本地文件夹，再打开上面的云同步——坚果云会自动把整个文件夹同步'
            '到云端，换设备也能拉回。',
            style: TextStyle(
                fontSize: 12.5, height: 1.7, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
