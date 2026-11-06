import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';

/// 工具类型。
enum _Tool { select, pen, eraser, ruler, lasso, text, image, table }

/// 画笔宽度/透明度预设（width 为 null 时的默认值）。
const Map<BrushType, double> _brushWidth = {
  BrushType.pen: 3.5,
  BrushType.fountain: 2.2,
  BrushType.marker: 12,
  BrushType.pencil: 2.5,
  BrushType.highlighter: 26,
  BrushType.line: 3.5,
};
const Map<BrushType, double> _brushOpacity = {
  BrushType.pen: 1.0,
  BrushType.fountain: 1.0,
  BrushType.marker: 0.55,
  BrushType.pencil: 0.85,
  BrushType.highlighter: 0.3,
  BrushType.line: 1.0,
};

/// 色板（ARGB）。
const List<int> _palette = [
  0xFF1A1A1A,
  0xFFE53935,
  0xFF1E88E5,
  0xFF43A047,
  0xFFFB8C00,
  0xFFFDD835,
  0xFF8E24AA,
];

const List<(BrushType, String, IconData)> _brushes = [
  (BrushType.pen, '圆珠笔', Icons.brush),
  (BrushType.fountain, '钢笔', Icons.create),
  (BrushType.marker, '马克笔', Icons.format_paint),
  (BrushType.pencil, '铅笔', Icons.edit),
  (BrushType.highlighter, '荧光笔', Icons.highlight),
];

/// 复制/剪切的剪贴板（笔迹 + 对象一起）。
class _ClipboardData {
  final List<InkStroke> strokes;
  final List<TextItem> texts;
  final List<ImageItem> images;
  final List<TableItem> tables;
  const _ClipboardData(
      {required this.strokes,
      required this.texts,
      required this.images,
      required this.tables});
  bool get isEmpty =>
      strokes.isEmpty && texts.isEmpty && images.isEmpty && tables.isEmpty;
}

/// 无边记式画布编辑器。
///
/// 交互模型（按用户要求彻底重做）：
/// - **双指 = 平移 + 缩放**（所有工具下都生效）；
/// - **单指 = 书写**（画笔/橡皮/尺子/套索）；选择工具下单指拖动「已选中」
///   的对象 = 移动，拖右下角圆点 = 缩放，拖空白/未选中对象 = 什么都不做；
/// - **双击 = 选中该对象**；对已选中的文本/表格再双击 = 直接打开编辑；
///   空白双击 = 取消选择。
///
/// 画布按两种方式自动长大：内容逼近边缘时按内容扩展（提前量 900），
/// 以及缩小时自动扩展到盖住整个视口（不再有「画布外面是灰色」的问题）。
/// 手势全部由画布层自己的 GestureDetector 处理（InteractiveViewer 的平移/缩放
/// 已禁用），坐标用 `TransformationController.toScene` 换算——这样缩放手柄
/// 即使画在世界边缘之外也照样抓得住（此前事件落不到画布 SizedBox 外，
/// 「拉住圆点卡住」的根因）。
class WhiteboardScreen extends ConsumerStatefulWidget {
  final Whiteboard? board; // null = 新建
  const WhiteboardScreen({super.key, this.board});

  @override
  ConsumerState<WhiteboardScreen> createState() => _WhiteboardScreenState();
}

/// 单指拖动模式（down 时命中判定，超过阈值后激活）。
enum _DragMode { none, draw, move, resize, rotate, pan }

class _WhiteboardScreenState extends ConsumerState<WhiteboardScreen> {
  late final Whiteboard _wb;
  final TransformationController _transform = TransformationController();

  _Tool _tool = _Tool.select;
  BrushType _brush = BrushType.pen;
  int _color = 0xFF1A1A1A;
  double _penWidth = 3.5; // 画笔粗细（用户可调）

  // 世界尺寸（随内容增长，实现无限画布）。
  double _worldW = 2400;
  double _worldH = 1800;

  // 撤销/重做：内容 JSON 快照栈。
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  // 正在绘制中的笔迹（实时预览）。
  List<WhiteboardPoint> _currentPoints = [];
  BrushType _currentBrush = BrushType.pen;
  int _currentColor = 0xFF1A1A1A;
  double _currentWidth = 3.5;

  /// 内容版本号：内容每次变化 +1，静态笔迹层据此判断是否重绘
  /// （替代 shouldRepaint 恒 true，修「笔迹一多就掉帧」）。
  int _revision = 0;

  // 套索。
  final List<Offset> _lasso = [];
  final Set<String> _selection = {};
  _ClipboardData? _clipboard;
  int _pasteCount = 0;

  // 选择工具手势状态。
  double _scaleAccum = 1.0;
  Offset _lastFocal = Offset.zero;
  Set<String>? _moveIds;
  bool _moved = false;

  String? _resizeId;
  Offset? _resizeStartPos;
  double? _resizeOrigW;
  double? _resizeOrigH;
  double? _resizeOrigFontSize;

  // 旋转手柄状态。
  String? _rotateId;

  /// 当前视口尺寸（逻辑像素），由 LayoutBuilder 更新，供「画布盖住视口」计算。
  Size _viewportSize = Size.zero;

  // 橡皮实时位置。
  Offset? _eraserPos;

  int _counter = 0;
  String _newId(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch}${_counter++}';

  /// 视图坐标 → 世界坐标（InteractiveViewer 的变换矩阵反算）。
  Offset _toWorld(Offset p) => _transform.toScene(p);

  /// 当前视图缩放（用于把手柄/线宽换算成屏幕恒定大小）。
  double get _viewScale {
    final s = _transform.value.getMaxScaleOnAxis();
    return s <= 0.01 ? 0.01 : s;
  }

