import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/annotation.dart';
import '../services/epub_loader.dart';

/// Renders an EPUB one spine document at a time.
///
/// Replaces `EpubView`, which drives its content off the NCX table of contents
/// and therefore drops every chapter the publisher forgot to list there. See
/// [EpubLoader] for the details.
class EpubReaderView extends StatefulWidget {
  final LoadedEpub book;

  /// Section to open at, clamped internally.
  final int initialSection;

  /// Fired when the topmost visible section changes.
  final void Function(int index, int total)? onSectionChanged;

  /// Base font size for body text.
  final double fontSize;

  /// Line-height multiplier for body text (1.4–2.2).
  final double lineHeight;

  /// Body text colour. When null (day theme) the ambient [DefaultTextStyle]
  /// colour is used so the reader blends with the Material surface.
  final Color? textColor;

  /// Font family for body text. `'serif'` for serif; `null` for system default.
  final String? fontFamily;

  /// Horizontal page margin in logical pixels (12–40).
  final double pageMargin;

  /// Fired when the user highlights text or creates a note from a selection.
  /// [anchor] is the computed position, [quotedText] is the selected passage.
  /// For highlights [note] is empty and [color] is set; for notes [color] is
  /// null and [note] contains the user's text (the dialog is shown internally).
  final void Function({
    required TextAnchor anchor,
    required String quotedText,
    required AnnotationType type,
    String? color,
    String note,
  })? onAnnotate;

  /// Existing annotations for this book, used to render highlight spans.
  final List<Annotation> annotations;

  /// 选中文字点「从这里朗读」：回传所在节 + 选区起始偏移（对纯文本）。
  final void Function(int sectionIndex, int startOffset)? onReadFrom;

  /// If set, the annotation with this id will get a red outline on first
  /// render so the reader can spot it after a jump. The outline is cleared
  /// after a brief animation.
  final int? initialFlashAnnotationId;

  /// 章节内滚动比例（0~1）：打开时恢复到上次读到的段落。
  final double initialIntra;

  /// 滚动停止后回调节章内比例（0~1），父层负责持久化。
  final void Function(double intra)? onIntraProgress;

  const EpubReaderView({
    super.key,
    required this.book,
    this.initialSection = 0,
    this.onSectionChanged,
    this.fontSize = 17,
    this.lineHeight = 1.75,
    this.textColor,
    this.fontFamily,
    this.pageMargin = 20,
    this.onAnnotate,
    this.annotations = const [],
    this.onReadFrom,
    this.initialFlashAnnotationId,
    this.initialIntra = 0,
    this.onIntraProgress,
  });

  @override
  State<EpubReaderView> createState() => EpubReaderViewState();
}

class EpubReaderViewState extends State<EpubReaderView> {
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();
  int _current = 0;

  // Selection state — populated by SelectionArea.onSelectionChanged, consumed
  // by the custom context menu buttons.
  String? _selectedText;
  int _selectedSectionIndex = 0;

  // Flash state for jump-back: when non-null, the annotation with this id
  // renders with a pulsing highlight colour so the reader can spot it.
  int? _flashAnnotationId;
  Timer? _flashTimer;
  DateTime _flashStart = DateTime.now();

  // 章节内滚动位置报告（滚动停止 500ms 后触发一次，避免滚动中频繁落盘）。
  Timer? _intraDebounce;

  // Highlight colour palette shown in the context menu.
  static const _highlightColors = <String, String>{
    '黄': '#FFEB3B',
    '绿': '#4CAF50',
    '蓝': '#2196F3',
    '粉': '#E91E63',
  };

  int get currentSection => _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialSection.clamp(0, widget.book.sections.length - 1);
    _positionsListener.itemPositions.addListener(_onPositions);

    // If we're opening the book to a specific annotation, flash it.
    if (widget.initialFlashAnnotationId != null) {
      _flashAnnotationId = widget.initialFlashAnnotationId;
      _startFlashTimer();
    }

