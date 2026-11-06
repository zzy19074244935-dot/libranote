import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_models.dart';
import '../models/models.dart' show Book;
import '../providers/providers.dart';
import '../services/services.dart';
import '../widgets/attachment_picker_sheet.dart';
import 'agent_task_screen.dart';
import 'ai_settings_screen.dart';
import 'summarize_past_screen.dart';

/// 供其他页面（书架/阅读器）通知 AI 中心刷新侧栏历史。
final aiCenterRefreshProvider = StateProvider<int>((ref) => 0);

/// AI 中心：顶栏（侧栏开关/模型名/设置）+ 侧栏对话历史 + 聊天区。
///
/// [fileId]/[fileType]/[fileName] 非空时，直接打开该书的 AI 对话
/// （Phase 2 阅读器 AI 闭环复用；Phase 1 仅从底部导航进入，三个参数为 null，
/// 即纯 AI 对话）。
class AiCenterScreen extends ConsumerStatefulWidget {
  final String? fileId;
  final String? fileType;
  final String? fileName;

  const AiCenterScreen({
    super.key,
    this.fileId,
    this.fileType,
    this.fileName,
  });

  @override
  ConsumerState<AiCenterScreen> createState() => _AiCenterScreenState();
}

class _AiCenterScreenState extends ConsumerState<AiCenterScreen> {
  static const _presets = <(String, String)>[
    ('解释', '请解释以下内容：\n\n'),
    ('你的看法', '谈谈你对以下内容的看法：\n\n'),
    ('总结', '请总结以下内容：\n\n'),
    ('分析', '请分析以下内容：\n\n'),
    ('建议', '请针对以下内容给出建议：\n\n'),
  ];

  int? _currentConvId;
  String? _convTitle;
  final List<AiConversation> _conversations = [];
  final List<AiMessage> _messages = [];
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// 本次对话的附件（「+」上传的书库书籍 / 笔记中心笔记）。
  final List<AiAttachment> _attachments = [];

  /// 每个会话各自的附件（内存 + SharedPreferences 双层持久化）。
  final Map<int, List<AiAttachment>> _attachmentsByConv = {};
  static const _kAttachmentsPref = 'ai_center_attachments_v1';

  bool _streaming = false;
  String _streamBuffer = '';
  AiProviderConfig? _provider;
  double _fontSize = 16;

  /// 自定义提示词（预设 chips 用，加载一次）。
  final List<AiPrompt> _customPrompts = [];

  /// 启用的 AI 工具（工具行 + 工具循环用）。
  List<AiToolDefinition> _tools = const [];

  /// 侧栏统计卡数据。
  AiStats _stats = const AiStats();

  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  void initState() {
    super.initState();
    _init();
    // 别的页面（Phase 2 阅读器）新增对话后，home_screen 切 Tab 触发刷新。
    ref.listenManual(aiCenterRefreshProvider, (prev, next) {
      if (prev != next) _reloadConversations();
    });
  }

