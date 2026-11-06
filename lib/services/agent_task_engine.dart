import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'agent_task_notifier.dart';
import 'ai_provider_config.dart';
import 'ai_service.dart';
import 'ai_tools.dart';
import 'mcp_client.dart';
import 'storage_service.dart';

/// 待用户确认的写操作（工具名 + 参数摘要 + 所在步骤）。
class AgentApproval {
  final String toolName;
  final String toolLabel;
  final String argsSummary;
  final String stepText;
  const AgentApproval({
    required this.toolName,
    required this.toolLabel,
    required this.argsSummary,
    required this.stepText,
  });
}

/// 任务式 Agent 引擎（Phase 1）：计划 → 用户确认 → 逐步执行 → 汇报。
///
/// 单例，生命周期独立于 UI（切走页面/退回桌面任务继续跑；Android 上
/// 通过前台服务保活并展示通知进度）。所有状态通过 ChangeNotifier 广播，
/// 任务页监听刷新。
///
/// 放行策略（两级）：
/// - read 工具自动执行；
/// - write/dangerous 工具 → 任务页可见时弹确认框；后台时若设置里开了
///   「后台写操作自动放行」则放行，否则任务暂停（waiting_approval）并
///   发系统通知，用户回任务页确认后继续。
class AgentTaskEngine extends ChangeNotifier {
  AgentTaskEngine._() : _ai = AiService.instance;
  static final AgentTaskEngine instance = AgentTaskEngine._();

  @visibleForTesting
  AgentTaskEngine.testing({required AiService aiService}) : _ai = aiService;

  final AiService _ai;

  static const int maxSteps = 20;

  AiTask? _task;
  String _activity = '';
  bool _cancelled = false;
  bool _starting = false;
  bool _executing = false;
  CancelToken? _cancelToken;

  StorageService? _storage;
  AiProviderConfig? _provider;
  String? _apiKey;
  String? _systemPrompt;
  List<AiToolDefinition> _tools = const [];
  List<Map<String, dynamic>> _mcpTools = const [];
  AiToolContext? _toolContext;

  Completer<bool>? _confirmCompleter;
  Completer<bool>? _approvalCompleter;
  AgentApproval? _pendingApproval;

  /// 前台审批回调（任务页可见时挂上；null = 后台）。
  Future<bool> Function(AgentApproval approval)? approvalHandler;

  AiTask? get task => _task;
  String get activity => _activity;
  AgentApproval? get pendingApproval => _pendingApproval;
  bool get running => _starting || _executing || (_task?.isRunning ?? false);

  /// 计划阶段的元指令（追加在用户系统提示词之后）。
  static const String agentMetaPrompt = '''
你是 Libranote 的任务型 Agent，替用户完成多步骤任务。
- 规划阶段：只输出一个 JSON 字符串数组（不要输出任何其他文字），
  每个元素是任务的一个步骤（一句简短中文，3~8 步，按执行顺序）。
- 执行阶段：只完成当前这一步；可以调用工具；拿到工具结果后，
  用一句话说明这一步的结果。
- 涉及修改用户数据的工具可能被系统要求用户确认；被拒绝时不要反复
  重试，如实告诉用户即可。
''';

