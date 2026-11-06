import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/mcp_client.dart';

/// MCP 服务器管理：添加/编辑/启停/测试 HTTP 与 stdio 型服务器。
class McpServersScreen extends ConsumerStatefulWidget {
  const McpServersScreen({super.key});

  @override
  ConsumerState<McpServersScreen> createState() => _McpServersScreenState();
}

class _McpServersScreenState extends ConsumerState<McpServersScreen> {
  List<McpServerConfig> _servers = [];
  final Map<String, String> _status = {}; // serverId → 测试结果
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await McpRegistry.instance.load();
    if (!mounted) return;
    setState(() {
      _servers = list;
      _loading = false;
    });
  }

  Future<void> _test(McpServerConfig s) async {
    setState(() => _status[s.id] = '测试中…');
    final result = await McpRegistry.instance.testConnection(s);
    McpRegistry.instance.invalidate(s.id);
    if (!mounted) return;
    setState(() => _status[s.id] = result);
  }

  Future<void> _toggle(McpServerConfig s, bool v) async {
    await McpRegistry.instance.upsert(s.copyWith(enabled: v));
    _load();
  }

  Future<void> _edit([McpServerConfig? s]) async {
    final saved = await showDialog<McpServerConfig>(
      context: context,
      builder: (_) => _McpEditDialog(server: s),
    );
    if (saved == null || !mounted) return;
    await McpRegistry.instance.upsert(saved);
    _load();
    // 保存后顺手测一次，让用户立刻知道通不通。
    _status[saved.id] = '测试中…';
    final result = await McpRegistry.instance.testConnection(saved);
    McpRegistry.instance.invalidate(saved.id);
    if (!mounted) return;
    setState(() => _status[saved.id] = result);
  }

  Future<void> _delete(McpServerConfig s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 MCP 服务器'),
        content: Text('确定删除「${s.name}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await McpRegistry.instance.remove(s.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 服务器'),
        actions: [
          IconButton(
            tooltip: '添加服务器',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '接入 MCP（Model Context Protocol）生态：填一个 HTTP 地址'
                  '（Streamable HTTP）或本地命令（stdio），服务器的工具就会'
                  '出现在 AI 助手的工具箱里，AI 可直接调用。',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (_servers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('还没有 MCP 服务器。点右上角 + 添加',
                          style: TextStyle(color: colors.onSurfaceVariant)),
                    ),
                  )
                else
                  for (final s in _servers) _card(s, colors),
              ],
            ),
    );
  }

  Widget _card(McpServerConfig s, ColorScheme colors) {
    final status = _status[s.id];
    final subtitle = s.isHttp
        ? s.url
        : '${s.command} ${s.args.join(' ')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            title: Text(s.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5)),
                if (status != null)
                  Text(status,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: status.startsWith('连接成功')
                            ? const Color(0xFF16A34A)
                            : colors.error,
                      )),
              ],
            ),
            trailing: Switch(value: s.enabled, onChanged: (v) => _toggle(s, v)),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('测试'),
                  onPressed: () => _test(s),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('编辑'),
                  onPressed: () => _edit(s),
                ),
                const Spacer(),
                TextButton.icon(
                  style:
                      TextButton.styleFrom(foregroundColor: colors.error),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除'),
                  onPressed: () => _delete(s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 添加/编辑 MCP 服务器的表单弹窗。
class _McpEditDialog extends StatefulWidget {
  final McpServerConfig? server;

  const _McpEditDialog({this.server});

  @override
  State<_McpEditDialog> createState() => _McpEditDialogState();
}

class _McpEditDialogState extends State<_McpEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _commandCtrl;
  late final TextEditingController _argsCtrl;
  late bool _http; // true = HTTP，false = stdio
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _urlCtrl = TextEditingController(text: s?.url ?? '');
    _commandCtrl = TextEditingController(text: s?.command ?? '');
    _argsCtrl = TextEditingController(text: (s?.args ?? const []).join(' '));
    _http = s?.isHttp ?? true;
    _enabled = s?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _commandCtrl.dispose();
    _argsCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    final command = _commandCtrl.text.trim();
    final args = _argsCtrl.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((a) => a.isNotEmpty)
        .toList();
    if (name.isEmpty) {
      _toast('请填写名称');
      return;
    }
    if (_http) {
      if (url.isEmpty || !url.startsWith('http')) {
        _toast('请填写有效的 HTTP 地址（http(s):// 开头）');
        return;
      }
    } else {
      if (command.isEmpty) {
        _toast('请填写本地命令（如 npx / uvx）');
        return;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        _toast('stdio 型服务器仅支持桌面端（Windows/macOS/Linux）');
        return;
      }
    }
    Navigator.pop(
      context,
      McpServerConfig(
        id: widget.server?.id ??
            'mcp_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        url: _http ? url : null,
        command: _http ? null : command,
        args: args,
        enabled: _enabled,
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.server == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '如：高德地图 / 本地文件',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true,
                    icon: Icon(Icons.language, size: 16),
                    label: Text('HTTP 地址')),
                ButtonSegment(
                    value: false,
                    icon: Icon(Icons.terminal, size: 16),
                    label: Text('本地命令')),
              ],
              selected: {_http},
              onSelectionChanged: (v) => setState(() => _http = v.first),
            ),
            const SizedBox(height: 12),
            if (_http)
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'HTTP 地址（Streamable HTTP）',
                  hintText: 'https://example.com/mcp',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              )
            else ...[
              TextField(
                controller: _commandCtrl,
                decoration: const InputDecoration(
                  labelText: '命令',
                  hintText: 'npx / uvx / C:\\tools\\server.exe',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _argsCtrl,
                decoration: const InputDecoration(
                  labelText: '参数（空格分隔）',
                  hintText: '-y @modelcontextprotocol/server-filesystem C:\\data',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用'),
              subtitle: const Text('启用的服务器的工具会并入 AI 工具箱',
                  style: TextStyle(fontSize: 12)),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
