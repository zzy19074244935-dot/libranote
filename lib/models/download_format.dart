/// A downloadable format returned by /eapi/book/{id}/{hash}/formats
class DownloadFormat {
  final String id;
  final String extension; // epub, pdf, mobi, fb2, …
  final String url;
  final String? fileSize;
  final String? filename;

  const DownloadFormat({
    required this.id,
    required this.extension,
    required this.url,
    this.fileSize,
    this.filename,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'extension': extension,
        'url': url,
        'fileSize': fileSize,
        'filename': filename,
      };

  factory DownloadFormat.fromJson(Map<String, dynamic> json) => DownloadFormat(
        id: (json['id'] ?? '').toString(),
        extension: (json['extension'] ?? '').toString().toLowerCase(),
        url: (json['url'] ?? json['downloadUrl'] ?? '').toString(),
        fileSize: json['fileSize'] as String? ?? json['filesize'] as String?,
        filename: json['filename'] as String? ?? json['fileName'] as String?,
      );

  /// Convenience: is this an EPUB variant?
  bool get isEpub => extension == 'epub';

  /// Convenience: is this a PDF?
  bool get isPdf => extension == 'pdf';
}
