import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外观设置（主题模式 + 主色调），SharedPreferences 持久化。
///
/// 历史原因：参考稿要求整体锁定浅色（app.dart 硬编码 ThemeMode.light）。
/// 现在把选择权交回用户（更多设置 → 外观总设置），默认仍是浅色。
class AppearanceSettings {
  /// 'light' | 'dark' | 'system'
  final String mode;

  /// 主色调种子（ARGB int）。默认沿用 Libranote 深青绿。
  final int seedColor;

  /// 自定义 App 背景图路径（null = 使用主题默认背景）。
  /// 图片由外观设置页选择并复制到 Documents/appearance/ 下。
  final String? backgroundImagePath;

  const AppearanceSettings({
    this.mode = 'light',
    this.seedColor = 0xFF1B5E5E,
    this.backgroundImagePath,
  });

  ThemeMode get themeMode => switch (mode) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };

  AppearanceSettings copyWith({
    String? mode,
    int? seedColor,
    String? backgroundImagePath,
    bool clearBackground = false,
  }) =>
      AppearanceSettings(
        mode: mode ?? this.mode,
        seedColor: seedColor ?? this.seedColor,
        backgroundImagePath: clearBackground
            ? null
            : (backgroundImagePath ?? this.backgroundImagePath),
      );
}

class AppearanceStore {
  AppearanceStore._();
  static final AppearanceStore instance = AppearanceStore._();

  static const _kMode = 'appearance.mode';
  static const _kSeed = 'appearance.seed';
  static const _kBackground = 'appearance.background_image';

  Future<AppearanceSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppearanceSettings(
      mode: prefs.getString(_kMode) ?? 'light',
      seedColor: prefs.getInt(_kSeed) ?? 0xFF1B5E5E,
      backgroundImagePath: prefs.getString(_kBackground),
    );
  }

  Future<void> save(AppearanceSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, s.mode);
    await prefs.setInt(_kSeed, s.seedColor);
    if (s.backgroundImagePath == null || s.backgroundImagePath!.isEmpty) {
      await prefs.remove(_kBackground);
    } else {
      await prefs.setString(_kBackground, s.backgroundImagePath!);
    }
  }
}

class AppearanceNotifier extends StateNotifier<AppearanceSettings> {
  AppearanceNotifier() : super(const AppearanceSettings()) {
    // fire-and-forget：首帧用默认（浅色），SharedPreferences 就绪后刷新。
    AppearanceStore.instance.load().then((v) => state = v);
  }

  Future<void> setMode(String mode) async {
    state = state.copyWith(mode: mode);
    await AppearanceStore.instance.save(state);
  }

  Future<void> setSeedColor(int color) async {
    state = state.copyWith(seedColor: color);
    await AppearanceStore.instance.save(state);
  }

  Future<void> setBackgroundImage(String? path) async {
    state = path == null
        ? state.copyWith(clearBackground: true)
        : state.copyWith(backgroundImagePath: path);
    await AppearanceStore.instance.save(state);
  }
}

final appearanceProvider =
    StateNotifierProvider<AppearanceNotifier, AppearanceSettings>(
        (ref) => AppearanceNotifier());

/// 用户头像版本号：换头像后自增，全局 AppAvatar 监听它重建。
final avatarVersionProvider = StateProvider<int>((ref) => 0);
