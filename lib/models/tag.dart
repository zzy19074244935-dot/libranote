/// 书架标签（Phase 6：AI 工具「列出标签/列出书籍标签/应用书籍标签」的地基
/// + 书详情页标签编辑 UI）。
class BookTag {
  final int? id; // auto-increment PK, null until persisted
  final String name;
  final String color; // '#4ade80' 等

  const BookTag({this.id, this.name = '', this.color = '#4ade80'});

  BookTag copyWith({int? id, String? name, String? color}) => BookTag(
        id: id ?? this.id,
        name: name ?? this.name,
        color: color ?? this.color,
      );
}
