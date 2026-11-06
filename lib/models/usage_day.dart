/// 一天的 App 使用统计：累计使用秒数 + 当天登录次数。
///
/// [date] 是本地日期键 `yyyy-MM-dd`（不是时间戳），主键去重。
/// GitHub 热力格的颜色深浅只看 [seconds]，而「当天登录过就绿」用 [logins]
/// 兜底：登录但几乎没停留的用户当天也显示最低一档绿色。
class UsageDay {
  final String date;
  final int seconds;
  final int logins;

  const UsageDay({
    required this.date,
    required this.seconds,
    required this.logins,
  });

  /// 一天的时长显示：`2 小时 15 分` / `35 分钟` / `40 秒`。
  String get durationLabel {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return m > 0 ? '$h 小时 $m 分' : '$h 小时';
    }
    if (m > 0) {
      return s > 0 ? '$m 分 $s 秒' : '$m 分钟';
    }
    return '$s 秒';
  }

  /// GitHub 风格 5 档：0 无记录，1 登录/浅用，2~4 使用越久越深。
  ///
  /// 阈值参考 GitHub 贡献度直觉：<30 分钟=1 档，30~60=2 档，
  /// 60~120=3 档，>120 分钟=4 档（最深绿）。
  int get level {
    if (seconds <= 0 && logins <= 0) return 0;
    if (seconds < 30 * 60) return 1;
    if (seconds < 60 * 60) return 2;
    if (seconds < 120 * 60) return 3;
    return 4;
  }

  UsageDay copyWith({int? seconds, int? logins}) => UsageDay(
        date: date,
        seconds: seconds ?? this.seconds,
        logins: logins ?? this.logins,
      );
}