  /// 启动一个新任务（先落库 planning，再异步规划）。
  Future<AiTask> startTask({
    required String goal,
    required StorageService storage,
    AiToolContext? toolContext,
  }) async {
    if (running) {
      throw const FormatException('已有任务在运行');
    }
    if (goal.trim().isEmpty) throw const FormatException('请输入任务目标');
    _starting = true;
    try {
      final provider = await AiProviderStore.instance.getActive();
      if (provider == null) {
        throw const FormatException('请先在 AI 设置里开启一个供应商');
      }
      final key = await AiProviderStore.instance.getApiKey(provider.id);
      if (key == null || key.isEmpty) {
        throw FormatException('供应商「${provider.name}」还没有 API Key');
      }

      _provider = provider;
      _apiKey = key;
      _tools = await AiToolsStore.instance.enabledTools();
      // MCP：启用服务器的工具并入 Agent 工具箱。
      _mcpTools = await McpRegistry.instance.allToolJson();
      _storage = storage;
      _toolContext = toolContext ?? AiToolContext(storage: storage);
      _systemPrompt = await _loadSystemPrompt(storage);
      _cancelled = false;
      _cancelToken = CancelToken();
      _activity = '规划中…';
      _confirmCompleter = null;
      _approvalCompleter = null;
      _pendingApproval = null;

      final id = await storage.insertAiTask(AiTask(goal: goal));
      final task = AiTask(
        id: id,
        goal: goal,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _task = task;
      _executing = true;
      notifyListeners();
      AgentTaskNotifier.start(goal);

      unawaited(_run());
      return task;
    } finally {
      _starting = false;
    }
  }

  Future<String?> _loadSystemPrompt(StorageService storage) async {
    final id = await AiToolsStore.instance.systemPromptId();
    if (id == null) return null;
    final prompts = await storage.getAiPrompts();
    for (final p in prompts) {
      if (p.id == id) return p.content;
    }
    return null;
  }

  Future<void> _run() async {
    try {
      await _plan();
      if (_cancelled) {
        await _finish('cancelled', '任务已取消');
        return;
      }
      final confirm = _confirmCompleter = Completer<bool>();
      await _setStatus('awaiting_confirm');
      AgentTaskNotifier.stop(); // 等确认时不占前台服务
      final ok = await confirm.future;
      if (!ok || _cancelled) {
        await _finish('cancelled', '计划未确认，任务已取消');
        return;
      }
      AgentTaskNotifier.start(_task!.goal);
      await _setStatus('running');
      AgentTaskNotifier.updateProgress(
          _task!.goal, '开始执行', 0, _task!.steps.length);
      await _execute();
    } on AiRequestCancelled {
      await _finish('cancelled', '任务已取消');
    } catch (e) {
      debugPrint('[Agent] task failed: $e');
      await _finish(_cancelled ? 'cancelled' : 'failed',
          _cancelled ? '任务已取消' : '任务失败：$e');
    } finally {
      _executing = false;
      _pendingApproval = null;
      _confirmCompleter = null;
      _approvalCompleter = null;
      AgentTaskNotifier.stop();
      notifyListeners();
    }
  }

  /// 规划阶段：让模型输出步骤 JSON 数组。
  Future<void> _plan() async {
    final task = _task!;
    final messages = <Map<String, String>>[
      {
        'role': 'user',
        'content': '任务目标：${task.goal}\n'
            '请先规划执行步骤（只输出 JSON 字符串数组）。',
      },
    ];
    final round = await _ai.chatRound(
      provider: _provider!,
      apiKey: _apiKey!,
      messages: messages,
      systemPrompt: _mergedSystemPrompt(),
      cancelToken: _cancelToken,
    );
    _checkCancelled();
    final steps = parsePlan(round.content);
    if (steps.isEmpty) {
      throw const FormatException('模型没有给出可执行的计划');
    }
    final stepList = [
      for (final s in steps.take(maxSteps)) AiTaskStep(text: s),
    ];
    _task = task.copyWith(steps: stepList);
    await _persist();
    notifyListeners();
  }

  String _mergedSystemPrompt() {
    final user = _systemPrompt;
    if (user == null || user.isEmpty) return agentMetaPrompt;
    return '$user\n\n$agentMetaPrompt';
  }

  /// 执行阶段：逐步完成，每步一次工具循环。
  Future<void> _execute() async {
    final steps = List<AiTaskStep>.from(_task!.steps);
    final doneResults = <String>[];
    for (var i = 0; i < steps.length; i++) {
      if (_cancelled) break;
      _activity = '第 ${i + 1}/${steps.length} 步：${steps[i].text}';
      steps[i] = steps[i].copyWith(status: 'running');
      _task = _task!.copyWith(steps: steps);
      await _persist();
      notifyListeners();
      AgentTaskNotifier.updateProgress(
          _task!.goal, _activity, i + 1, steps.length);

      try {
        final messages = <Map<String, String>>[
          {
            'role': 'user',
            'content': '任务目标：${_task!.goal}\n'
                '完整计划：\n${steps.map((s) => '- ${s.text}').join('\n')}\n'
                '已完成步骤的结果：\n'
                '${doneResults.isEmpty ? '（无）' : doneResults.join('\n')}\n\n'
                '现在请完成第 ${i + 1} 步：${steps[i].text}\n'
                '完成后用一句话说明这一步的结果。',
          },
        ];
        final result = await _ai.runToolLoop(
          provider: _provider!,
          apiKey: _apiKey!,
          messages: messages,
          systemPrompt: _mergedSystemPrompt(),
          cancelToken: _cancelToken,
          tools: [
            for (final t in _tools) t.toToolJson(),
            ..._mcpTools,
          ],
          executeTool: (call) => _executeCall(call, steps[i].text),
          onToolCall: (name) {
            final t = AiTools.byName(name);
            _activity = '第 ${i + 1}/${steps.length} 步：正在调用'
                '「${t?.label ?? (name.startsWith('mcp_') ? 'MCP 工具 $name' : name)}」';
            notifyListeners();
            AgentTaskNotifier.updateProgress(
                _task!.goal, _activity, i + 1, steps.length);
          },
        );
        _checkCancelled();
        steps[i] = steps[i].copyWith(
          status: 'done',
          result: _cap(result.content, 400),
          toolName: result.calls.isNotEmpty
              ? result.calls.map((c) => c.name).join('、')
              : '',
        );
        doneResults.add('第 ${i + 1} 步：${steps[i].text}\n结果：${steps[i].result}');
      } on AiRequestCancelled {
        steps[i] = steps[i].copyWith(status: 'skipped', result: '用户取消了任务');
        _task = _task!.copyWith(steps: steps);
        rethrow;
      } catch (e) {
        steps[i] = steps[i].copyWith(status: 'failed', result: '执行出错：$e');
        doneResults.add('第 ${i + 1} 步：${steps[i].text}\n结果：执行出错（$e）');
      }
      _task = _task!.copyWith(steps: steps);
      await _persist();
      notifyListeners();
    }

    if (_cancelled) {
      await _finish('cancelled', '任务已取消');
      return;
    }
    await _summarize(doneResults);
  }

  /// 最终汇报：一段总结。
  Future<void> _summarize(List<String> doneResults) async {
    _checkCancelled();
    final status =
        _task!.steps.any((s) => s.status == 'failed') ? 'failed' : 'done';
    _activity = '生成任务总结…';
    notifyListeners();
    try {
      final messages = <Map<String, String>>[
        {
          'role': 'user',
          'content': '任务目标：${_task!.goal}\n'
              '执行记录：\n${doneResults.join('\n\n')}\n\n'
              '请用不超过 200 字总结任务成果（做了哪些事、结果如何；'
              '有步骤失败或操作被拒绝时如实说明）。',
        },
      ];
      final resp = await _ai.chatOnce(
        provider: _provider!,
        apiKey: _apiKey!,
        messages: messages,
        systemPrompt: _mergedSystemPrompt(),
        cancelToken: _cancelToken,
      );
      _checkCancelled();
      await _finish(status, resp.content);
    } on AiRequestCancelled {
      rethrow;
    } catch (e) {
      _checkCancelled();
      await _finish(status, '${doneResults.join('\n\n')}\n\n总结生成失败：$e');
    }
  }

  /// 工具调用执行 + 两级放行闸门。
  Future<String> _executeCall(AiToolCall call, String stepText) async {
    _checkCancelled();
    // MCP 工具：直接转发给对应服务器（视为只读，不弹审批）。
    if (call.name.startsWith('mcp_')) {
      Map<String, dynamic> args = {};
      try {
        final decoded = jsonDecode(call.arguments);
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}
      return McpRegistry.instance.executeByName(call.name, args);
    }
    final tool = AiTools.byName(call.name);
    if (tool == null) return '未知工具：${call.name}';
    if (tool.danger != AiToolDanger.read) {
      final ok = await _requestApproval(
        AgentApproval(
          toolName: tool.name,
          toolLabel: tool.label,
          argsSummary: _cap(call.arguments, 200),
          stepText: stepText,
        ),
      );
      _checkCancelled();
      if (!ok) {
        return '用户拒绝了「${tool.label}」操作';
      }
    }
    final ctx = _toolContext!;
    return AiTools.executeCall(call, ctx);
  }

  Future<bool> _requestApproval(AgentApproval approval) async {
    _checkCancelled();
    // 前台：任务页挂的回调直接弹框。
    final handler = approvalHandler;
    if (handler != null) {
      try {
        // 取消时解除等待；弹窗稍后的返回值不再触发工具调用。
        return await Future.any([
          handler(approval),
          _cancelToken!.whenCancel.then((_) => false),
        ]);
      } catch (_) {
        return false;
      }
    }
    // 后台：自动放行开关 → 放行；否则暂停等用户回来确认。
    final autoApprove = await AiToolsStore.instance.autoApproveWrite();
    _checkCancelled();
    if (autoApprove) return true;
    final c = _approvalCompleter = Completer<bool>();
    _pendingApproval = approval;
    _activity = '等待确认：${approval.toolLabel}';
    await _setStatus('waiting_approval');
    notifyListeners();
    AgentTaskNotifier.updateProgress(
        _task!.goal, '任务需要确认「${approval.toolLabel}」', -1, 0);
    final ok = await c.future;
    _pendingApproval = null;
    _approvalCompleter = null;
    if (!_cancelled) await _setStatus('running');
    return ok;
  }

  /// UI 确认计划。
  void confirmPlan() {
    final c = _confirmCompleter;
    if (c != null && !c.isCompleted) c.complete(true);
  }

  /// UI 取消计划（任务结束）。
  void rejectPlan() {
    final c = _confirmCompleter;
    if (c != null && !c.isCompleted) c.complete(false);
  }

  /// UI 回答写操作确认。
  void resolveApproval(bool approved, {required AgentApproval approval}) {
    // 旧弹窗可能在取消后、另一任务等待审批时才返回。
    if (!identical(approval, _pendingApproval)) return;
    final c = _approvalCompleter;
    if (c != null && !c.isCompleted) c.complete(approved);
  }

  /// 取消当前任务（任何阶段）。
  void cancel() {
    if (!running) return;
    _cancelled = true;
    _cancelToken?.cancel('用户取消任务');
    final c1 = _confirmCompleter;
    if (c1 != null && !c1.isCompleted) c1.complete(false);
    final c2 = _approvalCompleter;
    if (c2 != null && !c2.isCompleted) c2.complete(false);
    _activity = '取消中…';
    notifyListeners();
  }

  Future<void> _setStatus(String status) async {
    _task = _task!.copyWith(status: status);
    await _persist();
    notifyListeners();
  }

  Future<void> _finish(String status, String result) async {
    _activity = '';
    _pendingApproval = null;
    _task = _task!.copyWith(
      status: status,
      result: result,
      steps: status == 'cancelled'
          ? [
              for (final s in _task!.steps)
                if (s.status == 'pending' || s.status == 'running')
                  s.copyWith(status: 'skipped', result: '任务取消，未继续执行')
                else
                  s
            ]
          : null,
    );
    await _persist();
    notifyListeners();
    AgentTaskNotifier.stop();
  }

  Future<void> _persist() async {
    final t = _task;
    final s = _storage;
    if (t == null || s == null || t.id == null) return;
    await s.updateAiTask(t);
  }

  void _checkCancelled() {
    if (_cancelled) throw const AiRequestCancelled();
  }

  /// App 重启后把上次遗留的「进行中」任务标记为中断（进程死了任务不会复活）。
  static Future<void> markStaleTasks(StorageService storage) async {
    try {
      final active = await storage.listAiTasks(onlyActive: true);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final t in active) {
        await storage.updateAiTask(t.copyWith(
          status: 'failed',
          result: 'App 已重启，任务中断',
          updatedAt: now,
        ));
      }
    } catch (e) {
      debugPrint('[Agent] mark stale tasks failed: $e');
    }
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// 从模型输出里提取步骤 JSON 数组（容忍 ```json 围栏/前后杂文）。
  /// 失败时按非空行兜底。
  static List<String> parsePlan(String content) {
    final text = content.trim();
    // 剥围栏。
    var body = text;
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final m = fence.firstMatch(text);
    if (m != null) body = m.group(1)!;

    // 找第一个 JSON 数组。
    final start = body.indexOf('[');
    if (start >= 0) {
      for (var end = body.length - 1; end > start; end--) {
        if (body[end] != ']') continue;
        final candidate = body.substring(start, end + 1);
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is List) {
            final steps = <String>[
              for (final e in decoded)
                if (e is String && e.trim().isNotEmpty) e.trim(),
            ];
            if (steps.isNotEmpty) return steps;
          }
        } catch (_) {
          // 继续找更短的候选。
        }
      }
    }
    // 兜底：按行切。
    return [
      for (final line in body.split('\n'))
        if (line.trim().isNotEmpty &&
            !line.trim().startsWith('[') &&
            !line.trim().startsWith(']'))
          line.trim(),
    ];
  }
}
