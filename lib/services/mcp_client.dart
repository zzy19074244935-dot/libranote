import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MCP 异常（带中文可读信息）。
class McpException implements Exception {
  final String message;
  const McpException(this.message);

  @override
  String toString() => message;
}

/// MCP 服务器配置（Streamable HTTP / stdio 两种传输）。
class McpServerConfig {
  final String id;
  String name;

  /// Streamable HTTP 地址（http(s)://…）。
  String? url;

  /// stdio：本地可执行文件（如 npx / uvx / 某个 exe）。
  String? command;

  /// stdio 参数（空格分隔存储，展示时 join）。
  List<String> args;

  bool enabled;

  McpServerConfig({
    required this.id,
    required this.name,
    this.url,
    this.command,
    this.args = const [],
    this.enabled = true,
  });

  bool get isHttp => url != null && url!.isNotEmpty;
  bool get isStdio => command != null && command!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'command': command,
        'args': args,
        'enabled': enabled,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) =>
      McpServerConfig(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        url: json['url'] as String?,
        command: json['command'] as String?,
        args: [
          for (final a in (json['args'] as List? ?? [])) a.toString(),
        ],
        enabled: json['enabled'] != true ? json['enabled'] != false : true,
      );

  McpServerConfig copyWith({
    String? name,
    String? url,
    String? command,
    List<String>? args,
    bool? enabled,
  }) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        command: command ?? this.command,
        args: args ?? this.args,
        enabled: enabled ?? this.enabled,
      );
}

/// MCP 工具元信息（透传给模型的 JSON Schema + 调用信息）。
class McpToolInfo {
  final String serverId;
  final String serverName;
  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;

  const McpToolInfo({
    required this.serverId,
    required this.serverName,
    required this.name,
    this.description,
    this.inputSchema = const {},
  });

  /// 给模型看的工具名（mcp_<服务器名>_<工具名>，避免与内置工具撞名）。
  String get fullName => 'mcp_${serverName}_$name';

  Map<String, dynamic> toToolJson() => {
        'type': 'function',
        'function': {
          'name': fullName,
          'description':
              '[MCP 工具 · $serverName] ${description ?? ''}'.trim(),
          'parameters': inputSchema.isEmpty
              ? {'type': 'object', 'properties': <String, dynamic>{}}
              : inputSchema,
        },
      };
}

/// MCP 注册表：服务器配置存取 + 客户端连接 + 工具列表/调用。
///
/// 传输支持：
/// - Streamable HTTP（MCP 2025-03-26 规范）：POST JSON-RPC，响应为
///   JSON 或 text/event-stream；
/// - stdio：本机进程（桌面端可用；Android 不能跑任意可执行文件，
///   会给出明确提示）。
class McpRegistry {
  McpRegistry._();
  static final McpRegistry instance = McpRegistry._();

  static const _prefsKey = 'mcp_servers_v1';

  final Map<String, _McpConn> _conns = {};
  final Map<String, List<McpToolInfo>> _toolCache = {};

  // ── 配置存取 ──────────────────────────────────────────────────────

