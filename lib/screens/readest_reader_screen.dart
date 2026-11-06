import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/readest_style.dart';
import '../services/screen_capture.dart';
import '../services/shot_library.dart';
import '../services/translate_service.dart';
import '../services/tts_service.dart';
import '../services/web_search.dart';
import '../widgets/ai_dialog_widget.dart';
import '../widgets/foliate_reader_view.dart';
import 'reader_screen.dart';
/// readest 同款 EPUB 阅读器（foliate-js 引擎 + readest 外观复刻）。
///
/// 布局：
///   · 顶部：返回、书名、目录、搜索、设置
///   · 中间：FoliateReaderView（foliate-js 分页渲染）
///   · 底部：上一页 / 页码·章节 / 下一页
/// 设置面板（bottom sheet）：字号、行距、页边距、字体、11 套主题 + 暗色。
class ReadestReaderScreen extends ConsumerStatefulWidget {
  final Book book;

  /// 打开后直接跳到的位置（CFI）；null = 用上次阅读进度。
  /// 笔记中心按书跳转时传入对应笔记的 CFI。
  final String? initialCfi;

  const ReadestReaderScreen({
    super.key,
    required this.book,
    this.initialCfi,
  });

  @override
  ConsumerState<ReadestReaderScreen> createState() =>
      _ReadestReaderScreenState();
}

class _ReadestReaderScreenState extends ConsumerState<ReadestReaderScreen> {
  final _viewKey = GlobalKey<FoliateReaderViewState>();

  /// 阅读样式：从全局持久化配置恢复（readest 全局设置同款行为）。
  late final ReadestStyleConfig _style =
      ReadestStyleConfig.fromJson(AppConfig.instance.readestStyleJson);

  /// 翻页动画（persisted，readest animated 属性）。
  late bool _animated = AppConfig.instance.readestAnimated;

  bool _bookReady = false;

  /// 是否 PDF（readest 引擎内 PDF 用 pdf.js 渲染）。
  bool _isPdf = false;

  // 进度显示。
  int _page = 0;
  int _pages = 0;
  String _tocLabel = '';

  // 侧栏数据（目录/搜索结果）。
  List<({String label, String href, int depth})> _toc = [];
  List<({String cfi, String excerpt, String label, int secIndex})>
      _searchResults = [];
  bool _searching = false;

  // 笔记（高亮/划线/笔记正文）。
  List<ReadestNote> _notes = [];

  // AI 标注（用户确认过的生成内容，ai_notes 表）。
  List<AiNote> _aiNotes = [];

  // 选区截图暂存：cfi → PNG 路径。用户先截图再批注/AI 时，
  // 截图随记录一起落库（方案 §2.8 四要素捆绑）。
  final Map<String, String> _pendingShots = {};

  // 朗读状态。
  bool _ttsActive = false;
  bool _ttsPaused = false;
  String _ttsText = '';
  int _lastSectionIndex = -1;
  double _ttsRate = 0.5;

  // 书签（当前页 CFI）。
  String _lastCfi = '';
  bool _bookmarked = false;

  // PDF 打开兜底：readest 引擎（pdf.js）在个别设备的 WebView 上打不开
  // 时，超时/报错自动切换回 pdfrx 内置引擎，保证书架 PDF 一定能打开。
  Timer? _openWatchdog;
  bool _fallbackScheduled = false;

  // 进度上报节流（bookshelf progress 列 = 主页「最近阅读」数据源）。
  int _lastSavedPercent = -1;

  Book get book => widget.book;

  @override
  void initState() {
    super.initState();
    // 打开看门狗：15 秒还没 book-ready 且是 PDF → 回退内置引擎。
    //（正常打开 PDF 时本屏幕已不再被路由到——PDF 默认直接进 pdfrx；
    //  这里只兜底「笔记中心按 CFI 跳进 readest 引擎 PDF」的历史路径，
    //  大 PDF + 慢设备给足 pdf.js 预热时间，避免误报引擎失败。）
    _openWatchdog = Timer(const Duration(seconds: 15), () {
      if (!mounted || _bookReady) return;
      if ((book.extension ?? '').toLowerCase() == 'pdf') {
        _fallbackToLegacyPdf('超时未加载');
      }
    });
  }

