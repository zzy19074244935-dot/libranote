import 'dart:convert';

/// Agent 任务的一个步骤（计划中的一个条目）。
class AiTaskStep {
  /// 步骤文字（计划里的一句话）。
  final String text;

  /// 执行状态：pending / running / done / failed / skipped。
  final String status;

  /// 执行中调用的工具名（无则为空）。
  final String toolName;

  /// 步骤结果摘要（模型产出或工具结果，展示用）。
  final String result;

  const AiTaskStep({
    required this.text,
    this.status = 'pending',
    this.toolName = '',
    this.result = '',
  });

  AiTaskStep copyWith({String? text, String? status, String? toolName, String? result}) =>
      AiTaskStep(
        text: text ?? this.text,
        status: status ?? this.status,
        toolName: toolName ?? this.toolName,
        result: result ?? this.result,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'status': status,
        'toolName': toolName,
        'result': result,
      };

  factory AiTaskStep.fromJson(Map<String, dynamic> json) => AiTaskStep(
        text: (json['text'] ?? '') as String,
        status: (json['status'] ?? 'pending') as String,
        toolName: (json['toolName'] ?? '') as String,
        result: (json['result'] ?? '') as String,
      );
}

/// 一个 Agent 任务（计划 → 执行 → 汇报）。
///
/// 状态机：planning → awaiting_confirm → running → done / failed / cancelled。
/// 特殊状态 waiting_approval = 后台遇到写操作需要用户确认（执行暂停）。
class AiTask {
  final int? id;

  /// 用户任务目标。
  final String goal;

  final String status;

  /// 计划步骤列表（JSON 数组存库，运行时展开）。
  final List<AiTaskStep> steps;

  /// 结果汇总（done 时模型给的一句话总结；failed 时是错误信息）。
  final String result;

  final int createdAt;
  final int updatedAt;

  const AiTask({
    this.id,
    required this.goal,
    this.status = 'planning',
    this.steps = const [],
    this.result = '',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  bool get isFinished =>
      status == 'done' || status == 'failed' || status == 'cancelled';

  bool get isRunning => !isFinished;

  AiTask copyWith({
    int? id,
    String? goal,
    String? status,
    List<AiTaskStep>? steps,
    String? result,
    int? createdAt,
    int? updatedAt,
  }) =>
      AiTask(
        id: id ?? this.id,
        goal: goal ?? this.goal,
        status: status ?? this.status,
        steps: steps ?? this.steps,
        result: result ?? this.result,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 计划/结果持久化为 JSON 字符串。
  String encodeSteps() => jsonEncode([for (final s in steps) s.toJson()]);

  static List<AiTaskStep> decodeSteps(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map)
            AiTaskStep.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'goal': goal,
        'status': status,
        'steps': encodeSteps(),
        'result': result,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory AiTask.fromJson(Map<String, dynamic> json) => AiTask(
        id: json['id'] as int?,
        goal: (json['goal'] ?? '') as String,
        status: (json['status'] ?? 'planning') as String,
        steps: decodeSteps(json['steps'] as String?),
        result: (json['result'] ?? '') as String,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      );
}
