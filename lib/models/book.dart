/// A locally imported reading document.
class Book {
  final String id;
  final String hash;
  final String title;
  final String author;
  final String? coverUrl;
  final String? description;
  final String? language;
  final String? extension; // pdf, epub, mobi …
  final int? year;
  final String? fileSize; // human-readable, e.g. "3.2 MB"
  final int? pages;
  final String? publisher;
  final double? rating;
  final bool isLocal; // already downloaded?

  /// Local-only fields (populated from SQLite).
  final String? localPath;
  final int? progressPercent;
  final DateTime? lastReadAt;
  final DateTime? downloadDate;

  /// 书架文件夹名（'' = 未分类）。
  final String folder;

  const Book({
    required this.id,
    required this.hash,
    required this.title,
    required this.author,
    this.coverUrl,
    this.description,
    this.language,
    this.extension,
    this.year,
    this.fileSize,
    this.pages,
    this.publisher,
    this.rating,
    this.isLocal = false,
    this.localPath,
    this.progressPercent,
    this.lastReadAt,
    this.downloadDate,
    this.folder = '',
  });

  Book copyWith({
    String? id,
    String? hash,
    String? title,
    String? author,
    String? coverUrl,
    String? description,
    String? language,
    String? extension,
    int? year,
    String? fileSize,
    int? pages,
    String? publisher,
    double? rating,
    bool? isLocal,
    String? localPath,
    int? progressPercent,
    DateTime? lastReadAt,
    DateTime? downloadDate,
    String? folder,
  }) {
    return Book(
      id: id ?? this.id,
      hash: hash ?? this.hash,
      title: title ?? this.title,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      description: description ?? this.description,
      language: language ?? this.language,
      extension: extension ?? this.extension,
      year: year ?? this.year,
      fileSize: fileSize ?? this.fileSize,
      pages: pages ?? this.pages,
      publisher: publisher ?? this.publisher,
      rating: rating ?? this.rating,
      isLocal: isLocal ?? this.isLocal,
      localPath: localPath ?? this.localPath,
      progressPercent: progressPercent ?? this.progressPercent,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      downloadDate: downloadDate ?? this.downloadDate,
      folder: folder ?? this.folder,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'hash': hash,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'description': description,
        'language': language,
        'extension': extension,
        'year': year,
        'fileSize': fileSize,
        'pages': pages,
        'publisher': publisher,
        'rating': rating,
        'isLocal': isLocal,
        'localPath': localPath,
        'progressPercent': progressPercent,
        'lastReadAt': lastReadAt?.millisecondsSinceEpoch,
        'downloadDate': downloadDate?.millisecondsSinceEpoch,
        'folder': folder,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: (json['id'] ?? json['bookId'] ?? '').toString(),
        hash: (json['hash'] ?? '').toString(),
        title: (json['title'] ?? 'Unknown Title').toString(),
        author: (json['author'] ?? 'Unknown Author').toString(),
        coverUrl: json['coverUrl'] as String? ?? json['cover'] as String?,
        description: json['description'] as String?,
        language: json['language'] as String?,
        extension: json['extension'] as String?,
        year: json['year'] is int
            ? json['year'] as int
            : int.tryParse('${json['year']}'),
        fileSize: json['fileSize'] as String? ?? json['filesize'] as String?,
        pages: json['pages'] is int
            ? json['pages'] as int
            : int.tryParse('${json['pages']}'),
        publisher: json['publisher'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        isLocal: json['isLocal'] == true || json['local_path'] != null,
        localPath: json['localPath'] as String? ?? json['local_path'] as String?,
        progressPercent: json['progressPercent'] as int? ??
            json['progress'] as int?,
        lastReadAt: json['lastReadAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastReadAt'] as int)
            : json['last_read'] != null
                ? DateTime.fromMillisecondsSinceEpoch(json['last_read'] as int)
                : null,
        downloadDate: json['downloadDate'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['downloadDate'] as int)
            : json['download_date'] != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    json['download_date'] as int)
                : null,
        folder: (json['folder'] as String?) ?? '',
      );

  /// From SQLite row.
  factory Book.fromDbRow(Map<String, dynamic> row) => Book(
        id: row['id'] as String,
        hash: row['hash'] as String? ?? '',
        title: row['title'] as String,
        author: row['author'] as String,
        coverUrl: row['cover_url'] as String?,
        extension: row['format'] as String?,
        isLocal: true,
        localPath: row['local_path'] as String?,
        progressPercent: row['progress'] as int?,
        lastReadAt: row['last_read'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['last_read'] as int)
            : null,
        downloadDate: row['download_date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(row['download_date'] as int)
            : null,
        folder: row['folder'] as String? ?? '',
      );
}
