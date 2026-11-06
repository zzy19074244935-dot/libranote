import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_models.dart';
import '../models/annotation.dart';
import '../models/memo.dart';
import '../models/whiteboard.dart';
import 'storage_service.dart';
import 'webdav_service.dart';

/// 同步配置（不含密码——密码只存 flutter_secure_storage，永不导出）。
class SyncConfig {
  String server; // WebDAV 端点，默认坚果云
  String username; // 坚果云账号（邮箱）
  bool autoOnStartup;
  bool autoOnForeground;
  bool autoOnFileChange;
  bool syncBooks; // 书籍文件同步，默认关（免费版 1GB/月流量，一本书几十 MB）
  bool syncUserFolder; // 用户指定本地文件夹同步，默认关
  String userFolderPath; // 下载路径设置里选的本地文件夹

  SyncConfig({
    this.server = 'https://dav.jianguoyun.com/dav/',
    this.username = '',
    this.autoOnStartup = true,
    this.autoOnForeground = true,
    this.autoOnFileChange = true,
    this.syncBooks = false,
    this.syncUserFolder = false,
    this.userFolderPath = '',
  });

  bool get hasAccount =>
      server.isNotEmpty && username.isNotEmpty;

  SyncConfig copyWith({
    String? server,
    String? username,
    bool? autoOnStartup,
    bool? autoOnForeground,
    bool? autoOnFileChange,
    bool? syncBooks,
    bool? syncUserFolder,
    String? userFolderPath,
  }) =>
      SyncConfig(
        server: server ?? this.server,
        username: username ?? this.username,
        autoOnStartup: autoOnStartup ?? this.autoOnStartup,
        autoOnForeground: autoOnForeground ?? this.autoOnForeground,
        autoOnFileChange: autoOnFileChange ?? this.autoOnFileChange,
        syncBooks: syncBooks ?? this.syncBooks,
        syncUserFolder: syncUserFolder ?? this.syncUserFolder,
        userFolderPath: userFolderPath ?? this.userFolderPath,
      );

  Map<String, dynamic> toJson() => {
        'server': server,
        'username': username,
        'auto_on_startup': autoOnStartup,
        'auto_on_foreground': autoOnForeground,
        'auto_on_file_change': autoOnFileChange,
        'sync_books': syncBooks,
        'sync_user_folder': syncUserFolder,
        'user_folder_path': userFolderPath,
      };

  factory SyncConfig.fromJson(Map<String, dynamic> json) => SyncConfig(
        server: (json['server'] as String?) ??
            'https://dav.jianguoyun.com/dav/',
        username: (json['username'] as String?) ?? '',
        autoOnStartup: json['auto_on_startup'] != false,
        autoOnForeground: json['auto_on_foreground'] != false,
        autoOnFileChange: json['auto_on_file_change'] != false,
        syncBooks: json['sync_books'] == true,
        syncUserFolder: json['sync_user_folder'] == true,
        userFolderPath: (json['user_folder_path'] as String?) ?? '',
      );
}

/// 一次同步的结果（同步设置页展示 + 日志）。
class SyncReport {
  int uploaded = 0;
  int downloaded = 0;
  int conflicts = 0;
  int errors = 0;
  final List<String> messages = [];

  String summary() {
    final buf = StringBuffer();
    if (uploaded > 0) buf.write('上传 $uploaded 个');
    if (downloaded > 0) {
      if (buf.isNotEmpty) buf.write('，');
      buf.write('下载 $downloaded 个');
    }
    if (conflicts > 0) {
      if (buf.isNotEmpty) buf.write('，');
      buf.write('冲突副本 $conflicts 个');
    }
    if (buf.isEmpty) return '云端已是最新，无需传输';
    return buf.toString();
  }
}

/// manifest 里的一个文件记录。
class _ManifestEntry {
  final String path;
  final int size;
  final int mtimeMs;
  final String hash;

  const _ManifestEntry({
    required this.path,
    required this.size,
    required this.mtimeMs,
    required this.hash,
  });

  Map<String, dynamic> toJson() =>
      {'path': path, 'size': size, 'mtime': mtimeMs, 'hash': hash};