  Future<List<McpServerConfig>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map) McpServerConfig.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (e) {
      debugPrint('[MCP] load configs failed: $e');
      return [];
    }
  }

  Future<void> saveAll(List<McpServerConfig> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode([for (final s in list) s.toJson()]));
    // 配置变了 → 清连接与工具缓存，下次重建。
    final ids = {for (final s in list) s.id};
    _conns.removeWhere((k, _) => !ids.contains(k));
    _toolCache.clear();
  }

  Future<void> upsert(McpServerConfig s) async {
    final all = await load();
    final idx = all.indexWhere((x) => x.id == s.id);
    if (idx >= 0) {
      all[idx] = s;
    } else {
      all.add(s);
    }
    await saveAll(all);
  }

  Future<void> remove(String id) async {
    final all = await load()..removeWhere((x) => x.id == id);
    await saveAll(all);
  }

  // ── 工具发现 / 调用 ───────────────────────────────────────────────

  /// 测试连接：initialize + tools/list，返回人话结果。
  Future<String> testConnection(McpServerConfig s) async {
    try {
      final tools = await listTools(s);
      return '连接成功，发现 ${tools.length} 个工具';
    } catch (e) {
      return '连接失败：$e';
    }
  }

  /// 列出单个服务器的工具（带缓存）。
  Future<List<McpToolInfo>> listTools(McpServerConfig s) async {
    final cached = _toolCache[s.id];
    if (cached != null) return cached;
    final conn = _conn(s);
    await conn.request('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'libranote', 'version': '1.0.0'},
    });
    final res = await conn.request('tools/list', <String, dynamic>{});
    final tools = ((res['result'] as Map?)?['tools'] as List?) ?? [];
    final out = <McpToolInfo>[];
    for (final t in tools) {
      if (t is! Map) continue;
      final name = t['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final schema = t['inputSchema'];
      out.add(McpToolInfo(
        serverId: s.id,
        serverName: s.name,
        name: name,
        description: t['description']?.toString(),
        inputSchema: schema is Map
            ? Map<String, dynamic>.from(schema)
            : <String, dynamic>{},
      ));
    }
    _toolCache[s.id] = out;
    return out;
  }

  /// 调用一个工具（每次调用前幂等 initialize，失败也不影响调用）。
  Future<String> callTool(
      McpServerConfig s, String tool, Map<String, dynamic> args) async {
    final conn = _conn(s);
    try {
      await conn.request('initialize', {
        'protocolVersion': '2025-03-26',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'libranote', 'version': '1.0.0'},
      });
    } catch (_) {
      // 个别服务器只认第一次 initialize，这里忽略。
    }
    final res = await conn.request('tools/call', {
      'name': tool,
      'arguments': args,
    });
    final result = res['result'];
    if (result is Map) {
      final content = result['content'];
      if (content is List) {
        final buf = StringBuffer();
        for (final c in content) {
          if (c is Map && c['type'] == 'text' && c['text'] is String) {
            buf.writeln(c['text']);
          } else if (c != null) {
            buf.writeln(c.toString());
          }
        }
        final text = buf.toString().trim();
        if (text.isNotEmpty) {
          if (result['isError'] == true) return 'MCP 工具返回错误：\n$text';
          return text;
        }
      }
    }
    return 'MCP 工具返回：${jsonEncode(result)}';
  }

  /// 全部启用服务器的工具 JSON（合并进模型 tools 列表；失败的服务跳过）。
  Future<List<Map<String, dynamic>>> allToolJson() async {
    final out = <Map<String, dynamic>>[];
    for (final s in await load()) {
      if (!s.enabled) continue;
      try {
        for (final t in await listTools(s)) {
          out.add(t.toToolJson());
        }
      } catch (e) {
        debugPrint('[MCP] list tools ${s.name} failed: $e');
      }
    }
    return out;
  }

  /// 按完整名（mcp_<服务器>_<工具>）执行，返回文本结果。
  Future<String> executeByName(
      String fullName, Map<String, dynamic> args) async {
    for (final s in await load()) {
      if (!s.enabled) continue;
      final prefix = 'mcp_${s.name}_';
      if (!fullName.startsWith(prefix)) continue;
      try {
        return await callTool(s, fullName.substring(prefix.length), args);
      } catch (e) {
        return 'MCP 工具调用失败（${s.name}）：$e';
      }
    }
    return '未知的 MCP 工具：$fullName';
  }

  /// 清除某服务器的工具缓存（测试按钮后强制刷新）。
  void invalidate(String id) => _toolCache.remove(id);

  _McpConn _conn(McpServerConfig s) {
    final existing = _conns[s.id];
    if (existing != null) return existing;
    final _McpConn conn;
    if (s.isHttp) {
      conn = _HttpConn(s.url!);
    } else if (s.isStdio) {
      if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
        throw const McpException(
            'stdio 型 MCP 服务器仅支持桌面端（Windows/macOS/Linux）');
      }
      conn = _StdioConn(s.command!, s.args);
    } else {
      throw const McpException('服务器配置不完整：需要 HTTP 地址或本地命令');
    }
    _conns[s.id] = conn;
    return conn;
  }
}

// ── 连接抽象 ─────────────────────────────────────────────────────────

abstract class _McpConn {
  int _nextId = 1;

  Future<Map<String, dynamic>> request(
      String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    return send(id, method, params);
  }

  Future<Map<String, dynamic>> send(
      int id, String method, Map<String, dynamic> params);
}

