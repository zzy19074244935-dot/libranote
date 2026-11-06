import 'dart:convert';

/// One text block inside a [Memo], with a named style.
///
/// Style keys map to distinct rendered text styles:
///   h1  标题（大号加粗）
///   h2  小标题（中号加粗）
///   h3  副标题（小号、次要色）
///   p   正文（默认）
///   code 等宽（monospace + 浅底）
class MemoBlock {
  String type;
  String text;

  MemoBlock({this.type = 'p', this.text = ''});

  Map<String, dynamic> toJson() => {'type': type, 'text': text};

  factory MemoBlock.fromJson(Map<String, dynamic> json) => MemoBlock(
        type: (json['type'] as String?) ?? 'p',
        text: (json['text'] as String?) ?? '',
      );
}

/// A standalone memo (备忘录), separate from book annotations.
///
/// Content is a list of styled [MemoBlock]s, persisted as a JSON array string.
class Memo {
  int? id;
  String title;
  List<MemoBlock> blocks;
  String fontFamily; // 'default' | 'serif' | 'mono'
  DateTime createdAt;
  DateTime updatedAt;

  Memo({
    this.id,
    this.title = '',
    List<MemoBlock>? blocks,
    this.fontFamily = 'default',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : blocks = blocks ?? [MemoBlock(type: 'p', text: '')],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  String get contentJson => jsonEncode(blocks.map((b) => b.toJson()).toList());

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': contentJson,
        'font_family': fontFamily,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Memo.fromJson(Map<String, dynamic> json) {
    final raw = json['content'];
    final blocks = <MemoBlock>[];
    if (raw is String && raw.isNotEmpty) {
      try {
        blocks.addAll((jsonDecode(raw) as List)
            .map((e) => MemoBlock.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // Corrupt JSON — fall back to an empty body block.
      }
    } else if (raw is List) {
      blocks.addAll(raw.map((e) =>
          MemoBlock.fromJson((e as Map).cast<String, dynamic>())));
    }
    if (blocks.isEmpty) blocks.add(MemoBlock(type: 'p', text: ''));

    return Memo(
      id: json['id'] as int?,
      title: (json['title'] as String?) ?? '',
      blocks: blocks,
      fontFamily: (json['font_family'] as String?) ?? 'default',
      createdAt: json['created_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['created_at'] as int)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['updated_at'] as int)
          : DateTime.now(),
    );
  }
}
