import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/usage_day.dart';
import '../providers/usage_provider.dart';
import '../services/storage_service.dart';

/// GitHub 风格热力格卡片。
///
/// 规则（用户需求）：
/// - 当天登录过 → 至少一档绿（`UsageDay.level` 里 logins>0 保底 1 档）；
/// - 颜色越深 = 当天累计使用时间越长（30 分钟 / 1 小时 / 2 小时三档加深）。
/// 展示范围 = **用户下载 App 开始使用的那天 → 今天**（不再是固定近 70 天：
/// 窄卡片里横向滚动只能看到开头的老日子，今天这一格在视野外，看起来
/// 「不变绿」）。点格子看当天明细。
class UsageHeatmapCard extends ConsumerStatefulWidget {
  const UsageHeatmapCard({super.key});

  @override
  ConsumerState<UsageHeatmapCard> createState() => _UsageHeatmapCardState();
}

class _UsageHeatmapCardState extends ConsumerState<UsageHeatmapCard> {
  /// GitHub 明暗两套配色（浅色模式锁定，暗色预留）。
  static const List<Color> _light = [
    Color(0xFFEBEDF0),
    Color(0xFF9BE9A8),
    Color(0xFF40C463),
    Color(0xFF30A14E),
    Color(0xFF216E39),
  ];
  static const List<Color> _dark = [
    Color(0xFF2A3038),
    Color(0xFF0E4429),
    Color(0xFF006D32),
    Color(0xFF26A641),
    Color(0xFF39D353),
  ];

  static const double _cell = 12;
  static const double _gap = 3;

  /// 热力格横向滚动控制器：初始滚到最右（今天）。
  final ScrollController _gridCtrl = ScrollController();
  bool _scrolledToEnd = false;
  int _lastColumns = -1;

  @override
  void dispose() {
    _gridCtrl.dispose();
    super.dispose();
  }

  /// 首次布局后滚到最右，让「今天」永远在视野里；列数变化（跨周）后重滚。
  void _scrollToEnd(int columns) {
    if (columns != _lastColumns) {
      _lastColumns = columns;
      _scrolledToEnd = false;
    }
    if (_scrolledToEnd || !_gridCtrl.hasClients) return;
    _gridCtrl.jumpTo(_gridCtrl.position.maxScrollExtent);
    _scrolledToEnd = true;
  }

  static String _fmtSeconds(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return m > 0 ? '$h 小时 $m 分' : '$h 小时';
    if (m > 0) return '$m 分钟';
    return '$seconds 秒';
  }

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(usageProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final palette = dark ? _dark : _light;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 起始 = 下载 App 开始使用的那天（无记录则今天），对齐到周日
    //（GitHub 一周从周日开始）。
    final first = usage.startDate ?? today;
    final start = DateTime(first.year, first.month, first.day);
    final startWeek =
        start.subtract(Duration(days: start.weekday % 7)); // 周日 0
    final columns = (today.difference(startWeek).inDays ~/ 7) + 1;

    // 布局完成后滚到最右（今天）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(columns));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? const Color(0xFF30363D) : const Color(0xFFF1F5F9),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 标题行：活跃日历 + 今日/累计 ──────────────────────────
          Row(
            children: [
              const Expanded(
                child: Text(
                  '活跃日历',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              // 窄屏（主页里与「最近阅读」并排时）防溢出。
              Flexible(
                child: Text(
                  '今日 ${_fmtSeconds(usage.todaySeconds)}'
                  '${usage.todayLogins > 0 ? ' · 已登录' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: dark ? const Color(0xFF8B949E) : const Color(0xFF94A3B8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${start.year}年${start.month}月${start.day}日 以来共使用 '
            '${_fmtSeconds(usage.totalSeconds)}'
            ' · 登录 ${usage.totalLoginDays} 天，绿色越深当天用越久',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: dark ? const Color(0xFF8B949E) : const Color(0xFF94A3B8),
            ),
          ),
          const SizedBox(height: 10),

          // ── 热力格主体（横滑） ─────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧星期标签（GitHub 只标 一/三/五）。
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  children: [
                    for (var row = 0; row < 7; row++)
                      SizedBox(
                        height: _cell,
                        child: row == 1 || row == 3 || row == 5
                            ? Text(
                                const ['日', '一', '二', '三', '四', '五', '六'][row],
                                style: TextStyle(
                                  fontSize: 9,
                                  height: 1.3,
                                  color: dark
                                      ? const Color(0xFF8B949E)
                                      : const Color(0xFF94A3B8),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _gridCtrl,
                  scrollDirection: Axis.horizontal,
                  reverse: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 月份标签行（周首日进入新月才标）。
                      SizedBox(
                        height: 14,
                        width: columns * (_cell + _gap),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: _monthLabels(startWeek, columns, dark),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var col = 0; col < columns; col++)
                            Padding(
                              padding: EdgeInsets.only(
                                  right: col == columns - 1 ? 0 : _gap),
                              child: Column(
                                children: [
                                  for (var row = 0; row < 7; row++)
                                    _buildCell(
                                      context,
                                      ref,
                                      palette,
                                      startWeek
                                          .add(Duration(days: col * 7 + row)),
                                      today,
                                      row == 6,
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── 图例：少 → 多 ─────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                '少',
                style: TextStyle(
                  fontSize: 10,
                  color: dark ? const Color(0xFF8B949E) : const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(width: 4),
              for (final c in palette)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Text(
                '多',
                style: TextStyle(
                  fontSize: 10,
                  color: dark ? const Color(0xFF8B949E) : const Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 每列顶部月标签：该周首日是新月份且后面还有空间才画。
  List<Widget> _monthLabels(DateTime startWeek, int columns, bool dark) {
    final labels = <Widget>[];
    int? lastMonth;
    for (var col = 0; col < columns; col++) {
      final first = startWeek.add(Duration(days: col * 7));
      if (first.month != lastMonth) {
        lastMonth = first.month;
        labels.add(Positioned(
          left: col * (_cell + _gap),
          child: Text(
            '${first.month}月',
            style: TextStyle(
              fontSize: 9,
              color: dark ? const Color(0xFF8B949E) : const Color(0xFF94A3B8),
            ),
          ),
        ));
      }
    }
    return labels;
  }

  Widget _buildCell(
    BuildContext context,
    WidgetRef ref,
    List<Color> palette,
    DateTime day,
    DateTime today,
    bool bottom,
  ) {
    final future = day.isAfter(today);
    final key = StorageService.usageDateKey(day);
    final usage = ref.read(usageProvider).days[key];
    final level = usage?.level ?? 0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom ? 0 : _gap),
      child: InkWell(
        onTap: future || level == 0
            ? null
            : () => _showDayDetail(context, day, usage!),
        borderRadius: BorderRadius.circular(2),
        child: Container(
          width: _cell,
          height: _cell,
          decoration: BoxDecoration(
            color: future ? Colors.transparent : palette[level.clamp(0, 4)],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  void _showDayDetail(BuildContext context, DateTime day, UsageDay usage) {
    final dateLabel = '${day.year}年${day.month}月${day.day}日';
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dateLabel,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 18),
                const SizedBox(width: 8),
                Text('使用时长：${usage.durationLabel}'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.login, size: 18),
                const SizedBox(width: 8),
                Text('登录 ${usage.logins} 次'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
