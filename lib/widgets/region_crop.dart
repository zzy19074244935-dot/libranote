import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 框选区域截图的结果：裁剪后的 PNG + 裁剪矩形（相对原图 0~1 归一化，
/// 供「插入编辑中的文件」换算成页面归一化坐标）。
class RegionCropResult {
  final Uint8List png;

  /// 相对原图：左 / 上 / 宽 / 高（0~1）。
  final double nx;
  final double ny;
  final double nw;
  final double nh;

  const RegionCropResult({
    required this.png,
    required this.nx,
    required this.ny,
    required this.nw,
    required this.nh,
  });
}

/// 全屏框选截图：显示 [sourcePng]，用户拖动矩形框（内部=移动、四角=缩放、
/// 框外拖动=重画选区），确认后裁剪返回。
Future<RegionCropResult?> showRegionCrop(
  BuildContext context, {
  required Uint8List sourcePng,
  String title = '框选截图区域',
}) async {
  final image = await _decode(sourcePng);
  if (image == null) return null;
  if (!context.mounted) return null;

  return Navigator.of(context).push<RegionCropResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _RegionCropScreen(image: image, title: title),
    ),
  );
}

Future<ui.Image?> _decode(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

class _RegionCropScreen extends StatefulWidget {
  final ui.Image image;
  final String title;
  const _RegionCropScreen({required this.image, required this.title});

  @override
  State<_RegionCropScreen> createState() => _RegionCropScreenState();
}

enum _DragMode { none, move, resizeTL, resizeTR, resizeBL, resizeBR, creating }

class _RegionCropScreenState extends State<_RegionCropScreen> {
  /// 当前选区（相对图片显示区的 0~1 坐标）。
  Rect? _sel;
  _DragMode _mode = _DragMode.none;
  Offset? _dragStart;
  Rect? _selStart;

  // 图片显示区（BoxFit.contain 后的实际矩形）。
  Rect _imgRect = Rect.zero;
  Size _viewport = Size.zero;

  static const double _handleR = 18;

  @override
  void dispose() {
    widget.image.dispose();
    super.dispose();
  }

  /// 初始选区：中间 60% 区域。build 期间调用（直接赋值不 setState）。
  void _ensureInitSel() {
    if (_sel != null || _imgRect.isEmpty) return;
    _sel = Rect.fromLTWH(
      _imgRect.left + _imgRect.width * 0.2,
      _imgRect.top + _imgRect.height * 0.2,
      _imgRect.width * 0.6,
      _imgRect.height * 0.6,
    );
  }

  _DragMode _hitTest(Offset p) {
    final r = _sel;
    if (r == null) return _DragMode.creating;
    bool near(Offset a) => (p - a).distance <= _handleR;
    if (near(r.topLeft)) return _DragMode.resizeTL;
    if (near(r.topRight)) return _DragMode.resizeTR;
    if (near(r.bottomLeft)) return _DragMode.resizeBL;
    if (near(r.bottomRight)) return _DragMode.resizeBR;
    if (r.contains(p)) return _DragMode.move;
    return _DragMode.creating;
  }

  void _onDown(Offset p) {
    _dragStart = p;
    _selStart = _sel;
    _mode = _hitTest(p);
    if (_mode == _DragMode.creating) {
      setState(() => _sel = Rect.fromPoints(p, p));
    }
  }

  Rect _clamp(Rect r) {
    final l = r.left.clamp(_imgRect.left, _imgRect.right - 20);
    final t = r.top.clamp(_imgRect.top, _imgRect.bottom - 20);
    final rr = r.right.clamp(_imgRect.left + 20, _imgRect.right);
    final b = r.bottom.clamp(_imgRect.top + 20, _imgRect.bottom);
    return Rect.fromLTRB(
      rr < l ? rr : l,
      b < t ? b : t,
      rr < l ? l : rr,
      b < t ? t : b,
    );
  }

  void _onMove(Offset p) {
    final start = _dragStart;
    if (start == null || _sel == null) return;
    final dx = p.dx - start.dx;
    final dy = p.dy - start.dy;
    final base = _selStart ?? _sel!;
    switch (_mode) {
      case _DragMode.move:
        final moved = base.shift(Offset(dx, dy));
        // 选区不能整体移出显示区。
        if (moved.left >= _imgRect.left &&
            moved.right <= _imgRect.right &&
            moved.top >= _imgRect.top &&
            moved.bottom <= _imgRect.bottom) {
          setState(() => _sel = moved);
        }
      case _DragMode.resizeTL:
        setState(() => _sel = _clamp(Rect.fromLTRB(
            base.left + dx, base.top + dy, base.right, base.bottom)));
      case _DragMode.resizeTR:
        setState(() => _sel = _clamp(Rect.fromLTRB(
            base.left, base.top + dy, base.right + dx, base.bottom)));
      case _DragMode.resizeBL:
        setState(() => _sel = _clamp(Rect.fromLTRB(
            base.left + dx, base.top, base.right, base.bottom + dy)));
      case _DragMode.resizeBR:
        setState(() => _sel = _clamp(Rect.fromLTRB(
            base.left, base.top, base.right + dx, base.bottom + dy)));
      case _DragMode.creating:
        setState(() => _sel = _clamp(Rect.fromPoints(start, p)));
      case _DragMode.none:
        break;
    }
  }

  void _onUp() {
    _dragStart = null;
    _selStart = null;
    _mode = _DragMode.none;
  }

  /// 显示区坐标 → 原图像素坐标 → 裁剪。
  Future<void> _confirm() async {
    final sel = _sel;
    if (sel == null) return;
    final srcRect = Rect.fromLTRB(
      (sel.left - _imgRect.left) / _imgRect.width * widget.image.width,
      (sel.top - _imgRect.top) / _imgRect.height * widget.image.height,
      (sel.right - _imgRect.left) / _imgRect.width * widget.image.width,
      (sel.bottom - _imgRect.top) / _imgRect.height * widget.image.height,
    );
    final w = srcRect.width.round().clamp(1, 8192);
    final h = srcRect.height.round().clamp(1, 8192);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      widget.image,
      srcRect,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..isAntiAlias = true,
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(w, h);
    picture.dispose();
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (data == null) return;
    final result = RegionCropResult(
      png: data.buffer.asUint8List(),
      nx: (sel.left - _imgRect.left) / _imgRect.width,
      ny: (sel.top - _imgRect.top) / _imgRect.height,
      nw: sel.width / _imgRect.width,
      nh: sel.height / _imgRect.height,
    );
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: _sel == null ? null : _confirm,
            child: const Text('完成截图',
                style: TextStyle(color: Colors.white, fontSize: 14)),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          _viewport = Size(constraints.maxWidth, constraints.maxHeight);
          final iw = widget.image.width.toDouble();
          final ih = widget.image.height.toDouble();
          final scale = (iw / _viewport.width).clamp(0.0, 1.0) >
                  (ih / _viewport.height).clamp(0.0, 1.0)
              ? _viewport.width / iw
              : _viewport.height / ih;
          final dw = iw * scale;
          final dh = ih * scale;
          _imgRect = Rect.fromLTWH(
            (_viewport.width - dw) / 2,
            (_viewport.height - dh) / 2,
            dw,
            dh,
          );
          _ensureInitSel();
          final sel = _sel;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _onDown(e.localPosition),
            onPointerMove: (e) => _onMove(e.localPosition),
            onPointerUp: (_) => _onUp(),
            onPointerCancel: (_) => _onUp(),
            child: Stack(
              children: [
                // 原图。
                Positioned.fromRect(
                  rect: _imgRect,
                  child: RawImage(
                    image: widget.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                // 选区外变暗。
                if (sel != null)
                  CustomPaint(
                    size: Size.infinite,
                    painter: _ShadePainter(
                      imgRect: _imgRect,
                      sel: sel,
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                // 选区边框 + 手柄。
                if (sel != null)
                  Positioned.fromRect(
                    rect: sel,
                    child: const IgnorePointer(
                      child: CustomPaint(
                        painter: _SelPainter(),
                      ),
                    ),
                  ),
                // 底部提示。
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '拖动框选截图区域：框内=移动 · 四角=调整大小 · 框外=重画',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 选区外暗化。
class _ShadePainter extends CustomPainter {
  final Rect imgRect;
  final Rect sel;
  final Color color;
  const _ShadePainter(
      {required this.imgRect, required this.sel, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // 四条边暗化（简化：整屏暗 + 选区挖亮）。
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(sel);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ShadePainter old) =>
      old.sel != sel || old.color != color;
}

/// 选区边框 + 四角手柄 + 三分线。
class _SelPainter extends CustomPainter {
  static const double handleR = 18;
  const _SelPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRect(rect, border);

    // 三分线。
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }

    // 四角手柄。
    final handle = Paint()..color = const Color(0xFF4F8CFF);
    final handleBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final p in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(p, handleR / 2, handle);
      canvas.drawCircle(p, handleR / 2, handleBorder);
    }
  }

  @override
  bool shouldRepaint(covariant _SelPainter old) => false;
}