  factory _ManifestEntry.fromJson(Map<String, dynamic> json) => _ManifestEntry(
        path: json['path'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtimeMs: (json['mtime'] as num?)?.toInt() ?? 0,
        hash: (json['hash'] as String?) ?? '',
      );
}

/// 待同步的本地文件条目。
class _SyncEntry {
  final String relPath; // 相对作用域根，如 'notes.json'
  final String localPath; // 本地绝对路径（上传源 / 下载目标）
  final int mtimeMs;
  final String hash;

  const _SyncEntry({
    required this.relPath,
    required this.localPath,
    required this.mtimeMs,
    required this.hash,
  });
}

/// 云同步服务（Phase 5）。
///
/// 同步范围三块，各自独立 manifest 增量同步：
/// 1. **App 数据**（默认开）：画布 / 备忘录 / 笔记 / AI 对话 / 设置配置，
///    先导出成 JSON 落本地暂存目录，再同步到云端 `Libranote/data/`；
/// 2. **书籍文件**（默认关）：书架里的书 → `Libranote/books/`；
/// 3. **用户指定文件夹**（默认关，与下载路径设置联动）→ `Libranote/files/`。
///
/// 冲突策略：两边都改过 → mtime 最后写入胜，落败方在本地保留
/// `xxx.conflict-<时间>` 副本（永远不静默丢数据）。
/// 删除策略：**同步只做备份，不传播删除**——本地删了云端保留；云端有而
/// 本地没有的文件会下载回来（换机恢复）。这与「坚果云是数据备份」的
/// 产品定位一致，避免一台设备误删把所有设备都删光。
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  static const String remoteRoot = 'Libranote';

  /// StorageService 数据写入钩子：任何笔记/画布/备忘录写库后触发一次
  /// 防抖同步（main.dart 里把 StorageService.onDataChanged 指到这里）。
  static void Function()? onDataChanged;

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  static const _securePasswordKey = 'webdav_password';

  SyncConfig config = SyncConfig();
  String? _password;
  bool _running = false;
  Timer? _debounce;
  StorageService? _storage;

  DateTime? lastSyncAt; // 上次同步完成时间（内存，设置页展示）
  SyncReport? lastReport;

  // ── 配置存取 ───────────────────────────────────────────────────────

  Future<void> init() async {
    await _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sync_config_v1');
      if (raw != null && raw.isNotEmpty) {
        config =
            SyncConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
      _password = await _secure.read(key: _securePasswordKey);
    } catch (e) {
      debugPrint('[Sync] load config failed: $e');
    }
  }

  Future<void> saveConfig(SyncConfig c, {String? newPassword}) async {
    config = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_config_v1', jsonEncode(c.toJson()));
    if (newPassword != null) {
      _password = newPassword.trim();
      if (_password!.isEmpty) {
        await _secure.delete(key: _securePasswordKey);
      } else {
        await _secure.write(key: _securePasswordKey, value: _password!);
      }
    }
    debugPrint('[Sync] config saved (server=${c.server}, user=${c.username})');
  }

  bool get configured =>
      config.hasAccount && _password != null && _password!.isNotEmpty;

  String? get password => _password;

  void attachStorage(StorageService storage) {
    _storage = storage;
  }

  // ── 配置导出/导入 ──────────────────────────────────────────────────

