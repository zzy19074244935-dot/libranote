import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/services.dart';

/// 「总结过往」：把对话历史 + 所有笔记当成两个「文件夹」摆出来
/// （分好类、有日期、按时间排序），勾选想要的内容 → 在对话框里让 AI
/// 总结/分析/自定义操作。
///
/// · 每条可勾选/取消勾选，「重选」一键清空勾选；
/// · 每条可删除（删除的是底层真实记录，需确认）；
/// · 发送后走当前 AI 供应商流式生成，结果留在本页，同时落库为一条
///   「总结过往」对话（AI 中心侧栏可见）。
class SummarizePastScreen extends ConsumerStatefulWidget {
  const SummarizePastScreen({super.key});

  @override
  ConsumerState<SummarizePastScreen> createState() =>
      _SummarizePastScreenState();
}

/// 可勾选条目（对话 or 笔记）的统一包装。
class _SelectableItem {
  final String kind; // 'conversation' | 'annotation' | 'readest' | 'ai' | 'docx'
  final int id;
  final String title; // 对话标题 or 引用原文
  final String subtitle; // 日期/书名
  final String content; // 喂给 AI 的内容
  final String section; // 分组名（对话历史 / 书名）

  _SelectableItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.content,
    required this.section,
  });
}

class _SummarizePastScreenState extends ConsumerState<SummarizePastScreen> {
  List<_SelectableItem> _items = [];
  final Set<int> _selectedKeys = {}; // kind+id 复合 key（int）
  bool _loading = true;
  bool _streaming = false;
  String _streamBuffer = '';
  String _result = '';
  final _inputCtrl = TextEditingController();

  StorageService get _storage => ref.read(storageServiceProvider);

