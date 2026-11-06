import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/docx_loader.dart';
import 'tap_catcher.dart';

/// DOCX 选区信息：段落索引 + 原文 + 字符偏移。
class TxtSelection {
  final int paraIndex;
  final String text;
  final int start;
  final int end;

  const TxtSelection({
    required this.paraIndex,
    required this.text,
    required this.start,
    required this.end,
  });
}

/// 选中菜单动作名：copy / search / translate / tts / note / ai / share
/// （「截图」已按用户要求从选中菜单移除，改为阅读器顶栏截图按钮）。
typedef TxtSelectionAction = void Function(String action, TxtSelection sel);

/// Renders plain-text paragraphs with configurable typography.
///
/// Used by both the TXT reader (via [TxtLoader]) and the DOCX reader (via
/// [DocxLoader]) — the two formats differ only in how they parse bytes into
/// paragraph lists; the rendering is identical.
///
/// Phase 4（Word 批注闭环）：传入 [annotations] 时启用 DOCX 批注模式——
/// · 段落高亮/下划线/波浪线渲染（TextSpan background / decoration）；
/// · 选中文字 → 弹出两行菜单（复制/搜索/翻译/朗读/批注/AI/分享 +
///   高亮批注栏），与 PDF/EPUB 引擎同款；选中已批注区间时多一个「查看批注」；
/// · 点击高亮 → [onHighlightTap] 弹笔记。
/// DOCX 传入 [richParagraphs] 时保留 Word 格式（加粗/斜体/对齐/字号/颜色）。
/// TXT/MD 不传 annotations → 保持只读（行为与旧版一致）。
class TxtReaderView extends StatefulWidget {
  /// Paragraphs to render, in reading order.  May be empty (empty file).
  final List<String> paragraphs;

  final double fontSize;
  final double lineHeight;
  final Color? textColor;
  final String? fontFamily;
  final double pageMargin;

  /// Fired when the user scrolls, carrying the approximate progress 0.0–1.0.
  /// The parent can feed this into [ReaderNotifier.updateProgress].
  final void Function(double progress)? onProgress;

  /// 轻点某一段落时回调（听书朗读：点击某处开始朗读）。
  final void Function(int index)? onParagraphTap;

  /// 上次阅读进度（0.0–1.0）：打开时滚动到该位置（续读）。
  final double initialProgress;

  /// DOCX 批注列表（null = 只读模式，TXT/MD 用）。
  final List<DocxNote>? annotations;

  /// 富文本段落（与 [paragraphs] 一一对应；null = 旧纯文本模式，TXT/MD 用）。
  /// 批注模式下非空时按 runs 渲染加粗/斜体/对齐/标题等格式。
  final List<DocxPara>? richParagraphs;

  /// DOCX 内容块（段落/表格/文本框，按文档顺序）；null = 旧纯文本模式。
  /// 提供时按块渲染：表格画框线、文本框画边框，段落保留 w:pBdr 框线。
  final List<DocxBlock>? blocks;

  /// 选区动作（批注模式下菜单第一行按钮）。
  final TxtSelectionAction? onSelectionAction;

  /// 高亮栏确认：父级落库（style/color/note）。
  final void Function(TxtSelection sel, String color, String style,
      String note)? onAnnotate;

  /// 点击高亮范围 → 弹笔记。
  final void Function(DocxNote note)? onHighlightTap;

  /// 浮动文本框被拖动/移动后 → 父级落库（携带新几何与内容）。
  final void Function(DocxNote note)? onTextBoxChanged;

  /// 双击浮动文本框 → 父级弹编辑/删除对话框。
  final void Function(DocxNote note)? onTextBoxEdit;

  /// 打开后跳转到该段落并闪烁（笔记中心回跳，DOCX 用）。
  final int? jumpToPara;

  /// 编辑模式：点段落/表格单元格 → [onEditParagraph]（Word 段落级编辑）。
  final bool editMode;

  /// 编辑模式下点某段落（扁平下标）时的回调。
  final void Function(int paraIndex)? onEditParagraph;

  /// 编辑模式下当前选中的段落（扁平下标）：给它画选区高亮框。
  final int? editSelectedPara;

  const TxtReaderView({
    super.key,
    required this.paragraphs,
    this.fontSize = 17,
    this.lineHeight = 1.75,
    this.textColor,
    this.fontFamily,
    this.pageMargin = 20,
    this.onProgress,
    this.onParagraphTap,
    this.initialProgress = 0,
    this.annotations,
    this.richParagraphs,
    this.blocks,
    this.onSelectionAction,
    this.onAnnotate,
    this.onHighlightTap,
    this.onTextBoxChanged,
    this.onTextBoxEdit,
    this.jumpToPara,
    this.editMode = false,
    this.onEditParagraph,
    this.editSelectedPara,
  });

  @override
  State<TxtReaderView> createState() => TxtReaderViewState();
}

class TxtReaderViewState extends State<TxtReaderView> {
  final _scrollController = ScrollController();
  final _tapRecognizers = <String, TapGestureRecognizer>{};

  /// 当前选区（最近一次 onSelectionChanged）。
  TxtSelection? _lastSel;

  /// 高亮批注栏当前样式/颜色。
  String _selStyle = 'highlight';
  String? _selColor;

  /// 回跳闪烁段落。
  int? _flashPara;
  Timer? _flashTimer;

  // ── 浮动文本框（style='textbox' 批注）交互状态 ──────────────────────
  int? _selectedBoxId;
  final Map<int, DocxNote> _boxWork = {}; // 拖动中的临时几何
  Offset? _boxDragStart; // 全局坐标
  DocxNote? _boxDragStartNote;
  bool _boxDragged = false;
  DateTime? _boxLastTapTime;
  int? _boxLastTapId;
  Offset? _boxLastTapPos;

