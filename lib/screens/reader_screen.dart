import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../config/app_config.dart';
import '../providers/app_providers.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_settings_provider.dart';
import '../services/docx_loader.dart';
import '../services/docx_edit_service.dart';
import '../services/epub_loader.dart';
import '../services/pdf_ocr_service.dart';
import '../services/readest_style.dart';
import '../services/screen_capture.dart';
import '../services/shot_actions.dart';
import '../services/shot_library.dart';
import '../services/translate_service.dart';
import '../services/tts_service.dart';
import '../services/txt_loader.dart';
import '../services/web_search.dart';
import '../widgets/ai_dialog_widget.dart';
import '../widgets/epub_reader_view.dart';
import '../widgets/markdown_reader_view.dart';
import '../widgets/pick_image_source_sheet.dart';
import '../widgets/region_crop.dart';
import '../widgets/txt_reader_view.dart';
import 'package:open_file/open_file.dart';
import 'readest_reader_screen.dart';

/// PDF 文本框的拖拽类型（移动 / 右下角缩放 / 顶部旋转）。
enum _InkTextDrag { none, move, resize, rotate }

/// 文本框命中部位（身体 / 顶部旋转手柄 / 右下角缩放手柄）。
enum _InkTextPart { none, body, rotate, resize }

/// AI 插入文字的备选字体颜色（十六进制，默认紫罗兰）。
const List<String> _insertPalette = [
  '#4C1D95', // 紫
  '#1D4ED8', // 蓝
  '#0D9488', // 青
  '#16A34A', // 绿
  '#CA8A04', // 金
  '#EA580C', // 橙
  '#DC2626', // 红
  '#475569', // 灰
  '#000000', // 黑
];

/// '#RRGGBB' → 0xFFRRGGBB 整数（PDF 文本框颜色）。
int _hexToArgbInt(String hex) {
  final v = hex.replaceFirst('#', '');
  return int.tryParse('FF$v', radix: 16) ?? 0xFF4C1D95;
}

/// AI 插入确认弹窗里的字体颜色圆点选择行（Word/PDF 共用）。
class _InsertColorDots extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _InsertColorDots({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final hex in _insertPalette)
          GestureDetector(
            onTap: () => onChanged(hex),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: docxColorOr(hex, const Color(0xFF000000)),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected == hex ? primary : Colors.black12,
                  width: selected == hex ? 2.5 : 1,
                ),
              ),
              child: selected == hex
                  ? const Icon(Icons.check, size: 15, color: Colors.white)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// EPUB / PDF reader screen.
///
/// Uses [pdfrx] for PDF rendering and [EpubReaderView] for EPUB rendering.
/// Both are wired into the existing [readerProvider] for progress tracking
/// and annotation support.
///
/// When [initialAnchor] is set (e.g. coming from the notes centre), the reader
/// will jump to that position and briefly flash the target highlight.
class ReaderScreen extends ConsumerStatefulWidget {
  final Book book;
  final TextAnchor? initialAnchor;
  final int? initialAnnotationId;

  /// 强制走 pdfrx 老引擎（readest 引擎内「手写批注」入口用；
  /// PDF 默认已路由到 readest 引擎，此开关保留手写/旧批注路径）。
  final bool forceLegacyPdf;

  const ReaderScreen({
    super.key,
    required this.book,
    this.initialAnchor,
    this.initialAnnotationId,
    this.forceLegacyPdf = false,
  });

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  // PDF state
  PdfViewerController? _pdfController;
  PdfDocument? _pdfDocument;
  int _pdfCurrentPage = 1;
  int _pdfTotalPages = 1;
  bool _pdfResumeDone = false; // 打开后是否已恢复到上次阅读页

  // PDF 手写批注状态（v2：一页 = 笔迹 + 文本框，见 models/pdf_ink.dart）
  bool _inkMode = false;
  final Map<int, PdfInkPage> _pdfInkByPage = {};
  List<WhiteboardPoint> _inkCurrent = [];
  int _inkColor = 0xFFE53935;
  double _inkWidth = 2.2; // 画笔粗细（PDF points）
  bool _inkEraser = false;
  bool _inkHighlighter = false;
  bool _inkSelect = false; // 选择工具（点选/拖动/删除）
  bool _inkTextTool = false; // 文本工具（点页面放文本框）
  bool _pdfOcrRunning = false; // OCR 识别中（扫描版 PDF 用）
  int _inkEraserMode = 0; // 0 分段擦除 / 1 白覆盖 / 2 整条删除
  String? _selectedStrokeId;
  String? _selectedTextId;
  String? _selectedImageId; // 选中图片（截图/相册插入批注图层的图片，问题14）
  Offset? _inkDragLast; // 选择拖动：上一次的归一化位置
  final List<Map<int, PdfInkPage>> _inkUndo = [];
  final List<Map<int, PdfInkPage>> _inkRedo = [];
  int _inkCounter = 0;

  // 文本框拖动状态（移动/缩放/旋转）与起点的归一化坐标/快照。
  _InkTextDrag _inkTextDrag = _InkTextDrag.none;
  Offset? _inkTextDragStartN;
  PdfTextItem? _inkTextDragStartItem;

  // 图片拖动状态（移动 / 右下角缩放）与起点的归一化坐标/快照（问题14）。
  bool _inkImageResize = false;
  Offset? _inkImageDragStartN;
  PdfImageItem? _inkImageDragStartItem;

  // 拖动手势层在按下瞬间的原点（页面坐标系）。手势层会跟着被拖对象移动，
  // 而指针事件的 localPosition 始终以「按下时的层位置」换算，所以必须锁住
  // 按下那一刻的原点，否则每帧多算一次位移 → 文本框/图片一拖就飞向边缘。
  Offset? _inkTextLayerOrigin;
  Offset? _inkImageLayerOrigin;

  // 图片解码缓存（按文件名）+ 加载去重（避免每次 build 重复异步解码）。
  final Map<String, ui.Image> _pdfImageCache = {};
  final Set<String> _pdfImageLoading = {};

  // ── PDF 文字选择功能栏（选中后自动弹出，Windows/Android 一致） ──
  bool _pdfSelectionActive = false;
  String _pdfSelStyle = 'highlight'; // highlight / underline / squiggly
  String? _pdfSelColor; // null = 跟随样式默认色
  // 选区截图暂存：选中文本 → PNG 路径（批注/AI 确认时捆绑进记录，§2.8）。
  final Map<String, String> _pendingPdfShots = {};

  // DOCX 批注（Phase 4：段落索引 + 字符偏移锚点）。
  List<DocxNote> _docxNotes = const [];

  // 从笔记中心跳来的 PDF 定位闪烁（在该页高亮矩形上画脉动描边）。
  int? _pdfFlashPage;
  DateTime? _pdfFlashStart;
  Timer? _pdfFlashTimer;

  // 听书（TTS）状态。
  bool _ttsActive = false;
  bool _ttsPaused = false;
  String _ttsText = '';
  double _ttsRate = 0.5;

  // TXT/DOCX 段落缓存（供朗读从当前位置开始）。
  List<String>? _txtParagraphs;
  List<String>? _docxParagraphs;

  // EPUB state
  final _epubViewKey = GlobalKey<EpubReaderViewState>();
  Future<LoadedEpub>? _epubFuture;
  String? _epubPathLoaded;
  int _epubSection = 0;
  int _epubTotal = 0;
  bool _initialJumpDone = false;

  // TXT / DOCX / Markdown state
  final _txtViewKey = GlobalKey<TxtReaderViewState>();
  final _mdViewKey = GlobalKey<MarkdownReaderViewState>();
  Future<LoadedTxt>? _txtFuture;
  String? _txtPathLoaded;
  Future<LoadedDocx>? _docxFuture;
  String? _docxPathLoaded;
  String? _mdContent;
  String? _mdPathLoaded;

  // Word 段落级编辑（编辑模式开关 + 当前已解析的文档树，写回用）。
  bool _docxEditMode = false;
  LoadedDocx? _docxLoaded;

  /// 编辑模式当前选中的段落（扁平下标）；工具栏的格式操作作用于它。
  int? _docxEditSel;

