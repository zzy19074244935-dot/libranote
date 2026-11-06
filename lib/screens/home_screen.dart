import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../widgets/app_shell.dart';
import 'ai_center_screen.dart';
import 'bookshelf_screen.dart';
import 'home_portal_screen.dart';
import 'notes_screen.dart';
import 'profile_screen.dart';
import 'whiteboard_list_screen.dart';

/// Main shell with bottom navigation.
///
/// 参考稿风格：底部是圆角胶囊模块栏；切换 Tab 时内容做一次淡入 + 上滑的
/// 丝滑过渡（IndexedStack 保状态，各 Tab 常驻不重建）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;

  late final AnimationController _fadeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );

  static const _screens = <Widget>[
    HomePortalScreen(),
    BookshelfScreen(),
    NotesScreen(),
    AiCenterScreen(),
    WhiteboardListScreen(),
    ProfileScreen(),
  ];

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _switchTab(int i) {
    if (i == _currentIndex) return;
    setState(() => _currentIndex = i);
    // 切到「主页」Tab 时刷新活跃日历与最近阅读（IndexedStack 下各 Tab 常驻，
    // 不刷新会一直显示旧数据）。
    if (i == 0) {
      ref.read(usageProvider.notifier).refresh();
      ref.read(bookshelfProvider.notifier).loadBooks();
    }
    // 切到「笔记」Tab 时刷新笔记中心（IndexedStack 下各 Tab 常驻，
    // 不刷新会一直显示旧数据）。
    if (i == 2) {
      ref.read(notesRefreshProvider.notifier).state++;
    }
    // 切到「AI」Tab 时刷新对话历史侧栏（阅读器里新产生的对话也能看到）。
    if (i == 3) {
      ref.read(aiCenterRefreshProvider.notifier).state++;
    }
    // 切到「书架」Tab 时重绘书架：封面提取完成后能立刻显示。
    if (i == 1) {
      ref.read(shelfRefreshProvider.notifier).state++;
    }
    // 切到「画布」Tab 时重载画布列表：编辑返回后新画布立刻可见。
    if (i == 4) {
      ref.read(whiteboardRefreshProvider.notifier).state++;
    }
    _fadeCtrl.forward(from: 0.45);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _fadeCtrl,
        builder: (context, child) {
          final t = _fadeCtrl.value;
          return Opacity(
            opacity: 0.55 + 0.45 * t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 12),
              child: child,
            ),
          );
        },
        child: IndexedStack(index: _currentIndex, children: _screens),
      ),
      bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
          ? null
          : AppBottomNav(
              currentIndex: _currentIndex,
              onSelect: _switchTab,
            ),
    );
  }
}
