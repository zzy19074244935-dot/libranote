import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../providers/app_providers.dart';
import '../services/shot_actions.dart';
import '../services/storage_service.dart';

/// xournalpp 式多页手写笔记本（移植自 xournalpp 的功能与外观）。
///
/// 核心模型：文档 = 多页（固定尺寸 pt，默认 A4），每页 = 背景（plain/ruled/
/// lined/graph/dotted）+ 多层（元素：笔迹/文本/图片/表格）。
///
/// 交互（移植 xournalpp + 移动端适配）：
///   · 画笔/荧光笔/橡皮工具：单指绘制（支持触控笔压感，逐点线宽）
///   · 选择工具：点选/拖动移动/右下圆点缩放/顶部圆点旋转
///   · 单指拖空白/双指：平移+缩放（0.3~7 倍，xournalpp 范围）
///   · 页导航：底部 ‹ 页码 › + 新增页/删除页
class XournalppBoardScreen extends ConsumerStatefulWidget {
  final Whiteboard? board;

  const XournalppBoardScreen({super.key, this.board});

  @override
  ConsumerState<XournalppBoardScreen> createState() =>
      _XournalppBoardScreenState();
}

/// 单指拖动模式。
enum _DragMode { none, draw, move, resize, rotate, pan }

class _XournalppBoardScreenState extends ConsumerState<XournalppBoardScreen>
    with WidgetsBindingObserver {
  late final Whiteboard _wb;

  /// initState 抓一次 storage：dispose 兜底写库不再依赖 ref。
  late final StorageService _storage;

  /// 多页文档（工作数据）。
  late List<BoardPage> _pages;
  int _currentPage = 0;

  // ── 工具状态（xournalpp 语义） ────────────────────────────────────
  _Tool _tool = _Tool.pen;
  BrushType _brush = BrushType.pen; // pen/marker(荧光笔)
  int _color = 0xFF3333CC; // xournalpp royalblue
  double _penWidth = 1.41; // MEDIUM 档（xournalpp Pen 第三档）
  int _eraserMode = 0; // 0=标准切段 1=白覆盖 2=整条删除

  final TransformationController _transform = TransformationController();

  // 撤销/重做。
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  // 绘制中。
  List<WhiteboardPoint> _currentPoints = [];
  BrushType _currentBrush = BrushType.pen;
  int _currentColor = 0xFF000000;
  double _currentWidth = 3.5;
  int _revision = 0;

  // 选择。
  final Set<String> _selection = {};
  Set<String>? _moveIds;
  bool _moved = false;
  String? _resizeId;
  Offset? _resizeStartPos;
  double? _resizeOrigW;
  double? _resizeOrigH;
  double? _resizeOrigFontSize;
  String? _rotateId;

  // 手势状态机（Listener 单指 + GestureDetector 双指）。
  final Map<int, Offset> _pointers = {};
  int _activePointer = -1;
  Offset? _downPos;
  Offset? _lastWorldPos;
  Offset? _lastViewPos;
  _DragMode _downMode = _DragMode.none;
  _DragMode _activeMode = _DragMode.none;
  bool _pinchStarted = false;
  double _scaleAccum = 1.0;
  Offset _lastFocal = Offset.zero;

  /// 最近一次指针压力（触控笔 0~1；鼠标/触摸恒 1.0）。
  double _lastPressure = 1.0;

  Size _viewportSize = Size.zero;
  Timer? _saveTimer;
  int _counter = 0;
  String _newId(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch}${_counter++}';

  // ── 页面几何 ───────────────────────────────────────────────────────

  static const double _pageGap = 40; // 页面之间的世界坐标间距

  double _pageOffset(int index) {
    var y = 0.0;
    for (var i = 0; i < index; i++) {
      y += _pages[i].height + _pageGap;
    }
    return y;
  }

  double get _totalHeight {
    var h = 0.0;
    for (final page in _pages) {
      h += page.height + _pageGap;
    }
    return h;
  }

  double get _totalWidth =>
      _pages.fold(0.0, (w, page) => math.max(w, page.width)) + 400;

  /// 世界坐标 → (页 index, 页内坐标)；不在任何页上返回 null。
  (int, Offset)? _locatePage(Offset world) {
    for (var i = 0; i < _pages.length; i++) {
      final top = _pageOffset(i);
      final page = _pages[i];
      if (world.dy >= top - _pageGap / 2 &&
          world.dy < top + page.height + _pageGap / 2) {
        return (i, Offset(world.dx, world.dy - top));
      }
    }
    return null;
  }

  Offset _toWorld(Offset p) => _transform.toScene(p);

  double get _viewScale {
    final s = _transform.value.getMaxScaleOnAxis();
    return s <= 0.01 ? 0.01 : s;
  }

  // ── 工作层访问 ─────────────────────────────────────────────────────

  /// 当前图层（xournalpp currentLayer 语义，绘制/橡皮只写它）。
  int _currentLayer = 0;

  BoardLayer get _activeLayer =>
      _pages[_currentPage].layers[_currentLayer];

  void _replacePage(int index, BoardPage page) {
    _pages[index] = page;
  }

  void _replaceLayer(int pageIndex, int layerIndex, BoardLayer layer) {
    final page = _pages[pageIndex];
    final layers = List<BoardLayer>.from(page.layers);
    layers[layerIndex] = layer;
    _replacePage(pageIndex, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: layers,
    ));
  }

  // ── 生命周期 ───────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _storage = ref.read(storageServiceProvider);
    _wb = Whiteboard(
      id: widget.board?.id,
      title: widget.board?.title ?? '',
      createdAt: widget.board?.createdAt,
    );
    _wb.loadContent(widget.board?.contentJson);
    _pages = _initPages();
    if (_wb.title.isEmpty && widget.board == null) {
      _wb.title = '笔记本 ${DateFormat('MM-dd HH:mm').format(DateTime.now())}';
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _centerFirstPage();
      setState(() {});
    });
  }

  /// v1（单画布）→ v2（多页）迁移：旧内容包成一页。
  List<BoardPage> _initPages() {
    if (_wb.pages.isNotEmpty) return List.of(_wb.pages);
    final hasContent = _wb.strokes.isNotEmpty ||
        _wb.texts.isNotEmpty ||
        _wb.images.isNotEmpty ||
        _wb.tables.isNotEmpty;
    if (!hasContent) {
      return [BoardPage.a4(bgType: _mapLegacyBg(_wb.background))];
    }
    // 旧内容 → 单页（尺寸取内容包围盒 + 页边，至少 A4）。
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void add(double x, double y) {
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }

    for (final s in _wb.strokes) {
      for (final pt in s.points) {
        add(pt.x, pt.y);
      }
    }
    for (final t in _wb.texts) {
      add(t.x, t.y);
      add(t.x + t.text.length * t.fontSize * 0.55, t.y + t.fontSize * 1.6);
    }
    for (final im in _wb.images) {
      add(im.x, im.y);
      add(im.x + im.width, im.y + im.height);
    }
    for (final tb in _wb.tables) {
      add(tb.x, tb.y);
      add(tb.x + tb.cols * tb.cellW, tb.y + tb.rows * tb.cellH);
    }
    final width = math.max(595.28, maxX - minX + 200);
    final height = math.max(841.89, maxY - minY + 200);
    final dx = 100 - minX;
    final dy = 100 - minY;
    final layer = BoardLayer(
      name: '图层 1',
      strokes: _wb.strokes
          .map((s) => InkStroke(
                id: s.id,
                color: s.color,
                brush: s.brush,
                width: s.width,
                points: s.points
                    .map((pt) => WhiteboardPoint(
                        x: pt.x + dx, y: pt.y + dy, pressure: pt.pressure))
                    .toList(),
              ))
          .toList(),
      texts: _wb.texts
          .map((t) => TextItem(
              id: t.id,
              x: t.x + dx,
              y: t.y + dy,
              text: t.text,
              fontSize: t.fontSize,
              rotation: t.rotation))
          .toList(),
      images: _wb.images
          .map((im) => ImageItem(
              id: im.id,
              x: im.x + dx,
              y: im.y + dy,
              width: im.width,
              height: im.height,
              path: im.path,
              rotation: im.rotation))
          .toList(),
      tables: _wb.tables
          .map((tb) => TableItem(
              id: tb.id,
              x: tb.x + dx,
              y: tb.y + dy,
              rows: tb.rows,
              cols: tb.cols,
              cells: tb.cells,
              cellW: tb.cellW,
              cellH: tb.cellH,
              rotation: tb.rotation))
          .toList(),
    );
    return [
      BoardPage(
        width: width,
        height: height,
        bgType: _mapLegacyBg(_wb.background),
        layers: [layer],
      ),
    ];
  }

  static String _mapLegacyBg(String legacy) => switch (legacy) {
        'lines' => 'ruled',
        'dots' => 'dotted',
        _ => 'plain',
      };

  void _centerFirstPage() {
    if (_viewportSize == Size.zero || _pages.isEmpty) return;
    final page = _pages.first;
    final dx = (_viewportSize.width - page.width) / 2;
    final dy = (_viewportSize.height - page.height) / 2;
    if (dx > 0 || dy > 0) {
      _panBy(Offset(dx, dy));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _persist();
    _transform.dispose();
    super.dispose();
  }

  /// App 切后台时立刻落盘（杀进程不丢最后一笔）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _persist();
    }
  }

  // ── 持久化 ─────────────────────────────────────────────────────────

  Future<void> _persist() async {
    try {
      _wb.pages = List.of(_pages);
      if (_wb.id == null) {
        _wb.id = await _storage.insertWhiteboard(_wb);
      } else {
        await _storage.updateWhiteboard(_wb);
      }
    } catch (e) {
      debugPrint('[Xournal] persist failed: $e');
    }
  }

  void _markDirtyAndSave() {
    if (!mounted) return;
    _revision++;
    setState(() {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _persist);
  }

  // ── 撤销/重做 ──────────────────────────────────────────────────────

  void _pushUndo() {
    _wb.pages = List.of(_pages);
    _undoStack.add(_wb.contentJson);
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _wb.pages = List.of(_pages);
    _redoStack.add(_wb.contentJson);
    _wb.loadContent(_undoStack.removeLast());
    _pages = List.of(_wb.pages);
    _currentPage = _currentPage.clamp(0, _pages.length - 1);
    _selection.clear();
    _currentPoints = [];
    _revision++;
    setState(() {});
    _persist();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _wb.pages = List.of(_pages);
    _undoStack.add(_wb.contentJson);
    _wb.loadContent(_redoStack.removeLast());
    _pages = List.of(_wb.pages);
    _currentPage = _currentPage.clamp(0, _pages.length - 1);
    _selection.clear();
    _currentPoints = [];
    _revision++;
    setState(() {});
    _persist();
  }

  // ── 页面操作 ───────────────────────────────────────────────────────

  void _addPage() {
    _pushUndo();
    _pages.add(BoardPage.a4());
    _currentPage = _pages.length - 1;
    _markDirtyAndSave();
  }

  void _deletePage() {
    if (_pages.length <= 1) {
      _toast('至少保留一页');
      return;
    }
    _pushUndo();
    _pages.removeAt(_currentPage);
    _currentPage = _currentPage.clamp(0, _pages.length - 1);
    _markDirtyAndSave();
  }

  void _setPageBackground(String bgType) {
    _pushUndo();
    final page = _pages[_currentPage];
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: bgType,
      bgColor: page.bgColor,
      layers: page.layers,
    ));
    _markDirtyAndSave();
  }

  // ── 图层操作 ───────────────────────────────────────────────────────

  void _addLayer() {
    _pushUndo();
    final page = _pages[_currentPage];
    final layers = List<BoardLayer>.from(page.layers)
      ..add(BoardLayer(name: '图层 ${page.layers.length + 1}'));
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: layers,
    ));
    _currentLayer = layers.length - 1;
    _markDirtyAndSave();
  }

  void _removeLayer(int index) {
    if (_pages[_currentPage].layers.length <= 1) {
      _toast('至少保留一个图层');
      return;
    }
    _pushUndo();
    final page = _pages[_currentPage];
    final layers = List<BoardLayer>.from(page.layers)..removeAt(index);
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: layers,
    ));
    _currentLayer = _currentLayer.clamp(0, layers.length - 1);
    _markDirtyAndSave();
  }

  void _toggleLayerVisible(int index) {
    _pushUndo();
    final page = _pages[_currentPage];
    final layers = List<BoardLayer>.from(page.layers);
    layers[index] = layers[index].copyWith(visible: !layers[index].visible);
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: layers,
    ));
    _markDirtyAndSave();
  }

  void _moveLayer(int index, int delta) {
    final target = index + delta;
    final layers = _pages[_currentPage].layers;
    if (target < 0 || target >= layers.length) return;
    _pushUndo();
    final page = _pages[_currentPage];
    final list = List<BoardLayer>.from(page.layers);
    final item = list.removeAt(index);
    list.insert(target, item);
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: list,
    ));
    if (_currentLayer == index) {
      _currentLayer = target;
    } else if (_currentLayer == target) {
      _currentLayer = index;
    }
    _markDirtyAndSave();
  }

  Future<void> _renameLayer(int index) async {
    final layer = _pages[_currentPage].layers[index];
    final ctrl = TextEditingController(text: layer.name ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名图层'),
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
    if (ok != true || !mounted) return;
    _pushUndo();
    final page = _pages[_currentPage];
    final layers = List<BoardLayer>.from(page.layers);
    layers[index] = layers[index].copyWith(name: ctrl.text.trim());
    _replacePage(_currentPage, BoardPage(
      width: page.width,
      height: page.height,
      bgType: page.bgType,
      bgColor: page.bgColor,
      layers: layers,
    ));
    _markDirtyAndSave();
  }

  void _showLayersSheet() {
    final page = _pages[_currentPage];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Text('图层（第 ${_currentPage + 1} 页）',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: '新增图层',
                      onPressed: () {
                        _addLayer();
                        setLocal(() {});
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 倒序显示：顶层在列表顶部（xournalpp SidebarPreviewLayers）。
              for (var i = page.layers.length - 1; i >= 0; i--)
                ListTile(
                  dense: true,
                  selected: i == _currentLayer,
                  leading: Icon(
                    page.layers[i].visible
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                    color: page.layers[i].visible ? null : Colors.grey,
                  ),
                  title: Text(
                    page.layers[i].name ?? '图层 ${i + 1}',
                    style: TextStyle(
                        fontWeight: i == _currentLayer
                            ? FontWeight.w700
                            : FontWeight.w400),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        tooltip: '上移',
                        onPressed: () {
                          _moveLayer(i, 1);
                          setLocal(() {});
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward, size: 18),
                        tooltip: '下移',
                        onPressed: () {
                          _moveLayer(i, -1);
                          setLocal(() {});
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '重命名',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _renameLayer(i);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: '删除',
                        onPressed: () {
                          _removeLayer(i);
                          setLocal(() {});
                        },
                      ),
                    ],
                  ),
                  onTap: () {
                    setState(() => _currentLayer = i);
                    Navigator.pop(ctx);
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility_outlined, size: 20),
                      tooltip: '显示/隐藏当前图层',
                      onPressed: () {
                        _toggleLayerVisible(_currentLayer);
                        setLocal(() {});
                      },
                    ),
                    const Text('点眼睛图标或行切换图层；绘制与橡皮只作用于当前图层',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 工具 ───────────────────────────────────────────────────────────

  bool get _drawDrag =>
      _tool == _Tool.pen || _tool == _Tool.eraser || _tool == _Tool.lasso;

  /// 套索路径（页内坐标）。
  final List<Offset> _lasso = [];

  // ── 命中检测（当前页、页内坐标） ──────────────────────────────────

  Rect _strokeBounds(InkStroke s) {
    if (s.points.isEmpty) return Rect.zero;
    var minX = s.points.first.x, minY = s.points.first.y;
    var maxX = minX, maxY = minY;
    for (final pt in s.points) {
      minX = math.min(minX, pt.x);
      minY = math.min(minY, pt.y);
      maxX = math.max(maxX, pt.x);
      maxY = math.max(maxY, pt.y);
    }
    final w = (s.width ?? (_brushWidth[s.brush] ?? 3.5)) + 10;
    return Rect.fromLTRB(minX - w, minY - w, maxX + w, maxY + w);
  }

  Rect _textRect(TextItem t) {
    final w = (t.text.length * t.fontSize * 0.55).clamp(24.0, 900.0);
    return Rect.fromLTWH(t.x, t.y, w, t.fontSize * 1.6);
  }

  Rect _imageRect(ImageItem im) => Rect.fromLTWH(im.x, im.y, im.width, im.height);

  Rect _tableRect(TableItem tb) =>
      Rect.fromLTWH(tb.x, tb.y, tb.cols * tb.cellW, tb.rows * tb.cellH);

  InkStroke? _strokeById(String id) {
    for (final l in _pages[_currentPage].layers) {
      for (final s in l.strokes) {
        if (s.id == id) return s;
      }
    }
    return null;
  }

  TextItem? _textById(String id) {
    for (final l in _pages[_currentPage].layers) {
      for (final t in l.texts) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  ImageItem? _imageById(String id) {
    for (final l in _pages[_currentPage].layers) {
      for (final im in l.images) {
        if (im.id == id) return im;
      }
    }
    return null;
  }

  TableItem? _tableById(String id) {
    for (final l in _pages[_currentPage].layers) {
      for (final tb in l.tables) {
        if (tb.id == id) return tb;
      }
    }
    return null;
  }

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

  double _rotationOf(String id) {
    if (id.startsWith('t')) return _textById(id)?.rotation ?? 0;
    if (id.startsWith('i')) return _imageById(id)?.rotation ?? 0;
    if (id.startsWith('tb')) return _tableById(id)?.rotation ?? 0;
    return 0;
  }

  Offset? _centerOf(String id) {
    final r = _rectById(id);
    return r?.center;
  }

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

  /// 命中（页内坐标）：后画的在上层——表格→图片→文本→笔迹。
  String? _hitObject(int pageIndex, Offset pos) {
    final layers = _pages[pageIndex].layers.reversed.toList();
    for (final layer in layers) {
      if (!layer.visible) continue;
      for (final tb in layer.tables.reversed) {
        if (tb.rotation == 0
            ? _tableRect(tb).contains(pos)
            : _pointInPolygon(pos, _cornersOf(tb.id))) {
          return tb.id;
        }
      }
      for (final im in layer.images.reversed) {
        if (im.rotation == 0
            ? _imageRect(im).contains(pos)
            : _pointInPolygon(pos, _cornersOf(im.id))) {
          return im.id;
        }
      }
      for (final t in layer.texts.reversed) {
        if (t.rotation == 0
            ? _textRect(t).contains(pos)
            : _pointInPolygon(pos, _cornersOf(t.id))) {
          return t.id;
        }
      }
      for (final s in layer.strokes.reversed) {
        if (_strokeBounds(s).contains(pos)) return s.id;
      }
    }
    return null;
  }

  String? _hitResizeHandle(Offset pos) {
    final radius = 26 / _viewScale;
    for (final id in _selection) {
      if (id.startsWith('s')) continue;
      final handle = _scaleHandleOf(id);
      if (handle != null && (pos - handle).distance < radius) return id;
    }
    return null;
  }

  String? _hitRotateHandle(Offset pos) {
    final radius = 26 / _viewScale;
    for (final id in _selection) {
      if (id.startsWith('s')) continue;
      final handle = _rotateHandleOf(id);
      if (handle != null && (pos - handle).distance < radius) return id;
    }
    return null;
  }

  // ── 单指手势状态机（Listener，不参与识别器竞技场） ───────────────

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _lastPressure = e.pressure > 0 ? e.pressure : 1.0;
    if (_pointers.length >= 2) {
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

  _DragMode _resolveDownMode(Offset world) {
    if (_drawDrag) return _DragMode.draw;
    if (_tool != _Tool.select) return _DragMode.none;
    final located = _locatePage(world);
    if (located == null) return _DragMode.pan;
    if (_currentPage != located.$1) {
      _currentPage = located.$1;
      setState(() {});
    }
    final pos = located.$2;
    if (_hitResizeHandle(pos) != null) return _DragMode.resize;
    if (_hitRotateHandle(pos) != null) return _DragMode.rotate;
    if (_hitObject(_currentPage, pos) != null) return _DragMode.move;
    return _DragMode.pan;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (e.pressure > 0) _lastPressure = e.pressure;
    if (_pointers.length >= 2 || e.pointer != _activePointer) return;
    final world = _toWorld(e.localPosition);

    if (_activeMode == _DragMode.none) {
      final dist = (world - _downPos!).distance * _viewScale;
      if (dist < 6) return;
      _activateGesture(_downPos!);
      if (_activeMode == _DragMode.none) return;
    }

    switch (_activeMode) {
      case _DragMode.draw:
        _drawUpdate(world);
      case _DragMode.move:
        final dx = world.dx - _lastWorldPos!.dx;
        final dy = world.dy - _lastWorldPos!.dy;
        if (dx != 0 || dy != 0) {
          if (!_moved) {
            _pushUndo();
            _moved = true;
          }
          _translateSelection(dx, dy);
        }
        _lastWorldPos = world;
      case _DragMode.resize:
        _resizeBy(Offset(
            world.dx - _lastWorldPos!.dx, world.dy - _lastWorldPos!.dy));
        _lastWorldPos = world;
      case _DragMode.rotate:
        _rotateBy(world);
      case _DragMode.pan:
        _panBy(e.localPosition - _lastViewPos!);
        _lastViewPos = e.localPosition;
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

  void _onPointerCancel(PointerCancelEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers.remove(e.pointer);
    if (e.pointer != _activePointer) return;
    _activePointer = -1;
    _cancelActiveGesture();
    _downMode = _DragMode.none;
    _downPos = null;
  }

  void _activateGesture(Offset world) {
    switch (_downMode) {
      case _DragMode.draw:
        _drawStart(world);
      case _DragMode.move:
        _beginMove(world);
      case _DragMode.resize:
        _beginResize(world);
      case _DragMode.rotate:
        _beginRotate(world);
      case _DragMode.pan:
        break;
      case _DragMode.none:
        return;
    }
    _activeMode = _downMode;
  }

  void _finishActiveGesture() {
    switch (_activeMode) {
      case _DragMode.draw:
        _finishStroke();
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
      case _DragMode.none:
        break;
    }
    _moved = false;
  }

  void _cancelActiveGesture() {
    switch (_activeMode) {
      case _DragMode.draw:
        _finishStroke();
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

  void _handleTap(Offset world) {
    if (_tool != _Tool.select) return;
    final located = _locatePage(world);
    if (located == null) {
      setState(() => _selection.clear());
      return;
    }
    if (_currentPage != located.$1) {
      _currentPage = located.$1;
    }
    final hit = _hitObject(_currentPage, located.$2);
    if (hit == null) {
      setState(() => _selection.clear());
      return;
    }
    final alreadySelected = _selection.length == 1 && _selection.contains(hit);
    setState(() => _selection
      ..clear()
      ..add(hit));
    if (alreadySelected) {
      if (hit.startsWith('t')) {
        final t = _textById(hit);
        if (t != null) _editText(t);
      } else if (hit.startsWith('tb')) {
        final tb = _tableById(hit);
        if (tb != null) _pickTableCell(tb);
      }
    }
  }

  // ── 双指 scale ─────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount < 2) return;
    _pinchStarted = true;
    _cancelActiveGesture();
    _scaleAccum = 1.0;
    _lastFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount < 2) return;
    if (!_pinchStarted) {
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
    setState(() {});
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _pinchStarted = false;
    setState(() {});
  }

  void _panBy(Offset delta) {
    final m = _transform.value.clone();
    m.translateByDouble(delta.dx, delta.dy, 0, 1);
    _transform.value = m;
  }

  void _zoomAt(Offset focal, double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    var f = factor;
    // xournalpp 缩放范围 0.3 ~ 7。
    if (current * f < 0.3) f = 0.3 / current;
    if (current * f > 7) f = 7 / current;
    final m = _transform.value.clone();
    m.translateByDouble(focal.dx, focal.dy, 0, 1);
    m.scaleByDouble(f, f, f, 1);
    m.translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _transform.value = m;
  }

  // ── 绘制（压感） ───────────────────────────────────────────────────

  void _drawStart(Offset world) {
    final located = _locatePage(world);
    if (located == null) return;
    if (_currentPage != located.$1) {
      _currentPage = located.$1;
    }
    _pushUndo();
    if (_tool == _Tool.lasso) {
      _lasso
        ..clear()
        ..add(located.$2);
      setState(() {});
      return;
    }
    _currentBrush = _tool == _Tool.eraser ? BrushType.pen : _brush;
    _currentColor = _tool == _Tool.eraser && _eraserMode == 1
        ? _pages[_currentPage].bgColor
        : _color;
    _currentWidth = _tool == _Tool.eraser
        ? _eraserWidth
        : (_brush == BrushType.marker ? _penWidth * 3 : _penWidth);
    _currentPoints = [WhiteboardPoint(
        x: located.$2.dx, y: located.$2.dy, pressure: _lastPressure)];
    setState(() {});
  }

  double get _eraserWidth =>
      _penWidth > 5 ? 18.0 : (_penWidth > 2 ? 8.5 : (_penWidth > 1 ? 2.83 : 1.0));

  void _drawUpdate(Offset world) {
    if (_tool == _Tool.lasso) {
      final located = _locatePage(world);
      if (located == null || located.$1 != _currentPage) return;
      setState(() => _lasso.add(located.$2));
      return;
    }
    if (_currentPoints.isEmpty) return;
    final located = _locatePage(world);
    if (located == null || located.$1 != _currentPage) return;
    final pos = located.$2;

    if (_tool == _Tool.eraser) {
      if (_eraserMode == 2) {
        // 整条删除：命中即删。
        final hit = _hitObject(_currentPage, pos);
        if (hit != null && hit.startsWith('s')) {
          _deleteById(hit);
        }
      } else if (_eraserMode == 1) {
        // 白覆盖：当作白色画笔。
        _currentPoints.add(WhiteboardPoint(
            x: pos.dx, y: pos.dy, pressure: _lastPressure));
      } else {
        // 标准：切段擦除。
        _eraseAt(pos);
      }
      setState(() {});
      return;
    }

    _currentPoints.add(WhiteboardPoint(
        x: pos.dx, y: pos.dy, pressure: _lastPressure));
    setState(() {});
  }

  void _finishStroke() {
    if (_tool == _Tool.lasso) {
      _finishLasso();
      return;
    }
    if (_currentPoints.length >= 2 && _tool != _Tool.eraser) {
      final layer = _activeLayer;
      _replaceLayer(_currentPage, _currentLayer, layer.copyWith(strokes: [
        ...layer.strokes,
        InkStroke(
          id: _newId('s'),
          color: _currentColor,
          brush: _currentBrush,
          width: _currentWidth,
          points: List.of(_currentPoints),
        ),
      ]));
    }
    if (_tool == _Tool.eraser && _currentPoints.length >= 2) {
      _markDirtyAndSave();
    }
    _currentPoints = [];
  }

  /// 套索圈选（xournalpp 语义：笔迹所有点都在多边形内才算选中；
  /// 文本/图片/表格要求包围盒四角全在多边形内）。
  void _finishLasso() {
    final poly = List<Offset>.from(_lasso);
    setState(() => _lasso.clear());
    if (poly.length < 3) return;

    final selected = <String>{};
    for (final layer in _pages[_currentPage].layers) {
      if (!layer.visible) continue;
      for (final s in layer.strokes) {
        // xournalpp Stroke::isInSelection：所有点都在框内。
        final allInside =
            s.points.every((pt) => _pointInPolygon(Offset(pt.x, pt.y), poly));
        if (allInside) selected.add(s.id);
      }
      for (final t in layer.texts) {
        final r = _textRect(t);
        if (_rectInside(r, poly)) selected.add(t.id);
      }
      for (final im in layer.images) {
        if (_rectInside(_imageRect(im), poly)) selected.add(im.id);
      }
      for (final tb in layer.tables) {
        if (_rectInside(_tableRect(tb), poly)) selected.add(tb.id);
      }
    }
    _selection
      ..clear()
      ..addAll(selected);
    _markDirtyAndSave();
  }

  bool _rectInside(Rect r, List<Offset> poly) =>
      _pointInPolygon(r.topLeft, poly) &&
      _pointInPolygon(r.topRight, poly) &&
      _pointInPolygon(r.bottomLeft, poly) &&
      _pointInPolygon(r.bottomRight, poly);

  void _deleteById(String id) {
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(
      strokes: layer.strokes.where((s) => s.id != id).toList(),
      texts: layer.texts.where((t) => t.id != id).toList(),
      images: layer.images.where((i) => i.id != id).toList(),
      tables: layer.tables.where((tb) => tb.id != id).toList(),
    ));
  }

  /// 标准橡皮：按段切（半径 = 屏幕恒定 16px）。
  void _eraseAt(Offset c) {
    final r = 16.0 / _viewScale;
    final layer = _activeLayer;
    final next = <InkStroke>[];
    for (final s in layer.strokes) {
      next.addAll(_splitStroke(s, c, r));
    }
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(strokes: next));
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
        if (kept.length >= 2) {
          out.add(InkStroke(
              id: _newId('s'),
              color: s.color,
              brush: s.brush,
              width: s.width,
              points: kept));
        }
        kept.clear();
      } else {
        kept.add(pt);
      }
    }
    if (kept.length >= 2) {
      out.add(InkStroke(
          id: _newId('s'),
          color: s.color,
          brush: s.brush,
          width: s.width,
          points: kept));
    }
    return out;
  }

  double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  // ── 选择：移动/缩放/旋转 ──────────────────────────────────────────

  void _beginMove(Offset world) {
    final located = _locatePage(world);
    if (located == null) return;
    final hit = _hitObject(_currentPage, located.$2);
    if (hit == null) return;
    if (!_selection.contains(hit)) {
      setState(() => _selection
        ..clear()
        ..add(hit));
    }
    _moveIds = Set.of(_selection);
    _moved = false;
  }

  void _beginResize(Offset world) {
    final located = _locatePage(world);
    if (located == null) return;
    final hit = _hitResizeHandle(located.$2);
    if (hit == null) return;
    final r = _rectById(hit);
    if (r == null) return;
    _resizeId = hit;
    _resizeStartPos = located.$2;
    _resizeOrigW = r.width;
    _resizeOrigH = r.height;
    _resizeOrigFontSize = _textById(hit)?.fontSize;
  }

  void _beginRotate(Offset world) {
    final located = _locatePage(world);
    if (located == null) return;
    final hit = _hitRotateHandle(located.$2);
    if (hit == null || _centerOf(hit) == null) return;
    _rotateId = hit;
  }

  void _translateSelection(double dx, double dy) {
    final layer = _activeLayer;
    final strokes = layer.strokes.map((s) {
      if (!_moveIds!.contains(s.id)) return s;
      return InkStroke(
          id: s.id,
          color: s.color,
          brush: s.brush,
          width: s.width,
          points: s.points
              .map((pt) => WhiteboardPoint(
                  x: pt.x + dx, y: pt.y + dy, pressure: pt.pressure))
              .toList());
    }).toList();
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(
      strokes: strokes,
      texts: layer.texts.map((t) => _moveIds!.contains(t.id)
          ? TextItem(
              id: t.id,
              x: t.x + dx,
              y: t.y + dy,
              text: t.text,
              fontSize: t.fontSize,
              rotation: t.rotation)
          : t).toList(),
      images: layer.images.map((im) => _moveIds!.contains(im.id)
          ? ImageItem(
              id: im.id,
              x: im.x + dx,
              y: im.y + dy,
              width: im.width,
              height: im.height,
              path: im.path,
              rotation: im.rotation)
          : im).toList(),
      tables: layer.tables.map((tb) => _moveIds!.contains(tb.id)
          ? TableItem(
              id: tb.id,
              x: tb.x + dx,
              y: tb.y + dy,
              rows: tb.rows,
              cols: tb.cols,
              cells: tb.cells,
              cellW: tb.cellW,
              cellH: tb.cellH,
              rotation: tb.rotation)
          : tb).toList(),
    ));
  }

  void _resizeBy(Offset delta) {
    final id = _resizeId;
    if (id == null || _resizeStartPos == null) return;
    final layer = _activeLayer;
    if (id.startsWith('t')) {
      final t = _textById(id);
      if (t != null && _resizeOrigFontSize != null) {
        var size = (_resizeOrigFontSize! + (delta.dx + delta.dy) / 6.0)
            .clamp(8.0, 160.0);
        _replaceLayer(_currentPage, _currentLayer, layer.copyWith(texts: layer.texts
            .map((x) => x.id == id
                ? TextItem(
                    id: x.id,
                    x: x.x,
                    y: x.y,
                    text: x.text,
                    fontSize: size,
                    rotation: x.rotation)
                : x)
            .toList()));
      }
    } else {
      final w = _resizeOrigW ?? 100;
      final h = _resizeOrigH ?? 60;
      final nw = (w + delta.dx).clamp(40.0, 4000.0);
      final nh = (h + delta.dy).clamp(24.0, 4000.0);
      if (id.startsWith('i')) {
        _replaceLayer(_currentPage, _currentLayer, layer.copyWith(images: layer.images
            .map((im) => im.id == id
                ? ImageItem(
                    id: im.id,
                    x: im.x,
                    y: im.y,
                    width: nw,
                    height: nh,
                    path: im.path,
                    rotation: im.rotation)
                : im)
            .toList()));
      } else if (id.startsWith('tb')) {
        final tb = _tableById(id);
        if (tb != null) {
          final cw = (nw / tb.cols).clamp(28.0, 400.0);
          final ch = (nh / tb.rows).clamp(16.0, 200.0);
          _replaceLayer(_currentPage, _currentLayer, layer.copyWith(tables: layer.tables
              .map((x) => x.id == id
                  ? TableItem(
                      id: x.id,
                      x: x.x,
                      y: x.y,
                      rows: x.rows,
                      cols: x.cols,
                      cells: x.cells,
                      cellW: cw,
                      cellH: ch,
                      rotation: x.rotation)
                  : x)
              .toList()));
        }
      }
    }
  }

  void _rotateBy(Offset world) {
    final id = _rotateId;
    final located = _locatePage(world);
    if (id == null || located == null) return;
    final center = _centerOf(id);
    if (center == null) return;
    final angle = (located.$2 - center).direction + 1.5707963267948966;
    var target = angle;
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
  }

  void _setItemRotation(String id, double rotation) {
    final layer = _activeLayer;
    if (id.startsWith('t')) {
      _replaceLayer(_currentPage, _currentLayer, layer.copyWith(texts: layer.texts
          .map((t) => t.id == id
              ? TextItem(
                  id: t.id,
                  x: t.x,
                  y: t.y,
                  text: t.text,
                  fontSize: t.fontSize,
                  rotation: rotation)
              : t)
          .toList()));
    } else if (id.startsWith('i')) {
      _replaceLayer(_currentPage, _currentLayer, layer.copyWith(images: layer.images
          .map((im) => im.id == id
              ? ImageItem(
                  id: im.id,
                  x: im.x,
                  y: im.y,
                  width: im.width,
                  height: im.height,
                  path: im.path,
                  rotation: rotation)
              : im)
          .toList()));
    } else if (id.startsWith('tb')) {
      _replaceLayer(_currentPage, _currentLayer, layer.copyWith(tables: layer.tables
          .map((tb) => tb.id == id
              ? TableItem(
                  id: tb.id,
                  x: tb.x,
                  y: tb.y,
                  rows: tb.rows,
                  cols: tb.cols,
                  cells: tb.cells,
                  cellW: tb.cellW,
                  cellH: tb.cellH,
                  rotation: rotation)
              : tb)
          .toList()));
    }
  }

  void _deleteSelected() {
    if (_selection.isEmpty) return;
    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(
      strokes: layer.strokes.where((s) => !_selection.contains(s.id)).toList(),
      texts: layer.texts.where((t) => !_selection.contains(t.id)).toList(),
      images: layer.images.where((i) => !_selection.contains(i.id)).toList(),
      tables: layer.tables.where((tb) => !_selection.contains(tb.id)).toList(),
    ));
    _selection.clear();
    _markDirtyAndSave();
  }

  /// 选中图片 → 复制到 App 截图库（saveToDownloads=false）或
  /// 保存到系统下载目录（true）。与 PDF/Word/画布（tldraw）同款。
  Future<void> _selectedImageAction(bool saveToDownloads) async {
    final layer = _activeLayer;
    final imageIds = {for (final i in layer.images) i.id};
    final sel = _selection.where(imageIds.contains).toList();
    if (sel.isEmpty) {
      _toast('请先用选择工具点选一张图片');
      return;
    }
    final im = layer.images.firstWhere((i) => i.id == sel.first);
    final path = im.path;
    if (path.isEmpty || !File(path).existsSync()) {
      _toast('图片文件已不存在（可能已被删除）');
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      if (saveToDownloads) {
        final ok = await ShotActions.saveToLocal(context, ref, bytes,
            prefix: 'board_img');
        if (mounted) {
          _toast(ok ? '图片已保存到本机下载目录' : '保存失败，请重试');
        }
      } else {
        final saved =
            await ShotActions.saveToLibrary(bytes, prefix: 'board_img');
        if (mounted) {
          _toast(saved != null
              ? '图片已复制到 App 截图库（可在文件/画布再次插入）'
              : '复制失败，请重试');
        }
      }
    } catch (e) {
      debugPrint('[Xopp] image action failed: $e');
      if (mounted) _toast('操作失败: $e');
    }
  }

  // ── 文本/图片/表格（弹窗式，复用旧交互） ─────────────────────────

  Future<void> _addText() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('插入文本'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '输入文字…', border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('插入')),
        ],
      ),
    );
    if (ok != true || ctrl.text.isEmpty || !mounted) return;
    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(texts: [
      ...layer.texts,
      TextItem(id: _newId('t'), x: 80, y: 120, text: ctrl.text),
    ]));
    _markDirtyAndSave();
  }

  Future<void> _addImage() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.image, withData: true);
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
    } catch (_) {}

    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(images: [
      ...layer.images,
      ImageItem(id: _newId('i'), x: 80, y: 120, width: w, height: h, path: dest),
    ]));
    _markDirtyAndSave();
  }

  Future<void> _addTable() async {
    var rows = 3, cols = 3;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('插入表格'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                const Text('行数'),
                Expanded(
                  child: Slider(
                      value: rows.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: '$rows',
                      onChanged: (v) => setLocal(() => rows = v.round())),
                ),
                Text('$rows'),
              ]),
              Row(children: [
                const Text('列数'),
                Expanded(
                  child: Slider(
                      value: cols.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: '$cols',
                      onChanged: (v) => setLocal(() => cols = v.round())),
                ),
                Text('$cols'),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('插入')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(tables: [
      ...layer.tables,
      TableItem(
          id: _newId('tb'),
          x: 80,
          y: 120,
          rows: rows,
          cols: cols,
          cells: List.filled(rows * cols, '')),
    ]));
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
              TextField(controller: ctrl, autofocus: true, maxLines: 3,
                  decoration: const InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))))),
              Row(children: [
                const Text('字号'),
                Expanded(
                  child: Slider(
                      value: size,
                      min: 12,
                      max: 96,
                      onChanged: (v) => setLocal(() => size = v)),
                ),
                Text(size.round().toString()),
              ]),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(texts: layer.texts
        .map((x) => x.id == t.id
            ? TextItem(
                id: x.id, x: x.x, y: x.y, text: ctrl.text,
                fontSize: size, rotation: x.rotation)
            : x)
        .toList()));
    _markDirtyAndSave();
  }

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
    final ctrl = TextEditingController(text: tb.cell(picked.$1, picked.$2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑单元格（第 ${picked.$1 + 1} 行 · 第 ${picked.$2 + 1} 列）'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 3,
            decoration: const InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _pushUndo();
    final layer = _activeLayer;
    _replaceLayer(_currentPage, _currentLayer, layer.copyWith(tables: layer.tables
        .map((x) {
          if (x.id != tb.id) return x;
          final cells = List<String>.from(x.cells);
          cells[picked.$1 * tb.cols + picked.$2] = ctrl.text;
          return TableItem(
              id: x.id, x: x.x, y: x.y, rows: x.rows, cols: x.cols,
              cells: cells, cellW: x.cellW, cellH: x.cellH, rotation: x.rotation);
        })
        .toList()));
    _markDirtyAndSave();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── 分屏打开哔哩哔哩（Android 7+，边看视频边做笔记） ─────────────

  Future<void> _openBilibiliSplit() async {
    try {
      const channel = MethodChannel('io.github.zzy19074244935.libranote/split');
      final map = await channel.invokeMethod<Map>('openBilibili');
      if (!mounted) return;
      final ok = map?['ok'] == true;
      final reason = (map?['reason'] as String?) ?? '';
      _toast(ok
          ? '已尝试分屏打开 B 站：若系统未自动分屏，请按最近任务键手动分屏'
          : reason == 'not_installed'
              ? '未检测到哔哩哔哩 App，请先安装'
              : '分屏启动失败，请手动从最近任务分屏打开 B 站');
    } catch (e) {
      if (mounted) _toast('当前设备不支持分屏启动 B 站（Android 7+ 可用）');
    }
  }

  // ── 导出当前页 PNG ─────────────────────────────────────────────────

  Future<void> _exportPng() async {
    final page = _pages[_currentPage];
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // 页背景 + 元素（缩放上限 3200px）。
    var scale = 1.0;
    const maxDim = 3200.0;
    final longest = math.max(page.width, page.height);
    if (longest > maxDim) scale = maxDim / longest;
    canvas.scale(scale);

    canvas.drawRect(Rect.fromLTWH(0, 0, page.width, page.height),
        Paint()..color = Color(page.bgColor));
    _paintPageBackground(canvas, page, forExport: true);
    for (final layer in page.layers) {
      if (!layer.visible) continue;
      for (final s in layer.strokes) {
        _paintStroke(canvas, s);
      }
      for (final t in layer.texts) {
        final tp = TextPainter(
          text: TextSpan(
              text: t.text,
              style: TextStyle(
                  fontSize: t.fontSize, color: const Color(0xFF1A1A1A))),
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
      for (final im in layer.images) {
        try {
          final bytes = await File(im.path).readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          canvas.drawImageRect(
            frame.image,
            Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
                frame.image.height.toDouble()),
            Rect.fromLTWH(im.x, im.y, im.width, im.height),
            Paint()..filterQuality = FilterQuality.medium,
          );
          frame.image.dispose();
        } catch (_) {}
      }
      for (final tb in layer.tables) {
        final grid = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF999999);
        for (var r = 0; r < tb.rows; r++) {
          for (var c = 0; c < tb.cols; c++) {
            final rect = Rect.fromLTWH(
                tb.x + c * tb.cellW, tb.y + r * tb.cellH, tb.cellW, tb.cellH);
            canvas.drawRect(rect, Paint()..color = Colors.white);
            canvas.drawRect(rect, grid);
            final tp = TextPainter(
              text: TextSpan(
                  text: tb.cell(r, c),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF1A1A1A))),
              textDirection: ui.TextDirection.ltr,
            )..layout(maxWidth: tb.cellW - 8);
            tp.paint(canvas, Offset(rect.left + 4, rect.top + 4));
          }
        }
      }
    }
    final picture = recorder.endRecording();
    final img = await picture.toImage(
        (page.width * scale).ceil(), (page.height * scale).ceil());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (byteData == null) {
      _toast('导出失败');
      return;
    }
    final pngBytes = byteData.buffer.asUint8List();
    final dir = await getApplicationDocumentsDirectory();
    final filename =
        'board-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}.png';
    final file = File(p.join(dir.path, filename));
    await file.writeAsBytes(pngBytes, flush: true);
    if (!mounted) return;
    final export = ref.read(fileExportServiceProvider);
    await export.saveToDownloads(filePath: file.path, fileName: filename);
    try {
      await export.shareFile(filePath: file.path);
    } catch (_) {}
    if (mounted) _toast('已导出本页图片：$filename');
  }

  // ── 构建 ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF565656), // xournalpp 灰底
      appBar: AppBar(
        title: Text(
          _wb.title.isEmpty ? '笔记本' : _wb.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!kIsWeb && Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.vertical_split_outlined),
              tooltip: '分屏打开 B 站',
              onPressed: _openBilibiliSplit,
            ),
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: '导出本页为图片',
            onPressed: _exportPng,
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
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildCanvas(colors)),
          _buildToolbar(colors),
          _buildPageBar(colors),
        ],
      ),
    );
  }

  Widget _buildCanvas(ColorScheme colors) {
    final child = SizedBox(
      width: _totalWidth,
      height: _totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < _pages.length; i++)
            Positioned(
              top: _pageOffset(i),
              left: 200,
              child: _buildPageWidget(i, colors),
            ),
        ],
      ),
    );

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
                minScale: 0.3,
                maxScale: 7,
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

  Widget _buildPageWidget(int index, ColorScheme colors) {
    final page = _pages[index];
    final selectedPage = index == _currentPage;
    return Container(
      width: page.width,
      height: page.height,
      decoration: BoxDecoration(
        color: Color(page.bgColor),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
        border: selectedPage
            ? Border.all(color: colors.primary, width: 2)
            : Border.all(color: const Color(0xFFBDBDBD), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BoardPainter(
                page: page,
                selection: selectedPage ? _selection : const {},
                selectionPolys: selectedPage
                    ? {
                        for (final id in _selection)
                          if (_cornersOf(id).isNotEmpty) id: _cornersOf(id),
                      }
                    : const {},
                scaleHandles: selectedPage
                    ? {
                        for (final id in _selection)
                          if (!id.startsWith('s'))
                            if (_scaleHandleOf(id) != null)
                              id: _scaleHandleOf(id)!,
                      }
                    : const {},
                rotateHandles: selectedPage
                    ? {
                        for (final id in _selection)
                          if (!id.startsWith('s'))
                            if (_rotateHandleOf(id) != null)
                              id: _rotateHandleOf(id)!,
                      }
                    : const {},
                currentPoints: selectedPage && index == _currentPage
                    ? _currentPoints
                    : const [],
                lasso: selectedPage && index == _currentPage ? _lasso : const [],
                currentBrush: _currentBrush,
                currentColor: _currentColor,
                currentWidth: _currentWidth,
                viewScale: _viewScale,
                accent: colors.primary,
                revision: _revision,
              ),
            ),
          ),
          // 文本/图片/表格 widget 层。
          for (final layer in page.layers)
            if (layer.visible) ...[
              ...layer.texts.map((t) => Positioned(
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
              ...layer.images.map((im) => Positioned(
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
              ...layer.tables.map((tb) => Positioned(
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
        ],
      ),
    );
  }

  /// 背景绘制（xournalpp 参数：ruled 24pt/0.5pt dodgerblue、graph·dotted
  /// 14.17pt silver、ruled 页眉 80 页脚 60）。
  void _paintPageBackground(Canvas canvas, BoardPage page,
      {bool forExport = false}) {
    switch (page.bgType) {
      case 'ruled':
      case 'lined':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = const Color(0xFF40A0FF); // xopp_dodgerblue
        for (var y = 80.0; y <= page.height - 60; y += 24) {
          canvas.drawLine(
              Offset(0, y), Offset(page.width, y), paint);
        }
        if (page.bgType == 'lined') {
          final vPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5
            ..color = const Color(0xFFFF0080); // xopp_deeppink
          canvas.drawLine(const Offset(72, 0), Offset(72, page.height), vPaint);
        }
      case 'graph':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = const Color(0xFFBDBDBD); // xopp_silver
        for (var x = 0.0; x <= page.width; x += 14.17) {
          canvas.drawLine(Offset(x, 0), Offset(x, page.height), paint);
        }
        for (var y = 0.0; y <= page.height; y += 14.17) {
          canvas.drawLine(Offset(0, y), Offset(page.width, y), paint);
        }
      case 'dotted':
        final pts = <Offset>[];
        for (var y = 14.17; y < page.height; y += 14.17) {
          for (var x = 14.17; x < page.width; x += 14.17) {
            pts.add(Offset(x, y));
          }
        }
        if (pts.isNotEmpty) {
          canvas.drawPoints(
            ui.PointMode.points,
            pts,
            Paint()
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round
              ..color = const Color(0xFFBDBDBD),
          );
        }
      default:
        break;
    }
  }

  Widget _buildToolbar(ColorScheme colors) {
    final showBrush = _tool == _Tool.pen;
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
                    _toolBtn(_Tool.lasso, Icons.gesture, '套索', colors),
                    _toolBtn(_Tool.text, Icons.title, '文本', colors),
                    _toolBtn(_Tool.image, Icons.image_outlined, '图片', colors),
                    _toolBtn(_Tool.table, Icons.table_chart_outlined, '表格', colors),
                    _toolBtn(_Tool.layers, Icons.layers_outlined, '图层', colors),
                    if (_tool == _Tool.select && _selection.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      // 选中图片 → 复制 / 保存（选中其它元素时也显示，
                      // 点按会给提示）。
                      TextButton.icon(
                        onPressed: () => _selectedImageAction(false),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制'),
                      ),
                      TextButton.icon(
                        onPressed: () => _selectedImageAction(true),
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text('保存'),
                      ),
                      TextButton.icon(
                        onPressed: _deleteSelected,
                        icon: const Icon(Icons.delete, size: 16),
                        label: const Text('删除'),
                      ),
                    ],
                    if (_tool != _Tool.select) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.check),
                        tooltip: '完成（切回选择）',
                        onPressed: () => setState(() => _tool = _Tool.select),
                      ),
                    ],
                  ],
                ),
              ),
              if (showBrush || _tool == _Tool.eraser) ...[
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      if (showBrush) ...[
                        // 笔型：画笔 / 荧光笔（xournalpp highlighter）。
                        ChoiceChip(
                          avatar: const Icon(Icons.edit, size: 16),
                          label: const Text('画笔', style: TextStyle(fontSize: 12)),
                          selected: _brush == BrushType.pen,
                          onSelected: (_) =>
                              setState(() => _brush = BrushType.pen),
                          visualDensity: VisualDensity.compact,
                          selectedColor: colors.primaryContainer,
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          avatar: const Icon(Icons.border_color, size: 16),
                          label: const Text('荧光笔', style: TextStyle(fontSize: 12)),
                          selected: _brush == BrushType.marker,
                          onSelected: (_) =>
                              setState(() => _brush = BrushType.marker),
                          visualDensity: VisualDensity.compact,
                          selectedColor: colors.primaryContainer,
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (_tool == _Tool.eraser) ...[
                        // 橡皮三模式（xournalpp EraserType）。
                        for (final (label, mode) in const [
                          ('标准', 0),
                          ('白覆盖', 1),
                          ('整条删除', 2),
                        ]) ...[
                          ChoiceChip(
                            label: Text(label, style: const TextStyle(fontSize: 12)),
                            selected: _eraserMode == mode,
                            onSelected: (_) =>
                                setState(() => _eraserMode = mode),
                            visualDensity: VisualDensity.compact,
                            selectedColor: colors.primaryContainer,
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                      const VerticalDivider(width: 1),
                      const SizedBox(width: 8),
                      // xournalpp 5 档粗细。
                      const Text('粗细', style: TextStyle(fontSize: 12)),
                      SizedBox(
                        width: 140,
                        child: Slider(
                          value: _penWidth,
                          min: 0.42,
                          max: 5.67,
                          onChanged: (v) => setState(() => _penWidth = v),
                        ),
                      ),
                      Text(_penWidth.toStringAsFixed(2),
                          style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 10),
                      const VerticalDivider(width: 1),
                      const SizedBox(width: 8),
                      // xournalpp 11 色调色板。
                      for (final c in _xournalColors)
                        GestureDetector(
                          onTap: () => setState(() => _color = c),
                          child: Container(
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == c
                                    ? colors.primary
                                    : Colors.black.withValues(alpha: 0.15),
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
                      const Text('页面背景', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 8),
                      for (final (label, type) in const [
                        ('空白', 'plain'),
                        ('横线', 'ruled'),
                        ('横线+竖线', 'lined'),
                        ('方格', 'graph'),
                        ('点阵', 'dotted'),
                      ]) ...[
                        ChoiceChip(
                          label: Text(label, style: const TextStyle(fontSize: 12)),
                          selected: _pages[_currentPage].bgType == type,
                          onSelected: (_) => _setPageBackground(type),
                          visualDensity: VisualDensity.compact,
                          selectedColor: colors.primaryContainer,
                        ),
                        const SizedBox(width: 6),
                      ],
                      const SizedBox(width: 12),
                      Text(
                        '单指点选/拖动 · 单指拖空白=平移 · 双指=缩放 · 右下圆点=缩放 · 顶部圆点=旋转',
                        style: TextStyle(
                            fontSize: 11, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageBar(ColorScheme colors) {
    return Material(
      color: colors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '新增页',
                onPressed: _addPage,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除当前页',
                onPressed: _deletePage,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _currentPage > 0
                    ? () {
                        setState(() => _currentPage--);
                        _scrollToCurrentPage();
                      }
                    : null,
              ),
              Text('${_currentPage + 1} / ${_pages.length}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _currentPage < _pages.length - 1
                    ? () {
                        setState(() => _currentPage++);
                        _scrollToCurrentPage();
                      }
                    : null,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.zoom_out),
                tooltip: '缩小',
                onPressed: () => _zoomAt(Offset(_viewportSize.width / 2,
                        _viewportSize.height / 2),
                    1 / 1.2),
              ),
              IconButton(
                icon: const Icon(Icons.zoom_in),
                tooltip: '放大',
                onPressed: () => _zoomAt(Offset(_viewportSize.width / 2,
                        _viewportSize.height / 2),
                    1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scrollToCurrentPage() {
    // 简单实现：把当前页顶部对齐视口上部 20%。
    final top = _pageOffset(_currentPage);
    final currentViewTop = _toWorld(Offset(0, _viewportSize.height * 0.2)).dy;
    _panBy(Offset(0, currentViewTop - top));
    setState(() {});
  }

  Widget _toolBtn(_Tool tool, IconData icon, String label, ColorScheme colors) {
    final selected = _tool == tool;
    return InkWell(
      onTap: () {
        switch (tool) {
          case _Tool.text:
            _addText();
          case _Tool.image:
            _addImage();
          case _Tool.table:
            _addTable();
          case _Tool.layers:
            _showLayersSheet();
          case _Tool.select:
          case _Tool.pen:
          case _Tool.eraser:
          case _Tool.lasso:
            setState(() {
              _tool = tool;
              if (tool == _Tool.select) _selection.clear();
            });
        }
      },
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
    );
  }
}

/// xournalpp 默认调色板（11 色，palettes/xournalpp.gpl）。
const List<int> _xournalColors = [
  0xFFFFE16B, // 黄
  0xFFFFA154, // 橙
  0xFFCD9EF7, // 紫
  0xFF9BDB4D, // 浅绿
  0xFF64BAFF, // 浅蓝
  0xFF808080, // 灰
  0xFF3A9104, // 深绿
  0xFFED5353, // 红
  0xFF002E99, // 深蓝
  0xFF000000, // 黑
  0xFFFFFFFF, // 白
];

enum _Tool { select, pen, eraser, lasso, text, image, table, layers }

// ── 笔迹预设（与 whiteboard_screen 一致） ─────────────────────────────

const Map<BrushType, double> _brushWidth = {
  BrushType.pen: 3.5,
  BrushType.fountain: 2.2,
  BrushType.marker: 9.0,
  BrushType.pencil: 2.8,
  BrushType.highlighter: 14.0,
  BrushType.line: 3.5,
};

const Map<BrushType, double> _brushOpacity = {
  BrushType.pen: 1.0,
  BrushType.fountain: 1.0,
  BrushType.marker: 0.47, // xournalpp OPACITY_HIGHLIGHTER
  BrushType.pencil: 0.8,
  BrushType.highlighter: 0.3,
  BrushType.line: 1.0,
};

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

void _paintStroke(Canvas canvas, InkStroke s) {
  // 压感笔迹（存在压力 < 0.99 的点）：逐段画，每段线宽 = 压力 × 基础线宽
  // （xournalpp Point.z 语义）。无压感：平滑 Path 一次画完。
  final hasPressure =
      s.points.any((pt) => pt.pressure > 0 && pt.pressure < 0.99);
  final baseW = s.width ?? (_brushWidth[s.brush] ?? 3.5);
  final opacity = _brushOpacity[s.brush] ?? 1.0;
  final color = Color(s.color).withValues(alpha: opacity);

  if (!hasPressure || s.points.length < 2) {
    canvas.drawPath(_strokePath(s.points),
        _strokePaint(s));
    if (s.points.length == 1 && hasPressure) {
      final p0 = s.points.first;
      canvas.drawCircle(
        Offset(p0.x, p0.y),
        (p0.pressure > 0 ? p0.pressure : 1) * baseW / 2,
        Paint()..color = color,
      );
    }
    return;
  }

  // 压感：逐段线段 + 圆头（端点重叠保证无缝隙）。
  for (var i = 1; i < s.points.length; i++) {
    final a = s.points[i - 1];
    final b = s.points[i];
    // xournalpp MAX_WIDTH_VARIATION=0.3：相邻点线宽突变时拆段插值；
    // 这里取两端平均已足够平滑（采样密集）。
    final pa = a.pressure > 0 ? a.pressure : 1.0;
    final pb = b.pressure > 0 ? b.pressure : 1.0;
    final w = ((pa + pb) / 2 * baseW).clamp(0.2, 80.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = w
      ..color = color;
    canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), paint);
  }
}

// ── 画板画笔 ──────────────────────────────────────────────────────────

class _BoardPainter extends CustomPainter {
  final BoardPage page;
  final Set<String> selection;
  final Map<String, List<Offset>> selectionPolys;
  final Map<String, Offset> scaleHandles;
  final Map<String, Offset> rotateHandles;
  final List<WhiteboardPoint> currentPoints;
  final List<Offset> lasso;
  final BrushType currentBrush;
  final int currentColor;
  final double currentWidth;
  final double viewScale;
  final Color accent;
  final int revision;

  _BoardPainter({
    required this.page,
    required this.selection,
    required this.selectionPolys,
    required this.scaleHandles,
    required this.rotateHandles,
    required this.currentPoints,
    required this.lasso,
    required this.currentBrush,
    required this.currentColor,
    required this.currentWidth,
    required this.viewScale,
    required this.accent,
    required this.revision,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 纸面。
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(page.bgColor));
    _paintBackground(canvas, size);
    // 元素（可见层）。
    for (final layer in page.layers) {
      if (!layer.visible) continue;
      for (final s in layer.strokes) {
        _paintStroke(canvas, s);
      }
    }
    // 绘制中预览。
    if (currentPoints.isNotEmpty) {
      final preview = InkStroke(
          id: '',
          color: currentColor,
          brush: currentBrush,
          width: currentWidth,
          points: currentPoints);
      _paintStroke(canvas, preview);
    }
    // 套索路径（半透明填充 + 描边）。
    if (lasso.length >= 2) {
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
    // 选中框与手柄。
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
  }

  void _paintBackground(Canvas canvas, Size size) {
    switch (page.bgType) {
      case 'ruled':
      case 'lined':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = const Color(0xFF40A0FF);
        for (var y = 80.0; y <= size.height - 60; y += 24) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
        if (page.bgType == 'lined') {
          final vPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5
            ..color = const Color(0xFFFF0080);
          canvas.drawLine(const Offset(72, 0), Offset(72, size.height), vPaint);
        }
      case 'graph':
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = const Color(0xFFBDBDBD);
        for (var x = 0.0; x <= size.width; x += 14.17) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 0.0; y <= size.height; y += 14.17) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case 'dotted':
        final pts = <Offset>[];
        for (var y = 14.17; y < size.height; y += 14.17) {
          for (var x = 14.17; x < size.width; x += 14.17) {
            pts.add(Offset(x, y));
          }
        }
        if (pts.isNotEmpty) {
          canvas.drawPoints(
            ui.PointMode.points,
            pts,
            Paint()
              ..strokeWidth = 1.5
              ..strokeCap = StrokeCap.round
              ..color = const Color(0xFFBDBDBD),
          );
        }
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) =>
      old.revision != revision ||
      old.page != page ||
      old.selection.length != selection.length ||
      old.currentPoints.length != currentPoints.length ||
      old.lasso.length != lasso.length ||
      old.viewScale != viewScale;
}

// ── 表格控件 ──────────────────────────────────────────────────────────

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