  bool get _annotationMode => widget.annotations != null;

  /// 浮动文本框列表。
  List<DocxNote> get _textBoxes {
    final all = widget.annotations;
    if (all == null) return const [];
    return all.where((n) => n.style == 'textbox').toList();
  }

  /// 正文内容总高度（滚动位置 + 视口高；未挂载时退回视口高）。
  double _contentExtent() {
    if (!_scrollController.hasClients) return 0;
    final pos = _scrollController.position;
    return math.max(
        pos.maxScrollExtent + pos.viewportDimension, pos.viewportDimension);
  }

  DocxNote _boxCurrent(DocxNote n) {
    if (n.id == null) return n;
    return _boxWork[n.id!] ?? n;
  }

  void _boxPointerDown(DocxNote n, PointerDownEvent e) {
    setState(() => _selectedBoxId = n.id);
    _boxDragStart = e.position;
    _boxDragStartNote = n;
    _boxDragged = false;
    if (n.id != null) _boxWork[n.id!] = n;
    // 双击（同一框 380ms 内两次按下且位移 <24px）→ 编辑。
    final now = DateTime.now();
    final lastTime = _boxLastTapTime;
    final lastPos = _boxLastTapPos;
    if (_boxLastTapId == n.id &&
        lastTime != null &&
        lastPos != null &&
        now.difference(lastTime) < const Duration(milliseconds: 380) &&
        (lastPos - e.position).distance < 24) {
      _boxLastTapTime = null;
      _boxLastTapId = null;
      _boxLastTapPos = null;
      widget.onTextBoxEdit?.call(n);
    }
  }

  void _boxPointerMove(
      DocxNote n, PointerMoveEvent e, double contentW, double contentH) {
    final start = _boxDragStart;
    final startNote = _boxDragStartNote;
    if (start == null || startNote == null || startNote.id != n.id) return;
    final delta = e.position - start;
    if (delta.distance > 4) _boxDragged = true;
    if (!_boxDragged) return;
    if (n.id == null) return;
    final nx = (startNote.x + delta.dx / contentW).clamp(0.0, 1.0 - startNote.w);
    final ny = (startNote.y + delta.dy / contentH).clamp(0.0, 0.98);
    _boxWork[n.id!] = startNote.copyWith(x: nx, y: ny);
    setState(() {});
  }

  void _boxPointerUp(DocxNote n, PointerUpEvent e) {
    final moved = _boxDragged;
    if (!moved && _boxDragStart != null) {
      final now = DateTime.now();
      _boxLastTapTime = now;
      _boxLastTapId = n.id;
      _boxLastTapPos = e.position;
    }
    DocxNote? work;
    if (n.id != null) work = _boxWork.remove(n.id);
    if (moved && work != null) {
      widget.onTextBoxChanged?.call(work);
    }
    _boxDragStart = null;
    _boxDragStartNote = null;
    _boxDragged = false;
  }

