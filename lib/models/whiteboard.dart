import 'dart:convert';

/// 无边记式画布（白板）的完整内容模型。
///
/// 一张白板 = 若干自由笔迹 + 文本框 + 图片 + 表格，全部用「世界坐标」
/// （画布固定逻辑尺寸，缩放/平移由 InteractiveViewer 的变换矩阵负责，
/// 与这里存储的坐标无关）。内容整体序列化成一个 JSON 字符串存 SQLite。

// ── 笔迹 ────────────────────────────────────────────────────────────────

/// 笔迹上的一个采样点。pressure 保留触控笔压感（v1 未用于线宽，留待后续）。
class WhiteboardPoint {
  final double x;
  final double y;
  final double pressure;

  const WhiteboardPoint({required this.x, required this.y, this.pressure = 1});

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': pressure};

  factory WhiteboardPoint.fromJson(Map<String, dynamic> json) => WhiteboardPoint(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        pressure: (json['p'] as num?)?.toDouble() ?? 1,
      );
}

/// 画笔类型（决定线宽/透明度/笔帽）。
///
/// - pen        圆珠笔：细、实
/// - fountain   钢笔：更细、实
/// - marker     马克笔：粗、半透明
/// - pencil     铅笔：细、略浅
/// - highlighter 荧光笔：极粗、很透明（画在文字上像高亮）
/// - line       尺子直线：两点的细实线
enum BrushType { pen, fountain, marker, pencil, highlighter, line }

/// 一条自由手写笔迹。
class InkStroke {
  final String id;
  final int color; // ARGB，如 0xFF000000
  final BrushType brush;
  final List<WhiteboardPoint> points;

  /// 用户自定义线宽（画笔粗细调节）；null 时用笔触预设宽度。
  final double? width;

