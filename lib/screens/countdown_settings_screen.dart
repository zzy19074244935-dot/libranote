import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/countdown_service.dart';

/// 倒计时设置：预设时长、当前状态、操作（与主页「今日学习」卡片同一份状态）。
class CountdownSettingsScreen extends ConsumerWidget {
  const CountdownSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cd = ref.watch(countdownProvider);
    final notifier = ref.read(countdownProvider.notifier);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('倒计时设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('学习倒计时', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '设定一段时间专注学习，倒计时结束会弹出提醒（提示音 + 对话框）。'
            'App 关闭期间到点，重新打开时会补弹提醒。',
            style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('当前状态'),
                  trailing: Text(
                    cd.finished
                        ? '已到点'
                        : cd.running
                            ? '倒计时中（剩余 ${_fmt(cd.remainMs ~/ 1000)}）'
                            : '未开始',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cd.running ? colors.primary : null,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('预设时长（分钟）'),
                  subtitle: Text('当前：${notifier.presetMinutes} 分钟',
                      style: const TextStyle(fontSize: 12)),
                  trailing: TextButton(
                    onPressed: () => _editPresetMinutes(context, notifier),
                    child: const Text('修改'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in const [25, 45, 60, 90])
                ChoiceChip(
                  label: Text('$m 分钟'),
                  selected: notifier.presetMinutes == m,
                  onSelected: (_) => notifier.setPresetMinutes(m),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (cd.running)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.pause),
                    label: const Text('暂停'),
                    onPressed: notifier.pause,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('重置'),
                    onPressed: notifier.reset,
                  ),
                ),
              ],
            )
          else if (cd.finished)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('重新开始'),
                onPressed: () => notifier.start(),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: Text('开始倒计时（${notifier.presetMinutes} 分钟）'),
                onPressed: () => notifier.start(),
              ),
            ),
        ],
      ),
    );
  }

  /// 修改预设时长（分钟）。
  Future<void> _editPresetMinutes(
      BuildContext context, CountdownNotifier notifier) async {
    final ctrl = TextEditingController(text: '${notifier.presetMinutes}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('预设倒计时时长'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '分钟',
            hintText: '例如 45（1–600）',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (ok != true) return;
    final m = int.tryParse(ctrl.text.trim());
    if (m != null && m > 0 && m <= 600) {
      notifier.setPresetMinutes(m);
    }
  }

  static String _fmt(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return m > 0 ? '$m 分 $s 秒' : '$s 秒';
  }
}
