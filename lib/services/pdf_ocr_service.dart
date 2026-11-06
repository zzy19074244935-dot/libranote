import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// 扫描版 PDF 的离线 OCR 服务。
///
/// 图片版 PDF 没有文字层：pdfrx 的 loadText 返回空串，导致书内搜索、
/// 选中文字、AI 读取全部失效。本服务补上 OCR：
/// - 渲染：pdfrx 把指定页渲染成 PNG（放大 [scale] 倍、白底，识别率更高）；
/// - 识别：Google ML Kit **离线中文模型**（不依赖 Google Play 服务，
///   华为/小米可用；中文模型同时覆盖拉丁字母）；
/// - 缓存：内存 + 磁盘（Documents/pdf_ocr/<bookId>/p<pageNo>.txt），
///   同一页只识别一次，AI 工具循环重复读页不再耗模型时间。
class PdfOcrService {
  PdfOcrService._();
  static final PdfOcrService instance = PdfOcrService._();

  TextRecognizer? _recognizer;

  /// 内存缓存与进行中请求（同一页并发只识别一次）。
  final Map<String, String> _memCache = {};
  final Map<String, Future<String?>> _inflight = {};

  /// 当前平台是否支持离线 OCR（ML Kit 只支持 Android/iOS）。
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  TextRecognizer _getRecognizer() {
    if (_recognizer != null) return _recognizer!;
    // 中英混排：中文模型兼容拉丁字母。
    _recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    return _recognizer!;
  }

  Future<void> dispose() async {
    try {
      await _recognizer?.close();
    } catch (_) {}
    _recognizer = null;
    _memCache.clear();
    _inflight.clear();
  }

  /// 渲染 PDF 第 [pageNo] 页（1-based）为 PNG 字节。失败返回 null。
  Future<Uint8List?> renderPagePng(String pdfPath, int pageNo,
      {double scale = 1.6}) async {
    PdfDocument? doc;
    try {
      final file = File(pdfPath);
      if (!file.existsSync()) return null;
      doc = await PdfDocument.openFile(pdfPath);
      if (pageNo < 1 || pageNo > doc.pages.length) return null;
      final page = doc.pages[pageNo - 1];
      final w = page.width;
      final h = page.height;
      if (w <= 0 || h <= 0) return null;
      final image = await page.render(
        fullWidth: w * scale,
        fullHeight: h * scale,
        backgroundColor: 0xFFFFFFFF,
      );
      if (image == null) return null;
      final uiImage = await image.createImage();
      image.dispose();
      try {
        final data = await uiImage.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        uiImage.dispose();
      }
    } catch (e) {
      debugPrint('[OCR] render page $pageNo failed: $e');
      return null;
    } finally {
      try {
        await doc?.dispose();
      } catch (_) {}
    }
  }

  /// OCR 一页（内存 + 磁盘缓存）。识别不出文字返回 null。
  Future<String?> ocrPage(String pdfPath, String bookId, int pageNo,
      {double scale = 1.6}) async {
    if (!supported) return null;
    final key = _cacheKey(bookId, pageNo);
    final mem = _memCache[key];
    if (mem != null) return mem.isEmpty ? null : mem;
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    final fut = _ocrUncached(pdfPath, bookId, pageNo, scale: scale);
    _inflight[key] = fut;
    try {
      final text = await fut;
      _memCache[key] = text ?? '';
      return text;
    } finally {
      _inflight.remove(key);
    }
  }

  /// 清掉一页的缓存（用户重新 OCR 想强制刷新时用）。
  Future<void> clearPageCache(String bookId, int pageNo) async {
    final key = _cacheKey(bookId, pageNo);
    _memCache.remove(key);
    try {
      final f = await _diskCacheFile(bookId, pageNo);
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<String?> _ocrUncached(String pdfPath, String bookId, int pageNo,
      {required double scale}) async {
    // 1. 磁盘缓存。
    final cached = await _diskCacheFile(bookId, pageNo);
    if (cached != null && cached.existsSync()) {
      final t = await cached.readAsString();
      if (t.trim().isNotEmpty) return t.trim();
    }
    // 2. 渲染成 PNG。
    final png = await renderPagePng(pdfPath, pageNo, scale: scale);
    if (png == null) return null;
    // 3. ML Kit 识别（fromFilePath 走本地文件，Android/iOS 均可用）。
    final tmp = await getTemporaryDirectory();
    final file = File(p.join(
        tmp.path, 'pdf_ocr_${DateTime.now().microsecondsSinceEpoch}.png'));
    await file.writeAsBytes(png);
    try {
      final recognized =
          await _getRecognizer().processImage(InputImage.fromFilePath(file.path));
      final text = recognized.text.trim();
      if (text.isEmpty) return null;
      // 4. 写磁盘缓存。
      await _writeDiskCache(bookId, pageNo, text);
      return text;
    } catch (e) {
      debugPrint('[OCR] recognize page $pageNo failed: $e');
      return null;
    } finally {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  static String _cacheKey(String bookId, int pageNo) => '$bookId:$pageNo';

  Future<File?> _diskCacheFile(String bookId, int pageNo) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final safe = bookId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      return File(p.join(docs.path, 'pdf_ocr', safe, 'p$pageNo.txt'));
    } catch (e) {
      debugPrint('[OCR] cache dir failed: $e');
      return null;
    }
  }

  Future<void> _writeDiskCache(String bookId, int pageNo, String text) async {
    try {
      final f = await _diskCacheFile(bookId, pageNo);
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
    } catch (e) {
      debugPrint('[OCR] write cache failed: $e');
    }
  }
}
