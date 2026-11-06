import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/ai_models.dart';

/// AI 对话历史的导出与上下文组装。
///
/// 导出格式固定 txt / md / json 三种——全部是外部设备（记事本/Office/
/// 编辑器）能直接打开编辑的纯文本，满足「导出后还能在别的设备改」。
class ChatHistoryService {
  ChatHistoryService._();

  static const formats = ['md', 'txt', 'json'];

  /// 组装给模型的上下文：最近的 [limit] 条消息（含新发的这条）。
  /// 只带 role/content 两个字段，不把内部 id/时间泄漏进请求。
  ///
  /// Phase 6：**过滤 role=='tool' 的记录**——工具消息只是执行痕迹的展示
  /// 卡片，回喂给模型需要带 tool_call_id 的完整序列，不能从历史里裸塞。
  static List<Map<String, String>> buildContext(
    List<AiMessage> messages, {
    int limit = 10,
  }) {
    final usable = messages.where((m) => m.role != 'tool').toList();
    final recent = usable.length <= limit
        ? usable
        : usable.sublist(usable.length - limit);
    return [
      for (final m in recent) {'role': m.role, 'content': m.content},
    ];
  }

  static String _fmt(int ms) => DateFormat('yyyy-MM-dd HH:mm:ss')
      .format(DateTime.fromMillisecondsSinceEpoch(ms));

  /// 导出的标题：书内对话用书名，纯 AI 用对话标题。
  static String displayTitle(AiConversation c) {
    if (!c.isPureAi && c.fileName.isNotEmpty) return c.fileName;
    return c.title.isNotEmpty ? c.title : '未命名对话';
  }

  // ── 序列化 ─────────────────────────────────────────────────────────

  static String toTxt(AiConversation c, List<AiMessage> messages) {
    final buf = StringBuffer()
      ..writeln(displayTitle(c))
      ..writeln('导出时间: ${_fmt(DateTime.now().millisecondsSinceEpoch)}')
      ..writeln();
    for (final m in messages) {
      final who = m.role == 'user' ? '我' : 'AI';
      buf
        ..writeln('【$who】${_fmt(m.createdAt)}')
        ..writeln(m.content)
        ..writeln();
    }
    return buf.toString();
  }

  static String toMarkdown(AiConversation c, List<AiMessage> messages) {
    final buf = StringBuffer()
      ..writeln('# ${displayTitle(c)}')
      ..writeln()
      ..writeln('> 导出时间: ${_fmt(DateTime.now().millisecondsSinceEpoch)}')
      ..writeln();
    for (final m in messages) {
      buf
        ..writeln(m.role == 'user' ? '## 🧑 我' : '## 🤖 AI')
        ..writeln('_${_fmt(m.createdAt)}_')
        ..writeln()
        ..writeln(m.content)
        ..writeln();
    }
    return buf.toString();
  }

  static String toJson(AiConversation c, List<AiMessage> messages) {
    return const JsonEncoder.withIndent('  ').convert({
      'title': displayTitle(c),
      'file_name': c.fileName,
      'file_type': c.fileType,
      'created_at': c.createdAt,
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'messages': [
        for (final m in messages)
          {
            'role': m.role,
            'content': m.content,
            'created_at': m.createdAt,
          },
      ],
    });
  }

  static String serialize(
      AiConversation c, List<AiMessage> messages, String format) {
    switch (format) {
      case 'md':
        return toMarkdown(c, messages);
      case 'json':
        return toJson(c, messages);
      case 'txt':
      default:
        return toTxt(c, messages);
    }
  }

  /// 写临时文件并调系统分享（与 readest 笔记导出的落盘方式一致）。
  static Future<void> export({
    required AiConversation conversation,
    required List<AiMessage> messages,
    required String format,
  }) async {
    final dir = await getTemporaryDirectory();
    final safeName = displayTitle(conversation)
        .replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), '_')
        .trim();
    final file = File(p.join(
      dir.path,
      'ai-chat-${safeName.isEmpty ? conversation.id : safeName}-'
      '${DateTime.now().millisecondsSinceEpoch}.$format',
    ));
    await file.writeAsString(serialize(conversation, messages, format),
        encoding: utf8);
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: '${displayTitle(conversation)} · AI 对话',
    );
  }
}
