import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/usage_day.dart';
import '../services/storage_service.dart';
import '../services/usage_tracker.dart';
import 'app_providers.dart';

/// 使用时长追踪器：main.dart 启动后首次读取即开始计时；
/// 每次刷库成功后刷新热力格 provider。
final usageTrackerProvider = Provider<UsageTracker>((ref) {
  final tracker = UsageTracker(ref.read(storageServiceProvider));
  tracker.onFlushed = () {
    // 追踪器每 30s 刷一次，热力格跟着刷新「今天」格子的颜色。
    ref.read(usageProvider.notifier).refresh();
  };
  ref.onDispose(tracker.dispose);
  tracker.start();
  return tracker;
});

/// 主页热力格数据：近一年多的每日使用时长 + 登录记录。
class UsageNotifier extends StateNotifier<UsageState> {
  final StorageService _storage;

  UsageNotifier(this._storage) : super(const UsageState()) {
    refresh();
  }

  Future<void> refresh() async {
    try {
      final now = DateTime.now();
      // 起始 = 用户最早的活动记录（≈ 下载 App 开始使用那天）；没有记录
      // 就从今天开始。热力格从这天画到今天——今天这一格永远在视野里
      //（旧实现固定画最近 70 天，横向滚动只能看到开头的老日子）。
      final first = await _storage.getFirstActivityDate() ?? now;
      final startDay = DateTime(first.year, first.month, first.day);
      final days = await _storage.getUsageDays(startDay, now);
      final map = {for (final d in days) d.date: d};
      final today = map[StorageService.usageDateKey(now)];
      state = UsageState(
        days: map,
        startDate: startDay,
        totalSeconds: map.values.fold(0, (sum, d) => sum + d.seconds),
        // 「登录 N 天」= 有登录记录的自然日数（不是登录事件总数）。
        totalLoginDays:
            map.values.where((d) => d.logins > 0).length,
        todaySeconds: today?.seconds ?? 0,
        todayLogins: today?.logins ?? 0,
      );
    } catch (e, st) {
      // 统计表坏了不能影响主页其它功能。
      debugPrint('[Usage] load failed: $e\n$st');
    }
  }
}

class UsageState {
  /// dateKey（yyyy-MM-dd）→ 当天统计。
  final Map<String, UsageDay> days;

  /// 热力格起始日期（第一条使用记录，无记录时为今天）。
  final DateTime? startDate;

  final int totalSeconds;
  final int totalLoginDays;
  final int todaySeconds;
  final int todayLogins;

  const UsageState({
    this.days = const {},
    this.startDate,
    this.totalSeconds = 0,
    this.totalLoginDays = 0,
    this.todaySeconds = 0,
    this.todayLogins = 0,
  });
}

final usageProvider = StateNotifierProvider<UsageNotifier, UsageState>((ref) {
  return UsageNotifier(ref.read(storageServiceProvider));
});
