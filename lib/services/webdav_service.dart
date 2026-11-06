import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:xml/xml.dart';

/// 坚果云 WebDAV 客户端（Phase 5 云同步的传输层）。
///
/// 设计（结合 Phase 0 对 webdav_client 1.2.2 的 API 验证）：
/// - 文件操作（列目录/上传/下载/建目录/删除）走 `webdav_client`——它的
///   Basic/Digest 认证协商、302 重定向跟随、错误处理都是验证过的；
/// - **连接测试与配额走自建 dio PROPFIND**——webdav_client 的 `ping()` 用
///   OPTIONS（部分服务器会 405），且它的配额查询（`wdQuota`）是注释掉的
///   死代码；PROPFIND 才是 WebDAV 语义里最可靠的连通性/配额探测方式。
///
/// WebDAV 跟随服务端的重定向，例如重定向到存储节点。
class WebdavQuota {
  final int usedBytes;
  final int availableBytes;

  const WebdavQuota({required this.usedBytes, required this.availableBytes});

  int get totalBytes => usedBytes + availableBytes;

  /// 人类可读：`12.3 MB / 1.0 GB（已用 1.2%）`
  String describe() {
    final pct = totalBytes > 0 ? (usedBytes / totalBytes * 100) : 0.0;
    return '${formatBytes(usedBytes)} / ${formatBytes(totalBytes)}'
        '（已用 ${pct.toStringAsFixed(1)}%）';
  }

  static String formatBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

/// 云端一个文件/目录的元信息（manifest 同步用）。
class WebdavEntry {
  final String path; // 相对 dav 根，如 Libranote/data/notes.json
  final bool isDir;
  final int size;
  final int mtimeMs;

  const WebdavEntry({
    required this.path,
    this.isDir = false,
    this.size = 0,
    this.mtimeMs = 0,
  });
}

/// WebDAV 异常，message 直接是可展示的中文人话（网络层抛异常，UI 层展示）。
class WebdavException implements Exception {
  final String message;
  const WebdavException(this.message);

  @override
  String toString() => message;
}

class WebdavService {
  /// 坚果云 WebDAV 端点（用户可在同步设置页改，一般不用动）。
  String server = 'https://dav.jianguoyun.com/dav/';

  /// 坚果云账号（邮箱）。
  String username = '';

  /// 应用专属密码（不是登录密码）。只存内存，持久化走 flutter_secure_storage。
  String password = '';

