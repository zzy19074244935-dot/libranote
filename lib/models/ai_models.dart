import 'dart:convert';

/// AI 相关数据模型：供应商配置、对话、消息、AI 标注。

/// AI 供应商配置（运行时对象）。
///
/// 持久化分两处：配置本体（除 API Key）存 shared_preferences 的 JSON 数组；
/// API Key 存 flutter_secure_storage（系统加密存储，不进 JSON，防止导出配置
/// 时把密钥一起带走）。
class AiProviderConfig {
  /// 稳定标识：预置为 'deepseek'/'kimi'/'qwen'，自定义为 'custom_<uuid>'。
  final String id;

  /// 显示名（用户可改，如「DeepSeek」「我的中转站」）。
  final String name;

  /// OpenAI 兼容 base 地址（不含 /chat/completions 尾段，保存前会归一化）。
  final String baseUrl;

  /// 默认模型名（可被「获取模型列表」覆盖）。
  final String model;

  /// 推理强度 = OpenAI 的 temperature，0~2，默认 0.7。
  final double temperature;

  /// 推理模型（kimi-k2/k3 等）只接受 temperature=1：置 true 时
  /// 请求体固定发 temperature=1（或由自动重试兜底），否则 400
  /// 「invalid temperature: only 1 is allowed」。
  final bool fixedTemperature;

  /// 供应商开关：关掉后 AI 中心与阅读器对话框都不可选。
  final bool enabled;

  /// 预置供应商不可删除（删除会把用户已配的 key 一起清掉，易误伤）。
  final bool preset;

  /// 协议类型。本版本只有 OpenAI 兼容（DeepSeek/Kimi/Qwen 都是），
  /// 字段先落库，未来加 Anthropic 风格时用。
  final String protocol;

  /// 配置教程链接（仅预置供应商有）。
  final String? tutorialUrl;

  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.temperature = 0.7,
    this.fixedTemperature = false,
    this.enabled = false,
    this.preset = false,
    this.protocol = 'openai',
    this.tutorialUrl,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'temperature': temperature,
        'fixedTemperature': fixedTemperature,
        'enabled': enabled,
        'preset': preset,
        'protocol': protocol,
        'tutorialUrl': tutorialUrl,
      };

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) {
    return AiProviderConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      model: json['model'] as String? ?? '',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      fixedTemperature: json['fixedTemperature'] == true,
      enabled: json['enabled'] == true,
      preset: json['preset'] == true,
      protocol: json['protocol'] as String? ?? 'openai',
      tutorialUrl: json['tutorialUrl'] as String?,
    );
  }

  AiProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? model,
    double? temperature,
    bool? fixedTemperature,
    bool? enabled,
    String? protocol,
    String? tutorialUrl,
  }) {
    return AiProviderConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      fixedTemperature: fixedTemperature ?? this.fixedTemperature,
      enabled: enabled ?? this.enabled,
      preset: preset,
      protocol: protocol ?? this.protocol,
      tutorialUrl: tutorialUrl ?? this.tutorialUrl,
    );
  }
}

/// 一次 AI 对话（纯 AI 中心的 fileId 为 null；书内对话绑定书籍）。
class AiConversation {
  final int? id;
  final String? fileId;
  final String? fileType; // 'epub' | 'pdf' | 'docx'；纯 AI 为 null
  final String fileName;
  final String title;
  final int createdAt;
  final int updatedAt;

  /// 消息条数（列表展示用，由查询附带，不落库）。
  final int messageCount;

  const AiConversation({
    this.id,
    this.fileId,
    this.fileType,
    this.fileName = '',
    this.title = '',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.messageCount = 0,
  });

  bool get isPureAi => fileId == null || fileId!.isEmpty;
}

/// 一条对话消息（role: 'user' | 'assistant'）。
class AiMessage {
  final int? id;
  final int conversationId;
  final String role;
  final String content;

  /// 估算 token 用量（AI 服务返回或本地估算，仅统计展示用）。
  final int tokenUsage;
  final int createdAt;

  const AiMessage({
    this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.tokenUsage = 0,
    this.createdAt = 0,
  });
}

/// AI 生成的标注（用户确认后落库；Phase 2 阅读器闭环使用）。
///
/// 铁律（方案 §2.8）：quoted_text 必填——原文缺失当缺陷修。
class AiNote {
  final int? id;
  final String bookId;
  final String fileType;
  final String anchor; // JSON：格式相关（CFI / 段落偏移 / 页码坐标）
  final String quotedText;
  final String content;
  final String? imagePath;
  final int? conversationId;
  final int createdAt;
  final int updatedAt;

  const AiNote({
    this.id,
    required this.bookId,
    required this.fileType,
    this.anchor = '{}',
    required this.quotedText,
    this.content = '',
    this.imagePath,
    this.conversationId,
    this.createdAt = 0,
    this.updatedAt = 0,
  });
}

/// 用户自定义提示词（Phase 6：AI 中心预设 chips + 可设为系统提示）。
class AiPrompt {
  final int? id;
  final String title;
  final String content;
  final int createdAt;
  final int updatedAt;

  const AiPrompt({
    this.id,
    this.title = '',
    this.content = '',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  AiPrompt copyWith({String? title, String? content}) => AiPrompt(
        id: id,
        title: title ?? this.title,
        content: content ?? this.content,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// AI 中心「+」上传的附件：书库书籍 / 笔记中心笔记。
///
/// 附件跟着对话走（按会话持久化），AI 通过工具读取附件内容
/// （list_attached_files / read_attached_file / search_attached_files）。
class AiAttachment {
  /// 'book' | 'annotation' | 'readest_note' | 'ai_note' | 'docx_note'
  final String kind;

  /// book: bookId；笔记类: 各表自增 id 的字符串。
  final String ref;

  /// 展示名（书名 / 「类型 · 原文截断」）。
  final String label;

  /// 副标题（作者·格式 / 笔记正文截断）。
  final String detail;

  const AiAttachment({
    required this.kind,
    required this.ref,
    this.label = '',
    this.detail = '',
  });

  /// 稳定唯一键（去重/选中用）。
  String get key => '$kind:$ref';

  bool get isBook => kind == 'book';

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'ref': ref,
        'label': label,
        'detail': detail,
      };

  factory AiAttachment.fromJson(Map<String, dynamic> json) => AiAttachment(
        kind: (json['kind'] ?? 'book').toString(),
        ref: (json['ref'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        detail: (json['detail'] ?? '').toString(),
      );

  static List<AiAttachment> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is Map) AiAttachment.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<AiAttachment> list) =>
      jsonEncode([for (final a in list) a.toJson()]);
}

/// AI 中心统计卡数据（Phase 6：对话数 / 消息数 / 估算 token 用量）。
class AiStats {
  final int conversations;
  final int messages;
  final int tokens;

  const AiStats({
    this.conversations = 0,
    this.messages = 0,
    this.tokens = 0,
  });
}
