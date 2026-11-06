import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// foliate-js 引擎事件（host.html → Flutter）。
class FoliateEvent {
  final String name;
  final Map<String, dynamic> payload;

  const FoliateEvent(this.name, this.payload);

  String get cfi => (payload['cfi'] as String?) ?? '';
  double get fraction => (payload['fraction'] as num?)?.toDouble() ?? 0;
  int get index => (payload['index'] as num?)?.toInt() ?? 0;

  /// PDF（fixed-layout）真实页码：foliate-fxl 的 page/pages（0-based）。
  int? get page => (payload['page'] as num?)?.toInt();
  int? get pages => (payload['pages'] as num?)?.toInt();

  /// readest 的"页码"：location = {current, next, total}，每 1500 字符一页。
  int get locationCurrent => _int(_map('location')?['current']);
  int get locationTotal => _int(_map('location')?['total']);

  /// 章节号 section = {current, total}。
  int get sectionCurrent => _int(_map('section')?['current']);
  int get sectionTotal => _int(_map('section')?['total']);

  /// 剩余分钟 time = {section, total}。
  int get timeSection => _int(_map('time')?['section']);
  int get timeTotal => _int(_map('time')?['total']);

  String get tocItemLabel => (_map('tocItem')?['label'] as String?) ?? '';
  String get tocItemHref => (_map('tocItem')?['href'] as String?) ?? '';

  bool get fixedLayout => (payload['fixedLayout'] as bool?) ?? false;
  String get format => (payload['format'] as String?) ?? '';

  Map<String, dynamic>? _map(String key) {
    final v = payload[key];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  static int _int(Object? v) => (v as num?)?.toInt() ?? 0;
}

/// foliate-js 阅读引擎封装（readest 同款引擎，EPUB 分页渲染）。
///
/// 架构：
///   · LocalhostServer 从 assets/reader/ 提供 host.html 与全部引擎模块
///     （正规 http origin，模块化 ES import 正常工作）；
///   · 书籍字节走自定义 scheme `x-book://main`，由 [shouldInterceptRequest]
///     回传（避免几 MB base64 字符串在 JS 桥里搬运）；
///   · Flutter ↔ JS：`window.__foliate.*` 方法（evaluateJavascript 调用）
///     与 `foliateEvent` JS handler（JS → Flutter 事件）。
class FoliateReaderView extends StatefulWidget {
  /// EPUB/PDF 文件本地路径。
  final String bookPath;

  /// 上次阅读位置（CFI），null 则从头开始。
  final String? initialCfi;

  /// 阅读样式 CSS（[ReadestStyle] 生成）；null 用引擎默认。
  final String? styleCss;

  /// 翻页动画开关。
  final bool animated;

  /// 内容区最大行宽（px）。
  final double maxInlineSize;

  /// 内容区最大高度（px，分页的"页高"）。
  final double maxBlockSize;

  /// 分页列间距（百分比 0~100）。
  final double gapPercent;

  /// 事件回调（shell-ready / book-ready / relocate / load / error…）。
  final void Function(FoliateEvent event)? onEvent;

  const FoliateReaderView({
    super.key,
    required this.bookPath,
    this.initialCfi,
    this.styleCss,
    this.animated = false,
    this.maxInlineSize = 700,
    this.maxBlockSize = 1200,
    this.gapPercent = 5,
    this.onEvent,
  });

  @override
  State<FoliateReaderView> createState() => FoliateReaderViewState();
}

class FoliateReaderViewState extends State<FoliateReaderView> {
  InAppWebViewController? _controller;
  InAppLocalhostServer? _server;
  bool _opened = false;

  /// 书籍字节缓存（同一次打开内多次请求只读一次盘）。
  Uint8List? _bookBytes;

  /// 专用书籍字节服务器（raw dart:io HttpServer，跨平台行为一致）。
  ///
  /// 为什么不用 shouldInterceptRequest：Android 上 InAppLocalhostServer 走
  /// ServiceWorker 拦截，Dart 回调与它的优先级因版本而异；Chromium 的
  /// fetch() 又对非 http(s) scheme 直接抛 "Failed to fetch"（书库打开书籍
  /// 失败的根因）。独立的 loopback HttpServer 不经过任何拦截层，最稳。
  HttpServer? _bookServer;

