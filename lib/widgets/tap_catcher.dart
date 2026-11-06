import 'package:flutter/material.dart';

/// 轻量「点击段落」捕获器。
///
/// 用原始指针事件（Listener）判断快速轻点，而不是 GestureDetector 的
/// onTap —— 这样不会和 SelectableText 自带的手势竞技场抢事件：
/// 轻点触发回调（例如「从这里开始朗读」），长按选择/复制照常工作。
class TapCatcher extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const TapCatcher({super.key, required this.onTap, required this.child});

  @override
  State<TapCatcher> createState() => _TapCatcherState();
}

class _TapCatcherState extends State<TapCatcher> {
  Offset? _down;
  DateTime _downTime = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (e) {
        _down = e.position;
        _downTime = DateTime.now();
      },
      onPointerUp: (e) {
        final d = _down;
        if (d != null &&
            (e.position - d).distance < 12 &&
            DateTime.now().difference(_downTime).inMilliseconds < 400) {
          widget.onTap();
        }
        _down = null;
      },
      child: widget.child,
    );
  }
}
