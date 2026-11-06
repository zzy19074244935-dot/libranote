import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';
import '../services/agent_task_engine.dart';

/// Agent 任务页（Phase 1 任务式 Agent）：
/// 输入目标 → 计划确认 → 逐步执行（进度/取消/写操作确认）→ 结果与历史。
/// 任务在引擎单例里跑：离开本页、退回桌面任务继续（Android 前台服务保活）。
class AgentTaskScreen extends ConsumerStatefulWidget {
  const AgentTaskScreen({super.key});

  @override
  ConsumerState<AgentTaskScreen> createState() => _AgentTaskScreenState();
}

class _AgentTaskScreenState extends ConsumerState<AgentTaskScreen> {
  static const _statusLabels = <String, String>{
    'planning': '规划中',
    'awaiting_confirm': '等待确认计划',
    'waiting_approval': '等待确认写操作',
    'running': '执行中',
    'done': '已完成',
    'failed': '失败',
    'cancelled': '已取消',
  };

  final _goalCtrl = TextEditingController();
  final AgentTaskEngine _engine = AgentTaskEngine.instance;
  bool _starting = false;
  bool _approvalShowing = false;
  List<AiTask> _history = const [];

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _engine.approvalHandler = _approvalDialog;
    _init();
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngineChanged);
    if (_engine.approvalHandler == _approvalDialog) {
      _engine.approvalHandler = null;
    }
    _goalCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _reloadHistory();
    final pending = _engine.pendingApproval;
    if (!mounted) return;
    setState(() {});
    // 后台挂起的写操作确认：一进页面立刻补弹。
    if (pending != null && !_approvalShowing) {
      _approvalShowing = true;
      unawaited(_approvalDialog(pending).then((ok) {
        _approvalShowing = false;
        _engine.resolveApproval(ok, approval: pending);
      }));
    }
  }

  Future<void> _reloadHistory() async {
    final list = await ref.read(storageServiceProvider).listAiTasks();
    if (!mounted) return;
    setState(() => _history = list);
  }

  void _onEngineChanged() {
    if (!mounted) return;
    setState(() {});
    // 后台挂起的写操作确认：页面可见时立刻弹框。
    final p = _engine.pendingApproval;
    if (p != null && !_approvalShowing) {
      _approvalShowing = true;
      unawaited(_approvalDialog(p).then((ok) {
        _approvalShowing = false;
        _engine.resolveApproval(ok, approval: p);
      }));
    }
    final t = _engine.task;
    if (t != null && t.isFinished) {
      unawaited(_reloadHistory());
    }
  }

  /// 写操作确认弹框（引擎前台直调 / 后台挂起后由监听器补弹）。
  Future<bool> _approvalDialog(AgentApproval a) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Agent 想执行写操作'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工具：${a.toolLabel}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('步骤：${a.stepText}'),
            const SizedBox(height: 6),
            Text('参数：${a.argsSummary}',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            // 同「开始执行」：全局主题 minSize=(∞,52) 在 Row 里会撑爆，
            // 显式覆盖成有限宽度。
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _start() async {
    final goal = _goalCtrl.text.trim();
    if (goal.isEmpty || _starting || _engine.running) return;
    setState(() => _starting = true);
    try {
      await _engine.startTask(
        goal: goal,
        storage: ref.read(storageServiceProvider),
      );
      _goalCtrl.clear();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  Future<void> _deleteHistory(AiTask t) async {
    if (!t.isFinished) return;
    await ref.read(storageServiceProvider).deleteAiTask(t.id!);
    await _reloadHistory();
  }

  // ── UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final task = _engine.task;
    final running = task != null && task.isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Agent 任务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (running) ..._buildRunningSection(task, colors),
          if (!running) ..._buildStartSection(colors),
          const SizedBox(height: 20),
          Text('任务历史',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: colors.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('还没有任务。试试：\n「把《三体》前 3 章各写一段 50 字摘要」',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant)),
              ),
            )
          else
            for (final t in _history) _historyCard(t, colors),
        ],
      ),
    );
  }

  List<Widget> _buildStartSection(ColorScheme colors) {
    return [
      const Text('把多步骤任务交给 AI 自己干',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      const SizedBox(height: 6),
      Text(
        'Agent 会先列计划（你确认后执行）、逐步调用工具、最后汇报。\n'
        '读操作自动执行；改数据前会请你确认。任务可在后台继续跑。',
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _goalCtrl,
        minLines: 2,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: '例如：把《三体》前 3 章各写一段 50 字摘要，'
              '并整理成一份笔记',
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        icon: _starting
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.rocket_launch_outlined),
        label: Text(_starting ? '正在提交…' : '开始任务'),
        onPressed: _starting ? null : _start,
      ),
    ];
  }

  List<Widget> _buildRunningSection(AiTask task, ColorScheme colors) {
    final statusLabel = _statusLabels[task.status] ?? task.status;
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  task.status == 'awaiting_confirm'
                      ? Icons.rule
                      : task.status == 'waiting_approval'
                          ? Icons.gpp_maybe_outlined
                          : Icons.autorenew,
                  size: 16,
                  color: colors.onPrimaryContainer,
                ),
                const SizedBox(width: 6),
                Text(statusLabel,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: colors.onPrimaryContainer)),
              ],
            ),
            const SizedBox(height: 8),
            Text(task.goal,
                style: TextStyle(color: colors.onPrimaryContainer)),
            if (_engine.activity.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_engine.activity,
                  style: TextStyle(
                      fontSize: 12, color: colors.onPrimaryContainer)),
            ],
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (task.status == 'awaiting_confirm') ...[
        const Text('计划（确认后开始执行）',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (var i = 0; i < task.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}. ',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: colors.primary)),
                Expanded(child: Text(task.steps[i].text)),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              // ⚠️ 全局主题 FilledButton minimumSize=(∞,52)：在 Row 里
              // 不覆盖会宽度撑爆溢出 → 按钮空白且点击无响应（用户反馈
              // 「确认计划按钮点不了」的根因）。必须显式改成有限宽度。
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _engine.confirmPlan,
              child: const Text('开始执行'),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _engine.rejectPlan,
              child: const Text('取消'),
            ),
          ],
        ),
      ] else if (task.steps.isNotEmpty) ...[
        for (var i = 0; i < task.steps.length; i++)
          _stepTile(i, task.steps[i], colors),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.stop_circle_outlined),
        label: const Text('取消任务'),
        onPressed: _engine.cancel,
      ),
    ];
  }

  Widget _stepTile(int index, AiTaskStep step, ColorScheme colors) {
    final IconData icon;
    final Color color;
    switch (step.status) {
      case 'done':
        icon = Icons.check_circle;
        color = const Color(0xFF16A34A);
      case 'running':
        icon = Icons.hourglass_top;
        color = colors.primary;
      case 'failed':
        icon = Icons.error_outline;
        color = colors.error;
      default:
        icon = Icons.radio_button_unchecked;
        color = colors.outline;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${index + 1}. ${step.text}'),
                if (step.toolName.isNotEmpty)
                  Text('调用：${step.toolName}',
                      style: TextStyle(
                          fontSize: 11, color: colors.onSurfaceVariant)),
                if (step.result.isNotEmpty)
                  Text(step.result,
                      style: TextStyle(
                          fontSize: 12, color: colors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyCard(AiTask t, ColorScheme colors) {
    final label = _statusLabels[t.status] ?? t.status;
    final created = t.createdAt > 0
        ? DateFormat('MM-dd HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(t.createdAt))
        : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _showHistoryDetail(t),
        title: Text(t.goal,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$label · $created'
          '${t.result.isNotEmpty ? '\n${t.result}' : ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: t.isFinished ? () => _deleteHistory(t) : null,
        ),
      ),
    );
  }

  Future<void> _showHistoryDetail(AiTask t) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.goal, style: const TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('状态：${_statusLabels[t.status] ?? t.status}'),
              if (t.result.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('结果：\n${t.result}'),
              ],
              if (t.steps.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('步骤：',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                for (final s in t.steps)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        '${s.status == 'done' ? '✓' : '·'} ${s.text}'),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
