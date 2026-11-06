import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/usage_provider.dart';
import '../services/countdown_service.dart';

/// 主页「今日学习」卡片（替代原 GitHub 热力格，用户要求改为简洁的
/// 「今日学习：X小时X分钟」）+ 内置倒计时：
/// · 今日学习时长来自本地 usage_days（UsageTracker 每 30 秒刷新）；
/// · 倒计时预设 25/45/60 分钟 + 自定义，开始/暂停/重置；
/// · 到点弹提醒（对话框 + 系统提示音；App 关闭期间到点，重进补弹）。
class TodayStudyCard extends ConsumerStatefulWidget {
  const TodayStudyCard({super.key});

  @override
  ConsumerState<TodayStudyCard> createState() => _TodayStudyCardState();
}

class _TodayStudyCardState extends ConsumerState<TodayStudyCard> {
  /// 倒计时到点提醒（用根 navigator 弹，主页不在导航根上也能弹）。
  void _listenFinish() {
    final notifier = ref.read(countdownProvider.notifier);
    notifier.onFinished = () {
      if (!mounted) return;
      _showFinishedDialog();
    };
  }

  @override
  void initState() {
    super.initState();
    _listenFinish();
    // 恢复后若上次倒计时已在关闭期间结束，补弹提醒。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(countdownProvider.notifier);
      if (notifier.shouldNotify) _showFinishedDialog();
    });
  }

  Future<void> _showFinishedDialog() async {
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.notifications_active_outlined, color: Color(0xFFF59E0B)),
            SizedBox(width: 8),
            Text('倒计时结束'),
          ],
        ),
        content: const Text('设定的学习倒计时到啦！休息一下，或者开始下一段学习。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(countdownProvider.notifier).acknowledgeFinished();
            },
            child: const Text('知道了'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(countdownProvider.notifier).acknowledgeFinished();
              // 再来一段：直接按上次预设开始。
              ref.read(countdownProvider.notifier).start();
              messenger.showSnackBar(
                const SnackBar(
                    content: Text('已开始新一轮倒计时'), duration: Duration(seconds: 2)),
              );
            },
            child: const Text('再来一段'),
          ),
        ],
      ),
    );
  }

  /// 自定义倒计时时长输入（分钟）。
  Future<void> _showCustomDuration() async {
    final ctrl = TextEditingController(
        text: '${ref.read(countdownProvider.notifier).presetMinutes}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义倒计时'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '时长（分钟）',
            hintText: '例如 45',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final minutes = int.tryParse(ctrl.text.trim());
    if (minutes == null || minutes <= 0 || minutes > 600) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入 1–600 之间的分钟数')),
      );
      return;
    }
    final notifier = ref.read(countdownProvider.notifier);
    notifier.setPresetMinutes(minutes);
    notifier.start(Duration(minutes: minutes));
  }

  String _fmtDuration(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h小时${m.toString().padLeft(2, '0')}分钟';
    }
    if (m > 0) {
      return '$m分钟${s.toString().padLeft(2, '0')}秒';
    }
    return '$s 秒';
  }

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(usageProvider);
    final cd = ref.watch(countdownProvider);
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_fire_department_outlined,
                  size: 18, color: colors.primary),
              const SizedBox(width: 6),
              const Text('今日学习',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _fmtDuration(usage.todaySeconds),
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            usage.totalLoginDays > 0
                ? '累计学习 ${usage.totalLoginDays} 天'
                : '今天也要好好学习',
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          const Divider(height: 18),
          // ── 倒计时 ──────────────────────────────────────────
          Row(
            children: [
              const Icon(Icons.timer_outlined,
                  size: 16, color: Color(0xFF64748B)),
              const SizedBox(width: 4),
              const Text('倒计时',
                  style:
                      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (!cd.running && !cd.finished)
                TextButton(
                  style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: _showCustomDuration,
                  child: const Text('自定义', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 剩余时间（大号显示）。
          Center(
            child: Text(
              cd.finished ? '00:00' : _clockText(cd.remainMs ~/ 1000),
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 1.2,
                color: cd.running ? colors.onSurface : const Color(0xFF94A3B8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (cd.running || cd.finished) ...[
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10)),
                  icon: Icon(cd.running ? Icons.pause : Icons.play_arrow,
                      size: 16),
                  label: Text(cd.running ? '暂停' : '继续',
                      style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    final n = ref.read(countdownProvider.notifier);
                    cd.running ? n.pause() : n.resume();
                  },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10)),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重置', style: TextStyle(fontSize: 12)),
                  onPressed: () => ref.read(countdownProvider.notifier).reset(),
                ),
              ],
            ),
          ] else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                for (final m in const [25, 45, 60])
                  ChoiceChip(
                    label:
                        Text('$m 分钟', style: const TextStyle(fontSize: 11.5)),
                    visualDensity: VisualDensity.compact,
                    selected:
                        ref.read(countdownProvider.notifier).presetMinutes == m,
                    onSelected: (_) {
                      final n = ref.read(countdownProvider.notifier);
                      n.setPresetMinutes(m);
                      n.start();
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _clockText(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
