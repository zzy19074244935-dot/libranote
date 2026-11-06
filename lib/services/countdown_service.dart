import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 倒计时（番茄钟式学习倒计时），主页「今日学习」卡片使用。
///
/// 状态机：idle → running → finished（到点弹提醒）。剩余时间持久化到
/// SharedPreferences（记录 deadline 时间戳），App 被杀/重启后：
/// · deadline 未到 → 恢复继续倒计时；
/// · deadline 已过 → 进入 finished，主页重新进入时补弹提醒。
class CountdownNotifier extends StateNotifier<CountdownState> {
  CountdownNotifier() : super(const CountdownState()) {
    _restore();
  }

  static const _kDeadline = 'countdown.deadline_ms';
  static const _kRunning = 'countdown.running';
  static const _kPresetMin = 'countdown.preset_minutes';

  Timer? _ticker;
  bool _finishedNotified = false; // finished 只弹一次提醒

  /// 预设时长（分钟），设置面板里改。
  int presetMinutes = 25;

  /// 倒计时结束回调（主页弹提醒对话框 + 提示音）。
  void Function()? onFinished;

  // ── 持久化恢复 ────────────────────────────────────────────────────

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      presetMinutes = prefs.getInt(_kPresetMin) ?? 25;
      final deadline = prefs.getInt(_kDeadline);
      final running = prefs.getBool(_kRunning) ?? false;
      if (deadline == null || !running) return;
      final remainMs = deadline - DateTime.now().millisecondsSinceEpoch;
      if (remainMs <= 0) {
        // App 关闭期间倒计时已结束：补一次提醒。
        state = const CountdownState(finished: true);
        _finishedNotified = true;
        Future<void>.microtask(() => onFinished?.call());
      } else {
        state = state.copyWith(running: true, remainMs: remainMs);
        _startTicker();
      }
    } catch (e) {
      debugPrint('[Countdown] restore failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPresetMin, presetMinutes);
      if (state.running && state.deadlineMs != null) {
        await prefs.setInt(_kDeadline, state.deadlineMs!);
        await prefs.setBool(_kRunning, true);
      } else {
        await prefs.remove(_kDeadline);
        await prefs.setBool(_kRunning, false);
      }
    } catch (e) {
      debugPrint('[Countdown] persist failed: $e');
    }
  }

  // ── 操作 ──────────────────────────────────────────────────────────

  /// 开始/重新开始倒计时。
  void start([Duration? duration]) {
    final d = duration ?? Duration(minutes: presetMinutes);
    if (d.inSeconds <= 0) return;
    final deadline = DateTime.now().add(d).millisecondsSinceEpoch;
    _ticker?.cancel();
    _finishedNotified = false;
    state = CountdownState(running: true, remainMs: d.inMilliseconds, deadlineMs: deadline);
    _persist();
    _startTicker();
  }

  void pause() {
    if (!state.running) return;
    _ticker?.cancel();
    state = state.copyWith(running: false);
    _persist();
  }

  void resume() {
    if (state.running || state.remainMs <= 0) return;
    final deadline =
        DateTime.now().add(Duration(milliseconds: state.remainMs)).millisecondsSinceEpoch;
    state = state.copyWith(running: true, deadlineMs: deadline);
    _persist();
    _startTicker();
  }

  /// 停止并清零。
  void reset() {
    _ticker?.cancel();
    _finishedNotified = false;
    state = const CountdownState();
    _persist();
  }

  /// 修改预设时长（分钟），持久化。
  void setPresetMinutes(int minutes) {
    presetMinutes = minutes.clamp(1, 600);
    _persist();
  }

  /// 提醒已确认（关掉对话框后调用，避免反复弹）。
  void acknowledgeFinished() {
    _finishedNotified = true;
    state = const CountdownState();
    _persist();
  }

  bool get shouldNotify => state.finished && !_finishedNotified;

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!state.running) return;
      final remainMs =
          (state.deadlineMs ?? 0) - DateTime.now().millisecondsSinceEpoch;
      if (remainMs <= 0) {
        _ticker?.cancel();
        state = const CountdownState(finished: true);
        _persist();
        if (!_finishedNotified) {
          _finishedNotified = true;
          onFinished?.call();
        }
      } else {
        state = state.copyWith(remainMs: remainMs);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

class CountdownState {
  final bool running;
  final bool finished;

  /// 剩余毫秒（running/paused 时有效）。
  final int remainMs;

  /// 结束时间戳（running 时有效，用于持久化）。
  final int? deadlineMs;

  const CountdownState({
    this.running = false,
    this.finished = false,
    this.remainMs = 0,
    this.deadlineMs,
  });

  CountdownState copyWith({
    bool? running,
    bool? finished,
    int? remainMs,
    int? deadlineMs,
  }) =>
      CountdownState(
        running: running ?? this.running,
        finished: finished ?? this.finished,
        remainMs: remainMs ?? this.remainMs,
        deadlineMs: deadlineMs ?? this.deadlineMs,
      );
}

final countdownProvider =
    StateNotifierProvider<CountdownNotifier, CountdownState>(
        (ref) => CountdownNotifier());
