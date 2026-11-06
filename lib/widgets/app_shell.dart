import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../config/appearance.dart';
import '../config/theme.dart';
import '../screens/settings_screen.dart';

/// 悬浮导航：安全区留白、最大宽度和独立点击区域；不覆盖页面正文。
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const AppBottomNav(
      {super.key, required this.currentIndex, required this.onSelect});

  static const _tabs = <(IconData, IconData, String)>[
    (Icons.home_rounded, Icons.home_outlined, '主页'),
    (Icons.library_books_rounded, Icons.library_books_outlined, '书架'),
    (Icons.note_rounded, Icons.note_outlined, '笔记'),
    (Icons.auto_awesome_rounded, Icons.auto_awesome_outlined, 'AI'),
    (Icons.draw_rounded, Icons.draw_outlined, '画布'),
    (Icons.person_rounded, Icons.person_outline, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
    final height = 68.0 + (scale - 1).clamp(0, 2) * 16;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.overlay),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.22 : 0.07),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                )
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.overlay),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Material(
                  key: const ValueKey('floating-nav-surface'),
                  color: colors.surface.withValues(alpha: 0.96),
                  child: SizedBox(
                    height: height,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      child: Row(children: [
                        for (var i = 0; i < _tabs.length; i++)
                          _NavItem(
                            icon: _tabs[i].$1,
                            unselectedIcon: _tabs[i].$2,
                            label: _tabs[i].$3,
                            selected: i == currentIndex,
                            onTap: () => onSelect(i),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData unselectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem(
      {required this.icon,
      required this.unselectedIcon,
      required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(22),
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    width: 40,
                    height: 30,
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.primary.withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(selected ? icon : unselectedIcon,
                        size: 21, color: foreground),
                  ),
                  const SizedBox(height: 3),
                  Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                              color: foreground))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 右上角用户头像（渐变描边 + 首字母），点击打开账户信息与设置。
///
/// 每个模块页面右上角都放它（用户要求的统一入口）。
class AppAvatar extends ConsumerWidget {
  final double size;

  /// 点击行为：默认 push 设置页（账户信息 + 应用设置）；传 null 则不可点。
  final VoidCallback? onTap;

  const AppAvatar({super.key, this.size = 36, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 监听头像版本号：在「我的」页换头像后，这里立即重建显示新头像。
    ref.watch(avatarVersionProvider);
    const letter = '书';

    // 用户上传过头像 → 显示图片；否则渐变首字母头像。
    final avatarPath = AppConfig.instance.avatarPath;
    final hasImage = avatarPath != null &&
        avatarPath.isNotEmpty &&
        File(avatarPath).existsSync();

    final avatar = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.05),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: hasImage
            ? Image.file(
                File(avatarPath),
                fit: BoxFit.cover,
                width: size,
                height: size,
                errorBuilder: (_, __, ___) => Text(
                  letter,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: size * 0.42,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              )
            : Text(
                letter,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
      ),
    );

    final handler = onTap ??
        () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          );
        };

    return Tooltip(
      message: '阅读与设置',
      child: InkWell(
        onTap: handler,
        customBorder: const CircleBorder(),
        child: avatar,
      ),
    );
  }
}