  /// 朗读文本事件通道的等待者（section-text 事件回传时完成）。
  Completer<({String text, int index, String label})>? _sectionTextCompleter;

  @override
  void initState() {
    super.initState();
    _startServer();
    _startBookServer();
  }

  @override
  void dispose() {
    _server?.close();
    _server = null;
    _bookServer?.close(force: true);
    _bookServer = null;
    super.dispose();
  }

  /// 启动书籍字节服务器（8413 起，被占则顺延；127.0.0.1 仅回环）。
  Future<void> _startBookServer() async {
    for (var port = 8413; port < 8420; port++) {
      try {
        final server =
            await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _bookServer = server;
        server.listen(_handleBookRequest);
        debugPrint('[Foliate] book server on port $port');
        return;
      } catch (e) {
        debugPrint('[Foliate] bind $port failed: $e');
      }
    }
    debugPrint('[Foliate] no port available for book server');
  }

  Future<void> _handleBookRequest(HttpRequest req) async {
    try {
      if (req.uri.path != '/book/main') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (req.method == 'OPTIONS') {
        // CORS 预检（一般不会发生：GET 无自定义头是简单请求）。
        req.response
          ..statusCode = HttpStatus.noContent
          ..headers.set('Access-Control-Allow-Origin', '*')
          ..headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS')
          ..headers.set('Access-Control-Allow-Headers', '*');
        await req.response.close();
        return;
      }
      _bookBytes ??= await File(widget.bookPath).readAsBytes();
      final ext = widget.bookPath.toLowerCase();
      final contentType = ext.endsWith('.pdf')
          ? 'application/pdf'
          : 'application/epub+zip';
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.parse(contentType)
        ..headers.set('Access-Control-Allow-Origin', '*')
        ..headers.set('Cache-Control', 'no-store')
        ..add(_bookBytes!);
      await req.response.close();
    } catch (e) {
      debugPrint('[Foliate] book server error: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _startServer() async {
    try {
      final server = InAppLocalhostServer(
        port: 8410,
        documentRoot: 'assets/reader',
      );
      await server.start();
      if (!mounted) {
        server.close();
        return;
      }
      setState(() => _server = server);
    } catch (e) {
      debugPrint('[Foliate] localhost server start failed: $e');
      if (mounted) setState(() => _server = null);
    }
  }

  /// JS → Flutter 事件。
  void _onJsEvent(List<dynamic> args) {
    if (args.isEmpty || args.first is! Map) return;
    final map = Map<String, dynamic>.from(args.first as Map);
    final name = map['name'] as String? ?? '';
    final raw = map['payload'];
    final payload = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};

    // 朗读文本走事件通道回传（真机：evaluateJavascript 回传 Promise 结果
    // 不可靠，而 callHandler 事件通道已被选词朗读验证可用）。
    if (name == 'section-text') {
      final c = _sectionTextCompleter;
      if (c != null && !c.isCompleted) {
        c.complete((
          text: (payload['text'] as String?) ?? '',
          index: (payload['index'] as num?)?.toInt() ?? 0,
          label: (payload['label'] as String?) ?? '',
        ));
      }
      return;
    }

    if (!mounted) return;
    widget.onEvent?.call(FoliateEvent(name, payload));
  }

  Future<void> _eval(String source) async {
    try {
      await _controller?.evaluateJavascript(source: source);
    } catch (e) {
      debugPrint('[Foliate] eval failed: $e');
    }
  }

  /// 打开书并应用设置（页面加载完成后调用一次）。
  ///
  /// ⚠️ 书必须走真实 http：Chromium 的 fetch() 对非 http(s) scheme（如
  /// `x-book://`）在渲染进程直接抛 "Failed to fetch"，请求根本到不了
  /// shouldInterceptRequest——这正是书库打开书籍失败的根因。书籍字节由
  /// [_bookServer]（独立 loopback HttpServer）提供；x-book scheme 仅作
  /// 兜底（个别平台也许能拦截）。
  Future<void> _openBook(InAppWebViewController c) async {
    if (_opened) return;
    _opened = true;

    final port = _bookServer?.port;
    final url = port != null
        ? 'http://127.0.0.1:$port/book/main'
        : 'x-book://main';
    await c.evaluateJavascript(source: "window.__foliate.open(${jsonEncode(url)})");
    // open 是 async（整本书解析），book-ready 事件由 JS 发出；Flutter 端收到
    // book-ready 后调用 [applySettings] 应用样式与恢复进度（见 reader_screen）。
  }

  /// 把样式/属性应用到引擎。
  Future<void> _applySettings(InAppWebViewController c) async {
    final css = widget.styleCss;
    if (css != null && css.isNotEmpty) {
      await c.evaluateJavascript(
          source: 'window.__foliate.applyStyles(${jsonEncode(css)})');
    }
    final animated = widget.animated;
    if (animated) {
      await c.evaluateJavascript(
          source: "window.__foliate.setAttr('animated', '')");
    } else {
      await c.evaluateJavascript(
          source: 'document.querySelector("foliate-view")?.renderer?.removeAttribute("animated"); true');
    }
    await c.evaluateJavascript(source:
        "window.__foliate.setAttr('max-inline-size', '${widget.maxInlineSize}px')");
    await c.evaluateJavascript(source:
        "window.__foliate.setAttr('max-block-size', '${widget.maxBlockSize}px')");
    await c.evaluateJavascript(source:
        "window.__foliate.setAttr('gap', '${widget.gapPercent}%')");
  }

  /// 书籍字节拦截：
  ///   · 主路径：同源 http `…/x-book/main`（fetch 对非 http scheme 直接失败，
  ///     所以书必须走 http 再拦截回传）；
  ///   · 兼容路径：旧 `x-book://main` scheme（保留兜底）。
  Future<WebResourceResponse?> _intercept(
      InAppWebViewController controller, WebResourceRequest request) async {
    final uri = request.url;
    final isBookPath = uri.path == '/x-book/main' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
    if (uri.scheme == 'x-book' || isBookPath) {
      try {
        // 缓存字节：pdf.js 的 range transport 与主线程解析可能多次读同一本书，
        // 避免每次都重新读盘。
        _bookBytes ??= await File(widget.bookPath).readAsBytes();
        final ext = widget.bookPath.toLowerCase();
        final contentType = ext.endsWith('.pdf')
            ? 'application/pdf'
            : 'application/epub+zip';
        return WebResourceResponse(
          contentType: contentType,
          contentEncoding: 'binary',
          data: _bookBytes,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Content-Disposition': 'inline',
          },
        );
      } catch (e) {
        debugPrint('[Foliate] intercept book bytes failed: $e');
        return WebResourceResponse(
          contentType: 'text/plain',
          contentEncoding: 'utf-8',
          data: Uint8List.fromList(utf8.encode('book load error: $e')),
          statusCode: 500,
        );
      }
    }
    return null;
  }