  @override
  void dispose() {
    _openWatchdog?.cancel();
    _openWatchdog = null;
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = _style.colors;

    return Scaffold(
      backgroundColor: Color(c.bg),
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: Text(
          book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          // PDF：切换到 pdfrx 老引擎做手写批注（readest 引擎无手绘能力，
          // 保留原引擎作为批注扩展路径）。
          if (_isPdf)
            IconButton(
              icon: const Icon(Icons.draw_outlined),
              tooltip: '手写批注模式',
              onPressed: () {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) =>
                        ReaderScreen(book: book, forceLegacyPdf: true),
                  ),
                );
              },
            ),
          IconButton(
            icon: Icon(_bookmarked
                ? Icons.bookmark
                : Icons.bookmark_border),
            tooltip: _bookmarked ? '移除书签' : '添加书签',
            onPressed: _bookReady ? _toggleBookmark : null,
          ),
          IconButton(
            icon: Icon(_ttsActive
                ? Icons.stop_circle_outlined
                : Icons.record_voice_over_outlined),
            tooltip: _ttsActive ? '停止朗读' : '听书朗读',
            onPressed: _bookReady
                ? (_ttsActive ? _stopTts : _showTtsStartSheet)
                : null,
          ),
          // 整页截图（问题14）：引擎 takeScreenshot → App 截图库。
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: '截图',
            onPressed: _bookReady ? _takeFullScreenshot : null,
          ),
          IconButton(
            icon: const Icon(Icons.toc_outlined),
            tooltip: '目录',
            onPressed: _bookReady ? _showTocSheet : null,
          ),
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: '笔记',
            onPressed: _bookReady ? _showNotesSheet : null,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _bookReady ? _showSearchSheet : null,
          ),
          IconButton(
            icon: const Icon(Icons.text_fields),
            tooltip: '阅读设置',
            onPressed: _showSettingsSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FoliateReaderView(
              key: _viewKey,
              bookPath: book.localPath!,
              initialCfi:
                  widget.initialCfi ?? AppConfig.instance.readestCfi(book.id),
              styleCss: _style.buildCss(),
              animated: _animated,
              gapPercent: _style.gapPercent,
              onEvent: _onEngineEvent,
            ),
          ),
          if (_ttsActive) _buildTtsBar(colors),
        ],
      ),
      bottomNavigationBar: _buildFooter(colors),
    );
  }

  // ── 引擎事件 ───────────────────────────────────────────────────────

  void _onEngineEvent(FoliateEvent e) {
    switch (e.name) {
      case 'book-ready':
        _openWatchdog?.cancel();
        _openWatchdog = null;
        _isPdf = e.fixedLayout || e.format == 'pdf' ||
            (book.extension ?? '').toLowerCase() == 'pdf';
        setState(() => _bookReady = true);
        _viewKey.currentState?.applyInitialSettings();
        _applyLayout();
        _loadToc();
        _restoreNotes();
      case 'relocate':
        if (e.cfi.isNotEmpty) {
          _lastCfi = e.cfi;
          AppConfig.instance.setReadestCfi(book.id, e.cfi);
        }
        setState(() {
          if (_isPdf && e.page != null && e.pages != null) {
            // PDF：真实页码（foliate-fxl page/pages，0-based）。
            _page = e.page!;
            _pages = e.pages!;
          } else {
            // EPUB：readest 页码语义 = location.current/total（0-based）。
            _page = e.locationCurrent;
            _pages = e.locationTotal;
          }
          if (e.tocItemLabel.isNotEmpty) _tocLabel = e.tocItemLabel;
        });
        _refreshBookmarkState();
        // 进度写进书架（节流到整数百分比变化）：主页「最近阅读」与
        // 书架排序都依赖 progress/last_read 列。
        if (_pages > 0) {
          final percent = ((_page + 1) * 100 ~/ _pages).clamp(0, 100);
          if ((percent - _lastSavedPercent).abs() >= 1) {
            _lastSavedPercent = percent;
            ref.read(bookshelfProvider.notifier).updateProgress(book.id, percent);
          }
        }
      case 'annotation-created':
        _onAnnotationCreated(e.payload);
      case 'annotation-tapped':
        _onAnnotationTapped(e.payload);
      case 'selection-action':
        _onSelectionAction(e.payload);
      case 'image-press':
        _onImagePress(e.payload);
      case 'footnote-link':
        _onFootnoteLink(e.payload);
      case 'external-link':
        _onExternalLink(e.payload);
      case 'error':
        final msg = e.payload['message'] as String? ?? '未知错误';
        debugPrint('[Readest] engine error: $msg');
        if ((book.extension ?? '').toLowerCase() == 'pdf' && !_bookReady) {
          _fallbackToLegacyPdf(msg);
          break;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('打开失败: $msg'), duration: const Duration(seconds: 4)),
          );
        }
      default:
        break;
    }
  }

  /// PDF 在 readest 引擎打不开 → 回退 pdfrx 内置阅读器（手写批注同款引擎，
  /// 用户设备上实测可用），保证书架里的 PDF 一定能打开。
  void _fallbackToLegacyPdf(String reason) {
    if (_fallbackScheduled || !mounted) return;
    _fallbackScheduled = true;
    _openWatchdog?.cancel();
    TtsService.instance.stop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('PDF 引擎加载失败（$reason），已切换到内置 PDF 阅读器'),
        duration: const Duration(seconds: 4),
      ),
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(book: book, forceLegacyPdf: true),
      ),
    );
  }

  /// book-ready 后按持久化布局设置渲染器属性。
  Future<void> _applyLayout() async {
    final view = _viewKey.currentState;
    if (view == null) return;
    final attrs = <String, String?>{
      if (_style.scrolled) 'flow': 'scrolled' else 'flow': null,
      'max-column-count': _style.scrolled ? null : '${_style.maxColumns}',
      'gap': '${_style.gapPercent}%',
      if (_style.scrolled) 'scroll-direction': 'vertical',
    };
    await view.setLayout(attrs);
    if (_isPdf) await _applyPdfView();
  }

  /// PDF：缩放模式/缩放比例/主题应用（readest fixed-layout 设置）。
  Future<void> _applyPdfView() async {
    final view = _viewKey.currentState;
    if (view == null) return;
    await view.setLayout({
      'zoom': _style.pdfZoomMode == 'custom' ? 'custom' : _style.pdfZoomMode,
      'scale-factor': _style.pdfZoomMode == 'custom'
          ? _style.pdfScale.toString()
          : null,
      'spread': 'auto',
    });
    await _applyPdfTheme();
  }

  Future<void> _applyPdfTheme() async {
    final view = _viewKey.currentState;
    if (view == null || !_isPdf) return;
    if (_style.pdfThemeApplied) {
      final c = _style.colors;
      String hex(int v) =>
          '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      await view.setPageColors(apply: true, bg: hex(c.bg), fg: hex(c.fg));
    } else {
      await view.setPageColors(apply: false, bg: '#ffffff', fg: '#000000');
    }
  }

  // ── 选择菜单动作（复制/搜索/翻译/朗读/批注/AI/分享/截图） ──────────

  void _onSelectionAction(Map<String, dynamic> payload) {
    final name = payload['name'] as String? ?? '';
    final text = payload['text'] as String? ?? '';
    if (text.isEmpty) return;
    switch (name) {
      case 'tts':
        _showSelectionTtsSheet(text);
      case 'dict':
        _showDictSheet(text);
      case 'search':
        // 选中文字点搜索 → 跳系统浏览器网页搜索
        // （全书搜索入口在顶部放大镜图标）。
        openWebSearch(text, context: context);
      case 'share':
        _shareSelectionText(text);
      case 'ai':
        _openAiDialog(payload);
      case 'shot':
        _takeSelectionShot(payload);
      case 'copy':
        // 复制动作在页内已完成（clipboard）；这里不需要缓存原文——
        // 批注/AI 的记录自带 quoted_text，复制过的选区再记笔记时原文
        // 必然在记录里（方案 §2.8）。
        break;
    }
  }

  /// 分享选中文本（写入临时 txt 后走系统分享，与笔记导出同款路径）。
  Future<void> _shareSelectionText(String text) async {
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

  /// 选区截图：引擎按选区 rect 截 PNG → 存 App 目录 → 暂存待捆绑。
  Future<void> _takeSelectionShot(Map<String, dynamic> payload) async {
    final cfi = payload['cfi'] as String? ?? '';
    final rect = payload['rect'];
    Map<String, double>? selRect;
    if (rect is Map) {
      try {
        selRect = {
          for (final e in rect.entries)
            e.key.toString(): (e.value as num).toDouble(),
        };
      } catch (_) {}
    }
    final bytes =
        await _viewKey.currentState?.takeScreenshot(selectionRect: selRect);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前设备不支持选区截图，已保留原文')),
      );
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final shotDir = Directory('${docs.path}/ai_shots');
      if (!await shotDir.exists()) await shotDir.create(recursive: true);
      final path = '${shotDir.path}/${book.id}_'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);
      if (cfi.isNotEmpty) _pendingShots[cfi] = path;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('截图已保存，将随笔记一起保存')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图保存失败: $e')),
        );
      }
    }
  }

  /// 整页截图（问题14）：Android 优先整屏 MediaProjection（分屏时连
  /// 另一侧 App 一起截），否则 FoliateReaderView.takeScreenshot() 截
  /// 视口 → 存 App 截图库；不支持时提示。
  Future<void> _takeFullScreenshot() async {
    var bytes = await ScreenCapture.captureFullScreen();
    if (bytes == null || bytes.isEmpty) {
      final notice = ScreenCapture.fallbackNotice;
      if (notice != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(notice)));
      }
      bytes = await _viewKey.currentState?.takeScreenshot();
    }
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前设备不支持截图')),
      );
      return;
    }
    final path = await ShotLibrary.instance.savePng(bytes);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图保存失败')),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('截图已保存到 App 截图库')),
      );
    }
  }

  /// AI 对话框：确认后 → ai_notes 落库 + 原文渲染标注点 + 笔记中心。
  Future<void> _openAiDialog(Map<String, dynamic> payload) async {
    final cfi = payload['cfi'] as String? ?? '';
    final text = payload['text'] as String? ?? '';
    if (cfi.isEmpty || text.isEmpty) return;

    // 先截过图？把暂存的截图带上（四要素捆绑）。
    final shotPath = _pendingShots.remove(cfi);
    if (!mounted) return;
    final result = await showAiDialog(
      context,
      bookId: book.id,
      fileType: (_isPdf ? 'pdf' : 'epub'),
      fileName: book.title,
      cfi: cfi,
      quotedText: text,
      imagePath: shotPath,
    );
    if (result == null || !mounted) {
      // 取消/关闭：截图已暂存且用户没走完流程 → 放回暂存，等下次
      // 同选区操作再捆绑（或用户忽略，暂存只是内存态不落盘）。
      if (result == null && shotPath != null && cfi.isNotEmpty) {
        _pendingShots[cfi] = shotPath;
      }
      return;
    }

    final storage = ref.read(storageServiceProvider);
    final noteId = await storage.insertAiNote(AiNote(
      bookId: book.id,
      fileType: _isPdf ? 'pdf' : 'epub',
      anchor: jsonEncode({'cfi': cfi}),
      quotedText: text,
      content: result.content,
      imagePath: result.imagePath,
      conversationId: result.conversationId,
    ));
    // 原文渲染 AI 标注点（violet 色，与菜单 AI 按钮同色系）。
    await _viewKey.currentState?.addAnnotation({
      'value': cfi,
      'text': text,
      'color': '#7c3aed',
      'style': 'highlight',
      'note': result.content,
      'source': 'ai',
    });
    if (!mounted) return;
    setState(() {
      _aiNotes.insert(
        0,
        AiNote(
          id: noteId,
          bookId: book.id,
          fileType: _isPdf ? 'pdf' : 'epub',
          anchor: jsonEncode({'cfi': cfi}),
          quotedText: text,
          content: result.content,
          imagePath: result.imagePath,
          conversationId: result.conversationId,
        ),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存 AI 笔记（原文已标记，可在笔记中心查看）')),
    );
  }

  /// 朗读选中文本（原生 TTS，不打断正文进度）。
  Future<void> _speakSelection(String text) async {
    try {
      await TtsService.instance.stop();
      await TtsService.instance.play(TtsService.splitSentences(text));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('朗读失败: $e')),
        );
      }
    }
  }

  /// 选词翻译（readest 选词翻译的简化版：复用现有翻译服务）。
  Future<void> _showDictSheet(String text) async {
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
                            style:
                                const TextStyle(fontSize: 14, height: 1.6)),
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

  /// 图片画廊在 host.html 内实现（readest ImageViewer 同款思路：图片是
  /// WebView 内的 blob/localhost 资源，Flutter 侧拿不到，必须在页内展示）。
  void _onImagePress(Map<String, dynamic> payload) {
    // host.html 的 #image-gallery 已打开；这里只记录，无 UI 动作。
  }

  /// 脚注跳转：引擎已跳页，提示可返回原位。
  void _onFootnoteLink(Map<String, dynamic> payload) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已跳转到脚注'),
        action: SnackBarAction(
          label: '返回',
          onPressed: () => _viewKey.currentState?.historyBack(),
        ),
      ),
    );
  }

  void _onExternalLink(Map<String, dynamic> payload) async {
    // readest 行为：外部链接交给系统浏览器打开。
    final href = payload['href'] as String? ?? '';
    if (href.isEmpty || !mounted) return;
    try {
      final uri = Uri.parse(href);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开该链接')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开该链接: $e')),
        );
      }
    }
  }

  // ── 笔记（高亮/划线/笔记正文） ────────────────────────────────────

  Future<void> _onAnnotationCreated(Map<String, dynamic> payload) async {
    final cfi = payload['value'] as String? ?? '';
    if (cfi.isEmpty) return;
    // 先截过图的话，截图随这条批注一起落库（方案 §2.8 四要素捆绑）。
    final shotPath = _pendingShots.remove(cfi);
    final note = ReadestNote(
      bookId: book.id,
      cfi: cfi,
      text: payload['text'] as String? ?? '',
      color: payload['color'] as String?,
      style: payload['style'] as String? ?? 'highlight',
      note: payload['note'] as String? ?? '',
      imagePath: shotPath,
    );
    final id = await ref
        .read(storageServiceProvider)
        .upsertReadestNote(note);
    if (!mounted) return;
    setState(() {
      _notes.removeWhere((n) => n.cfi == cfi);
      _notes.add(ReadestNote(
        id: id,
        bookId: note.bookId,
        cfi: note.cfi,
        text: note.text,
        color: note.color,
        style: note.style,
        note: note.note,
        imagePath: note.imagePath,
        createdAt: note.createdAt,
      ));
    });
  }

  /// book-ready 后把库里的笔记恢复给引擎。
  ///
  /// 通过 `setAnnotations` 一次性灌入：引擎侧维护 pending 队列，目标章节
  /// 尚未加载完也没关系，每次章节加载完成（create-overlay）都会按 CFI
  /// 重注入——「退出后重进/从笔记中心跳回后高亮消失」的修复点。
  /// AI 标注同样进这条队列（source='ai' 字段随 payload 一起恢复）。
  Future<void> _restoreNotes() async {
    final storage = ref.read(storageServiceProvider);
    final notes = await storage.getReadestNotes(book.id);
    final aiNotes = await storage.getAiNotes(book.id);
    _notes = notes;
    _aiNotes = aiNotes;
    await _viewKey.currentState?.setAnnotations([
      for (final n in notes)
        if (n.style != 'bookmark') // 书签不渲染高亮
          {
            'value': n.cfi,
            'text': n.text,
            'color': n.color,
            'style': n.style,
            'note': n.note,
          },
      for (final a in aiNotes)
        if (_aiNoteCfi(a).isNotEmpty)
          {
            'value': _aiNoteCfi(a),
            'text': a.quotedText,
            'color': '#7c3aed',
            'style': 'highlight',
            'note': a.content,
            'source': 'ai',
          },
    ]);
    if (mounted) {
      setState(() {
        _bookmarked = _isBookmarkCfi(_lastCfi);
      });
    }
  }

  /// 解析 ai_notes.anchor 里的 CFI（EPUB/PDF readest 引擎统一存
  /// `{"cfi": "..."}`；解析失败返回空串，跳过渲染）。
  static String _aiNoteCfi(AiNote a) {
    try {
      final map = jsonDecode(a.anchor);
      if (map is Map) return (map['cfi'] as String?) ?? '';
    } catch (_) {}
    return '';
  }

  /// 点击已有高亮 → 底部弹窗：看笔记/编辑/删除。
  void _onAnnotationTapped(Map<String, dynamic> payload) {
    final cfi = payload['value'] as String? ?? '';
    if (cfi.isEmpty || !mounted) return;
    ReadestNote? note;
    for (final n in _notes) {
      if (n.cfi == cfi) {
        note = n;
        break;
      }
    }
    AiNote? aiNote;
    for (final a in _aiNotes) {
      if (_aiNoteCfi(a) == cfi) {
        aiNote = a;
        break;
      }
    }
    final isBookmark = note?.style == 'bookmark';
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (aiNote != null)
              ListTile(
                leading: const Icon(Icons.auto_awesome,
                    color: Color(0xFF7C3AED)),
                title: Row(
                  children: [
                    const Flexible(
                      child: Text('AI 生成',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3E8FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('AI',
                          style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF7C3AED),
                              fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      aiNote.content,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (aiNote.quotedText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '原文：${aiNote.quotedText}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                  ],
                ),
                isThreeLine: true,
              )
            else
              ListTile(
                leading: Icon(Icons.notes_outlined,
                    color: Theme.of(ctx).colorScheme.primary),
                title: Text(note?.note.isNotEmpty == true
                    ? '笔记：${note!.note}'
                    : (isBookmark ? '书签' : '高亮')),
                subtitle: Text(
                  note?.text ?? '',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const Divider(height: 1),
            if (aiNote != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除这条 AI 笔记'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteAiNote(aiNote!);
                },
              )
            else ...[
              if (!isBookmark)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('编辑笔记'),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (note != null) _editNote(note);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除这条高亮'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _deleteNote(cfi);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 删除 AI 笔记：清引擎标注 + ai_notes 表 + 内存列表。
  Future<void> _deleteAiNote(AiNote a) async {
    final cfi = _aiNoteCfi(a);
    if (cfi.isNotEmpty) {
      await _viewKey.currentState?.deleteAnnotation(cfi);
    }
    if (a.id != null) {
      await ref.read(storageServiceProvider).deleteAiNote(a.id!);
    }
    if (mounted) {
      setState(() => _aiNotes.removeWhere((n) => n.id == a.id));
    }
  }

  /// 编辑高亮的笔记正文（readest BookNote 编辑交互）。
  Future<void> _editNote(ReadestNote note) async {
    final ctrl = TextEditingController(text: note.note);
    final newNote = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑笔记'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '写下你的想法…',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (newNote == null || newNote == note.note) return;
    final updated = note.copyWith(note: newNote);
    await ref.read(storageServiceProvider).upsertReadestNote(updated);
    // 引擎重渲染这条批注（删除再注入，note 会随 highlight 一起恢复）。
    await _viewKey.currentState?.deleteAnnotation(note.cfi);
    await _viewKey.currentState?.addAnnotation({
      'value': note.cfi,
      'text': note.text,
      'color': note.color,
      'style': note.style,
      'note': newNote,
    });
    if (!mounted) return;
    setState(() {
      final i = _notes.indexWhere((n) => n.cfi == note.cfi);
      if (i >= 0) _notes[i] = updated;
    });
  }

  Future<void> _deleteNote(String cfi) async {
    await _viewKey.currentState?.deleteAnnotation(cfi);
    await ref
        .read(storageServiceProvider)
        .deleteReadestNoteByCfi(book.id, cfi);
    if (mounted) {
      setState(() => _notes.removeWhere((n) => n.cfi == cfi));
    }
  }

  // ── 书签 ───────────────────────────────────────────────────────────

  bool _isBookmarkCfi(String cfi) =>
      _notes.any((n) => n.style == 'bookmark' && n.cfi == cfi);

  Future<void> _toggleBookmark() async {
    // _lastCfi 由 relocate 维护；万一没到位，直接问引擎要当前位置。
    if (_lastCfi.isEmpty) {
      final cfi = await _viewKey.currentState?.getCurrentCfi() ?? '';
      if (cfi.isNotEmpty) _lastCfi = cfi;
    }
    if (_lastCfi.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没定位到当前位置，翻一页再试')),
      );
      return;
    }
    final existing =
        _notes.where((n) => n.style == 'bookmark' && n.cfi == _lastCfi);
    if (existing.isNotEmpty) {
      for (final b in existing.toList()) {
        await _viewKey.currentState?.deleteAnnotation(b.cfi);
        await ref
            .read(storageServiceProvider)
            .deleteReadestNoteByCfi(book.id, b.cfi);
        setState(() => _notes.removeWhere((n) => n.cfi == b.cfi));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书签已移除'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }
    final note = ReadestNote(
      bookId: book.id,
      cfi: _lastCfi,
      text: _tocLabel,
      style: 'bookmark',
    );
    final id = await ref.read(storageServiceProvider).upsertReadestNote(note);
    if (!mounted) return;
    setState(() => _notes.add(ReadestNote(
          id: id,
          bookId: note.bookId,
          cfi: note.cfi,
          text: note.text,
          style: 'bookmark',
        )));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加书签'), duration: Duration(seconds: 1)),
    );
  }

  /// 当前页是否有书签（relocate 时刷新图标）。
  void _refreshBookmarkState() {
    final has = _isBookmarkCfi(_lastCfi);
    if (has != _bookmarked && mounted) {
      setState(() => _bookmarked = has);
    }
  }

  void _showNotesSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('笔记与高亮',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                    ),
                    // readest Notebook 导出（Markdown，NoteExportConfig 结构）。
                    IconButton(
                      icon: const Icon(Icons.ios_share, size: 20),
                      tooltip: '导出 Markdown',
                      onPressed: () => _exportNotesMarkdown(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _notes.isEmpty
                    ? const Center(
                        child: Text('还没有笔记。选中文字后点颜色圆点即可高亮',
                            style:
                                TextStyle(color: Colors.grey, fontSize: 13)))
                    : ListView.builder(
                        itemCount: _notes.length,
                        itemBuilder: (ctx, i) {
                          final n = _notes[i];
                          final isBookmark = n.style == 'bookmark';
                          return ListTile(
                            dense: true,
                            leading: isBookmark
                                ? const Icon(Icons.bookmark, size: 18)
                                : Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
                                      color: n.color != null
                                          ? Color(int.parse(n.color!
                                              .replaceFirst('#', '0xFF')))
                                          : const Color(0xFFFACC15),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                            title: Text(
                              n.note.isNotEmpty
                                  ? n.note
                                  : (isBookmark
                                      ? (n.text.isEmpty
                                          ? '书签'
                                          : '书签 · ${n.text}')
                                      : (n.text.isEmpty ? '（高亮）' : n.text)),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!isBookmark)
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 18),
                                    tooltip: '编辑笔记',
                                    onPressed: () => _editNote(n),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18),
                                  onPressed: () => _deleteNote(n.cfi),
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _viewKey.currentState?.goTo(n.cfi);
                            },
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

  /// 导出 Markdown（readest NoteExportConfig：书名/作者/日期 + 引用 + 笔记）。
  Future<void> _exportNotesMarkdown() async {
    if (_notes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有笔记可导出')),
      );
      return;
    }
    final lines = <String>[
      '# ${book.title}',
      if (book.author.isNotEmpty) '作者：${book.author}',
      '导出时间：${DateTime.now().toIso8601String().split('.').first}',
      '',
    ];
    for (final n in _notes) {
      final styleLabel = switch (n.style) {
        'bookmark' => '书签',
        'underline' => '下划线',
        'squiggly' => '波浪线',
        _ => '高亮',
      };
      lines.add('---');
      lines.add('**[$styleLabel]** ${n.text.isNotEmpty ? '> ${n.text}' : ''}');
      if (n.note.isNotEmpty) {
        lines.add('');
        lines.add(n.note);
      }
      lines.add('');
    }
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/'
          '${book.title.isEmpty ? '读书笔记' : book.title}_笔记.md');
      await file.writeAsString(lines.join('\n'));
      await Share.shareXFiles([XFile(file.path)], subject: '${book.title} 笔记');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  Future<void> _loadToc() async {
    final view = _viewKey.currentState;
    if (view == null) return;
    final toc = await view.callJsList(
        'window.__foliate.toc()',
        (item) => (
              label: (item['label'] as String?) ?? '',
              href: (item['href'] as String?) ?? '',
              depth: (item['depth'] as num?)?.toInt() ?? 0,
            ));
    if (mounted && toc.isNotEmpty) setState(() => _toc = toc);
  }

  // ── 朗读（原生 TTS + 引擎文本/翻页） ──────────────────────────────

  /// 顶部朗读按钮 → 选择朗读起始位置（用户需求：不要一点就直接读）。
  void _showTtsStartSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择朗读起点',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('从当前章节开始'),
              subtitle: const Text('读完自动翻到下一章继续'),
              onTap: () {
                Navigator.pop(ctx);
                _startTts(fromStart: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('从全书开始'),
              onTap: () {
                Navigator.pop(ctx);
                _startTts(fromStart: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('语速设置'),
              onTap: () {
                Navigator.pop(ctx);
                _showTtsRateSheet();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 选中文案后的朗读选项。
  void _showSelectionTtsSheet(String text) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('朗读',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.short_text),
              title: const Text('只读选中文本'),
              onTap: () {
                Navigator.pop(ctx);
                _speakSelection(text);
              },
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('从当前章节开始连续朗读'),
              onTap: () {
                Navigator.pop(ctx);
                _startTts(fromStart: false);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 开始连续朗读（默认从当前章节；[fromStart] 从全书开头）。
  void _startTts({required bool fromStart}) {
    _stopTts(silent: true);
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _ttsText = '';
      _lastSectionIndex = -1;
    });
    if (fromStart) {
      _viewKey.currentState?.goToFraction(0);
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (_ttsActive) _playCurrentSection();
      });
    } else {
      _playCurrentSection();
    }
  }

  /// 语速调节弹窗（0.4~0.8，立即生效）。
  void _showTtsRateSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('朗读语速',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              Row(
                children: [
                  const Text('慢', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _ttsRate.clamp(0.4, 0.8),
                      min: 0.4,
                      max: 0.8,
                      divisions: 8,
                      label: _ttsRate.toStringAsFixed(2),
                      onChanged: (v) {
                        setLocal(() => _ttsRate = v);
                        TtsService.instance.setRate(v);
                      },
                    ),
                  ),
                  const Text('快', style: TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _stopTts({bool silent = false}) {
    TtsService.instance.stop();
    if (!silent && mounted) {
      setState(() {
        _ttsActive = false;
        _ttsPaused = false;
        _ttsText = '';
      });
    }
  }

  Future<void> _playCurrentSection() async {
    // JS 侧 getSectionText 自带 6 次 × 400ms 重试并整章拼页，Dart 只等一次
    //（真机修复：结果经 JS→Flutter 事件通道回传，不依赖 evaluateJavascript）。
    final section = await _viewKey.currentState?.sectionText();
    if (!mounted || !_ttsActive) return;
    final text = (section?.text ?? '').trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可朗读的文本')),
      );
      _stopTts();
      return;
    }
    _lastSectionIndex = section!.index;
    _playSentences(section.text, () => _afterSectionDone());
  }

  void _playSentences(String text, VoidCallback onDone) {
    final sentences = TtsService.splitSentences(text);
    if (sentences.isEmpty) {
      onDone();
      return;
    }
    TtsService.instance.play(
      sentences,
      onProgress: (i, s) {
        if (mounted) setState(() => _ttsText = s);
      },
      onDone: () {
        if (_ttsActive) onDone();
      },
      onError: (msg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
          );
          _stopTts();
        }
      },
    );
  }

  /// 一节读完 → 翻页到下一节继续（index 变化才继续，否则到书尾停止）。
  Future<void> _afterSectionDone() async {
    if (!mounted || !_ttsActive) return;
    await _viewKey.currentState?.nextPage();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final section = await _viewKey.currentState?.sectionText();
    if (!mounted || !_ttsActive) return;
    if (section != null &&
        section.index != _lastSectionIndex &&
        section.text.trim().isNotEmpty) {
      _playCurrentSection();
    } else {
      _stopTts(); // 书尾或翻不动。
    }
  }

  Widget _buildTtsBar(ColorScheme colors) {
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              // 醒目的暂停/继续按钮（用户需求：朗读时要有清晰的暂停键）。
              IconButton.filledTonal(
                iconSize: 26,
                icon: Icon(_ttsPaused ? Icons.play_arrow : Icons.pause),
                tooltip: _ttsPaused ? '继续朗读' : '暂停朗读',
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                ),
                onPressed: () {
                  if (_ttsPaused) {
                    setState(() => _ttsPaused = false);
                    TtsService.instance.resume();
                  } else {
                    setState(() => _ttsPaused = true);
                    TtsService.instance.pause();
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                tooltip: '停止朗读',
                onPressed: _stopTts,
              ),
              // 语速（readest ttsRate 的移动端映射：0.4 慢 ~ 0.8 快）。
              IconButton(
                icon: const Icon(Icons.speed),
                tooltip: '语速',
                onPressed: _showTtsRateSheet,
              ),
              Expanded(
                child: Text(
                  _ttsPaused
                      ? '已暂停 · $_ttsText'
                      : (_ttsText.isEmpty ? '准备朗读…' : _ttsText),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 底部栏 ─────────────────────────────────────────────────────────

  Widget _buildFooter(ColorScheme colors) {
    // 0-based 页码显示成 1-based；没有数据时显示静态空进度条（value 不能
    // 传 null——LinearProgressIndicator 的 null = 无限转圈动画，用户看起来
    // 就是「一直在加载」）。
    final displayPage = _pages > 0 ? (_page + 1).clamp(1, _pages) : 0;
    final fraction =
        _pages > 0 ? (_page / _pages).clamp(0.0, 1.0) : 0.0;
    return Material(
      color: colors.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 阅读进度条（readest 底部粘性进度条语义）。
            LinearProgressIndicator(
              value: fraction,
              minHeight: 2,
              backgroundColor: colors.surfaceContainerHighest,
              color: Color(_style.colors.primary),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    tooltip: '上一页',
                    onPressed: _bookReady
                        ? () => _viewKey.currentState?.prevPage()
                        : null,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          // readest 页码（EPUB 每 1500 字符一页；PDF 真实页）。
                          _pages > 0 ? '$displayPage / $_pages' : ' ',
                          style: TextStyle(
                              fontSize: 12, color: colors.onSurfaceVariant),
                        ),
                        if (_tocLabel.isNotEmpty)
                          Text(
                            _tocLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurfaceVariant
                                    .withValues(alpha: 0.7)),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    tooltip: '下一页',
                    onPressed: _bookReady
                        ? () => _viewKey.currentState?.nextPage()
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 目录侧栏 ───────────────────────────────────────────────────────

  void _showTocSheet() {
    if (_toc.isEmpty) {
      _loadToc();
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text('目录',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              const Divider(height: 1),
              Expanded(
                child: _toc.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _toc.length,
                        itemBuilder: (ctx, i) {
                          final t = _toc[i];
                          // readest：当前章节在目录里高亮（relocate 的 tocItem）。
                          final current = _tocLabel.isNotEmpty &&
                              t.label == _tocLabel;
                          return ListTile(
                            dense: true,
                            selected: current,
                            selectedTileColor: Theme.of(ctx)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08),
                            contentPadding:
                                EdgeInsets.only(left: 12.0 + t.depth * 18),
                            leading: current
                                ? Icon(Icons.play_arrow,
                                    size: 16,
                                    color: Theme.of(ctx).colorScheme.primary)
                                : null,
                            title: Text(t.label,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () {
                              Navigator.pop(ctx);
                              if (t.href.isNotEmpty) {
                                _viewKey.currentState?.goTo(t.href);
                              }
                            },
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

  // ── 搜索 ───────────────────────────────────────────────────────────

  // 搜索状态（弹层里实时使用）。
  String _searchOriginCfi = ''; // 打开搜索时的阅读位置（「返回当前位置」用）
  int _searchSections = 0; // 全书章节数（结果位置百分比换算）
  Timer? _searchDebounce;

  /// 打开全书搜索弹层：
  /// · 先释放 WebView 焦点（否则 Android 上 IME 被 WebView 占着，
  ///   打字后搜索栏看不到字——用户反馈的 bug）；
  /// · 记录当前位置，弹层里可一键「回到阅读位置」；
  /// · 输入即时防抖搜索，结果紧随其后显示在下方列表。
  Future<void> _showSearchSheet({String initialQuery = ''}) async {
    if (_bookReady) {
      // 记录当前位置（打开弹层前的最新 CFI）。
      final current = await _viewKey.currentState?.getCurrentCfi() ?? '';
      if (current.isNotEmpty) {
        _searchOriginCfi = current;
      } else if (_lastCfi.isNotEmpty) {
        _searchOriginCfi = _lastCfi;
      }
      await _viewKey.currentState?.releaseFocus();
    }
    if (!mounted) return;

    final ctrl = TextEditingController(text: initialQuery);
    String mode = 'contains';
    bool matchCase = false;
    String lastQuery = '';
    void run(String q, void Function(VoidCallback) setLocal) {
      if (q.trim().isEmpty || q == lastQuery) return;
      lastQuery = q;
      _runSearch(q, mode, matchCase, setLocal);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) => SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          autofocus: true,
                          // 显式指定文字颜色：主题的输入框样式不保证与弹层
                          // 背景对比（此前「打字后搜索栏没有字」的根因之一）。
                          style: TextStyle(
                            fontSize: 15,
                            color: Theme.of(ctx).colorScheme.onSurface,
                          ),
                          decoration: const InputDecoration(
                            hintText: '搜索全书…',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.all(Radius.circular(999)),
                            ),
                            contentPadding: EdgeInsets.symmetric(
                                vertical: 6, horizontal: 14),
                            isDense: true,
                          ),
                          onChanged: (q) {
                            // 防抖 450ms：打字即搜，结果紧随其后出现。
                            _searchDebounce?.cancel();
                            _searchDebounce = Timer(
                                const Duration(milliseconds: 450), () {
                              if (ctx.mounted) run(q, setLocal);
                            });
                          },
                          onSubmitted: (q) => run(q, setLocal),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40)),
                        onPressed: _searching
                            ? null
                            : () => run(ctrl.text, setLocal),
                        child: _searching
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('搜索'),
                      ),
                    ],
                  ),
                ),
                // readest 搜索选项：模式 + 大小写。
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final (label, value) in const [
                        ('包含', 'contains'),
                        ('全词', 'whole-words'),
                        ('正则', 'regex'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(label,
                                style: const TextStyle(fontSize: 11)),
                            selected: mode == value,
                            onSelected: (_) {
                              setLocal(() => mode = value);
                              lastQuery = '';
                              run(ctrl.text, setLocal);
                            },
                          ),
                        ),
                      const Spacer(),
                      const Text('区分大小写', style: TextStyle(fontSize: 11)),
                      Switch(
                        value: matchCase,
                        onChanged: (v) {
                          setLocal(() => matchCase = v);
                          lastQuery = '';
                          run(ctrl.text, setLocal);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 结果计数 + 回到阅读位置。
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                  child: Row(
                    children: [
                      Text(
                        _searching
                            ? '搜索中…'
                            : _searchResults.isEmpty
                                ? '结果会显示在这里'
                                : '${_searchResults.length} 个结果',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF94A3B8)),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8)),
                        icon: const Icon(Icons.undo, size: 15),
                        label: const Text('回到阅读位置',
                            style: TextStyle(fontSize: 12)),
                        onPressed: _searchOriginCfi.isEmpty
                            ? null
                            : () {
                                _viewKey.currentState
                                    ?.goTo(_searchOriginCfi);
                              },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _searchResults.isEmpty
                      ? Center(
                          child: Text(
                            _searching ? '正在搜索全书…' : '输入关键词，结果会自动出现在这里',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _searchResults.length,
                          itemBuilder: (ctx, i) {
                            final r = _searchResults[i];
                            return ListTile(
                              dense: true,
                              // 章节 + 位置：第 X 章（按 CFI 解析）+ 全书约 Y%。
                              title: Text(r.excerpt.isEmpty
                                  ? '（无摘要）'
                                  : r.excerpt,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                _searchLocationLabel(
                                    r.cfi, r.label, r.secIndex),
                                style: const TextStyle(fontSize: 11),
                              ),
                              onTap: () {
                                // 点击跳转（弹层保持打开，可继续试其它结果，
                                // 想回原位点上面「回到阅读位置」）。
                                _viewKey.currentState?.goTo(r.cfi);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => _searchDebounce?.cancel());
  }

  /// 搜索结果位置标签：「章节名 · 第 X 章 · 全书约 N%」。
  /// 优先级：JS 给的章节名 → 目录 TOC 里按章节序号找 → CFI 正则解析。
  String _searchLocationLabel(String cfi, String label, int secIndex) {
    final parts = <String>[];

    // 1) 章节名（JS 侧已用 tocProgress / sections 兜底；这里再用目录兜一层）。
    var chapterLabel = label;
    if (chapterLabel.isEmpty && secIndex >= 0 && secIndex < _toc.length) {
      chapterLabel = _toc[secIndex].label;
    }
    if (chapterLabel.isNotEmpty) parts.add(chapterLabel);

    // 2) 章节序号 + 全书百分比。
    var secIdx = secIndex;
    if (secIdx < 0) {
      // CFI 形如 epubcfi(/6/N[...]!/…)，N 即章节序号（0-based）。
      final m = RegExp(r'^epubcfi\(/6/(\d+)').firstMatch(cfi);
      secIdx = m != null ? int.tryParse(m.group(1)!) ?? -1 : -1;
    }
    if (secIdx >= 0 && _searchSections > 0) {
      parts.add('第 ${secIdx + 1} 章 · 全书约 '
          '${((secIdx + 1) / _searchSections * 100).round()}%');
    }
    return parts.join(' · ');
  }

  Future<void> _runSearch(String query, String mode, bool matchCase,
      void Function(VoidCallback) setLocal) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setLocal(() {
      _searching = true;
      _searchResults = [];
    });
    final view = _viewKey.currentState;
    if (view == null) return;
    final r = await view.search(q, mode: mode, matchCase: matchCase);
    if (mounted) {
      setLocal(() {
        _searching = false;
        _searchSections = r.sections;
        _searchResults = r.results;
      });
    }
  }

  // ── 设置面板（readest 字体/颜色面板复刻） ─────────────────────────

  void _showSettingsSheet() {
    final fontSizeCtrl = TextEditingController(text: _style.fontSize.toString());
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            final colors = Theme.of(ctx).colorScheme;
            return Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('阅读设置',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: colors.onSurface)),
                    const SizedBox(height: 14),

                    // 字号
                    _sliderRow(
                      ctx,
                      '字号',
                      _style.fontSize,
                      8,
                      30,
                      1,
                      (v) => _updateStyle(setLocal, () {
                        _style.fontSize = v;
                        fontSizeCtrl.text = v.toStringAsFixed(0);
                      }),
                    ),
                    // 行距
                    _sliderRow(ctx, '行距', _style.lineHeight, 0.8, 2.4, 0.1,
                        (v) => _updateStyle(setLocal, () {
                              _style.lineHeight =
                                  double.parse(v.toStringAsFixed(1));
                            })),
                    // 页边距
                    _sliderRow(ctx, '页边距', _style.marginLeft, 8, 88, 2,
                        (v) => _updateStyle(setLocal, () {
                              _style.marginLeft = v;
                              _style.marginRight = v;
                              _style.marginTop = v;
                              _style.marginBottom = v;
                            })),
                    // 段间距（readest paragraphMargin）
                    _sliderRow(ctx, '段间距', _style.paragraphMarginEm, 0, 2, 0.1,
                        (v) => _updateStyle(setLocal, () {
                              _style.paragraphMarginEm =
                                  double.parse(v.toStringAsFixed(1));
                            })),
                    // 首行缩进（readest textIndent，CJK 常用 2em）
                    _sliderRow(ctx, '首行缩进', _style.textIndentEm, 0, 4, 0.1,
                        (v) => _updateStyle(setLocal, () {
                              _style.textIndentEm =
                                  double.parse(v.toStringAsFixed(1));
                            })),
                    // 字距
                    _sliderRow(ctx, '字距', _style.letterSpacingEm, 0, 0.5, 0.05,
                        (v) => _updateStyle(setLocal, () {
                              _style.letterSpacingEm =
                                  double.parse(v.toStringAsFixed(2));
                            })),
                    const SizedBox(height: 4),

                    // 阅读模式（readest：分页 / 连续滚动）
                    Text('阅读模式', style: _labelStyle(colors)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('分页',
                              style: TextStyle(fontSize: 12)),
                          selected: !_style.scrolled,
                          onSelected: (_) => _updateLayout(setLocal, () {
                            _style.scrolled = false;
                          }),
                        ),
                        ChoiceChip(
                          label: const Text('滚动',
                              style: TextStyle(fontSize: 12)),
                          selected: _style.scrolled,
                          onSelected: (_) => _updateLayout(setLocal, () {
                            _style.scrolled = true;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // 分栏（readest maxColumnCount 1~2，仅分页模式生效）
                    Text('分栏', style: _labelStyle(colors)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final n in const [1, 2])
                          ChoiceChip(
                            label: Text('$n 栏',
                                style: const TextStyle(fontSize: 12)),
                            selected: _style.maxColumns == n,
                            onSelected: (_) => _updateLayout(setLocal, () {
                              _style.maxColumns = n;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // 字重（readest fontWeight 400/500/600/700）
                    Text('字重', style: _labelStyle(colors)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final w in const [400, 500, 600, 700])
                          ChoiceChip(
                            label: Text(
                                const {400: '常规', 500: '中等', 600: '半粗', 700: '粗体'}[w]!,
                                style: const TextStyle(fontSize: 12)),
                            selected: _style.fontWeight == w,
                            onSelected: (_) => _updateStyle(setLocal, () {
                              _style.fontWeight = w;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 字体
                    Text('字体', style: _labelStyle(colors)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final f in readestFontStacks.keys)
                          ChoiceChip(
                            label: Text(f,
                                style: const TextStyle(fontSize: 12)),
                            selected: _style.fontFamily == f,
                            onSelected: (_) => _updateStyle(setLocal, () {
                              _style.fontFamily = f;
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 主题（11 套）
                    Text('主题', style: _labelStyle(colors)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final id in readestThemes.keys)
                          _themeDot(id, setLocal),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 暗色
                    Row(
                      children: [
                        Text('深色纸面', style: _labelStyle(colors)),
                        const Spacer(),
                        Switch(
                          value: _style.dark,
                          onChanged: (v) => _updateStyle(setLocal, () {
                            _style.dark = v;
                            if (_isPdf && _style.pdfThemeApplied) {
                              _applyPdfTheme();
                            }
                          }),
                        ),
                      ],
                    ),
                    // 两端对齐（readest fullJustification）
                    Row(
                      children: [
                        Text('两端对齐', style: _labelStyle(colors)),
                        const Spacer(),
                        Switch(
                          value: _style.fullJustification,
                          onChanged: (v) => _updateStyle(setLocal, () {
                            _style.fullJustification = v;
                          }),
                        ),
                      ],
                    ),
                    // 连字符（readest hyphenation）
                    Row(
                      children: [
                        Text('自动连字符', style: _labelStyle(colors)),
                        const Spacer(),
                        Switch(
                          value: _style.hyphenation,
                          onChanged: (v) => _updateStyle(setLocal, () {
                            _style.hyphenation = v;
                          }),
                        ),
                      ],
                    ),
                    // 翻页动画（readest animated）
                    Row(
                      children: [
                        Text('翻页动画', style: _labelStyle(colors)),
                        const Spacer(),
                        Switch(
                          value: _animated,
                          onChanged: (v) => setLocal(() {
                            _animated = v;
                            AppConfig.instance.setReadestAnimated(v);
                            _viewKey.currentState?.setAnimated(v);
                          }),
                        ),
                      ],
                    ),

                    // ── PDF 专属（readest fixed-layout 设置） ──────────
                    if (_isPdf) ...[
                      const Divider(height: 20),
                      Text('PDF 显示', style: _labelStyle(colors)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (label, mode) in const [
                            ('适应页面', 'fit-page'),
                            ('适应宽度', 'fit-width'),
                            ('原始大小', 'original-size'),
                            ('自定义', 'custom'),
                          ])
                            ChoiceChip(
                              label: Text(label,
                                  style: const TextStyle(fontSize: 12)),
                              selected: _style.pdfZoomMode == mode,
                              onSelected: (_) => _updateLayout(setLocal, () {
                                _style.pdfZoomMode = mode;
                              }),
                            ),
                        ],
                      ),
                      if (_style.pdfZoomMode == 'custom')
                        _sliderRow(ctx, '缩放', _style.pdfScale, 50, 500, 10,
                            (v) => _updateLayout(setLocal, () {
                                  _style.pdfScale = v;
                                })),
                      Row(
                        children: [
                          Text('主题应用到 PDF', style: _labelStyle(colors)),
                          const Spacer(),
                          Switch(
                            value: _style.pdfThemeApplied,
                            onChanged: (v) => _updateLayout(setLocal, () {
                              _style.pdfThemeApplied = v;
                            }),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  TextStyle _labelStyle(ColorScheme colors) =>
      TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.onSurfaceVariant);

  Widget _sliderRow(BuildContext ctx, String label, double value, double min,
      double max, double divisions, void Function(double) onChanged) {
    final colors = Theme.of(ctx).colorScheme;
    return Row(
      children: [
        SizedBox(
            width: 52,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / divisions).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _themeDot(String id, StateSetter setLocal) {
    final entry = readestThemes[id]!;
    final c = _style.dark ? entry.dark : entry.light;
    final selected = _style.themeId == id;
    return Tooltip(
      message: id,
      child: GestureDetector(
        onTap: () => _updateStyle(setLocal, () {
          _style.themeId = id;
        }),
        child: Container(
          width: 36,
          height: 36,
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

  void _updateStyle(StateSetter setLocal, void Function() mutate) {
    mutate();
    setLocal(() {});
    _viewKey.currentState?.updateStyles(_style.buildCss());
    AppConfig.instance.setReadestStyleJson(jsonEncode(_style.toJson()));
  }

  /// 布局类设置（模式/分栏/PDF 缩放）：改渲染器属性而非 CSS。
  void _updateLayout(StateSetter setLocal, void Function() mutate) {
    mutate();
    setLocal(() {});
    _applyLayout();
    AppConfig.instance.setReadestStyleJson(jsonEncode(_style.toJson()));
  }
}
