import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../models/ai_models.dart';
import '../providers/providers.dart';
import '../screens/ai_settings_screen.dart';
import '../services/services.dart';

/// AI 对话框的确认结果：用户确认（可能修改过）的内容 + 可选选区截图 +
/// 对话 id（消息已落库）。
class AiDialogResult {
  final String content;
  final String? imagePath;
  final int conversationId;

  const AiDialogResult({
    required this.content,
    required this.conversationId,
    this.imagePath,
  });
}

/// 打开书内小 AI 对话框（底部弹层）。
///
/// 行为约定（方案 §2.4/§2.8）：
/// - 每次提问/回复都写进该书的 AI 会话（ai_conversations 复用一条），
///   对话历史归入 AI 中心该书会话——「取消不保留」的对象是**生成内容/
///   标注**，不是对话记录；
/// - AI 回复生成后出现可编辑区 + 确认/取消：确认 → pop 返回结果，由阅读器
///   存 ai_notes 并在原文渲染标注点；取消 → 只清编辑区，不产生标注。
Future<AiDialogResult?> showAiDialog(
  BuildContext context, {
  required String bookId,
  required String fileType,
  required String fileName,
  required String cfi,
  required String quotedText,
  String? imagePath,
  int? currentSectionIndex,
}) {
  return showModalBottomSheet<AiDialogResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AiDialogWidget(
      bookId: bookId,
      fileType: fileType,
      fileName: fileName,
      cfi: cfi,
      quotedText: quotedText,
      imagePath: imagePath,
      currentSectionIndex: currentSectionIndex,
    ),
  );
}

class AiDialogWidget extends ConsumerStatefulWidget {
  final String bookId;
  final String fileType;
  final String fileName;
  final String cfi;
  final String quotedText;
  final String? imagePath;

  /// 当前章节/页码序号（0-based；PDF 书内对话传入当前页-1，供
  /// 「当前章节内容」工具按页取文本）。
  final int? currentSectionIndex;

  const AiDialogWidget({
    super.key,
    required this.bookId,
    required this.fileType,
    required this.fileName,
    required this.cfi,
    required this.quotedText,
    this.imagePath,
    this.currentSectionIndex,
  });

  @override
  ConsumerState<AiDialogWidget> createState() => _AiDialogWidgetState();
}

class _AiDialogWidgetState extends ConsumerState<AiDialogWidget> {
  static const _presets = <(String, String)>[
    ('解释这段话', '请解释这段话'),
    ('总结', '请总结这段话'),
    ('分析', '请分析这段话'),
    ('建议', '对这段话给出你的建议'),
  ];

  int? _convId;
  final List<AiMessage> _messages = [];
  final _inputCtrl = TextEditingController();
  final _editCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  AiProviderConfig? _provider;
  String? _apiKey;
  bool _loading = true;
  bool _streaming = false;
  String _streamBuffer = '';