  // ── 对外控制 API（reader_screen 调用） ────────────────────────────

  Future<void> nextPage() => _eval('window.__foliate.next()');
  Future<void> prevPage() => _eval('window.__foliate.prev()');
  Future<void> goTo(String cfi) =>
      _eval('window.__foliate.goTo(${jsonEncode(cfi)})');
  Future<void> goToFraction(double f) =>
      _eval('window.__foliate.goToFraction($f)');
  Future<void> updateStyles(String css) =>
      _eval('window.__foliate.applyStyles(${jsonEncode(css)})');
  Future<void> updateAttr(String name, String value) =>
      _eval("window.__foliate.setAttr('$name', '$value')");

  /// 运行时开关翻页动画（设置面板切换，不用重开书）。
  Future<void> setAnimated(bool on) async {
    if (on) {
      await _eval("window.__foliate.setAttr('animated', '')");
    } else {
      await _eval("document.querySelector('foliate-view')?.renderer"
          "?.removeAttribute('animated'); true");
    }
  }

  /// 批量布局属性（flow/gap/max-column-count/dir/zoom/scale-factor/spread…）。
  Future<void> setLayout(Map<String, String?> attrs) =>
      _eval('window.__foliate.setLayout(${jsonEncode(attrs)})');

  /// PDF：主题应用到纸面（readest applyThemeToPDF）。
  Future<void> setPageColors({
    required bool apply,
    required String bg,
    required String fg,
  }) =>
      _eval('window.__foliate.setPageColors($apply, ${jsonEncode(bg)}, '
          '${jsonEncode(fg)})');