  /// 单个文本框渲染（内容坐标 → 视口坐标：随滚动平移）。
  Widget _buildTextBox(
    DocxNote n,
    double scroll,
    double contentW,
    double contentH,
    double viewportW,
    double viewportH,
  ) {
    final cur = _boxCurrent(n);
    final fs = cur.fontSize > 0 ? cur.fontSize : widget.fontSize;
    final maxW = (cur.w * contentW).clamp(48.0, viewportW - widget.pageMargin * 2);
    final text = cur.note.isEmpty ? '（空文本框，双击编辑）' : cur.note;
    final color = docxColorOr(cur.color, const Color(0xFF4C1D95));
    final tp = TextPainter(
      text: TextSpan(
          text: text, style: TextStyle(fontSize: fs, color: color, height: 1.4)),
      textDirection: TextDirection.ltr,
      maxLines: 300,
    )..layout(maxWidth: math.max(maxW, 48.0));
    final left = widget.pageMargin + cur.x * contentW;
    final top = cur.y * contentH - scroll;
    final selected = _selectedBoxId == n.id;
    return Positioned(
      left: left.clamp(-10.0, viewportW - 40),
      top: top,
      width: tp.width + 14,
      height: tp.height + 10,
      child: Transform.rotate(
        angle: cur.rotation * math.pi / 180,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _boxPointerDown(n, e),
          onPointerMove: (e) => _boxPointerMove(n, e, contentW, contentH),
          onPointerUp: (e) => _boxPointerUp(n, e),
          onPointerCancel: (_) {
            if (n.id != null) {
              final w = _boxWork.remove(n.id);
              if (_boxDragged && w != null) widget.onTextBoxChanged?.call(w);
            }
            _boxDragStart = null;
            _boxDragStartNote = null;
            _boxDragged = false;
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? color.withValues(alpha: 0.10)
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? Colors.blue
                    : color.withValues(alpha: 0.45),
                width: selected ? 1.6 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(text,
                style: TextStyle(fontSize: fs, color: color, height: 1.4)),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _restore();
    if (widget.jumpToPara != null) {
      jumpToParagraph(widget.jumpToPara!);
    }
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
    _flashTimer?.cancel();
    for (final r in _tapRecognizers.values) {
      r.dispose();
    }
    _tapRecognizers.clear();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.position.pixels;
    if (max <= 0) {
      widget.onProgress?.call(0);
      return;
    }
    final progress = (current / max).clamp(0.0, 1.0);
    widget.onProgress?.call(progress);
  }

  /// Scroll forward/back by roughly one viewport height (used by tap-to-turn).
  void scrollPage(bool forward) {
    if (!_scrollController.hasClients) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = _scrollController.position.pixels +
        (forward ? viewport * 0.85 : -viewport * 0.85);
    _scrollController.animateTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// 跳转到某段落（估算位置 + 4 秒闪烁高亮，方便找到目标）。
  void jumpToParagraph(int index, {bool flash = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final count = widget.paragraphs.length;
      if (max <= 0 || count <= 0) return;
      final target =
          (max * (index / count)).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
      if (flash) {
        setState(() => _flashPara = index);
        _flashTimer?.cancel();
        _flashTimer = Timer(const Duration(seconds: 4), () {
          if (mounted) setState(() => _flashPara = null);
        });
      }
    });
  }

  // ── 批注渲染 ───────────────────────────────────────────────────────

  List<DocxNote> _notesFor(int paraIndex) {
    final all = widget.annotations;
    if (all == null) return const [];
    return all.where((n) => n.paraIndex == paraIndex).toList();
  }

  /// 把一个段落的批注渲染成带样式的 TextSpan 列表。
  List<TextSpan> _buildSpans(
      String para, List<DocxNote> notes, TextStyle base) {
    final children = <TextSpan>[];
    var cursor = 0;
    for (final n in notes) {
      var s = n.startOffset.clamp(0, para.length).toInt();
      var e = n.endOffset.clamp(0, para.length).toInt();
      if (e < s) e = s;
      // 与上一条批注部分重叠时截断起点：保证拼接后文本不重复、
      // 不丢字符（后添加的批注样式赢）。
      if (s < cursor) s = cursor;
      if (s > cursor) {
        children.add(TextSpan(text: para.substring(cursor, s)));
      }
      if (e > s) {
        final color = docxColorOr(n.color, const Color(0xFFFACC15));
        final TextStyle? markStyle = switch (n.style) {
          'underline' => TextStyle(
              decoration: TextDecoration.underline,
              decorationColor: color,
              decorationThickness: 1.8),
          'squiggly' => TextStyle(
              decoration: TextDecoration.underline,
              decorationColor: color,
              decorationStyle: TextDecorationStyle.wavy,
              decorationThickness: 1.3),
          'plain' => null, // 复制/截图记录：无视觉标记
          _ => TextStyle(backgroundColor: color.withValues(alpha: 0.35)),
        };
        // 每条批注一个识别器：点击弹笔记。
        final key = '${n.id ?? 'x'}_${n.paraIndex}_${n.startOffset}';
        final recognizer = _tapRecognizers.putIfAbsent(
            key, () => TapGestureRecognizer());
        recognizer.onTap = () => widget.onHighlightTap?.call(n);
        children.add(TextSpan(
          text: para.substring(s, e),
          style: markStyle,
          recognizer: recognizer,
        ));
        cursor = e;
      }
    }
    if (cursor < para.length) {
      children.add(TextSpan(text: para.substring(cursor)));
    }
    if (children.isEmpty) {
      children.add(TextSpan(text: para));
    }
    return children;
  }

  // ── 富文本渲染（Word 保留格式） ───────────────────────────────────

  TextAlign _alignOf(String a) => switch (a) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      };

  /// run 的样式 = 基础样式 + run 自身属性（b/i/u/strike/sz/color/font/highlight）。
  /// [sizeScale] 把文档字号按「段落基准字号 → 阅读器字号」的比例缩放，
  /// 保留文档内部的大小对比，同时整体跟随阅读器字号设置。
  TextStyle _runStyle(DocxRun r, TextStyle base, double sizeScale) {
    TextDecoration? decoration;
    if (r.underline && r.strike) {
      decoration = TextDecoration.combine(
          [TextDecoration.underline, TextDecoration.lineThrough]);
    } else if (r.underline) {
      decoration = TextDecoration.underline;
    } else if (r.strike) {
      decoration = TextDecoration.lineThrough;
    }
    final fam = r.effectiveFontFamily;
    final List<ui.FontFeature>? features = switch (r.vertAlign) {
      'superscript' => const [ui.FontFeature.superscripts()],
      'subscript' => const [ui.FontFeature.subscripts()],
      _ => null,
    };
    return base.copyWith(
      color: r.colorHex != null
          ? docxColorOr(r.colorHex, base.color ?? const Color(0xFF000000))
          : base.color,
      backgroundColor: r.highlight != null
          ? docxColorOr(r.highlight, const Color(0x00000000))
          : base.backgroundColor,
      fontWeight: r.bold ? FontWeight.bold : base.fontWeight,
      fontStyle: r.italic ? FontStyle.italic : base.fontStyle,
      fontSize: r.fontSize != null ? r.fontSize! * sizeScale : base.fontSize,
      fontFamily: fam ?? base.fontFamily,
      decoration: decoration,
      fontFeatures: features,
    );
  }

  /// 批注标记样式（与 _buildSpans 一致）。
  TextStyle? _markStyleFor(DocxNote n) {
    final color = docxColorOr(n.color, const Color(0xFFFACC15));
    return switch (n.style) {
      'underline' => TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationThickness: 1.8),
      'squiggly' => TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationStyle: TextDecorationStyle.wavy,
          decorationThickness: 1.3),
      'plain' => null,
      _ => TextStyle(backgroundColor: color.withValues(alpha: 0.35)),
    };
  }

  /// 把批注标记叠加到 run 样式上（保留 run 原样式）。
  TextStyle _overlayMarkStyle(TextStyle run, TextStyle? mark) {
    if (mark == null) return run;
    return run.copyWith(
      backgroundColor: mark.backgroundColor,
      decoration: mark.decoration,
      decorationColor: mark.decorationColor,
      decorationStyle: mark.decorationStyle,
      decorationThickness: mark.decorationThickness,
    );
  }