  /// 导出同步配置 JSON（**不含密码**——导入后要重新填一次应用密码，
  /// 这是刻意的安全边界）。
  Future<String> exportConfigJson() async {
    final map = config.toJson();
    map['exported_at'] = DateTime.now().millisecondsSinceEpoch;
    map['note'] = '导入后需重新填写坚果云应用密码（密码不随配置导出）';
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// 导入配置 JSON：覆盖除密码外的全部字段；密码保留本机已存的。
  Future<String> importConfigJson(String raw) async {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final imported = SyncConfig.fromJson(map);
    final merged = SyncConfig(
      server: imported.server,
      username: imported.username,
      autoOnStartup: imported.autoOnStartup,
      autoOnForeground: imported.autoOnForeground,
      autoOnFileChange: imported.autoOnFileChange,
      syncBooks: imported.syncBooks,
      syncUserFolder: imported.syncUserFolder,
      userFolderPath: imported.userFolderPath,
    );
    await saveConfig(merged);
    return '配置已导入：${merged.server} · ${merged.username}'
        '${_password == null || _password!.isEmpty ? '\n⚠ 还需填写应用密码' : ''}';
  }

  // ── 连接测试 / 配额 ────────────────────────────────────────────────

  Future<void> testConnection() async {
    await _dav().testConnection();
  }

  Future<WebdavQuota?> fetchQuota() async {
    if (!configured) return null;
    return _dav().fetchQuota();
  }

  WebdavService _dav() {
    final dav = WebdavService()
      ..server = config.server
      ..username = config.username
      ..password = _password ?? '';
    return dav;
  }

  // ── 触发调度 ───────────────────────────────────────────────────────

  bool get autoSyncEnabled =>
      config.autoOnStartup || config.autoOnForeground || config.autoOnFileChange;

  /// App 启动后延迟触发（等 UI 就绪 + 数据库打开）。
  void scheduleStartupSync() {
    if (!configured || !config.autoOnStartup) return;
    debugPrint('[Sync] scheduled startup sync');
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 6), () {
      syncNow(onMessage: (m) => debugPrint('[Sync] $m'));
    });
  }

  /// App 回前台触发。
  void onForeground() {
    if (!configured || !config.autoOnForeground) return;
    debugPrint('[Sync] foreground sync triggered');
    syncNow(onMessage: (m) => debugPrint('[Sync] $m'));
  }

  /// 数据变更 → 3 秒防抖（合并连续写库）。
  void notifyFileChanged() {
    if (!configured || !config.autoOnFileChange) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      syncNow(onMessage: (m) => debugPrint('[Sync] $m'));
    });
  }

  // ── 同步主流程 ─────────────────────────────────────────────────────

  /// 立即同步三个作用域。onMessage 供 UI 展示逐条进度。
  Future<SyncReport> syncNow({
    void Function(String message)? onMessage,
  }) async {
    void log(String m) {
      debugPrint('[Sync] $m');
      onMessage?.call(m);
    }

    if (_running) {
      log('已有同步在进行中，本次跳过');
      throw const WebdavException('已有同步在进行中');
    }
    if (!configured) {
      throw const WebdavException('尚未配置坚果云：请填写账号与应用密码'
          '并先「测试连接」');
    }
    final storage = _storage;
    if (storage == null) {
      throw const WebdavException('存储尚未就绪，请稍后重试');
    }

    _running = true;
    final report = SyncReport();
    final dav = _dav();
    try {
      log('开始同步（${config.server}）…');

      // ── 作用域 1：App 数据（默认开，不可关） ──
      final dataDir = await _syncRootDir();
      final staging = Directory(p.join(dataDir.path, 'data'));
      await staging.create(recursive: true);
      await _exportAppData(storage, staging.path);
      await _syncScope(
        dav: dav,
        scopeName: 'data',
        remoteDir: '$remoteRoot/data',
        localDir: staging.path,
        downloadDir: staging.path,
        report: report,
        log: log,
      );

      // ── 作用域 2：书籍文件（默认关） ──
      if (config.syncBooks) {
        log('同步书籍文件…');
        await dav.ensureDir('$remoteRoot/books');
        final docs = await getApplicationDocumentsDirectory();
        final booksDir = Directory(p.join(docs.path, 'books'));
        await booksDir.create(recursive: true);
        // 书籍条目直接指向书架原文件（不复制），mtime 用文件修改时间；
        // 云端下载回来的书落 Documents/books，由书架刷新收养
        // （StorageService.adoptOrphanDownloads 已有此逻辑）。
        final entries = await _bookEntries(storage);
        await _syncEntries(
          dav: dav,
          scopeName: 'books',
          remoteDir: '$remoteRoot/books',
          downloadDir: booksDir.path,
          entries: entries,
          report: report,
          log: log,
        );
      }

      // ── 作用域 3：用户指定文件夹（默认关） ──
      if (config.syncUserFolder &&
          config.userFolderPath.isNotEmpty &&
          await Directory(config.userFolderPath).exists()) {
        log('同步本地文件夹 ${config.userFolderPath}…');
        await dav.ensureDir('$remoteRoot/files');
        await _syncScope(
          dav: dav,
          scopeName: 'files',
          remoteDir: '$remoteRoot/files',
          localDir: config.userFolderPath,
          downloadDir: config.userFolderPath,
          report: report,
          log: log,
        );
      }

      lastSyncAt = DateTime.now();
      lastReport = report;
      log('同步完成：${report.summary()}'
          '${report.errors > 0 ? '（${report.errors} 个错误）' : ''}');
      return report;
    } finally {
      _running = false;
    }
  }

  // ── 作用域：普通目录（数据暂存目录 / 用户文件夹） ─────────────────

  Future<void> _syncScope({
    required WebdavService dav,
    required String scopeName,
    required String remoteDir,
    required String localDir,
    required String downloadDir,
    required SyncReport report,
    required void Function(String) log,
  }) async {
    await dav.ensureDir(remoteDir);
    final entries = <_SyncEntry>[];
    final dir = Directory(localDir);
    if (await dir.exists()) {
      // 递归收集（书少文件少，深度不会太大）；跳过隐藏文件与 manifest 自身。
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (p.basename(f.path).startsWith('.')) continue;
        final rel = p.relative(f.path, from: localDir).replaceAll('\\', '/');
        entries.add(_SyncEntry(
          relPath: rel,
          localPath: f.path,
          mtimeMs: f.statSync().modified.millisecondsSinceEpoch,
          hash: await _hashFile(f.path),
        ));
      }
    }
    await _syncEntries(
      dav: dav,
      scopeName: scopeName,
      remoteDir: remoteDir,
      downloadDir: downloadDir,
      entries: entries,
      report: report,
      log: log,
    );
  }

  /// 书籍作用域：书架里的书（文件存在才同步）。
  Future<List<_SyncEntry>> _bookEntries(StorageService storage) async {
    final entries = <_SyncEntry>[];
    for (final book in await storage.getBookshelf()) {
      final path = book.localPath;
      if (path == null || path.isEmpty) continue;
      final f = File(path);
      if (!await f.exists()) continue;
      // 书名 + 格式做云端文件名；非法字符换掉，避免 WebDAV 400。
      final safeTitle = book.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      final ext = book.extension?.toLowerCase() ?? p.extension(path).replaceAll('.', '');
      entries.add(_SyncEntry(
        relPath: '${safeTitle.isEmpty ? book.id : safeTitle}.$ext',
        localPath: path,
        mtimeMs: f.statSync().modified.millisecondsSinceEpoch,
        hash: await _hashFile(path),
      ));
    }
    return entries;
  }

  // ── manifest 增量同步核心 ──────────────────────────────────────────

  Future<void> _syncEntries({
    required WebdavService dav,
    required String scopeName,
    required String remoteDir,
    required String downloadDir,
    required List<_SyncEntry> entries,
    required SyncReport report,
    required void Function(String) log,
  }) async {
    final root = await _syncRootDir();
    final manifestFile = File(p.join(root.path, 'manifest.$scopeName.json'));

    // 1) 云端 manifest（不存在 = 第一次同步）。
    Map<String, _ManifestEntry> remoteManifest = {};
    try {
      final raw = await dav.readText('$remoteDir/.manifest.json');
      remoteManifest = _decodeManifest(raw);
    } on WebdavException {
      // 404/不存在都当空处理——第一次同步。
    }

    // 2) 本地记录的「上次同步后云端状态」。
    Map<String, _ManifestEntry> prevManifest = {};
    if (await manifestFile.exists()) {
      try {
        prevManifest = _decodeManifest(await manifestFile.readAsString());
      } catch (e) {
        debugPrint('[Sync] local manifest corrupt, reset: $e');
      }
    }

    // 3) 本地当前条目。
    final local = {for (final e in entries) e.relPath: e};

    final keys = <String>{...remoteManifest.keys, ...local.keys};
    for (final key in keys) {
      final r = remoteManifest[key];
      final l = local[key];
      final p = prevManifest[key];

      if (l == null) {
        // 只有云端：本地已有一致文件（hash 相同）→ 跳过；否则下载
        // （换机恢复 / 别的设备新上传的）。
        if (r == null) continue;
        final target = _localTarget(downloadDir, key);
        if (await target.exists() &&
            await _hashFile(target.path) == r.hash) {
          continue; // 本地已有一致的文件
        }
        try {
          await _download(dav, '$remoteDir/$key', target.path);
          report.downloaded++;
          log('  下载 $key');
        } catch (e) {
          report.errors++;
          log('  下载失败 $key：$e');
        }
        continue;
      }

      if (r == null) {
        // 只有本地：上传。
        try {
          await dav.uploadFile(l.localPath, '$remoteDir/${l.relPath}');
          report.uploaded++;
          log('  上传 ${l.relPath}');
        } catch (e) {
          report.errors++;
          log('  上传失败 ${l.relPath}：$e');
        }
        continue;
      }

      final localChanged = p == null ||
          p.hash != l.hash ||
          p.mtimeMs != l.mtimeMs;
      final remoteChanged = p == null ||
          p.hash != r.hash ||
          p.mtimeMs != r.mtimeMs;

      if (!localChanged && !remoteChanged) continue;

      if (localChanged && !remoteChanged) {
        try {
          await dav.uploadFile(l.localPath, '$remoteDir/${l.relPath}');
          report.uploaded++;
          log('  上传 ${l.relPath}');
        } catch (e) {
          report.errors++;
          log('  上传失败 ${l.relPath}：$e');
        }
      } else if (!localChanged && remoteChanged) {
        try {
          final target = _localTarget(downloadDir, key);
          await _download(dav, '$remoteDir/$key', target.path);
          report.downloaded++;
          log('  下载 $key');
        } catch (e) {
          report.errors++;
          log('  下载失败 $key：$e');
        }
      } else {
        // 两边都改过：mtime 最后写入胜，落败方留冲突副本。
        if (l.mtimeMs >= r.mtimeMs) {
          try {
            // 云端版本拉下来留档，再用本地覆盖云端。
            final conflictPath = '${l.localPath}.conflict-'
                '${_ts(DateTime.now().millisecondsSinceEpoch)}';
            await _download(dav, '$remoteDir/$key', conflictPath);
            await dav.uploadFile(l.localPath, '$remoteDir/${l.relPath}');
            report.conflicts++;
            report.uploaded++;
            log('  冲突 ${l.relPath}：本地较新，云端版本保留为副本');
          } catch (e) {
            report.errors++;
            log('  冲突处理失败 ${l.relPath}：$e');
          }
        } else {
          try {
            // 本地版本复制留档，再拉云端覆盖。
            final conflictPath = '${l.localPath}.conflict-'
                '${_ts(DateTime.now().millisecondsSinceEpoch)}';
            await File(l.localPath).copy(conflictPath);
            await _download(dav, '$remoteDir/$key', l.localPath);
            report.conflicts++;
            report.downloaded++;
            log('  冲突 ${l.relPath}：云端较新，本地版本保留为副本');
          } catch (e) {
            report.errors++;
            log('  冲突处理失败 ${l.relPath}：$e');
          }
        }
      }
    }

    // 4) 重算同步后的本地状态，写本地 + 云端 manifest。
    final newManifest = <String, _ManifestEntry>{};
    for (final e in entries) {
      final f = File(e.localPath);
      if (!await f.exists()) continue;
      newManifest[e.relPath] = _ManifestEntry(
        path: e.relPath,
        size: f.lengthSync(),
        mtimeMs: f.statSync().modified.millisecondsSinceEpoch,
        hash: await _hashFile(e.localPath),
      );
    }
    // 云端有但本地没有的条目也保留在 manifest 里（换机恢复的判断依据）。
    for (final entry in remoteManifest.values) {
      newManifest.putIfAbsent(entry.path, () => entry);
    }
    final manifestJson =
        const JsonEncoder.withIndent(' ').convert({
      'version': 1,
      'files': [
        for (final v in newManifest.values) v.toJson(),
      ],
    });
    await manifestFile.writeAsString(manifestJson);
    try {
      await dav.writeText('$remoteDir/.manifest.json', manifestJson);
    } catch (e) {
      report.errors++;
      log('  写云端 manifest 失败：$e');
    }
  }

  File _localTarget(String downloadDir, String relPath) {
    return File(p.join(downloadDir, relPath));
  }

  Future<void> _download(
      WebdavService dav, String remotePath, String localPath) async {
    await File(localPath).parent.create(recursive: true);
    await dav.downloadFile(remotePath, localPath);
  }

  Map<String, _ManifestEntry> _decodeManifest(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final files = (map['files'] as List?) ?? [];
    return {
      for (final f in files.whereType<Map>())
        if (f['path'] is String)
          (f['path'] as String):
              _ManifestEntry.fromJson(Map<String, dynamic>.from(f)),
    };
  }

  // ── App 数据导出（作用域 1 的内容来源） ───────────────────────────

  Future<void> _exportAppData(StorageService storage, String staging) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 画布：白板全量（tldraw 快照与 xournalpp 多页都原样存 content JSON）。
    final boards = await storage.getWhiteboards();
    await _writeJson(p.join(staging, 'whiteboards.json'), {
      'exported_at': now,
      'whiteboards': [for (final wb in boards) wb.toJson()],
    });

    // 备忘录。
    final memos = await storage.getMemos();
    await _writeJson(p.join(staging, 'memos.json'), {
      'exported_at': now,
      'memos': [for (final m in memos) m.toJson()],
    });

    // 笔记四源（annotations / readest_notes / docx_notes / ai_notes）。
    final annotations = await storage.getAllAnnotations();
    final readest = await storage.getAllReadestNotes();
    final docx = await storage.getAllDocxNotes();
    final aiNotes = await storage.getAllAiNotes();
    await _writeJson(p.join(staging, 'notes.json'), {
      'exported_at': now,
      'annotations': [for (final a in annotations) a.toJson()],
      'readest_notes': [for (final n in readest) n.toDbRow()],
      'docx_notes': [for (final n in docx) n.toJson()],
      'ai_notes': [for (final n in aiNotes) _aiNoteToJson(n)],
    });

    // AI 对话（含消息）。
    final convs = await storage.listAiConversations();
    final convList = <Map<String, dynamic>>[];
    for (final c in convs) {
      final msgs = await storage.getAiMessages(c.id!);
      convList.add({
        'id': c.id,
        'file_id': c.fileId,
        'file_type': c.fileType,
        'file_name': c.fileName,
        'title': c.title,
        'created_at': c.createdAt,
        'updated_at': c.updatedAt,
        'messages': [
          for (final m in msgs)
            {
              'role': m.role,
              'content': m.content,
              'token_usage': m.tokenUsage,
              'created_at': m.createdAt,
            },
        ],
      });
    }
    await _writeJson(p.join(staging, 'ai_conversations.json'), {
      'exported_at': now,
      'conversations': convList,
    });

    // 设置配置（阅读/AI 中心字号/外观/TTS/翻译/下载路径；不含任何密钥）。
    final prefs = await SharedPreferences.getInstance();
    await _writeJson(p.join(staging, 'app_settings.json'), {
      'exported_at': now,
      'settings': _collectSettings(prefs),
    });

    // ── 图片/截图目录（问题14）：shots / ai_shots / photo_translate /
    // pdf_images 递归复制到 staging 同名子目录（覆盖式，跳过隐藏文件）。
    await _copyDocsDirToStaging(staging, 'shots');
    await _copyDocsDirToStaging(staging, 'ai_shots');
    await _copyDocsDirToStaging(staging, 'photo_translate');
    await _copyDocsDirToStaging(staging, 'pdf_images');
  }

  /// 把 Documents/<name>（若存在）递归复制到 staging/<name>
  /// （覆盖式，跳过隐藏文件）。
  Future<void> _copyDocsDirToStaging(String staging, String name) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final src = Directory(p.join(docs.path, name));
      if (!await src.exists()) return;
      final dst = Directory(p.join(staging, name));
      await dst.create(recursive: true);
      for (final f in src.listSync(recursive: true).whereType<File>()) {
        if (p.basename(f.path).startsWith('.')) continue;
        final rel = p.relative(f.path, from: src.path);
        final target = File(p.join(dst.path, rel));
        await target.parent.create(recursive: true);
        await f.copy(target.path);
      }
      debugPrint('[Sync] staged $name');
    } catch (e) {
      debugPrint('[Sync] stage $name failed: $e');
    }
  }

  /// 把 staging 子目录复制回 Documents 对应目录（只补不删——
  /// 本地已有同名文件就跳过，跳过隐藏文件）。
  Future<void> _copyStagingDirBack(String srcDir, String dstDir) async {
    try {
      final src = Directory(srcDir);
      if (!await src.exists()) return;
      final dst = Directory(dstDir);
      await dst.create(recursive: true);
      for (final f in src.listSync(recursive: true).whereType<File>()) {
        if (p.basename(f.path).startsWith('.')) continue;
        final rel = p.relative(f.path, from: src.path);
        final target = File(p.join(dst.path, rel));
        if (await target.exists()) continue; // 本地已有同名文件 → 跳过
        await target.parent.create(recursive: true);
        await f.copy(target.path);
      }
    } catch (e) {
      debugPrint('[Sync] restore dir failed: $e');
    }
  }

  Map<String, dynamic> _aiNoteToJson(dynamic n) {
    return {
      'book_id': n.bookId,
      'file_type': n.fileType,
      'anchor': n.anchor,
      'quoted_text': n.quotedText,
      'content': n.content,
      'image_path': n.imagePath,
      'conversation_id': n.conversationId,
      'created_at': n.createdAt,
      'updated_at': n.updatedAt,
    };
  }

  /// 收集参与同步的设置键（白名单——宁可少带，不带任何密钥）。
  Map<String, dynamic> _collectSettings(SharedPreferences prefs) {
    const keys = [
      'rs.fontSize', 'rs.lineHeight', 'rs.pageMargin', 'rs.useSerif',
      'rs.theme', 'rs.tapToTurn', 'rs.immersive',
      'ai_chat_font_size_v1',
      'appearance.mode', 'appearance.seed',
      'tts.rate', 'tts.pitch',
      'translate.enabled', 'translate.target',
      'download.user_folder',
    ];
    return {for (final k in keys) k: prefs.get(k)};
  }

  Future<void> _writeJson(String path, Map<String, dynamic> map) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(map));
  }

  // ── 云端数据导入（换机恢复） ───────────────────────────────────────

  /// 把云端同步下来的 JSON 恢复到本地库。
  /// 恢复原则：按「标题/原文+时间」去重，只补不删——导入不会动现有数据。
  Future<String> importCloudData() async {
    final storage = _storage;
    if (storage == null) throw const WebdavException('存储尚未就绪');
    final root = await _syncRootDir();
    final dataDir = Directory(p.join(root.path, 'data'));
    final counts = <String, int>{};

    Future<void> bump(String kind, int n) async {
      counts[kind] = (counts[kind] ?? 0) + n;
    }

    // 白板。
    final wbFile = File(p.join(dataDir.path, 'whiteboards.json'));
    if (await wbFile.exists()) {
      final map = jsonDecode(await wbFile.readAsString());
      final list = (map['whiteboards'] as List?) ?? [];
      var n = 0;
      final existing = await storage.getWhiteboards();
      final existingTitles = {for (final w in existing) w.title};
      for (final item in list.whereType<Map>()) {
        final wb = Whiteboard.fromJson(Map<String, dynamic>.from(item));
        if (existingTitles.contains(wb.title)) continue;
        await storage.insertWhiteboard(wb);
        n++;
      }
      await bump('画布', n);
    }

    // 备忘录。
    final memoFile = File(p.join(dataDir.path, 'memos.json'));
    if (await memoFile.exists()) {
      final map = jsonDecode(await memoFile.readAsString());
      final list = (map['memos'] as List?) ?? [];
      var n = 0;
      final existing = await storage.getMemos();
      final existingTitles = {for (final m in existing) m.title};
      for (final item in list.whereType<Map>()) {
        final memo = Memo.fromJson(Map<String, dynamic>.from(item));
        if (existingTitles.contains(memo.title)) continue;
        await storage.insertMemo(memo);
        n++;
      }
      await bump('备忘录', n);
    }

    // 笔记（只恢复书还在书架上的——notes 都挂 book_id 外键）。
    final notesFile = File(p.join(dataDir.path, 'notes.json'));
    if (await notesFile.exists()) {
      final map = jsonDecode(await notesFile.readAsString());
      final shelf = await storage.getBookshelf();
      final bookIds = {for (final b in shelf) b.id};
      var n = 0;
      for (final item
          in ((map['annotations'] as List?) ?? []).whereType<Map>()) {
        final a = Annotation.fromJson(Map<String, dynamic>.from(item));
        if (!bookIds.contains(a.bookId)) continue;
        if (a.quotedText.isEmpty) continue; // 原文铁律：缺原文不入库
        await storage.insertAnnotation(a);
        n++;
      }
      await bump('笔记', n);
    }

    // AI 对话。
    final convFile = File(p.join(dataDir.path, 'ai_conversations.json'));
    if (await convFile.exists()) {
      final map = jsonDecode(await convFile.readAsString());
      var n = 0;
      for (final item
          in ((map['conversations'] as List?) ?? []).whereType<Map>()) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final id = await storage.insertAiConversation(AiConversation(
          fileId: item['file_id'] as String?,
          fileType: item['file_type'] as String?,
          fileName: (item['file_name'] as String?) ?? '',
          title: (item['title'] as String?) ?? '',
          createdAt: (item['created_at'] as num?)?.toInt() ?? now,
          updatedAt: (item['updated_at'] as num?)?.toInt() ?? now,
        ));
        for (final m in ((item['messages'] as List?) ?? []).whereType<Map>()) {
          await storage.insertAiMessage(AiMessage(
            conversationId: id,
            role: (m['role'] as String?) ?? 'user',
            content: (m['content'] as String?) ?? '',
            tokenUsage: (m['token_usage'] as num?)?.toInt() ?? 0,
            createdAt: (m['created_at'] as num?)?.toInt() ?? now,
          ));
        }
        n++;
      }
      await bump('AI 对话', n);
    }

    // 设置配置：白名单键直接套用。
    final settingsFile = File(p.join(dataDir.path, 'app_settings.json'));
    if (await settingsFile.exists()) {
      final map = jsonDecode(await settingsFile.readAsString());
      final settings = (map['settings'] as Map?) ?? {};
      final prefs = await SharedPreferences.getInstance();
      var n = 0;
      settings.forEach((k, v) {
        if (v == null) return;
        if (v is bool) {
          prefs.setBool('$k', v);
        } else if (v is num) {
          prefs.setDouble('$k', v.toDouble());
        } else if (v is String) {
          prefs.setString('$k', v);
        }
        n++;
      });
      await bump('设置项', n);
    }

    // ── 图片/截图目录（问题14）：把四个 staging 子目录复制回 Documents
    // 对应目录（只补不删——本地已有同名文件就跳过）。
    final docsDir = await getApplicationDocumentsDirectory();
    await _copyStagingDirBack(
        p.join(dataDir.path, 'shots'), p.join(docsDir.path, 'shots'));
    await _copyStagingDirBack(p.join(dataDir.path, 'ai_shots'),
        p.join(docsDir.path, 'ai_shots'));
    await _copyStagingDirBack(p.join(dataDir.path, 'photo_translate'),
        p.join(docsDir.path, 'photo_translate'));
    await _copyStagingDirBack(p.join(dataDir.path, 'pdf_images'),
        p.join(docsDir.path, 'pdf_images'));

    final parts = [
      for (final e in counts.entries) '${e.key} ${e.value} 个',
    ];
    return parts.isEmpty
        ? '云端没有可导入的数据（先执行一次同步）'
        : '导入完成：${parts.join('、')}';
  }

  // ── 工具 ───────────────────────────────────────────────────────────

  Future<Directory> _syncRootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'libranote_sync'));
    await dir.create(recursive: true);
    return dir;
  }

  static String _ts(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// FNV-1a 64 位文件指纹（采样头/尾各 64KB + 大小——与书架文件 id 同源，
  /// 大书不全量读，避免同步慢）。
  static Future<String> _hashFile(String path) async {
    final f = File(path);
    final size = f.lengthSync();
    final raf = await f.open();
    try {
      final head = await raf.read(64 * 1024);
      var tail = <int>[];
      if (size > 64 * 1024) {
        await raf.setPosition(size - 64 * 1024);
        tail = await raf.read(64 * 1024);
      }
      var h = 0xcbf29ce484222325;
      for (final b in [...head, ...tail, ...utf8.encode('$size')]) {
        h ^= b;
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }
      return h.toRadixString(16).padLeft(16, '0');
    } finally {
      await raf.close();
    }
  }
}