  static int _keyOf(String kind, int id) => '$kind:$id'.hashCode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = <_SelectableItem>[];
    final fmt = DateFormat('MM-dd HH:mm');
    try {
      // ── 文件夹 1：对话历史（按更新时间倒序） ──
      final convs = await _storage.listAiConversations();
      convs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      for (final c in convs) {
        final msgs = await _storage.getAiMessages(c.id!);
        final buf = StringBuffer();
        for (final m in msgs.where((m) => m.role != 'tool')) {
          if (m.content.isEmpty) continue;
          buf.writeln('${m.role == 'user' ? '问' : '答'}: $m.content');
        }
        if (buf.isEmpty) continue;
        final title = c.isPureAi
            ? (c.title.isEmpty ? '未命名对话' : c.title)
            : '${c.fileName} · ${c.title}';
        items.add(_SelectableItem(
          kind: 'conversation',
          id: c.id!,
          title: title,
          subtitle: fmt.format(DateTime.fromMillisecondsSinceEpoch(c.updatedAt)),
          content: buf.toString(),
          section: '对话历史',
        ));
      }

      // ── 文件夹 2：所有笔记（按书分组、按时间倒序） ──
      final annos = await _storage.getAllAnnotations();
      final readest = await _storage.getAllReadestNotes();
      final aiNotes = await _storage.getAllAiNotes();
      final docx = await _storage.getAllDocxNotes();

      void addNote({
        required String kind,
        required int id,
        required String bookTitle,
        required DateTime time,
        required String quote,
        required String note,
      }) {
        final content = StringBuffer();
        if (quote.isNotEmpty) content.writeln('原文：$quote');
        if (note.isNotEmpty) content.writeln('笔记：$note');
        items.add(_SelectableItem(
          kind: kind,
          id: id,
          title: quote.isEmpty
              ? (note.isEmpty ? '（无内容）' : note)
              : quote,
          subtitle: '$bookTitle · ${fmt.format(time)}',
          content: content.toString(),
          section: '笔记 · $bookTitle',
        ));
      }

      for (final a in annos) {
        addNote(
          kind: 'annotation',
          id: a.id!,
          bookTitle: a.bookTitle ?? '',
          time: a.createdAt,
          quote: a.quotedText,
          note: a.note,
        );
      }
      for (final n in readest) {
        addNote(
          kind: 'readest',
          id: n.id!,
          bookTitle: '',
          time: n.createdAt,
          quote: n.text,
          note: n.note,
        );
      }
      for (final n in aiNotes) {
        addNote(
          kind: 'ai',
          id: n.id!,
          bookTitle: '',
          time: DateTime.fromMillisecondsSinceEpoch(n.createdAt),
          quote: n.quotedText,
          note: n.content,
        );
      }
      for (final n in docx) {
        addNote(
          kind: 'docx',
          id: n.id!,
          bookTitle: '',
          time: n.createdAt,
          quote: n.quotedText,
          note: n.note,
        );
      }
    } catch (e) {
      debugPrint('[Summarize] load failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// 组装喂给 AI 的上下文（截断保护：单条 2000 字、总量 20000 字）。
  String _buildContext(String instruction) {
    final buf = StringBuffer();
    buf.writeln('请根据下面我勾选的内容，$instruction。');
    buf.writeln();
    final convItems =
        _items.where((i) => _selectedKeys.contains(_keyOf(i.kind, i.id)) &&
            i.kind == 'conversation').toList();
    final noteItems =
        _items.where((i) => _selectedKeys.contains(_keyOf(i.kind, i.id)) &&
            i.kind != 'conversation').toList();
    if (convItems.isNotEmpty) {
      buf.writeln('【对话历史】');
      for (final i in convItems) {
        final c = i.content.length > 2000
            ? '${i.content.substring(0, 2000)}…'
            : i.content;
        buf.writeln('## ${i.title}（${i.subtitle}）');
        buf.writeln(c);
        buf.writeln();
      }
    }
    if (noteItems.isNotEmpty) {
      buf.writeln('【笔记】');
      for (final i in noteItems) {
        final c = i.content.length > 2000
            ? '${i.content.substring(0, 2000)}…'
            : i.content;
        buf.writeln('- [${i.section}] ${i.title}（${i.subtitle}）');
        buf.writeln(c);
        buf.writeln();
      }
    }
    var text = buf.toString();
    if (text.length > 20000) {
      text = '${text.substring(0, 20000)}\n…（内容过长已截断）';
    }
    return text;
  }

  /// 删除某一条底层记录（对话或笔记），需确认。
  Future<void> _deleteItem(_SelectableItem item) async {
    final label = item.kind == 'conversation'
        ? '对话「${item.title}」'
        : '笔记「${item.title}」';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确定删除$label吗？删除的是真实记录，无法恢复。'),
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
    try {
      switch (item.kind) {
        case 'conversation':
          await _storage.deleteAiConversation(item.id);
        case 'annotation':
          await _storage.deleteAnnotation(item.id);
        case 'readest':
          await _storage.deleteReadestNote(item.id);
        case 'ai':
          await _storage.deleteAiNote(item.id);
        case 'docx':
          await _storage.deleteDocxNote(item.id);
      }
      setState(() {
        _selectedKeys.remove(_keyOf(item.kind, item.id));
      });
      await _load();
    } catch (e) {
      _toast('删除失败: $e');
    }
  }

  Future<void> _send() async {
    final instruction = _inputCtrl.text.trim();
    if (_selectedKeys.isEmpty) {
      _toast('请先勾选要总结的内容（对话历史 / 笔记）');
      return;
    }
    if (instruction.isEmpty) {
      _toast('请输入你的要求，例如：总结这些内容');
      return;
    }
    if (_streaming) return;

    final provider = await AiProviderStore.instance.getActive();
    if (provider == null) {
      _toast('请先在 AI 设置里开启一个供应商并配置 API Key');
      return;
    }
    final key = await AiProviderStore.instance.getApiKey(provider.id);
    if (key == null || key.isEmpty) {
      _toast('供应商「${provider.name}」还没有 API Key，请到 AI 设置里填写');
      return;
    }

    final context = _buildContext(instruction);
    final now = DateTime.now().millisecondsSinceEpoch;
    final convId = await _storage.insertAiConversation(AiConversation(
      title: '总结过往 ${DateFormat('MM-dd HH:mm').format(DateTime.now())}',
      createdAt: now,
      updatedAt: now,
    ));
    await _storage.insertAiMessage(AiMessage(
      conversationId: convId,
      role: 'user',
      content: instruction,
      tokenUsage: AiService.estimateTokens(context),
      createdAt: now,
    ));

    setState(() {
      _streaming = true;
      _streamBuffer = '';
      _result = '';
    });

    try {
      final result = await AiService.instance.chatStream(
        provider: provider,
        apiKey: key,
        messages: [
          {'role': 'user', 'content': context},
        ],
        onChunk: (delta) {
          if (mounted) setState(() => _streamBuffer += delta);
        },
      );
      final content = result.content.isNotEmpty ? result.content : _streamBuffer;
      if (content.isEmpty) {
        _toast('模型没有返回内容，请换个模型试试');
      } else {
        await _storage.insertAiMessage(AiMessage(
          conversationId: convId,
          role: 'assistant',
          content: content,
          tokenUsage: AiService.estimateTokens(content),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
        if (mounted) setState(() => _result = content);
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
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  int get _selectedCount => _selectedKeys.length;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('总结过往'),
        actions: [
          TextButton(
            onPressed: _selectedKeys.isEmpty
                ? null
                : () => setState(_selectedKeys.clear),
            child: const Text('重选'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // ── 选择区：两个「文件夹」（对话历史 / 笔记，按书分组） ──
                Expanded(
                  child: _items.isEmpty
                      ? const Center(
                          child: Text('还没有对话历史和笔记。\n先去读书、划高亮、和 AI 聊几句吧。',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 13)),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          children: _buildSectionList(),
                        ),
                ),
                // ── 生成结果区 ────────────────────────────────────
                if (_streaming || _result.isNotEmpty) ...[
                  const Divider(height: 1),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 260),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    color: const Color(0xFFF8FAFC),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: _result.isNotEmpty
                          ? MarkdownWidget(
                              data: _result,
                              shrinkWrap: true,
                              selectable: true,
                              config: MarkdownConfig(configs: [
                                const PConfig(
                                    textStyle: TextStyle(
                                        fontSize: 13.5, height: 1.6)),
                              ]),
                            )
                          : Text(
                              _streamBuffer.isEmpty
                                  ? '生成中…'
                                  : _streamBuffer,
                              style: const TextStyle(
                                  fontSize: 13.5, height: 1.6),
                            ),
                    ),
                  ),
                ],
                // ── 操作区 ────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                    color: Colors.white,
                    border: Border(
                        top: BorderSide(color: colors.outlineVariant)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 34,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final label in const [
                                '总结这些内容',
                                '分析这些内容',
                                '提炼重点',
                                '找出关联',
                                '概括我的学习情况',
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: ActionChip(
                                    label: Text(label,
                                        style: const TextStyle(fontSize: 12)),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _streaming
                                        ? null
                                        : () => _inputCtrl.text = label,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _inputCtrl,
                                minLines: 1,
                                maxLines: 3,
                                decoration: InputDecoration(
                                  hintText: '已选 $_selectedCount 项 · 输入你的要求',
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 10),
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
                                          strokeWidth: 2,
                                          color: Colors.white),
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
              ],
            ),
    );
  }

  /// 按文件夹分组渲染（对话历史一个组；笔记按书名分组，组内按时间排序）。
  List<Widget> _buildSectionList() {
    final groups = <String, List<_SelectableItem>>{};
    for (final i in _items) {
      groups.putIfAbsent(i.section, () => []).add(i);
    }
    // 组内按 subtitle（含日期）倒序——装载时已按时间倒序，保持原顺序。
    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Row(
          children: [
            Icon(
              entry.key == '对话历史'
                  ? Icons.folder_outlined
                  : Icons.folder_copy_outlined,
              size: 17,
              color: const Color(0xFF64748B),
            ),
            const SizedBox(width: 6),
            Text(
              entry.key,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ));
      for (final item in entry.value) {
        widgets.add(_itemTile(item));
      }
    }
    return widgets;
  }

  Widget _itemTile(_SelectableItem item) {
    final key = _keyOf(item.kind, item.id);
    final checked = _selectedKeys.contains(key);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        onTap: () {
          setState(() {
            if (checked) {
              _selectedKeys.remove(key);
            } else {
              _selectedKeys.add(key);
            }
          });
        },
        leading: Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 20,
          color: checked
              ? Theme.of(context).colorScheme.primary
              : const Color(0xFF94A3B8),
        ),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          item.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: '删除这条记录',
          onPressed: () => _deleteItem(item),
        ),
      ),
    );
  }
}
