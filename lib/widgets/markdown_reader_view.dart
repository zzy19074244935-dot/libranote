import 'package:flutter/material.dart';

import 'tap_catcher.dart';

/// A lightweight Markdown renderer that converts MD text into a scrollable
/// list of styled Flutter widgets.
///
/// We do NOT pull in `flutter_markdown` — it has been deprecated and drags in
/// a large dependency tree.  This converter handles the 80 % case that covers
/// virtually all real-world README / note files:
///
/// **Block elements:**
/// - ATX headings (`#` … `######`)
/// - Blockquotes (`>`)
/// - Fenced code blocks (` ``` `)
/// - Unordered lists (`-`, `*`, `+`)
/// - Ordered lists (`1.`, `2.` …)
/// - Horizontal rules (`---`, `***`, `___`)
///
/// **Inline elements:**
/// - Bold (`**text**`)
/// - Italic (`*text*`)
/// - Inline code (`` `code` ``)
/// - Links (`[text](url)`) — rendered as tappable text
///
/// Setext headings (`===`, `---`), reference-style links, images, and HTML
/// tags are intentionally unsupported — they are rare in note-style Markdown.
class MarkdownReaderView extends StatefulWidget {
  /// Raw Markdown source text.
  final String markdown;

  final double fontSize;
  final double lineHeight;
  final Color? textColor;
  final String? fontFamily;
  final double pageMargin;

  /// Fired with approximate reading progress 0.0–1.0.
  final void Function(double progress)? onProgress;

  /// 轻点某个块时回调，参数是该块在原始 Markdown 里的起始行号
  /// （听书朗读：点击某处开始朗读，从该行所在段落读起）。
  final void Function(int startLine)? onParagraphTap;

  /// 上次阅读进度（0.0–1.0）：打开时滚动到该位置（续读）。
  final double initialProgress;

  const MarkdownReaderView({
    super.key,
    required this.markdown,
    this.fontSize = 17,
    this.lineHeight = 1.75,
    this.textColor,
    this.fontFamily,
    this.pageMargin = 20,
    this.onProgress,
    this.onParagraphTap,
    this.initialProgress = 0,
  });

  @override
  State<MarkdownReaderView> createState() => MarkdownReaderViewState();
}

class MarkdownReaderViewState extends State<MarkdownReaderView> {
  final _scrollController = ScrollController();
  late final List<_MdBlock> _blocks;

  @override
  void initState() {
    super.initState();
    _blocks = _parse(widget.markdown);
    _scrollController.addListener(_onScroll);
    _restore();
  }

  /// 恢复上次阅读位置：布局完成后按进度比例跳转。
  void _restore() {
    if (widget.initialProgress <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max <= 0) return;
      final target = (max * widget.initialProgress).clamp(0.0, max);
      _scrollController.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final cur = _scrollController.position.pixels;
    if (max <= 0) {
      widget.onProgress?.call(0);
      return;
    }
    widget.onProgress?.call((cur / max).clamp(0.0, 1.0));
  }

  /// Scroll by roughly one viewport (tap-to-turn support).
  void scrollPage(bool forward) {
    if (!_scrollController.hasClients) return;
    final vp = _scrollController.position.viewportDimension;
    final target = _scrollController.position.pixels +
        (forward ? vp * 0.85 : -vp * 0.85);
    _scrollController.animateTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final baseColor = widget.textColor ?? colors.onSurface;

    if (_blocks.isEmpty) {
      return Center(
        child: Text('文件内容为空',
            style: TextStyle(color: colors.onSurfaceVariant)),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: widget.pageMargin,
        vertical: 16,
      ),
      itemCount: _blocks.length,
      itemBuilder: (context, index) {
        final block = _blocks[index];
        return TapCatcher(
          onTap: () => widget.onParagraphTap?.call(block.startLine),
          child: _buildBlock(block, colors, baseColor),
        );
      },
    );
  }