  const InkStroke({
    required this.id,
    required this.color,
    required this.brush,
    required this.points,
    this.width,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'color': color,
        'brush': brush.name,
        'points': points.map((p) => p.toJson()).toList(),
        if (width != null) 'w': width,
      };

  factory InkStroke.fromJson(Map<String, dynamic> json) => InkStroke(
        id: (json['id'] as String?) ?? '',
        color: (json['color'] as num?)?.toInt() ?? 0xFF000000,
        brush: BrushType.values.firstWhere(
          (b) => b.name == json['brush'],
          orElse: () => BrushType.pen,
        ),
        points: ((json['points'] as List?) ?? [])
            .map((e) => WhiteboardPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        width: (json['w'] as num?)?.toDouble(),
      );
}

// ── 文本 ────────────────────────────────────────────────────────────────

class TextItem {
  final String id;
  final double x;
  final double y;
  final String text;
  final double fontSize;

  /// 旋转角（弧度，绕中心）。
  final double rotation;

  const TextItem({
    required this.id,
    required this.x,
    required this.y,
    required this.text,
    this.fontSize = 20,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'x': x, 'y': y, 'text': text, 'fontSize': fontSize,
       if (rotation != 0) 'rotation': rotation};

  factory TextItem.fromJson(Map<String, dynamic> json) => TextItem(
        id: (json['id'] as String?) ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        text: (json['text'] as String?) ?? '',
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 20,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );
}

// ── 图片 ────────────────────────────────────────────────────────────────

class ImageItem {
  final String id;
  final double x;
  final double y;
  final double width;
  final double height;

  /// 旋转角（弧度，绕中心）。
  final double rotation;

  /// 图片在 App 私有目录下的副本路径（导入时复制过去，保证持久）。
  final String path;

  const ImageItem({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.path,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'path': path,
        if (rotation != 0) 'rotation': rotation,
      };

  factory ImageItem.fromJson(Map<String, dynamic> json) => ImageItem(
        id: (json['id'] as String?) ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        width: (json['w'] as num?)?.toDouble() ?? 200,
        height: (json['h'] as num?)?.toDouble() ?? 200,
        path: (json['path'] as String?) ?? '',
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );
}

// ── 表格 ────────────────────────────────────────────────────────────────

class TableItem {
  final String id;
  final double x;
  final double y;
  final int rows;
  final int cols;

  /// 旋转角（弧度，绕中心）。
  final double rotation;

  /// 单元格尺寸（缩放表格时同步变化）。
  final double cellW;
  final double cellH;

  /// 单元格内容，row-major，长度 == rows * cols。
  final List<String> cells;

  const TableItem({
    required this.id,
    required this.x,
    required this.y,
    required this.rows,
    required this.cols,
    required this.cells,
    this.cellW = 84,
    this.cellH = 34,
    this.rotation = 0,
  });

  String cell(int r, int c) => cells[r * cols + c];

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'rows': rows,
        'cols': cols,
        'cw': cellW,
        'ch': cellH,
        'cells': cells,
        if (rotation != 0) 'rotation': rotation,
      };

  factory TableItem.fromJson(Map<String, dynamic> json) => TableItem(
        id: (json['id'] as String?) ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        rows: (json['rows'] as num?)?.toInt() ?? 2,
        cols: (json['cols'] as num?)?.toInt() ?? 2,
        cellW: (json['cw'] as num?)?.toDouble() ?? 84,
        cellH: (json['ch'] as num?)?.toDouble() ?? 34,
        cells: ((json['cells'] as List?) ?? [])
            .map((e) => (e as String?) ?? '')
            .toList(),
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );
}

// ── xournalpp 式多页文档（v2 内容格式） ───────────────────────────────

/// 一页画纸（xournalpp 式：固定尺寸 pt + 背景 + 多层）。
class BoardPage {
  final double width;
  final double height;

  /// 背景类型：'plain' 空白 / 'ruled' 横线 / 'lined' 横线+竖线 /
  /// 'graph' 方格 / 'dotted' 点阵。
  final String bgType;

  /// 纸面颜色（ARGB，plain 背景用）。
  final int bgColor;

  final List<BoardLayer> layers;

  const BoardPage({
    required this.width,
    required this.height,
    this.bgType = 'ruled',
    this.bgColor = 0xFFFFFFFF,
    this.layers = const [],
  });

  /// 默认 A4 纵向页（xournalpp 默认 595.28 x 841.89 pt）。
  static BoardPage a4({String bgType = 'ruled'}) => BoardPage(
        width: 595.28,
        height: 841.89,
        bgType: bgType,
        layers: [const BoardLayer(name: '图层 1')],
      );

  Map<String, dynamic> toJson() => {
        'w': width,
        'h': height,
        'bg': bgType,
        'bgColor': bgColor,
        'layers': layers.map((l) => l.toJson()).toList(),
      };

  factory BoardPage.fromJson(Map<String, dynamic> json) => BoardPage(
        width: (json['w'] as num?)?.toDouble() ?? 595.28,
        height: (json['h'] as num?)?.toDouble() ?? 841.89,
        bgType: (json['bg'] as String?) ?? 'ruled',
        bgColor: (json['bgColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
        layers: ((json['layers'] as List?) ?? [])
            .map((e) => BoardLayer.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 一层（笔迹/文本/图片/表格，含可见性）。
class BoardLayer {
  final String? name;
  final bool visible;
  final List<InkStroke> strokes;
  final List<TextItem> texts;
  final List<ImageItem> images;
  final List<TableItem> tables;

  const BoardLayer({
    this.name,
    this.visible = true,
    this.strokes = const [],
    this.texts = const [],
    this.images = const [],
    this.tables = const [],
  });

  BoardLayer copyWith({
    String? name,
    bool? visible,
    List<InkStroke>? strokes,
    List<TextItem>? texts,
    List<ImageItem>? images,
    List<TableItem>? tables,
  }) =>
      BoardLayer(
        name: name ?? this.name,
        visible: visible ?? this.visible,
        strokes: strokes ?? this.strokes,
        texts: texts ?? this.texts,
        images: images ?? this.images,
        tables: tables ?? this.tables,
      );

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        'visible': visible,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'texts': texts.map((t) => t.toJson()).toList(),
        'images': images.map((i) => i.toJson()).toList(),
        'tables': tables.map((t) => t.toJson()).toList(),
      };

  factory BoardLayer.fromJson(Map<String, dynamic> json) => BoardLayer(
        name: json['name'] as String?,
        visible: (json['visible'] as bool?) ?? true,
        strokes: ((json['strokes'] as List?) ?? [])
            .map((e) => InkStroke.fromJson(e as Map<String, dynamic>))
            .toList(),
        texts: ((json['texts'] as List?) ?? [])
            .map((e) => TextItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        images: ((json['images'] as List?) ?? [])
            .map((e) => ImageItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        tables: ((json['tables'] as List?) ?? [])
            .map((e) => TableItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ── 白板 ────────────────────────────────────────────────────────────────

class Whiteboard {
  int? id;
  String title;
  List<InkStroke> strokes;
  List<TextItem> texts;
  List<ImageItem> images;
  List<TableItem> tables;

  /// 背景类型：'blank' 空白 / 'lines' 横线 / 'dots' 点点。
  String background;

  /// xournalpp 式多页（v2 内容格式）。非空时优先使用；空 = 旧版单画布。
  List<BoardPage> pages;

  /// tldraw 引擎快照（v3 内容格式）：tldraw store.getSnapshot() 的原始
  /// JSON 字符串。非空时优先使用——真实 tldraw 白板，与 v1/v2 互斥。
  String? tldrawJson;

  /// tldraw 白板的列表缩略图（PNG，App 私有目录）。
  String? thumbnailPath;

  DateTime createdAt;
  DateTime updatedAt;

  Whiteboard({
    this.id,
    this.title = '',
    List<InkStroke>? strokes,
    List<TextItem>? texts,
    List<ImageItem>? images,
    List<TableItem>? tables,
    this.background = 'blank',
    List<BoardPage>? pages,
    this.tldrawJson,
    this.thumbnailPath,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : strokes = strokes ?? [],
        texts = texts ?? [],
        images = images ?? [],
        tables = tables ?? [],
        pages = pages ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  bool get isEmpty =>
      strokes.isEmpty &&
      texts.isEmpty &&
      images.isEmpty &&
      tables.isEmpty &&
      pages.isEmpty &&
      (tldrawJson == null || tldrawJson!.isEmpty);

  /// 是否是多页文档（v2）。
  bool get isPaged => pages.isNotEmpty;

  /// 是否是 tldraw 白板（v3）。
  bool get isTldraw => tldrawJson != null && tldrawJson!.isNotEmpty;

  /// 内容序列化（存 `whiteboard.content` 列、也是撤销栈的快照单位）。
  Map<String, dynamic> contentToJson() {
    if (isTldraw) {
      // v3：tldraw 引擎。snapshot 原样保存（tldraw store 快照 JSON），
      // 避免 jsonDecode→jsonEncode 往返破坏精度。
      return {
        'version': 3,
        'engine': 'tldraw',
        'snapshot': jsonDecode(tldrawJson!),
        if (thumbnailPath != null) 'thumbnail': thumbnailPath,
      };
    }
    if (pages.isNotEmpty) {
      return {
        'version': 2,
        'pages': pages.map((p) => p.toJson()).toList(),
      };
    }
    return {
      'background': background,
      'strokes': strokes.map((s) => s.toJson()).toList(),
      'texts': texts.map((t) => t.toJson()).toList(),
      'images': images.map((i) => i.toJson()).toList(),
      'tables': tables.map((t) => t.toJson()).toList(),
    };
  }

  String get contentJson => jsonEncode(contentToJson());

  /// 从内容 JSON 重建（容错：任何一块坏了都不影响其余）。
  /// v3（tldraw）> v2（多页）> v1（四个旧列表）。
  void loadContent(String? json) {
    if (json == null || json.isEmpty) return;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final version = (map['version'] as num?)?.toInt() ?? 1;
      if (version >= 3) {
        final snapshot = map['snapshot'];
        tldrawJson = snapshot == null ? null : jsonEncode(snapshot);
        thumbnailPath = map['thumbnail'] as String?;
        return;
      }
      if (version == 2) {
        pages = ((map['pages'] as List?) ?? [])
            .map((e) => BoardPage.fromJson(e as Map<String, dynamic>))
            .toList();
        return;
      }
      background = (map['background'] as String?) ?? 'blank';
      strokes = ((map['strokes'] as List?) ?? [])
          .map((e) => InkStroke.fromJson(e as Map<String, dynamic>))
          .toList();
      texts = ((map['texts'] as List?) ?? [])
          .map((e) => TextItem.fromJson(e as Map<String, dynamic>))
          .toList();
      images = ((map['images'] as List?) ?? [])
          .map((e) => ImageItem.fromJson(e as Map<String, dynamic>))
          .toList();
      tables = ((map['tables'] as List?) ?? [])
          .map((e) => TableItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 损坏内容 → 保持现状，不崩。
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': contentJson,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Whiteboard.fromJson(Map<String, dynamic> json) {
    final wb = Whiteboard(
      id: json['id'] as int?,
      title: (json['title'] as String?) ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updated_at'] as int)
          : DateTime.now(),
    );
    wb.loadContent(json['content'] as String?);
    return wb;
  }
}
