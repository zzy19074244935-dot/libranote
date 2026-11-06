/// readest 引擎的书内笔记（CFI 锚点：高亮/划线/波浪线 + 笔记正文）。
class ReadestNote {
  int? id;
  final String bookId;
  final String cfi;
  final String text; // 选中原文
  final String? color; // '#facc15' 等
  final String style; // 'highlight' | 'underline' | 'squiggly'
  final String note; // 笔记正文（可为空 = 纯高亮）

  /// 选中截图（可选）：与笔记捆绑保存（方案 §2.8 四要素）。
  final String? imagePath;
  final DateTime createdAt;
  final DateTime updatedAt;

  ReadestNote({
    this.id,
    required this.bookId,
    required this.cfi,
    this.text = '',
    this.color,
    this.style = 'highlight',
    this.note = '',
    this.imagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  ReadestNote copyWith(
          {String? note, String? color, String? style, String? imagePath}) =>
      ReadestNote(
        id: id,
        bookId: bookId,
        cfi: cfi,
        text: text,
        color: color ?? this.color,
        style: style ?? this.style,
        note: note ?? this.note,
        imagePath: imagePath ?? this.imagePath,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toDbRow() => {
        'book_id': bookId,
        'cfi': cfi,
        'text': text,
        'color': color,
        'style': style,
        'note': note,
        'image_path': imagePath,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory ReadestNote.fromDbRow(Map<String, dynamic> row) => ReadestNote(
        id: row['id'] as int?,
        bookId: (row['book_id'] as String?) ?? '',
        cfi: (row['cfi'] as String?) ?? '',
        text: (row['text'] as String?) ?? '',
        color: row['color'] as String?,
        style: (row['style'] as String?) ?? 'highlight',
        note: (row['note'] as String?) ?? '',
        imagePath: row['image_path'] as String?,
        createdAt: row['created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int)
            : DateTime.now(),
        updatedAt: row['updated_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int)
            : DateTime.now(),
      );
}