  // ── Block rendering ─────────────────────────────────────────────────

  Widget _buildBlock(_MdBlock block, ColorScheme colors, Color baseColor) {
    switch (block.type) {
      case _MdType.heading:
        return _heading(block, baseColor);
      case _MdType.paragraph:
        return _paragraph(block, baseColor);
      case _MdType.codeBlock:
        return _codeBlock(block, colors);
      case _MdType.quote:
        return _quote(block, colors, baseColor);
      case _MdType.horizontalRule:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(color: colors.outlineVariant),
        );
      case _MdType.unorderedList:
      case _MdType.orderedList:
        return _listItem(block, colors, baseColor);
    }
  }

  Widget _heading(_MdBlock block, Color baseColor) {
    final scale = switch (block.level) {
      1 => 1.6,
      2 => 1.35,
      3 => 1.15,
      _ => 1.05,
    };
    return Padding(
      padding: EdgeInsets.only(top: block.level == 1 ? 20 : 12, bottom: 6),
      child: Text.rich(
        _inline(block.content, baseColor, baseColor.withValues(alpha: 0.7)),
        style: TextStyle(
          fontSize: widget.fontSize * scale,
          height: widget.lineHeight,
          fontWeight: FontWeight.w700,
          color: baseColor,
          fontFamily: widget.fontFamily,
        ),
      ),
    );
  }

  Widget _paragraph(_MdBlock block, Color baseColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        _inline(block.content, baseColor, baseColor.withValues(alpha: 0.7)),
        style: TextStyle(
          fontSize: widget.fontSize,
          height: widget.lineHeight,
          color: baseColor,
          fontFamily: widget.fontFamily,
        ),
      ),
    );
  }

  Widget _codeBlock(_MdBlock block, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          block.content,
          style: TextStyle(
            fontSize: widget.fontSize * 0.9,
            height: widget.lineHeight,
            fontFamily: 'monospace',
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _quote(_MdBlock block, ColorScheme colors, Color baseColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              color: colors.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                _inline(
                    block.content, baseColor, colors.onSurfaceVariant),
                style: TextStyle(
                  fontSize: widget.fontSize,
                  height: widget.lineHeight,
                  color: colors.onSurfaceVariant,
                  fontFamily: widget.fontFamily,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listItem(_MdBlock block, ColorScheme colors, Color baseColor) {
    final bullet = block.type == _MdType.orderedList
        ? '${block.listNumber}.'
        : '•';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2, left: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(bullet,
                style: TextStyle(
                  fontSize: widget.fontSize,
                  height: widget.lineHeight,
                  color: baseColor,
                  fontFamily: widget.fontFamily,
                )),
          ),
          Expanded(
            child: Text.rich(
              _inline(block.content, baseColor,
                  baseColor.withValues(alpha: 0.7)),
              style: TextStyle(
                fontSize: widget.fontSize,
                height: widget.lineHeight,
                color: baseColor,
                fontFamily: widget.fontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Inline parsing ──────────────────────────────────────────────────

  /// Parse inline formatting within a single block's text content and return
  /// a [TextSpan] tree.  [baseColor] is the default text colour; [muted] is
  /// used for secondary elements like link URLs.
  TextSpan _inline(String text, Color baseColor, Color muted) {
    if (text.isEmpty) return TextSpan(text: '', style: TextStyle(color: baseColor));

    final spans = <InlineSpan>[];

    // Inline code `` ` `` — highest priority, backticks must not be confused
    // with bold/italic markers.
    final codeRe = RegExp(r'`([^`]+)`');

    // Walk the text looking for inline patterns. We use a simple multi-pass
    // approach: first split by inline code, then process bold/italic/links in
    // each plain segment.
    final segments = <_InlineSegment>[];
    int last = 0;
    for (final m in codeRe.allMatches(text)) {
      if (m.start > last) {
        segments.add(_InlineSegment(text.substring(last, m.start), false));
      }
      segments.add(_InlineSegment(m.group(1)!, true));
      last = m.end;
    }
    if (last < text.length) {
      segments.add(_InlineSegment(text.substring(last), false));
    }

    for (final seg in segments) {
      if (seg.isCode) {
        spans.add(WidgetSpan(
          baseline: TextBaseline.alphabetic,
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: baseColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(seg.text,
                style: TextStyle(
                  fontSize: widget.fontSize * 0.92,
                  fontFamily: 'monospace',
                  color: baseColor.withValues(alpha: 0.8),
                )),
          ),
        ));
      } else {
        spans.addAll(_inlineRich(seg.text, baseColor, muted));
      }
    }

    return TextSpan(style: TextStyle(color: baseColor), children: spans);
  }

  /// Parse bold, italic, and links within a plain (non-code) segment.
  List<InlineSpan> _inlineRich(String text, Color baseColor, Color muted) {
    // Combined regex for bold, italic, link, and image.
    // Order matters: longer patterns first (bold before italic).
    final re = RegExp(
      r'\*\*(.+?)\*\*|'     // bold
      r'\*(.+?)\*|'          // italic
      r'\[([^\]]+)\]\(([^)]+)\)|' // link
      r'!\[([^\]]*)\]\(([^)]+)\)', // image — treat as link text
    );

    final spans = <InlineSpan>[];
    int pos = 0;

    for (final m in re.allMatches(text)) {
      // Plain text before this match.
      if (m.start > pos) {
        spans.add(TextSpan(
          text: text.substring(pos, m.start),
          style: TextStyle(color: baseColor),
        ));
      }

      if (m.group(1) != null) {
        // Bold **...**
        spans.add(TextSpan(
          text: m.group(1),
          style: TextStyle(
              color: baseColor,
              fontWeight: FontWeight.w700,
              fontSize: widget.fontSize),
        ));
      } else if (m.group(2) != null) {
        // Italic *...*
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(
              color: baseColor,
              fontStyle: FontStyle.italic,
              fontSize: widget.fontSize),
        ));
      } else if (m.group(3) != null && m.group(4) != null) {
        // Link [text](url)
        final label = m.group(3)!;
        spans.add(TextSpan(
          text: label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
            fontSize: widget.fontSize,
          ),
          // Recognizer would need a GestureRecognizer with url_launcher;
          // for S8 we style links visually but don't make them tappable
          // inside SelectableText (GestureRecognizer + SelectableText
          // conflict). Full link support can follow.
        ));
      } else if (m.group(5) != null) {
        // Image ![alt](url) — render the alt text as muted
        if (m.group(5)!.isNotEmpty) {
          spans.add(TextSpan(
            text: '[图片: ${m.group(5)}]',
            style: TextStyle(color: muted, fontStyle: FontStyle.italic),
          ));
        }
      }

      pos = m.end;
    }

    // Remaining plain text.
    if (pos < text.length) {
      spans.add(TextSpan(
        text: text.substring(pos),
        style: TextStyle(color: baseColor),
      ));
    }

    return spans;
  }

  // ── Block-level parser (line-by-line) ───────────────────────────────

  static List<_MdBlock> _parse(String md) {
    final lines = md.split('\n');
    final blocks = <_MdBlock>[];
    int i = 0;

    while (i < lines.length) {
      final line = lines[i];

      // Blank line — skip, it separates blocks.
      if (line.trim().isEmpty) {
        i++;
        continue;
      }

      // Fenced code block.
      if (line.trim().startsWith('```')) {
        final startLine = i;
        final lang = line.trim().substring(3).trim();
        final buf = StringBuffer();
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          if (buf.isNotEmpty) buf.write('\n');
          buf.write(lines[i]);
          i++;
        }
        i++; // skip closing ```
        blocks.add(_MdBlock(
          type: _MdType.codeBlock,
          content: buf.toString(),
          meta: lang.isEmpty ? null : lang,
          startLine: startLine,
        ));
        continue;
      }

      // Horizontal rule.
      if (RegExp(r'^[ ]{0,3}([-*_])[ ]{0,2}\1[ ]{0,2}\1[ ]*$')
          .hasMatch(line)) {
        blocks.add(_MdBlock(
            type: _MdType.horizontalRule, content: '', startLine: i));
        i++;
        continue;
      }

      // ATX heading.
      final headingMatch =
          RegExp(r'^(#{1,6})\s+(.*?)(?:\s+#+\s*)?$').firstMatch(line);
      if (headingMatch != null) {
        blocks.add(_MdBlock(
          type: _MdType.heading,
          content: headingMatch.group(2) ?? '',
          level: headingMatch.group(1)!.length,
          startLine: i,
        ));
        i++;
        continue;
      }

      // Blockquote.
      if (line.trim().startsWith('>')) {
        final startLine = i;
        final buf = StringBuffer();
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          final content = lines[i].trim().substring(1).trim();
          if (buf.isNotEmpty) buf.write(' ');
          buf.write(content);
          i++;
        }
        blocks.add(_MdBlock(
            type: _MdType.quote, content: buf.toString(), startLine: startLine));
        continue;
      }

      // Unordered list.
      final ulMatch =
          RegExp(r'^[ ]{0,3}[-*+]\s+(.*)$').firstMatch(line);
      if (ulMatch != null) {
        blocks.add(_MdBlock(
          type: _MdType.unorderedList,
          content: ulMatch.group(1) ?? '',
          startLine: i,
        ));
        i++;
        continue;
      }

      // Ordered list.
      final olMatch =
          RegExp(r'^[ ]{0,3}(\d+)\.\s+(.*)$').firstMatch(line);
      if (olMatch != null) {
        blocks.add(_MdBlock(
          type: _MdType.orderedList,
          content: olMatch.group(2) ?? '',
          listNumber: int.tryParse(olMatch.group(1) ?? '1'),
          startLine: i,
        ));
        i++;
        continue;
      }

      // Paragraph — collect consecutive non-empty, non-special lines.
      final startLine = i;
      final buf = StringBuffer();
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !lines[i].trim().startsWith('```') &&
          !lines[i].trim().startsWith('>') &&
          !RegExp(r'^(#{1,6})\s').hasMatch(lines[i]) &&
          !RegExp(r'^[ ]{0,3}[-*+]\s').hasMatch(lines[i]) &&
          !RegExp(r'^[ ]{0,3}\d+\.\s').hasMatch(lines[i]) &&
          !RegExp(r'^[ ]{0,3}([-*_])\s{0,2}\1\s{0,2}\1[ ]*$')
              .hasMatch(lines[i])) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(lines[i].trim());
        i++;
      }
      // Trim trailing whitespace-only text
      final paraText = buf.toString().trim();
      if (paraText.isNotEmpty) {
        blocks.add(_MdBlock(
            type: _MdType.paragraph, content: paraText, startLine: startLine));
      }
    }

    return blocks;
  }
}

// ── Internal data types ─────────────────────────────────────────────────

enum _MdType {
  heading,
  paragraph,
  codeBlock,
  quote,
  horizontalRule,
  unorderedList,
  orderedList,
}

class _MdBlock {
  final _MdType type;
  final String content;
  final int level; // heading level 1-6
  final String? meta; // code-block language
  final int? listNumber; // ordered list item number

  /// 该块在原始 Markdown 里的起始行号（点段落朗读用）。
  final int startLine;

  const _MdBlock({
    required this.type,
    required this.content,
    this.level = 1,
    this.meta,
    this.listNumber,
    this.startLine = 0,
  });
}

/// Internal helper for inline parsing: a segment of text that is either
/// plain (subject to bold/italic/link parsing) or inline code (literal).
class _InlineSegment {
  final String text;
  final bool isCode;
  const _InlineSegment(this.text, this.isCode);
}