  /// 段落字号缩放：文档基准字号（第一个设字号的 run）→ [target]（默认
  /// 阅读器字号）。无显式字号时 1.0（全部跟随基础样式）。
  double _paraSizeScale(DocxPara para, {double? target}) {
    final basePt = para.baseFontSize;
    if (basePt == null || basePt <= 0) return 1.0;
    return (target ?? widget.fontSize) / basePt;
  }

  /// 富文本段落：runs 展平成「字符→样式」区间，叠加批注标记后合并成 spans。
  List<TextSpan> _buildRichSpans(
      DocxPara para, List<DocxNote> notes, TextStyle base) {
    final text = para.plainText;
    final len = text.length;
    if (len == 0) return const [];

    // 缩放目标 = 基础样式的字号（标题段基础字号已放大 1.4 倍，
    // 显式字号的 run 也按同比例放大，大小对比不丢）。
    final sizeScale = _paraSizeScale(para, target: base.fontSize ?? widget.fontSize);

    // 1. runs → 基础区间。
    var segs = <_RichSeg>[];
    var offset = 0;
    for (final r in para.runs) {
      final t = r.text;
      if (t.isEmpty) continue;
      segs.add(_RichSeg(
          offset, offset + t.length, _runStyle(r, base, sizeScale), null));
      offset += t.length;
    }
    if (segs.isEmpty) {
      segs.add(_RichSeg(0, len, base, null));
    }

    // 2. 叠加批注（与 _buildSpans 相同的光标裁剪：后添加的不覆盖先添加的）。
    var cursor = 0;
    for (final n in notes) {
      var s = n.startOffset.clamp(0, len).toInt();
      var e = n.endOffset.clamp(0, len).toInt();
      if (e < s) e = s;
      if (s < cursor) s = cursor;
      if (e <= s) continue;
      segs = _splitSegs(segs, s);
      segs = _splitSegs(segs, e);
      final mark = _markStyleFor(n);
      final key = '${n.id ?? 'x'}_${n.paraIndex}_${n.startOffset}';
      final recognizer =
          _tapRecognizers.putIfAbsent(key, () => TapGestureRecognizer());
      recognizer.onTap = () => widget.onHighlightTap?.call(n);
      for (final seg in segs) {
        if (seg.start >= s && seg.end <= e) {
          seg.style = _overlayMarkStyle(seg.style, mark);
          seg.recognizer = recognizer;
        }
      }
      cursor = e;
    }

    // 3. 合并相邻且样式/识别器相同的区间。
    final merged = <_RichSeg>[];
    for (final seg in segs) {
      if (seg.end <= seg.start) continue;
      if (merged.isNotEmpty) {
        final last = merged.last;
        if (last.end == seg.start &&
            last.style == seg.style &&
            identical(last.recognizer, seg.recognizer)) {
          last.end = seg.end;
          continue;
        }
      }
      merged.add(_RichSeg(seg.start, seg.end, seg.style, seg.recognizer));
    }

    return merged
        .map((m) => TextSpan(
              text: text.substring(m.start, m.end),
              style: m.style,
              recognizer: m.recognizer,
            ))
        .toList();
  }

  List<_RichSeg> _splitSegs(List<_RichSeg> segs, int x) {
    final out = <_RichSeg>[];
    for (final seg in segs) {
      if (seg.end <= x || seg.start >= x) {
        out.add(seg);
      } else {
        out.add(_RichSeg(seg.start, x, seg.style, seg.recognizer));
        out.add(_RichSeg(x, seg.end, seg.style, seg.recognizer));
      }
    }
    return out;
  }

  void _handleSelectionText(int paraIndex, String text) {
    if (text.trim().isEmpty) {
      if (_lastSel?.paraIndex == paraIndex) {
        setState(() => _lastSel = null);
      }
      return;
    }
    // 选区必须能在段落原文里精确匹配到（同一文本源，几乎必然成功）。
    final start = widget.paragraphs[paraIndex].indexOf(text);
    if (start < 0) {
      _lastSel = null;
      return;
    }
    setState(() {
      _lastSel = TxtSelection(
        paraIndex: paraIndex,
        text: text,
        start: start,
        end: start + text.length,
      );
    });
  }

  // ── 选中菜单（与 PDF/EPUB 引擎同款两行布局） ──────────────────────

