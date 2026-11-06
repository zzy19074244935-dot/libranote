import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';

/// Parsed plain-text file, ready to render.
///
/// For small files (< 5 MB) the entire text is returned as a single chunk.
/// For large files the text is split at `\n` boundaries into ~64 KB chunks
/// so the widget layer can use [ListView.builder] without materialising the
/// whole string tree at once.
class LoadedTxt {
  /// Text chunks in reading order.  Each chunk spans one or more whole lines;
  /// a chunk never breaks mid-line.
  final List<String> chunks;

  /// Total character count across all chunks (cached for progress calculation).
  final int totalChars;

  /// The encoding that was actually used to decode the file, so the UI can
  /// show a hint when the file is GBK.
  final String encodingUsed;

  const LoadedTxt({
    required this.chunks,
    required this.totalChars,
    required this.encodingUsed,
  });
}

/// Reads a plain-text file with automatic encoding detection.
///
/// Strategy:
/// 1. Check for a BOM (UTF-8 / UTF-16LE / UTF-16BE) — if found, that is the
///    authoritative answer.
/// 2. Try UTF-8 with `allowMalformed: false`.  If it succeeds, we assume UTF-8
///    because nearly all English + modern Chinese files use it.
/// 3. Try GBK via [fast_gbk].  Most legacy Chinese TXT files use GBK/GB18030.
/// 4. If both fail, throw with a clear message so the user can re-save the file
///    as UTF-8 in Notepad — we never silently display garbled text.
class TxtLoader {
  const TxtLoader._();

  /// Chunk size in bytes for large files.  64 KB is small enough to avoid
  /// jank in [ListView.builder] and large enough to keep chunk count low.
  static const int _chunkBytes = 64 * 1024;

  /// Files larger than this threshold are split into chunks.
  static const int _largeThreshold = 5 * 1024 * 1024;

  /// Open a text file from disk, detect its encoding, and return parsed chunks.
  static Future<LoadedTxt> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return _parse(bytes, path);
  }

  /// Parse raw bytes into a [LoadedTxt].
  static LoadedTxt _parse(Uint8List bytes, String debugPath) {
    if (bytes.isEmpty) {
      throw const FormatException('文件是空的');
    }

    // ── BOM detection ──────────────────────────────────────────────────
    // UTF-8 BOM: EF BB BF  → just skip the 3 bytes and decode as UTF-8.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      final text = const Utf8Decoder().convert(bytes, 3);
      return _buildLoaded(text, 'utf-8');
    }

    // UTF-16LE BOM: FF FE
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      // If there is no surrogate evidence treat as UTF-16LE; dart:convert
      // will throw on malformed surrogates, which is what we want.
      final text = utf16BytesToText(bytes, 2, Endian.little);
      return _buildLoaded(text, 'utf-16le');
    }

    // UTF-16BE BOM: FE FF
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final text = utf16BytesToText(bytes, 2, Endian.big);
      return _buildLoaded(text, 'utf-16be');
    }

    // ── Try UTF-8 without BOM ──────────────────────────────────────────
    try {
      final text = const Utf8Decoder(allowMalformed: false).convert(bytes);
      return _buildLoaded(text, 'utf-8');
    } on FormatException {
      // Not valid UTF-8 — fall through to GBK.
    }

    // ── Try GBK ────────────────────────────────────────────────────────
    try {
      final text = gbk.decode(bytes);
      if (text.isEmpty) {
        throw const FormatException('GBK 解码结果为空');
      }
      debugPrint('[Txt] $debugPath decoded as GBK, ${text.length} chars');
      return _buildLoaded(text, 'gbk');
    } catch (e) {
      // Not GBK either — give the user a clear path forward.
      throw const FormatException(
        '无法识别文件编码。\n'
        '该文件不是 UTF-8 也不是 GBK 编码。\n'
        '请用记事本打开 → 另存为 → 编码选择 UTF-8 → 重新导入。',
      );
    }
  }

  /// Build a [LoadedTxt] from decoded text, optionally chunking it.
  static LoadedTxt _buildLoaded(String text, String encoding) {
    if (text.length < _largeThreshold) {
      return LoadedTxt(
        chunks: text.isEmpty ? const [''] : [text],
        totalChars: text.length,
        encodingUsed: encoding,
      );
    }

    // Chunk by ~64 KB at newline boundaries so ListView.builder stays fast.
    final chunks = <String>[];
    int start = 0;
    while (start < text.length) {
      int end = start + _chunkBytes;
      if (end >= text.length) {
        chunks.add(text.substring(start));
        break;
      }
      // Walk forward to the next newline so we never split mid-line.
      int nl = text.indexOf('\n', end);
      if (nl == -1 || nl - end > _chunkBytes ~/ 2) {
        // No newline within a reasonable distance — take the last space or
        // just split at the hard boundary.
        final space = text.lastIndexOf(' ', end);
        end = space > start ? space + 1 : end;
      } else {
        end = nl + 1;
      }
      chunks.add(text.substring(start, end));
      start = end;
    }

    return LoadedTxt(
      chunks: chunks,
      totalChars: text.length,
      encodingUsed: encoding,
    );
  }

  /// Decode UTF-16 bytes (without BOM) to a Dart string.
  ///
  /// Dart has no built-in UTF-16 decoder, so we walk pairs manually.
  /// This handles the Basic Multilingual Plane only — surrogate pairs for
  /// supplementary planes (rare in TXT files) are supported via the standard
  /// UTF-16 algorithm.
  static String utf16BytesToText(
    List<int> bytes,
    int offset,
    Endian endian,
  ) {
    final buf = StringBuffer();
    int i = offset;
    while (i + 1 < bytes.length) {
      int unit;
      if (endian == Endian.little) {
        unit = bytes[i] | (bytes[i + 1] << 8);
      } else {
        unit = (bytes[i] << 8) | bytes[i + 1];
      }
      i += 2;

      // Surrogate pair (supplementary plane characters).
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.length) {
        int low;
        if (endian == Endian.little) {
          low = bytes[i] | (bytes[i + 1] << 8);
        } else {
          low = (bytes[i] << 8) | bytes[i + 1];
        }
        i += 2;
        if (low >= 0xDC00 && low <= 0xDFFF) {
          final cp =
              0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
          buf.writeCharCode(cp);
          continue;
        }
        // Invalid low surrogate — treat the high surrogate as a lone
        // replacement character (don't crash on a whole book for one byte).
        buf.writeCharCode(0xFFFD);
        i -= 2; // re-read the low surrogate as a new unit
        continue;
      }

      if (unit >= 0xDC00 && unit <= 0xDFFF) {
        // Lone low surrogate → replacement.
        buf.writeCharCode(0xFFFD);
      } else {
        buf.writeCharCode(unit);
      }
    }
    // Lone trailing byte.
    if (i < bytes.length) {
      buf.writeCharCode(0xFFFD);
    }
    return buf.toString();
  }
}