  /// 上一章/下一章。
  Future<void> nextSection() => _eval('window.__foliate.nextSection()');
  Future<void> prevSection() => _eval('window.__foliate.prevSection()');

  /// 历史返回（脚注跳转后回原位）。
  Future<void> historyBack() => _eval('window.__foliate.historyBack()');

  /// 全文搜索（readest 选项：mode / matchCase）。
  /// sections = 全书章节数（搜索结果里的位置百分比用它换算）。
  /// 每个结果带 secIndex = 章节序号（0-based，-1 = 未知），label = 章节名。
  Future<
      ({
        bool ok,
        int sections,
        List<({String cfi, String excerpt, String label, int secIndex})>
            results
      })> search(String query,
      {String mode = 'contains', bool matchCase = false}) async {
    try {
      final r = await _controller?.evaluateJavascript(
          source: 'window.__foliate.search(${jsonEncode(query)}, '
              '{mode: ${jsonEncode(mode)}, matchCase: $matchCase})');
      final map = r is Map ? Map<String, dynamic>.from(r) : <String, dynamic>{};
      final list = (map['results'] as List?) ?? [];
      final results = <({String cfi, String excerpt, String label, int secIndex})>[
        for (final raw in list.whereType<Map>())
          if (raw['cfi'] is String)
            (
              cfi: raw['cfi'] as String,
              excerpt: (raw['excerpt'] as String?) ?? '',
              label: (raw['label'] as String?) ?? '',
              secIndex: (raw['index'] as num?)?.toInt() ?? -1,
            )
      ];
      return (
        ok: map['ok'] == true,
        sections: (map['sections'] as num?)?.toInt() ?? 0,
        results: results,
      );
    } catch (e) {
      debugPrint('[Foliate] search failed: $e');
      return (
        ok: false,
        sections: 0,
        results:
            const <({String cfi, String excerpt, String label, int secIndex})>[]
      );
    }
  }

  /// 释放 WebView 的文字输入焦点。
  ///
  /// 打开 Flutter 弹层（搜索/AI/笔记）前调用：个别 Android 设备上 WebView
  /// 仍持有系统 IME 焦点，导致 Flutter 的 TextField「打字后搜索栏没有字」
  /// （键盘输入全被 WebView 吃掉了）。blur 页面焦点 + clearFocus 双保险。
  Future<void> releaseFocus() async {
    try {
      await _controller?.evaluateJavascript(
        source: "if (document.activeElement && document.activeElement.blur) "
            "{ document.activeElement.blur(); } true",
      );
    } catch (_) {}
    try {
      await _controller?.clearFocus();
    } catch (_) {}
  }

  /// 当前节所有图片（画廊数据源）。
  Future<List<({String src, String alt})>> sectionImages() =>
      callJsList('window.__foliate.sectionImages()',
          (m) => (src: (m['src'] as String?) ?? '', alt: (m['alt'] as String?) ?? ''));

  /// 注入一条高亮/笔记（{value: cfi, text, color, style, note}）。
  Future<void> addAnnotation(Map<String, dynamic> payload) =>
      _eval('window.__foliate.addAnnotation(${jsonEncode(payload)})');

  /// 恢复全部批注：引擎侧维护 pending 队列，每个章节加载完成时按 CFI
  /// 自动重注入（未加载的章节不再静默丢失——「退出后/笔记中心跳回后
  /// 高亮消失」的修复）。
  Future<void> setAnnotations(List<Map<String, dynamic>> payloads) =>
      _eval('window.__foliate.setAnnotations(${jsonEncode(payloads)})');

  /// 删除一条高亮（按 CFI）。
  Future<void> deleteAnnotation(String cfi) =>
      _eval('window.__foliate.deleteAnnotation(${jsonEncode(cfi)})');