  bool get configured =>
      server.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  /// 每个请求新建一个短生命周期 dio；不要复用——同步会话结束后要能释放。
  Dio _dio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(minutes: 5),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (s) => s != null && s < 600,
      headers: {'Authorization': _basicAuth()},
    ));
  }

  String _basicAuth() =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// 组装完整 URL：路径**逐段** percent-encode——中文文件名不编码会 400，
  /// 整段 encode 又会把 `/` 编码掉，所以按段拆开编。
  String _url(String path) {
    final base = server.endsWith('/') ? server : '$server/';
    final segs = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return '$base$segs';
  }

  /// 新建 webdav_client 的 Client（路径同样逐段编码后再交给它）。
  Client _client() {
    final base = server.endsWith('/') ? server : '$server/';
    return newClient(base, user: username, password: password);
  }

  String _encodeRemote(String remotePath) {
    return remotePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
  }

  // ── 连接测试 / 配额 ────────────────────────────────────────────────

  /// 连接测试：PROPFIND dav 根（Depth 0）。
  ///
  /// 判据：207/200 = 连得上且账号密码正确；401 = 账号或应用密码错误；
  /// 其余状态/超时 → 带原因的中文异常。
  Future<void> testConnection() async {
    if (!configured) {
      throw const WebdavException('请先填写服务器地址、账号与应用密码');
    }
    final dio = _dio();
    try {
      final resp = await dio.request<String>(
        _url('/'),
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
        data: '<?xml version="1.0" encoding="utf-8"?>'
            '<D:propfind xmlns:D="DAV:"><D:prop>'
            '<D:displayname/><D:quota-available-bytes/><D:quota-used-bytes/>'
            '</D:prop></D:propfind>',
      );
      if (resp.statusCode == 401) {
        throw const WebdavException('账号或应用密码错误（401）。'
            '注意：坚果云要用「第三方应用管理」里生成的应用密码，'
            '不是登录密码');
      }
      if (resp.statusCode == 207 || resp.statusCode == 200) {
        debugPrint('[WebDAV] test connection OK (${resp.statusCode})');
        return;
      }
      throw WebdavException(
          '连接失败（HTTP ${resp.statusCode}）。请检查服务器地址'
          '（默认 https://dav.jianguoyun.com/dav/）');
    } on WebdavException {
      rethrow;
    } on DioException catch (e) {
      throw _mapDioError(e);
    } finally {
      dio.close();
    }
  }

  /// 读取坚果云空间配额（PROPFIND 根目录，解析 quota-* 属性）。
  /// 服务器不返回配额属性时返回 null（不当作错误）。
  Future<WebdavQuota?> fetchQuota() async {
    if (!configured) return null;
    final dio = _dio();
    try {
      final resp = await dio.request<String>(
        _url('/'),
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
        data: '<?xml version="1.0" encoding="utf-8"?>'
            '<D:propfind xmlns:D="DAV:"><D:prop>'
            '<D:quota-available-bytes/><D:quota-used-bytes/>'
            '</D:prop></D:propfind>',
      );
      if (resp.statusCode == 401) {
        throw const WebdavException('账号或应用密码错误（401）');
      }
      if (resp.statusCode != 207 && resp.statusCode != 200) {
        throw WebdavException('读取云空间失败（HTTP ${resp.statusCode}）');
      }
      final body = resp.data ?? '';
      if (body.isEmpty) return null;
      final doc = XmlDocument.parse(body);
      final used = _propValue(doc, 'quota-used-bytes');
      final available = _propValue(doc, 'quota-available-bytes');
      if (used == null && available == null) return null;
      return WebdavQuota(
        usedBytes: used ?? 0,
        availableBytes: available ?? 0,
      );
    } on WebdavException {
      rethrow;
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('解析云空间配额失败：$e');
    } finally {
      dio.close();
    }
  }

  /// 在任意命名空间里找第一个文本非空的属性（DAV: 前缀常省略或别名化）。
  int? _propValue(XmlDocument doc, String localName) {
    for (final el in doc.descendants.whereType<XmlElement>()) {
      if (el.name.local == localName) {
        return int.tryParse(el.innerText.trim());
      }
    }
    return null;
  }

  // ── 文件操作（webdav_client） ─────────────────────────────────────

  /// 列目录（Depth 1）。目录不存在抛 404 中文异常。
  Future<List<WebdavEntry>> listDir(String remoteDir) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      final files =
          await client.readDir('/${_encodeRemote(remoteDir)}');
      return [
        for (final f in files)
          if (f.name != null)
            WebdavEntry(
              path: f.path ?? f.name!,
              isDir: f.isDir ?? false,
              size: f.size ?? 0,
              mtimeMs: f.mTime?.millisecondsSinceEpoch ?? 0,
            ),
      ];
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('读取云端目录失败：$e');
    }
  }

  /// 递归建目录（已存在不报错）。
  Future<void> ensureDir(String remoteDir) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      await client.mkdirAll('/${_encodeRemote(remoteDir)}');
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('创建云端目录失败：$e');
    }
  }

  /// 上传本地文件到云端（流式，支持大文件）。
  Future<void> uploadFile(String localPath, String remotePath) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      await client.writeFromFile(localPath, '/${_encodeRemote(remotePath)}');
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('上传失败：$e');
    }
  }

  /// 下载云端文件到本地（流式）。
  Future<void> downloadFile(String remotePath, String localPath) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      await client.read2File('/${_encodeRemote(remotePath)}', localPath);
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('下载失败：$e');
    }
  }

  /// 读取云端文本文件（manifest / 配置文件）。
  Future<String> readText(String remotePath) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      final bytes =
          await client.read('/${_encodeRemote(remotePath)}');
      return utf8.decode(bytes);
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('读取云端文件失败：$e');
    }
  }

  /// 写云端文本文件（manifest / 配置文件）。
  Future<void> writeText(String remotePath, String text) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      await client.write(
        '/${_encodeRemote(remotePath)}',
        Uint8List.fromList(utf8.encode(text)),
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('写入云端文件失败：$e');
    }
  }

  /// 删除云端文件/目录（不存在视为成功）。
  Future<void> remove(String remotePath) async {
    if (!configured) {
      throw const WebdavException('请先配置坚果云账号');
    }
    final client = _client();
    try {
      await client.remove('/${_encodeRemote(remotePath)}');
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw WebdavException('删除云端文件失败：$e');
    }
  }

  // ── 错误翻译 ───────────────────────────────────────────────────────

  /// Dio 错误 → 中文人话。WebDAV 状态码语义与普通 HTTP 不同：
  /// 401=认证错、404=不存在、405=不支持、423=锁定、507=空间不足。
  WebdavException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 401:
        return const WebdavException('账号或应用密码错误（401）。'
            '坚果云要用「第三方应用管理」里的应用密码');
      case 403:
        return const WebdavException('没有权限（403），请检查账号权限');
      case 404:
        return const WebdavException('云端路径不存在（404）');
      case 405:
        return const WebdavException('服务器不支持该操作（405），'
            '请确认地址是 WebDAV 端点');
      case 423:
        return const WebdavException('文件被锁定（423），请稍后重试');
      case 507:
        return const WebdavException('坚果云空间不足（507），请清理云端空间');
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return const WebdavException('连接坚果云超时，请检查网络');
      case DioExceptionType.connectionError:
        return const WebdavException('网络连接失败，请检查网络或服务器地址');
      default:
        return WebdavException('坚果云请求失败：${e.message ?? e.type.name}');
    }
  }
}