  Future<void> _init() async {
    _provider = await AiProviderStore.instance.getActive();
    _fontSize = await AiProviderStore.instance.getChatFontSize();
    _tools = await AiToolsStore.instance.enabledTools();
    _customPrompts
      ..clear()
      ..addAll(await _storage.getAiPrompts());
    _stats = await _storage.getAiStats();
    await _loadAttachmentPrefs();
    await _reloadConversations();
    if (widget.fileId != null && widget.fileType != null) {
      // 书内对话：打开（或创建）该书的会话。
      final conv = await _storage.getOrCreateAiConversation(
        fileId: widget.fileId!,
        fileType: widget.fileType!,
        fileName: widget.fileName ?? '',
      );
      await _openConv(conv.id!);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reloadConversations() async {
    final list = await _storage.listAiConversations();
    _stats = await _storage.getAiStats();
    if (!mounted) return;
    setState(() => _conversations
      ..clear()
      ..addAll(list));
  }

  Future<void> _openConv(int id) async {
    final msgs = await _storage.getAiMessages(id);
    final conv = _conversations.where((c) => c.id == id).firstOrNull;
    if (!mounted) return;
    setState(() {
      _currentConvId = id;
      _convTitle = conv?.title ?? '';
      _messages
        ..clear()
        ..addAll(msgs);
      // 恢复该会话的附件。
      _attachments
        ..clear()
        ..addAll(_attachmentsByConv[id] ?? const <AiAttachment>[]);
    });
    _scrollToBottom();
  }

  void _newChat() {
    setState(() {
      _currentConvId = null;
      _convTitle = null;
      _messages.clear();
      _streamBuffer = '';
      _attachments.clear();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  /// 组装系统提示：用户把某条自定义提示词设为「系统提示」时带上。
  Future<String?> _systemPrompt() async {
    final id = await AiToolsStore.instance.systemPromptId();
    if (id == null) return null;
    final prompts = await _storage.getAiPrompts();
    for (final p in prompts) {
      if (p.id == id) return p.content;
    }
    return null;
  }

  // ── 附件（「+」上传书库/笔记） ────────────────────────────────────

  Future<void> _loadAttachmentPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kAttachmentsPref);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _attachmentsByConv.clear();
      for (final e in map.entries) {
        final id = int.tryParse(e.key);
        if (id == null || e.value is! String) continue;
        _attachmentsByConv[id] =
            AiAttachment.listFromJson(e.value as String);
      }
    } catch (_) {
      // 附件只是增强上下文，恢复失败不阻断对话。
    }
  }

  Future<void> _saveAttachmentPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kAttachmentsPref,
        jsonEncode({
          for (final e in _attachmentsByConv.entries)
            '${e.key}': AiAttachment.listToJson(e.value),
        }),
      );
    } catch (_) {}
  }

  /// 附件 → 喂给模型的系统提示（让模型知道有资料可读 + 用哪些工具）。
  String? _attachmentHint() {
    if (_attachments.isEmpty) return null;
    final lines = <String>[];
    for (var i = 0; i < _attachments.length; i++) {
      final a = _attachments[i];
      lines.add('${i + 1}. [${a.isBook ? '书' : '笔记'}] ${a.label}'
          '${a.detail.isNotEmpty ? '（${a.detail}）' : ''}');
    }
    return '用户已把以下资料上传到本次对话（附件），回答时可先用工具读取：\n'
        '${lines.join('\n')}\n'
        '附件相关工具：list_attached_files（列出附件）、'
        'read_attached_file（读取某个附件，书支持章节/页码/段落定位）、'
        'search_attached_files（在附件里全文搜索）。'
        '此外你也能直接读/搜用户书架上的其他书：'
        'read_bookshelf_book（按书名读任意书）/ search_bookshelf（全库检索）。';
  }

  /// 打开「+」上传选择器（书库 / 笔记中心）。
  Future<void> _pickAttachments() async {
    final picked = await showModalBottomSheet<List<AiAttachment>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (ctx) => AttachmentPickerSheet(
        storage: _storage,
        already: {for (final a in _attachments) a.key},
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(picked));
    final convId = _currentConvId;
    if (convId != null) {
      _attachmentsByConv[convId] = List.of(_attachments);
    }
    await _saveAttachmentPrefs();
    _toast('已添加 ${picked.length} 个附件，AI 可通过工具读取它们');
  }

  void _removeAttachment(AiAttachment a) {
    setState(() => _attachments.removeWhere((x) => x.key == a.key));
    final convId = _currentConvId;
    if (convId != null) {
      _attachmentsByConv[convId] = List.of(_attachments);
    }
    _saveAttachmentPrefs();
  }

  /// 内置写工具的放行确认（设置里开了「自动放行」则跳过）。
  Future<bool> _confirmWriteTool(
      AiToolDefinition tool, AiToolCall call) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 想修改 App 数据'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工具：${tool.label}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('参数：${_truncate(call.arguments, 220)}',
                style: const TextStyle(fontSize: 12, height: 1.5)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('拒绝')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('允许')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// 把 AI 回复保存为某本书的 AI 笔记（功能 1：生成内容直接进笔记）。
  Future<void> _saveReplyAsNote(String content) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final books = await _storage.getBookshelf();
    if (books.isEmpty) {
      _toast('书架上还没有书，请先导入书籍');
      return;
    }
    Book? target;
    // 优先挂到附件里的第一本书。
    for (final a in _attachments) {
      if (!a.isBook) continue;
      for (final b in books) {
        if (b.id == a.ref) {
          target = b;
          break;
        }
      }
      if (target != null) break;
    }
    target ??= await _pickBookForNote(books);
    if (target == null || !mounted) return;
    await _storage.insertAiNote(AiNote(
      bookId: target.id,
      fileType: (target.extension ?? 'pdf').toLowerCase(),
      anchor: jsonEncode({'source': 'ai_assistant'}),
      quotedText: 'AI 生成',
      content: text,
    ));
    _toast('已保存为《${target.title}》的 AI 笔记（笔记中心可见）');
  }

  Future<Book?> _pickBookForNote(List<Book> books) async {
    return showDialog<Book>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存到哪本书的笔记？'),
        content: SizedBox(
          width: double.maxFinite,
          height: 320,
          child: ListView.builder(
            itemCount: books.length,
            itemBuilder: (ctx, i) {
              final b = books[i];
              return ListTile(
                dense: true,
                title: Text(b.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${b.author} · ${(b.extension ?? '').toUpperCase()}',
                    style: const TextStyle(fontSize: 11.5)),
                onTap: () => Navigator.pop(ctx, b),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _streaming) return;

    final provider = await AiProviderStore.instance.getActive();
    if (provider == null) {
      _toast('请先在 AI 设置里开启一个供应商并配置 API Key');
      _openAiSettings();
      return;
    }
    final key = await AiProviderStore.instance.getApiKey(provider.id);
    if (key == null || key.isEmpty) {
      _toast('供应商「${provider.name}」还没有 API Key，请到 AI 设置里填写');
      _openAiSettings();
      return;
    }

    _inputCtrl.clear();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 纯 AI 新对话：发第一条消息时才建会话（避免空会话堆积）。
    int convId;
    if (_currentConvId == null) {
      convId = await _storage.insertAiConversation(AiConversation(
        title: _truncate(text, 24),
        createdAt: now,
        updatedAt: now,
      ));
    } else {
      convId = _currentConvId!;
    }

    final userMsg = AiMessage(
      conversationId: convId,
      role: 'user',
      content: text,
      tokenUsage: AiService.estimateTokens(text),
      createdAt: now,
    );
    await _storage.insertAiMessage(userMsg);
    // 第一条消息作对话标题（书内对话的标题已由文件创建流程给定）。
    if (_convTitle == null || _convTitle!.isEmpty) {
      _convTitle = _truncate(text, 24);
      await _storage.touchAiConversation(convId, title: _convTitle);
    } else {
      await _storage.touchAiConversation(convId);
    }

    setState(() {
      _currentConvId = convId;
      _messages.add(userMsg);
      _streaming = true;
      _streamBuffer = '';
    });
    // 附件跟着会话走：新对话首条消息发出后落档。
    _attachmentsByConv[convId] = List.of(_attachments);
    _saveAttachmentPrefs();
    _scrollToBottom();

    // 系统提示 = 自定义系统提示词 + 附件提示（两者都有时拼接）。
    final customPrompt = await _systemPrompt();
    final attachmentHint = _attachmentHint();
    final combined = [
      if (customPrompt != null && customPrompt.isNotEmpty) customPrompt,
      if (attachmentHint != null) attachmentHint,
    ].join('\n\n');
    final systemPrompt = combined.isEmpty ? null : combined;
    try {
      // ── 有工具 → 走工具调用循环（非流式，状态实时显示） ──
      final tools = await AiToolsStore.instance.enabledTools();
      // MCP：启用服务器的工具并入本次请求（每次发送时拉取；有缓存）。
      final mcpTools = await McpRegistry.instance.allToolJson();
      if (tools.isNotEmpty || mcpTools.isNotEmpty) {
        final context = AiToolContext(
          storage: _storage,
          fileId: widget.fileId,
          fileType: widget.fileType,
          fileName: widget.fileName,
          attachments: List.of(_attachments),
        );
        final result = await AiService.instance.runToolLoop(
          provider: provider,
          apiKey: key,
          messages: ChatHistoryService.buildContext(_messages),
          systemPrompt: systemPrompt,
          tools: [
            for (final t in tools) t.toToolJson(),
            ...mcpTools,
          ],
          onToolCall: (name) {
            final tool = AiTools.byName(name);
            if (mounted) {
              setState(() => _streamBuffer =
                  '正在调用工具：${tool?.label ?? (name.startsWith('mcp_') ? 'MCP 工具 $name' : name)}…');
            }
          },
          executeTool: (call) async {
            // MCP 工具：直接转发给对应服务器。
            if (call.name.startsWith('mcp_')) {
              Map<String, dynamic> args = {};
              try {
                final decoded = jsonDecode(call.arguments);
                if (decoded is Map<String, dynamic>) args = decoded;
              } catch (_) {}
              return McpRegistry.instance.executeByName(call.name, args);
            }
            // 内置写工具：改 App 数据前弹确认（设置里可开「自动放行」）。
            final tool = AiTools.byName(call.name);
            if (tool != null && tool.danger != AiToolDanger.read) {
              final approved = await AiToolsStore.instance.autoApproveWrite() ||
                  await _confirmWriteTool(tool, call);
              if (!approved) return '用户拒绝了该操作（${tool.label}）';
            }
            return AiTools.executeCall(call, context);
          },
        );
        // 工具执行痕迹存成 role='tool' 的消息（气泡区渲染成卡片；
        // 回喂模型的上下文会自动过滤它们）。
        for (final c in result.calls) {
          final content = c.name == 'mind_map'
              ? 'MINDMAP:${c.result}'
              : 'TOOL:${c.name}\n${c.result}';
          await _storage.insertAiMessage(AiMessage(
            conversationId: convId,
            role: 'tool',
            content: content,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));
        }
        if (result.content.isEmpty) {
          _toast('模型没有返回内容，请换个模型试试');
        } else {
          final aiMsg = AiMessage(
            conversationId: convId,
            role: 'assistant',
            content: result.content,
            tokenUsage: AiService.estimateTokens(result.content),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          );
          await _storage.insertAiMessage(aiMsg);
          // 工具卡片与最终回答一起显示。
          await _openConv(convId);
        }
        return;
      }

      // ── 无工具 → 原有流式路径 ──
      final result = await AiService.instance.chatStream(
        provider: provider,
        apiKey: key,
        messages: ChatHistoryService.buildContext(_messages),
        systemPrompt: systemPrompt,
        onChunk: (delta) {
          if (mounted) {
            setState(() => _streamBuffer += delta);
          }
        },
      );
      final content = result.content.isNotEmpty ? result.content : _streamBuffer;
      if (content.isEmpty) {
        _toast('模型没有返回内容，请换个模型试试');
      } else {
        final aiMsg = AiMessage(
          conversationId: convId,
          role: 'assistant',
          content: content,
          tokenUsage: AiService.estimateTokens(content),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _storage.insertAiMessage(aiMsg);
        if (mounted) setState(() => _messages.add(aiMsg));
      }
    } catch (e) {
      if (mounted) {
        _toast('$e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _streaming = false;
          _streamBuffer = '';
        });
      }
      _reloadConversations();
      _scrollToBottom();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openAiSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
    ).then((_) => _refreshProviderAndFont());
  }

  Future<void> _refreshProviderAndFont() async {
    _provider = await AiProviderStore.instance.getActive();
    _fontSize = await AiProviderStore.instance.getChatFontSize();
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(AiConversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除「${ChatHistoryService.displayTitle(c)}」吗？'
            '对话内容将无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              // 全局主题 FilledButton minimumSize=(∞,52)：AlertDialog 的
              // actions 也是 Row，不覆盖会把「取消」挤出可视区。
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _storage.deleteAiConversation(c.id!);
    if (_currentConvId == c.id) _newChat();
    _reloadConversations();
  }

  Future<void> _exportConv(AiConversation c) async {
    final msgs = await _storage.getAiMessages(c.id!);
    if (!mounted) return;
    final format = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('导出格式（均可外部编辑）',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown (.md)'),
              onTap: () => Navigator.pop(ctx, 'md'),
            ),
            ListTile(
              leading: const Icon(Icons.notes_outlined),
              title: const Text('纯文本 (.txt)'),
              onTap: () => Navigator.pop(ctx, 'txt'),
            ),
            ListTile(
              leading: const Icon(Icons.data_object_outlined),
              title: const Text('JSON (.json)'),
              onTap: () => Navigator.pop(ctx, 'json'),
            ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    try {
      await ChatHistoryService.export(
          conversation: c, messages: msgs, format: format);
    } catch (e) {
      _toast('导出失败: $e');
    }
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ── 设置弹层 ───────────────────────────────────────────────────────

  Future<void> _openSettingsSheet() async {
    await _refreshProviderAndFont();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('AI 设置', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('当前模型'),
                subtitle: Text(
                  _provider == null
                      ? '未配置'
                      : '${_provider!.name} · ${_provider!.model}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickProvider();
                },
              ),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('API 配置（供应商 / Key）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _openAiSettings();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Text('字体大小'),
                    Expanded(
                      child: Slider(
                        value: _fontSize.clamp(12, 24),
                        min: 12,
                        max: 24,
                        divisions: 12,
                        label: _fontSize.round().toString(),
                        onChanged: (v) async {
                          setSheetState(() => _fontSize = v);
                          await AiProviderStore.instance.setChatFontSize(v);
                        },
                      ),
                    ),
                    Text('${_fontSize.round()}',
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    _refreshProviderAndFont();
  }

  Future<void> _pickProvider() async {
    final all = await AiProviderStore.instance.loadAll();
    final enabled = all.where((p) => p.enabled).toList();
    if (!mounted) return;
    if (enabled.isEmpty) {
      _toast('还没有开启的供应商，请先到 AI 设置里开启');
      return;
    }
    final activeId = await AiProviderStore.instance.getActiveId();
    if (!mounted) return;
    // Flutter 3.32+ 弃用了 RadioListTile 自带的 groupValue/onChanged，
    // 统一挂在 RadioGroup 上（避免 deprecated 告警）。
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择模型', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            RadioGroup<String>(
              groupValue: activeId ?? enabled.first.id,
              onChanged: (v) async {
                if (v != null) {
                  await AiProviderStore.instance.setActiveId(v);
                }
                // ctx 是弹层的 BuildContext，用 ctx.mounted 判断，
                // State 的 mounted 与它不同步（analyzer 也会拦）。
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final p in enabled)
                    RadioListTile<String>(
                      value: p.id,
                      title: Text(p.name),
                      subtitle: Text('${p.model} · ${p.baseUrl}'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    _refreshProviderAndFont();
  }

  // ── 侧栏 ───────────────────────────────────────────────────────────

  Widget _drawer() {
    final pure = _conversations.where((c) => c.isPureAi).toList();
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('对话历史',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: '新建对话',
                    icon: const Icon(Icons.add_comment_outlined),
                    onPressed: () {
                      Navigator.pop(context);
                      _newChat();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  _convSection('纯 AI 对话', pure),
                  _convSection('EPUB 对话历史',
                      _conversations.where((c) => c.fileType == 'epub').toList()),
                  _convSection('PDF 对话历史',
                      _conversations.where((c) => c.fileType == 'pdf').toList()),
                  _convSection('Word 对话历史',
                      _conversations.where((c) => c.fileType == 'docx').toList()),
                ],
              ),
            ),
            // ── 统计卡（Phase 6，借鉴 Anx Reader） ─────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                border: Border(top: BorderSide(color: Color(0xFFE8EDF3))),
              ),
              child: Row(
                children: [
                  _statItem('对话', _stats.conversations),
                  _statItem('消息', _stats.messages),
                  _statItem('Token', _stats.tokens),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, int value) {
    String display(int v) {
      if (v >= 10000) return '${(v / 1000).toStringAsFixed(1)}k';
      return '$v';
    }

    return Expanded(
      child: Column(
        children: [
          Text(display(value),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800)),
          Text(label,
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  /// 一个分区：纯 AI 直接列条目；书内对话按文件名分组。
  Widget _convSection(String title, List<AiConversation> list) {
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600)),
        ),
        if (list.first.isPureAi)
          for (final c in list) _convTile(c)
        else
          ..._groupByFile(list),
      ],
    );
  }

  List<Widget> _groupByFile(List<AiConversation> list) {
    final groups = <String, List<AiConversation>>{};
    for (final c in list) {
      groups.putIfAbsent(c.fileName, () => []).add(c);
    }
    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(28, 6, 16, 0),
        child: Text(
          entry.key.isEmpty ? '（未命名书籍）' : entry.key,
          style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      for (final c in entry.value) {
        widgets.add(_convTile(c, indent: true));
      }
    }
    return widgets;
  }

  Widget _convTile(AiConversation c, {bool indent = false}) {
    final selected = c.id == _currentConvId;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: indent ? 40 : 16, right: 4),
      selected: selected,
      title: Text(
        c.isPureAi
            ? (c.title.isEmpty ? '未命名对话' : c.title)
            : (c.title.isEmpty ? c.fileName : c.title),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, fontWeight: selected ? FontWeight.w700 : null),
      ),
      subtitle: Text(
        '${DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(c.updatedAt))}'
        ' · ${c.messageCount} 条',
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () {
        Navigator.pop(context);
        _openConv(c.id!);
      },
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) {
          if (v == 'delete') {
            _confirmDelete(c);
          } else if (v == 'export') {
            _exportConv(c);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'export', child: Text('导出')),
          PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }

  // ── 聊天区 ─────────────────────────────────────────────────────────

  Widget _bubble(AiMessage m) {
    final isUser = m.role == 'user';
    // 工具执行痕迹：渲染成可折叠的工具卡片（思维导图有专门卡片）。
    if (m.role == 'tool') {
      if (m.content.startsWith('MINDMAP:')) {
        return _MindMapCard(
            raw: m.content.substring('MINDMAP:'.length));
      }
      final rest = m.content.startsWith('TOOL:')
          ? m.content.substring('TOOL:'.length)
          : m.content;
      final newline = rest.indexOf('\n');
      final name = newline > 0
          ? rest.substring(0, newline)
          : '工具';
      final result = newline > 0 ? rest.substring(newline + 1) : rest;
      final tool = AiTools.byName(name);
      return toolCallCard(
        name: name,
        label: tool?.label ?? name,
        result: result,
      );
    }
    final bg = isUser ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final fg = isUser ? Colors.white : const Color(0xFF0F172A);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: isUser
            ? SelectableText(m.content,
                style: TextStyle(fontSize: _fontSize, height: 1.6, color: fg))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MarkdownWidget(
                    data: m.content,
                    shrinkWrap: true,
                    selectable: true,
                    config: MarkdownConfig(configs: [
                      PConfig(
                          textStyle: TextStyle(
                              fontSize: _fontSize, height: 1.7, color: fg)),
                      CodeConfig(
                          style: TextStyle(fontSize: _fontSize - 2, color: fg)),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  // AI 回复操作：复制 / 存为笔记（直接生成到某本书的笔记）。
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () async {
                          await Clipboard.setData(
                              ClipboardData(text: m.content));
                          _toast('已复制');
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Icon(Icons.copy,
                              size: 14, color: Colors.grey.shade600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _saveReplyAsNote(m.content),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.note_add_outlined,
                                  size: 14, color: Colors.grey.shade600),
                              const SizedBox(width: 3),
                              Text('存为笔记',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  /// 工具调用卡片：图标 + 名字 + 可折叠结果 + 复制。
  Widget toolCallCard({
    required String name,
    required String label,
    required String result,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.9),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF0FDF4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_toolIcon(name), size: 16, color: const Color(0xFF166534)),
                const SizedBox(width: 6),
                Text('已调用工具：$label',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF166534))),
                const Spacer(),
                InkWell(
                  onTap: () =>
                      Clipboard.setData(ClipboardData(text: result)),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.copy, size: 14, color: Color(0xFF166534)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  result,
                  style: const TextStyle(
                      fontSize: 12, height: 1.5, color: Color(0xFF14532D)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _toolIcon(String name) {
    return switch (name) {
      'calculator' => Icons.calculate_outlined,
      'current_time' => Icons.schedule,
      'mind_map' => Icons.account_tree_outlined,
      'book_search' => Icons.find_in_page_outlined,
      'bookshelf_list' => Icons.library_books_outlined,
      'organize_bookshelf' => Icons.reorder,
      'search_notes' => Icons.search,
      'reading_history' => Icons.history,
      'current_book_toc' => Icons.list_alt_outlined,
      'current_chapter_content' => Icons.article_outlined,
      'get_chapter_by_href' => Icons.menu_book_outlined,
      'list_tags' => Icons.sell_outlined,
      'list_book_tags' => Icons.label_outline,
      'apply_book_tags' => Icons.bookmark_add_outlined,
      'list_attached_files' => Icons.attach_file,
      'read_attached_file' => Icons.chrome_reader_mode_outlined,
      'search_attached_files' => Icons.manage_search,
      'read_bookshelf_book' => Icons.auto_stories_outlined,
      'search_bookshelf' => Icons.travel_explore,
      'ocr_pdf_pages' => Icons.document_scanner_outlined,
      'save_note' => Icons.note_add_outlined,
      'edit_note' => Icons.edit_note,
      'delete_note' => Icons.delete_sweep_outlined,
      'create_memo' => Icons.sticky_note_2_outlined,
      'list_memos' => Icons.list_alt_outlined,
      'move_books_to_folder' => Icons.drive_file_move_outlined,
      _ => Icons.build_outlined,
    };
  }

  Widget _inputBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(24)),
        color: Theme.of(context).colorScheme.surface,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 附件行：「+」上传的书库书籍 / 笔记中心笔记，点击 × 移除。
              if (_attachments.isNotEmpty)
                SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final a in _attachments)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InputChip(
                            avatar: Icon(
                              a.isBook
                                  ? Icons.menu_book_outlined
                                  : Icons.sticky_note_2_outlined,
                              size: 14,
                              color: const Color(0xFF7C3AED),
                            ),
                            label: SizedBox(
                              width: 150,
                              child: Text(
                                a.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: const Color(0xFFF5F3FF),
                            side: const BorderSide(color: Color(0xFFEDE9FE)),
                            onDeleted: _streaming
                                ? null
                                : () => _removeAttachment(a),
                          ),
                        ),
                    ],
                  ),
                ),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    // 自定义提示词排前面（用户自己的预设优先看到）。
                    for (final p in _customPrompts)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          avatar: const Icon(Icons.auto_awesome,
                              size: 14, color: Color(0xFF7C3AED)),
                          label: Text(p.title,
                              style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          onPressed: _streaming
                              ? null
                              : () {
                                  _inputCtrl.text = p.content;
                                  _inputCtrl.selection =
                                      TextSelection.collapsed(
                                          offset: p.content.length);
                                },
                        ),
                      ),
                    for (final (label, prompt) in _presets)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          label: Text(label, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          onPressed: _streaming
                              ? null
                              : () {
                                  _inputCtrl.text = prompt;
                                  _inputCtrl.selection =
                                      TextSelection.collapsed(
                                          offset: prompt.length);
                                },
                        ),
                      ),
                  ],
                ),
              ),
              // AI 工具行：点击把示例问题填进输入框（模型会自动调用对应工具）。
              if (_tools.isNotEmpty)
                SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final tool in _tools)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ActionChip(
                            avatar: Icon(_toolIcon(tool.name),
                                size: 14, color: const Color(0xFF166534)),
                            label: Text(tool.label,
                                style: const TextStyle(fontSize: 11.5)),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: const Color(0xFFF0FDF4),
                            side: const BorderSide(color: Color(0xFFBBF7D0)),
                            onPressed: _streaming
                                ? null
                                : () {
                                    _inputCtrl.text = tool.example;
                                    _inputCtrl.selection =
                                        TextSelection.collapsed(
                                            offset: tool.example.length);
                                  },
                          ),
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 「+」：上传书库书籍 / 笔记中心笔记。
                  IconButton(
                    tooltip: '上传书库书籍 / 笔记中心笔记（AI 可读取）',
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: _streaming ? null : _pickAttachments,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: _provider == null
                            ? '先配置 AI 模型再开始对话'
                            : '问点什么…',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: '发送',
                    icon: _streaming
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded),
                    onPressed: _streaming ? null : _send,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('AI 助手',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              _provider == null
                  ? '右上角设置 → 配置 API：\n支持 DeepSeek / Kimi / Qwen\n（Key 只保存在本机加密存储）'
                  : '点下方预设或直接输入问题\n解释 / 看法 / 总结 / 分析 / 建议 一键生成提示词',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.7, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMessages = _messages.isNotEmpty || _streaming;
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: '对话历史',
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: InkWell(
          onTap: _provider == null ? _openAiSettings : _openSettingsSheet,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_provider == null)
                const Icon(Icons.warning_amber_rounded,
                    size: 18, color: Color(0xFFF59E0B))
              else
                Icon(Icons.psychology_outlined,
                    size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _provider == null
                      ? '请配置 API'
                      : '${_provider!.name} · ${_provider!.model}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Agent 任务（AI 自主规划并执行多步骤任务）',
            icon: const Icon(Icons.rocket_launch_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AgentTaskScreen()),
              );
            },
          ),
          IconButton(
            tooltip: '总结过往（勾选对话历史与笔记，让 AI 总结/分析）',
            icon: const Icon(Icons.summarize_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const SummarizePastScreen()),
              ).then((_) => _reloadConversations());
            },
          ),
          IconButton(
            tooltip: 'AI 设置',
            icon: const Icon(Icons.tune),
            onPressed: _openSettingsSheet,
          ),
        ],
      ),
      drawer: _drawer(),
      body: Column(
        children: [
          Expanded(
            child: hasMessages
                ? ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: _messages.length + (_streaming ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i < _messages.length) return _bubble(_messages[i]);
                      // 流式中的临时气泡：随增量实时重渲染。
                      return Container(
                        margin: const EdgeInsets.symmetric(
                            vertical: 4, horizontal: 12),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.82),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: _streamBuffer.isEmpty
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 8),
                                  Text('思考中…', style: TextStyle(fontSize: 13)),
                                ],
                              )
                            : MarkdownWidget(
                                data: _streamBuffer,
                                shrinkWrap: true,
                                config: MarkdownConfig(configs: [
                                  PConfig(
                                      textStyle: TextStyle(
                                          fontSize: _fontSize, height: 1.7)),
                                ]),
                              ),
                      );
                    },
                  )
                : _emptyHint(),
          ),
          _inputBar(),
        ],
      ),
    );
  }
}

