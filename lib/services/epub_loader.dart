import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/annotation.dart';

/// Plain text produced from an XHTML string, with a mapping from every plain
/// character back to its position in the original HTML.
///
/// The mapping is the critical piece for S5 highlight rendering: when we know
/// the `startOffset`/`endOffset` in plain text we use [htmlIndex] to convert
/// those back to HTML positions so we can insert `<mark>` tags without
/// corrupting the markup.
///
/// Rules:
/// - `<script>` and `<style>` blocks are discarded entirely.
/// - Block-level tag boundaries emit a `\n` into the plain text.
/// - Consecutive whitespace is collapsed to a single space.
class PlainText {
  /// The extracted human-readable text.
  final String text;

  /// [htmlIndex][i] = the byte offset in the original HTML string that
  /// produced [text][i]. Length equals [text].length.
  final List<int> htmlIndex;

  const PlainText({required this.text, required this.htmlIndex});
}

/// One document from the EPUB spine — i.e. one XHTML file of the book.
class EpubSection {
  /// Normalised path inside the archive, e.g. `OEBPS/Text/part0005.xhtml`.
  final String href;

  /// Raw XHTML, handed to the renderer as-is.
  final String html;

  /// Human-readable label: the NCX entry if there is one, otherwise the first
  /// heading found in the document, otherwise a positional fallback.
  final String title;

  /// Whether [title] came from the book's own table of contents.
  final bool fromToc;

  EpubSection({
    required this.href,
    required this.html,
    required this.title,
    required this.fromToc,
  });

  // ── Lazily computed plain text view ─────────────────────────────────

  PlainText? _plain;

  /// The XHTML body as plain text with a mapping back to HTML positions.
  ///
  /// Computed once on first access; cached because the HTML doesn't change.
  PlainText get plain => _plain ??= EpubLoader.plainText(html);
}

/// A parsed EPUB, ready to render.
class LoadedEpub {
  final String? title;
  final String? author;

  /// Every spine document, in reading order.
  final List<EpubSection> sections;

  /// The archive, kept open so images can be resolved lazily while reading.
  final Archive _archive;

  LoadedEpub({
    required this.title,
    required this.author,
    required this.sections,
    required Archive archive,
  }) : _archive = archive;

  /// Resolve an `<img src="…">` against the document that referenced it.
  Uint8List? imageBytes(String src, String fromHref) {
    final resolved = EpubLoader.resolve(p.dirname(fromHref), src);
    final file = _archive.findFile(resolved) ??
        _archive.findFile(Uri.decodeComponent(resolved));
    if (file == null) return null;
    final content = file.content;
    return content is Uint8List ? content : Uint8List.fromList(content as List<int>);
  }
}

/// Reads an EPUB by walking the **spine**, not the table of contents.
///
/// This is the whole point of the class. `epub_view` (and `epubx` underneath
/// it) builds the book from the NCX `navMap`, so anything the publisher left
/// out of the table of contents is silently unreachable. Real-world files do
/// that constantly — the 三体全集 test file declares 62 spine documents and
/// exactly 4 navPoints, so an NCX-driven reader shows four part-title pages
/// and none of the actual chapters.
///
/// The spine, by contrast, is required by the EPUB spec to list every document
/// in reading order, so it is the only reliable source of content. The NCX is
/// still read, but only to *label* sections.
class EpubLoader {
  const EpubLoader._();