/// Streamable HTTP 传输：POST JSON-RPC；响应可能是 JSON 或 SSE 文本。
class _HttpConn extends _McpConn {
  final String url;
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 90),
    validateStatus: (s) => s != null && s < 500,
  ));

  _HttpConn(this.url);

  @override
  Future<Map<String, dynamic>> send(
      int id, String method, Map<String, dynamic> params) async {
    final resp = await _dio.post<String>(
      url,
      data: jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json, text/event-stream',
        },
        responseType: ResponseType.plain,
      ),
    );
    final body = resp.data ?? '';
    if (resp.statusCode != null && resp.statusCode! >= 400) {
      throw McpException('HTTP ${resp.statusCode}：${_short(body)}');
    }    if (body.trim().startsWith('event:') ||
        body.trim().startsWith('data:')) {
      return _parseSse(body, id);
    }
    try {
      final m = jsonDecode(body);
      if (m is Map<String, dynamic>) {
        if (m['error'] != null) {
          throw McpException(_errorText(m['error']));
        }
        return m;
      }
    } catch (e) {
      if (e is McpException) rethrow;
      throw McpException('响应不是合法 JSON：${_short(body)}');
    }
    throw const McpException('响应格式异常');
  }

  /// 从 SSE 文本里找 id 匹配的 data: 行。
  Map<String, dynamic> _parseSse(String body, int id) {
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (!t.startsWith('data:')) continue;
      final payload = t.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final m = jsonDecode(payload);
        if (m is Map<String, dynamic> && m['id'] == id) {
          if (m['error'] != null) throw McpException(_errorText(m['error']));
          return m;
        }
      } catch (e) {
        if (e is McpException) rethrow;
        // 半行 JSON：继续找下一行。
      }
    }
    throw const McpException('SSE 响应里没有找到匹配的响应');
  }

  static String _errorText(dynamic err) {
    if (err is Map && err['message'] is String) return err['message'] as String;
    return err.toString();
  }

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 200 ? one : '${one.substring(0, 200)}…';
  }
}

/// stdio 传输：启动本地进程，按行 JSON-RPC。
class _StdioConn extends _McpConn {
  final String command;
  final List<String> args;

  Process? _proc;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StringBuffer _buffer = StringBuffer();
  bool _starting = false;

  _StdioConn(this.command, this.args);

  @override
  Future<Map<String, dynamic>> send(
      int id, String method, Map<String, dynamic> params) async {
    await _ensureStarted();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _proc!.stdin.write(
          jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      await _proc!.stdin.flush();
      return await completer.future
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      _pending.remove(id);
      rethrow;
    }
  }

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    if (_starting) {
      // 简单防重入：等 50ms 再查。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_proc != null) return;
    }
    _starting = true;
    try {
      final proc = await Process.start(
        command,
        args,
        runInShell: Platform.isWindows,
      );
      _proc = proc;
      proc.stdout.transform(utf8.decoder).listen(_onLine, onDone: () {
        _failAll('MCP 进程已退出');
      });
      proc.stderr
          .transform(utf8.decoder)
          .listen((d) => debugPrint('[MCP] $command stderr: $d'));
      proc.exitCode.then((code) {
        debugPrint('[MCP] $command exited with code $code');
        _failAll('MCP 进程已退出（code $code）');
      });
    } finally {
      _starting = false;
    }
  }

  void _onLine(String chunk) {
    _buffer.write(chunk);
    final text = _buffer.toString();
    int idx;
    while ((idx = text.indexOf('\n')) >= 0) {
      final line = text.substring(0, idx).trim();
      _buffer = StringBuffer(text.substring(idx + 1));
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line);
        if (m is Map<String, dynamic> && m['id'] != null) {
          final c = _pending.remove(m['id']);
          if (c != null && !c.isCompleted) {
            if (m['error'] != null) {
              c.completeError(McpException(
                  m['error'] is Map && m['error']['message'] is String
                      ? m['error']['message'] as String
                      : m['error'].toString()));
            } else {
              c.complete(m);
            }
          }
        }
      } catch (_) {
        // 非 JSON 行（日志等）忽略。
      }
    }
  }

  void _failAll(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(McpException(reason));
    }
    _pending.clear();
    _proc = null;
  }
}
