import 'dart:convert';

import 'whiteboard.dart';

/// PDF 手写批注 v3 数据模型。
///
/// pdf_ink.strokes 列从「纯笔迹数组」（v1）→ v2（笔迹+文本框）升级到
/// v3：一页 = 笔迹 + 文本 + **图片**（截图插入/本地图片插入批注图层）。
/// 图片本体存在 `Documents/pdf_images/<bookId>/<id>.<ext>`，JSON 里只存
/// 元数据（位置/尺寸/旋转/文件名），避免把大图 base64 塞进 SQLite。

/// PDF 页面上的一个文本框。
class PdfTextItem {
  final String id;

  /// 左上角归一化坐标（0~1，相对页面宽高）。
  final double x;
  final double y;

  final String text;

  /// 字号（PDF points，未缩放；渲染/导出时按缩放系数放大）。
  final double fontSize;

  /// 文本块宽度（归一化，0~1），用于自动换行与命中测试。
  final double width;

  /// 文字颜色（ARGB）。
  final int color;

  /// 旋转角度（度，绕文本框中心；0 = 不旋转，正数顺时针）。
  final double rotation;

  const PdfTextItem({
    required this.id,
    required this.x,
    required this.y,
    required this.text,
    this.fontSize = 10,
    this.width = 0.26,
    this.color = 0xFF374151,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'text': text,
        'fontSize': fontSize,
        'width': width,
        'color': color,
        if (rotation != 0) 'rotation': rotation,
      };

  factory PdfTextItem.fromJson(Map<String, dynamic> json) => PdfTextItem(
        id: (json['id'] as String?) ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        text: (json['text'] as String?) ?? '',
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 10,
        width: (json['width'] as num?)?.toDouble() ?? 0.26,
        color: (json['color'] as num?)?.toInt() ?? 0xFF374151,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );

  PdfTextItem copyWith({
    String? id,
    double? x,
    double? y,
    String? text,
    double? fontSize,
    double? width,
    int? color,
    double? rotation,
  }) =>
      PdfTextItem(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        width: width ?? this.width,
        color: color ?? this.color,
        rotation: rotation ?? this.rotation,
      );
}

/// PDF 页面上的一个图片（截图插入 / 本地图片插入批注图层）。
class PdfImageItem {
  final String id;

  /// 左上角归一化坐标（0~1，相对页面宽高）。
  final double x;
  final double y;

  /// 显示宽高（归一化，0~1）。缩放手柄保持宽高比。
  final double w;
  final double h;

  /// 图片文件本体（Documents/pdf_images/ 下），仅存文件名。
  final String fileName;

  /// 旋转角度（度，绕中心，正数顺时针）。
  final double rotation;

  const PdfImageItem({
    required this.id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.fileName,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'file': fileName,
        if (rotation != 0) 'rotation': rotation,
      };

  factory PdfImageItem.fromJson(Map<String, dynamic> json) => PdfImageItem(
        id: (json['id'] as String?) ?? '',
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        w: (json['w'] as num?)?.toDouble() ?? 0.3,
        h: (json['h'] as num?)?.toDouble() ?? 0.3,
        fileName: (json['file'] as String?) ?? '',
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
      );

  PdfImageItem copyWith({
    String? id,
    double? x,
    double? y,
    double? w,
    double? h,
    String? fileName,
    double? rotation,
  }) =>
      PdfImageItem(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        fileName: fileName ?? this.fileName,
        rotation: rotation ?? this.rotation,
      );
}

/// 一页的手写内容（笔迹 + 文本 + 图片）。
class PdfInkPage {
  final List<InkStroke> strokes;
  final List<PdfTextItem> texts;
  final List<PdfImageItem> images;

  const PdfInkPage({
    this.strokes = const [],
    this.texts = const [],
    this.images = const [],
  });

  bool get isEmpty => strokes.isEmpty && texts.isEmpty && images.isEmpty;

  /// v3 编码：`{"version":3, "strokes":[], "texts":[], "images":[]}`。
  String encode() => jsonEncode({
        'version': 3,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'texts': texts.map((t) => t.toJson()).toList(),
        'images': images.map((i) => i.toJson()).toList(),
      });

  /// 解码：v1 纯笔迹数组 / v2（笔迹+文本）/ v3（+图片）都兼容（老数据不丢）。
  static PdfInkPage decode(String raw) {
    try {
      final obj = jsonDecode(raw);
      if (obj is List) {
        // v1：纯笔迹数组。
        return PdfInkPage(
          strokes: obj
              .whereType<Map>()
              .map((e) => InkStroke.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      }
      if (obj is Map) {
        return PdfInkPage(
          strokes: ((obj['strokes'] as List?) ?? [])
              .whereType<Map>()
              .map((e) => InkStroke.fromJson(e as Map<String, dynamic>))
              .toList(),
          texts: ((obj['texts'] as List?) ?? [])
              .whereType<Map>()
              .map((e) => PdfTextItem.fromJson(e as Map<String, dynamic>))
              .toList(),
          images: ((obj['images'] as List?) ?? [])
              .whereType<Map>()
              .map((e) => PdfImageItem.fromJson(e as Map<String, dynamic>))
              .toList(),
        );
      }
    } catch (_) {}
    return const PdfInkPage();
  }

  PdfInkPage copyWith({
    List<InkStroke>? strokes,
    List<PdfTextItem>? texts,
    List<PdfImageItem>? images,
  }) =>
      PdfInkPage(
        strokes: strokes ?? this.strokes,
        texts: texts ?? this.texts,
        images: images ?? this.images,
      );
}