    // 续读：恢复到上次章节内的段落（initialIntra > 0 时）。
    if (widget.initialIntra > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.isAttached) return;
        _scrollController.scrollTo(
          index: _current,
          alignment: widget.initialIntra.clamp(0.0, 1.0),
          duration: Duration.zero,
        );
      });
    }
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onPositions);
    _flashTimer?.cancel();
    _intraDebounce?.cancel();
    super.dispose();
  }

  /// 闪烁由周期定时器驱动：每 100ms 重绘一次，颜色在亮黄/橙之间脉动，
  /// 4 秒后自动清除——用背景色动画替代 CSS outline（flutter_html 对
  /// outline 支持不稳，之前的「跳回来找不到高亮」就是这样来的）。
  void _startFlashTimer() {
    _flashTimer?.cancel();
    _flashStart = DateTime.now();
    _flashTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) {
        _flashTimer?.cancel();
        return;
      }
      if (DateTime.now().difference(_flashStart).inMilliseconds > 4000) {
        _flashTimer?.cancel();
        setState(() => _flashAnnotationId = null);
      } else {
        setState(() {});
      }
    });
  }

  void _onPositions() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // 程序跳转后 1 秒内的位置回调是旧位置的过渡数据，不覆盖 _current
    //（否则「从笔记中心跳到第 2 节却被拉回第 1 节」）。
    final jumpAt = _lastProgrammaticJump;
    if (jumpAt != null &&
        DateTime.now().difference(jumpAt).inMilliseconds < 1000) {
      // 但真实的滚动（用户手动滑）要能恢复跟踪——1 秒保护期足够短。
      return;
    }
    // The section occupying the top of the viewport is the one being read.
    final top = positions
        .where((pos) => pos.itemTrailingEdge > 0)
        .fold<int?>(null, (best, pos) => best == null || pos.index < best
            ? pos.index
            : best);
    if (top != null) {
      if (top != _current) {
        setState(() => _current = top);
        widget.onSectionChanged?.call(top, widget.book.sections.length);
      }
      _scheduleIntraReport(top);
    }
  }

  /// 滚动停止 500ms 后，计算并上报「当前章节内的阅读比例」。
  ///
  /// itemPositions 的 leadingEdge/trailingEdge 是相对视口的比例：
  ///   h = trailingEdge - leadingEdge = 章高 / 视口高
  ///   视口顶在章内偏移 d = -leadingEdge（视口高为单位）
  ///   章节内可滚动范围 = h - 1 → intra = d / (h - 1)
  void _scheduleIntraReport(int top) {
    _intraDebounce?.cancel();
    _intraDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final positions = _positionsListener.itemPositions.value;
      for (final pos in positions) {
        if (pos.index != top) continue;
        final h = pos.itemTrailingEdge - pos.itemLeadingEdge;
        if (h <= 1.0) {
          widget.onIntraProgress?.call(0); // 整章在一屏内，无章内偏移。
          return;
        }
        final intra = (-pos.itemLeadingEdge / (h - 1.0)).clamp(0.0, 1.0);
        widget.onIntraProgress?.call(intra);
        return;
      }
    });
  }

  /// Jump to a section (used by the table-of-contents sheet).
  ///
  /// 修复「笔记中心点第 2 页的笔记却总是回到第 1 页」：
  /// · 控制器未挂载时（跳转发生在列表首帧布局前）jumpTo 会被静默丢弃，
  ///   改为最多 20 次 × 100ms 重试直到真正跳过去；
  /// · 记录程序跳转时间戳，[_onPositions] 在跳转后 1 秒内不覆盖 [_current]，
  ///   防止滚动位置回调用旧位置把「当前节」拉回第 1 节。
  void jumpTo(int index) {
    final clamped = index.clamp(0, widget.book.sections.length - 1);
    _lastProgrammaticJump = DateTime.now();
    setState(() => _current = clamped);
    widget.onSectionChanged?.call(clamped, widget.book.sections.length);
    _jumpAttempts = 0;
    _tryJumpTo(clamped);
  }

  DateTime? _lastProgrammaticJump;
  int _jumpAttempts = 0;

  void _tryJumpTo(int target) {
    if (!mounted) return;
    if (_scrollController.isAttached) {
      _scrollController.jumpTo(index: target);
      // 跳转后让位置回调有机会反映新位置；滚动停止后依然以真实位置为准。
      _lastProgrammaticJump = DateTime.now();
      return;
    }
    _jumpAttempts++;
    if (_jumpAttempts > 20) return;
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _tryJumpTo(target);
    });
  }

  /// Jump to the section containing [anchor] and briefly flash the highlight
  /// span so the reader can find it.
  ///
  /// [annotationId] must match an [Annotation.id] in [EpubReaderView.annotations];
  /// its colour span will get a red outline for ~1.2 s.
  void jumpToAnnotation(TextAnchor anchor, int annotationId) {
    final sectionIdx = anchor.sectionIndex ?? 0;
    jumpTo(sectionIdx);
    setState(() => _flashAnnotationId = annotationId);
    _startFlashTimer();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return ScrollablePositionedList.builder(
      itemCount: widget.book.sections.length,
      initialScrollIndex: _current,
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      itemBuilder: (context, index) {
        final section = widget.book.sections[index];

        // Filter annotations that belong to this section and insert highlight
        // spans. Must happen inside itemBuilder because _flashAnnotationId
        // changes at runtime.
        final sectionAnnotations = widget.annotations
            .where((a) =>
                a.anchor.kind == AnchorKind.epub &&
                a.anchor.sectionIndex == index)
            .toList();

        // 闪烁色：亮黄 ↔ 橙 之间脉动。
        Color? flashColor;
        if (_flashAnnotationId != null) {
          final elapsed =
              DateTime.now().difference(_flashStart).inMilliseconds;
          final t = (elapsed % 600) / 600.0;
          flashColor = Color.lerp(
              const Color(0xFFFFF176), const Color(0xFFFF7043), t);
        }

        final highlightedHtml = sectionAnnotations.isEmpty
            ? section.html
            : EpubLoader.withHighlights(
                section.html,
                section.plain,
                sectionAnnotations,
                flashId: _flashAnnotationId,
                flashColor: flashColor,
              );

        // Resolve text colour: explicit colour wins, otherwise fall back to
        // the ambient Material text colour so the day theme blends naturally.
        final effectiveTextColor =
            widget.textColor ?? colors.onSurface;

        return Padding(
          padding: EdgeInsets.symmetric(
              horizontal: widget.pageMargin, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (index > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Divider(color: colors.outlineVariant),
                ),
              // Each section gets its own SelectionArea so cross-section
              // selections are impossible — the anchor would be ambiguous.
              SelectionArea(
                contextMenuBuilder: _buildContextMenu,
                onSelectionChanged: (sel) {
                  if (sel != null && sel.plainText.trim().isNotEmpty) {
                    _selectedText = sel.plainText;
                    _selectedSectionIndex = index;
                  }
                },
                child: Html(
                  data: highlightedHtml,
                  style: {
                    'body': Style(
                      margin: Margins.zero,
                      padding: HtmlPaddings.zero,
                      fontSize: FontSize(widget.fontSize),
                      lineHeight: LineHeight(widget.lineHeight),
                      fontFamily:
                          widget.fontFamily ?? 'sans-serif',
                      color: effectiveTextColor,
                    ),
                    'p': Style(
                      margin: Margins.only(bottom: 14),
                      textAlign: TextAlign.justify,
                    ),
                    'h1': Style(fontSize: FontSize(widget.fontSize * 1.5)),
                    'h2': Style(fontSize: FontSize(widget.fontSize * 1.3)),
                    'h3': Style(fontSize: FontSize(widget.fontSize * 1.15)),
                  },
                  extensions: [
                    // Images live inside the archive, so the default network
                    // loader would just render a broken box.
                    TagExtension(
                      tagsToExtend: {'img', 'image'},
                      builder: (ctx) => _archiveImage(ctx, section.href),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Context menu ──────────────────────────────────────────────────────

  /// Builds the custom text-selection toolbar with highlight colours,
  /// a note button, and copy.
  Widget _buildContextMenu(BuildContext ctx, SelectableRegionState state) {
    final theme = Theme.of(ctx);
    final colors = theme.colorScheme;

    return AdaptiveTextSelectionToolbar(
      anchors: state.contextMenuAnchors,
      children: [
        // 横向可滚动，窄屏上 7 个按钮不溢出。
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Four highlight-colour dots.
              for (final entry in _highlightColors.entries)
                _ColorDot(
                  color:
                      Color(int.parse(entry.value.replaceFirst('#', '0xFF'))),
                  label: entry.key,
                  onTap: () {
                    state.hideToolbar();
                    _processHighlight(entry.value);
                  },
                ),
              const SizedBox(width: 8),
              // Note button.
              _ToolbarButton(
                icon: Icons.edit_note,
                label: '笔记',
                color: colors.primary,
                onTap: () {
                  state.hideToolbar();
                  _processNote();
                },
              ),
              const SizedBox(width: 4),
              // 从这里朗读：选中句作为朗读起点。
              _ToolbarButton(
                icon: Icons.play_circle_outline,
                label: '朗读',
                color: colors.primary,
                onTap: () {
                  state.hideToolbar();
                  _processReadFrom();
                },
              ),
              const SizedBox(width: 4),
              // Copy button.
              _ToolbarButton(
                icon: Icons.copy,
                label: '复制',
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _selectedText ?? ''));
                  state.hideToolbar();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Selection processing ──────────────────────────────────────────────

  /// 关键约束：**quotedText 必须是 plain.text 里的连续片段**——偏移永远
  /// 对得上。旧版本在「压掉空白后的字符串」里反算偏移，偏移与 plain.text
  /// 对不上，导致高亮 span 插错位置甚至插不进去（「屏幕不显示高亮」的根因）。
  /// 现在统一：先在原文找，找不到就找最长可匹配前缀，把实际匹配到的文字
  /// 作为 quotedText 返回。
  (TextAnchor, String)? _calculateAnchor() {
    if (_selectedText == null || _selectedText!.trim().isEmpty) return null;

    final section = widget.book.sections[_selectedSectionIndex];
    final plain = section.plain;
    final selected = _selectedText!.trim();

    // 1) 原文精确匹配。
    int idx = plain.text.indexOf(selected);

    // 2) 压空白后匹配 → 再用头部关键词把位置映射回原文。
    String matched = selected;
    if (idx == -1) {
      final query = selected.replaceAll(RegExp(r'\s+'), ' ');
      final haystack = plain.text.replaceAll(RegExp(r'\s+'), ' ');
      final cIdx = haystack.indexOf(query);
      if (cIdx != -1) {
        final head = selected.replaceAll(RegExp(r'\s+'), '');
        final headKey = head.length > 12 ? head.substring(0, 12) : head;
        final rawIdx = plain.text.indexOf(headKey);
        if (rawIdx != -1) {
          idx = rawIdx;
          // 精确匹配失败但找到了开头：quotedText 收敛为纯文本里从 idx 起、
          // 长度不超过选中文本的片段（保证连续）。
          matched = plain.text.substring(
              idx, (idx + selected.length).clamp(idx, plain.text.length));
        }
      }
    }

    // 3) 最后兜底：找最长公共前缀（至少 3 个字符）。
    if (idx == -1) {
      final head = selected.length > 8 ? selected.substring(0, 8) : selected;
      final headNorm = head.replaceAll(RegExp(r'\s+'), '');
      if (headNorm.length < 3) return null;
      final haystack = plain.text.replaceAll(RegExp(r'\s+'), '');
      final cIdx = haystack.indexOf(headNorm);
      if (cIdx == -1) {
        debugPrint('[Epub] selection not found in plain text: '
            '"${selected.length > 50 ? '${selected.substring(0, 50)}…' : selected}"');
        return null;
      }
      // 把压空白下标映射回原文：跳过原文里的空白逐个计数。
      var plainIdx = 0;
      var collapsedIdx = 0;
      while (plainIdx < plain.text.length && collapsedIdx < cIdx) {
        final ch = plain.text[plainIdx];
        if (!RegExp(r'\s').hasMatch(ch)) collapsedIdx++;
        plainIdx++;
      }
      idx = plainIdx;
      matched = plain.text.substring(
          idx, (idx + selected.length).clamp(idx, plain.text.length));
    }

    final startOffset = idx;
    final endOffset = (idx + matched.length).clamp(idx, plain.text.length);
    if (endOffset <= startOffset) return null;

    // Capture fingerprint for S5 fallback re-anchoring.
    final t = plain.text;
    final prefix = startOffset >= 24
        ? t.substring(startOffset - 24, startOffset)
        : t.substring(0, startOffset);
    final suffix = endOffset + 24 <= t.length
        ? t.substring(endOffset, endOffset + 24)
        : t.substring(endOffset);

    return (
      TextAnchor(
        kind: AnchorKind.epub,
        sectionIndex: _selectedSectionIndex,
        startOffset: startOffset,
        endOffset: endOffset,
        prefix: prefix.isNotEmpty ? prefix : null,
        suffix: suffix.isNotEmpty ? suffix : null,
      ),
      matched,
    );
  }

  /// User tapped a highlight colour — save immediately.
  void _processHighlight(String color) {
    final result = _calculateAnchor();
    if (result == null) return;
    widget.onAnnotate?.call(
      anchor: result.$1,
      quotedText: result.$2,
      type: AnnotationType.highlight,
      color: color,
      note: '',
    );
  }

  /// User tapped the note button — calculate anchor, then show the note
  /// dialog so they can type commentary.
  void _processNote() {
    final result = _calculateAnchor();
    final anchor = result?.$1;
    final text = result?.$2;
    if (anchor == null || text == null || text.isEmpty) return;

    // Defer so the context menu has time to dismiss before we push the dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showNoteDialog(anchor, text);
    });
  }

  /// 选中文字点「从这里朗读」→ 回传锚点，由阅读器从选区起始句开始朗读。
  void _processReadFrom() {
    final result = _calculateAnchor();
    final anchor = result?.$1;
    if (anchor == null ||
        anchor.sectionIndex == null ||
        anchor.startOffset == null) {
      return;
    }
    widget.onReadFrom?.call(anchor.sectionIndex!, anchor.startOffset!);
  }

  void _showNoteDialog(TextAnchor anchor, String quotedText) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加笔记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                border: const Border(left: BorderSide(color: Colors.grey, width: 3)),
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                quotedText,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 4,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '输入笔记内容…',
                border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                helperText: anchor.display,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onAnnotate?.call(
                anchor: anchor,
                quotedText: quotedText,
                type: AnnotationType.note,
                note: ctrl.text.trim(),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _archiveImage(ExtensionContext ctx, String fromHref) {
    final src = ctx.attributes['src'] ??
        ctx.attributes['xlink:href'] ??
        ctx.attributes['href'];
    if (src == null) return const SizedBox.shrink();
    final bytes = widget.book.imageBytes(src, fromHref);
    if (bytes == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}

// ── Small helpers for the custom context menu ───────────────────────────

/// A coloured circle that acts as a highlight-colour picker.
class _ColorDot extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ColorDot({
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label色高亮',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact icon+label button for the custom text-selection toolbar.
class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(fontSize: 13, color: color)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onTap,
    );
  }
}
