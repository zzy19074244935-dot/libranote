/// Word（DOCX）批注模型（方案 Phase 4）。
///
/// DOCX 没有页码概念，锚点 = 段落索引 + 字符偏移（相对该段落纯文本），
/// DOCX 加载后段落文本稳定，偏移不会漂移。quoted_text 必填（§2.8 铁律）。
class DocxNote {
  final int? id; // auto-increment PK, null until persisted
  final String bookId;

  /// 段落索引（0-based，对应 DocxLoader.paragraphs 的下标）。
  final int paraIndex;

  /// 选中文本在该段落纯文本里的字符偏移（闭开区间 [start, end)）。
  final int startOffset;
  final int endOffset;

  /// 原文引用（必填）。
  final String quotedText;

  /// 用户笔记正文（高亮可为空）。
  final String note;

  /// 颜色 #RRGGBB。
  final String? color;

  /// 样式：highlight / underline / squiggly。
  final String style;

  /// 来源：'manual'（划词批注）/ 'ai'（AI 确认后的标注）。
  final String source;

  /// 选区截图路径（可选）。
  final String? imagePath;

  /// ── 浮动文本框几何（style='textbox' 时有效） ──────────────────────
  /// x / y / w 相对正文区 0~1（y 是相对**全文总高度**的比例），
  /// font_size 为 pt（0 = 用阅读器默认字号），rotation 为角度制。
  final double x;
  final double y;
  final double w;
  final double fontSize;
  final double rotation;

  final DateTime createdAt;
  final DateTime updatedAt;

  DocxNote({
    this.id,
    required this.bookId,
    required this.paraIndex,
    required this.startOffset,
    required this.endOffset,
    required this.quotedText,
    this.note = '',
    this.color,
    this.style = 'highlight',
    this.source = 'manual',
    this.imagePath,
    this.x = 0,
    this.y = 0,
    this.w = 0.4,
    this.fontSize = 0,
    this.rotation = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  DocxNote copyWith({
    int? id,
    String? bookId,
    int? paraIndex,
    int? startOffset,
    int? endOffset,
    String? quotedText,
    String? note,
    String? color,
    String? style,
    String? source,
    String? imagePath,
    double? x,
    double? y,
    double? w,
    double? fontSize,
    double? rotation,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      DocxNote(
        id: id ?? this.id,
        bookId: bookId ?? this.bookId,
        paraIndex: paraIndex ?? this.paraIndex,
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        quotedText: quotedText ?? this.quotedText,
        note: note ?? this.note,
        color: color ?? this.color,
        style: style ?? this.style,
        source: source ?? this.source,
        imagePath: imagePath ?? this.imagePath,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        fontSize: fontSize ?? this.fontSize,
        rotation: rotation ?? this.rotation,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'para_index': paraIndex,
        'start_offset': startOffset,
        'end_offset': endOffset,
        'quoted_text': quotedText,
        'note': note,
        'color': color,
        'style': style,
        'source': source,
        'image_path': imagePath,
        'x': x,
        'y': y,
        'w': w,
        'font_size': fontSize,
        'rotation': rotation,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory DocxNote.fromJson(Map<String, dynamic> json) => DocxNote(
        id: json['id'] as int?,
        bookId: json['book_id'] as String,
        paraIndex: (json['para_index'] as num?)?.toInt() ?? 0,
        startOffset: (json['start_offset'] as num?)?.toInt() ?? 0,
        endOffset: (json['end_offset'] as num?)?.toInt() ?? 0,
        quotedText: (json['quoted_text'] ?? '') as String,
        note: (json['note'] ?? '') as String,
        color: json['color'] as String?,
        style: (json['style'] as String?) ?? 'highlight',
        source: (json['source'] as String?) ?? 'manual',
        imagePath: json['image_path'] as String?,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        w: (json['w'] as num?)?.toDouble() ?? 0.4,
        fontSize: (json['font_size'] as num?)?.toDouble() ?? 0,
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
        createdAt: json['created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int)
            : DateTime.now(),
        updatedAt: json['updated_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['updated_at'] as int)
            : DateTime.now(),
      );
}
