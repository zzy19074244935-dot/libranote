import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:libranote/config/app_config.dart';
import 'package:libranote/config/theme.dart';
import 'package:libranote/providers/app_providers.dart';
import 'package:libranote/screens/home_screen.dart';
import 'package:libranote/widgets/app_shell.dart';
import 'package:libranote/services/storage_service.dart';
import 'support/ui_storage.dart';
import 'package:libranote/app.dart';

const _previewDir = String.fromEnvironment('UI_SCREENSHOT_DIR');

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

Future<void> _preview(WidgetTester tester, String name) async {
  if (_previewDir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory(_previewDir);
      await dir.create(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  late Directory testDir;
  late StorageService storage;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    originalPaths = PathProviderPlatform.instance;
    testDir = await Directory.systemTemp.createTemp('libranote_ui_');
    PathProviderPlatform.instance = _Paths(testDir.path);
    storage = UiStorage();
    await AppConfig.instance.init();
    if (_previewDir.isNotEmpty) {
      for (final family in ['UiPreview', 'Ahem', 'Roboto']) {
        final font = FontLoader(family);
        font.addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
        await font.load();
      }
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  tearDownAll(() async {
    await storage.close();
    PathProviderPlatform.instance = originalPaths;
    final root = Directory.systemTemp.absolute.path;
    if (testDir.absolute.path
        .startsWith('$root${Platform.pathSeparator}libranote_ui_')) {
      await testDir.delete(recursive: true);
    }
  });

  testWidgets('cold start opens the local dashboard without an account', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
      child: const LibranoteApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('打开示例文档'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 390.0, 768.0]) {
    testWidgets('悬浮导航 ${width.toInt()} 宽：安全区留白与六个入口可点击', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                  body: const Align(
                      alignment: Alignment.bottomCenter,
                      child: Text('正文底部', key: ValueKey('last-content'))),
                  bottomNavigationBar: AppBottomNav(
                      currentIndex: selected,
                      onSelect: (index) => setState(() => selected = index)),
                )),
      ));
      final rect =
          tester.getRect(find.byKey(const ValueKey('floating-nav-surface')));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(width - 16));
      expect(rect.bottom, lessThanOrEqualTo(844 - 34));
      expect(tester.getRect(find.byKey(const ValueKey('last-content'))).bottom,
          lessThanOrEqualTo(rect.top));
      for (final label in ['书架', '笔记', 'AI', '画布', '我的', '主页']) {
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      }
      expect(selected, 0);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('手机六模块、键盘和${dark ? '深' : '浅'}色主题', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      var theme = dark ? AppTheme.dark() : AppTheme.light();
      if (_previewDir.isNotEmpty) {
        theme = theme.copyWith(
            appBarTheme: theme.appBarTheme.copyWith(
              titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'UiPreview'),
            ),
            chipTheme: theme.chipTheme.copyWith(
              labelStyle: theme.chipTheme.labelStyle?.copyWith(fontFamily: 'UiPreview'),
            ),
            textTheme: theme.textTheme.apply(fontFamily: 'UiPreview'),
            primaryTextTheme:
                theme.primaryTextTheme.apply(fontFamily: 'UiPreview'));
      }
      await tester.pumpWidget(ProviderScope(
          overrides: [storageServiceProvider.overrideWithValue(storage)],
          child: RepaintBoundary(
            key: const ValueKey('preview'),
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                home: const HomeScreen()),
          )));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await _preview(tester, dark ? 'home-dark' : 'home-light');
      for (final label in ['书架', '笔记', 'AI', '画布', '我的']) {
        await tester.tap(find.descendant(
            of: find.byType(AppBottomNav), matching: find.text(label)));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull, reason: label);
        if (label == 'AI') {
          await _preview(tester, dark ? 'ai-dark' : 'ai-light');
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AppBottomNav), findsNothing);
          expect(tester.takeException(), isNull, reason: '键盘弹出');
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AppBottomNav), findsOneWidget);
        }
      }
      await _preview(tester, dark ? 'profile-dark' : 'profile-light');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('窄屏大字号导航不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.6)),
        child: child!,
      ),
      home: Scaffold(
          bottomNavigationBar: AppBottomNav(currentIndex: 0, onSelect: (_) {})),
    ));
    expect(tester.takeException(), isNull);
  });
}