  static Future<LoadedEpub> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return open(bytes);
  }

  static Future<LoadedEpub> open(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1 ── container.xml points at the package document (OPF).
    final containerXml = _readString(archive, 'META-INF/container.xml');
    if (containerXml == null) {
      throw const FormatException('缺少 META-INF/container.xml，不是有效的 EPUB');
    }
    final opfPath = XmlDocument.parse(containerXml)
        .findAllElements('rootfile')
        .map((e) => e.getAttribute('full-path'))
        .firstWhere((v) => v != null && v.isNotEmpty,
            orElse: () => throw const FormatException('EPUB 缺少 rootfile 声明'))!;

    final opfXml = _readString(archive, opfPath);
    if (opfXml == null) {
      throw FormatException('读不到 $opfPath');
    }
    final opf = XmlDocument.parse(opfXml);
    final opfDir = p.url.dirname(opfPath);

    // 2 ── manifest: id → href / media-type.
    final hrefById = <String, String>{};
    final typeById = <String, String>{};
    final propsById = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      hrefById[id] = resolve(opfDir, href);
      typeById[id] = item.getAttribute('media-type') ?? '';
      propsById[id] = item.getAttribute('properties') ?? '';
    }

    // 3 ── spine: the reading order.
    final spineIds = <String>[];
    String? ncxId;
    for (final spine in opf.findAllElements('spine')) {
      ncxId ??= spine.getAttribute('toc');
      for (final ref in spine.findAllElements('itemref')) {
        final idref = ref.getAttribute('idref');
        if (idref != null) spineIds.add(idref);
      }
    }

    // 4 ── labels from the table of contents, if the book has a usable one.
    final tocLabels = _readTocLabels(archive, opf, hrefById, typeById,
        propsById, ncxId, opfDir);

    // 5 ── build the sections.
    final sections = <EpubSection>[];
    for (final id in spineIds) {
      final href = hrefById[id];
      if (href == null) continue;
      final type = typeById[id] ?? '';
      if (type.isNotEmpty &&
          !type.contains('xhtml') &&
          !type.contains('html')) {
        continue;
      }
      final html = _readString(archive, href);
      if (html == null || html.trim().isEmpty) continue;

      final tocLabel = tocLabels[href];
      sections.add(EpubSection(
        href: href,
        html: html,
        title: tocLabel ??
            _firstHeading(html) ??
            '第 ${sections.length + 1} 节',
        fromToc: tocLabel != null,
      ));
    }

    if (sections.isEmpty) {
      throw const FormatException('EPUB 里没有找到任何正文文件');
    }

    final meta = _metadata(opf);
    debugPrint('[Epub] ${sections.length} spine sections, '
        '${tocLabels.length} toc labels');

    return LoadedEpub(
      title: meta.$1,
      author: meta.$2,
      sections: sections,
      archive: archive,
    );
  }

  /// Join a relative href against a directory inside the archive.
  ///
  /// Archive entries always use `/`, so this stays on [p.url] rather than the
  /// platform separator — otherwise every lookup fails on Windows.
  static String resolve(String dir, String href) {
    final clean = href.split('#').first;
    final decoded = Uri.decodeComponent(clean);
    if (dir.isEmpty || dir == '.') return p.url.normalize(decoded);
    return p.url.normalize(p.url.join(dir, decoded));
  }

  /// Insert highlight `<span>` tags into [html] using plain-text offsets.
  ///
  /// Each annotation whose offsets map into [plain] gets a
  /// `<span style="background-color: …">…</span>` wrapped around its quoted
  /// text. Insertions are processed in descending [htmlStart] order so earlier
  /// inserts do not shift the positions of later ones.
  ///
  /// [flashId], when set, causes that one annotation to render with a strong
  /// [flashColor] background (跳转定位时的闪烁) so the reader can spot it.
  /// 用背景色而不是 CSS outline 做闪烁——flutter_html 对 outline 支持不稳，
  /// 之前的「回跳看不到高亮」就是这样来的。
  ///
  /// 自愈：偏移对不上当前章节（书换过版本、旧版算法漂移）时，用 quotedText /
  /// prefix+suffix 反查修复；实在找不到就静默跳过。渲染永远不允许抛异常。
  static String withHighlights(
    String html,
    PlainText plain,
    List<Annotation> annotations, {
    int? flashId,
    Color? flashColor,
  }) {
    if (annotations.isEmpty) return html;

    final inserts = <_HtmlInsert>[];

    for (final a in annotations) {
      if (a.anchor.kind != AnchorKind.epub) continue;
      var start = a.anchor.startOffset;
      var end = a.anchor.endOffset;

      // 偏移缺失或失效 → 用文本反查修复一次。
      if (start == null ||
          end == null ||
          start < 0 ||
          end > plain.htmlIndex.length ||
          start >= end ||
          plain.htmlIndex[start] >= plain.htmlIndex[end - 1]) {
        final fixed = _locateOffsets(a, plain);
        if (fixed == null) continue;
        start = fixed.$1;
        end = fixed.$2;
      }

      // 再校验一次：偏移圈住的原文是否与 quotedText 一致（忽略空白差异）。
      // 不一致说明偏移是旧版算法在「压空白字符串」里算出来的错位值，
      // 强行插入会把高亮画到别处甚至完全画不出来——用指纹反查救回。
      final slice = plain.text.substring(start, end);
      String norm(String s) => s.replaceAll(RegExp(r'\s+'), '');
      if (norm(slice) != norm(a.quotedText)) {
        final fixed = _locateOffsets(a, plain);
        if (fixed == null) continue;
        start = fixed.$1;
        end = fixed.$2;
      }

      final htmlStartRaw = plain.htmlIndex[start];
      // end is exclusive, so the last selected character is at end-1, and we
      // close the span after that character.
      final htmlEndRaw = plain.htmlIndex[end - 1] + 1;
      if (htmlStartRaw >= htmlEndRaw ||
          htmlStartRaw >= html.length ||
          htmlEndRaw > html.length) {
        continue;
      }

      // 插入点不能落在 HTML 标签内部：选中文本横跨 <b>/<i> 等标签时，
      // htmlIndex 映射出的位置可能正好落在标签中间，直接插 <span> 会把
      // markup 撕烂，flutter_html 解析失败 → 「高亮保存了却不显示」。
      // 这里把起点向后、终点向前收敛到最近的标签边界。
      final htmlStart = _snapOutOfTag(html, htmlStartRaw, forward: true);
      final htmlEnd = _snapOutOfTag(html, htmlEndRaw, forward: false);
      if (htmlStart >= htmlEnd || htmlStart >= html.length || htmlEnd > html.length) {
        continue;
      }

      final isFlash = flashId != null && a.id == flashId;
      final color = (isFlash && flashColor != null)
          ? '#${flashColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}'
          : (a.color ?? '#FFEB3B');

      inserts.add(_HtmlInsert(
        htmlStart,
        true,
        '<span style="background-color: $color; border-radius: 2px; padding: 1px 0">',
      ));
      inserts.add(_HtmlInsert(htmlEnd, false, '</span>'));
    }

    if (inserts.isEmpty) return html;

    // Sort by position descending; ties: close tags before open tags so
    // pathological overlapping highlights don't break the structure.
    inserts.sort((a, b) {
      final cmp = b.pos.compareTo(a.pos);
      if (cmp != 0) return cmp;
      return a.isOpen ? 1 : -1;
    });

    final buf = StringBuffer();
    int last = 0;
    for (final ins in inserts) {
      // 兜底：排序后理论上不会出现，但宁可跳过也不能 substring 越界崩溃。
      if (ins.pos < last || ins.pos > html.length) continue;
      buf.write(html.substring(last, ins.pos));
      buf.write(ins.text);
      last = ins.pos;
    }
    buf.write(html.substring(last));
    return buf.toString();
  }

  /// 把插入点收敛到最近的 HTML 标签边界之外。
  ///
  /// [forward]=true 时把 [pos] 向后（右）移到当前标签的 `>` 之后；
  /// [forward]=false 时把 [pos] 向前（左）移到横跨它的标签的 `<` 之前。
  /// 连续嵌套标签时循环收敛，最多 8 层防死循环。
  static int _snapOutOfTag(String html, int pos, {required bool forward}) {
    var p = pos.clamp(0, html.length).toInt();
    for (var guard = 0; guard < 8; guard++) {
      if (forward) {
        if (p >= html.length) return html.length;
        // 向左找最近的 '<'；若其闭合 '>' 在 p 之后（或没有），p 在标签内。
        final lt = html.lastIndexOf('<', p - 1);
        if (lt == -1) return p;
        final gt = html.indexOf('>', lt);
        if (gt != -1 && gt < p) return p; // 标签已闭合，p 在标签外。
        if (gt == -1) return html.length;
        p = gt + 1;
      } else {
        if (p <= 0) return 0;
        final lt = html.lastIndexOf('<', p - 1);
        if (lt == -1) return p;
        final gt = html.indexOf('>', lt);
        if (gt != -1 && gt < p) return p; // 标签已闭合，p 在标签外。
        p = lt; // 标签横跨 p，回退到 '<' 之前。
      }
    }
    return p;
  }

  /// 用原文指纹在 [plain] 里反查偏移：优先 prefix+quoted+suffix，退化为只找原文。
  static (int, int)? _locateOffsets(Annotation a, PlainText plain) {
    final q = a.quotedText.trim();
    if (q.isEmpty) return null;

    final prefix = (a.anchor.prefix ?? '').trim();
    final suffix = (a.anchor.suffix ?? '').trim();
    final full = '$prefix$q$suffix';
    var idx = prefix.isNotEmpty || suffix.isNotEmpty
        ? plain.text.indexOf(full)
        : -1;
    if (idx >= 0) {
      return (idx + prefix.length, idx + prefix.length + q.length);
    }

    idx = plain.text.indexOf(q);
    if (idx >= 0) return (idx, idx + q.length);
    return null;
  }

  /// Convert XHTML to plain text with a position map back to the source.
  ///
  /// The returned [PlainText.htmlIndex] lets S5 convert plain-text character
  /// offsets into HTML byte positions so `<mark>` tags can be inserted at the
  /// correct spots without breaking the markup.
  ///
  /// Algorithm:
  /// 1. Walk the HTML character-by-character.
  /// 2. Skip `<script>` / `<style>` blocks entirely (including their content).
  /// 3. Block-level tag boundaries emit a `\n`.
  /// 4. Consecutive whitespace collapses to one space.
  /// 5. Every character written to [PlainText.text] records its originating
  ///    position in [PlainText.htmlIndex].
  static PlainText plainText(String html) {
    final textBuf = StringBuffer();
    final htmlIdx = <int>[];

    bool inSkip = false; // inside a <script> or <style>
    int skipDepth = 0;
    bool lastWasNewline = false;
    bool pendingSpace = false;

    // Tags whose boundaries act like paragraph breaks.
    const blockTags = {
      'p', 'div', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
      'li', 'tr', 'section', 'article', 'header', 'footer',
      'blockquote', 'pre', 'hr', 'ol', 'ul', 'table', 'dd', 'dt', 'dl',
    };

    void emit(int pos) {
      final ch = html[pos];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        if (!lastWasNewline) pendingSpace = true;
        return;
      }
      if (pendingSpace) {
        textBuf.write(' ');
        htmlIdx.add(pos); // approximate — fine for whitespace
        pendingSpace = false;
        lastWasNewline = false;
      }
      textBuf.write(ch);
      htmlIdx.add(pos);
      lastWasNewline = false;
    }

    void emitNewline(int pos) {
      if (lastWasNewline) return;
      textBuf.write('\n');
      htmlIdx.add(pos);
      lastWasNewline = true;
      pendingSpace = false;
    }

    int i = 0;
    while (i < html.length) {
      if (html[i] != '<') {
        if (!inSkip) emit(i);
        i++;
        continue;
      }

      // Parse the tag — always, even if inSkip, so we detect </script>.
      final close = html.indexOf('>', i);
      if (close == -1) {
        i++;
        continue;
      }

      final inner = html.substring(i + 1, close);
      final isClose = inner.startsWith('/');
      final tagPart = isClose ? inner.substring(1) : inner;
      final tagName = tagPart.split(RegExp(r'\s|>|/'))[0].toLowerCase();

      if (isClose) {
        if (tagName == 'script' || tagName == 'style') {
          if (skipDepth > 0) skipDepth--;
          if (skipDepth <= 0) inSkip = false;
        }
        if (!inSkip && blockTags.contains(tagName)) emitNewline(i);
      } else {
        if (tagName == 'script' || tagName == 'style') {
          skipDepth++;
          inSkip = true;
        } else if (!inSkip && blockTags.contains(tagName)) {
          emitNewline(i);
        }
      }

      i = close + 1;
    }

    // Flush trailing pending space.
    if (pendingSpace) {
      textBuf.write(' ');
      htmlIdx.add(html.length - 1);
    }

    // Trim whitespace at both ends and adjust the index array accordingly.
    final raw = textBuf.toString();
    final trimmed = raw.trim();
    if (trimmed.length < raw.length) {
      final start = raw.indexOf(trimmed);
      htmlIdx.removeRange(0, start);
      // Remove trailing entries if any.
      while (htmlIdx.length > trimmed.length) {
        htmlIdx.removeLast();
      }
    }

    return PlainText(text: trimmed, htmlIndex: htmlIdx);
  }

  // ── Internals ──────────────────────────────────────────────────────

  static String? _readString(Archive archive, String path) {
    final file = archive.findFile(path) ??
        archive.findFile(Uri.decodeComponent(path)) ??
        archive.findFile(Uri.encodeFull(path));
    if (file == null) return null;
    final content = file.content;
    final bytes = content is Uint8List
        ? content
        : Uint8List.fromList(content as List<int>);
    // EPUB text is UTF-8 by spec; allow malformed bytes rather than throwing
    // on a file that is otherwise perfectly readable.
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  /// Map of `document path → label`, from the NCX (EPUB 2) or nav doc (EPUB 3).
  ///
  /// Entries pointing at an anchor inside a document collapse onto that
  /// document, which is fine: the label is only used to name the section.
  static Map<String, String> _readTocLabels(
    Archive archive,
    XmlDocument opf,
    Map<String, String> hrefById,
    Map<String, String> typeById,
    Map<String, String> propsById,
    String? ncxId,
    String opfDir,
  ) {
    final labels = <String, String>{};

    // EPUB 2 — toc.ncx
    var ncxPath = ncxId != null ? hrefById[ncxId] : null;
    ncxPath ??= hrefById.entries
        .firstWhere(
          (e) => (typeById[e.key] ?? '').contains('dtbncx'),
          orElse: () => const MapEntry('', ''),
        )
        .value;
    if (ncxPath.isNotEmpty) {
      final ncx = _readString(archive, ncxPath);
      if (ncx != null) {
        try {
          final doc = XmlDocument.parse(ncx);
          final ncxDir = p.url.dirname(ncxPath);
          for (final point in doc.findAllElements('navPoint')) {
            final src = point
                .findElements('content')
                .map((e) => e.getAttribute('src'))
                .firstWhere((v) => v != null, orElse: () => null);
            final text = point
                .findElements('navLabel')
                .expand((e) => e.findElements('text'))
                .map((e) => e.innerText.trim())
                .firstWhere((v) => v.isNotEmpty, orElse: () => '');
            if (src == null || text.isEmpty) continue;
            labels.putIfAbsent(resolve(ncxDir, src), () => text);
          }
        } catch (e) {
          debugPrint('[Epub] NCX parse failed (ignored): $e');
        }
      }
    }

    // EPUB 3 — nav document with properties="nav"
    final navId = propsById.entries
        .firstWhere((e) => e.value.split(RegExp(r'\s+')).contains('nav'),
            orElse: () => const MapEntry('', ''))
        .key;
    final navPath = navId.isEmpty ? null : hrefById[navId];
    if (navPath != null) {
      final nav = _readString(archive, navPath);
      if (nav != null) {
        final navDir = p.url.dirname(navPath);
        for (final m in RegExp(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
                dotAll: true, caseSensitive: false)
            .allMatches(nav)) {
          final href = m.group(1)!;
          final text = m
              .group(2)!
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (text.isEmpty) continue;
          labels.putIfAbsent(resolve(navDir, href), () => text);
        }
      }
    }

    return labels;
  }

  static String? _firstHeading(String html) {
    final match =
        RegExp(r'<h[1-6][^>]*>(.*?)</h[1-6]>', dotAll: true, caseSensitive: false)
            .firstMatch(html);
    final raw = match?.group(1) ?? _titleTag(html);
    if (raw == null) return null;
    final text = raw
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
  }

  static String? _titleTag(String html) {
    return RegExp(r'<title[^>]*>(.*?)</title>',
            dotAll: true, caseSensitive: false)
        .firstMatch(html)
        ?.group(1);
  }

  static (String?, String?) _metadata(XmlDocument opf) {
    String? pick(String name) {
      for (final e in opf.findAllElements(name,
          namespace: 'http://purl.org/dc/elements/1.1/')) {
        final v = e.innerText.trim();
        if (v.isNotEmpty) return v;
      }
      for (final e in opf.findAllElements('dc:$name')) {
        final v = e.innerText.trim();
        if (v.isNotEmpty) return v;
      }
      return null;
    }

    return (pick('title'), pick('creator'));
  }
}

/// Small helper for [EpubLoader.withHighlights]: records where to insert an
/// open or close tag into the HTML string.
class _HtmlInsert {
  final int pos; // byte offset in the original HTML
  final bool isOpen;
  final String text;
  const _HtmlInsert(this.pos, this.isOpen, this.text);
}
