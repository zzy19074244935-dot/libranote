/// 拍照翻译的一条历史记录（保存在 App 内，照片存
/// `Documents/photo_translate/`，记录进 SQLite）。
class TranslateRecord {
  final int? id;
  final String? imagePath;
  final String sourceText;
  final String translatedText;
  final String target;
  final DateTime createdAt;

  TranslateRecord({
    this.id,
    this.imagePath,
    required this.sourceText,
    required this.translatedText,
    required this.target,
    required this.createdAt,
  });

  Map<String, dynamic> toDbRow() => {
        'image_path': imagePath,
        'source_text': sourceText,
        'translated_text': translatedText,
        'target': target,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory TranslateRecord.fromDbRow(Map<String, dynamic> row) =>
      TranslateRecord(
        id: row['id'] as int?,
        imagePath: row['image_path'] as String?,
        sourceText: (row['source_text'] as String?) ?? '',
        translatedText: (row['translated_text'] as String?) ?? '',
        target: (row['target'] as String?) ?? 'zh-CN',
        createdAt: row['created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int)
            : DateTime.now(),
      );
}
