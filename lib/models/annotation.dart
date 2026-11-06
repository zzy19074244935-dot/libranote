import 'dart:convert';

/// What kind of document a [TextAnchor] points into.
enum AnchorKind { epub, pdf, plain }

/// A normalised rectangle (0–1), independent of zoom / DPI.
class NormRect {
  final double l, t, r, b;

  const NormRect({
    required this.l,
    required this.t,
    required this.r,
    required this.b,
  });

  Map<String, dynamic> toJson() => {'l': l, 't': t, 'r': r, 'b': b};

  factory NormRect.fromJson(Map<String, dynamic> json) => NormRect(
        l: (json['l'] as num).toDouble(),
        t: (json['t'] as num).toDouble(),
        r: (json['r'] as num).toDouble(),
        b: (json['b'] as num).toDouble(),
      );

  static List<NormRect> listFromJson(String? json) {
    if (json == null || json.isEmpty) return [];
    return (jsonDecode(json) as List)
        .map((e) => NormRect.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJson(List<NormRect> rects) =>
      jsonEncode(rects.map((r) => r.toJson()).toList());
}

/// Structured anchor that can navigate back to the exact spot in a book.
///
/// The primary anchor (sectionIndex / pageIndex / offsets) may drift when the
/// parser or the source file changes, so every anchor also stores a
/// [prefix] + [quotedText] + [suffix] fingerprint that can be fuzzy-matched
/// as a fallback (S5).
class TextAnchor {
  final AnchorKind kind;

  /// EPUB: 0-based index into the spine.
  final int? sectionIndex;

  /// PDF: 1-based page number.
  final int? pageIndex;

  /// Character offset into the *plain text* (not HTML) of the section / page.
  /// For EPUB this is relative to [EpubLoader.plainText].
  final int? startOffset;
  final int? endOffset;

  /// PDF highlight rectangles, normalised 0–1.
  final List<NormRect> rects;

  /// Fallback fingerprint: up to 24 characters before and after the selection.
  final String? prefix;
  final String? suffix;

  const TextAnchor({
    required this.kind,
    this.sectionIndex,
    this.pageIndex,
    this.startOffset,
    this.endOffset,
    this.rects = const [],
    this.prefix,
    this.suffix,
  });

  /// Human-readable label for UI.
  String get display {
    switch (kind) {
      case AnchorKind.epub:
        if (sectionIndex != null) return '第 ${sectionIndex! + 1} 节';
        return 'EPUB';
      case AnchorKind.pdf:
        if (pageIndex != null) return '第 $pageIndex 页';
        return 'PDF';
      case AnchorKind.plain:
        return '当前位置';
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (sectionIndex != null) 'section_index': sectionIndex,
        if (pageIndex != null) 'page_index': pageIndex,
        if (startOffset != null) 'start_offset': startOffset,
        if (endOffset != null) 'end_offset': endOffset,
        if (rects.isNotEmpty) 'rects': NormRect.listToJson(rects),
        if (prefix != null) 'prefix': prefix,
        if (suffix != null) 'suffix': suffix,
      };

  factory TextAnchor.fromJson(Map<String, dynamic> json) => TextAnchor(
        kind: AnchorKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => AnchorKind.plain,
        ),
        sectionIndex: json['section_index'] as int?,
        pageIndex: json['page_index'] as int?,
        startOffset: json['start_offset'] as int?,
        endOffset: json['end_offset'] as int?,
        rects: NormRect.listFromJson(json['rects'] as String?),
        prefix: json['prefix'] as String?,
        suffix: json['suffix'] as String?,
      );
}

/// A highlight or note attached to a book.
///
/// [quotedText] is the selected original text. [note] is the user's own
/// commentary (empty for pure highlights). [anchor] stores the structured
/// position so the reader can jump back to it.
///
/// Backward compatibility: the old `location` and `text` columns are still
/// written on every insert (SQLite in its default configuration does not
/// support DROP COLUMN, and both columns are NOT NULL with no default —
/// omitting them would break INSERT for existing databases). Old rows read
/// back get a plain anchor and `quotedText` from the legacy `text` column.
class Annotation {
  final int? id; // auto-increment PK, null until persisted
  final String bookId;

  /// Redundant copy of the book title so the notes centre can show it without
  /// joining the bookshelf table (and so notes survive book deletion).
  final String? bookTitle;

  final AnnotationType type;
  final TextAnchor anchor;
  final String quotedText; // the highlighted passage
  final String note; // user commentary, may be empty
  final String? color; // #RRGGBB

  /// 标注样式：'highlight'（高亮）/ 'underline'（下划线）/ 'squiggly'
  /// （波浪线）。与 readest 引擎同款三态。
  final String style;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 来源：'manual' = 划词高亮/文字笔记；'ink' = PDF 手写批注的合成条目
  /// （由 syncPdfInkAnnotation 维护，quoted_text 为空、note 是摘要）。
  final String source;

  /// 选区截图路径（可选）：选中文字 → 截图 → 再高亮/记笔记时捆绑保存
  /// （方案 §2.8 四要素：原文 + 截图 + 笔记 + AI 内容）。
  final String? imagePath;

  /// Backward-compatible getter — old UI code reads [location] directly.
  String get location => anchor.display;

  /// Old code reads [text]; now returns [quotedText].
  String get text => quotedText;

  Annotation({
    this.id,
    required this.bookId,
    this.bookTitle,
    required this.type,
    required this.anchor,
    required this.quotedText,
    this.note = '',
    this.color,
    this.style = 'highlight',
    this.tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    this.source = 'manual',
    this.imagePath,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Annotation copyWith({
    int? id,
    String? bookId,
    String? bookTitle,
    AnnotationType? type,
    TextAnchor? anchor,
    String? quotedText,
    String? note,
    String? color,
    String? style,
    List<String>? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? source,
    String? imagePath,
  }) {
    return Annotation(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      bookTitle: bookTitle ?? this.bookTitle,
      type: type ?? this.type,
      anchor: anchor ?? this.anchor,
      quotedText: quotedText ?? this.quotedText,
      note: note ?? this.note,
      color: color ?? this.color,
      style: style ?? this.style,
      tags: tags ?? this.tags,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      source: source ?? this.source,
      imagePath: imagePath ?? this.imagePath,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'book_title': bookTitle,
        'type': type.name,
        'location': anchor.display, // legacy column, NOT NULL, must be present
        'text': quotedText, // legacy column, NOT NULL, must be present
        'anchor_kind': anchor.kind.name,
        'section_index': anchor.sectionIndex,
        'page_index': anchor.pageIndex,
        'start_offset': anchor.startOffset,
        'end_offset': anchor.endOffset,
        'rects': anchor.rects.isNotEmpty
            ? NormRect.listToJson(anchor.rects)
            : null,
        'prefix': anchor.prefix,
        'suffix': anchor.suffix,
        'quoted_text': quotedText,
        'note': note,
        'color': color,
        'style': style,
        'tags': tags.isNotEmpty ? jsonEncode(tags) : null,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'source': source,
        'image_path': imagePath,
      };

  factory Annotation.fromJson(Map<String, dynamic> json) {
    // Parse anchor: prefer new structured columns, fall back to old location.
    final TextAnchor anchor;
    if (json['anchor_kind'] != null) {
      anchor = TextAnchor.fromJson({
        'kind': json['anchor_kind'],
        'section_index': json['section_index'],
        'page_index': json['page_index'],
        'start_offset': json['start_offset'],
        'end_offset': json['end_offset'],
        'rects': json['rects'],
        'prefix': json['prefix'],
        'suffix': json['suffix'],
      });
    } else {
      // Pre-migration row — build a plain anchor; `location` getter still works
      // because `anchor.display` falls back to '当前位置' for plain kind.
      anchor = const TextAnchor(kind: AnchorKind.plain);
    }

    // Tags: may be a JSON-encoded list or already decoded by sqflite.
    List<String> tags;
    final rawTags = json['tags'];
    if (rawTags == null) {
      tags = [];
    } else if (rawTags is String) {
      try {
        tags = (jsonDecode(rawTags) as List).map((e) => e.toString()).toList();
      } catch (_) {
        tags = [];
      }
    } else if (rawTags is List) {
      tags = rawTags.map((e) => e.toString()).toList();
    } else {
      tags = [];
    }

    return Annotation(
      id: json['id'] as int?,
      bookId: json['book_id'] as String,
      bookTitle: json['book_title'] as String?,
      type: AnnotationType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => AnnotationType.highlight,
      ),
      anchor: anchor,
      quotedText: (json['quoted_text'] ?? json['text'] ?? '') as String,
      note: (json['note'] ?? '') as String,
      color: json['color'] as String?,
      style: (json['style'] as String?) ?? 'highlight',
      tags: tags,
      createdAt: json['created_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updated_at'] as int)
          : DateTime.now(),
      source: (json['source'] as String?) ?? 'manual',
      imagePath: json['image_path'] as String?,
    );
  }
}

enum AnnotationType { highlight, note }
