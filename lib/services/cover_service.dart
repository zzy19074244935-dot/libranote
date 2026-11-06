import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' as archive;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

/// Extracts cover thumbnails from local EPUB/PDF files.
///
/// EPUB files are ZIP containers.  We read the container metadata to locate
/// the cover image, extract it, and cache it as a PNG thumbnail on disk.
/// PDF 封面用 pdfrx 把第一页渲染成小图缓存。
class CoverService {
  CoverService._();
  static final CoverService _instance = CoverService._();
  static CoverService get instance => _instance;

  Directory? _cacheDir;

  Future<Directory> get _thumbDir async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    return _cacheDir!;
  }

  /// Return the cached thumbnail path for [bookId], or `null` if not found.
  Future<String?> getThumbnailPath(String bookId) async {
    final dir = await _thumbDir;
    final thumbFile = File(p.join(dir.path, '$bookId.png'));
    if (await thumbFile.exists()) return thumbFile.path;
    return null;
  }

  /// Extract and cache a thumbnail for a local book file.
  ///
  /// Returns the thumbnail path on success, `null` on failure.
  Future<String?> extractThumbnail({
    required String bookId,
    required String filePath,
    required String format, // 'epub' or 'pdf'
  }) async {
    try {
      final dir = await _thumbDir;
      final thumbPath = p.join(dir.path, '$bookId.png');

      Uint8List? imageBytes;
      switch (format.toLowerCase()) {
        case 'epub':
          imageBytes = await _extractEpubCover(filePath);
          break;
        case 'pdf':
          imageBytes = await _extractPdfCover(filePath);
          break;
        default:
          return null;
      }

      if (imageBytes == null || imageBytes.isEmpty) return null;

      final thumbFile = File(thumbPath);
      await thumbFile.writeAsBytes(imageBytes);
      debugPrint('[Cover] Thumbnail cached: $thumbPath (${imageBytes.length} bytes)');
      return thumbPath;
    } catch (e) {
      debugPrint('[Cover] Failed to extract thumbnail for $bookId: $e');
      return null;
    }
  }

  /// Extract the cover image from an EPUB file.
  ///
  /// Steps:
  /// 1. Open EPUB as ZIP
  /// 2. Parse META-INF/container.xml → find OPF path
  /// 3. Parse OPF → find cover image item
  /// 4. Extract cover image bytes
  Future<Uint8List?> _extractEpubCover(String epubPath) async {
    final file = File(epubPath);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    final zip = archive.ZipDecoder().decodeBytes(bytes);

    // Step 1: Find container.xml
    final containerFile = zip.findFile('META-INF/container.xml');
    if (containerFile == null) {
      debugPrint('[Cover] No META-INF/container.xml found in EPUB');
      return null;
    }

    final containerXml = utf8.decode(containerFile.content as List<int>);
    final rootfileMatch = RegExp(
      r'rootfile[^>]*full-path="([^"]*)"',
    ).firstMatch(containerXml);
    if (rootfileMatch == null) {
      debugPrint('[Cover] No rootfile in container.xml');
      return null;
    }

    final opfPath = rootfileMatch.group(1)!;
    debugPrint('[Cover] OPF path: $opfPath');
    final opfDir = p.dirname(opfPath);

    // Step 2: Find the OPF file in the ZIP
    final opfFile = zip.findFile(opfPath);
    if (opfFile == null) {
      debugPrint('[Cover] OPF file not found: $opfPath');
      return null;
    }

    final opfXml = utf8.decode(opfFile.content as List<int>);

    // Step 3: Find cover ID from <meta name="cover" content="…"/>
    final coverIdMatch = RegExp(
      r'<meta[^>]*name="cover"[^>]*content="([^"]*)"',
    ).firstMatch(opfXml);
    String? coverId = coverIdMatch?.group(1);
    debugPrint('[Cover] Cover ID from meta: $coverId');

    // Step 4: Find cover image href from manifest item
    String? coverHref;
    if (coverId != null) {
      final itemPattern = RegExp(
        '<item[^>]*id="$coverId"[^>]*href="([^"]*)"[^>]*>',
      );
      final itemMatch = itemPattern.firstMatch(opfXml);
      coverHref = itemMatch?.group(1);
    }

    // Fallback: look for cover image by properties (EPUB3)
    if (coverHref == null) {
      final propMatch = RegExp(
        r'<item[^>]*properties="[^"]*cover-image[^"]*"[^>]*href="([^"]*)"',
      ).firstMatch(opfXml);
      coverHref = propMatch?.group(1);
    }

    // Fallback: look for item with id containing "cover"
    if (coverHref == null) {
      final idMatch = RegExp(
        r'<item[^>]*id="[^"]*cover[^"]*"[^>]*href="([^"]*)"',
        caseSensitive: false,
      ).firstMatch(opfXml);
      coverHref = idMatch?.group(1);
      if (coverHref != null) debugPrint('[Cover] Cover found by id fallback');
    }

    // Fallback: just look for "cover" in image filenames
    if (coverHref == null) {
      for (final f in zip) {
        final name = f.name.toLowerCase();
        if ((name.contains('cover') || name.contains('title')) &&
            (name.endsWith('.jpg') ||
                name.endsWith('.jpeg') ||
                name.endsWith('.png') ||
                name.endsWith('.webp'))) {
          debugPrint('[Cover] Cover found by filename: ${f.name}');
          return Uint8List.fromList(f.content as List<int>);
        }
      }
    }

    if (coverHref == null) {
      debugPrint('[Cover] Could not locate cover image in EPUB');
      return null;
    }

    // Step 5: Resolve path and extract
    final coverPath = coverHref.contains('/')
        ? coverHref
        : (opfDir == '.' ? coverHref : '$opfDir/$coverHref');
    debugPrint('[Cover] Looking for cover at: $coverPath');

    final imageFile = zip.findFile(coverPath);
    if (imageFile != null) {
      return Uint8List.fromList(imageFile.content as List<int>);
    }

    // Try with path segments URL-decoded
    final segments = coverPath.split('/');
    for (final f in zip) {
      if (f.name.endsWith(segments.last) &&
          (f.name.endsWith('.jpg') ||
              f.name.endsWith('.jpeg') ||
              f.name.endsWith('.png') ||
              f.name.endsWith('.webp'))) {
        debugPrint('[Cover] Cover found by filename match: ${f.name}');
        return Uint8List.fromList(f.content as List<int>);
      }
    }

    debugPrint('[Cover] Cover image file not found: $coverPath');
    return null;
  }

  /// 把 PDF 第一页渲染成 PNG 缩略图（最大边 600 像素，书架封面够用）。
  ///
  /// 扫描版 PDF 第一页通常就是封面；文字版渲染出的首页也直观。失败返回
  /// null（书架再兜底用网络封面/占位图）。
  Future<Uint8List?> _extractPdfCover(String pdfPath) async {
    PdfDocument? doc;
    try {
      final file = File(pdfPath);
      if (!await file.exists()) return null;
      doc = await PdfDocument.openFile(pdfPath);
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final w = page.width;
      final h = page.height;
      if (w <= 0 || h <= 0) return null;
      const maxDim = 600.0;
      final scale = maxDim / (w > h ? w : h);
      final image = await page.render(
        fullWidth: w * scale,
        fullHeight: h * scale,
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) return null;
      final uiImage = await image.createImage();
      try {
        final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        uiImage.dispose();
      }
    } catch (e) {
      debugPrint('[Cover] pdf thumbnail failed: $e');
      return null;
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
    }
  }
}