  /// 当前章节纯文本（供原生 TTS 朗读）。
  ///
  /// 通过 JS 事件通道（`section-text`）回传：真机上 evaluateJavascript
  /// 回传 Promise 结果不可靠（「没有可朗读的文本」的根因），而事件通道
  /// 已被选词朗读验证可用。JS 侧自带 6 次 × 400ms 重试 + 整章拼页。
  Future<({String text, int index, String label})> sectionText() async {
    final completer = Completer<({String text, int index, String label})>();
    _sectionTextCompleter = completer;
    try {
      await _eval('window.__foliate.getSectionText()');
    } catch (e) {
      debugPrint('[Foliate] getSectionText eval failed: $e');
    }
    try {
      return await completer.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () => (text: '', index: 0, label: ''),
      );
    } finally {
      if (_sectionTextCompleter == completer) _sectionTextCompleter = null;
    }
  }
  Future<String> getCurrentCfi() async {
    try {
      final r = await _controller?.evaluateJavascript(
          source: 'window.__foliate.currentCfi()');
      return (r as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 调用 JS 表达式并解析为对象列表（表达式须返回 JSON 数组）。
  Future<List<T>> callJsList<T>(
      String jsExpr, T Function(Map<String, dynamic> item) mapper) async {
    try {
      final r = await _controller?.evaluateJavascript(source: jsExpr);
      if (r is List) {
        return r
            .whereType<Map>()
            .map((m) => mapper(Map<String, dynamic>.from(m)))
            .toList();
      }
      if (r is String) {
        final decoded = jsonDecode(r);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((m) => mapper(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
      return const [];
    } catch (e) {
      debugPrint('[Foliate] callJsList failed: $e');
      return const [];
    }
  }

  /// 打开书后（book-ready 事件）应用样式并恢复进度。
  Future<void> applyInitialSettings() async {
    await _applySettings(_controller!);
    final cfi = widget.initialCfi;
    await _eval("window.__foliate.restore(${cfi == null ? 'null' : jsonEncode(cfi)})");
  }

  /// 截取当前 WebView 的 PNG（选中截图用）。
  ///
  /// [selectionRect] = 选区在页面视口的包围盒（left/top/right/bottom，
  /// JS getBoundingClientRect 的 CSS 像素）。Android 与 Windows 的原生
  /// takeScreenshot 都支持按 rect 截取选区区域；失败（个别平台/版本
  /// 不支持或 rect 非法）自动降级为全视口截图，再失败返回 null——
  /// 调用方再降级为「只保存原文，截图跳过」（方案决策点 6）。
  Future<Uint8List?> takeScreenshot({Map<String, double>? selectionRect}) async {
    // 选区截图：外扩 6px 留边，clamp 到非负（平台侧有 assert）。
    ScreenshotConfiguration? config;
    if (selectionRect != null) {
      final left = (selectionRect['left'] ?? 0.0).clamp(0.0, 100000.0) - 6;
      final top = (selectionRect['top'] ?? 0.0).clamp(0.0, 100000.0) - 6;
      final right = (selectionRect['right'] ?? 0.0).clamp(0.0, 100000.0) + 6;
      final bottom = (selectionRect['bottom'] ?? 0.0).clamp(0.0, 100000.0) + 6;
      final w = (right - left).clamp(1.0, 4096.0);
      final h = (bottom - top).clamp(1.0, 4096.0);
      if (w > 0 && h > 0) {
        config = ScreenshotConfiguration(
          rect: InAppWebViewRect(
            x: left.clamp(0.0, 4096.0),
            y: top.clamp(0.0, 4096.0),
            width: w,
            height: h,
          ),
          afterScreenUpdates: true,
        );
      }
    }
    try {
      final shot = await _controller?.takeScreenshot(
          screenshotConfiguration: config);
      if (shot != null && shot.isNotEmpty) return shot;
    } catch (e) {
      debugPrint('[Foliate] rect screenshot failed: $e');
    }
    // 降级：整页视口截图（rect 参数不支持时）。
    try {
      return await _controller?.takeScreenshot();
    } catch (e) {
      debugPrint('[Foliate] takeScreenshot failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    if (server == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return InAppWebView(
      key: const ValueKey('foliate-reader'),
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:${server.port}/host.html'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        supportZoom: false,
      ),
      shouldInterceptRequest: _intercept,
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'foliateEvent',
          callback: _onJsEvent,
        );
      },
      onLoadStop: (controller, url) {
        if (url != null && url.path.endsWith('/host.html')) {
          _openBook(controller);
        }
      },
      onConsoleMessage: (controller, message) {
        debugPrint('[FoliateJS] ${message.message}');
      },
    );
  }
}