  /// 最近一次 AI 回复（待用户修改/确认/取消）。
  String? _lastReply;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _provider = await AiProviderStore.instance.getActive();
    if (_provider != null) {
      _apiKey = await AiProviderStore.instance.getApiKey(_provider!.id);
    }
    // 该书会话：同一次阅读中的多轮对话都进同一条记录。
    final conv = await ref.read(storageServiceProvider).getOrCreateAiConversation(
          fileId: widget.bookId,
          fileType: widget.fileType,
          fileName: widget.fileName,
        );
    _convId = conv.id;
    final msgs =
        await ref.read(storageServiceProvider).getAiMessages(conv.id!, limit: 6);
    if (!mounted) return;
    setState(() {
      _messages.addAll(msgs);
      _loading = false;
    });
    _scrollToBottom();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _editCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _streaming) return;
    final provider = _provider;
    final key = _apiKey;
    if (provider == null || key == null || key.isEmpty) {
      _toast('请先在 AI 设置里配置 API Key');
      return;
    }

    _inputCtrl.clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    final userMsg = AiMessage(
      conversationId: _convId!,
      role: 'user',
      content: text,
      tokenUsage: AiService.estimateTokens(text),
      createdAt: now,
    );
    await ref.read(storageServiceProvider).insertAiMessage(userMsg);
    await ref.read(storageServiceProvider).touchAiConversation(_convId!);
    setState(() {
      _messages.add(userMsg);
      _lastReply = null; // 新问题开始，旧编辑区收起
      _editCtrl.clear();
      _streaming = true;
      _streamBuffer = '';
    });
    _scrollToBottom();

    try {
      // Phase 6：有启用的 AI 工具 → 走工具调用循环（书内对话也能用
      // 计算器/书内搜索/标签等工具）；MCP 服务器工具一并并入。
      final tools = await AiToolsStore.instance.enabledTools();
      final mcpTools = await McpRegistry.instance.allToolJson();
      final String content;
      if (tools.isNotEmpty || mcpTools.isNotEmpty) {
        final context = AiToolContext(
          storage: ref.read(storageServiceProvider),
          fileId: widget.bookId,
          fileType: widget.fileType,
          fileName: widget.fileName,
          currentSectionIndex: widget.currentSectionIndex,
        );
        final result = await AiService.instance.runToolLoop(
          provider: provider,
          apiKey: key,
          messages: ChatHistoryService.buildContext(_messages),
          systemPrompt: _systemPrompt(),
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
            if (call.name.startsWith('mcp_')) {
              Map<String, dynamic> args = {};
              try {
                final decoded = jsonDecode(call.arguments);
                if (decoded is Map<String, dynamic>) args = decoded;
              } catch (_) {}
              return McpRegistry.instance.executeByName(call.name, args);
            }
            // 写工具：改 App 数据前弹确认。
            final tool = AiTools.byName(call.name);
            if (tool != null && tool.danger != AiToolDanger.read) {
              final ok = await AiToolsStore.instance.autoApproveWrite() ||
                  await _confirmWrite(tool, call);
              if (!ok) return '用户拒绝了该操作（${tool.label}）';
            }
            return AiTools.executeCall(call, context);
          },
        );
        // 工具痕迹一并存进该书会话（AI 中心历史可见）。
        for (final c in result.calls) {
          await ref.read(storageServiceProvider).insertAiMessage(AiMessage(
                conversationId: _convId!,
                role: 'tool',
                content: c.name == 'mind_map'
                    ? 'MINDMAP:${c.result}'
                    : 'TOOL:${c.name}\n${c.result}',
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ));
        }
        content = result.content;
      } else {
        final result = await AiService.instance.chatStream(
          provider: provider,
          apiKey: key,
          messages: ChatHistoryService.buildContext(_messages),
          systemPrompt: _systemPrompt(),
          onChunk: (delta) {
            if (mounted) {
              setState(() => _streamBuffer += delta);
            }
          },
        );
        content = result.content.isNotEmpty ? result.content : _streamBuffer;
      }
      if (content.isEmpty) {
        _toast('模型没有返回内容，请重试');
      } else {
        final aiMsg = AiMessage(
          conversationId: _convId!,
          role: 'assistant',
          content: content,
          tokenUsage: AiService.estimateTokens(content),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        );
        await ref.read(storageServiceProvider).insertAiMessage(aiMsg);
        await ref.read(storageServiceProvider).touchAiConversation(_convId!);
        if (!mounted) return;
        setState(() {
          _messages.add(aiMsg);
          _lastReply = content;
          _editCtrl.text = content;
        });
      }
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) {
        setState(() {
          _streaming = false;
          _streamBuffer = '';
        });
      }
      _scrollToBottom();
    }
  }

  /// 系统提示：告诉模型它正在回答「书里选中段落」相关的问题。
  String _systemPrompt() {
    final bookName = widget.fileName.isEmpty ? '当前书籍' : widget.fileName;
    return '你是读书助手，正在帮用户读《$bookName》。'
        '用户选中了书中一段话，请围绕这段话回答，回答用中文。\n'
        '选中原文：\n"""\n${widget.quotedText}\n"""';
  }

  /// 写工具确认：改 App 数据前问一句。
  Future<bool> _confirmWrite(AiToolDefinition tool, AiToolCall call) async {
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
            Text('参数：${call.arguments.length > 200 ? '${call.arguments.substring(0, 200)}…' : call.arguments}',
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

  /// 确认：返回用户修改后的内容，由阅读器存 ai_notes + 渲染标注。
  void _confirm() {
    final content = _editCtrl.text.trim();
    if (content.isEmpty) {
      _toast('内容为空，请保留或取消');
      return;
    }
    Navigator.pop(
      context,
      AiDialogResult(
        content: content,
        conversationId: _convId!,
        imagePath: widget.imagePath,
      ),
    );
  }

  /// 取消：不保留本次生成内容（对话记录仍在 AI 中心历史里）。
  void _cancelEdit() {
    setState(() {
      _lastReply = null;
      _editCtrl.clear();
    });
    _toast('已取消，本次内容不保存');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final insets = MediaQuery.of(context).viewInsets;
    // 键盘弹出时（编辑生成内容/输入问题），把整个弹层垫高 viewInsets
    // 的高度：否则底部按钮（确认/取消/发送）会被输入法盖住看不见。
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Container(
        height: size.height * 0.78,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
              children: [
                // ── 头部 ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome,
                          size: 18, color: Color(0xFF7C3AED)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'AI 助手 · ${widget.fileName.isEmpty ? '读书' : widget.fileName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
                      IconButton(
                        tooltip: 'AI 设置',
                        icon: const Icon(Icons.tune, size: 20),
                        onPressed: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const AiSettingsScreen()),
                          );
                          _init();
                        },
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // ── 选中原文引用 ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F3FF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFEDE9FE)),
                    ),
                    child: Text(
                      '「${widget.quotedText}」',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: Color(0xFF4C1D95)),
                    ),
                  ),
                ),
                // ── 消息区 ────────────────────────────────────────
                Expanded(
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: _messages.length + (_streaming ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i < _messages.length) return _bubble(_messages[i]);
                      return _bubble(AiMessage(
                        conversationId: 0,
                        role: 'assistant',
                        content: _streamBuffer.isEmpty ? '…' : _streamBuffer,
                      ));
                    },
                  ),
                ),
                // ── 生成结果编辑区（确认/取消） ───────────────────
                if (_lastReply != null && !_streaming)
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                      color: Color(0xFFFFFBF0),
                      border: Border(
                        top: BorderSide(color: Color(0xFFF1E6C8)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('修改生成的内容（可编辑）',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF8A6D1D))),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _editCtrl,
                          minLines: 2,
                          maxLines: 6,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                            contentPadding: EdgeInsets.all(10),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _cancelEdit,
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(0, 44),
                                  ),
                                  child: const Text('取消'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // ⚠️ 全局主题的 FilledButton minimumSize 是
                              // (double.infinity, 52)：在 Row 里会吃掉全部
                              // 宽度把相邻按钮挤出可视区（用户反馈「只有
                              // 取消」的根因）。这里必须显式覆盖成 (0, 44)。
                              Expanded(
                                flex: 2,
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.check, size: 18),
                                  label: const Text('确认保存到笔记'),
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 44),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12),
                                  ),
                                  onPressed: _confirm,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                // ── 预设 + 输入 ───────────────────────────────────
                Container(
                  decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                    border: Border(top: BorderSide(color: Color(0xFFE8EDF3))),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 32,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final (label, prompt) in _presets)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  label: Text(label,
                                      style: const TextStyle(fontSize: 12)),
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
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _inputCtrl,
                              minLines: 1,
                              maxLines: 3,
                              decoration: InputDecoration(
                                hintText: _provider == null
                                    ? '请先配置 AI（点右上 ⚙）'
                                    : '如：解释这段话 / 计算一下这题…',
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 9),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton.filled(
                            icon: _streaming
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.send_rounded, size: 20),
                            onPressed: _streaming ? null : _send,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ),
    );
  }

  Widget _bubble(AiMessage m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: isUser
            ? Text(m.content,
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Colors.white))
            : MarkdownWidget(
                data: m.content,
                shrinkWrap: true,
                config: MarkdownConfig(configs: [
                  const PConfig(
                      textStyle: TextStyle(fontSize: 13.5, height: 1.6)),
                ]),
              ),
      ),
    );
  }
}