  /// 选中功能栏（停靠版，与 PDF/EPUB 引擎同款两行布局）。
  ///
  /// 不用 SelectionArea 的浮动 contextMenuBuilder：它在 Windows 桌面上
  /// 只认右键，拖选后永远看不到菜单（与 pdfrx 同一个坑）。改为
  /// onSelectionChanged 驱动停靠栏，选中即弹出，全平台一致。
  Widget _buildSelectionBar(ColorScheme colors) {
    const dotColors = <String>[
      '#F87171',
      '#FACC15',
      '#4ADE80',
      '#60A5FA',
      '#A78BFA',
    ];
    const styleDefault = <String, String>{
      'highlight': '#FACC15',
      'underline': '#4ADE80',
      'squiggly': '#60A5FA',
    };
    final effectiveColor = _selColor ?? styleDefault[_selStyle];

    Widget btn(IconData icon, String label, VoidCallback onTap,
        {Color? color}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ],
          ),
        ),
      );
    }

    // 取当前选区；选区不存在则不动。
    void act(String name, {void Function(TxtSelection sel)? then}) {
      final sel = _lastSel;
      if (sel == null) return;
      if (then != null) {
        then(sel);
      } else {
        widget.onSelectionAction?.call(name, sel);
      }
    }

    // 当前选区若正好是某条已有批注的范围 → 提供「查看批注」按钮
    // （用户要求：像 EPUB 一样，选中/点击高亮部分就能看到批注内容）。
    DocxNote? matched;
    final selNow = _lastSel;
    final all = widget.annotations;
    if (selNow != null && all != null) {
      for (final n in all) {
        if (n.paraIndex == selNow.paraIndex &&
            n.startOffset == selNow.start &&
            n.endOffset == selNow.end &&
            n.style != 'plain') {
          matched = n;
          break;
        }
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: const [
          BoxShadow(
              color: Color(0x22000000),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：功能栏（窄屏横向滚动）。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (matched != null) ...[
                  btn(Icons.visibility_outlined, '查看批注',
                      () => widget.onHighlightTap?.call(matched!),
                      color: colors.primary),
                  const SizedBox(width: 2),
                ],
                btn(Icons.copy, '复制', () => act('copy',
                        then: (sel) {
                      Clipboard.setData(ClipboardData(text: sel.text));
                      widget.onSelectionAction?.call('copy', sel);
                    })),
                btn(Icons.search, '搜索', () => act('search')),
                btn(Icons.translate, '翻译', () => act('translate')),
                btn(Icons.record_voice_over_outlined, '朗读',
                    () => act('tts')),
                btn(Icons.edit_note, '批注',
                    () => act('note', then: (sel) {
                          widget.onSelectionAction?.call('note', sel);
                        }),
                    color: colors.primary),
                btn(Icons.auto_awesome, 'AI', () => act('ai'),
                    color: const Color(0xFF7C3AED)),
                btn(Icons.share_outlined, '分享', () => act('share')),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 第二行：高亮批注栏（样式三态 + 颜色圆点）。
          Row(
            children: [
              for (final style in const [
                ('highlight', '高亮'),
                ('underline', '下划线'),
                ('squiggly', '波浪线'),
              ]) ...[
                GestureDetector(
                  onTap: () {
                    setState(() => _selStyle = style.$1);
                    _applyMark(styleDefault[style.$1]!, style.$1, '');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: _selStyle == style.$1
                          ? colors.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(style.$2,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: _selStyle == style.$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _selStyle == style.$1
                                ? colors.onPrimaryContainer
                                : colors.onSurfaceVariant)),
                  ),
                ),
                const SizedBox(width: 2),
              ],
              const Spacer(),
              for (final hex in dotColors)
                GestureDetector(
                  onTap: () {
                    setState(() => _selColor = hex);
                    _applyMark(hex, _selStyle, '');
                  },
                  child: Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color:
                          Color(int.parse(hex.replaceFirst('#', '0xFF'))),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: effectiveColor == hex
                            ? colors.primary
                            : colors.outline.withValues(alpha: 0.4),
                        width: effectiveColor == hex ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 高亮栏点击 → 立即按样式/颜色应用（父级 upsert 落库）。
  void _applyMark(String color, String style, String note) {
    final sel = _lastSel;
    if (sel == null) return;
    widget.onAnnotate?.call(sel, color, style, note);
  }

  // ── build ──────────────────────────────────────────────────────────

  /// 渲染一个段落（扁平下标 [index]）：富文本 + 批注标记 + 图片批注 +
  /// 段落边框 + 点击朗读 + 批注模式选区。段落/表格单元格/文本框共用。
  Widget _buildParaBlock(int index) {
    final colors = Theme.of(context).colorScheme;
    final effectiveColor = widget.textColor ?? colors.onSurface;
    final para = index < widget.paragraphs.length ? widget.paragraphs[index] : '';
    if (para.isEmpty) {
      // Preserve blank lines as spacing between paragraphs.
      return const SizedBox(height: 12);
    }
    final rich = widget.richParagraphs;
    final docxPara = (rich != null && index < rich.length) ? rich[index] : null;
    var baseStyle = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      color: effectiveColor,
      fontFamily: widget.fontFamily,
    );
    if (docxPara != null) {
      // 行距：Word 的倍数行距 / 固定行距优先于阅读器行距设置。
      final ls = docxPara.lineSpacingMultiple;
      final lsp = docxPara.lineSpacingPt;
      if (ls != null) {
        baseStyle = baseStyle.copyWith(height: ls);
      } else if (lsp != null) {
        baseStyle = baseStyle.copyWith(
            height: math.max(lsp / widget.fontSize, 0.8));
      }
      if (docxPara.isTitle) {
        baseStyle = baseStyle.copyWith(
          fontSize: widget.fontSize * 1.4,
          fontWeight: FontWeight.bold,
        );
      }
    }

    Widget text;
    final notesForPara = _annotationMode ? _notesFor(index) : const <DocxNote>[];
    if (!_annotationMode) {
      text = SelectableText(
        para,
        style: baseStyle,
        textAlign: docxPara != null ? _alignOf(docxPara.alignment) : null,
      );
    } else if (docxPara != null) {
      final spans = _buildRichSpans(docxPara, notesForPara, baseStyle);
      text = Text.rich(
        TextSpan(style: baseStyle, children: spans),
        textAlign: _alignOf(docxPara.alignment),
      );
    } else {
      final spans = _buildSpans(para, notesForPara, baseStyle);
      text = Text.rich(TextSpan(style: baseStyle, children: spans));
    }

    // 带标注的段落不包 TapCatcher：点击高亮范围要弹笔记（span 识别器），
    // 不能同时触发「点击段落开始朗读」。无标注段落保持旧行为。
    // 编辑模式下所有段落都包 TapCatcher，点击进入段落编辑。
    Widget paraWidget;
    if (widget.editMode) {
      paraWidget = TapCatcher(
        onTap: () => widget.onEditParagraph?.call(index),
        child: text,
      );
    } else if (_annotationMode && notesForPara.isNotEmpty) {
      paraWidget = text;
    } else {
      paraWidget = TapCatcher(
        onTap: () => widget.onParagraphTap?.call(index),
        child: text,
      );
    }

    // style='image' 的批注 = 插入该段的照片/截图：渲染在段落下方。
    final imageNotes = notesForPara.where((n) => n.style == 'image').toList();
    if (imageNotes.isNotEmpty) {
      final images = <Widget>[];
      for (final n in imageNotes) {
        final imgPath = n.imagePath;
        if (imgPath == null || imgPath.isEmpty) continue;
        if (!File(imgPath).existsSync()) continue;
        images.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: GestureDetector(
              onTap: () => widget.onHighlightTap?.call(n),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(imgPath),
                  fit: BoxFit.fitWidth,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      }
      if (images.isNotEmpty) {
        paraWidget = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [paraWidget, ...images],
        );
      }
    }

    // 段落框线（w:pBdr）：每侧独立线宽/颜色/线型（含虚线/点线/双线）。
    final bdr = docxPara?.pBdr;
    if (bdr != null && bdr.any) {
      paraWidget = _DocxParaBorderBox(bdr: bdr, child: paraWidget);
    }

    // 编辑模式选中段落：主题色高亮框。
    if (widget.editMode && widget.editSelectedPara == index) {
      paraWidget = Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.06),
          border: Border.all(color: colors.primary, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: paraWidget,
      );
    }

    // 回跳闪烁：目标段落加一层琥珀色底。
    if (_flashPara == index) {
      paraWidget = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x33FFB300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: paraWidget,
      );
    }

    // 段落缩进（左/右，按文档 pt 值）。
    final indentLeft = docxPara?.indentLeftPt ?? 0;
    final indentRight = docxPara?.indentRightPt ?? 0;
    if (indentLeft > 0 || indentRight > 0) {
      paraWidget = Padding(
        padding: EdgeInsets.only(left: indentLeft, right: indentRight),
        child: paraWidget,
      );
    }

    // 段落底纹（w:pPr/w:shd）：整段铺底色。
    final shading = docxPara?.shadingHex;
    if (shading != null) {
      paraWidget = Container(
        width: double.infinity,
        color: docxColorOr(shading, const Color(0x00000000)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: paraWidget,
      );
    }

    // 段前/段后间距（w:spacing before/after，pt）。
    paraWidget = Padding(
      padding: EdgeInsets.only(
        top: docxPara?.spacingBeforePt ?? 0,
        bottom: 8 + (docxPara?.spacingAfterPt ?? 0),
      ),
      child: paraWidget,
    );

    if (!_annotationMode) return paraWidget;
    // 批注模式：每段一个 SelectionArea（选区不跨段）。
    // 浮动右键菜单已禁用（用停靠功能栏替代）。
    return SelectionArea(
      contextMenuBuilder: (ctx, state) => const SizedBox.shrink(),
      onSelectionChanged: (content) =>
          _handleSelectionText(index, content?.plainText ?? ''),
      child: paraWidget,
    );
  }

  /// 渲染表格块：按行×单元格排布，保留每侧框线（宽/色/内横竖线）、
  /// 列宽比例、单元格底纹、垂直对齐与表格对齐（无显式框线时画淡网格）。
  Widget _buildTableBlock(DocxBlock b) {
    final rows = b.cells ?? const <List<List<int>>>[];
    if (rows.isEmpty) return const SizedBox(height: 12);
    final tb = b.tableBorders;
    final outerColor = docxColorOr(b.borderColorHex,
        b.bordered ? const Color(0xFF595959) : const Color(0xFFC9C9C9));

    BorderSide sideOf(DocxBorderSide? s) {
      if (s != null) {
        return BorderSide(
          color: docxColorOr(s.colorHex, outerColor),
          width: s.width.clamp(0.5, 4.0),
        );
      }
      return BorderSide(
        color: outerColor,
        width: b.bordered ? b.borderWidth.clamp(0.5, 3.0) : 0.7,
      );
    }

    BorderSide innerOf(DocxBorderSide? s) {
      if (s != null) {
        return BorderSide(
          color: docxColorOr(s.colorHex, outerColor),
          width: s.width.clamp(0.5, 4.0),
        );
      }
      // 无内部线定义：淡网格兜底，表格结构仍可见。
      return BorderSide(
        color: b.bordered ? outerColor : const Color(0xFFC9C9C9),
        width: b.bordered ? (b.borderWidth.clamp(0.5, 3.0)) : 0.7,
      );
    }

    Widget table = Table(
      border: TableBorder(
        top: sideOf(tb?.top),
        bottom: sideOf(tb?.bottom),
        left: sideOf(tb?.left),
        right: sideOf(tb?.right),
        horizontalInside: innerOf(tb?.insideH),
        verticalInside: innerOf(tb?.insideV),
      ),
      columnWidths: b.colWidths != null && b.colWidths!.isNotEmpty
          ? {
              for (var i = 0; i < b.colWidths!.length; i++)
                i: FlexColumnWidth(b.colWidths![i]),
            }
          : const {},
      defaultColumnWidth: const FlexColumnWidth(1),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (var ri = 0; ri < rows.length; ri++)
          TableRow(
            children: [
              for (var ci = 0; ci < rows[ri].length; ci++)
                _buildTableCell(b, ri, ci, rows[ri][ci]),
            ],
          ),
      ],
    );

    // 表格宽度百分比（w:tblW type=pct）与对齐（tblPr/jc）。
    final pct = b.tableWidthPct;
    if (pct != null) {
      table = FractionallySizedBox(
        widthFactor: (pct / 100.0).clamp(0.1, 1.0),
        child: table,
      );
    }
    switch (b.tableAlign) {
      case 'center':
        table = Align(alignment: Alignment.center, child: table);
        break;
      case 'right':
        table = Align(alignment: Alignment.centerRight, child: table);
        break;
      default:
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: table,
    );
  }

  /// 表格单元格：底纹 + 垂直对齐 + 内部段落。
  Widget _buildTableCell(DocxBlock b, int ri, int ci, List<int> paras) {
    String? fill;
    final fills = b.cellFills;
    if (fills != null && ri < fills.length && ci < fills[ri].length) {
      fill = fills[ri][ci];
    }
    var vAlign = TableCellVerticalAlignment.middle;
    final vAligns = b.cellVAligns;
    if (vAligns != null && ri < vAligns.length && ci < vAligns[ri].length) {
      vAlign = switch (vAligns[ri][ci]) {
        'top' => TableCellVerticalAlignment.top,
        'bottom' => TableCellVerticalAlignment.bottom,
        _ => TableCellVerticalAlignment.middle,
      };
    }
    return TableCell(
      verticalAlignment: vAlign,
      child: Container(
        color: fill != null
            ? docxColorOr(fill, const Color(0x00000000))
            : null,
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final idx in paras) _buildCellText(idx),
          ],
        ),
      ),
    );
  }

  /// 表格单元格里的一个段落：富文本 + 批注标记 + 批注模式选区（可在
  /// 单元格文字上划词批注）。
  Widget _buildCellText(int flatIdx) {
    final colors = Theme.of(context).colorScheme;
    final effectiveColor = widget.textColor ?? colors.onSurface;
    final para = flatIdx < widget.paragraphs.length
        ? widget.paragraphs[flatIdx]
        : '';
    final rich = widget.richParagraphs;
    final docxPara =
        (rich != null && flatIdx < rich.length) ? rich[flatIdx] : null;
    var baseStyle = TextStyle(
      fontSize: (widget.fontSize * 0.92).clamp(11.0, 18.0),
      height: widget.lineHeight * 0.95,
      color: effectiveColor,
      fontFamily: widget.fontFamily,
    );
    if (docxPara != null && docxPara.isTitle) {
      baseStyle = baseStyle.copyWith(fontWeight: FontWeight.bold);
    }
    final notesForPara =
        _annotationMode ? _notesFor(flatIdx) : const <DocxNote>[];
    Widget text;
    if (docxPara != null) {
      final spans = _buildRichSpans(docxPara, notesForPara, baseStyle);
      text = Text.rich(
        TextSpan(style: baseStyle, children: spans),
        textAlign: _alignOf(docxPara.alignment),
      );
    } else {
      final spans = _buildSpans(para, notesForPara, baseStyle);
      text = Text.rich(TextSpan(style: baseStyle, children: spans));
    }
    if (!_annotationMode && !widget.editMode) return text;
    if (widget.editMode) {
      Widget sel = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onEditParagraph?.call(flatIdx),
        child: text,
      );
      if (widget.editSelectedPara == flatIdx) {
        sel = Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.06),
            border: Border.all(color: colors.primary, width: 1.2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: sel,
        );
      }
      return sel;
    }
    return SelectionArea(
      contextMenuBuilder: (ctx, state) => const SizedBox.shrink(),
      onSelectionChanged: (content) =>
          _handleSelectionText(flatIdx, content?.plainText ?? ''),
      child: text,
    );
  }

  /// 渲染文本框块：保留 Word 文本框的描边颜色/线宽与填充色，内部段落照常渲染。
  Widget _buildTextBoxBlock(DocxBlock b) {
    final colors = Theme.of(context).colorScheme;
    final strokeColor =
        docxColorOr(b.textboxStrokeColorHex, const Color(0xFF9E9E9E));
    final strokeWidth = (b.textboxStrokeWidthPt ?? 1.0).clamp(0.5, 4.0);
    final fill = b.textboxFillHex;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      decoration: BoxDecoration(
        color: fill != null
            ? docxColorOr(fill, colors.surfaceContainerLowest)
            : colors.surfaceContainerLowest.withValues(alpha: 0.45),
        border: Border.all(color: strokeColor, width: strokeWidth),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = b.paraStart;
              i < b.paraStart + b.paraCount && i < widget.paragraphs.length;
              i++)
            _buildParaBlock(i),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    if (widget.paragraphs.isEmpty) {
      return Center(
        child: Text('文件内容为空',
            style: TextStyle(color: colors.onSurfaceVariant)),
      );
    }

    // 选中功能栏（停靠版）：SelectionArea 的浮动菜单在 Windows 只认右键，
    // 改用 onSelectionChanged 驱动，选中即弹出。
    final selectionBar = (_annotationMode && _lastSel != null)
        ? _buildSelectionBar(colors)
        : null;

    // Use ListView.builder so the framework only builds visible paragraphs.
    final blocks = widget.blocks;
    final useBlocks = blocks != null && blocks.isNotEmpty;
    final list = ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.symmetric(
        horizontal: widget.pageMargin,
        vertical: 16,
      ),
      itemCount: useBlocks ? blocks.length : widget.paragraphs.length,
      itemBuilder: (context, index) {
        if (!useBlocks) return _buildParaBlock(index);
        final b = blocks[index];
        switch (b.type) {
          case DocxBlockType.para:
            return _buildParaBlock(b.paraStart);
          case DocxBlockType.table:
            return _buildTableBlock(b);
          case DocxBlockType.textbox:
            return _buildTextBoxBlock(b);
        }
      },
    );

    // 浮动文本框层：盖在正文上，随内容滚动平移（坐标按全文比例锚定）。
    Widget content = list;
    if (_textBoxes.isNotEmpty) {
      content = LayoutBuilder(builder: (ctx, constraints) {
        final viewportW = constraints.maxWidth;
        final viewportH = constraints.maxHeight;
        return ClipRect(
          child: ListenableBuilder(
            listenable: _scrollController,
            builder: (ctx, _) {
              final scroll = _scrollController.hasClients
                  ? _scrollController.position.pixels
                  : 0.0;
              final contentH = math.max(_contentExtent(), viewportH);
              final contentW =
                  math.max(viewportW - widget.pageMargin * 2, 1.0);
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  list,
                  for (final n in _textBoxes)
                    _buildTextBox(n, scroll, contentW, contentH, viewportW,
                        viewportH),
                ],
              );
            },
          ),
        );
      });
    }

    // ⚠️ 选中功能栏出现/消失时，不能让列表子树换父节点：一旦从
    // 「直接 return content」切到「Column(bar, Expanded(content))」，
    // Flutter 会把整个 ListView 元素树销毁重建 → ScrollController 的
    // 滚动位置丢失 → 页面跳回顶部（用户反馈「长按选字跳回顶部，
    // 同时功能栏出现」的根因）。这里固定用 Column 骨架：功能栏槽位
    // 永远存在（没有选区时放 SizedBox.shrink），Expanded(content)
    // 始终在同一个槽位，列表元素不重建，滚动位置不动。
    return Column(
      children: [
        selectionBar ?? const SizedBox.shrink(),
        Expanded(child: content),
      ],
    );
  }
}