  @override
  void initState() {
    super.initState();
    _wb = Whiteboard(
      id: widget.board?.id,
      title: widget.board?.title ?? '',
      createdAt: widget.board?.createdAt,
    );
    _wb.loadContent(widget.board?.contentJson);
    if (_wb.title.isEmpty && widget.board == null) {
      _wb.title = '画布 ${DateFormat('MM-dd HH:mm').format(DateTime.now())}';
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fitCanvas();
      _growCanvasToViewport();
      _centerOnContent();
      setState(() {});
    });
  }

  @override
  void dispose() {
    // 取消防抖并立刻落盘：快速退出也不丢最后一次修改。
    _saveTimer?.cancel();
    _persist();
    _transform.dispose();
    super.dispose();
  }

  // ── 持久化 ────────────────────────────────────────────────────────

  Future<void> _persist() async {
    try {
      final storage = ref.read(storageServiceProvider);
      if (_wb.id == null) {
        _wb.id = await storage.insertWhiteboard(_wb);
      } else {
        await storage.updateWhiteboard(_wb);
      }
    } catch (e) {
      debugPrint('[Whiteboard] persist failed: $e');
    }
  }

  Timer? _saveTimer;

  /// 500ms 防抖合并连续写库（拖动/绘制收尾高频触发时不再每下都写 SQLite）。
  void _schedulePersist() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _persist);
  }

  void _markDirtyAndSave() {
    if (!mounted) return;
    _revision++;
    _fitCanvas();
    _growCanvasToViewport();
    setState(() {});
    _schedulePersist();
  }

  // ── 无限画布：按内容自适应扩展 ─────────────────────────────────

  /// 内容包围盒（无内容时返回 null）。
  Rect? _contentBounds() {
    double? minX, minY, maxX, maxY;
    void add(Rect r) {
      minX = minX == null ? r.left : (r.left < minX! ? r.left : minX);
      minY = minY == null ? r.top : (r.top < minY! ? r.top : minY);
      maxX = maxX == null ? r.right : (r.right > maxX! ? r.right : maxX);
      maxY = maxY == null ? r.bottom : (r.bottom > maxY! ? r.bottom : maxY);
    }

    for (final s in _wb.strokes) {
      add(_strokeBounds(s));
    }
    for (final t in _wb.texts) {
      add(_textRect(t));
    }
    for (final im in _wb.images) {
      add(_imageRect(im));
    }
    for (final tb in _wb.tables) {
      add(_tableRect(tb));
    }
    if (minX == null) return null;
    return Rect.fromLTRB(minX!, minY!, maxX!, maxY!);
  }

  /// 内容越过边缘时：扩展画布；内容跑到负坐标时：整体平移回正并补偿视图，
  /// 让画面不跳动。这样画布向任何方向都是「无限」的。
  void _fitCanvas() {
    // 提前量给大一些：内容离边缘还有 900 世界像素时画布就扩展，
    // 而不是等笔画画出边界才变大。
    const margin = 900.0;
    final bounds = _contentBounds();
    if (bounds == null) return;

    double dx = 0, dy = 0;
    if (bounds.left < margin) dx = margin - bounds.left;
    if (bounds.top < margin) dy = margin - bounds.top;
    final newW = bounds.right + margin > _worldW ? bounds.right + margin : _worldW;
    final newH = bounds.bottom + margin > _worldH ? bounds.bottom + margin : _worldH;

    if (dx != 0 || dy != 0) {
      _translateAll(dx, dy);
      // 内容平移了 (+dx,+dy)，视图矩阵反向补偿，画面保持不动。
      final m = _transform.value.clone();
      m.translateByDouble(-dx, -dy, 0, 1);
      _transform.value = m;
    }
    _worldW = newW;
    _worldH = newH;
  }

  /// 让世界画布始终盖住整个视口（用户缩小画面时自动「加载」画布，
  /// 而不是显示画布外的灰底）。
  ///
  /// 用当前变换矩阵把视口四角反算回世界坐标，世界画布小于可见范围就往
  /// 四周长大（带 1200 世界单位的余量）；可见区域进入负坐标时同样整体
  /// 平移回正并补偿视图矩阵，画面不跳。
  void _growCanvasToViewport() {    if (_viewportSize == Size.zero) return;
    const margin = 1200.0;

    final tl = _toWorld(Offset.zero);
    final br = _toWorld(Offset(_viewportSize.width, _viewportSize.height));
    final minX = tl.dx < br.dx ? tl.dx : br.dx;
    final minY = tl.dy < br.dy ? tl.dy : br.dy;
    final maxX = tl.dx > br.dx ? tl.dx : br.dx;
    final maxY = tl.dy > br.dy ? tl.dy : br.dy;

    double dx = 0, dy = 0;
    if (minX < margin) dx = margin - minX;
    if (minY < margin) dy = margin - minY;

    if (dx != 0 || dy != 0) {
      _translateAll(dx, dy);
      final m = _transform.value.clone();
      m.translateByDouble(-dx, -dy, 0, 1);
      _transform.value = m;
    }
    final neededW = maxX + margin;
    final neededH = maxY + margin;
    if (neededW > _worldW) _worldW = neededW;
    if (neededH > _worldH) _worldH = neededH;
  }

  /// 首次进入：平移视图让内容包围盒中心对齐视口中心（有内容时）。
  void _centerOnContent() {
    if (_viewportSize == Size.zero) return;
    final bounds = _contentBounds();
    if (bounds == null) return;
    final inView = MatrixUtils.transformPoint(_transform.value, bounds.center);
    final dx = _viewportSize.width / 2 - inView.dx;
    final dy = _viewportSize.height / 2 - inView.dy;
    if (dx.abs() < 1 && dy.abs() < 1) return;
    _panBy(Offset(dx, dy));
  }

  /// 平移所有内容（画布扩展时用）。
  void _translateAll(double dx, double dy) {
    for (var i = 0; i < _wb.strokes.length; i++) {
      _wb.strokes[i] = _translatedStroke(_wb.strokes[i], dx, dy);
    }
    for (var i = 0; i < _wb.texts.length; i++) {
      final t = _wb.texts[i];
      _wb.texts[i] = TextItem(
          id: t.id,
          x: t.x + dx,
          y: t.y + dy,
          text: t.text,
          fontSize: t.fontSize,
          rotation: t.rotation);
    }
    for (var i = 0; i < _wb.images.length; i++) {
      final im = _wb.images[i];
      _wb.images[i] = ImageItem(
          id: im.id,
          x: im.x + dx,
          y: im.y + dy,
          width: im.width,
          height: im.height,
          path: im.path,
          rotation: im.rotation);
    }
    for (var i = 0; i < _wb.tables.length; i++) {
      final tb = _wb.tables[i];
      _wb.tables[i] = TableItem(
          id: tb.id,
          x: tb.x + dx,
          y: tb.y + dy,
          rows: tb.rows,
          cols: tb.cols,
          cells: tb.cells,
          cellW: tb.cellW,
          cellH: tb.cellH,
          rotation: tb.rotation);
    }
  }

  InkStroke _translatedStroke(InkStroke s, double dx, double dy) => InkStroke(
        id: s.id,
        color: s.color,
        brush: s.brush,
        width: s.width,
        points: s.points
            .map((pt) =>
                WhiteboardPoint(x: pt.x + dx, y: pt.y + dy, pressure: pt.pressure))
            .toList(),
      );

  // ── 撤销/重做 ─────────────────────────────────────────────────────

  void _pushUndo() {
    _undoStack.add(_wb.contentJson);
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_wb.contentJson);
    _wb.loadContent(_undoStack.removeLast());
    _clearTransientGestureState();
    _revision++;
    _fitCanvas();
    _growCanvasToViewport();
    setState(() {});
    _persist();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_wb.contentJson);
    _wb.loadContent(_redoStack.removeLast());
    _clearTransientGestureState();
    _revision++;
    _fitCanvas();
    _growCanvasToViewport();
    setState(() {});
    _persist();
  }

  /// 撤销/重做后清掉绘制中的预览笔迹、套索与橡皮圈，避免残留到下一次绘制。
  void _clearTransientGestureState() {
    _currentPoints = [];
    _lasso.clear();
    _eraserPos = null;
    _selection.clear();
  }

  // ── 几何 / 命中 ──────────────────────────────────────────────────

  Rect _strokeBounds(InkStroke s) {
    if (s.points.isEmpty) return Rect.zero;
    var minX = s.points.first.x, minY = s.points.first.y;
    var maxX = minX, maxY = minY;
    for (final pt in s.points) {
      if (pt.x < minX) minX = pt.x;
      if (pt.x > maxX) maxX = pt.x;
      if (pt.y < minY) minY = pt.y;
      if (pt.y > maxY) maxY = pt.y;
    }
    final w = (s.width ?? (_brushWidth[s.brush] ?? 3.5)) + 10;
    return Rect.fromLTRB(minX - w, minY - w, maxX + w, maxY + w);
  }

  Rect _textRect(TextItem t) {
    final w = (t.text.length * t.fontSize * 0.55).clamp(24.0, 900.0);
    return Rect.fromLTWH(t.x, t.y, w, t.fontSize * 1.6);
  }

  Rect _imageRect(ImageItem im) =>
      Rect.fromLTWH(im.x, im.y, im.width, im.height);

  Rect _tableRect(TableItem tb) =>
      Rect.fromLTWH(tb.x, tb.y, tb.cols * tb.cellW, tb.rows * tb.cellH);

  InkStroke? _strokeById(String id) {
    for (final s in _wb.strokes) {
      if (s.id == id) return s;
    }
    return null;
  }

  TextItem? _textById(String id) {
    for (final t in _wb.texts) {
      if (t.id == id) return t;
    }
    return null;
  }

  TableItem? _tableById(String id) {
    for (final tb in _wb.tables) {
      if (tb.id == id) return tb;
    }
    return null;
  }

  ImageItem? _imageById(String id) {
    for (final im in _wb.images) {
      if (im.id == id) return im;
    }
    return null;
  }

  /// 选中项的未旋转外框（x,y,w,h —— 用于取尺寸/缩放基准）。
  Rect? _rectById(String id) {
    if (id.startsWith('t')) {
      final t = _textById(id);
      return t == null ? null : _textRect(t);
    }
    if (id.startsWith('i')) {
      final im = _imageById(id);
      return im == null ? null : _imageRect(im);
    }
    if (id.startsWith('tb')) {
      final tb = _tableById(id);
      return tb == null ? null : _tableRect(tb);
    }
    final s = _strokeById(id);
    return s == null ? null : _strokeBounds(s);
  }

  /// 对象旋转角（笔迹无旋转）。
  double _rotationOf(String id) {
    if (id.startsWith('t')) return _textById(id)?.rotation ?? 0;
    if (id.startsWith('i')) return _imageById(id)?.rotation ?? 0;
    if (id.startsWith('tb')) return _tableById(id)?.rotation ?? 0;
    return 0;
  }

  /// 旋转后对象的中心点。
  Offset? _centerOf(String id) {
    final r = _rectById(id);
    if (r == null) return null;
    return r.center;
  }

  /// 旋转后的四个角点（顺时针：TL TR BR BL）。
  List<Offset> _cornersOf(String id) {
    final r = _rectById(id);
    if (r == null) return const [];
    final a = _rotationOf(id);
    final c = r.center;
    final cosA = math.cos(a), sinA = math.sin(a);
    Offset rot(double lx, double ly) => Offset(
          c.dx + lx * cosA - ly * sinA,
          c.dy + lx * sinA + ly * cosA,
        );
    return [
      rot(-r.width / 2, -r.height / 2),
      rot(r.width / 2, -r.height / 2),
      rot(r.width / 2, r.height / 2),
      rot(-r.width / 2, r.height / 2),
    ];
  }

  /// 缩放手柄位置：旋转后的右下角。
  Offset? _scaleHandleOf(String id) {
    final r = _rectById(id);
    if (r == null) return null;
    final a = _rotationOf(id);
    final c = r.center;
    return Offset(
      c.dx + (r.width / 2) * math.cos(a) - (r.height / 2) * math.sin(a),
      c.dy + (r.width / 2) * math.sin(a) + (r.height / 2) * math.cos(a),
    );
  }

  /// 旋转手柄位置：旋转后的顶边中点。
  Offset? _rotateHandleOf(String id) {
    final r = _rectById(id);
    if (r == null) return null;
    final a = _rotationOf(id);
    final c = r.center;
    return Offset(
      c.dx - (-r.height / 2) * math.sin(a),
      c.dy + (-r.height / 2) * math.cos(a),
    );
  }

  /// 命中检测：后画的在上层——先对象（表格→图片→文本）再笔迹。
  /// 旋转对象用**旋转后的多边形**判定（旧版用 AABB，45° 对象角部大面积
  /// 误命中）；未旋转对象用外框；笔迹用包围盒。
  String? _hitObject(Offset pos) {
    for (final tb in _wb.tables.reversed) {
      if (_hitItemPrecise(pos, tb.id, _tableRect(tb), tb.rotation)) {
        return tb.id;
      }
    }
    for (final im in _wb.images.reversed) {
      if (_hitItemPrecise(pos, im.id, _imageRect(im), im.rotation)) {
        return im.id;
      }
    }
    for (final t in _wb.texts.reversed) {
      if (_hitItemPrecise(pos, t.id, _textRect(t), t.rotation)) {
        return t.id;
      }
    }
    for (final s in _wb.strokes.reversed) {
      if (_strokeBounds(s).contains(pos)) return s.id;
    }
    return null;
  }

  bool _hitItemPrecise(Offset pos, String id, Rect rect, double rotation) {
    if (rect.isEmpty) return false;
    if (rotation == 0) return rect.contains(pos);
    return _pointInPolygon(pos, _cornersOf(id));
  }

  String? _hitResizeHandle(Offset pos) {
    // 命中半径按当前缩放换算成世界坐标，保证屏幕上始终是 ~26px，
    // 缩小画布时圆点也能轻松抓住。
    final radius = 26 / _viewScale;
    for (final id in _selection) {
      if (id.startsWith('s')) continue; // 笔迹无缩放
      final handle = _scaleHandleOf(id);
      if (handle == null) continue;
      if ((pos - handle).distance < radius) return id;
    }
    return null;
  }

  String? _hitRotateHandle(Offset pos) {
    final radius = 26 / _viewScale;
    for (final id in _selection) {
      if (id.startsWith('s')) continue;
      final handle = _rotateHandleOf(id);
      if (handle == null) continue;
      if ((pos - handle).distance < radius) return id;
    }
    return null;
  }

  // ── 手势：Listener 自研单指状态机 + GestureDetector 只挂双指 ────────
  //
  // 旧实现把 pan/scale/tap/doubleTap 全塞进 GestureDetector，识别器在竞技场
  // 里互抢：单指被 scale 误吞 → 画笔断续；pan accept 后双指接管不了 → 缩放
  // 失灵；没注册 onPanCancel → 状态残留。现在：
  //   · Listener 收原始指针事件，自己跟踪「几根手指」——单指全权处理
  //     （draw/move/resize/rotate/pan/tap），不参与任何识别器竞争，画笔
  //     down 即响应，零延迟；
  //   · GestureDetector 只注册 onScale*，且仅当 pointerCount ≥ 2 才生效
  //     （第二指落下的第一帧接管单指操作）；
  //   · 单击/双击不再用识别器：移动距离小于阈值（6 屏幕px）即视为点击，
  //     点已选中的文本/表格直接打开编辑（无边记式，无需双击）。

  bool get _drawDrag =>
      _tool == _Tool.pen ||
      _tool == _Tool.eraser ||
      _tool == _Tool.ruler ||
      _tool == _Tool.lasso;

  final Map<int, Offset> _pointers = {}; // pointerId → 视图坐标
  int _activePointer = -1;
  Offset? _downPos; // 单指 down 的世界坐标
  Offset? _lastWorldPos; // 上一帧世界坐标（move/resize 的增量）
  Offset? _lastViewPos; // 上一帧视图坐标（pan 的增量）
  _DragMode _downMode = _DragMode.none;
  _DragMode _activeMode = _DragMode.none;
  bool _pinchStarted = false;

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      // 第二指落下：收尾单指操作，等 scale 手势接管。
      _cancelActiveGesture();
      _activePointer = -1;
      return;
    }
    _activePointer = e.pointer;
    _downPos = _toWorld(e.localPosition);
    _lastWorldPos = _downPos;
    _lastViewPos = e.localPosition;
    _downMode = _resolveDownMode(_downPos!);
    _activeMode = _DragMode.none;
  }

  /// down 时判定意图（只判定，不执行；超过阈值才激活）。
  _DragMode _resolveDownMode(Offset pos) {
    if (_drawDrag) return _DragMode.draw;
    switch (_tool) {
      case _Tool.select:
        if (_hitResizeHandle(pos) != null) return _DragMode.resize;
        if (_hitRotateHandle(pos) != null) return _DragMode.rotate;
        if (_hitObject(pos) != null) return _DragMode.move;
        return _DragMode.pan;
      case _Tool.text:
      case _Tool.image:
      case _Tool.table:
        return _DragMode.none; // 只有点击放置
      default:
        return _DragMode.none;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2 || e.pointer != _activePointer) return;
    final pos = _toWorld(e.localPosition);

    if (_activeMode == _DragMode.none) {
      // 屏幕像素阈值：小于 6px 视为点击，不激活拖动。
      final dist = (pos - _downPos!).distance * _viewScale;
      if (dist < 6) return;
      _activateGesture(_downPos!);
      if (_activeMode == _DragMode.none) return;
    }

    switch (_activeMode) {
      case _DragMode.draw:
        _drawUpdate(pos);
      case _DragMode.move:
        final dx = pos.dx - _lastWorldPos!.dx;
        final dy = pos.dy - _lastWorldPos!.dy;
        if (dx != 0 || dy != 0) {
          if (!_moved) {
            // 第一次真正移动才压 undo 快照。
            _pushUndo();
            _moved = true;
          }
          _translateSelection(dx, dy);
        }
        _lastWorldPos = pos;
      case _DragMode.resize:
        _resizeBy(Offset(
            pos.dx - _lastWorldPos!.dx, pos.dy - _lastWorldPos!.dy));
        _lastWorldPos = pos;
      case _DragMode.rotate:
        _rotateBy(pos);
      case _DragMode.pan:
        _panBy(e.localPosition - _lastViewPos!);
        _lastViewPos = e.localPosition;
        _growCanvasToViewport();
      case _DragMode.none:
        break;
    }
    setState(() {});
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers.remove(e.pointer);
    if (e.pointer != _activePointer) return;
    _activePointer = -1;

    if (_activeMode != _DragMode.none) {
      _finishActiveGesture();
    } else {
      _handleTap(_downPos ?? _toWorld(e.localPosition));
    }
    _downMode = _DragMode.none;
    _activeMode = _DragMode.none;
    _downPos = null;
  }

  /// 指针被系统取消（来电/通知栏下拉等）：清理单指状态，绘制中的笔收尾。
  void _onPointerCancel(PointerCancelEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers.remove(e.pointer);
    if (e.pointer != _activePointer) return;
    _activePointer = -1;
    _cancelActiveGesture();
    _downMode = _DragMode.none;
    _downPos = null;
  }

  /// 超过阈值：把 down 时的意图真正执行起来。
  void _activateGesture(Offset pos) {
    switch (_downMode) {
      case _DragMode.draw:
        _drawStart(pos);
      case _DragMode.move:
        _beginMove(pos);
      case _DragMode.resize:
        _beginResize(pos);
      case _DragMode.rotate:
        _beginRotate(pos);
      case _DragMode.pan:
        break; // 平移无需准备
      case _DragMode.none:
        return;
    }
    _activeMode = _downMode;
  }

  /// 单指拖动结束：收尾 + 保存。
  void _finishActiveGesture() {
    switch (_activeMode) {
      case _DragMode.draw:
        _finishDrawingGesture();
      case _DragMode.move:
        if (_moveIds != null) {
          if (_moved) _markDirtyAndSave();
          _moveIds = null;
        }
      case _DragMode.resize:
        _resizeId = null;
        _resizeStartPos = null;
        _markDirtyAndSave();
      case _DragMode.rotate:
        _rotateId = null;
        _markDirtyAndSave();
      case _DragMode.pan:
        _growCanvasToViewport();
      case _DragMode.none:
        break;
    }
    _moved = false;
  }

  /// 双指接管：收尾进行中的单指操作（收笔保存 / 放弃拖动）。
  void _cancelActiveGesture() {
    switch (_activeMode) {
      case _DragMode.draw:
        _finishDrawingGesture();
      case _DragMode.move:
        _moveIds = null;
        _moved = false;
      case _DragMode.resize:
        _resizeId = null;
        _resizeStartPos = null;
      case _DragMode.rotate:
        _rotateId = null;
      case _DragMode.pan:
      case _DragMode.none:
        break;
    }
    _activeMode = _DragMode.none;
    _downMode = _DragMode.none;
  }

  /// 点击（移动 < 6px）：选择工具 = 选中/取消选中/编辑；
  /// 文本/图片/表格工具 = 放置对象。
  void _handleTap(Offset pos) {
    switch (_tool) {
      case _Tool.select:
        final hit = _hitObject(pos);
        if (hit == null) {
          setState(() => _selection.clear());
          return;
        }
        final alreadySelected =
            _selection.length == 1 && _selection.contains(hit);
        setState(() => _selection
          ..clear()
          ..add(hit));
        // 点已选中的文本/表格 → 直接打开编辑（无边记式，免双击）。
        if (alreadySelected) {
          if (hit.startsWith('t')) {
            final t = _textById(hit);
            if (t != null) _editText(t);
          } else if (hit.startsWith('tb')) {
            final tb = _tableById(hit);
            if (tb != null) _pickTableCell(tb);
          }
        }
      case _Tool.text:
        _addTextAt(pos);
      case _Tool.image:
        _addImageAt(pos);
      case _Tool.table:
        _addTableAt(pos);
      default:
        break;
    }
  }

  // ── 选择工具：移动 / 缩放 / 平移的实现 ─────────────────────────

  void _beginMove(Offset pos) {
    final hit = _hitObject(pos);
    if (hit == null) return;
    // 未选中 → 单选替换；已选中 → 保持多选整体移动。
    if (!_selection.contains(hit)) {
      setState(() => _selection
        ..clear()
        ..add(hit));
    }
    // 不在这里 pushUndo：第一次真正移动时才压栈（修「点了没动也产生
    // 一条 undo 记录、还要用 _undo 回滚」的脆弱设计）。
    _moveIds = Set.of(_selection);
    _moved = false;
  }

  void _beginResize(Offset pos) {
    final hit = _hitResizeHandle(pos);
    if (hit == null) return;
    final r = _rectById(hit);
    if (r == null) return;
    _pushUndo();
    _resizeId = hit;
    _resizeStartPos = pos;
    _resizeOrigW = r.width;
    _resizeOrigH = r.height;
    _resizeOrigFontSize = _textById(hit)?.fontSize;
  }

  void _beginRotate(Offset pos) {
    final hit = _hitRotateHandle(pos);
    if (hit == null) return;
    if (_centerOf(hit) == null) return;
    _pushUndo();
    _rotateId = hit;
  }

  /// 画布平移（单指拖空白 / 双指拖动）。
  void _panBy(Offset delta) {
    final m = _transform.value.clone();
    m.translateByDouble(delta.dx, delta.dy, 0, 1);
    _transform.value = m;
  }

  void _zoomAt(Offset focal, double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    var f = factor;
    if (current * f < 0.1) f = 0.1 / current;
    if (current * f > 12) f = 12 / current;
    final m = _transform.value.clone();
    m.translateByDouble(focal.dx, focal.dy, 0, 1);
    m.scaleByDouble(f, f, f, 1);
    m.translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _transform.value = m;
  }

  // ── 双指 scale：平移 + 缩放（GestureDetector 只挂这个） ──────────

  void _onScaleStart(ScaleStartDetails d) {
    // 单指时不接管（Listener 正在处理）；第二指落下的第一帧接管。
    if (d.pointerCount < 2) return;
    _pinchStarted = true;
    _cancelActiveGesture();
    _scaleAccum = 1.0;
    _lastFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount < 2) return;
    if (!_pinchStarted) {
      // 先单指拖了一段再落第二指：Scale 手势早已 accept，收不到新的
      // Start——在这里补一次接管，并吞掉单指阶段的累计缩放，画面不跳。
      _pinchStarted = true;
      _cancelActiveGesture();
      _scaleAccum = d.scale;
      _lastFocal = d.localFocalPoint;
      return;
    }
    final delta = d.localFocalPoint - _lastFocal;
    _panBy(delta);
    final factor = d.scale / _scaleAccum;
    _scaleAccum = d.scale;
    _zoomAt(d.localFocalPoint, factor);
    _lastFocal = d.localFocalPoint;
    // _growCanvasToViewport 不在每帧调（O(n) 遍历），手势结束再收敛。
    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _pinchStarted = false;
    _growCanvasToViewport();
    setState(() {});
  }

  /// 旋转手柄拖动：以对象中心为轴，按手指方位角实时更新旋转角。
  void _rotateBy(Offset pos) {
    final id = _rotateId;
    final center = id == null ? null : _centerOf(id);
    if (id == null || center == null) return;
    final angle = (pos - center).direction + 1.5707963267948966; // 顶部手柄为 0
    var target = angle;
    // 吸附：靠近 0/90/180/270/360 度时粘住，方便摆正。
    final deg = (target * 180 / 3.141592653589793) % 360;
    const snapDeg = 4.0;
    for (final snap in const [0.0, 90.0, 180.0, 270.0, 360.0]) {
      final diff = (deg - snap).abs() % 360;
      final d = diff > 180 ? 360 - diff : diff;
      if (d < snapDeg) {
        target = snap * 3.141592653589793 / 180;
        break;
      }
    }
    _setItemRotation(id, target);
    setState(() {});
  }

  void _setItemRotation(String id, double rotation) {
    if (id.startsWith('t')) {
      final idx = _wb.texts.indexWhere((x) => x.id == id);
      if (idx >= 0) {
        final t = _wb.texts[idx];
        _wb.texts[idx] = TextItem(
            id: t.id,
            x: t.x,
            y: t.y,
            text: t.text,
            fontSize: t.fontSize,
            rotation: rotation);
      }
    } else if (id.startsWith('i')) {
      final idx = _wb.images.indexWhere((x) => x.id == id);
      if (idx >= 0) {
        final im = _wb.images[idx];
        _wb.images[idx] = ImageItem(
            id: im.id,
            x: im.x,
            y: im.y,
            width: im.width,
            height: im.height,
            path: im.path,
            rotation: rotation);
      }
    } else if (id.startsWith('tb')) {
      final idx = _wb.tables.indexWhere((x) => x.id == id);
      if (idx >= 0) {
        final tb = _wb.tables[idx];
        _wb.tables[idx] = TableItem(
            id: tb.id,
            x: tb.x,
            y: tb.y,
            rows: tb.rows,
            cols: tb.cols,
            cells: tb.cells,
            cellW: tb.cellW,
            cellH: tb.cellH,
            rotation: rotation);
      }
    }
  }

  /// 把正在进行的绘制/拖动手势收尾（双指切入或手势结束时调用）。
  void _finishDrawingGesture() {
    if (_tool == _Tool.pen || _tool == _Tool.ruler) {
      _finishStroke();
    } else if (_tool == _Tool.eraser) {
      _eraserPos = null;
      _markDirtyAndSave(); // 之前只 persist 不重算画布/重绘，橡皮擦后画布不收敛
    } else if (_tool == _Tool.lasso) {
      _finishLasso();
    }
  }

  // ── 绘制手势（画笔/橡皮/尺子/套索） ────────────────────────────

  void _drawStart(Offset pos) {
    switch (_tool) {
      case _Tool.pen:
        _pushUndo();
        _currentBrush = _brush;
        _currentColor = _color;
        _currentWidth = _penWidth;
        _currentPoints = [WhiteboardPoint(x: pos.dx, y: pos.dy)];
        setState(() {});
      case _Tool.ruler:
        _pushUndo();
        _currentBrush = BrushType.line;
        _currentColor = _color;
        _currentWidth = _penWidth;
        _currentPoints = [WhiteboardPoint(x: pos.dx, y: pos.dy)];
        setState(() {});
      case _Tool.eraser:
        _pushUndo();
        _eraseAt(pos);
        setState(() => _eraserPos = pos);
      case _Tool.lasso:
        _lasso.clear();
        _lasso.add(pos);
        setState(() {});
      default:
        break;
    }
  }

  void _drawUpdate(Offset pos) {
    switch (_tool) {
      case _Tool.pen:
        setState(() => _currentPoints
            .add(WhiteboardPoint(x: pos.dx, y: pos.dy, pressure: 1)));
      case _Tool.ruler:
        setState(() {
          if (_currentPoints.length > 1) _currentPoints.removeLast();
          _currentPoints.add(WhiteboardPoint(x: pos.dx, y: pos.dy));
        });
      case _Tool.eraser:
        _eraseAt(pos);
        setState(() => _eraserPos = pos);
      case _Tool.lasso:
        setState(() => _lasso.add(pos));
      default:
        break;
    }
  }

  void _finishStroke() {
    if (_currentPoints.length >= 2) {
      _wb.strokes.add(InkStroke(
        id: _newId('s'),
        color: _currentColor,
        brush: _currentBrush,
        width: _currentWidth,
        points: List.of(_currentPoints),
      ));
      _markDirtyAndSave();
    }
    _currentPoints = [];
  }

  // ── 橡皮（按段擦除） ─────────────────────────────────────────────

  void _eraseAt(Offset c) {
    // 世界半径 = 16 屏幕px / 缩放：擦除范围屏幕恒定，缩小画布也能擦动。
    final r = 16.0 / _viewScale;
    final next = <InkStroke>[];
    for (final s in _wb.strokes) {
      next.addAll(_splitStroke(s, c, r));
    }
    _wb.strokes = next;
  }

  List<InkStroke> _splitStroke(InkStroke s, Offset c, double r) {
    final pts = s.points;
    if (pts.isEmpty) return [];
    final kept = <WhiteboardPoint>[];
    final out = <InkStroke>[];
    for (var i = 0; i < pts.length; i++) {
      final pt = pts[i];
      bool erased;
      if (i == 0) {
        erased = (Offset(pt.x, pt.y) - c).distance <= r;
      } else {
        final prev = pts[i - 1];
        erased = (Offset(pt.x, pt.y) - c).distance <= r ||
            _segDist(c, Offset(prev.x, prev.y), Offset(pt.x, pt.y)) <= r;
      }
      if (erased) {
        if (kept.length >= 2) out.add(_strokeFrom(kept, s));
        kept.clear();
      } else {
        kept.add(pt);
      }
    }
    if (kept.length >= 2) out.add(_strokeFrom(kept, s));
    return out;
  }

  InkStroke _strokeFrom(List<WhiteboardPoint> pts, InkStroke src) => InkStroke(
        id: _newId('s'),
        color: src.color,
        brush: src.brush,
        width: src.width,
        points: pts,
      );

  double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  // ── 套索（不规则自由形状，选中笔迹 + 对象） ────────────────────

  void _finishLasso() {
    if (_lasso.length < 3) {
      setState(() => _lasso.clear());
      return;
    }
    final selected = <String>{};
    for (final s in _wb.strokes) {
      if (s.points.any((pt) => _pointInPolygon(Offset(pt.x, pt.y), _lasso))) {
        selected.add(s.id);
      }
    }
    for (final t in _wb.texts) {
      if (_pointInPolygon(_textRect(t).topLeft, _lasso)) selected.add(t.id);
    }
    for (final im in _wb.images) {
      if (_pointInPolygon(_imageRect(im).topLeft, _lasso)) selected.add(im.id);
    }
    for (final tb in _wb.tables) {
      if (_pointInPolygon(_tableRect(tb).topLeft, _lasso)) selected.add(tb.id);
    }
    setState(() {
      _selection
        ..clear()
        ..addAll(selected);
      _lasso.clear();
    });
  }

  bool _pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final pi = poly[i], pj = poly[j];
      if ((pi.dy > p.dy) != (pj.dy > p.dy) &&
          p.dx <
              (pj.dx - pi.dx) * (p.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  // ── 复制 / 剪切 / 粘贴 ───────────────────────────────────────────

  void _copySelection({bool cut = false}) {
    final strokes = <InkStroke>[];
    final texts = <TextItem>[];
    final images = <ImageItem>[];
    final tables = <TableItem>[];
    for (final id in _selection) {
      if (id.startsWith('s')) {
        final s = _strokeById(id);
        if (s != null) strokes.add(_cloneStroke(s));
      } else if (id.startsWith('t')) {
        final t = _textById(id);
        if (t != null) texts.add(_cloneText(t));
      } else if (id.startsWith('i')) {
        final im = _imageById(id);
        if (im != null) images.add(_cloneImage(im));
      } else if (id.startsWith('tb')) {
        final tb = _tableById(id);
        if (tb != null) tables.add(_cloneTable(tb));
      }
    }
    _clipboard = _ClipboardData(
        strokes: strokes, texts: texts, images: images, tables: tables);
    final count = strokes.length + texts.length + images.length + tables.length;

    if (cut) {
      _pushUndo();
      _deleteSelection();
      _markDirtyAndSave();
      _toast('已剪切 $count 个对象');
    } else {
      _toast('已复制 $count 个对象（切到「选择」后可用粘贴）');
    }
  }

  void _pasteClipboard() {
    final cb = _clipboard;
    if (cb == null || cb.isEmpty) return;
    _pushUndo();
    _pasteCount++;
    final dx = 40.0 * _pasteCount;
    final ids = <String>[];
    for (final s in cb.strokes) {
      final c = _cloneStroke(s, dx: dx, dy: dx);
      _wb.strokes.add(c);
      ids.add(c.id);
    }
    for (final t in cb.texts) {
      final c = _cloneText(t, dx: dx, dy: dx);
      _wb.texts.add(c);
      ids.add(c.id);
    }
    for (final im in cb.images) {
      final c = _cloneImage(im, dx: dx, dy: dx);
      _wb.images.add(c);
      ids.add(c.id);
    }
    for (final tb in cb.tables) {
      final c = _cloneTable(tb, dx: dx, dy: dx);
      _wb.tables.add(c);
      ids.add(c.id);
    }
    _selection
      ..clear()
      ..addAll(ids);
    _markDirtyAndSave();
  }

  InkStroke _cloneStroke(InkStroke s, {double dx = 0, double dy = 0}) =>
      InkStroke(
        id: _newId('s'),
        color: s.color,
        brush: s.brush,
        width: s.width,
        points: s.points
            .map((pt) => WhiteboardPoint(
                x: pt.x + dx, y: pt.y + dy, pressure: pt.pressure))
            .toList(),
      );

  TextItem _cloneText(TextItem t, {double dx = 0, double dy = 0}) => TextItem(
      id: _newId('t'),
      x: t.x + dx,
      y: t.y + dy,
      text: t.text,
      fontSize: t.fontSize,
      rotation: t.rotation);

  ImageItem _cloneImage(ImageItem im, {double dx = 0, double dy = 0}) =>
      ImageItem(
          id: _newId('i'),
          x: im.x + dx,
          y: im.y + dy,
          width: im.width,
          height: im.height,
          path: im.path,
          rotation: im.rotation);

  TableItem _cloneTable(TableItem tb, {double dx = 0, double dy = 0}) =>
      TableItem(
          id: _newId('tb'),
          x: tb.x + dx,
          y: tb.y + dy,
          rows: tb.rows,
          cols: tb.cols,
          cells: List.of(tb.cells),
          cellW: tb.cellW,
          cellH: tb.cellH,
          rotation: tb.rotation);

  /// 删除当前选中的所有个体（不 push undo，由调用方决定）。
  void _deleteSelection() {
    _wb.strokes.removeWhere((s) => _selection.contains(s.id));
    _wb.texts.removeWhere((t) => _selection.contains(t.id));
    _wb.images.removeWhere((im) => _selection.contains(im.id));
    _wb.tables.removeWhere((tb) => _selection.contains(tb.id));
    _selection.clear();
  }

  void _deleteSelected() {
    if (_selection.isEmpty) return;
    _pushUndo();
    _deleteSelection();
    _markDirtyAndSave();
  }

  // ── 选择工具：移动 / 缩放 的几何操作 ───────────────────────────
  // （手势入口统一在「Listener 单指状态机」一节，这里只有几何操作。）

  void _translateSelection(double dx, double dy) {
    if (_moveIds == null) return;
    for (final id in _moveIds!) {
      if (id.startsWith('s')) {
        final idx = _wb.strokes.indexWhere((s) => s.id == id);
        if (idx >= 0) {
          _wb.strokes[idx] = _translatedStroke(_wb.strokes[idx], dx, dy);
        }
      } else if (id.startsWith('t')) {
        final idx = _wb.texts.indexWhere((t) => t.id == id);
        if (idx >= 0) {
          final t = _wb.texts[idx];
          _wb.texts[idx] = TextItem(
              id: t.id,
              x: t.x + dx,
              y: t.y + dy,
              text: t.text,
              fontSize: t.fontSize,
              rotation: t.rotation);
        }
      } else if (id.startsWith('i')) {
        final idx = _wb.images.indexWhere((im) => im.id == id);
        if (idx >= 0) {
          final im = _wb.images[idx];
          _wb.images[idx] = ImageItem(
              id: im.id,
              x: im.x + dx,
              y: im.y + dy,
              width: im.width,
              height: im.height,
              path: im.path,
              rotation: im.rotation);
        }
      } else if (id.startsWith('tb')) {
        final idx = _wb.tables.indexWhere((tb) => tb.id == id);
        if (idx >= 0) {
          final tb = _wb.tables[idx];
          _wb.tables[idx] = TableItem(
              id: tb.id,
              x: tb.x + dx,
              y: tb.y + dy,
              rows: tb.rows,
              cols: tb.cols,
              cells: tb.cells,
              cellW: tb.cellW,
              cellH: tb.cellH,
              rotation: tb.rotation);
        }
      }
    }
    setState(() {});
  }

  void _resizeBy(Offset delta) {
    final id = _resizeId;
    if (id == null || _resizeStartPos == null) return;
    if (id.startsWith('t')) {
      // 文本：缩放 = 改字号。
      final t = _textById(id);
      if (t != null && _resizeOrigFontSize != null) {
        var size = _resizeOrigFontSize! +
            (delta.dx + delta.dy) / 6.0;
        size = size.clamp(8.0, 160.0);
        final idx = _wb.texts.indexWhere((x) => x.id == id);
        if (idx >= 0) {
          _wb.texts[idx] = TextItem(
              id: t.id,
              x: t.x,
              y: t.y,
              text: t.text,
              fontSize: size,
              rotation: t.rotation);
        }
      }
    } else {
      final im = _imageById(id);
      final tb = _tableById(id);
      final w = _resizeOrigW ?? 100;
      final h = _resizeOrigH ?? 60;
      final nw = (w + delta.dx).clamp(40.0, 4000.0);
      final nh = (h + delta.dy).clamp(24.0, 4000.0);
      if (im != null) {
        final idx = _wb.images.indexWhere((x) => x.id == id);
        if (idx >= 0) {
          _wb.images[idx] = ImageItem(
              id: im.id,
              x: im.x,
              y: im.y,
              width: nw,
              height: nh,
              path: im.path,
              rotation: im.rotation);
        }
      } else if (tb != null) {
        // 表格整体缩放 = 同步改单元格尺寸，保持行列数不变。
        final cw = (nw / tb.cols).clamp(28.0, 400.0);
        final ch = (nh / tb.rows).clamp(16.0, 200.0);
        final idx = _wb.tables.indexWhere((x) => x.id == id);
        if (idx >= 0) {
          _wb.tables[idx] = TableItem(
              id: tb.id,
              x: tb.x,
              y: tb.y,
              rows: tb.rows,
              cols: tb.cols,
              cells: tb.cells,
              cellW: cw,
              cellH: ch,
              rotation: tb.rotation);
        }
      }
    }
    setState(() {});
  }

  /// 编辑当前唯一选中的个体：文本 → 编辑框；表格 → 选单元格编辑。
  void _editSelected() {
    if (_selection.length != 1) return;
    final id = _selection.first;
    if (id.startsWith('t')) {
      final t = _textById(id);
      if (t != null) _editText(t);
    } else if (id.startsWith('tb')) {
      final tb = _tableById(id);
      if (tb != null) _pickTableCell(tb);
    }
  }

  /// 弹窗选择表格的某个单元格 → 编辑其文字。
  Future<void> _pickTableCell(TableItem tb) async {
    final picked = await showModalBottomSheet<(int, int)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var r = 0; r < tb.rows; r++)
              for (var c = 0; c < tb.cols; c++)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.grid_on, size: 18),
                  title: Text(
                    tb.cell(r, c).isEmpty
                        ? '第 ${r + 1} 行 · 第 ${c + 1} 列（空）'
                        : '第 ${r + 1} 行 · 第 ${c + 1} 列：${tb.cell(r, c)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(ctx, (r, c)),
                ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _editTableCellAt(tb, picked.$1, picked.$2);
  }

  Future<void> _addTextAt(Offset pos) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('插入文本'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '输入文字…',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('插入')),
        ],
      ),
    );
    if (ok != true || ctrl.text.isEmpty || !mounted) return;
    _pushUndo();
    _wb.texts.add(TextItem(
      id: _newId('t'),
      x: pos.dx,
      y: pos.dy,
      text: ctrl.text,
    ));
    _markDirtyAndSave();
  }

  Future<void> _addImageAt(Offset pos) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.first;
    if (file == null) return;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || !mounted) return;

    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(dir.path, 'whiteboard_images'));
    await imgDir.create(recursive: true);
    final ext = p.extension(file.name).isEmpty
        ? 'png'
        : p.extension(file.name).replaceAll('.', '');
    final dest =
        p.join(imgDir.path, 'img_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await File(dest).writeAsBytes(bytes, flush: true);

    double w = 240, h = 180;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final iw = frame.image.width.toDouble();
      final ih = frame.image.height.toDouble();
      frame.image.dispose();
      const maxDim = 240.0;
      if (iw > ih) {
        w = maxDim;
        h = maxDim * ih / iw;
      } else {
        h = maxDim;
        w = maxDim * iw / ih;
      }
    } catch (e) {
      debugPrint('[Whiteboard] decode image size failed: $e');
    }

    _pushUndo();
    _wb.images.add(ImageItem(
      id: _newId('i'),
      x: pos.dx,
      y: pos.dy,
      width: w,
      height: h,
      path: dest,
    ));
    _markDirtyAndSave();
  }

  Future<void> _addTableAt(Offset pos) async {
    var rows = 3;
    var cols = 3;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('插入表格'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('行数'),
                  Expanded(
                    child: Slider(
                      value: rows.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: '$rows',
                      onChanged: (v) => setLocal(() => rows = v.round()),
                    ),
                  ),
                  Text('$rows'),
                ],
              ),
              Row(
                children: [
                  const Text('列数'),
                  Expanded(
                    child: Slider(
                      value: cols.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: '$cols',
                      onChanged: (v) => setLocal(() => cols = v.round()),
                    ),
                  ),
                  Text('$cols'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('插入')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    _wb.tables.add(TableItem(
      id: _newId('tb'),
      x: pos.dx,
      y: pos.dy,
      rows: rows,
      cols: cols,
      cells: List.filled(rows * cols, ''),
    ));
    _markDirtyAndSave();
  }

  Future<void> _editText(TextItem t) async {
    final ctrl = TextEditingController(text: t.text);
    var size = t.fontSize;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('编辑文本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              ),
              Row(
                children: [
                  const Text('字号'),
                  Expanded(
                    child: Slider(
                      value: size,
                      min: 12,
                      max: 96,
                      onChanged: (v) => setLocal(() => size = v),
                    ),
                  ),
                  Text(size.round().toString()),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx, false);
                _pushUndo();
                _wb.texts.removeWhere((x) => x.id == t.id);
                _markDirtyAndSave();
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    final idx = _wb.texts.indexWhere((x) => x.id == t.id);
    if (idx >= 0) {
      _wb.texts[idx] = TextItem(
        id: t.id,
        x: t.x,
        y: t.y,
        text: ctrl.text,
        fontSize: size,
        rotation: t.rotation,
      );
      _markDirtyAndSave();
    }
  }

  Future<void> _editTableCellAt(TableItem tb, int r, int c) async {
    final ctrl = TextEditingController(text: tb.cell(r, c));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑单元格（第 ${r + 1} 行 · 第 ${c + 1} 列）'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    final idx = _wb.tables.indexWhere((x) => x.id == tb.id);
    if (idx >= 0) {
      final cells = List<String>.from(_wb.tables[idx].cells);
      cells[r * tb.cols + c] = ctrl.text;
      _wb.tables[idx] = TableItem(
        id: tb.id,
        x: tb.x,
        y: tb.y,
        rows: tb.rows,
        cols: tb.cols,
        cells: cells,
        cellW: tb.cellW,
        cellH: tb.cellH,
        rotation: tb.rotation,
      );
      _markDirtyAndSave();
    }
  }

  // ── 表格结构调整：加/删行、加/删列 ────────────────────────────

  void _tableAddRow(String id) {
    final tb = _tableById(id);
    if (tb == null || tb.rows >= 12) return;
    _pushUndo();
    final cells = List<String>.from(tb.cells);
    cells.addAll(List.filled(tb.cols, ''));
    _replaceTable(tb, rows: tb.rows + 1, cells: cells);
  }

  void _tableRemoveRow(String id) {
    final tb = _tableById(id);
    if (tb == null || tb.rows <= 1) return;
    _pushUndo();
    final cells = List<String>.from(tb.cells);
    cells.removeRange((tb.rows - 1) * tb.cols, tb.rows * tb.cols);
    _replaceTable(tb, rows: tb.rows - 1, cells: cells);
  }

  void _tableAddCol(String id) {
    final tb = _tableById(id);
    if (tb == null || tb.cols >= 8) return;
    _pushUndo();
    final cells = <String>[];
    for (var r = 0; r < tb.rows; r++) {
      cells.addAll(tb.cells.sublist(r * tb.cols, (r + 1) * tb.cols));
      cells.add('');
    }
    _replaceTable(tb, cols: tb.cols + 1, cells: cells);
  }

  void _tableRemoveCol(String id) {
    final tb = _tableById(id);
    if (tb == null || tb.cols <= 1) return;
    _pushUndo();
    final cells = <String>[];
    for (var r = 0; r < tb.rows; r++) {
      final row = tb.cells.sublist(r * tb.cols, (r + 1) * tb.cols);
      cells.addAll(row.sublist(0, row.length - 1));
    }
    _replaceTable(tb, cols: tb.cols - 1, cells: cells);
  }

  void _replaceTable(
    TableItem tb, {
    int? rows,
    int? cols,
    List<String>? cells,
  }) {
    final idx = _wb.tables.indexWhere((x) => x.id == tb.id);
    if (idx < 0) return;
    _wb.tables[idx] = TableItem(
      id: tb.id,
      x: tb.x,
      y: tb.y,
      rows: rows ?? tb.rows,
      cols: cols ?? tb.cols,
      cells: cells ?? tb.cells,
      cellW: tb.cellW,
      cellH: tb.cellH,
      rotation: tb.rotation,
    );
    _markDirtyAndSave();
  }

  void _clearAll() async {
    if (_wb.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空画布'),
        content: const Text('确定删除画布上的所有内容吗？此操作可撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    _wb.strokes.clear();
    _wb.texts.clear();
    _wb.images.clear();
    _wb.tables.clear();
    _selection.clear();
    _markDirtyAndSave();
  }

  void _rename() async {
    final ctrl = TextEditingController(text: _wb.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名画布'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    _wb.title = ctrl.text.trim();
    setState(() {});
    _persist();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── 导出 PNG + 保存/分享 ─────────────────────────────────────────

  Future<void> _exportPng() async {
    final bounds = _contentBounds();
    if (bounds == null) {
      _toast('画布是空的，没有可导出的内容');
      return;
    }
    const pad = 80.0;
    var w = (bounds.width + pad * 2).ceil();
    var h = (bounds.height + pad * 2).ceil();
    // 超大画布按比例缩小导出，避免内存爆掉。
    var scale = 1.0;
    const maxDim = 3200;
    if (w > maxDim || h > maxDim) {
      scale = maxDim / (w > h ? w : h);
      w = (w * scale).ceil();
      h = (h * scale).ceil();
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final left = bounds.left - pad;
    final top = bounds.top - pad;
    canvas.scale(scale);
    canvas.translate(-left, -top);

    final painter = _BoardPainter(
      strokes: _wb.strokes,
      bg: const Color(0xFFFBFBF9),
      bgType: _wb.background,
      revision: 0,
    );
    painter.paint(canvas, Size(bounds.width + pad * 2, bounds.height + pad * 2));

    // 文本（带旋转）
    for (final t in _wb.texts) {
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(fontSize: t.fontSize, color: const Color(0xFF1A1A1A)),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      if (t.rotation != 0) {
        canvas.save();
        canvas.translate(t.x + tp.width / 2, t.y + tp.height / 2);
        canvas.rotate(t.rotation);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      } else {
        tp.paint(canvas, Offset(t.x, t.y));
      }
    }

    // 图片
    for (final im in _wb.images) {
      try {
        final bytes = await File(im.path).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        if (im.rotation != 0) {
          canvas.save();
          canvas.translate(im.x + im.width / 2, im.y + im.height / 2);
          canvas.rotate(im.rotation);
          canvas.drawImageRect(
            frame.image,
            Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
                frame.image.height.toDouble()),
            Rect.fromCenter(
                center: Offset.zero, width: im.width, height: im.height),
            Paint()..filterQuality = FilterQuality.medium,
          );
          canvas.restore();
        } else {
          canvas.drawImageRect(
            frame.image,
            Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
                frame.image.height.toDouble()),
            Rect.fromLTWH(im.x, im.y, im.width, im.height),
            Paint()..filterQuality = FilterQuality.medium,
          );
        }
        frame.image.dispose();
      } catch (_) {
        canvas.drawRect(Rect.fromLTWH(im.x, im.y, im.width, im.height),
            Paint()..color = const Color(0xFFE0E0E0));
      }
    }

    // 表格（带旋转）
    for (final tb in _wb.tables) {
      if (tb.rotation != 0) {
        canvas.save();
        canvas.translate(tb.x + tb.cols * tb.cellW / 2,
            tb.y + tb.rows * tb.cellH / 2);
        canvas.rotate(tb.rotation);
      }
      final grid = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF999999);
      for (var r = 0; r < tb.rows; r++) {
        for (var c = 0; c < tb.cols; c++) {
          final rect =
              Rect.fromLTWH(tb.x + c * tb.cellW, tb.y + r * tb.cellH, tb.cellW, tb.cellH);
          canvas.drawRect(rect, Paint()..color = Colors.white);
          canvas.drawRect(rect, grid);
          final tp = TextPainter(
            text: TextSpan(
              text: tb.cell(r, c),
              style: const TextStyle(fontSize: 12, color: Color(0xFF1A1A1A)),
            ),
            textDirection: ui.TextDirection.ltr,
          )..layout(maxWidth: tb.cellW - 8);
          tp.paint(canvas, Offset(rect.left + 4, rect.top + 4));
        }
      }
      if (tb.rotation != 0) canvas.restore();
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(w, h);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (byteData == null) {
      _toast('导出失败');
      return;
    }
    final pngBytes = byteData.buffer.asUint8List();

    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'canvas-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}.png';
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(pngBytes, flush: true);

    if (!mounted) return;
    final export = ref.read(fileExportServiceProvider);
    await export.saveToDownloads(filePath: file.path, fileName: filename);
    try {
      await export.shareFile(filePath: file.path);
    } catch (_) {
      // 桌面端分享面板可能不可用，已存 Downloads 兜底。
    }
    if (mounted) _toast('画布已保存为图片：$filename');
  }

  // ── 构建 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFFE8E8E6),
      appBar: AppBar(
        title: Text(
          _wb.title.isEmpty ? '画布' : _wb.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: '导出为图片（保存+分享）',
            onPressed: _exportPng,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '重命名',
            onPressed: _rename,
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: '撤销',
            onPressed: _undoStack.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: '重做',
            onPressed: _redoStack.isEmpty ? null : _redo,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空画布',
            onPressed: _clearAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCanvas(colors)),
          _buildToolbar(colors),
        ],
      ),
    );
  }

  Widget _buildCanvas(ColorScheme colors) {
    // 选中项 → 旋转后的四角多边形（画选中框）+ 两个手柄位置。
    final selectionPolys = <String, List<Offset>>{};
    final scaleHandles = <String, Offset>{};
    final rotateHandles = <String, Offset>{};
    for (final id in _selection) {
      final corners = _cornersOf(id);
      if (corners.isNotEmpty) {
        selectionPolys[id] = corners;
        final sh = _scaleHandleOf(id);
        final rh = _rotateHandleOf(id);
        if (!id.startsWith('s')) {
          if (sh != null) scaleHandles[id] = sh;
          if (rh != null) rotateHandles[id] = rh;
        }
      }
    }

    final child = SizedBox(
      width: _worldW,
      height: _worldH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BoardPainter(
                strokes: _wb.strokes,
                bg: const Color(0xFFFBFBF9),
                bgType: _wb.background,
                revision: _revision,
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BoardOverlayPainter(
                  currentPoints: _currentPoints,
                  currentBrush: _currentBrush,
                  currentColor: _currentColor,
                  currentWidth: _currentWidth,
                  eraserPos: _eraserPos,
                  accent: colors.primary,
                  lasso: _lasso,
                  selectionPolys: selectionPolys,
                  scaleHandles: scaleHandles,
                  rotateHandles: rotateHandles,
                  viewScale: _viewScale,
                ),
              ),
            ),
          ),
          ..._wb.texts.map((t) => Positioned(
                left: t.x,
                top: t.y,
                child: IgnorePointer(
                  child: Transform.rotate(
                    angle: t.rotation,
                    child: Text(
                      t.text,
                      style: TextStyle(
                        fontSize: t.fontSize,
                        color: const Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                ),
              )),
          ..._wb.images.map((im) => Positioned(
                left: im.x,
                top: im.y,
                child: IgnorePointer(
                  child: Transform.rotate(
                    angle: im.rotation,
                    child: Image.file(
                      File(im.path),
                      width: im.width,
                      height: im.height,
                      fit: BoxFit.fill,
                      errorBuilder: (_, __, ___) => Container(
                        width: im.width,
                        height: im.height,
                        color: colors.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                ),
              )),
          ..._wb.tables.map((tb) => Positioned(
                left: tb.x,
                top: tb.y,
                child: IgnorePointer(
                  child: Transform.rotate(
                    angle: tb.rotation,
                    child: _TableWidget(item: tb),
                  ),
                ),
              )),
        ],
      ),
    );

    // 手势层在 InteractiveViewer 之外、以整个视口为单位接收事件，
    // 再把视图坐标换算回世界坐标 —— 画布边缘外的缩放手柄、缩到很小时
    // 的画布外区域，全都抓得到。
    //
    // Listener 收原始指针事件：单指（绘制/移动/缩放/旋转/平移/点击）全部
    // 由自研状态机处理，不参与手势竞技场——画笔零延迟、单指拖空白平移、
    // 单击选中；GestureDetector 只挂双指 scale（pointerCount ≥ 2 才生效）。
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ClipRect(
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: false,
                boundaryMargin: EdgeInsets.zero,
                minScale: 0.1,
                maxScale: 12,
                panEnabled: false,
                scaleEnabled: false,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  // ── 底部工具栏 ───────────────────────────────────────────────────

  Widget _buildToolbar(ColorScheme colors) {
    final showBrush = _tool == _Tool.pen || _tool == _Tool.ruler;
    final hasClipboard = _clipboard != null && !_clipboard!.isEmpty;
    final hasSelection = _selection.isNotEmpty;

    return Material(
      color: colors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    _toolBtn(_Tool.select, Icons.pan_tool_alt, '选择', colors),
                    _toolBtn(_Tool.pen, Icons.brush, '画笔', colors),
                    _toolBtn(_Tool.eraser, Icons.auto_fix_normal, '橡皮', colors),
                    _toolBtn(_Tool.ruler, Icons.straighten, '尺子', colors),
                    _toolBtn(_Tool.lasso, Icons.gesture, '套索', colors),
                    _toolBtn(_Tool.text, Icons.title, '文本', colors),
                    _toolBtn(_Tool.image, Icons.image_outlined, '图片', colors),
                    _toolBtn(_Tool.table, Icons.table_chart_outlined, '表格', colors),
                    if (hasClipboard)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ActionChip(
                          avatar: const Icon(Icons.content_paste, size: 16),
                          label: const Text('粘贴'),
                          onPressed: _pasteClipboard,
                        ),
                      ),
                  ],
                ),
              ),
              if (showBrush) ...[
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final (b, label, icon) in _brushes) ...[
                        ChoiceChip(
                          avatar: Icon(icon, size: 16),
                          label: Text(label, style: const TextStyle(fontSize: 12)),
                          selected: _brush == b,
                          onSelected: (_) => setState(() => _brush = b),
                          visualDensity: VisualDensity.compact,
                          selectedColor: colors.primaryContainer,
                        ),
                        const SizedBox(width: 6),
                      ],
                      const SizedBox(width: 8),
                      const VerticalDivider(width: 1),
                      const SizedBox(width: 8),
                      // 画笔粗细调节。
                      const Text('粗细', style: TextStyle(fontSize: 12)),
                      SizedBox(
                        width: 130,
                        child: Slider(
                          value: _penWidth,
                          min: 1,
                          max: 24,
                          onChanged: (v) => setState(() => _penWidth = v),
                        ),
                      ),
                      Text(_penWidth.toStringAsFixed(1),
                          style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 10),
                      const VerticalDivider(width: 1),
                      const SizedBox(width: 8),
                      for (final c in _palette)
                        GestureDetector(
                          onTap: () => setState(() => _color = c),
                          child: Container(
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == c
                                    ? colors.primary
                                    : colors.outline.withValues(alpha: 0.4),
                                width: _color == c ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_tool == _Tool.select) ...[
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const Text('背景', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        avatar: const Icon(Icons.check_box_outline_blank,
                            size: 16),
                        label: const Text('空白', style: TextStyle(fontSize: 12)),
                        selected: _wb.background == 'blank',
                        onSelected: (_) => _setBackground('blank'),
                        visualDensity: VisualDensity.compact,
                        selectedColor: colors.primaryContainer,
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        avatar: const Icon(Icons.menu, size: 16),
                        label: const Text('横线', style: TextStyle(fontSize: 12)),
                        selected: _wb.background == 'lines',
                        onSelected: (_) => _setBackground('lines'),
                        visualDensity: VisualDensity.compact,
                        selectedColor: colors.primaryContainer,
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        avatar: const Icon(Icons.blur_on, size: 16),
                        label: const Text('点点', style: TextStyle(fontSize: 12)),
                        selected: _wb.background == 'dots',
                        onSelected: (_) => _setBackground('dots'),
                        visualDensity: VisualDensity.compact,
                        selectedColor: colors.primaryContainer,
                      ),
                      if (hasSelection) ...[
                        const SizedBox(width: 12),
                        const VerticalDivider(width: 1),
                        const SizedBox(width: 8),
                        Text('已选 ${_selection.length} 个',
                            style: const TextStyle(fontSize: 11)),
                        const SizedBox(width: 8),
                        if (_selection.length == 1 &&
                            !_selection.first.startsWith('s') &&
                            !_selection.first.startsWith('i'))
                          TextButton.icon(
                            onPressed: _editSelected,
                            icon: const Icon(Icons.edit, size: 16),
                            label: const Text('编辑'),
                          ),
                        // 选中单个表格时提供行列调整（用户要求的「大型功能」）。
                        if (_selection.length == 1 &&
                            _selection.first.startsWith('tb')) ...[
                          const SizedBox(width: 4),
                          TextButton(
                            onPressed: () => _tableAddRow(_selection.first),
                            child: const Text('＋行',
                                style: TextStyle(fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: () => _tableRemoveRow(_selection.first),
                            child: const Text('－行',
                                style: TextStyle(fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: () => _tableAddCol(_selection.first),
                            child: const Text('＋列',
                                style: TextStyle(fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: () => _tableRemoveCol(_selection.first),
                            child: const Text('－列',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        TextButton.icon(
                          onPressed: _deleteSelected,
                          icon: const Icon(Icons.delete, size: 16),
                          label: const Text('删除'),
                        ),
                        TextButton.icon(
                          onPressed: () => _copySelection(),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制'),
                        ),
                        TextButton.icon(
                          onPressed: () => _copySelection(cut: true),
                          icon: const Icon(Icons.content_cut, size: 16),
                          label: const Text('剪切'),
                        ),
                      ] else
                        const Padding(
                          padding: EdgeInsets.only(left: 12),
                          child: Text(
                            '单指点选/拖动=选中移动 · 单指拖空白=平移 · 双指=平移缩放 · 点已选文本/表格=编辑 · 右下圆点=缩放 · 顶部圆点=旋转',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_tool == _Tool.lasso && hasSelection) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('套住 ${_selection.length} 个对象',
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(width: 12),
                    TextButton.icon(
                        onPressed: () => _copySelection(),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制')),
                    TextButton.icon(
                        onPressed: () => _copySelection(cut: true),
                        icon: const Icon(Icons.content_cut, size: 16),
                        label: const Text('剪切')),
                    TextButton.icon(
                        onPressed: _deleteSelected,
                        icon: const Icon(Icons.delete, size: 16),
                        label: const Text('删除')),
                    TextButton(
                        onPressed: () => setState(() => _selection.clear()),
                        child: const Text('取消选择')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _setBackground(String type) {
    setState(() => _wb.background = type);
    _persist();
  }

  /// 工具栏里的迷你图标按钮（表格行列调整用）。
  Widget _toolBtn(_Tool tool, IconData icon, String label, ColorScheme colors) {
    final selected = _tool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: () => setState(() => _tool = tool),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? colors.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? colors.primary : colors.onSurface),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      color: selected ? colors.primary : colors.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 画布画笔 ────────────────────────────────────────────────────────────
// 拆成两层 CustomPaint：
//   · _BoardPainter（静态层）：背景 + 全部笔迹，revision 版本号控制重绘——
//     平移/选择/拖动对象等操作不再重绘几百条笔迹（修「笔迹一多就掉帧」）。
//   · _BoardOverlayPainter（动态层）：当前预览笔迹/选中框/手柄/套索/橡皮圈，
//     元素少，每帧重绘便宜。

/// 笔迹绘制工具（两个 painter 共用）。
Path _strokePath(List<WhiteboardPoint> pts) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts[0].x, pts[0].y);
  if (pts.length == 1) {
    path.lineTo(pts[0].x + 0.1, pts[0].y);
    return path;
  }
  for (var i = 1; i < pts.length - 1; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    path.quadraticBezierTo(a.x, a.y, (a.x + b.x) / 2, (a.y + b.y) / 2);
  }
  path.lineTo(pts.last.x, pts.last.y);
  return path;
}

Paint _strokePaint(InkStroke s) {
  final w = s.width ?? (_brushWidth[s.brush] ?? 3.5);
  final o = _brushOpacity[s.brush] ?? 1.0;
  return Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = w
    ..color = Color(s.color).withValues(alpha: o);
}

/// 静态层：背景 + 笔迹。只有 revision / 背景类型变化才重绘。
class _BoardPainter extends CustomPainter {
  final List<InkStroke> strokes;
  final Color bg;
  final String bgType;
  final int revision;

  _BoardPainter({
    required this.strokes,
    required this.bg,
    required this.bgType,
    required this.revision,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    _paintBackgroundPattern(canvas, size);
    for (final s in strokes) {
      canvas.drawPath(_strokePath(s.points), _strokePaint(s));
    }
  }

  /// 背景：横线 / 点点（空白不画）。
  void _paintBackgroundPattern(Canvas canvas, Size size) {
    const step = 36.0;
    const faint = Color(0xFFDCDCD8);
    switch (bgType) {
      case 'lines':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = faint;
        for (var y = step; y < size.height; y += step) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'dots':
        final pts = <Offset>[];
        for (var y = step; y < size.height; y += step) {
          for (var x = step; x < size.width; x += step) {
            pts.add(Offset(x, y));
          }
        }
        if (pts.isNotEmpty) {
          canvas.drawPoints(
            ui.PointMode.points,
            pts,
            Paint()
              ..strokeWidth = 1.6
              ..strokeCap = StrokeCap.round
              ..color = faint,
          );
        }
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.revision != revision ||
      old.bgType != bgType ||
      old.strokes != strokes;
}

/// 动态层：预览笔迹 / 选中框 / 手柄 / 套索 / 橡皮圈。每帧重绘（元素少）。
class _BoardOverlayPainter extends CustomPainter {
  final List<WhiteboardPoint> currentPoints;
  final BrushType currentBrush;
  final int currentColor;
  final double currentWidth;
  final Offset? eraserPos;
  final Color accent;
  final List<Offset> lasso;
  final Map<String, List<Offset>> selectionPolys;
  final Map<String, Offset> scaleHandles;
  final Map<String, Offset> rotateHandles;
  final double viewScale;

  _BoardOverlayPainter({
    required this.currentPoints,
    required this.currentBrush,
    required this.currentColor,
    required this.currentWidth,
    required this.eraserPos,
    required this.accent,
    required this.lasso,
    required this.selectionPolys,
    required this.scaleHandles,
    required this.rotateHandles,
    required this.viewScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 实时预览笔迹。
    if (currentPoints.isNotEmpty) {
      final preview = InkStroke(
          id: '',
          color: currentColor,
          brush: currentBrush,
          width: currentWidth,
          points: currentPoints);
      canvas.drawPath(_strokePath(currentPoints), _strokePaint(preview));
    }

    // 选中框（旋转后的多边形）+ 缩放手柄（右下圆点）+ 旋转手柄（顶部圆点）。
    // 线宽/手柄尺寸按 viewScale 反算，屏幕上是恒定大小。
    final vs = viewScale <= 0.05 ? 0.05 : viewScale;
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / vs
      ..color = accent.withValues(alpha: 0.9);
    final handleRadius = 7 / vs;
    selectionPolys.forEach((id, corners) {
      final path = Path()..moveTo(corners.first.dx, corners.first.dy);
      for (final c in corners.skip(1)) {
        path.lineTo(c.dx, c.dy);
      }
      path.close();
      canvas.drawPath(path, boxPaint);
    });

    void drawHandle(Offset at, Color fill) {
      canvas.drawCircle(at, handleRadius, Paint()..color = fill);
      canvas.drawCircle(
        at,
        handleRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / vs
          ..color = Colors.white,
      );
    }

    scaleHandles.forEach((id, at) => drawHandle(at, accent));
    rotateHandles.forEach((id, at) => drawHandle(at, const Color(0xFF43A047)));

    // 套索路径（自由不规则）。
    if (lasso.isNotEmpty) {
      final lp = Path()..moveTo(lasso.first.dx, lasso.first.dy);
      for (final o in lasso.skip(1)) {
        lp.lineTo(o.dx, o.dy);
      }
      lp.close();
      canvas.drawPath(lp, Paint()..color = accent.withValues(alpha: 0.12));
      canvas.drawPath(
        lp,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = accent,
      );
    }

    // 橡皮提示圈（屏幕恒定 16px，与擦除判定一致）。
    if (eraserPos != null) {
      canvas.drawCircle(
        eraserPos!,
        16 / vs,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(_BoardOverlayPainter old) => true;
}

// ── 表格控件 ────────────────────────────────────────────────────────────

class _TableWidget extends StatelessWidget {
  final TableItem item;
  const _TableWidget({required this.item});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        border: Border.all(color: colors.outline, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < item.rows; r++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var c = 0; c < item.cols; c++)
                  Container(
                    width: item.cellW,
                    height: item.cellH,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(
                            color: c < item.cols - 1
                                ? colors.outline
                                : Colors.transparent,
                            width: 0.5),
                        bottom: BorderSide(
                            color: r < item.rows - 1
                                ? colors.outline
                                : Colors.transparent,
                            width: 0.5),
                      ),
                    ),
                    child: Text(
                      item.cell(r, c),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