  @override
  void initState() {
    super.initState();
    _pdfController = PdfViewerController();
    // EPUB 走 readest 引擎（foliate-js，readest 同款分页体验）。
    // PDF 统一走 pdfrx 内置引擎：readest 的 pdf.js 在用户设备上反复
    // 「超时 → 回退」并弹出误导性的「引擎加载失败」提示（用户反馈），
    // 而 pdfrx 打开 PDF 稳定且承载手写批注 / AI 页边插字 / 带痕迹导出
    // 全部能力——PDF 直接进 pdfrx，不再做引擎探测。
    // 例外：从笔记中心跳转（旧 sectionIndex/pageIndex 锚点）仍走旧引擎；
    // forceLegacyPdf 直接进 pdfrx。
    final ext = (widget.book.extension ?? '').toLowerCase();
    final useReadest = (ext == 'epub') &&
        widget.initialAnchor == null &&
        !widget.forceLegacyPdf &&
        widget.book.localPath != null;
    if (useReadest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ReadestReaderScreen(book: widget.book),
          ),
        );
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readerProvider.notifier).openBook(widget.book);
      // 从笔记中心跳来 → 提示用户定位位置会闪烁显示，方便找段落。
      if (widget.initialAnchor != null && mounted) {
        final anchor = widget.initialAnchor!;
        final label = anchor.kind == AnchorKind.plain &&
                anchor.startOffset != null
            ? '第 ${anchor.startOffset! + 1} 段'
            : anchor.display;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已定位到「$label」，目标内容正在闪烁显示'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    TtsService.instance.stop();
    // 退出前把未落盘的笔迹再写一遍（防「写完马上退出 → 笔迹消失」）。
    _flushPdfInkNow();
    _pdfFlashTimer?.cancel();
    _pdfController = null;
    // 释放图片批注的解码缓存（避免 ui.Image 占用的纹理内存泄漏）。
    for (final img in _pdfImageCache.values) {
      img.dispose();
    }
    _pdfImageCache.clear();
    super.dispose();
  }

  /// 把内存里所有页的笔迹立刻发起落盘（best-effort，不等 await）。
  void _flushPdfInkNow() {
    for (final page in _pdfInkByPage.keys.toList()) {
      unawaited(_savePdfInk(page));
    }
  }

  void _onPdfPageChanged(int? pageNumber) {
    if (pageNumber == null) return;
    setState(() {
      _pdfCurrentPage = pageNumber;
      // 翻页后旧页的选中框/面板没有意义，清掉。
      _selectedStrokeId = null;
      _selectedTextId = null;
      _selectedImageId = null;
      _inkTextDrag = _InkTextDrag.none;
      _inkTextDragStartN = null;
      _inkTextDragStartItem = null;
    });
    // 笔记中心跳转：引擎确认到达目标页 → 立刻启动定位闪烁。
    if (_pdfJumpTarget != null && pageNumber == _pdfJumpTarget) {
      _pdfJumpTarget = null;
      _startPdfFlash(pageNumber);
    }
    if (_pdfTotalPages > 0) {
      final percent = (pageNumber / _pdfTotalPages * 100).round();
      ref.read(readerProvider.notifier).updateProgress(percent.clamp(0, 100));
    }
    _loadPdfInk(pageNumber);
  }

  void _onEpubSectionChanged(int index, int total) {
    setState(() {
      _epubSection = index;
      _epubTotal = total;
    });
    if (total > 0) {
      final percent = ((index + 1) / total * 100).round();
      ref.read(readerProvider.notifier).updateProgress(percent.clamp(0, 100));
    }
  }

  @override
  Widget build(BuildContext context) {
    final reader = ref.watch(readerProvider);
    final settings = ref.watch(readerSettingsProvider);
    final colors = Theme.of(context).colorScheme;
    final ext = (reader.book?.extension ?? widget.book.extension ?? '').toLowerCase();

    final bgColor = settings.backgroundColor == Colors.transparent
        ? null
        : settings.backgroundColor;

    return Scaffold(
      appBar: settings.immersive
          ? null
          : AppBar(
              title: Text(reader.book?.title ?? widget.book.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  icon: Icon(
                    _ttsActive
                        ? Icons.stop_circle_outlined
                        : Icons.record_voice_over_outlined,
                    color: _ttsActive ? colors.primary : null,
                  ),
                  tooltip: _ttsActive ? '停止朗读' : '听书朗读',
                  onPressed: () => _ttsActive ? _stopTts() : _startTts(ext),
                ),
                // Word/TXT/MD 框选区域截图（可调区域，保存本地/截图库/插入文档）。
                if (ext == 'txt' ||
                    ext == 'md' ||
                    ext == 'markdown' ||
                    ext == 'docx')
                  IconButton(
                    icon: const Icon(Icons.photo_camera_outlined),
                    tooltip: '框选区域截图',
                    onPressed: () => _plainRegionShot(ext),
                  ),
                // Word：插入图片（设备相册 / App 截图库，渲染在文档末尾，
                // 导出编辑版 DOCX 时烘焙进正文）。
                if (ext == 'docx')
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    tooltip: '插入图片（相册/App 截图库）',
                    onPressed: _docxPickImage,
                  ),
                // Word：编辑模式（导入只看；点「编辑」展开全套格式工具栏——
                // 字体/字号/B/I/U/颜色/高亮/对齐/插入/删除，写回原 DOCX）。
                if (ext == 'docx')
                  IconButton(
                    icon: Icon(
                      _docxEditMode
                          ? Icons.check_circle_outline
                          : Icons.edit_note,
                      color: _docxEditMode ? colors.primary : null,
                    ),
                    tooltip: _docxEditMode ? '完成编辑' : '编辑 Word 文档',
                    onPressed: () => setState(() {
                      _docxEditMode = !_docxEditMode;
                      _docxEditSel = null;
                    }),
                  ),
                // Word：添加浮动文本框（双击编辑、拖动移动，像 PDF 页边文字）。
                if (ext == 'docx')
                  IconButton(
                    icon: const Icon(Icons.sticky_note_2_outlined),
                    tooltip: '添加文本框',
                    onPressed: _docxAddTextBox,
                  ),
                // 分屏打开哔哩哔哩（Android 7+，边看视频边做笔记）。
                if (!kIsWeb && Platform.isAndroid)
                  IconButton(
                    icon: const Icon(Icons.vertical_split_outlined),
                    tooltip: '分屏打开 B 站',
                    onPressed: _openBilibiliSplit,
                  ),
                IconButton(
                  icon: const Icon(Icons.text_fields),
                  tooltip: '阅读设置',
                  onPressed: () => _showReaderSettings(settings),
                ),
                IconButton(
                  icon: const Icon(Icons.bookmarks_outlined),
                  tooltip: '书签',
                  onPressed: () => _showBookmarks(ext),
                ),
                IconButton(
                  icon: const Icon(Icons.format_quote),
                  tooltip: '批注',
                  onPressed: () => _showAnnotationSheet(ext),
                ),
              ],
            ),
      backgroundColor: bgColor,
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) => _handleTap(details, ext),
              child: reader.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : reader.errorMessage != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.error_outline,
                                  size: 48, color: colors.error),
                              const SizedBox(height: 12),
                              Text(reader.errorMessage!),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: () {
                                  ref
                                      .read(readerProvider.notifier)
                                      .openBook(widget.book);
                                },
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      : reader.localPath == null
                          ? _buildNoFile(colors, ext)
                          : _buildReader(reader, colors, ext, settings),
            ),
          ),
          // 听书悬浮条。
          if (_ttsActive) _buildTtsBar(colors),
        ],
      ),
    );
  }

  Widget _buildNoFile(ColorScheme colors, String ext) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ext == 'pdf' ? Icons.picture_as_pdf : Icons.menu_book,
            size: 64,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('文件不存在',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('请重新下载该书籍',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildReader(ReaderState reader, ColorScheme colors, String ext,
      ReaderSettings settings) {
    switch (ext) {
      case 'pdf':
        return _buildPdfReader(reader, colors, settings);
      case 'epub':
        return _buildEpubReader(reader, colors, settings);
      case 'txt':
        return _buildTxtReader(reader, colors, settings);
      case 'md':
      case 'markdown':
        return _buildMarkdownReader(reader, colors, settings);
      case 'docx':
        return _buildDocxReader(reader, colors, settings);
      default:
        return _buildUnsupportedReader(reader, colors, ext);
    }
  }

  // ── PDF Reader ────────────────────────────────────────────────────────

  Widget _buildPdfReader(ReaderState reader, ColorScheme colors,
      ReaderSettings settings) {
    final showChrome = !settings.immersive;

    return Column(
      children: [
        // Page indicator — hidden in immersive mode.
        if (showChrome) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: colors.surfaceContainerHighest,
            child: Row(
              children: [
                Text('第 $_pdfCurrentPage / $_pdfTotalPages 页'),
                const Spacer(),
                Text('${reader.progressPercent}%'),
                const SizedBox(width: 12),
                // 手写批注开关（仅 PDF 有此按钮）。
                InkWell(
                  onTap: () {
                    setState(() => _inkMode = !_inkMode);
                    // 退出书写模式时立即把笔迹落盘，防止紧接着退出 App 丢笔迹。
                    if (!_inkMode) _flushPdfInkNow();
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _inkMode ? colors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.primary),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _inkMode ? Icons.check : Icons.draw,
                          size: 15,
                          color: _inkMode ? colors.onPrimary : colors.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _inkMode ? '完成' : '手写',
                          style: TextStyle(
                            fontSize: 12,
                            color: _inkMode
                                ? colors.onPrimary
                                : colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 框选区域截图（保存本地/截图库/插入当前页）。
                InkWell(
                  onTap: _pdfRegionShot,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.primary),
                    ),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 15,
                      color: colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 图片/截图按钮（截图当前页插入 / 仅截图 / 从截图库·相册插入）。
                InkWell(
                  onTap: _showPdfImageSheet,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.primary),
                    ),
                    child: Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 15,
                      color: colors.primary,
                    ),
                  ),
                ),
                if (!kIsWeb && Platform.isAndroid) ...[
                  const SizedBox(width: 8),
                  // 分屏打开 B 站（边看视频边在 PDF 上做笔记）。
                  InkWell(
                    onTap: _openBilibiliSplit,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colors.primary),
                      ),
                      child: Icon(
                        Icons.vertical_split_outlined,
                        size: 15,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          LinearProgressIndicator(
            value: _pdfTotalPages > 0 ? _pdfCurrentPage / _pdfTotalPages : 0,
            minHeight: 2,
          ),
        ],
        // 手写工具栏（进入手写模式时显示）。
        if (_inkMode && showChrome) _buildInkToolbar(colors),
        // 选中文字 → 两行功能栏（复制/搜索/翻译/朗读/批注/AI/分享/截图 +
        // 高亮批注栏）。修复：Windows 拖选不再需要右键，选中即弹出。
        if (_pdfSelectionActive && !_inkMode && showChrome)
          _buildPdfSelectionBar(colors),
        // 文本框属性面板（正常模式双击选中 AI 页边文字后出现）：
        // 字号 / 角度 / 编辑 / 删除。
        if (!_inkMode &&
            showChrome &&
            (_selectedTextId != null || _selectedImageId != null))
          _buildPdfTextPanel(colors),
        Expanded(
          child: PdfViewer.file(
            reader.localPath!,
            controller: _pdfController,
            params: PdfViewerParams(
              onViewerReady: (document, controller) {
                setState(() {
                  _pdfDocument = document;
                  _pdfTotalPages = document.pages.length;
                });
                _loadPdfInk(_pdfCurrentPage);
                // 从笔记中心跳来 → 直接翻到批注/手写所在页并闪烁定位。
                final jumpAnchor = widget.initialAnchor;
                if (jumpAnchor != null &&
                    jumpAnchor.kind == AnchorKind.pdf &&
                    jumpAnchor.pageIndex != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _goToPdfPageWithFlash(jumpAnchor.pageIndex!);
                  });
                }
                // 自动续读：按上次进度百分比还原到对应页（不是跳批注时）。
                if (!_pdfResumeDone && widget.initialAnchor == null) {
                  _pdfResumeDone = true;
                  final saved = reader.progressPercent;
                  if (saved > 0 && document.pages.length > 1) {
                    final page = ((saved / 100) * document.pages.length)
                        .round()
                        .clamp(1, document.pages.length);
                    if (page > 1) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _pdfController?.goToPage(pageNumber: page);
                      });
                    }
                  }
                }
              },
              onPageChanged: _onPdfPageChanged,
              // 手写模式下禁用文字选择，避免选区和笔迹手势打架。
              // showContextMenuAutomatically + buildContextMenu 均弃用：
              // pdfrx 在 Windows 桌面拖选后默认只认右键菜单，用户拖选
              // 永远看不到菜单（bug）。改为 onTextSelectionChange 驱动
              // 自绘两行功能栏（与 readest 引擎同款：复制/搜索/翻译/朗读/
              // 批注/AI/分享/截图 + 高亮批注栏）。
              textSelectionParams: PdfTextSelectionParams(
                enabled: !_inkMode,
                showContextMenuAutomatically: true,
                onTextSelectionChange: _onPdfTextSelectionChange,
              ),
              buildContextMenu: (context, params) => null,
              // ── 高亮矩形 + 手写笔迹 + 文本框都画在页面上 ─────────
              pagePaintCallbacks: [
                _pdfPaintHighlights,
                _pdfPaintInk,
                _pdfPaintTexts,
                _pdfPaintImages,
              ],
              // 打开失败（FPDF_ERR_FORMAT 等）→ 友好错误横幅替代英文异常堆栈。
              // 坏文件多是镜像把下载回成网页，引导用户删书重下或重新导入。
              errorBannerBuilder:
                  (context, error, stack, docRef) =>
                      _pdfErrorBanner(colors, error),
              // 手写时锁住滚动/缩放，翻页用底部箭头。
              panEnabled: !_inkMode,
              scaleEnabled: !_inkMode,
              // 覆盖层常开：手写模式抓笔迹/文本操作；正常模式提供
              // 双击选中文本框（AI 页边文字可编辑），不干扰 pdfrx 滚动。
              pageOverlaysBuilder: _pdfInkOverlays,
            ),
          ),
        ),
        // Page controls — hidden in immersive mode.
        if (showChrome)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: colors.surfaceContainerHighest,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filled(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _pdfCurrentPage > 1
                      ? () => _pdfController?.goToPage(pageNumber: _pdfCurrentPage - 1)
                      : null,
                ),
                const SizedBox(width: 16),
                Text('$_pdfCurrentPage / $_pdfTotalPages'),
                const SizedBox(width: 16),
                IconButton.filled(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _pdfCurrentPage < _pdfTotalPages
                      ? () => _pdfController?.goToPage(pageNumber: _pdfCurrentPage + 1)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ── EPUB Reader ───────────────────────────────────────────────────────

  Widget _buildEpubReader(ReaderState reader, ColorScheme colors,
      ReaderSettings settings) {
    // Load once per file; rebuilds must not restart the parse.
    if (_epubFuture == null || _epubPathLoaded != reader.localPath) {
      _epubPathLoaded = reader.localPath;
      _epubFuture = EpubLoader.openFile(reader.localPath!);
    }

    return FutureBuilder<LoadedEpub>(
      future: _epubFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _epubError(colors, snapshot.error!);
        }

        final book = snapshot.data!;

        // If we're jumping to an annotation, start at its section.
        // 否则优先用「精确续读位置」（章节 + 章内比例），其次用章节级进度。
        int startAt;
        var initialIntra = 0.0;
        if (!_initialJumpDone && widget.initialAnchor != null) {
          startAt = (widget.initialAnchor!.sectionIndex ?? 0)
              .clamp(0, book.sections.length - 1);
        } else if (_epubTotal == 0) {
          final saved = AppConfig.instance.epubPosition(widget.book.id);
          if (saved != null) {
            final parts = saved.split(':');
            startAt = (int.tryParse(parts.first) ?? 0)
                .clamp(0, book.sections.length - 1);
            if (parts.length > 1) {
              initialIntra =
                  (double.tryParse(parts[1]) ?? 0).clamp(0.0, 1.0);
            }
          } else if (reader.progressPercent > 0) {
            startAt =
                ((reader.progressPercent / 100) * book.sections.length).floor();
          } else {
            startAt = _epubSection;
          }
        } else {
          startAt = _epubSection;
        }

        // Schedule initial jump as a post-frame callback so the widget tree
        // is built and the scroll controller is attached.
        if (!_initialJumpDone && widget.initialAnchor != null) {
          _initialJumpDone = true;
          final anchor = widget.initialAnchor!;
          final annId = widget.initialAnnotationId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (annId != null) {
              _epubViewKey.currentState?.jumpToAnnotation(anchor, annId);
            } else {
              _epubViewKey.currentState?.jumpTo(anchor.sectionIndex ?? 0);
            }
          });
        }

        return Column(
          children: [
            if (!settings.immersive) _epubHeader(book, colors),
            Expanded(
              child: EpubReaderView(
                key: _epubViewKey,
                book: book,
                initialSection: startAt,
                fontSize: settings.fontSize,
                lineHeight: settings.lineHeight,
                textColor: settings.textColor == Colors.transparent
                    ? null
                    : settings.textColor,
                fontFamily: settings.fontFamily,
                pageMargin: settings.pageMargin,
                onSectionChanged: _onEpubSectionChanged,
                onAnnotate: _onEpubAnnotate,
                onReadFrom: _onEpubReadFrom,
                annotations: reader.annotations,
                initialFlashAnnotationId: widget.initialAnnotationId,
                initialIntra: initialIntra,
                onIntraProgress: (intra) {
                  // 滚动停止后保存精确位置：章节 + 章内比例。
                  AppConfig.instance.setEpubPosition(
                    widget.book.id,
                    '$_epubSection:${intra.toStringAsFixed(4)}',
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ── TXT Reader ────────────────────────────────────────────────────────

  Widget _buildTxtReader(ReaderState reader, ColorScheme colors,
      ReaderSettings settings) {
    // Lazy-load: parse only when the path changes.
    if (_txtFuture == null || _txtPathLoaded != reader.localPath) {
      _txtPathLoaded = reader.localPath;
      _txtFuture = TxtLoader.openFile(reader.localPath!);
    }

    return FutureBuilder<LoadedTxt>(
      future: _txtFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _formatError(colors, 'TXT', snapshot.error!);
        }

        final txt = snapshot.data!;
        _txtParagraphs = txt.chunks; // 缓存给朗读用

        // Show encoding hint for GBK files.
        final header = (!settings.immersive && txt.encodingUsed == 'gbk')
            ? _encodingHint('GBK', colors)
            : null;

        return Column(
          children: [
            if (header != null) header,
            Expanded(
              child: RepaintBoundary(
                key: _txtShotKey,
                child: TxtReaderView(
                  key: _txtViewKey,
                  paragraphs: txt.chunks,
                  fontSize: settings.fontSize,
                lineHeight: settings.lineHeight,
                textColor: settings.textColor == Colors.transparent
                    ? null
                    : settings.textColor,
                fontFamily: settings.fontFamily,
                pageMargin: settings.pageMargin,
                initialProgress: reader.progressPercent / 100.0,
                onProgress: (p) {
                  ref
                      .read(readerProvider.notifier)
                      .updateProgress((p * 100).round());
                },
                onParagraphTap: (i) => _startTtsFromParagraph('txt', i),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Markdown Reader ───────────────────────────────────────────────────

  Widget _buildMarkdownReader(ReaderState reader, ColorScheme colors,
      ReaderSettings settings) {
    // MD files are plain UTF-8 text — load once and cache.
    if (_mdContent == null || _mdPathLoaded != reader.localPath) {
      _mdPathLoaded = reader.localPath;
      _mdContent = null; // trigger reload
      // Read synchronously — MD files are typically small.
      final file = File(reader.localPath!);
      if (!file.existsSync()) {
        return _buildNoFile(colors, 'md');
      }
      final mdBytes = file.readAsBytesSync();
      _mdContent = const Utf8Decoder(allowMalformed: true).convert(mdBytes);
    }

    return RepaintBoundary(
      key: _mdShotKey,
      child: MarkdownReaderView(
        key: _mdViewKey,
        markdown: _mdContent!,
        fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      textColor: settings.textColor == Colors.transparent
          ? null
          : settings.textColor,
      fontFamily: settings.fontFamily,
      pageMargin: settings.pageMargin,
      initialProgress: reader.progressPercent / 100.0,
      onProgress: (p) {
        ref
            .read(readerProvider.notifier)
            .updateProgress((p * 100).round());
      },
        onParagraphTap: (line) => _startTtsFromParagraph('md', line),
      ),
    );
  }

  // ── DOCX Reader ───────────────────────────────────────────────────────

  Widget _buildDocxReader(ReaderState reader, ColorScheme colors,
      ReaderSettings settings) {
    if (_docxFuture == null || _docxPathLoaded != reader.localPath) {
      _docxPathLoaded = reader.localPath;
      _docxFuture = DocxLoader.openFile(reader.localPath!);
      _docxNotes = const [];
      _loadDocxNotes(); // Phase 4：加载该书批注
    }

    return FutureBuilder<LoadedDocx>(
      future: _docxFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _formatError(colors, 'DOCX', snapshot.error!);
        }

        final docx = snapshot.data!;
        _docxParagraphs = docx.paragraphs; // 缓存给朗读用
        _docxLoaded = docx; // 段落级编辑写回用
        // 从笔记中心回跳：锚点 startOffset = 段落索引。
        final jumpPara = (widget.initialAnchor != null &&
                widget.initialAnchor!.kind == AnchorKind.plain &&
                widget.initialAnchor!.startOffset != null &&
                !_docxJumpDone)
            ? widget.initialAnchor!.startOffset
            : null;
        if (jumpPara != null) _docxJumpDone = true;

        final readerView = RepaintBoundary(
          key: _docxShotKey,
          child: TxtReaderView(
            key: _txtViewKey,
            paragraphs: docx.paragraphs,
            richParagraphs: docx.richParagraphs,
            blocks: docx.blocks,
            fontSize: settings.fontSize,
            lineHeight: settings.lineHeight,
            textColor: settings.textColor == Colors.transparent
                ? null
                : settings.textColor,
            fontFamily: settings.fontFamily,
            pageMargin: settings.pageMargin,
            initialProgress: reader.progressPercent / 100.0,
            onProgress: (p) {
              ref
                  .read(readerProvider.notifier)
                  .updateProgress((p * 100).round());
            },
            onParagraphTap: (i) => _startTtsFromParagraph('docx', i),
            // ── Phase 4：Word 批注闭环 ───────────────────────────────
            annotations: _docxNotes,
            jumpToPara: jumpPara,
            onSelectionAction: _docxOnSelectionAction,
            onAnnotate: _docxOnAnnotate,
            onHighlightTap: _docxOnHighlightTap,
            // 浮动文本框（AI 插入/手动添加）：拖动落库、双击编辑。
            onTextBoxChanged: _docxOnTextBoxChanged,
            onTextBoxEdit: _docxEditTextBox,
            // 段落级编辑模式：点段落/单元格/文本框文字进入编辑。
            editMode: _docxEditMode,
            onEditParagraph: _docxEditParagraph,
            editSelectedPara: _docxEditSel,
          ),
        );

        if (!_docxEditMode) return readerView;
        // 编辑模式：顶部提示条 + 底部全套格式工具栏（截图边界外）。
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: colors.primaryContainer,
              child: Row(
                children: [
                  Icon(Icons.touch_app_outlined,
                      size: 15, color: colors.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _docxEditSel != null
                          ? '已选中段落 ${_docxEditSel! + 1}：下方工具栏改格式/文字'
                          : '编辑模式：点击一个段落选中它，再用下方工具栏修改',
                      style: TextStyle(
                          fontSize: 12, color: colors.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: readerView),
            _buildDocxEditToolbar(colors),
          ],
        );
      },
    );
  }

  // ── Phase 4：Word（DOCX）批注闭环 ───────────────────────────────────

  bool _docxJumpDone = false;

  Future<void> _loadDocxNotes() async {
    try {
      final notes = await ref
          .read(storageServiceProvider)
          .getDocxNotes(widget.book.id);
      if (!mounted) return;
      setState(() => _docxNotes = notes);
    } catch (e) {
      debugPrint('[Docx] load notes failed: $e');
    }
  }

  // ── Word 段落级编辑（编辑模式） ─────────────────────────────────────

  /// 编辑模式点段落/单元格 → 选中该段（工具栏的格式操作作用于它）。
  void _docxEditParagraph(int index) {
    if (!_docxEditMode) return;
    setState(() => _docxEditSel = index);
  }

  /// 编辑模式当前选中的段落（格式工具栏读取用）。
  DocxPara? get _docxEditPara {
    final docx = _docxLoaded;
    final sel = _docxEditSel;
    if (docx == null || sel == null) return null;
    if (sel < 0 || sel >= docx.richParagraphs.length) return null;
    return docx.richParagraphs[sel];
  }

  /// 弹编辑框改当前选中段落的文字（可顺带前插/后插/删除）。
  /// 操作写回原 DOCX 文件后，同步迁移批注锚点并重新解析。
  Future<void> _docxEditSelectedText() async {
    final docx = _docxLoaded;
    final path = _docxPathLoaded;
    final paragraphs = _docxParagraphs;
    final index = _docxEditSel;
    if (docx == null || path == null || paragraphs == null) {
      _toast('文档还没加载好，稍等再试');
      return;
    }
    if (index == null || index < 0 || index >= paragraphs.length) {
      _toast('先点击一个段落选中它');
      return;
    }

    final ctrl = TextEditingController(text: paragraphs[index]);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑段落 ${index + 1}'),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 10,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入段落文字（换行 = 段内换行）',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('删除本段'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'insertBefore'),
            child: const Text('前插新段'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'insertAfter'),
            child: const Text('后插新段'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final newText = ctrl.text;
    ctrl.dispose();
    if (!mounted || choice == null || choice == 'cancel') return;

    try {
      final storage = ref.read(storageServiceProvider);
      switch (choice) {
        case 'save':
          await DocxEditService.setParagraphText(
            doc: docx,
            paraIndex: index,
            newText: newText,
            docxPath: path,
          );
          _toast('段落已保存回 DOCX');
        case 'insertBefore':
        case 'insertAfter':
          final after = choice == 'insertAfter';
          final text = await _docxPromptText(
              title: after ? '在该段之后插入新段落' : '在该段之前插入新段落');
          if (text == null || !mounted) return;
          await DocxEditService.insertParagraph(
            doc: docx,
            paraIndex: index,
            newText: text,
            docxPath: path,
            after: after,
          );
          // 批注锚点迁移：插入点及其后的段落下标 +1。
          await storage.shiftDocxNoteIndices(
              widget.book.id, after ? index + 1 : index, 1);
          if (!after) {
            // 前插后选中新段落（下标 = 原下标）。
            _docxEditSel = index;
          } else {
            _docxEditSel = index + 1;
          }
          _toast('已插入新段落');
        case 'delete':
          await DocxEditService.deleteParagraph(
              doc: docx, paraIndex: index, docxPath: path);
          // 该段的批注一并删除，其后的批注锚点 -1。
          await storage.deleteDocxNotesAtPara(widget.book.id, index);
          await storage.shiftDocxNoteIndices(widget.book.id, index + 1, -1);
          _docxEditSel = null;
          _toast('段落已删除');
      }
      _docxReloadAfterEdit();
    } catch (e) {
      debugPrint('[Docx] edit failed: $e');
      if (mounted) _toast('编辑失败: $e');
    }
  }

  /// 编辑写回后重新解析文档（段落数量不变时保留当前选中段落）。
  void _docxReloadAfterEdit() {
    if (!mounted) return;
    final sel = _docxEditSel;
    setState(() {
      _docxFuture = null; // 触发重新解析
      _docxLoaded = null;
      _docxParagraphs = null;
      _docxEditSel = sel;
    });
    _loadDocxNotes();
  }

  /// 编辑模式工具栏的「文末新增段落」：插到正文末尾（sectPr 之前）。
  Future<void> _docxAddParagraphAtEnd() async {
    final docx = _docxLoaded;
    final path = _docxPathLoaded;
    final paragraphs = _docxParagraphs;
    if (docx == null || path == null || paragraphs == null || paragraphs.isEmpty) {
      _toast('文档还没加载好');
      return;
    }
    final text = await _docxPromptText(title: '在文档末尾新增段落');
    if (text == null || !mounted) return;
    try {
      await DocxEditService.appendParagraph(
          doc: docx, newText: text, docxPath: path);
      if (mounted) {
        setState(() {
          _docxFuture = null;
          _docxLoaded = null;
          _docxParagraphs = null;
          _docxEditSel = null;
        });
      }
      _toast('已在文末新增段落');
    } catch (e) {
      debugPrint('[Docx] append failed: $e');
      if (mounted) _toast('新增段落失败: $e');
    }
  }

  // ── 编辑模式格式操作（工具栏按钮） ─────────────────────────────────

  /// 统一格式写回入口：run 属性 + 段落属性都走这里，写回后重新解析。
  Future<void> _docxApplyFmt({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    double? fontSizePt,
    String? colorHex,
    bool clearColor = false,
    String? highlight,
    bool clearHighlight = false,
    String? alignment,
  }) async {
    final docx = _docxLoaded;
    final path = _docxPathLoaded;
    final sel = _docxEditSel;
    if (docx == null || path == null || sel == null) {
      _toast('先点击一个段落选中它');
      return;
    }
    try {
      final runFmt = bold != null ||
          italic != null ||
          underline != null ||
          strike != null ||
          fontSizePt != null ||
          colorHex != null ||
          clearColor ||
          highlight != null ||
          clearHighlight;
      if (runFmt) {
        await DocxEditService.setRunFormat(
          doc: docx,
          paraIndex: sel,
          docxPath: path,
          bold: bold,
          italic: italic,
          underline: underline,
          strike: strike,
          fontSizePt: fontSizePt,
          colorHex: clearColor ? '' : colorHex,
          highlight: clearHighlight ? '' : highlight,
        );
      }
      if (alignment != null) {
        await DocxEditService.setParagraphFormat(
          doc: docx,
          paraIndex: sel,
          docxPath: path,
          alignment: alignment,
        );
      }
      _docxReloadAfterEdit();
    } catch (e) {
      debugPrint('[Docx] format failed: $e');
      if (mounted) _toast('格式修改失败: $e');
    }
  }

  /// B/I/U/S 切换：当前段全部 run 都开着 → 关，否则开。
  Future<void> _docxToggleStyle(String prop) async {
    final para = _docxEditPara;
    if (para == null || para.runs.isEmpty) {
      _toast('先点击一个段落选中它');
      return;
    }
    final bool cur;
    switch (prop) {
      case 'bold':
        cur = para.runs.every((r) => r.bold);
      case 'italic':
        cur = para.runs.every((r) => r.italic);
      case 'underline':
        cur = para.runs.every((r) => r.underline);
      default:
        cur = para.runs.every((r) => r.strike);
    }
    await _docxApplyFmt(
      bold: prop == 'bold' ? !cur : null,
      italic: prop == 'italic' ? !cur : null,
      underline: prop == 'underline' ? !cur : null,
      strike: prop == 'strike' ? !cur : null,
    );
  }

  /// 字号 ±1pt（以段落基准字号为起点，6~72 钳制）。
  Future<void> _docxFontSize(int delta) async {
    final para = _docxEditPara;
    if (para == null) {
      _toast('先点击一个段落选中它');
      return;
    }
    final base = para.baseFontSize ??
        ref.read(readerSettingsProvider).fontSize;
    final target = (base + delta).clamp(6.0, 72.0);
    await _docxApplyFmt(fontSizePt: target);
  }

  /// 颜色选择弹窗：返回 'RRGGBB'、'clear' 或 null（取消）。
  Future<String?> _docxPickColor(
      {required String title, required ColorScheme colors}) async {
    const palette = <String>[
      '000000',
      'FFFFFF',
      'E53935',
      'F57C00',
      'FDD835',
      '43A047',
      '1E88E5',
      '6D4C41',
      '7B1FA2',
      '546E7A',
    ];
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final hex in palette)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, hex),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: docxColorOr(hex, const Color(0xFF000000)),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: hex == 'FFFFFF'
                                ? colors.outlineVariant
                                : Colors.transparent),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.format_color_reset_outlined, size: 16),
              label: const Text('清除颜色'),
              onPressed: () => Navigator.pop(ctx, 'clear'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    return choice;
  }

  /// 工具栏「文字颜色」。
  Future<void> _docxPickTextColor() async {
    final colors = Theme.of(context).colorScheme;
    final choice = await _docxPickColor(title: '文字颜色', colors: colors);
    if (choice == null || !mounted) return;
    await _docxApplyFmt(
      colorHex: choice == 'clear' ? null : choice,
      clearColor: choice == 'clear',
    );
  }

  /// 工具栏「高亮色」。
  Future<void> _docxPickHighlight() async {
    final colors = Theme.of(context).colorScheme;
    final choice = await _docxPickColor(title: '高亮色', colors: colors);
    if (choice == null || !mounted) return;
    await _docxApplyFmt(
      highlight: choice == 'clear' ? null : choice,
      clearHighlight: choice == 'clear',
    );
  }

  /// 工具栏「前插/后插」。
  Future<void> _docxInsertSel(bool after) async {
    final docx = _docxLoaded;
    final path = _docxPathLoaded;
    final paragraphs = _docxParagraphs;
    final index = _docxEditSel;
    if (docx == null ||
        path == null ||
        paragraphs == null ||
        index == null ||
        index >= paragraphs.length) {
      _toast('先点击一个段落选中它');
      return;
    }
    final text = await _docxPromptText(
        title: after ? '在该段之后插入新段落' : '在该段之前插入新段落');
    if (text == null || !mounted) return;
    try {
      final storage = ref.read(storageServiceProvider);
      await DocxEditService.insertParagraph(
        doc: docx,
        paraIndex: index,
        newText: text,
        docxPath: path,
        after: after,
      );
      await storage.shiftDocxNoteIndices(
          widget.book.id, after ? index + 1 : index, 1);
      _docxEditSel = after ? index + 1 : index;
      _toast('已插入新段落');
      _docxReloadAfterEdit();
    } catch (e) {
      debugPrint('[Docx] insert failed: $e');
      if (mounted) _toast('插入失败: $e');
    }
  }

  /// 工具栏「删除本段」。
  Future<void> _docxDeleteSel() async {
    final docx = _docxLoaded;
    final path = _docxPathLoaded;
    final paragraphs = _docxParagraphs;
    final index = _docxEditSel;
    if (docx == null ||
        path == null ||
        paragraphs == null ||
        index == null ||
        index >= paragraphs.length) {
      _toast('先点击一个段落选中它');
      return;
    }
    try {
      final storage = ref.read(storageServiceProvider);
      await DocxEditService.deleteParagraph(
          doc: docx, paraIndex: index, docxPath: path);
      await storage.deleteDocxNotesAtPara(widget.book.id, index);
      await storage.shiftDocxNoteIndices(widget.book.id, index + 1, -1);
      _docxEditSel = null;
      _toast('段落已删除');
      _docxReloadAfterEdit();
    } catch (e) {
      debugPrint('[Docx] delete failed: $e');
      if (mounted) _toast('删除失败: $e');
    }
  }

  /// 编辑模式底部工具栏：段落操作 + 全套字符/段落格式。
  Widget _buildDocxEditToolbar(ColorScheme colors) {
    final para = _docxEditPara;
    final hasSel = para != null;
    final fontSizeBase =
        para?.baseFontSize ?? ref.watch(readerSettingsProvider).fontSize;

    Widget chip({
      required String tooltip,
      required Widget child,
      required VoidCallback onTap,
      bool active = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
            decoration: BoxDecoration(
              color: active ? colors.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          ),
        ),
      );
    }

    Widget iconBtn(IconData icon, String tooltip, VoidCallback onTap,
        {bool active = false}) {
      return chip(
        tooltip: tooltip,
        active: active,
        onTap: onTap,
        child: Icon(icon,
            size: 19,
            color: active ? colors.primary : colors.onSurfaceVariant),
      );
    }

    Widget labelBtn(String label, String tooltip, VoidCallback onTap,
        {bool active = false, Color? color}) {
      return chip(
        tooltip: tooltip,
        active: active,
        onTap: onTap,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: color ??
                (active ? colors.primary : colors.onSurfaceVariant),
          ),
        ),
      );
    }

    final allBold =
        hasSel && para.runs.isNotEmpty && para.runs.every((r) => r.bold);
    final allItalic =
        hasSel && para.runs.isNotEmpty && para.runs.every((r) => r.italic);
    final allUnder =
        hasSel && para.runs.isNotEmpty && para.runs.every((r) => r.underline);
    final allStrike =
        hasSel && para.runs.isNotEmpty && para.runs.every((r) => r.strike);
    final hasColor = hasSel && para.runs.any((r) => r.colorHex != null);
    final hasHighlight = hasSel && para.runs.any((r) => r.highlight != null);
    final align = para?.alignment ?? 'left';

    return Material(
      elevation: 10,
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 106,
          child: Column(
            children: [
              // 第一行：段落操作（选中/改文字/增删/完成）。
              SizedBox(
                height: 44,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      chip(
                        tooltip: '当前选中段落',
                        onTap: () {},
                        child: Text(
                          hasSel ? '段落 ${_docxEditSel! + 1}' : '未选中段落',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      labelBtn('改文字', '编辑选中段落的文字', _docxEditSelectedText,
                          color: colors.primary),
                      labelBtn('前插', '在选中段落前插入新段落',
                          () => _docxInsertSel(false)),
                      labelBtn('后插', '在选中段落后插入新段落',
                          () => _docxInsertSel(true)),
                      labelBtn('删除', '删除选中段落', _docxDeleteSel,
                          color: colors.error),
                      labelBtn('文末新增', '在文档末尾新增段落', _docxAddParagraphAtEnd),
                      labelBtn('完成', '退出编辑模式', () {
                        setState(() {
                          _docxEditMode = false;
                          _docxEditSel = null;
                        });
                      }, color: colors.primary),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              // 第二行：字符/段落格式（字号/B/I/U/S/颜色/高亮/对齐）。
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      iconBtn(Icons.text_decrease, '字号 -1', () => _docxFontSize(-1)),
                      labelBtn('${fontSizeBase.round()}pt', '当前段落基准字号', () {}),
                      iconBtn(Icons.text_increase, '字号 +1', () => _docxFontSize(1)),
                      const SizedBox(width: 8),
                      labelBtn('B', '加粗', () => _docxToggleStyle('bold'),
                          active: allBold),
                      labelBtn('I', '斜体', () => _docxToggleStyle('italic'),
                          active: allItalic),
                      labelBtn('U', '下划线', () => _docxToggleStyle('underline'),
                          active: allUnder),
                      labelBtn('S', '删除线', () => _docxToggleStyle('strike'),
                          active: allStrike),
                      const SizedBox(width: 8),
                      iconBtn(Icons.format_color_text, '文字颜色',
                          _docxPickTextColor,
                          active: hasColor),
                      iconBtn(Icons.border_color_outlined, '高亮色',
                          _docxPickHighlight,
                          active: hasHighlight),
                      const SizedBox(width: 8),
                      iconBtn(Icons.format_align_left, '左对齐',
                          () => _docxApplyFmt(alignment: 'left'),
                          active: align == 'left'),
                      iconBtn(Icons.format_align_center, '居中',
                          () => _docxApplyFmt(alignment: 'center'),
                          active: align == 'center'),
                      iconBtn(Icons.format_align_right, '右对齐',
                          () => _docxApplyFmt(alignment: 'right'),
                          active: align == 'right'),
                      iconBtn(Icons.format_align_justify, '两端对齐',
                          () => _docxApplyFmt(alignment: 'justify'),
                          active: align == 'justify'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入新段落文字的对话框；取消/空白返回 null。
  Future<String?> _docxPromptText({required String title}) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          minLines: 3,
          maxLines: 10,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入新段落文字（换行 = 段内换行）',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('插入')),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true || text.trim().isEmpty || !mounted) return null;
    return text;
  }

  /// 选中菜单动作（复制/搜索/翻译/朗读/批注/AI/分享/截图）。
  Future<void> _docxOnSelectionAction(String action, TxtSelection sel) async {
    switch (action) {
      case 'copy':
        // §2.8：复制 = 文字进剪贴板 + 以该选区为锚点确保一条记录存在
        // （原文必存；之后同选区批注/AI 更新同一条记录）。
        await _docxEnsureCopyRecord(sel);
      case 'search':
        // 跳系统浏览器网页搜索（不再进 App 内「发现图书」搜索页）。
        await openWebSearch(sel.text, context: context);
      case 'translate':
        if (!mounted) return;
        final future = TranslateService.instance.translate(sel.text, 'zh');
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (ctx) => Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.55,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(sel.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 16)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: FutureBuilder<String>(
                      future: future,
                      builder: (ctx, snap) {
                        final txt = snap.connectionState != ConnectionState.done
                            ? '翻译中…'
                            : (snap.data ?? '翻译失败');
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: SingleChildScrollView(
                            child: Text(txt,
                                style: const TextStyle(
                                    fontSize: 14, height: 1.6)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case 'tts':
        try {
          await TtsService.instance.stop();
          await TtsService.instance
              .play(TtsService.splitSentences(sel.text));
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('朗读失败: $e')),
            );
          }
        }
      case 'note':
        await _docxNoteDialog(sel);
      case 'ai':
        await _docxOnAi(sel);
      case 'share':
        try {
          final dir = await getTemporaryDirectory();
          final file = File('${dir.path}/selection-'
              '${DateTime.now().millisecondsSinceEpoch}.txt');
          await file.writeAsString(sel.text);
          await Share.shareXFiles([XFile(file.path)],
              subject: '选中文字分享');
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('分享失败: $e')),
            );
          }
        }
      case 'shot':
        await _docxOnShot(sel);
    }
  }

  /// 高亮栏确认：按样式/颜色/笔记 upsert 同选区记录。
  Future<void> _docxOnAnnotate(
      TxtSelection sel, String color, String style, String note) async {
    try {
      final id = await ref.read(storageServiceProvider).upsertDocxNote(
            DocxNote(
              bookId: widget.book.id,
              paraIndex: sel.paraIndex,
              startOffset: sel.start,
              endOffset: sel.end,
              quotedText: sel.text,
              note: note,
              color: color,
              style: style,
              source: 'manual',
              imagePath: _docxShotPath,
            ),
          );
      _docxShotPath = null;
      await _loadDocxNotes();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(note.isNotEmpty
              ? '笔记已保存'
              : (style == 'highlight' ? '已高亮' : '已添加$style标记')),
          duration: const Duration(seconds: 1),
        ),
      );
      debugPrint('[Docx] note saved id=$id para=${sel.paraIndex}');
    } catch (e) {
      debugPrint('[Docx] save note failed: $e');
    }
  }

  /// 批注对话框：引用原文 + 笔记输入框。
  Future<void> _docxNoteDialog(TxtSelection sel) async {
    if (!mounted) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
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
                border: const Border(
                    left: BorderSide(color: Colors.grey, width: 3)),
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
              ),
              child: Text(sel.text,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 4,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入笔记内容…',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final note = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true) {
      await _docxOnAnnotate(sel, _docxDefaultColor(), 'highlight', note);
    }
  }

  String _docxDefaultColor() => '#FACC15';

  /// AI：复用小 AI 对话框 → 确认后 ai_notes 落库 + 原文高亮（violet）+
  /// 可选把 AI 内容作为**浮动文本框**插入文档（双击编辑、拖动移动——
  /// 与 PDF 的 AI 页边插字同款体验，修「AI 文本贴在页面边上动不了」）。
  String? _docxShotPath;

  Future<void> _docxOnAi(TxtSelection sel) async {
    if (!mounted) return;
    final result = await showAiDialog(
      context,
      bookId: widget.book.id,
      fileType: 'docx',
      fileName: widget.book.title,
      cfi: jsonEncode({
        'para': sel.paraIndex,
        'start': sel.start,
        'end': sel.end,
      }),
      quotedText: sel.text,
      imagePath: _docxShotPath,
    );
    _docxShotPath = null;
    if (result == null || !mounted) return;

    // 问一句：是否把 AI 内容作为浮动文本框插到文档里（可先选字体颜色）。
    // ⚠️ 选中色必须存在 builder 闭包之外：StatefulBuilder 每次重建会
    // 重新执行 builder，写在里面会被重置回默认紫色——颜色圆点就会
    // 「看得见但点了没反应」（用户反馈的点不了根因）。
    var insertColor = '#4C1D95';
    final choice = await showDialog<(bool, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: const Text('AI 内容已保存到笔记'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFEDE9FE)),
                  ),
                  child: Text(
                    result.content,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('插入文字的字体颜色：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                _InsertColorDots(
                  selected: insertColor,
                  onChanged: (c) => setDlg(() => insertColor = c),
                ),
                const SizedBox(height: 12),
                const Text(
                  '是否把这段内容插入到文档里？\n'
                  '（插入后是文档上的浮动文本框：单击选中、直接拖动即可'
                  '移到任意位置；双击编辑文字/删除）',
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, (false, insertColor)),
                child: const Text('仅存笔记'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => Navigator.pop(ctx, (true, insertColor)),
                child: const Text('插入文档'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || choice == null) return;
    final insert = choice.$1;
    final color = choice.$2;

    final storage = ref.read(storageServiceProvider);
    // AI 标注进 ai_notes（原文必填铁律）。
    await storage.insertAiNote(AiNote(
      bookId: widget.book.id,
      fileType: 'docx',
      anchor: jsonEncode({
        'para': sel.paraIndex,
        'start': sel.start,
        'end': sel.end,
      }),
      quotedText: sel.text,
      content: result.content,
      imagePath: result.imagePath,
      conversationId: result.conversationId,
    ));
    // 原文渲染 AI 标注点（violet 高亮，与 PDF/EPUB 一致）。
    await storage.upsertDocxNote(DocxNote(
      bookId: widget.book.id,
      paraIndex: sel.paraIndex,
      startOffset: sel.start,
      endOffset: sel.end,
      quotedText: sel.text,
      note: '',
      color: '#7C3AED',
      style: 'highlight',
      source: 'ai',
      imagePath: result.imagePath,
    ));
    // 浮动文本框：AI 内容 + 用户选择的字体颜色 + 右侧留白默认位（不贴边）。
    if (insert) {
      await storage.insertDocxNote(DocxNote(
        bookId: widget.book.id,
        paraIndex: sel.paraIndex,
        startOffset: 0,
        endOffset: 0,
        quotedText: sel.text,
        note: result.content,
        color: color,
        style: 'textbox',
        source: 'ai',
        x: 0.52,
        y: 0.22,
        w: 0.42,
        fontSize: 13,
      ));
    }
    await _loadDocxNotes();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(insert == true
            ? '已保存 AI 笔记并插入文档文本框（单击选中拖动、双击编辑）'
            : '已保存 AI 笔记（原文已标记，可在笔记中心查看）'),
      ),
    );
  }

  // ── Word 浮动文本框（手动添加 / 拖动落库 / 双击编辑） ───────────────

  /// 手动在文档末尾添加一个文本框（与 AI 插入同款，双击写内容）。
  Future<void> _docxAddTextBox() async {
    try {
      final paragraphs = _docxParagraphs;
      final paraIndex =
          (paragraphs != null && paragraphs.isNotEmpty) ? paragraphs.length - 1 : 0;
      await ref.read(storageServiceProvider).insertDocxNote(DocxNote(
            bookId: widget.book.id,
            paraIndex: paraIndex,
            startOffset: 0,
            endOffset: 0,
            quotedText: '文本框',
            note: '',
            color: '#1D4ED8',
            style: 'textbox',
            source: 'manual',
            x: 0.52,
            y: 0.18,
            w: 0.42,
            fontSize: 14,
          ));
      await _loadDocxNotes();
      if (mounted) _toast('已添加文本框（双击编辑文字，直接拖动移动）');
    } catch (e) {
      debugPrint('[Docx] add textbox failed: $e');
      if (mounted) _toast('添加文本框失败: $e');
    }
  }

  /// 文本框拖动结束 → 更新内存 + 落库。
  Future<void> _docxOnTextBoxChanged(DocxNote n) async {
    if (n.id == null) return;
    if (mounted) {
      setState(() {
        final i = _docxNotes.indexWhere((x) => x.id == n.id);
        if (i >= 0) _docxNotes[i] = n;
      });
    }
    try {
      await ref.read(storageServiceProvider).updateDocxTextBox(n);
    } catch (e) {
      debugPrint('[Docx] update textbox failed: $e');
    }
  }

  /// 双击文本框 → 编辑文字 / 删除。
  Future<void> _docxEditTextBox(DocxNote n) async {
    if (!mounted) return;
    final ctrl = TextEditingController(text: n.note);
    final out = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑文本框'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入文本框内容…',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          if (n.id != null)
            TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, '__delete__'),
              child: const Text('删除'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (!mounted) return;
    if (out == '__delete__') {
      if (n.id != null) {
        await ref.read(storageServiceProvider).deleteDocxNote(n.id!);
        await _loadDocxNotes();
        if (mounted) _toast('文本框已删除');
      }
      return;
    }
    if (out == null || out == n.note) return;
    await ref
        .read(storageServiceProvider)
        .updateDocxTextBox(n.copyWith(note: out));
    await _loadDocxNotes();
  }

  /// 截图：截取阅读区域（RepaintBoundary）→ PNG → 挂到当前选区记录。
  final GlobalKey _docxShotKey = GlobalKey();
  /// TXT / MD 阅读区截图 RepaintBoundary key（问题14）。
  final GlobalKey _txtShotKey = GlobalKey();
  final GlobalKey _mdShotKey = GlobalKey();

  Future<void> _docxOnShot(TxtSelection sel) async {
    try {
      final boundary = _docxShotKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('截图失败（页面尚未渲染完成）')),
          );
        }
        return;
      }
      final image = await boundary.toImage(pixelRatio: 1.5);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) return;
      final docs = await getApplicationDocumentsDirectory();
      final shotDir = Directory('${docs.path}/ai_shots');
      if (!await shotDir.exists()) await shotDir.create(recursive: true);
      final path = '${shotDir.path}/${widget.book.id}_'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(byteData.buffer.asUint8List());
      _docxShotPath = path;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('截图已保存，将随笔记一起保存')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败: $e')),
        );
      }
    }
  }

  /// 根据格式取对应阅读区 RepaintBoundary 的 GlobalKey。
  GlobalKey _plainShotKey(String ext) {
    if (ext == 'docx') return _docxShotKey;
    if (ext == 'md' || ext == 'markdown') return _mdShotKey;
    return _txtShotKey;
  }

  /// 框选区域截图（PDF）：Android 上优先整屏截图（MediaProjection——
  /// 分屏时连另一侧的 B 站也能框进来），否则渲染当前页 → 全屏框选 →
  /// 保存本地 / 截图库 / 按框选位置插入当前页批注图层（所见即所得）。
  Future<void> _pdfRegionShot() async {
    final pageNumber = _pdfCurrentPage;
    Uint8List? bytes;
    final fullScreen = await ScreenCapture.captureFullScreen();
    if (fullScreen == null) {
      final notice = ScreenCapture.fallbackNotice;
      if (notice != null && mounted) _toast(notice);
    }
    bytes = fullScreen ?? await _renderPdfPagePng(pageNumber);
    if (bytes == null) {
      if (mounted) _toast('截图失败（页面渲染不可用）');
      return;
    }
    if (!mounted) return;
    final result =
        await showRegionCrop(context, sourcePng: bytes, title: '框选截图区域');
    if (result == null) return;
    if (!mounted) return;
    final action = await ShotActions.pick(context, canInsert: true);
    if (!mounted) return;
    switch (action) {
      case ShotAction.saveLocal:
        final ok = await ShotActions.saveToLocal(context, ref, result.png,
            prefix: 'pdf');
        if (mounted) {
          _toast(ok ? '截图已保存到本机下载目录（文件 App 可见）' : '保存到本机失败');
        }
      case ShotAction.saveLibrary:
        final path =
            await ShotActions.saveToLibrary(result.png, prefix: 'pdf');
        if (mounted) {
          _toast(path != null ? '截图已保存到 App 截图库（设置里可查看）' : '保存截图库失败');
        }
      case ShotAction.insert:
        // 先把裁剪结果写成临时 PNG，再按框选矩形插入批注图层。
        try {
          final dir = await getTemporaryDirectory();
          final tmp = File(p.join(dir.path,
              'region_${DateTime.now().millisecondsSinceEpoch}.png'));
          await tmp.writeAsBytes(result.png, flush: true);
          await _insertPdfImage(
            tmp.path,
            pageNumber,
            normRect: Rect.fromLTWH(
                result.nx, result.ny, result.nw, result.nh),
          );
          if (mounted) _toast('截图已插入当前页（可选中拖动/缩放）');
        } catch (e) {
          if (mounted) _toast('插入失败: $e');
        }
      case ShotAction.cancel:
        break;
    }
  }

  /// 框选区域截图（Word/TXT/MD）：Android 上优先整屏截图（MediaProjection，
  /// 分屏时连另一侧的 B 站一起框进来），否则截取阅读区视口 → 全屏框选 →
  /// 保存本地 / 截图库 / 插入 Word 文档（TXT/MD 只读，不提供插入）。
  Future<void> _plainRegionShot(String ext) async {
    Uint8List? sourcePng = await ScreenCapture.captureFullScreen();
    if (sourcePng == null) {
      final notice = ScreenCapture.fallbackNotice;
      if (notice != null && mounted) _toast(notice);
      final boundary = _plainShotKey(ext).currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) _toast('截图失败（页面尚未渲染完成）');
        return;
      }
      final image = await boundary.toImage(pixelRatio: 1.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        if (mounted) _toast('截图失败（编码错误）');
        return;
      }
      sourcePng = byteData.buffer.asUint8List();
    }
    if (!mounted) return;
    final result = await showRegionCrop(context,
        sourcePng: sourcePng, title: '框选截图区域');
    if (result == null) return;
    if (!mounted) return;
    final canInsert = ext == 'docx';
    final action = await ShotActions.pick(context, canInsert: canInsert);
    if (!mounted) return;
    switch (action) {
      case ShotAction.saveLocal:
        final ok = await ShotActions.saveToLocal(context, ref, result.png,
            prefix: ext);
        if (mounted) {
          _toast(ok ? '截图已保存到本机下载目录（文件 App 可见）' : '保存到本机失败');
        }
      case ShotAction.saveLibrary:
        final path = await ShotActions.saveToLibrary(result.png, prefix: ext);
        if (mounted) {
          _toast(path != null ? '截图已保存到 App 截图库（设置里可查看）' : '保存截图库失败');
        }
      case ShotAction.insert:
        await _docxInsertImage(result.png);
      case ShotAction.cancel:
        break;
    }
  }

  /// 把图片插入 Word 文档（记录为 style='image' 的批注，阅读器渲染在
  /// 文档末尾段落下，导出编辑版 DOCX 时烘焙成内嵌图片）。
  Future<void> _docxInsertImage(Uint8List png, {String sourceLabel = ''}) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'docx_images', widget.book.id));
      if (!await dir.exists()) await dir.create(recursive: true);
      final path = p.join(dir.path,
          'img${DateTime.now().millisecondsSinceEpoch}.png');
      await File(path).writeAsBytes(png, flush: true);
      final paragraphs = _docxParagraphs;
      final paraIndex =
          (paragraphs != null && paragraphs.isNotEmpty) ? paragraphs.length - 1 : 0;
      await ref.read(storageServiceProvider).upsertDocxNote(DocxNote(
            bookId: widget.book.id,
            paraIndex: paraIndex,
            startOffset: 0,
            endOffset: 0,
            quotedText: sourceLabel.isEmpty ? '插入图片' : '插入图片（$sourceLabel）',
            note: '',
            style: 'image',
            source: 'manual',
            imagePath: path,
          ));
      await _loadDocxNotes();
      if (mounted) _toast('图片已插入文档（位于文末段落；导出编辑版 DOCX 会烘焙进正文）');
    } catch (e) {
      if (mounted) _toast('插入图片失败: $e');
    }
  }

  /// Word 插入图片入口：设备相册 / App 截图库（修「只有截图一条路」）。
  Future<void> _docxPickImage() async {
    try {
      final path = await pickImagePathFromSource(context);
      if (path == null || !mounted) return;
      final bytes = await readImageBytes(path);
      if (bytes == null || bytes.isEmpty) {
        _toast('读取图片失败');
        return;
      }
      await _docxInsertImage(bytes, sourceLabel: '图片');
    } catch (e) {
      debugPrint('[Docx] pick image failed: $e');
      if (mounted) _toast('插入图片失败: $e');
    }
  }

  /// 分屏打开哔哩哔哩（Android 7+：两 App 各占半屏，边看视频边做笔记）。
  Future<void> _openBilibiliSplit() async {
    try {
      const channel = MethodChannel('io.github.zzy19074244935.libranote/split');
      final map = await channel.invokeMethod<Map>('openBilibili');
      if (mounted) {
        final ok = map?['ok'] == true;
        if (!ok) {
          final reason = (map?['reason'] as String?) ?? '';
          _toast(reason == 'not_installed'
              ? '未检测到哔哩哔哩 App，请先安装'
              : '分屏启动失败（$reason），请手动从最近任务分屏打开 B 站');
        } else {
          _toast('已尝试分屏打开 B 站：若系统未自动分屏，'
              '请按最近任务键，把本 App 与 B 站拖到一起分屏');
        }
      }
    } catch (e) {
      if (mounted) {
        _toast('当前设备不支持分屏启动 B 站（Android 7+ 可用）');
      }
    }
  }

  /// §2.8：复制后确保该选区有一条记录（原文必存）。
  Future<void> _docxEnsureCopyRecord(TxtSelection sel) async {
    try {
      final existing = await ref
          .read(storageServiceProvider)
          .getDocxNotes(widget.book.id);
      final has = existing.any((n) =>
          n.paraIndex == sel.paraIndex &&
          n.startOffset == sel.start &&
          n.endOffset == sel.end);
      if (has) return;
      await ref.read(storageServiceProvider).upsertDocxNote(DocxNote(
            bookId: widget.book.id,
            paraIndex: sel.paraIndex,
            startOffset: sel.start,
            endOffset: sel.end,
            quotedText: sel.text,
            style: 'plain',
            source: 'manual',
          ));
      await _loadDocxNotes();
    } catch (e) {
      debugPrint('[Docx] ensure copy record failed: $e');
    }
  }

  /// 点击高亮 → 底部弹窗：原文 + 笔记 + 删除。
  Future<void> _docxOnHighlightTap(DocxNote note) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.source == 'ai' ? 'AI 笔记' : 'Word 批注',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                  Text('第 ${note.paraIndex + 1} 段',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  border: const Border(
                      left: BorderSide(color: Colors.grey, width: 3)),
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                ),
                child: Text(note.quotedText,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.5)),
              ),
              // 图片批注（style='image'）：显示图片本身，可复制/保存。
              if (note.style == 'image' &&
                  note.imagePath != null &&
                  note.imagePath!.isNotEmpty) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: Image.file(
                      File(note.imagePath!),
                      width: double.infinity,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text('图片文件缺失',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                      ),
                    ),
                  ),
                ),
              ],
              if (note.note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(note.note,
                    style: const TextStyle(fontSize: 14, height: 1.6)),
              ],
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                  // 图片批注：复制到 App 截图库 / 保存到系统下载目录。
                  if (note.style == 'image' &&
                      note.imagePath != null &&
                      note.imagePath!.isNotEmpty) ...[
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('复制'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _docxImageAction(note, false);
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: const Text('保存'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _docxImageAction(note, true);
                      },
                    ),
                  ],
                  if (note.id != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.red),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await ref
                            .read(storageServiceProvider)
                            .deleteDocxNote(note.id!);
                        await _loadDocxNotes();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Word 图片批注 → 复制到 App 截图库（saveToDownloads=false）或
  /// 保存到系统下载目录（true）。
  Future<void> _docxImageAction(DocxNote note, bool saveToDownloads) async {
    final imgPath = note.imagePath;
    if (imgPath == null || imgPath.isEmpty) {
      _toast('图片文件不存在');
      return;
    }
    try {
      final file = File(imgPath);
      if (!await file.exists()) {
        _toast('图片文件已不存在（可能已被删除）');
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (saveToDownloads) {
        final ok = await ShotActions.saveToLocal(context, ref, bytes,
            prefix: 'docx_img');
        if (mounted) _toast(ok ? '已保存到本机下载目录' : '保存失败，请重试');
      } else {
        final saved =
            await ShotActions.saveToLibrary(bytes, prefix: 'docx_img');
        if (mounted) {
          _toast(saved != null
              ? '已复制到 App 截图库（任意文件/画布里可再次插入）'
              : '复制失败，请重试');
        }
      }
    } catch (e) {
      debugPrint('[Docx] image copy/save failed: $e');
      if (mounted) _toast('操作失败: $e');
    }
  }

  /// Small banner shown above TXT content to indicate GBK encoding.
  Widget _encodingHint(String encoding, ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colors.secondaryContainer,
      child: Text(
        '该文件为 $encoding 编码，若显示有误请用记事本另存为 UTF-8 后重新导入',
        style: TextStyle(fontSize: 12, color: colors.onSecondaryContainer),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// Generic format-error page with a retry button.
  Widget _formatError(ColorScheme colors, String format, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.error),
            const SizedBox(height: 12),
            Text('$format 打开失败',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _epubHeader(LoadedEpub book, ColorScheme colors) {
    final total = book.sections.length;
    final index = _epubSection.clamp(0, total - 1);
    return Material(
      color: colors.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _showEpubToc(book),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.list, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  book.sections[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Text('${index + 1}/$total',
                  style: TextStyle(
                      fontSize: 12, color: colors.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  /// Table of contents built from the spine, so every section is reachable
  /// even when the book's own NCX only lists a handful of them.
  void _showEpubToc(LoadedEpub book) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (ctx, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('目录',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(width: 8),
                    Text('${book.sections.length} 节',
                        style: TextStyle(
                            fontSize: 12, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: book.sections.length,
                  itemBuilder: (ctx, i) {
                    final section = book.sections[i];
                    final selected = i == _epubSection;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      leading: Text('${i + 1}',
                          style: TextStyle(
                              fontSize: 12, color: colors.onSurfaceVariant)),
                      title: Text(section.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Navigator.pop(ctx);
                        _epubViewKey.currentState?.jumpTo(i);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _epubError(ColorScheme colors, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.error),
            const SizedBox(height: 12),
            Text('EPUB 打开失败',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text(
              '文件可能不完整或不是标准 EPUB。\n可以删除后重新导入试试。',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ── Reading settings bottom sheet ────────────────────────────────────

  void _showReaderSettings(ReaderSettings s) {
    final notifier = ref.read(readerSettingsProvider.notifier);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        // Local state so sliders feel responsive — only persist on dismiss
        // or when the user finishes dragging.
        var fontSize = s.fontSize;
        var lineHeight = s.lineHeight;
        var pageMargin = s.pageMargin;
        var theme = s.theme;
        var useSerif = s.useSerif;
        var tapToTurn = s.tapToTurn;
        var immersive = s.immersive;

        return StatefulBuilder(
          builder: (ctx, setLocal) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.onSurfaceVariant.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('阅读设置',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 20),

                    // ── Font size slider ────────────────────────────
                    _SettingSlider(
                      icon: Icons.format_size,
                      label: '字号',
                      value: fontSize,
                      min: 14,
                      max: 28,
                      divisions: 14,
                      displayValue: '${fontSize.round()}',
                      onChanged: (v) => setLocal(() => fontSize = v),
                      onChangeEnd: (v) => notifier.setFontSize(v),
                    ),
                    const SizedBox(height: 8),

                    // ── Line height slider ──────────────────────────
                    _SettingSlider(
                      icon: Icons.format_line_spacing,
                      label: '行距',
                      value: lineHeight,
                      min: 1.4,
                      max: 2.2,
                      divisions: 8,
                      displayValue: lineHeight.toStringAsFixed(2),
                      onChanged: (v) => setLocal(() => lineHeight = v),
                      onChangeEnd: (v) => notifier.setLineHeight(v),
                    ),
                    const SizedBox(height: 8),

                    // ── Page margin slider ──────────────────────────
                    _SettingSlider(
                      icon: Icons.margin,
                      label: '页边距',
                      value: pageMargin,
                      min: 12,
                      max: 40,
                      divisions: 14,
                      displayValue: '${pageMargin.round()}',
                      onChanged: (v) => setLocal(() => pageMargin = v),
                      onChangeEnd: (v) => notifier.setPageMargin(v),
                    ),
                    const SizedBox(height: 20),

                    // ── Theme selector ──────────────────────────────
                    Text('主题',
                        style: Theme.of(ctx).textTheme.labelLarge
                            ?.copyWith(color: colors.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _ThemeChip(
                          label: '日间',
                          emoji: '☀️',
                          selected: theme == 'day',
                          backgroundColor: colors.surface,
                          textColor: colors.onSurface,
                          onTap: () {
                            setLocal(() => theme = 'day');
                            notifier.setTheme('day');
                          },
                        ),
                        const SizedBox(width: 8),
                        _ThemeChip(
                          label: '夜间',
                          emoji: '🌙',
                          selected: theme == 'night',
                          backgroundColor: const Color(0xFF121212),
                          textColor: const Color(0xFFC8C8C8),
                          onTap: () {
                            setLocal(() => theme = 'night');
                            notifier.setTheme('night');
                          },
                        ),
                        const SizedBox(width: 8),
                        _ThemeChip(
                          label: '纸黄',
                          emoji: '📜',
                          selected: theme == 'sepia',
                          backgroundColor: const Color(0xFFF5ECD9),
                          textColor: const Color(0xFF5B4636),
                          onTap: () {
                            setLocal(() => theme = 'sepia');
                            notifier.setTheme('sepia');
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // ── readest 11 套纸面主题 ──────────────────────
                    Text('readest 主题（11 套）',
                        style: Theme.of(ctx).textTheme.labelLarge
                            ?.copyWith(color: colors.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final id in readestThemes.keys)
                          _ReadestThemeDot(
                            id: id,
                            selected: theme == 'readest:$id',
                            onTap: () {
                              setLocal(() => theme = 'readest:$id');
                              notifier.setTheme('readest:$id');
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Toggles ─────────────────────────────────────
                    _SettingToggle(
                      icon: Icons.text_fields,
                      label: '衬线字体',
                      value: useSerif,
                      onChanged: (v) {
                        setLocal(() => useSerif = v);
                        notifier.setUseSerif(v);
                      },
                    ),
                    _SettingToggle(
                      icon: Icons.touch_app,
                      label: '点击翻页',
                      subtitle: '左右点击翻页（左=上页，右=下页）',
                      value: tapToTurn,
                      onChanged: (v) {
                        setLocal(() => tapToTurn = v);
                        notifier.setTapToTurn(v);
                      },
                    ),
                    _SettingToggle(
                      icon: Icons.fullscreen,
                      label: '沉浸式',
                      subtitle: '隐藏顶栏底栏，点击中间唤出',
                      value: immersive,
                      onChanged: (v) {
                        setLocal(() => immersive = v);
                        notifier.setImmersive(v);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Tap handler (tap-to-turn + immersive exit) ────────────────────────

  void _handleTap(TapUpDetails details, String ext) {
    final settings = ref.read(readerSettingsProvider);
    final w = MediaQuery.of(context).size.width;

    // Immersive exit: tap in the centre third brings chrome back.
    if (settings.immersive) {
      final x = details.localPosition.dx;
      if (x > w / 3 && x < w * 2 / 3) {
        ref.read(readerSettingsProvider.notifier).setImmersive(false);
      }
      return;
    }

    // 朗读进行中：点击不再翻页（点击留给「从某处开始朗读」的段落选择），
    // 翻页请先停止朗读或用底部翻页按钮。
    if (_ttsActive) return;

    // Tap-to-turn: only active when enabled and not in immersive mode.
    if (!settings.tapToTurn) return;

    final x = details.localPosition.dx;
    final forward = x > w * 2 / 3;
    final backward = x < w / 3;
    if (!forward && !backward) return;

    switch (ext) {
      case 'pdf':
        if (forward && _pdfCurrentPage < _pdfTotalPages) {
          _pdfController?.goToPage(pageNumber: _pdfCurrentPage + 1);
        } else if (backward && _pdfCurrentPage > 1) {
          _pdfController?.goToPage(pageNumber: _pdfCurrentPage - 1);
        }
      case 'epub':
        if (forward && _epubSection < _epubTotal - 1) {
          _epubViewKey.currentState?.jumpTo(_epubSection + 1);
        } else if (backward && _epubSection > 0) {
          _epubViewKey.currentState?.jumpTo(_epubSection - 1);
        }
      case 'txt':
      case 'docx':
        _txtViewKey.currentState?.scrollPage(forward);
      case 'md':
      case 'markdown':
        _mdViewKey.currentState?.scrollPage(forward);
    }
  }

  // ── Unsupported format ────────────────────────────────────────────────
  ///
  /// Shown for MOBI, AZW3, DJVU, FB2, RTF and any other format that has no
  /// in-app reader. Offers opening the file with the system default app.

  Widget _buildUnsupportedReader(ReaderState reader, ColorScheme colors, String ext) {
    final localPath = reader.localPath;
    final extUpper = ext.toUpperCase();

    // Human-readable labels for known unsupported formats.
    const formatLabels = <String, String>{
      'mobi': 'MOBI (Kindle)',
      'azw3': 'AZW3 (Kindle)',
      'djvu': 'DJVU (扫描文档)',
      'fb2': 'FB2 (FictionBook)',
      'rtf': 'RTF (富文本)',
      'doc': 'DOC (旧版 Word)',
    };

    // 旧版 .doc 给明确指引：用 Word 另存为 .docx 即可内置打开。
    final hint = ext == 'doc'
        ? '旧版 .doc 是二进制格式，内置阅读器支持 .docx。\n'
            '请用 Word/WPS 打开后「另存为」Word 文档 (.docx)，'
            '再导入阅读和批注。'
        : '暂不支持该格式的内置阅读';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 64, color: colors.primary),
            const SizedBox(height: 16),
            Text(formatLabels[ext] ?? '$extUpper 格式',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
            if (localPath != null) ...[
              const SizedBox(height: 4),
              Text(localPath,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            // ── Actions ──────────────────────────────────────────────
            if (localPath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  label: const Text('用其他 App 打开'),
                  onPressed: () {
                    OpenFile.open(localPath);
                  },
                ),
              ),

          ],
        ),
      ),
    );
  }

  // ── PDF text selection + highlights ───────────────────────────────────

  /// 文字选择变化回调：有选中文字 → 弹出两行功能栏；清空 → 收起。
  /// 延迟到帧尾再 setState，避免在引擎 build 期间触发重建。
  void _onPdfTextSelectionChange(PdfTextSelection selection) {
    final active = selection.hasSelectedText;
    if (active == _pdfSelectionActive || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || active == _pdfSelectionActive) return;
      setState(() => _pdfSelectionActive = active);
    });
  }

  /// 选中功能栏（与 readest 引擎 host.html 同款两行布局）：
  /// 第一行 复制|搜索|翻译|朗读|批注|AI|分享|截图；
  /// 第二行 高亮批注栏 = 样式三态（高亮/下划线/波浪线）+ 5 色圆点。
  Widget _buildPdfSelectionBar(ColorScheme colors) {
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
    final effectiveColor = _pdfSelColor ?? styleDefault[_pdfSelStyle];

    Widget btn(IconData icon, String label, VoidCallback onTap,
        {Color? color}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: color?.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 15,
                  color: color ?? colors.onSurfaceVariant),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color ?? colors.onSurfaceVariant,
                  )),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
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
              children: [
                btn(Icons.copy, '复制', () => _pdfSelAction('copy')),
                const SizedBox(width: 4),
                btn(Icons.search, '搜索', () => _pdfSelAction('search')),
                const SizedBox(width: 4),
                btn(Icons.translate, '翻译', () => _pdfSelAction('translate')),
                const SizedBox(width: 4),
                btn(Icons.record_voice_over_outlined, '朗读',
                    () => _pdfSelAction('tts')),
                const SizedBox(width: 4),
                btn(Icons.edit_note, '批注', () => _pdfSelAction('note'),
                    color: colors.primary),
                const SizedBox(width: 4),
                btn(Icons.auto_awesome, 'AI', () => _pdfSelAction('ai'),
                    color: const Color(0xFF7C3AED)),
                const SizedBox(width: 4),
                btn(Icons.share_outlined, '分享', () => _pdfSelAction('share')),
              ],
            ),
          ),
          const SizedBox(height: 6),
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
                    setState(() => _pdfSelStyle = style.$1);
                    _pdfSelApplyStyle();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _pdfSelStyle == style.$1
                          ? colors.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      style.$2,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: _pdfSelStyle == style.$1
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: _pdfSelStyle == style.$1
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
              ],
              const Spacer(),
              for (final hex in dotColors)
                GestureDetector(
                  onTap: () {
                    setState(() => _pdfSelColor = hex);
                    _pdfSelApplyStyle();
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: Color(
                          int.parse(hex.replaceFirst('#', '0xFF'))),
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

  /// 功能栏动作统一入口：从 pdfrx 拿当前选区 delegate。
  void _pdfSelAction(String name) {
    final sel = _pdfController?.textSelectionDelegate;
    if (sel == null || !sel.hasSelectedText) return;
    switch (name) {
      case 'copy':
        sel.copyTextSelection();
      case 'search':
        _processPdfSearch(sel);
      case 'translate':
        _processPdfTranslate(sel);
      case 'tts':
        _processPdfRead(sel);
      case 'note':
        _processPdfNote(sel);
      case 'ai':
        _processPdfAi(sel);
      case 'share':
        _processPdfShare(sel);
    }
  }

  /// 点样式三态 / 颜色圆点 → 立刻把当前选区应用成对应标注。
  Future<void> _pdfSelApplyStyle() async {
    final sel = _pdfController?.textSelectionDelegate;
    if (sel == null || !sel.hasSelectedText) return;
    const styleDefault = <String, String>{
      'highlight': '#FACC15',
      'underline': '#4ADE80',
      'squiggly': '#60A5FA',
    };
    await _processPdfSelection(
      sel,
      _pdfSelColor ?? styleDefault[_pdfSelStyle]!,
      _pdfSelStyle,
    );
  }

  /// 正常模式下的文本框属性面板（双击选中 AI 页边文字后出现）：
  /// 字号 / 角度 / 编辑文字 / 删除 / 完成。
  Widget _buildPdfTextPanel(ColorScheme colors) {
    final page = _currentPdfPage;
    if (page == null) return const SizedBox.shrink();
    // 图片批注：简化面板（删除 + 完成），复用 _inkDeleteSelected。
    if (_selectedImageId != null &&
        _inkSelectedImageOnPage(_pdfCurrentPage) != null) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Icon(Icons.image_outlined, size: 16),
              const SizedBox(width: 6),
              const Text('图片批注', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              // 复制到 App 截图库（任意文件/画布可再次插入）。
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制', style: TextStyle(fontSize: 12)),
                onPressed: () => _pdfImageAction(false),
              ),
              // 保存到系统下载目录（文件 App 可见）。
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('保存', style: TextStyle(fontSize: 12)),
                onPressed: () => _pdfImageAction(true),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('删除', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  final pg = _currentPdfPage;
                  if (pg != null) _inkDeleteSelected(pg);
                },
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: () => setState(_inkClearSelection),
                child: const Text('完成', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
    final item = _inkSelectedTextOnPage(_pdfCurrentPage);
    if (item == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
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
          Row(
            children: [
              const Icon(Icons.format_size, size: 16),
              const SizedBox(width: 4),
              const Text('字号', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: item.fontSize.clamp(6.0, 30.0),
                  min: 6,
                  max: 30,
                  onChanged: (v) => _inkUpdateSelectedText(
                      (t) => t.copyWith(fontSize: v)),
                  onChangeEnd: (_) => _savePdfInk(_pdfCurrentPage),
                ),
              ),
              Text('${item.fontSize.round()}',
                  style: const TextStyle(
                      fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.rotate_right, size: 16),
              const SizedBox(width: 4),
              const Text('角度', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: item.rotation.clamp(-180.0, 180.0),
                  min: -180,
                  max: 180,
                  onChanged: (v) => _inkUpdateSelectedText(
                      (t) => t.copyWith(rotation: v)),
                  onChangeEnd: (_) => _savePdfInk(_pdfCurrentPage),
                ),
              ),
              Text('${item.rotation.round()}°',
                  style: const TextStyle(
                      fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Icons.edit_note, size: 16),
                label: const Text('编辑文字', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  final pg = _currentPdfPage;
                  if (pg != null) _inkEditSelectedText(pg);
                },
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('删除', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  final pg = _currentPdfPage;
                  if (pg != null) _inkDeleteSelected(pg);
                },
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14)),
                onPressed: () => setState(_inkClearSelection),
                child: const Text('完成', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 修改当前选中的文本框（面板滑杆等调用；不落盘，由 onChangeEnd 落）。
  void _inkUpdateSelectedText(PdfTextItem Function(PdfTextItem) update) {
    final id = _selectedTextId;
    final page = _currentPdfPage;
    if (id == null || page == null) return;
    final ink = _pdfInkByPage[page.pageNumber];
    if (ink == null) return;
    final idx = ink.texts.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    _inkReplaceTextItem(page, idx, update(ink.texts[idx]));
    setState(() {});
  }

  /// 从选区范围推断真实页码（修复笔记错位：`_pdfCurrentPage` 状态可能
  /// 与实际渲染页失步，导致第 2 页的高亮存成第 1 页、跳转永远回第 1 页）。
  int _pageOfSelection(List<PdfPageTextRange> ranges) {
    if (ranges.isNotEmpty) {
      final p = ranges.first.pageText.pageNumber;
      if (p > 0) return p;
    }
    return _pdfCurrentPage;
  }

  /// Process a PDF text selection as a highlight/underline/squiggly mark.
  Future<void> _processPdfSelection(
    PdfTextSelectionDelegate sel,
    String color,
    String style,
  ) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;

    // 先截过图？把暂存的截图带上（四要素捆绑——「截图已保存但笔记里没有」的修复）。
    final shotPath = _pendingPdfShots.remove(text.trim());

    final ranges = await sel.getSelectedTextRanges();
    final rects = _pdfCalculateNormRects(ranges);
    final anchor = TextAnchor(
      kind: AnchorKind.pdf,
      pageIndex: _pageOfSelection(ranges),
      rects: rects,
      prefix: text.length > 24 ? text.substring(0, 24) : text,
    );

    if (mounted) {
      ref.read(readerProvider.notifier).addAnnotation(
            anchor: anchor,
            quotedText: text,
            type: AnnotationType.highlight,
            color: color,
            style: style,
            imagePath: shotPath,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(style == 'highlight' ? '已高亮' : '已添加$style标记'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
    await sel.clearTextSelection();
  }

  /// 搜索：直接跳系统浏览器网页搜索（不再进 App 内「发现图书」搜索页）。
  Future<void> _processPdfSearch(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;
    await sel.clearTextSelection();
    if (!mounted) return;
    await openWebSearch(text, context: context);
  }

  /// 翻译：底部弹层展示翻译结果（复用 TranslateService，免费无 key）。
  Future<void> _processPdfTranslate(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;
    await sel.clearTextSelection();
    if (!mounted) return;
    final future = TranslateService.instance.translate(text, 'zh');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<String>(
                  future: future,
                  builder: (ctx, snap) {
                    final txt = snap.connectionState != ConnectionState.done
                        ? '翻译中…'
                        : (snap.data ?? '翻译失败');
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        child: Text(txt,
                            style: const TextStyle(
                                fontSize: 14, height: 1.6)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分享选中文本：临时 txt → 系统分享面板。
  Future<void> _processPdfShare(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;
    await sel.clearTextSelection();
    if (!mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/selection-'
          '${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(text);
      await Share.shareXFiles([XFile(file.path)], subject: '选中文字分享');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败: $e')),
        );
      }
    }
  }

  // ── PDF 图片批注 / 截图（问题14） ────────────────────────────────────

  /// 渲染 PDF 整页为 PNG 字节（fullWidth = 1.5×页宽，白底）。
  Future<Uint8List?> _renderPdfPagePng(int pageNumber) async {
    final doc = _pdfDocument;
    if (doc == null || pageNumber < 1 || pageNumber > doc.pages.length) {
      return null;
    }
    try {
      final page = doc.pages[pageNumber - 1];
      final pdfImg = await page.render(
        fullWidth: page.width * 1.5,
        fullHeight: page.height * 1.5,
        backgroundColor: 0xFFFFFFFF,
      );
      if (pdfImg == null) return null;
      final img = await pdfImg.createImage();
      pdfImg.dispose();
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[Shot] render pdf page $pageNumber failed: $e');
      return null;
    }
  }

  /// 图片/截图底部弹层：截图当前页插入 / 仅截图 / 从截图库插入 / 相册插入。
  Future<void> _showPdfImageSheet() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('图片 / 截图',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.crop_free),
                title: const Text('截图当前页并插入'),
                subtitle: const Text('渲染整页 → 存截图库 → 插入当前页批注图层'),
                onTap: () {
                  Navigator.pop(ctx);
                  _shotPdfPageAndInsert();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('仅截图保存'),
                subtitle: const Text('渲染整页 → 只存到 App 截图库'),
                onTap: () {
                  Navigator.pop(ctx);
                  _shotPdfPageOnly();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从 App 截图库插入'),
                subtitle: const Text('阅读器/画布截过的图都在这里（含随笔记保存的选区截图）'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickPdfImageFromShots();
                },
              ),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('从相册选择插入'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickPdfImageFromGallery();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shotPdfPageAndInsert() async {
    final pageNumber = _pdfCurrentPage;
    final bytes = await _renderPdfPagePng(pageNumber);
    if (bytes == null) {
      if (mounted) _toast('截图失败（页面渲染不可用）');
      return;
    }
    final path = await ShotLibrary.instance.savePng(bytes, prefix: 'pdf');
    if (path == null) {
      if (mounted) _toast('截图失败（保存失败）');
      return;
    }
    await _insertPdfImage(path, pageNumber);
    if (!mounted) return;
    _toast('已截图并插入页面（可拖动）');
  }

  Future<void> _shotPdfPageOnly() async {
    final bytes = await _renderPdfPagePng(_pdfCurrentPage);
    if (bytes == null) {
      if (mounted) _toast('截图失败（页面渲染不可用）');
      return;
    }
    final path = await ShotLibrary.instance.savePng(bytes, prefix: 'pdf');
    if (path == null) {
      if (mounted) _toast('截图失败（保存失败）');
      return;
    }
    if (!mounted) return;
    _toast('截图已保存到 App 截图库');
  }

  /// 从 App 截图库选一张插入当前页（与 Word / 画布共用同一个缩略图网格
  /// 选择器）。截图库现在同时收录 `shots/` 与阅读时的 `ai_shots/`。
  Future<void> _pickPdfImageFromShots() async {
    final path = await showShotLibraryPicker(context);
    if (path == null || !mounted) return;
    await _insertPdfImage(path, _pdfCurrentPage);
  }

  Future<void> _pickPdfImageFromGallery() async {
    final path = await ShotLibrary.instance.pickLocalImage();
    if (path == null) return;
    await _insertPdfImage(path, _pdfCurrentPage);
  }

  /// 把源图片复制到 Documents/pdf_images/<bookId>/ 并加入指定页批注图层。
  /// [normRect] 非空时按框选截图区域（0~1 归一化）放置，否则居中 40% 宽。
  Future<void> _insertPdfImage(String srcPath, int pageNumber,
      {Rect? normRect}) async {
    final src = File(srcPath);
    if (!await src.exists()) {
      if (mounted) _toast('源图片不存在');
      return;
    }
    try {
      final bytes = await src.readAsBytes();
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'pdf_images', widget.book.id));
      if (!await dir.exists()) await dir.create(recursive: true);
      var ext = p.extension(srcPath);
      if (ext.isEmpty) ext = '.png';
      final id = 'img${DateTime.now().millisecondsSinceEpoch}${_inkCounter++}';
      final fileName = '$id$ext';
      await File(p.join(dir.path, fileName)).writeAsBytes(bytes, flush: true);

      double x;
      double y;
      double w;
      double h;
      final rect = normRect;
      if (rect != null) {
        // 框选截图：按截图区域归一化矩形放置（所见即所得）。
        x = rect.left.clamp(0.0, 1.0);
        y = rect.top.clamp(0.0, 1.0);
        w = rect.width.clamp(0.05, 0.95);
        h = rect.height.clamp(0.05, 0.95);
      } else {
        // 解出图片宽高比，按页面宽高比折算归一化 h（保持不拉伸）。
        double imgAspect = 1.0;
        try {
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          if (frame.image.height > 0) {
            imgAspect = frame.image.width / frame.image.height;
          }
          frame.image.dispose();
        } catch (e) {
          debugPrint('[Ink] decode image ratio failed: $e');
        }
        final page = _currentPdfPage;
        final pageAspect =
            (page != null && page.height > 0) ? page.width / page.height : 1.0;
        w = 0.4;
        h = (pageAspect > 0 && imgAspect > 0)
            ? (w * pageAspect / imgAspect).clamp(0.05, 0.95)
            : w;
        x = (0.5 - w / 2).clamp(0.0, 1.0 - w);
        y = (0.5 - h / 2).clamp(0.0, 1.0 - h);
      }

      final item = PdfImageItem(
        id: id,
        x: x,
        y: y,
        w: w,
        h: h,
        fileName: fileName,
      );

      _inkPushUndo();
      final ink = _pdfInkByPage[pageNumber] ?? const PdfInkPage();
      final images = List<PdfImageItem>.from(ink.images)..add(item);
      _pdfInkByPage[pageNumber] = ink.copyWith(images: images);
      if (!mounted) return;
      setState(() {
        _selectedImageId = id;
        _selectedStrokeId = null;
        _selectedTextId = null;
      });
      await _savePdfInk(pageNumber);
    } catch (e) {
      debugPrint('[Ink] insert image failed: $e');
      if (mounted) _toast('插入图片失败: $e');
    }
  }

  /// 图片文件绝对路径（Documents/pdf_images/<bookId>/<fileName>）。
  Future<String> _pdfImagePath(String fileName) async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'pdf_images', widget.book.id, fileName);
  }

  /// 删除图片时同步删除磁盘文件（best-effort）。
  Future<void> _deletePdfImageFile(PdfImageItem item) async {
    try {
      final path = await _pdfImagePath(item.fileName);
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[Ink] delete image file failed: $e');
    }
  }

  /// 选中图片 → 复制到 App 截图库（saveToDownloads=false）或
  /// 保存到系统下载目录（true）。
  Future<void> _pdfImageAction(bool saveToDownloads) async {
    final item = _inkSelectedImageOnPage(_pdfCurrentPage);
    if (item == null || item.fileName.isEmpty) {
      _toast('没有选中的图片');
      return;
    }
    try {
      final path = await _pdfImagePath(item.fileName);
      final file = File(path);
      if (!await file.exists()) {
        _toast('图片文件已不存在（可能已被删除）');
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (saveToDownloads) {
        final ok = await ShotActions.saveToLocal(context, ref, bytes,
            prefix: 'pdf_img');
        if (mounted) _toast(ok ? '已保存到本机下载目录' : '保存失败，请重试');
      } else {
        final saved =
            await ShotActions.saveToLibrary(bytes, prefix: 'pdf_img');
        if (mounted) {
          _toast(saved != null
              ? '已复制到 App 截图库（任意文件/画布里可再次插入）'
              : '复制失败，请重试');
        }
      }
    } catch (e) {
      debugPrint('[Ink] image copy/save failed: $e');
      if (mounted) _toast('操作失败: $e');
    }
  }

  /// Process a PDF text selection as a note.
  Future<void> _processPdfNote(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;

    // Show note dialog after a frame so the context menu can dismiss.
    if (!mounted) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
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
                border: const Border(
                    left: BorderSide(color: Colors.grey, width: 3)),
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
              ),
              child: Text(
                text,
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
              decoration: const InputDecoration(
                hintText: '输入笔记内容…',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) {
      await sel.clearTextSelection();
      return;
    }

    final ranges = await sel.getSelectedTextRanges();
    final rects = _pdfCalculateNormRects(ranges);
    final anchor = TextAnchor(
      kind: AnchorKind.pdf,
      pageIndex: _pageOfSelection(ranges),
      rects: rects,
      prefix: text.length > 24 ? text.substring(0, 24) : text,
    );

    // 先截过图？把暂存的截图带上（四要素捆绑）。
    final shotPath = _pendingPdfShots.remove(text.trim());

    ref.read(readerProvider.notifier).addAnnotation(
          anchor: anchor,
          quotedText: text,
          note: ctrl.text.trim(),
          type: AnnotationType.note,
          imagePath: shotPath,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('笔记已保存'),
          duration: Duration(seconds: 1),
        ),
      );
    }
    await sel.clearTextSelection();
  }

  /// AI 对话框（PDF 手写模式/旧引擎）：选中文字 → 问 AI → 确认后：
  /// ①原文加 violet 高亮标记 ②存 ai_notes（file_type='pdf'）③可选把生成
  /// 文字插入当前页右边空白处（方案决策点 3，默认做）。
  Future<void> _processPdfAi(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;
    if (!mounted) return;

    // 先截过图？把暂存的截图带上（四要素捆绑）。
    final shotPath = _pendingPdfShots.remove(text.trim());
    final result = await showAiDialog(
      context,
      bookId: widget.book.id,
      fileType: 'pdf',
      fileName: widget.book.title,
      cfi: '', // pdfrx 引擎没有 CFI，锚点用页码+坐标
      quotedText: text,
      imagePath: shotPath,
      currentSectionIndex: _pdfCurrentPage > 0 ? _pdfCurrentPage - 1 : null,
    );
    if (result == null || !mounted) {
      // 取消/关闭：截图放回暂存，等下次同选区操作再捆绑。
      if (shotPath != null) _pendingPdfShots[text.trim()] = shotPath;
      await sel.clearTextSelection();
      return;
    }

    // 用户已在对话框确认「保存到笔记」，这里再问一句是否插入到页面上
    // （插入前可选字体颜色）。
    final choice = await _pdfConfirmInsert(
      result.content,
      '是否把这段解释插入到当前页面上？\n'
      '（插入后是页面上的浮动文本框：单击选中、拖动即可移到'
      '页面任意位置；顶部圆点旋转、右下角圆点缩放，可调字号与角度）',
    );
    if (!mounted) return;
    // 弹层被手势关闭（无取消按钮）：按「仅存笔记」处理，与旧行为一致。
    final insert = choice?.$1 ?? false;
    final insertColor = choice?.$2 ?? '#4C1D95';

    // 原文加 AI 高亮标记（violet）。
    final ranges = await sel.getSelectedTextRanges();
    final rects = _pdfCalculateNormRects(ranges);
    final pageNumber = _pageOfSelection(ranges);
    final anchor = TextAnchor(
      kind: AnchorKind.pdf,
      pageIndex: pageNumber,
      rects: rects,
      prefix: text.length > 24 ? text.substring(0, 24) : text,
    );
    ref.read(readerProvider.notifier).addAnnotation(
          anchor: anchor,
          quotedText: text,
          type: AnnotationType.highlight,
          color: '#7C3AED',
        );

    // 插入页面：当前页右缘留白处放文本框（可拖动/编辑/删除）。
    // 默认位置留出页边距（x∈[0.62,0.90]、y 不贴顶不贴底），并自动选中——
    // 用户双击/单击选中后即可用手拖动到页面任意位置。
    double? mx;
    double? my;
    if (insert) {
      mx = 0.62;
      final selTop = rects.isNotEmpty
          ? (rects.first.t < rects.first.b ? rects.first.t : rects.first.b)
          : 0.3;
      my = selTop.clamp(0.08, 0.78);
      _inkPushUndo();
      final page = _pdfInkByPage[pageNumber] ?? const PdfInkPage();
      final texts = List<PdfTextItem>.from(page.texts);
      final newTextId =
          'a${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}';
      texts.add(PdfTextItem(
        id: newTextId,
        x: mx,
        y: my,
        text: result.content,
        fontSize: 9,
        width: 0.28,
        color: _hexToArgbInt(insertColor),
      ));
      _pdfInkByPage[pageNumber] = page.copyWith(texts: texts);
      // 插入后立刻选中：用户直接看到蓝框 + 手柄 + 属性面板（双击也可）。
      setState(() {
        _selectedTextId = newTextId;
        _selectedStrokeId = null;
      });
      await _savePdfInk(pageNumber);
    }

    // ai_notes 落库（原文必填铁律；锚点=页码+页边坐标）。
    await ref.read(storageServiceProvider).insertAiNote(AiNote(
          bookId: widget.book.id,
          fileType: 'pdf',
          anchor: jsonEncode({
            'page': pageNumber,
            if (mx != null) 'x': mx,
            if (my != null) 'y': my,
          }),
          quotedText: text,
          content: result.content,
          imagePath: result.imagePath,
          conversationId: result.conversationId,
        ));
    await sel.clearTextSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(insert == true
            ? '已保存 AI 笔记并插入页面文字（单击可选中拖动）'
            : '已保存 AI 笔记（原文已标记）'),
      ),
    );
  }

  /// PDF：AI 内容已存笔记后，确认是否插入当前页（插入前可选字体颜色）。
  /// 返回 (是否插入, 颜色十六进制)；手势关闭返回 null（按不插入处理）。
  Future<(bool, String)?> _pdfConfirmInsert(
      String content, String hint) async {
    // ⚠️ 选中色必须存在 builder 闭包之外（同 _docxOnAi）：
    // StatefulBuilder 每次重建会重新执行 builder，写在里面会被重置回
    // 默认紫色——颜色圆点「看得见但点了没反应」的根因。
    var color = '#4C1D95';
    return showDialog<(bool, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: const Text('AI 内容已保存到笔记'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFEDE9FE)),
                  ),
                  child: Text(
                    content,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('插入文字的字体颜色：',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                _InsertColorDots(
                  selected: color,
                  onChanged: (c) => setDlg(() => color = c),
                ),
                const SizedBox(height: 12),
                Text(hint, style: const TextStyle(fontSize: 13, height: 1.6)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, (false, color)),
                child: const Text('仅存笔记'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => Navigator.pop(ctx, (true, color)),
                child: const Text('插入页面'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 扫描版 PDF：OCR 识别（图片版没有文字层，选中/检索/读书都失效） ──

  /// 工具栏「OCR 识别」：识别当前页 → 弹结果面板（复制/翻译/搜索/AI）。
  Future<void> _pdfOcrCurrentPage() async {
    if (_pdfOcrRunning) return;
    final path = widget.book.localPath;
    if (path == null || path.isEmpty) {
      _toast('文档还没加载好');
      return;
    }
    if (!PdfOcrService.supported) {
      _toast('当前平台不支持离线 OCR（请在安卓手机上使用）');
      return;
    }
    final pageNo = _pdfCurrentPage;
    setState(() => _pdfOcrRunning = true);
    try {
      final text =
          await PdfOcrService.instance.ocrPage(path, widget.book.id, pageNo);
      if (!mounted) return;
      if (text == null || text.trim().isEmpty) {
        _toast('本页没有识别出文字（可能不是扫描页，或图片太模糊）');
        return;
      }
      await _showPdfOcrSheet(text);
    } catch (e) {
      debugPrint('[OCR] page $pageNo failed: $e');
      if (mounted) _toast('OCR 识别失败: $e');
    } finally {
      if (mounted) setState(() => _pdfOcrRunning = false);
    }
  }

  /// OCR 结果面板：全文字可选中复制 + 复制/翻译/搜索/AI 提问。
  Future<void> _showPdfOcrSheet(String text) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.document_scanner_outlined,
                      size: 18, color: Color(0xFF7C3AED)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '第 $_pdfCurrentPage 页 · OCR 识别结果',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新识别',
                        style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await PdfOcrService.instance
                          .clearPageCache(widget.book.id, _pdfCurrentPage);
                      _pdfOcrCurrentPage();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 8),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontSize: 14.5, height: 1.7),
                ),
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                border: Border(top: BorderSide(color: Color(0xFFE8EDF3))),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  _ocrAction(ctx, Icons.copy, '复制', () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) _toast('已复制 OCR 全文');
                  }),
                  _ocrAction(ctx, Icons.translate, '翻译', () {
                    Navigator.pop(ctx);
                    _pdfOcrTranslate(text);
                  }),
                  _ocrAction(ctx, Icons.search, '搜索', () {
                    Navigator.pop(ctx);
                    openWebSearch(text, context: context);
                  }),
                  _ocrAction(ctx, Icons.auto_awesome, 'AI 提问', () {
                    Navigator.pop(ctx);
                    _pdfOcrAi(text);
                  }, const Color(0xFF7C3AED)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ocrAction(
      BuildContext ctx, IconData icon, String label, VoidCallback onTap,
      [Color? color]) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 11.5, color: color ?? Colors.grey.shade700)),
            ],
          ),
        ),
      ),
    );
  }

  /// OCR 结果 → 翻译（复用选中文字翻译的弹层样式）。
  Future<void> _pdfOcrTranslate(String text) async {
    if (!mounted) return;
    final future = TranslateService.instance.translate(text, 'zh');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('OCR 识别文字（第 $_pdfCurrentPage 页）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<String>(
                  future: future,
                  builder: (ctx, snap) {
                    final txt = snap.connectionState != ConnectionState.done
                        ? '翻译中…'
                        : (snap.data ?? '翻译失败');
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        child: SelectableText(txt,
                            style: const TextStyle(
                                fontSize: 14, height: 1.6)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// OCR 结果 → 书内 AI 对话：确认后 ai_note 落库 + 可选插入页面文本框。
  Future<void> _pdfOcrAi(String ocrText) async {
    if (!mounted) return;
    final result = await showAiDialog(
      context,
      bookId: widget.book.id,
      fileType: 'pdf',
      fileName: widget.book.title,
      cfi: '',
      quotedText: ocrText,
      currentSectionIndex: _pdfCurrentPage > 0 ? _pdfCurrentPage - 1 : null,
    );
    if (result == null || !mounted) return;

    final choice = await _pdfConfirmInsert(
      result.content,
      '是否把这段 AI 回答插入到当前页面上？\n'
      '（插入后是页面上的浮动文本框，可拖动/旋转/缩放）',
    );
    if (!mounted) return;
    final insert = choice?.$1 ?? false;
    final insertColor = choice?.$2 ?? '#4C1D95';

    final pageNumber = _pdfCurrentPage;
    double? mx;
    double? my;
    if (insert) {
      mx = 0.62;
      my = 0.30;
      _inkPushUndo();
      final page = _pdfInkByPage[pageNumber] ?? const PdfInkPage();
      final texts = List<PdfTextItem>.from(page.texts);
      final newTextId =
          'a${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}';
      texts.add(PdfTextItem(
        id: newTextId,
        x: mx,
        y: my,
        text: result.content,
        fontSize: 9,
        width: 0.28,
        color: _hexToArgbInt(insertColor),
      ));
      _pdfInkByPage[pageNumber] = page.copyWith(texts: texts);
      setState(() {
        _selectedTextId = newTextId;
        _selectedStrokeId = null;
      });
      await _savePdfInk(pageNumber);
    }

    await ref.read(storageServiceProvider).insertAiNote(AiNote(
          bookId: widget.book.id,
          fileType: 'pdf',
          anchor: jsonEncode({
            'page': pageNumber,
            'ocr': true,
            if (mx != null) 'x': mx,
            if (my != null) 'y': my,
          }),
          quotedText: ocrText,
          content: result.content,
          imagePath: result.imagePath,
          conversationId: result.conversationId,
        ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(insert
            ? '已保存 AI 笔记（OCR 原文）并插入页面文字'
            : '已保存 AI 笔记（OCR 原文，可在笔记中心查看）'),
      ),
    );
  }

  /// Build a list of normalised rectangles from PDF text selection ranges.
  ///
  /// Each character's bounding rect is divided by the page dimensions to
  /// produce a 0–1 coordinate that is independent of zoom / DPI.
  List<NormRect> _pdfCalculateNormRects(List<PdfPageTextRange> ranges) {
    final doc = _pdfDocument;
    if (doc == null) return [];

    final result = <NormRect>[];
    for (final range in ranges) {
      final page = doc.pages[range.pageText.pageNumber - 1];
      final pw = page.width;
      final ph = page.height;
      if (pw <= 0 || ph <= 0) continue;

      for (int i = range.start; i < range.end && i < range.pageText.charRects.length; i++) {
        final r = range.pageText.charRects[i];
        // PDF 坐标原点在左下、Y 向上；屏幕坐标 Y 向下。转换为 0~1 归一化：
        //   屏幕 top    = 1 - pdf_bottom/ph
        //   屏幕 bottom = 1 - pdf_top/ph
        // 旧代码把 top/bottom 用反了（t 用 pdf_top、b 用 pdf_bottom），得到
        // top > bottom 的非法矩形，Rect.fromLTRB 画不出东西——「PDF 高亮
        // 保存了却不显示」的根因。
        result.add(NormRect(
          l: r.left / pw,
          t: 1.0 - (r.bottom / ph),
          r: r.right / pw,
          b: 1.0 - (r.top / ph),
        ));
      }
    }
    return result;
  }

  /// Draw highlight rectangles on the currently rendered pages.
  ///
  /// Used as a [PdfViewerPagePaintCallback] so highlights move and scale with
  /// the page perfectly.
  void _pdfPaintHighlights(Canvas canvas, Rect pageRect, PdfPage page) {
    final reader = ref.read(readerProvider);
    final annotations = reader.annotations;

    final pageHighlights = annotations.where((a) =>
        a.anchor.kind == AnchorKind.pdf &&
        a.anchor.pageIndex == page.pageNumber &&
        a.anchor.rects.isNotEmpty);

    for (final ann in pageHighlights) {
      final color = Color(
        int.parse((ann.color ?? '#FFEB3B').replaceFirst('#', '0xFF')),
      );

      for (final nr in ann.anchor.rects) {
        // min/max 兜底：旧版本保存的 rects 的 t/b 是反的（Y 轴翻转错误），
        // 直接用会得到非法矩形画不出来；这里保证 top <= bottom。
        final r = Rect.fromLTRB(
          pageRect.left + nr.l * pageRect.width,
          pageRect.top +
              (nr.t < nr.b ? nr.t : nr.b) * pageRect.height,
          pageRect.left + nr.r * pageRect.width,
          pageRect.top +
              (nr.t < nr.b ? nr.b : nr.t) * pageRect.height,
        );
        switch (ann.style) {
          case 'underline':
            canvas.drawLine(
              r.bottomLeft,
              r.bottomRight,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.6
                ..strokeCap = StrokeCap.round,
            );
          case 'squiggly':
            // 波浪线：沿矩形底边画正弦波。
            final wave = Path();
            const seg = 3.5;
            final dx = r.width > 0 ? r.width : 1.0;
            final count = math.max(2, (dx / seg).ceil());
            wave.moveTo(r.left, r.bottom);
            for (var i = 1; i <= count; i++) {
              final x = r.left + dx * i / count;
              final y = r.bottom +
                  (i.isOdd ? -2.2 : 2.2);
              wave.lineTo(x, y);
            }
            canvas.drawPath(
              wave,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.3
                ..strokeCap = StrokeCap.round,
            );
          default:
            canvas.drawRect(
              r,
              Paint()
                ..color = color.withValues(alpha: 0.35)
                ..style = PaintingStyle.fill,
            );
        }
      }
    }

    // 定位闪烁：在目标页的高亮矩形上画脉动描边；手写批注没有矩形时
    // 画整页边框，跳回来一眼就能找到位置。
    if (_pdfFlashPage == page.pageNumber && _pdfFlashStart != null) {
      final elapsed =
          DateTime.now().difference(_pdfFlashStart!).inMilliseconds;
      final t = (elapsed % 600) / 600.0;
      final flashColor = Color.lerp(
          const Color(0xFFFFB300), const Color(0xFFFF5252), t)!;
      final flashPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = flashColor;
      var any = false;
      for (final ann in pageHighlights) {
        for (final nr in ann.anchor.rects) {
          final r = Rect.fromLTRB(
            pageRect.left + nr.l * pageRect.width,
            pageRect.top +
                (nr.t < nr.b ? nr.t : nr.b) * pageRect.height,
            pageRect.left + nr.r * pageRect.width,
            pageRect.top +
                (nr.t < nr.b ? nr.b : nr.t) * pageRect.height,
          );
          canvas.drawRect(r, flashPaint);
          any = true;
        }
      }
      if (!any) {
        canvas.drawRect(pageRect.deflate(4), flashPaint);
      }
    }
  }

  // ── PDF 手写批注 ─────────────────────────────────────────────────────

  Future<void> _loadPdfInk(int page) async {
    if (_pdfInkByPage.containsKey(page)) return;
    try {
      final ink =
          await ref.read(storageServiceProvider).getPdfInkPage(widget.book.id, page);
      if (!mounted) return;
      // 读取期间用户可能已经在这页画了新笔迹——此时绝不覆盖，否则
      // 「有的批注没保存、重开消失」。
      if (_pdfInkByPage.containsKey(page)) return;
      setState(() => _pdfInkByPage[page] = ink);
    } catch (e) {
      debugPrint('[Ink] load page $page failed: $e');
    }
  }

  Future<void> _savePdfInk(int page) async {
    final ink = _pdfInkByPage[page] ?? const PdfInkPage();
    try {
      final storage = ref.read(storageServiceProvider);
      await storage.savePdfInkPage(widget.book.id, page, ink);
      // 同步笔记中心：本页有内容就维护一条「手写批注」条目，清空则删掉。
      final count = ink.strokes.length + ink.texts.length + ink.images.length;
      await storage.syncPdfInkAnnotation(
          widget.book.id, page, count, widget.book.title);
    } catch (e) {
      debugPrint('[Ink] save page $page failed: $e');
    }
  }

  void _inkPushUndo() {
    _inkUndo.add(Map<int, PdfInkPage>.from(_pdfInkByPage));
    if (_inkUndo.length > 50) _inkUndo.removeAt(0);
    _inkRedo.clear();
  }

  void _inkUndoAction() {
    if (_inkUndo.isEmpty) return;
    _inkRedo.add(Map<int, PdfInkPage>.from(_pdfInkByPage));
    _pdfInkByPage
      ..clear()
      ..addAll(_inkUndo.removeLast());
    _inkClearSelection();
    setState(() {});
    _savePdfInk(_pdfCurrentPage);
  }

  void _inkRedoAction() {
    if (_inkRedo.isEmpty) return;
    _inkUndo.add(Map<int, PdfInkPage>.from(_pdfInkByPage));
    _pdfInkByPage
      ..clear()
      ..addAll(_inkRedo.removeLast());
    _inkClearSelection();
    setState(() {});
    _savePdfInk(_pdfCurrentPage);
  }

  void _inkClearPage() {
    final page = _pdfInkByPage[_pdfCurrentPage];
    if (page == null || page.isEmpty) return;
    _inkPushUndo();
    _pdfInkByPage[_pdfCurrentPage] = const PdfInkPage();
    _inkClearSelection();
    setState(() {});
    _savePdfInk(_pdfCurrentPage);
  }

  void _inkClearSelection() {
    _selectedStrokeId = null;
    _selectedTextId = null;
    _selectedImageId = null;
    _inkDragLast = null;
  }

  /// 每页的覆盖层：
  /// - 手写模式：整页 opaque 手势层（笔迹/文本操作 + 双击选中）；
  /// - 正常模式：整页 translucent 层只做双击选中（不与 pdfrx 滚动/选区
  ///   抢手势），已选中的文本框上再盖一个专属 opaque 层做拖动/旋转/缩放。
  List<Widget> _pdfInkOverlays(
      BuildContext context, Rect pageRect, PdfPage page) {
    final widgets = <Widget>[];
    if (_inkMode) {
      widgets.add(Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _inkTap(page, pageRect, d),
          onDoubleTapDown: (d) =>
              _inkDoubleTapAt(page, pageRect, _normOf(pageRect, d.localPosition)),
          onPanStart: (d) => _inkPanStart(page, pageRect, d),
          onPanUpdate: (d) => _inkPanUpdate(page, pageRect, d),
          onPanEnd: (_) => _inkPanEnd(page),
        ),
      ));
    } else {
      // 正常模式：整页 translucent 层用**原始指针事件**（Listener，不进
      // 手势竞技场）手动识别「单击选中 / 双击选中」——GestureDetector 的
      // tap/double-tap 识别器要与 pdfrx 的 scale/滚动识别器抢竞技场，
      // 抢输的后果就是 AI 插入的文本框怎么点都选不中、拖不动。原始指针
      // 事件与 pdfrx 互不干扰，必然生效。
      widgets.add(Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _pdfNormalPointerDown(page, pageRect, e),
          onPointerMove: (e) => _pdfNormalPointerMove(page, pageRect, e),
          onPointerUp: (e) => _pdfNormalPointerUp(page, pageRect, e),
          onPointerCancel: (_) => _pdfNormalPointerReset(),
        ),
      ));
      // 已选中的文本框：专属手势层（移动/旋转/缩放）。
      // 用 Listener（原始指针事件）而非 GestureDetector：正常模式下
      // pdfrx 的滚动/选区识别器会抢手势竞技场，pan 永远输 →「文本框
      // 死死吸在边缘拖不动」的根因。原始指针不走竞技场，必然生效。
      final sel = _inkSelectedTextOnPage(page.pageNumber);
      if (sel != null) {
        final layout = _inkTextLayout(pageRect, page, sel);
        const pad = 24.0;
        final left = (layout.pos.dx - pad).clamp(0.0, pageRect.width);
        final top = (layout.pos.dy - pad).clamp(0.0, pageRect.height);
        final right =
            (layout.pos.dx + layout.w + pad).clamp(0.0, pageRect.width);
        final bottom =
            (layout.pos.dy + layout.h + pad).clamp(0.0, pageRect.height);
        widgets.add(Positioned(
          left: left,
          top: top,
          width: math.max(0.0, right - left),
          height: math.max(0.0, bottom - top),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              // 拖动过程中这一层会跟着文本框移动，而 Flutter 在按下时就
              // 把命中变换固定住了：后续 move 的 localPosition 仍以「按下
              // 时的层位置」为基准。这里必须锁住按下瞬间的层原点，否则
              // 「新原点 + 旧 localPosition」每帧多算一次位移 → 文本框
              // 一拖就飞向边缘（用户反馈的 bug）。
              _inkTextLayerOrigin = Offset(left, top);
              _inkTextDragStart(
                  page, pageRect, e.localPosition + Offset(left, top),
                  allowPadding: true);
            },
            onPointerMove: (e) => _inkTextDragUpdate(page, pageRect,
                e.localPosition + (_inkTextLayerOrigin ?? Offset(left, top))),
            onPointerUp: (_) => _inkTextDragEnd(page),
            onPointerCancel: (_) => _inkTextDragEnd(page),
          ),
        ));
      }
      // 已选中的图片：专属手势层（移动 / 右下角缩放），同样走原始指针。
      final selImg = _inkSelectedImageOnPage(page.pageNumber);
      if (selImg != null) {
        final imgLeft = selImg.x * pageRect.width;
        final imgTop = selImg.y * pageRect.height;
        final imgW = selImg.w * pageRect.width;
        final imgH = selImg.h * pageRect.height;
        const pad = 22.0;
        final layerLeft = (imgLeft - pad).clamp(0.0, pageRect.width);
        final layerTop = (imgTop - pad).clamp(0.0, pageRect.height);
        final layerRight = (imgLeft + imgW + pad).clamp(0.0, pageRect.width);
        final layerBottom = (imgTop + imgH + pad).clamp(0.0, pageRect.height);
        widgets.add(Positioned(
          left: layerLeft,
          top: layerTop,
          width: math.max(0.0, layerRight - layerLeft),
          height: math.max(0.0, layerBottom - layerTop),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              // 同文本框：锁住按下瞬间的层原点（见上方注释），否则图片
              // 一拖就飞出去。
              _inkImageLayerOrigin = Offset(layerLeft, layerTop);
              _inkImageDragStart(page, pageRect,
                  e.localPosition + Offset(layerLeft, layerTop),
                  allowPadding: true);
            },
            onPointerMove: (e) => _inkImageDragUpdate(
                page,
                pageRect,
                e.localPosition +
                    (_inkImageLayerOrigin ?? Offset(layerLeft, layerTop))),
            onPointerUp: (_) => _inkImageDragEnd(page),
            onPointerCancel: (_) => _inkImageDragEnd(page),
          ),
        ));
      }
    }
    return widgets;
  }

  /// 归一化点击位置。
  Offset _normOf(Rect pageRect, Offset local) => Offset(
      local.dx / pageRect.width, local.dy / pageRect.height);

  /// 双击：命中文本/笔迹 → 选中（并切到选择工具方便直接拖动）；空白 → 取消。
  void _inkDoubleTapAt(PdfPage page, Rect pageRect, Offset n) {
    final (part, text) = _inkTextHit(page, pageRect, n);
    if (text != null) {
      setState(() {
        _selectedTextId = text.id;
        _selectedStrokeId = null;
        if (_inkMode) _inkSwitchTool(select: true);
      });
      return;
    }
    if (_inkMode) {
      final stroke = _inkHitStroke(page, n);
      if (stroke != null) {
        setState(() {
          _selectedStrokeId = stroke.id;
          _selectedTextId = null;
          _inkSwitchTool(select: true);
        });
        return;
      }
    }
    if (_selectedStrokeId != null ||
        _selectedTextId != null ||
        _selectedImageId != null) {
      setState(_inkClearSelection);
    }
  }

  /// 手写模式工具切换（双击选中后切到「选择」，避免拖动被当成画笔）。
  void _inkSwitchTool({required bool select}) {
    _inkEraser = false;
    _inkHighlighter = false;
    _inkSelect = select;
    _inkTextTool = false;
  }

  /// 点击：文本工具=放文本框；选择工具=命中选中/点空白取消选中。
  void _inkTap(PdfPage page, Rect pageRect, TapUpDetails d) {
    final n = _normOf(pageRect, d.localPosition);
    if (_inkTextTool) {
      _inkAddText(page, n);
      return;
    }
    if (_inkSelect) {
      final hitStroke = _inkHitStroke(page, n);
      final (_, hitText) = _inkTextHit(page, pageRect, n);
      final (_, hitImage) = _inkImageHit(page, pageRect, n);
      setState(() {
        _selectedStrokeId = hitStroke?.id;
        _selectedTextId = hitText?.id;
        _selectedImageId = hitImage?.id;
      });
    }
  }

  /// 正常模式单击/双击的原始指针识别状态（不进手势竞技场）。
  DateTime? _pdfLastTapTime;
  Offset? _pdfLastTapPos; // 归一化坐标
  Offset? _pdfTapDownPos; // 归一化坐标
  bool _pdfTapMoved = false;

  void _pdfNormalPointerDown(PdfPage page, Rect pageRect, PointerDownEvent e) {
    _pdfTapDownPos = _normOf(pageRect, e.localPosition);
    _pdfTapMoved = false;
  }

  void _pdfNormalPointerMove(PdfPage page, Rect pageRect, PointerMoveEvent e) {
    final down = _pdfTapDownPos;
    if (down == null) return;
    final n = _normOf(pageRect, e.localPosition);
    if ((n - down).distance > 0.015) _pdfTapMoved = true;
  }

  void _pdfNormalPointerReset() {
    _pdfTapDownPos = null;
    _pdfTapMoved = false;
  }

  void _pdfNormalPointerUp(PdfPage page, Rect pageRect, PointerUpEvent e) {
    final down = _pdfTapDownPos;
    final moved = _pdfTapMoved;
    _pdfNormalPointerReset();
    if (down == null) return;
    final n = _normOf(pageRect, e.localPosition);
    // 明显位移 = pdfrx 的滚动/选区拖动，不算点击。
    if (moved || (n - down).distance > 0.015) return;
    final now = DateTime.now();
    final lastTime = _pdfLastTapTime;
    final lastPos = _pdfLastTapPos;
    final isDoubleTap = lastTime != null &&
        lastPos != null &&
        now.difference(lastTime) < const Duration(milliseconds: 380) &&
        (lastPos - n).distance < 0.03;
    _pdfLastTapTime = now;
    _pdfLastTapPos = n;
    if (isDoubleTap) {
      // 双击：命中文本框/图片 → 选中（用户需求：双击选中后用手拖动）。
      _inkDoubleTapAt(page, pageRect, n);
    } else {
      // 单击：选中文本框/图片，或点高亮看批注。
      _pdfNormalTap(page, pageRect, n);
    }
  }

  /// 正常模式单击：
  /// · 点中高亮矩形 → 弹批注内容（像 EPUB 一样，点高亮看笔记）；
  /// · 点中文本框 → 选中（蓝框 + 手柄，随后单指拖动即可移动——
  ///   修「AI 插入的文字一直吸附在侧边动不了」：以前必须先双击才能选中）。
  void _pdfNormalTap(PdfPage page, Rect pageRect, Offset n) {
    // 1) 文本框中选（单击即选中，可拖动）。
    final (_, hitText) = _inkTextHit(page, pageRect, n);
    if (hitText != null) {
      setState(() {
        _selectedTextId = hitText.id;
        _selectedStrokeId = null;
        _selectedImageId = null;
      });
      return;
    }
    // 2) 图片命中（单击即选中，可拖动）。
    final (_, hitImage) = _inkImageHit(page, pageRect, n);
    if (hitImage != null) {
      setState(() {
        _selectedImageId = hitImage.id;
        _selectedStrokeId = null;
        _selectedTextId = null;
      });
      return;
    }
    // 3) 高亮矩形命中 → 弹批注内容。
    final reader = ref.read(readerProvider);
    for (final a in reader.annotations) {
      if (a.anchor.kind != AnchorKind.pdf ||
          a.anchor.pageIndex != page.pageNumber) {
        continue;
      }
      for (final nr in a.anchor.rects) {
        final t = nr.t < nr.b ? nr.t : nr.b;
        final b = nr.t < nr.b ? nr.b : nr.t;
        if (n.dx >= nr.l - 0.01 &&
            n.dx <= nr.r + 0.01 &&
            n.dy >= t - 0.01 &&
            n.dy <= b + 0.01) {
          _showPdfAnnotationDialog(a);
          return;
        }
      }
    }
  }

  /// PDF 打开失败（FPDF_ERR_FORMAT 等）时的友好错误横幅：
  /// 坏文件多是镜像把下载请求回成了网页（跳转页），引导用户删书重下。
  Widget _pdfErrorBanner(ColorScheme colors, Object error) {
    return Container(
      width: double.infinity,
      color: colors.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.onErrorContainer, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这本书打不开：文件可能不是有效的 PDF（下载被拦截成网页跳转页'
              '时会出现这种错误，本地导入的文件不会）。\n'
              '建议：删除这本书 → 换一个镜像重新下载，或用「浏览器下载」'
              '后重新导入。\n\n原始错误：$error',
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: colors.onErrorContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
                foregroundColor: colors.onErrorContainer),
            onPressed: () async {
              await ref.read(storageServiceProvider).removeBook(widget.book.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已从书架删除这本书，请重新下载')),
                );
                Navigator.of(context).pop();
              }
            },
            child: const Text('删除本书', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 点高亮 → 底部弹窗：原文 + 笔记内容 + 删除（像 EPUB/Word 一样）。
  Future<void> _showPdfAnnotationDialog(Annotation a) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      a.type == AnnotationType.note ? 'PDF 笔记' : 'PDF 高亮批注',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                  Text(a.anchor.display,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 10),
              if (a.quotedText.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                    border: const Border(
                        left: BorderSide(color: Colors.grey, width: 3)),
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  ),
                  child: Text(a.quotedText,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                ),
              if (a.note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(a.note,
                    style: const TextStyle(fontSize: 14, height: 1.6)),
              ],
              if (a.note.isEmpty && a.quotedText.isEmpty) ...[
                const SizedBox(height: 6),
                const Text('（这条批注没有文字内容）',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                  if (a.id != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        ref
                            .read(readerProvider.notifier)
                            .deleteAnnotation(a.id!);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 文本工具：弹出输入框，把文本放到点击位置（归一化坐标）。
  Future<void> _inkAddText(PdfPage page, Offset n) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加文字'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入要放在页面上的文字…',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            // Row（AlertDialog actions）里必须覆盖全局 (∞,52) 的 minimumSize。
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放置'),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty || !mounted) return;
    _inkPushUndo();
    final texts = List<PdfTextItem>.from(
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).texts);
    texts.add(PdfTextItem(
      id: 't${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}',
      x: n.dx.clamp(0.0, 0.95),
      y: n.dy.clamp(0.0, 0.95),
      text: text,
      fontSize: 10,
      width: 0.28,
      color: _inkColor,
    ));
    _pdfInkByPage[page.pageNumber] =
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage())
            .copyWith(texts: texts);
    setState(() {});
    _savePdfInk(page.pageNumber);
  }

  /// 编辑选中的文本框（选择工具选中后，工具栏「编辑文字」按钮）。
  Future<void> _inkEditSelectedText(PdfPage page) async {
    final id = _selectedTextId;
    if (id == null) return;
    final texts = (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).texts;
    final idx = texts.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final ctrl = TextEditingController(text: texts[idx].text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑文字'),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty || !mounted) return;
    _inkPushUndo();
    final next = List<PdfTextItem>.from(texts);
    next[idx] = texts[idx].copyWith(text: text); // 保留 rotation 等属性
    _pdfInkByPage[page.pageNumber] =
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage())
            .copyWith(texts: next);
    setState(() {});
    _savePdfInk(page.pageNumber);
  }

  /// 删除选中（选择工具选中笔迹/文本/图片后，工具栏「删除选中」按钮）。
  void _inkDeleteSelected(PdfPage page) {
    final ink = _pdfInkByPage[page.pageNumber];
    if (ink == null) return;
    final strokeId = _selectedStrokeId;
    final textId = _selectedTextId;
    final imageId = _selectedImageId;
    if (strokeId == null && textId == null && imageId == null) return;
    // 删除图片时同步删除磁盘文件（best-effort，失败不阻塞）。
    PdfImageItem? deletedImage;
    if (imageId != null) {
      for (final im in ink.images) {
        if (im.id == imageId) {
          deletedImage = im;
          break;
        }
      }
    }
    _inkPushUndo();
    _pdfInkByPage[page.pageNumber] = PdfInkPage(
      strokes: strokeId == null
          ? ink.strokes
          : ink.strokes.where((s) => s.id != strokeId).toList(),
      texts: textId == null
          ? ink.texts
          : ink.texts.where((t) => t.id != textId).toList(),
      images: imageId == null
          ? ink.images
          : ink.images.where((i) => i.id != imageId).toList(),
    );
    _inkClearSelection();
    setState(() {});
    _savePdfInk(page.pageNumber);
    if (deletedImage != null) _deletePdfImageFile(deletedImage);
  }

  /// 命中测试：点是否落在某条笔迹上（页面点坐标，阈值 10pt）。
  InkStroke? _inkHitStroke(PdfPage page, Offset n) {
    final c = Offset(n.dx * page.width, n.dy * page.height);
    const r = 10.0;
    for (final s in (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage())
        .strokes
        .reversed) {
      final pts = s.points;
      for (var i = 0; i < pts.length; i++) {
        final pp = Offset(pts[i].x * page.width, pts[i].y * page.height);
        if (i == 0) {
          if ((pp - c).distance <= r) return s;
        } else {
          final prev = Offset(
              pts[i - 1].x * page.width, pts[i - 1].y * page.height);
          if (_inkSegDist(c, prev, pp) <= r) return s;
        }
      }
    }
    return null;
  }

  /// 文本框排版（页面局部像素坐标）。渲染 / 命中 / 手柄定位共用，
  /// 保证画出来的位置和点得到的位置完全一致。
  _InkTextLayout _inkTextLayout(Rect pageRect, PdfPage page, PdfTextItem t) {
    final scale = pageRect.width / page.width;
    final tp = TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          color: Color(t.color),
          fontSize: t.fontSize * scale,
          height: 1.35,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 200,
    );
    tp.layout(maxWidth: t.width * pageRect.width);
    return _InkTextLayout(
      Offset(t.x * pageRect.width, t.y * pageRect.height),
      tp.width,
      tp.height,
    );
  }

  /// 命中测试：点落在文本框的哪个部位（手柄只在 restrictToId 命中的
  /// 已选中项上参与判定）。旋转感知：身体用反旋转 AABB，手柄用世界坐标
  /// 距离。
  (_InkTextPart, PdfTextItem?) _inkTextHit(PdfPage page, Rect pageRect,
      Offset n, {String? restrictToId}) {
    final p = Offset(n.dx * pageRect.width, n.dy * pageRect.height);
    final texts =
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).texts;
    for (final t in texts.reversed) {
      if (restrictToId != null && t.id != restrictToId) continue;
      final layout = _inkTextLayout(pageRect, page, t);
      final c = layout.center;
      // 选中项的手柄优先（顶部=旋转、右下=缩放）。
      if (restrictToId == t.id) {
        const hr = 14.0;
        final top =
            _inkRotatePoint(Offset(c.dx, layout.pos.dy), c, t.rotation);
        final br = _inkRotatePoint(
            Offset(layout.pos.dx + layout.w, layout.pos.dy + layout.h),
            c,
            t.rotation);
        if ((p - top).distance <= hr) return (_InkTextPart.rotate, t);
        if ((p - br).distance <= hr) return (_InkTextPart.resize, t);
      }
      // 身体：把点反旋转回未旋转的框里做 AABB 判定。
      final q = _inkRotatePoint(p, c, -t.rotation);
      if (q.dx >= layout.pos.dx &&
          q.dx <= layout.pos.dx + layout.w &&
          q.dy >= layout.pos.dy &&
          q.dy <= layout.pos.dy + layout.h) {
        return (_InkTextPart.body, t);
      }
    }
    return (_InkTextPart.none, null);
  }

  /// 绕中心旋转一个点（角度制，屏幕坐标 Y 向下 → 正角顺时针）。
  Offset _inkRotatePoint(Offset p, Offset c, double deg) {
    final rad = deg * math.pi / 180;
    final dx = p.dx - c.dx;
    final dy = p.dy - c.dy;
    final cos = math.cos(rad);
    final sin = math.sin(rad);
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }

  /// 角度吸附：靠近 0/±90/180° 时吸上去（6° 内）。
  double _inkSnapAngle(double deg) {
    var a = deg % 360;
    if (a > 180) a -= 360;
    if (a < -180) a += 360;
    for (final s in const [0.0, 90.0, 180.0, -90.0]) {
      if ((a - s).abs() < 6) return s;
    }
    return a;
  }

  /// 当前页上被选中的文本框（找不到返回 null）。
  PdfTextItem? _inkSelectedTextOnPage(int pageNumber) {
    final id = _selectedTextId;
    if (id == null) return null;
    final ink = _pdfInkByPage[pageNumber];
    if (ink == null) return null;
    for (final t in ink.texts) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 当前页上被选中的图片（找不到返回 null）。
  PdfImageItem? _inkSelectedImageOnPage(int pageNumber) {
    final id = _selectedImageId;
    if (id == null) return null;
    final ink = _pdfInkByPage[pageNumber];
    if (ink == null) return null;
    for (final i in ink.images) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// 命中测试：点是否落在图片矩形内（未旋转 AABB）。restrictToId 命中时
  /// 右下角 16px 圆点判定为 resize=true。
  (bool resize, PdfImageItem?) _inkImageHit(PdfPage page, Rect pageRect,
      Offset n, {String? restrictToId}) {
    final p = Offset(n.dx * pageRect.width, n.dy * pageRect.height);
    final images =
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).images;
    for (final item in images.reversed) {
      if (restrictToId != null && item.id != restrictToId) continue;
      final rect = Rect.fromLTWH(
        item.x * pageRect.width,
        item.y * pageRect.height,
        item.w * pageRect.width,
        item.h * pageRect.height,
      );
      if (restrictToId == item.id && (p - rect.bottomRight).distance <= 16.0) {
        return (true, item);
      }
      if (rect.contains(p)) return (false, item);
    }
    return (false, null);
  }

  /// 替换当前页某个文本框（按索引），保持列表其它元素不变。
  void _inkReplaceTextItem(PdfPage page, int idx, PdfTextItem next) {
    final ink = _pdfInkByPage[page.pageNumber] ?? const PdfInkPage();
    if (idx < 0 || idx >= ink.texts.length) return;
    final texts = List<PdfTextItem>.from(ink.texts);
    texts[idx] = next;
    _pdfInkByPage[page.pageNumber] = ink.copyWith(texts: texts);
  }

  /// 文本框拖动起点（移动/旋转/缩放统一入口；正常模式专属层与手写模式
  /// 共用）。
  void _inkTextDragStart(PdfPage page, Rect pageRect, Offset local,
      {bool allowPadding = false}) {
    final n = _normOf(pageRect, local);
    final id = _selectedTextId;
    if (id == null) return;
    var (part, item) = _inkTextHit(page, pageRect, n, restrictToId: id);
    if (item == null && allowPadding) {
      // 专属拖动层比文本框本身大一圈（留了手柄的余量）。按在这圈留白上
      // 时以前直接忽略 → 用户感觉「只有间歇性触碰才能挪动」。这里退化成
      // 整体移动。
      item = _inkSelectedTextOnPage(page.pageNumber);
      part = _InkTextPart.body;
    }
    if (item == null) return;
    _inkPushUndo(); // 拖动起点打一次快照，抬手落盘
    _inkTextDrag = switch (part) {
      _InkTextPart.rotate => _InkTextDrag.rotate,
      _InkTextPart.resize => _InkTextDrag.resize,
      _ => _InkTextDrag.move,
    };
    _inkTextDragStartN = n;
    _inkTextDragStartItem = item;
    _inkDragLast = n;
  }

  void _inkTextDragUpdate(PdfPage page, Rect pageRect, Offset local) {
    final n = _normOf(pageRect, local);
    final start = _inkTextDragStartN;
    final startItem = _inkTextDragStartItem;
    final id = _selectedTextId;
    if (_inkTextDrag == _InkTextDrag.none ||
        start == null ||
        startItem == null ||
        id == null) {
      return;
    }
    final ink = _pdfInkByPage[page.pageNumber] ?? const PdfInkPage();
    final idx = ink.texts.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    switch (_inkTextDrag) {
      case _InkTextDrag.move:
        final dx = n.dx - start.dx;
        final dy = n.dy - start.dy;
        // 按当前文本框实际占用的归一化宽高限位，拖到任意位置都不会
        // 跑出页面或被顶回边缘。
        final layout = _inkTextLayout(pageRect, page, startItem);
        final maxX = (1.0 - layout.w / pageRect.width).clamp(0.0, 1.0);
        final maxY = (1.0 - layout.h / pageRect.height).clamp(0.0, 1.0);
        _inkReplaceTextItem(
          page,
          idx,
          startItem.copyWith(
            x: (startItem.x + dx).clamp(0.0, maxX),
            y: (startItem.y + dy).clamp(0.0, maxY),
          ),
        );
      case _InkTextDrag.resize:
        // 横向 → 宽度；纵向 → 字号（换算回 PDF 点）。
        final dx = n.dx - start.dx;
        final dy = (n.dy - start.dy) * page.height * 0.75;
        _inkReplaceTextItem(
          page,
          idx,
          startItem.copyWith(
            width: (startItem.width + dx).clamp(0.08, 0.92),
            fontSize: (startItem.fontSize + dy).clamp(6.0, 40.0),
          ),
        );
      case _InkTextDrag.rotate:
        // 手柄在顶部 → 手柄指向中心的角度 + 90° = 旋转角。
        final layout = _inkTextLayout(pageRect, page, startItem);
        final c = Offset(
          startItem.x + layout.w / pageRect.width / 2,
          startItem.y + layout.h / pageRect.height / 2,
        );
        final deg = math.atan2(n.dy - c.dy, n.dx - c.dx) * 180 / math.pi + 90;
        _inkReplaceTextItem(
            page, idx, startItem.copyWith(rotation: _inkSnapAngle(deg)));
      case _InkTextDrag.none:
        break;
    }
    _inkDragLast = n;
    setState(() {});
  }

  void _inkTextDragEnd(PdfPage page) {
    _inkTextLayerOrigin = null;
    if (_inkTextDrag == _InkTextDrag.none) return;
    _inkTextDrag = _InkTextDrag.none;
    _inkTextDragStartN = null;
    _inkTextDragStartItem = null;
    _inkDragLast = null;
    _savePdfInk(page.pageNumber);
  }

  void _inkImageDragStart(PdfPage page, Rect pageRect, Offset local,
      {bool allowPadding = false}) {
    final n = _normOf(pageRect, local);
    final id = _selectedImageId;
    if (id == null) return;
    var (resize, item) = _inkImageHit(page, pageRect, n, restrictToId: id);
    if (item == null && allowPadding) {
      item = _inkSelectedImageOnPage(page.pageNumber);
      resize = false;
    }
    if (item == null) return;
    _inkPushUndo(); // 拖动起点打一次快照，抬手落盘
    _inkImageResize = resize;
    _inkImageDragStartN = n;
    _inkImageDragStartItem = item;
  }

  void _inkImageDragUpdate(PdfPage page, Rect pageRect, Offset local) {
    final n = _normOf(pageRect, local);
    final start = _inkImageDragStartN;
    final startItem = _inkImageDragStartItem;
    final id = _selectedImageId;
    if (start == null || startItem == null || id == null) return;
    final ink = _pdfInkByPage[page.pageNumber] ?? const PdfInkPage();
    final idx = ink.images.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final images = List<PdfImageItem>.from(ink.images);
    if (_inkImageResize) {
      // 缩放手柄：横向位移改 w，h 按原宽高比同步。
      final dx = n.dx - start.dx;
      final ratio = startItem.h / startItem.w;
      final w = (startItem.w + dx).clamp(0.08, 0.95);
      images[idx] =
          startItem.copyWith(w: w, h: (w * ratio).clamp(0.08, 0.95));
    } else {
      final dx = n.dx - start.dx;
      final dy = n.dy - start.dy;
      images[idx] = startItem.copyWith(
        x: (startItem.x + dx).clamp(0.0, 1.0 - startItem.w),
        y: (startItem.y + dy).clamp(0.0, 1.0 - startItem.h),
      );
    }
    _pdfInkByPage[page.pageNumber] = ink.copyWith(images: images);
    setState(() {});
  }

  void _inkImageDragEnd(PdfPage page) {
    _inkImageLayerOrigin = null;
    if (_inkImageDragStartN == null && _inkImageDragStartItem == null) return;
    _inkImageResize = false;
    _inkImageDragStartN = null;
    _inkImageDragStartItem = null;
    _savePdfInk(page.pageNumber);
  }

  void _inkPanStart(PdfPage page, Rect pageRect, DragStartDetails d) {
    final n = _normOf(pageRect, d.localPosition);
    // 已选中文本框的手柄拖动优先于任何工具（含画笔）：顶部=旋转、
    // 右下=缩放。选中项身体拖动仍走下面的「选择工具」路径。
    if (_selectedTextId != null && !_inkEraser && !_inkTextTool) {
      final (part, _) = _inkTextHit(page, pageRect, n,
          restrictToId: _selectedTextId);
      if (part == _InkTextPart.rotate || part == _InkTextPart.resize) {
        _inkTextDragStart(page, pageRect, d.localPosition);
        return;
      }
    }
    // 已选中图片的右下角缩放手柄优先（图片无旋转手柄）。
    if (_selectedImageId != null && !_inkEraser && !_inkTextTool) {
      final (resize, _) =
          _inkImageHit(page, pageRect, n, restrictToId: _selectedImageId);
      if (resize) {
        _inkImageDragStart(page, pageRect, d.localPosition);
        return;
      }
    }
    if (_inkEraser) {
      _inkPushUndo();
      if (_inkEraserMode == 2) {
        // 整条删除：命中哪条删哪条。
        final hit = _inkHitStroke(page, n);
        final ink = _pdfInkByPage[page.pageNumber];
        if (hit != null && ink != null) {
          _pdfInkByPage[page.pageNumber] = ink.copyWith(
              strokes: ink.strokes.where((s) => s.id != hit.id).toList());
          setState(() {});
          _savePdfInk(page.pageNumber);
        }
        _inkDragLast = n;
        return;
      }
      if (_inkEraserMode == 1) {
        // 白覆盖：画一条白色粗线盖住（视觉擦除，导出同样生效）。
        _inkCurrent = [WhiteboardPoint(x: n.dx, y: n.dy)];
        return;
      }
      // 分段擦除（默认）。
      _inkEraseAt(page, n);
      _inkDragLast = n;
    } else if (_inkSelect) {
      _inkDragLast = n;
      if (_selectedStrokeId == null &&
          _selectedTextId == null &&
          _selectedImageId == null) {
        // 先命中选中，再拖。
        final hs = _inkHitStroke(page, n);
        final (_, ht) = _inkTextHit(page, pageRect, n);
        final (_, hi) = _inkImageHit(page, pageRect, n);
        setState(() {
          _selectedStrokeId = hs?.id;
          _selectedTextId = ht?.id;
          _selectedImageId = hi?.id;
        });
      } else {
        // 拖动已选中对象：起点打一次撤销快照。
        _inkPushUndo();
      }
    } else if (!_inkTextTool) {
      _inkCurrent = [WhiteboardPoint(x: n.dx, y: n.dy)];
    }
    setState(() {});
  }

  void _inkPanUpdate(PdfPage page, Rect pageRect, DragUpdateDetails d) {
    if (_inkTextDrag != _InkTextDrag.none) {
      _inkTextDragUpdate(page, pageRect, d.localPosition);
      return;
    }
    if (_inkImageDragStartN != null || _inkImageDragStartItem != null) {
      _inkImageDragUpdate(page, pageRect, d.localPosition);
      return;
    }
    final n = _normOf(pageRect, d.localPosition);
    if (_inkEraser) {
      if (_inkEraserMode == 1) {
        _inkCurrent.add(WhiteboardPoint(x: n.dx, y: n.dy));
        setState(() {});
      } else if (_inkEraserMode == 0) {
        _inkEraseAt(page, n);
        setState(() {});
      }
      _inkDragLast = n;
      return;
    }
    if (_inkSelect) {
      _inkMoveSelection(page, n);
      _inkDragLast = n;
      setState(() {});
      return;
    }
    if (_inkTextTool) return;
    _inkCurrent.add(WhiteboardPoint(x: n.dx, y: n.dy));
    setState(() {});
  }

  void _inkPanEnd(PdfPage page) {
    if (_inkTextDrag != _InkTextDrag.none) {
      _inkTextDragEnd(page);
      return;
    }
    if (_inkImageDragStartN != null || _inkImageDragStartItem != null) {
      _inkImageDragEnd(page);
      return;
    }
    if (_inkEraser) {
      if (_inkEraserMode == 1 && _inkCurrent.length >= 2) {
        // 白覆盖笔迹入库（白色、宽 16pt、不透明）。
        final strokes = List<InkStroke>.from(
            (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).strokes);
        strokes.add(InkStroke(
          id: 'w${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}',
          color: 0xFFFFFFFF,
          brush: BrushType.pen,
          width: 16,
          points: List.of(_inkCurrent),
        ));
        _pdfInkByPage[page.pageNumber] =
            (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage())
                .copyWith(strokes: strokes);
      }
      _inkCurrent = [];
      _inkDragLast = null;
      _savePdfInk(page.pageNumber);
      setState(() {});
      return;
    }
    if (_inkSelect) {
      _inkDragLast = null;
      if (_selectedStrokeId != null ||
          _selectedTextId != null ||
          _selectedImageId != null) {
        // 拖动结束 → 落盘（拖动过程中的中间态不落盘，防抖到抬手）。
        _savePdfInk(page.pageNumber);
      }
      return;
    }
    if (_inkTextTool) return;
    if (_inkCurrent.length < 2) {
      _inkCurrent = [];
      return;
    }
    _inkPushUndo();
    final strokes = List<InkStroke>.from(
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage()).strokes);
    strokes.add(InkStroke(
      id: 'i${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}',
      color: _inkColor,
      brush: _inkHighlighter ? BrushType.highlighter : BrushType.pen,
      width: _inkHighlighter ? null : _inkWidth,
      points: List.of(_inkCurrent),
    ));
    _pdfInkByPage[page.pageNumber] =
        (_pdfInkByPage[page.pageNumber] ?? const PdfInkPage())
            .copyWith(strokes: strokes);
    _inkCurrent = [];
    setState(() {});
    _savePdfInk(page.pageNumber);
  }

  /// 选择工具拖动：把选中的笔迹/文本平移（增量归一化位移）。
  void _inkMoveSelection(PdfPage page, Offset n) {
    final last = _inkDragLast;
    if (last == null) return;
    final dx = n.dx - last.dx;
    final dy = n.dy - last.dy;
    final ink = _pdfInkByPage[page.pageNumber];
    if (ink == null) return;
    final strokeId = _selectedStrokeId;
    final textId = _selectedTextId;
    final imageId = _selectedImageId;
    if (strokeId != null) {
      _pdfInkByPage[page.pageNumber] = PdfInkPage(
        strokes: [
          for (final s in ink.strokes)
            if (s.id == strokeId)
              InkStroke(
                id: s.id,
                color: s.color,
                brush: s.brush,
                width: s.width,
                points: [
                  for (final p in s.points)
                    WhiteboardPoint(
                      x: (p.x + dx).clamp(0.0, 1.0),
                      y: (p.y + dy).clamp(0.0, 1.0),
                      pressure: p.pressure,
                    ),
                ],
              )
            else
              s,
        ],
        texts: ink.texts,
      );
    } else if (textId != null) {
      _pdfInkByPage[page.pageNumber] = PdfInkPage(
        strokes: ink.strokes,
        texts: [
          for (final t in ink.texts)
            if (t.id == textId)
              t.copyWith(
                x: (t.x + dx).clamp(0.0, 1.0 - t.width),
                y: (t.y + dy).clamp(0.0, 1.0),
              )
            else
              t,
        ],
      );
    } else if (imageId != null) {
      _pdfInkByPage[page.pageNumber] = PdfInkPage(
        strokes: ink.strokes,
        texts: ink.texts,
        images: [
          for (final i in ink.images)
            if (i.id == imageId)
              i.copyWith(
                x: (i.x + dx).clamp(0.0, 1.0 - i.w),
                y: (i.y + dy).clamp(0.0, 1.0 - i.h),
              )
            else
              i,
        ],
      );
    }
  }

  /// 橡皮擦除：在「页面点」坐标系里按段判交（复用白板的段距离算法）。
  void _inkEraseAt(PdfPage page, Offset n) {
    final c = Offset(n.dx * page.width, n.dy * page.height);
    const r = 6.0; // PDF points
    final ink = _pdfInkByPage[page.pageNumber] ?? const PdfInkPage();
    final next = <InkStroke>[];
    for (final s in ink.strokes) {
      next.addAll(_inkSplitStroke(s, c, page, r));
    }
    _pdfInkByPage[page.pageNumber] = ink.copyWith(strokes: next);
  }

  List<InkStroke> _inkSplitStroke(
      InkStroke s, Offset c, PdfPage page, double r) {
    final pts = s.points;
    if (pts.isEmpty) return [];
    final kept = <WhiteboardPoint>[];
    final out = <InkStroke>[];
    for (var i = 0; i < pts.length; i++) {
      final pp = Offset(pts[i].x * page.width, pts[i].y * page.height);
      bool erased;
      if (i == 0) {
        erased = (pp - c).distance <= r;
      } else {
        final prev = Offset(
            pts[i - 1].x * page.width, pts[i - 1].y * page.height);
        erased = (pp - c).distance <= r || _inkSegDist(c, prev, pp) <= r;
      }
      if (erased) {
        if (kept.length >= 2) {
          out.add(InkStroke(
            id: 'i${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}',
            color: s.color,
            brush: s.brush,
            points: kept,
          ));
        }
        kept.clear();
      } else {
        kept.add(pts[i]);
      }
    }
    if (kept.length >= 2) {
      out.add(InkStroke(
        id: 'i${DateTime.now().microsecondsSinceEpoch}${_inkCounter++}',
        color: s.color,
        brush: s.brush,
        points: kept,
      ));
    }
    return out;
  }

  double _inkSegDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// 把手写笔迹画到页面上（归一化坐标 × 页面尺寸）。
  ///
  /// 已保存的笔迹 + 正在画的那一笔（实时预览，解决「写完一笔才出来」）。
  /// 选中的笔迹画一层浅蓝描边作选中指示。
  void _pdfPaintInk(Canvas canvas, Rect pageRect, PdfPage page) {
    final strokes = _pdfInkByPage[page.pageNumber]?.strokes;
    final hasSaved = strokes != null && strokes.isNotEmpty;
    final hasCurrent = _inkCurrent.isNotEmpty &&
        !_inkEraser &&
        !_inkSelect &&
        !_inkTextTool;
    if (!hasSaved && !hasCurrent) return;
    final scaleX = pageRect.width / page.width;

    if (hasSaved) {
      for (final s in strokes) {
        if (s.points.isEmpty) continue;
        final paint = _inkPaintFor(s, scaleX);
        canvas.drawPath(_inkPath(s.points, pageRect), paint);
        if (s.id == _selectedStrokeId) {
          canvas.drawPath(
            _inkPath(s.points, pageRect),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = (s.width ?? 2.2) * scaleX + 4
              ..color = const Color(0x664DA3FF),
          );
        }
      }
    }

    // 正在画的实时预览。
    if (hasCurrent) {
      final preview = InkStroke(
        id: '',
        color: _inkColor,
        brush: _inkHighlighter ? BrushType.highlighter : BrushType.pen,
        width: _inkHighlighter ? null : _inkWidth,
        points: _inkCurrent,
      );
      canvas.drawPath(
          _inkPath(_inkCurrent, pageRect), _inkPaintFor(preview, scaleX));
    }
  }

  /// 把文本框画到页面上（带旋转）。选中项画蓝框 + 两个手柄：
  /// 顶部圆点 = 旋转，右下角圆点 = 缩放。
  void _pdfPaintTexts(Canvas canvas, Rect pageRect, PdfPage page) {
    final texts = _pdfInkByPage[page.pageNumber]?.texts ?? [];
    if (texts.isEmpty) return;
    final scale = pageRect.width / page.width;
    for (final t in texts) {
      final maxWidth = t.width * pageRect.width;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: Color(t.color),
            fontSize: t.fontSize * scale,
            height: 1.35,
          ),
        ),
        // pdfrx 也导出了自己的 TextDirection 类（无 ltr 成员），
        // 必须用 ui. 前缀指回 dart:ui 的版本。
        textDirection: ui.TextDirection.ltr,
        maxLines: 200,
      );
      tp.layout(maxWidth: maxWidth);
      final pos = Offset(
        pageRect.left + t.x * pageRect.width,
        pageRect.top + t.y * pageRect.height,
      );
      final center = Offset(pos.dx + tp.width / 2, pos.dy + tp.height / 2);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(t.rotation * math.pi / 180);
      canvas.translate(-center.dx, -center.dy);
      if (t.id == _selectedTextId) {
        // 旋转坐标系里画未旋转的 AABB = 世界坐标里的旋转选中框。
        canvas.drawRect(
          Rect.fromLTWH(pos.dx - 3, pos.dy - 3, tp.width + 6, tp.height + 6),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF4DA3FF),
        );
        final handleFill = Paint()..color = const Color(0xFF4DA3FF);
        final handleRing = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white;
        final hr = 6.0 * scale;
        // 顶部中点 = 旋转手柄。
        canvas.drawCircle(Offset(pos.dx + tp.width / 2, pos.dy), hr, handleFill);
        canvas.drawCircle(Offset(pos.dx + tp.width / 2, pos.dy), hr, handleRing);
        // 右下角 = 缩放手柄。
        canvas.drawCircle(
            Offset(pos.dx + tp.width, pos.dy + tp.height), hr, handleFill);
        canvas.drawCircle(
            Offset(pos.dx + tp.width, pos.dy + tp.height), hr, handleRing);
      }
      tp.paint(canvas, pos);
      canvas.restore();
    }
  }

  /// 把图片批注画到页面上（带旋转 + 选中蓝框 + 右下角缩放手柄）。
  /// 图片按路径异步解码后 setState 触发重绘，同一路径去重。
  void _pdfPaintImages(Canvas canvas, Rect pageRect, PdfPage page) {
    final images = _pdfInkByPage[page.pageNumber]?.images ?? [];
    if (images.isEmpty) return;
    for (final item in images) {
      final img = _pdfImageCache[item.fileName];
      if (img == null) {
        unawaited(_loadPdfImage(item.fileName));
        continue;
      }
      final rect = Rect.fromLTWH(
        pageRect.left + item.x * pageRect.width,
        pageRect.top + item.y * pageRect.height,
        item.w * pageRect.width,
        item.h * pageRect.height,
      );
      final center = rect.center;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(item.rotation * math.pi / 180);
      final dst = Rect.fromCenter(
          center: Offset.zero, width: rect.width, height: rect.height);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        dst,
        Paint(),
      );
      canvas.restore();

      // 选中：未旋转 AABB 蓝框 + 右下角缩放手柄（与命中测试一致）。
      if (item.id == _selectedImageId) {
        canvas.drawRect(
          rect.deflate(-3),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF4DA3FF),
        );
        final hr = 6.0 * (pageRect.width / page.width);
        final handle = rect.bottomRight;
        canvas.drawCircle(handle, hr, Paint()..color = const Color(0xFF4DA3FF));
        canvas.drawCircle(
          handle,
          hr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Colors.white,
        );
      }
    }
  }

  /// 异步解码图片到缓存，完成后 setState 触发重绘（已缓存/加载中去重）。
  Future<void> _loadPdfImage(String fileName) async {
    if (_pdfImageCache.containsKey(fileName) ||
        _pdfImageLoading.contains(fileName)) {
      return;
    }
    _pdfImageLoading.add(fileName);
    try {
      final path = await _pdfImagePath(fileName);
      final f = File(path);
      if (!await f.exists()) return;
      final bytes = await f.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _pdfImageCache[fileName] = frame.image);
    } catch (e) {
      debugPrint('[Ink] load image $fileName failed: $e');
    } finally {
      _pdfImageLoading.remove(fileName);
    }
  }

  Path _inkPath(List<WhiteboardPoint> pts, Rect pageRect) {
    final path = Path();
    final first = pts.first;
    path.moveTo(
      pageRect.left + first.x * pageRect.width,
      pageRect.top + first.y * pageRect.height,
    );
    for (var i = 1; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      path.quadraticBezierTo(
        pageRect.left + a.x * pageRect.width,
        pageRect.top + a.y * pageRect.height,
        pageRect.left + ((a.x + b.x) / 2) * pageRect.width,
        pageRect.top + ((a.y + b.y) / 2) * pageRect.height,
      );
    }
    final last = pts.last;
    path.lineTo(
      pageRect.left + last.x * pageRect.width,
      pageRect.top + last.y * pageRect.height,
    );
    return path;
  }

  Paint _inkPaintFor(InkStroke s, double scaleX) {
    final isHl = s.brush == BrushType.highlighter;
    final widthPoints = s.width ?? (isHl ? 12.0 : 2.2);
    final opacity = isHl ? 0.35 : 1.0;
    return Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = widthPoints * scaleX
      ..color = Color(s.color).withValues(alpha: opacity);
  }

  /// 当前页的 PdfPage（工具栏的编辑/删除选中操作要用）。
  PdfPage? get _currentPdfPage {
    final doc = _pdfDocument;
    if (doc == null || _pdfCurrentPage < 1) return null;
    if (_pdfCurrentPage > doc.pages.length) return null;
    return doc.pages[_pdfCurrentPage - 1];
  }

  Widget _buildInkToolbar(ColorScheme colors) {
    final hasSelection = _selectedStrokeId != null ||
        _selectedTextId != null ||
        _selectedImageId != null;
    final showBrushProps = !_inkEraser && !_inkSelect && !_inkTextTool;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _inkChip(colors, '画笔', Icons.edit, !_inkEraser && !_inkHighlighter && !_inkSelect && !_inkTextTool,
                () => setState(() {
                      _inkEraser = false;
                      _inkHighlighter = false;
                      _inkSelect = false;
                      _inkTextTool = false;
                      _inkClearSelection();
                    })),
            const SizedBox(width: 6),
            _inkChip(colors, '荧光笔', Icons.border_color, _inkHighlighter,
                () => setState(() {
                      _inkEraser = false;
                      _inkHighlighter = true;
                      _inkSelect = false;
                      _inkTextTool = false;
                      _inkClearSelection();
                    })),
            const SizedBox(width: 6),
            _inkChip(colors, '橡皮', Icons.cleaning_services_outlined, _inkEraser,
                () => setState(() {
                      _inkEraser = true;
                      _inkHighlighter = false;
                      _inkSelect = false;
                      _inkTextTool = false;
                      _inkClearSelection();
                    })),
            // 橡皮三种模式（xournalpp 语义）：分段擦除 / 白覆盖 / 整条删除。
            if (_inkEraser)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: DropdownButton<int>(
                  value: _inkEraserMode,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A)),
                  items: const [
                    DropdownMenuItem(
                        value: 0, child: Text('分段擦除', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(
                        value: 1, child: Text('白覆盖', style: TextStyle(fontSize: 12))),
                    DropdownMenuItem(
                        value: 2, child: Text('整条删除', style: TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) => setState(() => _inkEraserMode = v ?? 0),
                ),
              ),
            const SizedBox(width: 6),
            _inkChip(colors, '选择', Icons.near_me_outlined, _inkSelect, () => setState(() {
                  _inkEraser = false;
                  _inkHighlighter = false;
                  _inkSelect = true;
                  _inkTextTool = false;
                })),
            const SizedBox(width: 6),
            _inkChip(colors, '文本', Icons.text_fields, _inkTextTool, () => setState(() {
                  _inkEraser = false;
                  _inkHighlighter = false;
                  _inkSelect = false;
                  _inkTextTool = true;
                  _inkClearSelection();
                })),
            const SizedBox(width: 6),
            // 扫描版 PDF：OCR 识别当前页（图片版没有文字层，无法选中/检索）。
            _inkChip(colors, 'OCR 识别', Icons.document_scanner_outlined,
                _pdfOcrRunning, () => _pdfOcrCurrentPage()),
            if (showBrushProps) ...[
              const SizedBox(width: 10),
              const VerticalDivider(width: 1),
              const SizedBox(width: 6),
              const Text('粗细', style: TextStyle(fontSize: 12)),
              SizedBox(
                width: 120,
                child: Slider(
                  value: _inkWidth,
                  min: 1,
                  max: 12,
                  onChanged: (v) => setState(() => _inkWidth = v),
                ),
              ),
              const SizedBox(width: 6),
              const VerticalDivider(width: 1),
              const SizedBox(width: 6),
              for (final c in const [
                0xFFE53935,
                0xFF1A1A1A,
                0xFF1E88E5,
                0xFF43A047,
                0xFFFB8C00,
              ])
                GestureDetector(
                  onTap: () => setState(() => _inkColor = c),
                  child: Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _inkColor == c
                            ? colors.primary
                            : colors.outline.withValues(alpha: 0.4),
                        width: _inkColor == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
            // 选中态操作：编辑文字（文本）/ 字号 / 角度 / 删除选中（笔迹或文本）。
            if (hasSelection) ...[
              const SizedBox(width: 10),
              const VerticalDivider(width: 1),
              const SizedBox(width: 6),
              if (_selectedTextId != null && _inkSelectedTextOnPage(_pdfCurrentPage) != null) ...[
                const Text('字号', style: TextStyle(fontSize: 12)),
                SizedBox(
                  width: 90,
                  child: Slider(
                    value: _inkSelectedTextOnPage(_pdfCurrentPage)!.fontSize
                        .clamp(6.0, 30.0),
                    min: 6,
                    max: 30,
                    onChanged: (v) =>
                        _inkUpdateSelectedText((t) => t.copyWith(fontSize: v)),
                    onChangeEnd: (_) => _savePdfInk(_pdfCurrentPage),
                  ),
                ),
                const SizedBox(width: 6),
                const Text('角度', style: TextStyle(fontSize: 12)),
                SizedBox(
                  width: 90,
                  child: Slider(
                    value: _inkSelectedTextOnPage(_pdfCurrentPage)!.rotation
                        .clamp(-180.0, 180.0),
                    min: -180,
                    max: 180,
                    onChanged: (v) =>
                        _inkUpdateSelectedText((t) => t.copyWith(rotation: v)),
                    onChangeEnd: (_) => _savePdfInk(_pdfCurrentPage),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (_selectedTextId != null)
                IconButton(
                  icon: const Icon(Icons.edit_note, size: 20),
                  tooltip: '编辑文字',
                  onPressed: () {
                    final page = _currentPdfPage;
                    if (page != null) _inkEditSelectedText(page);
                  },
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除选中',
                onPressed: () {
                  final page = _currentPdfPage;
                  if (page != null) _inkDeleteSelected(page);
                },
              ),
            ],
            const SizedBox(width: 10),
            const VerticalDivider(width: 1),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.undo, size: 20),
              tooltip: '撤销',
              onPressed: _inkUndo.isEmpty ? null : _inkUndoAction,
            ),
            IconButton(
              icon: const Icon(Icons.redo, size: 20),
              tooltip: '重做',
              onPressed: _inkRedo.isEmpty ? null : _inkRedoAction,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              tooltip: '清空本页手写',
              onPressed: _inkClearPage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _inkChip(ColorScheme colors, String label, IconData icon,
      bool selected, VoidCallback onTap) {
    return ChoiceChip(
      avatar: Icon(icon,
          size: 14,
          color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      selectedColor: colors.primaryContainer,
    );
  }

  // ── Annotations ───────────────────────────────────────────────────────

  /// 批注面板：**每次打开都从数据库现读**，不信任内存里的 ReaderState。
  ///
  /// 用户反馈「新建的笔记在笔记中心能看到，点开书本右上角笔记却没有记录」——
  /// 笔记中心读的是 DB 全量，而这里以前只读内存快照，任何一次加载竞态 /
  /// 旧状态残留都会让两者对不上。现读 DB 保证永远与笔记中心一致。
  Future<void> _showAnnotationSheet(String ext) async {
    final colors = Theme.of(context).colorScheme;
    final book = ref.read(readerProvider).book ?? widget.book;

    List<Annotation> annotations = const [];
    try {
      annotations = await ref.read(storageServiceProvider).getAnnotations(book.id);
    } catch (e) {
      debugPrint('[Anno] load annotations for sheet failed: $e');
    }
    if (!mounted) return;

    // 同时刷新内存快照，正文高亮也跟着更新。
    ref.read(readerProvider.notifier).setAnnotations(annotations);

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('批注与笔记',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (annotations.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('暂无批注',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.onSurfaceVariant)),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: annotations
                      .map((a) => ListTile(
                            leading: Icon(
                              a.type == AnnotationType.highlight
                                  ? Icons.format_quote
                                  : Icons.note,
                              size: 22,
                              color: a.color != null
                                  ? Color(int.parse(
                                      a.color!.replaceFirst('#', '0xFF')))
                                  : colors.primary,
                            ),
                            // 手写批注（source='ink'）没有原文，用摘要当标题。
                            title: Text(
                              a.quotedText.isNotEmpty ? a.quotedText : a.note,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onSurface,
                              ),
                            ),
                            subtitle: a.note.isNotEmpty && a.quotedText.isNotEmpty
                                ? Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      a.note,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  )
                                : Text(
                                    a.location,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                            // Tap the entry to jump to the annotation's position.
                            onTap: () {
                              Navigator.pop(ctx);
                              _jumpToAnnotation(a);
                            },
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () {
                                if (a.id != null) {
                                  ref
                                      .read(readerProvider.notifier)
                                      .deleteAnnotation(a.id!);
                                }
                                Navigator.pop(ctx);
                              },
                            ),
                          ))
                      .toList(),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('添加笔记'),
              onPressed: () {
                Navigator.pop(ctx);
                _addNote(ext);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Handles annotation events from [EpubReaderView]'s custom context menu.
  ///
  /// The view already calculated the [TextAnchor] with offsets + fingerprint;
  /// we just persist it. Highlights arrive with [note] empty, notes arrive
  /// with the user's commentary (the dialog was shown by EpubReaderView).
  /// Jump to an annotation's position in the open book.
  ///
  /// For EPUB books this scrolls to the correct section and flashes the
  /// highlight span. For PDF books it navigates to the page.
  void _jumpToAnnotation(Annotation a) {
    final ext = (widget.book.extension ?? '').toLowerCase();
    if (ext == 'epub' && a.anchor.kind == AnchorKind.epub) {
      _epubViewKey.currentState
          ?.jumpToAnnotation(a.anchor, a.id ?? 0);
    } else if (ext == 'pdf' && a.anchor.kind == AnchorKind.pdf) {
      final page = a.anchor.pageIndex;
      if (page != null) {
        _goToPdfPageWithFlash(page);
      }
    }
  }

  /// 翻到指定页并启动定位闪烁（笔记中心 / 批注面板跳转用）。
  ///
  /// 修复「点手写批注只闪第一页、不跳目标页」：
  /// · goToPage 在 viewer 刚 ready 时可能被引擎忽略 → 每 150ms 重试，
  ///   直到 onPageChanged 确认到达目标页；
  /// · 闪烁在**真正到达目标页后**才启动（旧实现立即启动，跳转失败时
  ///   4 秒在看不见的页面上白白烧完，用户滑过去已经不闪了）；
  /// · 闪烁时长 4s → 6s（手动翻到目标页也来得及看到）。
  void _goToPdfPageWithFlash(int page) {
    _pdfJumpTarget = page;
    _pdfJumpTries = 0;
    _pdfController?.goToPage(pageNumber: page);
    setState(() => _pdfCurrentPage = page);
    _tryPdfJump();
  }

  int? _pdfJumpTarget;
  int _pdfJumpTries = 0;

  void _tryPdfJump() {
    final target = _pdfJumpTarget;
    if (target == null || !mounted) return;
    if (_pdfCurrentPage == target) {
      _pdfJumpTarget = null;
      _startPdfFlash(target);
      return;
    }
    _pdfJumpTries++;
    if (_pdfJumpTries > 12) {
      // 引擎始终不确认：放弃重试，但仍启动闪烁——用户手动翻到该页
      // 时能看到定位框（6 秒窗口）。
      _pdfJumpTarget = null;
      _startPdfFlash(target);
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _pdfController?.goToPage(pageNumber: target);
      _tryPdfJump();
    });
  }

  /// 定位闪烁：周期重绘 6 秒，颜色在金黄/红之间脉动。
  void _startPdfFlash(int page) {
    _pdfFlashTimer?.cancel();
    setState(() {
      _pdfFlashPage = page;
      _pdfFlashStart = DateTime.now();
    });
    _pdfFlashTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) {
        _pdfFlashTimer?.cancel();
        return;
      }
      if (_pdfFlashStart == null ||
          DateTime.now().difference(_pdfFlashStart!).inMilliseconds > 6000) {
        _pdfFlashTimer?.cancel();
        setState(() {
          _pdfFlashPage = null;
          _pdfFlashStart = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  void _onEpubAnnotate({
    required TextAnchor anchor,
    required String quotedText,
    required AnnotationType type,
    String? color,
    String note = '',
  }) {
    ref.read(readerProvider.notifier).addAnnotation(
          anchor: anchor,
          quotedText: quotedText,
          note: note,
          type: type,
          color: color,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(type == AnnotationType.highlight ? '已高亮' : '笔记已保存'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// EPUB 选中文字点「从这里朗读」→ 从选区起始句开始读。
  void _onEpubReadFrom(int sectionIndex, int startOffset) {
    if (!mounted) return;
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _ttsText = '';
    });
    _ttsPlayEpubFrom(sectionIndex, charOffset: startOffset);
  }

  void _addNote(String ext) {
    // Build the best anchor we can with current position data.
    // S4/S5 will replace this with proper selection-based anchors.
    final anchor = ext == 'pdf'
        ? TextAnchor(kind: AnchorKind.pdf, pageIndex: _pdfCurrentPage)
        : TextAnchor(kind: AnchorKind.epub, sectionIndex: _epubSection);
    final locationLabel = anchor.display;
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加笔记'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: '输入笔记内容...',
            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
            helperText: locationLabel,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                ref.read(readerProvider.notifier).addAnnotation(
                      anchor: anchor,
                      quotedText: ctrl.text.trim(),
                      note: ctrl.text.trim(),
                      type: AnnotationType.note,
                    );
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ── Bookmarks ────────────────────────────────────────────────────────

  /// Build the best structured anchor for the current reading position.
  ///
  /// Only EPUB (section) and PDF (page) have a navigable position; TXT / MD /
  /// DOCX track no section/page index, so they get a plain anchor that only
  /// records "当前位置" without a jump target.
  TextAnchor _currentAnchor(String ext) {
    switch (ext) {
      case 'epub':
        return TextAnchor(kind: AnchorKind.epub, sectionIndex: _epubSection);
      case 'pdf':
        return TextAnchor(kind: AnchorKind.pdf, pageIndex: _pdfCurrentPage);
      default:
        return const TextAnchor(kind: AnchorKind.plain);
    }
  }

  /// Add a bookmark at the current position.
  Future<void> _addBookmark(String ext) async {
    final reader = ref.read(readerProvider);
    final book = reader.book;
    if (book == null) return;

    final anchor = _currentAnchor(ext);
    if (anchor.kind == AnchorKind.plain) {
      _toast('当前格式暂不支持书签定位（仅 EPUB / PDF）');
      return;
    }

    await ref.read(storageServiceProvider).insertBookmark(Bookmark(
          bookId: book.id,
          kind: anchor.kind,
          sectionIndex: anchor.sectionIndex,
          pageIndex: anchor.pageIndex,
        ));
    if (mounted) {
      _toast('已添加书签 · ${anchor.display}');
    }
  }

  /// Bottom sheet: list bookmarks for this book, tap to jump, delete to remove.
  ///
  /// Also offers a "把当前页加入书签" action so the toolbar's single bookmark
  /// icon is enough — users don't need to hunt for a second button.
  Future<void> _showBookmarks(String ext) async {
    final reader = ref.read(readerProvider);
    final book = reader.book;
    if (book == null) return;

    final storage = ref.read(storageServiceProvider);
    final bookmarks = await storage.getBookmarks(book.id);
    if (!mounted) return;

    final colors = Theme.of(context).colorScheme;

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text('书签',
                      style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Text('${bookmarks.length} 个',
                      style: TextStyle(
                          fontSize: 12, color: colors.onSurfaceVariant)),
                  const Spacer(),
                  FilledButton.icon(
                    icon: const Icon(Icons.bookmark_add, size: 18),
                    label: const Text('加书签'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _addBookmark(ext);
                    },
                  ),
                ],
              ),
            ),
            if (bookmarks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  '暂无书签，点右上角「加书签」记录当前位置',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: bookmarks.length,
                  itemBuilder: (ctx, i) {
                    final b = bookmarks[i];
                    return ListTile(
                      leading: const Icon(Icons.bookmark, size: 22),
                      title: Text(
                        b.label?.isNotEmpty == true
                            ? b.label!
                            : b.display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        DateFormat('yyyy-MM-dd HH:mm').format(b.createdAt),
                        style: TextStyle(
                            fontSize: 11, color: colors.onSurfaceVariant),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _deleteBookmark(b);
                        },
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _jumpToBookmark(b);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteBookmark(Bookmark b) async {
    if (b.id == null) return;
    await ref.read(storageServiceProvider).deleteBookmark(b.id!);
    if (mounted) _toast('书签已删除');
  }

  /// Jump to a bookmark's position (EPUB section / PDF page).
  void _jumpToBookmark(Bookmark b) {
    switch (b.kind) {
      case AnchorKind.epub:
        if (b.sectionIndex != null) {
          _epubViewKey.currentState?.jumpTo(b.sectionIndex!);
        }
      case AnchorKind.pdf:
        if (b.pageIndex != null) {
          _pdfController?.goToPage(pageNumber: b.pageIndex!);
          setState(() => _pdfCurrentPage = b.pageIndex!);
        }
      case AnchorKind.plain:
        break;
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ── 听书朗读（TTS） ────────────────────────────────────────────────

  /// 按格式启动朗读。EPUB 按章节、PDF 按页、TXT/MD/DOCX 按段落批次，
  /// 读完当前单位自动续下一个，直到用户停止或读完全书。
  void _startTts(String ext) {
    final reader = ref.read(readerProvider);
    if (reader.localPath == null) {
      _toast('文件还没加载好，稍等再试');
      return;
    }
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _ttsText = '';
    });
    switch (ext) {
      case 'epub':
        _ttsPlayEpubFrom(_epubSection);
      case 'pdf':
        _ttsPlayPdfFrom(_pdfCurrentPage);
      default:
        if (ext == 'md' || ext == 'markdown') {
          final paragraphs = (_mdContent ?? '')
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .map(TtsService.stripMarkdown)
              .toList();
          _ttsPlayPlain(paragraphs, 0);
        } else {
          final paragraphs =
              ext == 'docx' ? (_docxParagraphs ?? const <String>[]) : (_txtParagraphs ?? const <String>[]);
          if (paragraphs.isEmpty) {
            _toast('内容还没解析完，稍等再试');
            return;
          }
          // 从当前阅读进度估算起始段落。
          final percent = reader.progressPercent / 100.0;
          final from = (percent * paragraphs.length).floor().clamp(0, paragraphs.length - 1);
          _ttsPlayPlain(paragraphs, from);
        }
    }
  }

  /// 引擎级错误（无引擎/初始化失败）：弹提示；彻底不可用时收起朗读条。
  void _onTtsError(String msg) {
    if (!mounted) return;
    _toast(msg);
    if (msg.contains('没有可用的语音引擎') || msg.contains('初始化语音引擎失败')) {
      _stopTts();
    }
  }

  /// EPUB：从 sectionIdx 章节、charOffset 处的句子开始读（charOffset 0 = 章节开头）。
  /// 选中文字点「从这里朗读」时 charOffset 是选区的起始偏移。
  Future<void> _ttsPlayEpubFrom(int sectionIdx, {int charOffset = 0}) async {
    if (!_ttsActive || !mounted) return;
    final book = await _epubFuture;
    if (!mounted || !_ttsActive) return;
    if (book == null || sectionIdx >= book.sections.length) {
      _stopTts();
      return;
    }
    setState(() => _epubSection = sectionIdx);
    _epubViewKey.currentState?.jumpTo(sectionIdx);

    final plainText = book.sections[sectionIdx].plain.text;
    final sentences = TtsService.splitSentences(plainText);
    if (sentences.isEmpty) {
      await _ttsPlayEpubFrom(sectionIdx + 1);
      return;
    }
    // charOffset → 句子下标：数 charOffset 之前的句子终止符数量。
    var start = 0;
    if (charOffset > 0) {
      final before = plainText.substring(0, charOffset.clamp(0, plainText.length));
      start = RegExp(r'[。！？；!?;\n]').allMatches(before).length;
      start = start.clamp(0, sentences.length - 1);
    }
    await TtsService.instance.play(
      sentences,
      startIndex: start,
      onProgress: (i, s) {
        if (mounted) {
          setState(() {
            _ttsText = s;
          });
        }
      },
      onDone: () {
        if (_ttsActive) _ttsPlayEpubFrom(sectionIdx + 1);
      },
      onError: _onTtsError,
    );
  }

  /// PDF：读 page 页提取出的文本，读完自动翻下一页。
  /// [selectedText] 非空（选中文字点「从这里朗读」）时，从包含该文字的句子开始。
  Future<void> _ttsPlayPdfFrom(int page, {String? selectedText}) async {
    if (!_ttsActive || !mounted) return;
    if (page > _pdfTotalPages) {
      _stopTts();
      return;
    }
    _pdfController?.goToPage(pageNumber: page);
    setState(() => _pdfCurrentPage = page);

    final pageText = await _loadPageTextWithWait(page);
    if (!mounted || !_ttsActive) return;
    final text = (pageText?.fullText ?? '').trim();
    if (text.isEmpty) {
      await _ttsPlayPdfFrom(page + 1);
      return;
    }
    final sentences = TtsService.splitSentences(text);

    var start = 0;
    final q = selectedText?.trim() ?? '';
    if (q.length >= 2) {
      var idx = text.indexOf(q);
      if (idx < 0) {
        // 空白差异兜底：压掉所有空白再找前 8 个字符。
        final qn = q.replaceAll(RegExp(r'\s+'), '');
        final tn = text.replaceAll(RegExp(r'\s+'), '');
        final head = qn.length >= 8 ? qn.substring(0, 8) : qn;
        if (head.isNotEmpty) {
          final nIdx = tn.indexOf(head);
          if (nIdx >= 0) idx = nIdx;
        }
      }
      if (idx > 0) {
        final before = text.substring(0, idx.clamp(0, text.length));
        start = RegExp(r'[。！？；!?;\n]').allMatches(before).length;
        start = start.clamp(0, sentences.length - 1);
      }
    }

    await TtsService.instance.play(
      sentences,
      startIndex: start,
      onProgress: (i, s) {
        if (mounted) {
          setState(() {
            _ttsText = s;
          });
        }
      },
      onDone: () {
        if (_ttsActive) _ttsPlayPdfFrom(page + 1);
      },
      onError: _onTtsError,
    );
  }

  /// TXT/MD/DOCX：按段落批次读（每批 300 句，防大文件内存爆掉）。
  Future<void> _ttsPlayPlain(List<String> paragraphs, int from) async {
    if (!_ttsActive || !mounted) return;
    const batch = 300;
    final sentences = <String>[];
    var next = from;
    while (next < paragraphs.length && sentences.length < batch) {
      sentences.addAll(TtsService.splitSentences(paragraphs[next]));
      next++;
    }
    if (sentences.isEmpty) {
      if (next < paragraphs.length) {
        await _ttsPlayPlain(paragraphs, next);
        return;
      }
      _stopTts();
      return;
    }
    await TtsService.instance.play(
      sentences,
      onProgress: (i, s) {
        if (mounted) {
          setState(() {
            _ttsText = s;
          });
        }
      },
      onDone: () {
        if (_ttsActive) _ttsPlayPlain(paragraphs, next);
      },
      onError: _onTtsError,
    );
  }

  /// TXT/MD/DOCX：点击某段 → 从这里开始（或重新开始）朗读。
  void _startTtsFromParagraph(String ext, int paragraphIndex) {
    final reader = ref.read(readerProvider);
    if (reader.localPath == null) return;
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _ttsText = '';
    });
    if (ext == 'md' || ext == 'markdown') {
      _startTtsFromMdLine(paragraphIndex);
      return;
    }
    final paragraphs =
        ext == 'docx' ? (_docxParagraphs ?? const <String>[]) : (_txtParagraphs ?? const <String>[]);
    if (paragraphs.isEmpty) {
      _toast('内容还没解析完，稍等再试');
      return;
    }
    _ttsPlayPlain(paragraphs, paragraphIndex.clamp(0, paragraphs.length - 1));
  }

  /// MD：点击块 → 按块的起始行号，从该行所在的段落开始朗读（去掉 md 标记）。
  void _startTtsFromMdLine(int startLine) {
    final lines = (_mdContent ?? '')
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      _toast('内容还没解析完，稍等再试');
      return;
    }
    final paragraphs = lines.map(TtsService.stripMarkdown).toList();
    _ttsPlayPlain(paragraphs, startLine.clamp(0, paragraphs.length - 1));
  }

  /// PDF 选中文字点「从这里朗读」→ 从选中句开始读。
  Future<void> _processPdfRead(PdfTextSelectionDelegate sel) async {
    final text = await sel.getSelectedText();
    if (text.trim().isEmpty) return;
    await sel.clearTextSelection();
    if (!mounted) return;
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _ttsText = '';
    });
    _ttsPlayPdfFrom(_pdfCurrentPage, selectedText: text.trim());
  }

  /// 等待 PDF 页渲染完成并提取文本（翻页后页面可能还没加载完）。
  Future<PdfPageText?> _loadPageTextWithWait(int page) async {
    final doc = _pdfDocument;
    if (doc == null) return null;
    final p = doc.pages[page - 1];
    for (var i = 0; i < 50 && !p.isLoaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!p.isLoaded) return null;
    try {
      return await p.loadStructuredText();
    } catch (e) {
      debugPrint('[TTS] page text load failed: $e');
      return null;
    }
  }

  void _ttsPauseResume() {
    if (_ttsPaused) {
      setState(() => _ttsPaused = false);
      TtsService.instance.resume();
    } else {
      setState(() => _ttsPaused = true);
      TtsService.instance.pause();
    }
  }

  void _stopTts() {
    TtsService.instance.stop();
    if (mounted) {
      setState(() {
        _ttsActive = false;
        _ttsPaused = false;
        _ttsText = '';
      });
    }
  }

  Future<void> _ttsSetRate(double rate) async {
    setState(() => _ttsRate = rate);
    await TtsService.instance.setRate(rate);
  }

  Widget _buildTtsBar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(_ttsPaused ? Icons.play_arrow : Icons.pause),
                tooltip: _ttsPaused ? '继续朗读' : '暂停',
                onPressed: _ttsPauseResume,
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                tooltip: '停止朗读',
                onPressed: _stopTts,
              ),
              PopupMenuButton<double>(
                icon: const Icon(Icons.speed),
                tooltip: '语速',
                initialValue: _ttsRate,
                onSelected: _ttsSetRate,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 0.4, child: Text('慢速 0.8x')),
                  PopupMenuItem(value: 0.5, child: Text('正常 1.0x')),
                  PopupMenuItem(value: 0.65, child: Text('较快 1.3x')),
                  PopupMenuItem(value: 0.8, child: Text('快速 1.6x')),
                ],
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _ttsText.isEmpty ? '准备朗读…' : _ttsText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reading-settings bottom-sheet helpers ─────────────────────────────────

/// A labelled slider with an icon, value display, and range.
///
/// [onChanged] fires continuously while the user drags (local state update);
/// [onChangeEnd] fires once when they lift their finger (persist to provider).
class _SettingSlider extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _SettingSlider({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: colors.onSurfaceVariant),
        const SizedBox(width: 12),
        Text(label,
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(displayValue,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
      ],
    );
  }
}

/// A tappable card for the three reading themes (day / night / sepia).
class _ThemeChip extends StatelessWidget {
  final String label;
  final String emoji;
  final bool selected;
  final Color backgroundColor;
  final Color textColor;
  final VoidCallback onTap;

  const _ThemeChip({
    required this.label,
    required this.emoji,
    required this.selected,
    required this.backgroundColor,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? colors.primary : Colors.transparent,
              width: selected ? 2 : 0,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: colors.primary.withValues(alpha: 0.25),
                      blurRadius: 6,
                    )
                  ]
                : null,
          ),
          child: Column(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(fontSize: 11, color: textColor)),
            ],
          ),
        ),
      ),
    );
  }
}

/// readest 主题圆点（Aa 色块）。
class _ReadestThemeDot extends StatelessWidget {
  final String id;
  final bool selected;
  final VoidCallback onTap;

  const _ReadestThemeDot({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final entry = readestThemes[id]!;
    final c = entry.light;
    return Tooltip(
      message: id,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Color(c.bg),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Color(c.primary)
                  : Colors.grey.withValues(alpha: 0.4),
              width: selected ? 3 : 1,
            ),
          ),
          child: Center(
            child: Text(
              'Aa',
              style: TextStyle(
                  fontSize: 12,
                  color: Color(c.fg),
                  fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled switch with optional subtitle for the settings bottom sheet.
class _SettingToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SwitchListTile(
      dense: true,
      secondary: Icon(icon, size: 20, color: colors.onSurfaceVariant),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant))
          : null,
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 文本框排版结果（页面局部像素坐标）。
class _InkTextLayout {
  final Offset pos; // 左上角
  final double w;
  final double h;

  const _InkTextLayout(this.pos, this.w, this.h);

  Offset get center => Offset(pos.dx + w / 2, pos.dy + h / 2);
}