/// 富文本渲染中间态：一段 [start,end) 的字符区间及其样式/识别器。
class _RichSeg {
  int start;
  int end;
  TextStyle style;
  TapGestureRecognizer? recognizer;

  _RichSeg(this.start, this.end, this.style, this.recognizer);
}

/// 段落框线容器：每侧独立线宽/颜色/线型（实线/虚线/点线/双线）。
/// 用 CustomPaint 画线，[Border] 只支持实线，画不出 Word 的虚线框。
class _DocxParaBorderBox extends StatelessWidget {
  final DocxParaBorder bdr;
  final Widget child;

  const _DocxParaBorderBox({required this.bdr, required this.child});

  @override
  Widget build(BuildContext context) {
    final top = bdr.top?.width ?? 0.0;
    final bottom = bdr.bottom?.width ?? 0.0;
    final left = bdr.left?.width ?? 0.0;
    final right = bdr.right?.width ?? 0.0;
    return CustomPaint(
      foregroundPainter: _DocxBorderPainter(bdr),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(
          math.max(6.0, left + 4),
          math.max(4.0, top + 3),
          math.max(6.0, right + 4),
          math.max(3.0, bottom + 3),
        ),
        child: child,
      ),
    );
  }
}

/// 画段落框线（0 上 / 1 右 / 2 下 / 3 左）。
class _DocxBorderPainter extends CustomPainter {
  final DocxParaBorder bdr;

