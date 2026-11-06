import 'dart:async';

import 'package:flutter/widgets.dart';

import 'storage_service.dart';

/// 前台使用时长追踪器：每 30 秒把「真的在前台」的时长刷进 `usage_days`。
///
/// 精度取舍：
/// - 用墙钟差而非计时器 tick 数累计，后台休眠/CPU 冻结时计时器不走，
///   恢复后也不会把睡眠时间算进去（单次间隔 clamp 到 5 分钟兜底）。
/// - App 切后台（[AppLifecycleState.paused]）立即 flush 剩余量并挂起，
///   回到前台继续；统计只覆盖用户实际盯着屏幕的时间。
/// - 登录当天变绿由 [markLoginToday] 负责，与使用时长无关。
class UsageTracker with WidgetsBindingObserver {
  final StorageService _storage;

  Timer? _timer;
  DateTime? _lastTick;
  bool _appActive = true;
  bool _flushing = false;

  /// 每次成功刷库后回调（热力格 provider 用它刷新界面）。
  void Function()? onFlushed;

  UsageTracker(this._storage);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _lastTick = DateTime.now();
    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => _tick(),
    );
    // 打开 App 即记 1 秒：今天这一格立即变绿（否则要等第一个 30s 刷点，
    // 用户打开主页看到今天还是灰色，误以为热力格坏了）。
    _flush(1);
    debugPrint('[Usage] tracker started');
  }

  /// 记录一次登录：当天热力格至少一档绿（供 auth 状态跳转时调用）。
  Future<void> markLoginToday() async {
    try {
      await _storage.markLogin(DateTime.now());
      onFlushed?.call();
    } catch (e, st) {
      debugPrint('[Usage] markLogin failed: $e\n$st');
    }
  }

  void _tick() {
    final now = DateTime.now();
    final last = _lastTick ?? now;
    _lastTick = now;
    if (!_appActive) return; // 后台不累计，也不推进 lastTick 之外的状态
    var elapsed = now.difference(last).inSeconds;
    if (elapsed < 0) elapsed = 0;
    // 单次最长 5 分钟：设备睡眠/断电恢复的墙钟跳跃不计入使用时长。
    if (elapsed > 5 * 60) elapsed = 5 * 60;
    if (elapsed <= 0) return;
    _flush(elapsed);
  }

  Future<void> _flush(int seconds) async {
    if (_flushing) return; // 上一次还没写完就跳过本次，避免队列堆积
    _flushing = true;
    try {
      await _storage.addUsageSeconds(DateTime.now(), seconds);
      onFlushed?.call();
    } catch (e, st) {
      debugPrint('[Usage] flush failed: $e\n$st');
    } finally {
      _flushing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    if (active) {
      _lastTick = DateTime.now(); // 后台时段全部丢弃，从恢复时刻重新起算
      debugPrint('[Usage] resumed');
    } else {
      // 切后台前把挂着的几十秒补上，不丢尾数。
      final now = DateTime.now();
      final last = _lastTick ?? now;
      _lastTick = now;
      var elapsed = now.difference(last).inSeconds;
      if (elapsed > 0 && elapsed <= 5 * 60) _flush(elapsed);
      debugPrint('[Usage] paused');
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }
}