/// 思维导图卡片（mind_map 工具产物）。
///
/// 数据格式：{"mindmap":true,"title":"…","nodes":[{text, children:[…]}]}。
/// 渲染成可折叠的树 + 复制 JSON 按钮（外部可粘贴进 XMind/幕布等重排）。
class _MindMapCard extends StatefulWidget {
  final String raw;

  const _MindMapCard({required this.raw});

  @override
  State<_MindMapCard> createState() => _MindMapCardState();
}

class _MindMapCardState extends State<_MindMapCard> {
  String? _title;
  List<Map<String, dynamic>> _nodes = const [];
  final Set<String> _collapsed = {};
  bool _parseFailed = false;

  @override
  void initState() {
    super.initState();
    try {
      final map = jsonDecode(widget.raw) as Map<String, dynamic>;
      _title = map['title']?.toString();
      _nodes = [
        for (final n in (map['nodes'] as List? ?? []))
          if (n is Map) Map<String, dynamic>.from(n),
      ];
    } catch (_) {
      _parseFailed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_parseFailed) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('思维导图数据解析失败',
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade600)),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.9),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F3FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEDE9FE)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_tree_outlined,
                    size: 16, color: Color(0xFF6D28D9)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _title ?? '思维导图',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF4C1D95)),
                  ),
                ),
                InkWell(
                  onTap: () => Clipboard.setData(
                      ClipboardData(text: widget.raw)),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.copy, size: 14, color: Color(0xFF6D28D9)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _nodes.length; i++)
              _node(_nodes[i], '$i', 0),
            const SizedBox(height: 2),
            Text('点 ▸ 展开/收起 · 点复制图标拿 JSON（可粘进 XMind/幕布等工具）',
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
          ],
        ),
      ),
    );
  }

  Widget _node(Map<String, dynamic> node, String key, int depth) {
    final text = (node['text'] ?? '').toString();
    final kids = [
      for (final k in (node['children'] as List? ?? []))
        if (k is Map) Map<String, dynamic>.from(k),
    ];
    final hasKids = kids.isNotEmpty;
    final collapsed = _collapsed.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 14.0),
          child: Row(
            children: [
              if (hasKids)
                InkWell(
                  onTap: () => setState(() {
                    collapsed
                        ? _collapsed.remove(key)
                        : _collapsed.add(key);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      collapsed
                          ? Icons.arrow_right
                          : Icons.arrow_drop_down,
                      size: 18,
                      color: const Color(0xFF6D28D9),
                    ),
                  ),
                )
              else
                const SizedBox(width: 22),
              Flexible(
                child: Text(
                  text.isEmpty ? '（空节点）' : text,
                  style: TextStyle(
                    fontSize: depth == 0 ? 13 : 12,
                    height: 1.4,
                    fontWeight:
                        depth == 0 ? FontWeight.w700 : FontWeight.w500,
                    color: const Color(0xFF3B2F63),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasKids && !collapsed)
          for (var i = 0; i < kids.length; i++)
            _node(kids[i], '$key/$i', depth + 1),
      ],
    );
  }
}
