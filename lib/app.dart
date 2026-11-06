import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/appearance.dart';
import 'config/theme.dart';
import 'screens/home_screen.dart';
import 'services/update_service.dart';

/// Local-first application root; no account is required to read or take notes.
class LibranoteApp extends ConsumerWidget {
  const LibranoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 外观设置（更多设置 → 外观总设置）：主题模式 + 主色调 + 自定义背景。
    // 默认浅色（历史行为），用户可在设置里改深色/跟随系统。
    final appearance = ref.watch(appearanceProvider);
    final seed = Color(appearance.seedColor);

    final bgPath = appearance.backgroundImagePath;
    final hasBackground =
        bgPath != null && bgPath.isNotEmpty && File(bgPath).existsSync();

    final light = AppTheme.light(seed: seed);
    final dark = AppTheme.dark(seed: seed);

    return MaterialApp(
      title: 'Libranote',
      debugShowCheckedModeBanner: false,
      navigatorKey: UpdateService.navigatorKey,
      theme: hasBackground
          ? light.copyWith(scaffoldBackgroundColor: Colors.transparent)
          : light,
      darkTheme: hasBackground
          ? dark.copyWith(scaffoldBackgroundColor: Colors.transparent)
          : dark,
      themeMode: appearance.themeMode,

      // 自定义 App 背景：整棵 widget 树下面垫一张图 + 半透明白保持可读性。
      // Scaffold 背景在设置了背景图时变透明，让图片透出来。
      builder: (context, child) {
        if (!hasBackground) return child!;
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(bgPath),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFFF8FAFC)),
            ),
            const ColoredBox(color: Color(0xE6F8FAFC)), // 半透明白遮罩
            child!,
          ],
        );
      },

      home: const HomeScreen(),
    );
  }
}
