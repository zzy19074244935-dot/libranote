/// 拍照生成的单词卡片。
///
/// 服务端（火山函数计算）合成卡片图并返回 TOS 公网链接；App 把图片与
/// 音频下载到本地文件后入库，离线也能查看/朗读。URL 字段保留作回退
/// （本地文件被系统清理时可重新下载）。
class WordCard {
  int? id;
  String chineseWord;
  String englishWord;
  String ukPhonetic;
  String usPhonetic;
  String definition; // 英文释义（简短，适合初学者）
  String chineseDefinition; // 中文释义
  String cardImageUrl;
  String? cardImagePath; // 本地文件路径
  String? ukAudioUrl;
  String? ukAudioPath;
  String? usAudioUrl;
  String? usAudioPath;
  DateTime createdAt;

  WordCard({
    this.id,
    this.chineseWord = '',
    this.englishWord = '',
    this.ukPhonetic = '',
    this.usPhonetic = '',
    this.definition = '',
    this.chineseDefinition = '',
    this.cardImageUrl = '',
    this.cardImagePath,
    this.ukAudioUrl,
    this.ukAudioPath,
    this.usAudioUrl,
    this.usAudioPath,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 卡片图是否已在本地。
  bool get hasLocalImage =>
      cardImagePath != null && cardImagePath!.isNotEmpty;

  Map<String, dynamic> toDbRow() => {
        'chinese_word': chineseWord,
        'english_word': englishWord,
        'uk_phonetic': ukPhonetic,
        'us_phonetic': usPhonetic,
        'definition': definition,
        'chinese_definition': chineseDefinition,
        'card_image_url': cardImageUrl,
        'card_image_path': cardImagePath,
        'uk_audio_url': ukAudioUrl,
        'uk_audio_path': ukAudioPath,
        'us_audio_url': usAudioUrl,
        'us_audio_path': usAudioPath,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory WordCard.fromDbRow(Map<String, dynamic> row) => WordCard(
        id: row['id'] as int?,
        chineseWord: (row['chinese_word'] as String?) ?? '',
        englishWord: (row['english_word'] as String?) ?? '',
        ukPhonetic: (row['uk_phonetic'] as String?) ?? '',
        usPhonetic: (row['us_phonetic'] as String?) ?? '',
        definition: (row['definition'] as String?) ?? '',
        chineseDefinition: (row['chinese_definition'] as String?) ?? '',
        cardImageUrl: (row['card_image_url'] as String?) ?? '',
        cardImagePath: row['card_image_path'] as String?,
        ukAudioUrl: row['uk_audio_url'] as String?,
        ukAudioPath: row['uk_audio_path'] as String?,
        usAudioUrl: row['us_audio_url'] as String?,
        usAudioPath: row['us_audio_path'] as String?,
        createdAt: row['created_at'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int)
            : DateTime.now(),
      );
}
