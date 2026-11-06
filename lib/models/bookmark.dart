import 'annotation.dart';

/// A named reading bookmark that jumps back to a specific position in a book.
///
/// Unlike the implicit reading progress (which only stores a 0–100 percentage),
/// a bookmark stores a structured [AnchorKind] anchor — the same shape the
/// reader already uses for annotations — so it can jump to the exact section
/// or page even after the book is closed and reopened.
class Bookmark {
  final int? id; // auto-increment PK, null until persisted
  final String bookId;
  final String? label; // optional user name, e.g. "第三章开始"
  final AnchorKind kind;
  final int? sectionIndex; // EPUB: 0-based spine index
  final int? pageIndex; // PDF: 1-based page number
  final int? startOffset; // optional character offset (not used for jump yet)
  final DateTime createdAt;

  Bookmark({
    this.id,
    required this.bookId,
    this.label,
    required this.kind,
    this.sectionIndex,
    this.pageIndex,
    this.startOffset,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Human-readable position label for the bookmark list.
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
        'id': id,
        'book_id': bookId,
        'label': label,
        'anchor_kind': kind.name,
        'section_index': sectionIndex,
        'page_index': pageIndex,
        'start_offset': startOffset,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] as int?,
        bookId: json['book_id'] as String,
        label: json['label'] as String?,
        kind: AnchorKind.values.firstWhere(
          (k) => k.name == json['anchor_kind'],
          orElse: () => AnchorKind.plain,
        ),
        sectionIndex: json['section_index'] as int?,
        pageIndex: json['page_index'] as int?,
        startOffset: json['start_offset'] as int?,
        createdAt: json['created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int)
            : DateTime.now(),
      );
}