  _DocxBorderPainter(this.bdr);

  @override
  void paint(Canvas canvas, Size size) {
    _drawSide(canvas, size, bdr.top, 0);
    _drawSide(canvas, size, bdr.right, 1);
    _drawSide(canvas, size, bdr.bottom, 2);
    _drawSide(canvas, size, bdr.left, 3);
  }

  void _drawSide(Canvas canvas, Size size, DocxBorderSide? side, int which) {
    if (side == null) return;
    final half = side.width / 2;
    final paint = Paint()
      ..color = docxColorOr(side.colorHex, const Color(0xFF595959))
      ..strokeWidth = side.width.clamp(0.5, 4.0)
      ..strokeCap = StrokeCap.butt;
    final Offset a;
    final Offset b;
    switch (which) {
      case 0: // 上
        a = Offset(0, half);
        b = Offset(size.width, half);
        break;
      case 1: // 右
        a = Offset(size.width - half, 0);
        b = Offset(size.width - half, size.height);
        break;
      case 2: // 下
        a = Offset(0, size.height - half);
        b = Offset(size.width, size.height - half);
        break;
      default: // 左
        a = Offset(half, 0);
        b = Offset(half, size.height);
        break;
    }
    final style = side.style;
    if (style == 'dotted') {
      _dashLine(canvas, a, b, paint, 1.2, 2.4, round: true);
    } else if (style == 'dashed' ||
        style == 'dashSmallGap' ||
        style == 'dotDash' ||
        style == 'dotDotDash' ||
        style == 'dashDotStroked') {
      _dashLine(canvas, a, b, paint, 5.0, 3.0);
    } else if (style == 'double') {
      paint.strokeWidth = (side.width / 3).clamp(0.5, 1.5);
      final horizontal = which == 0 || which == 2;
      final offset = Offset(horizontal ? 0 : side.width * 1.1,
          horizontal ? side.width * 1.1 : 0);
      canvas.drawLine(a - offset, b - offset, paint);
      canvas.drawLine(a + offset, b + offset, paint);
    } else {
      // single / thick / wave 等：实线。
      canvas.drawLine(a, b, paint);
    }
  }

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint, double dash,
      double gap,
      {bool round = false}) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    final savedCap = paint.strokeCap;
    if (round) paint.strokeCap = StrokeCap.round;
    var d = 0.0;
    while (d < total) {
      final end = math.min(d + dash, total);
      canvas.drawLine(a + dir * d, a + dir * end, paint);
      d = end + gap;
    }
    paint.strokeCap = savedCap;
  }

  @override
  bool shouldRepaint(_DocxBorderPainter oldDelegate) =>
      oldDelegate.bdr != bdr;
}
