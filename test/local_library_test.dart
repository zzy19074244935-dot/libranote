import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:libranote/services/demo_library_service.dart';
import 'package:libranote/services/storage_service.dart';

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late StorageService storage;
  late PathProviderPlatform originalPaths;
  setUp(() async {
    originalPaths = PathProviderPlatform.instance;
    directory =
        await Directory.systemTemp.createTemp('libranote_library_test_');
    PathProviderPlatform.instance = _Paths(directory.path);
    storage = StorageService();
  });
  tearDown(() async {
    await storage.close();
    PathProviderPlatform.instance = originalPaths;
    final temp = Directory.systemTemp.absolute.path;
    if (directory.absolute.path
        .startsWith('$temp${Platform.pathSeparator}libranote_library_test_')) {
      await directory.delete(recursive: true);
    }
  });

  test('fresh installation can persist daily study time', () async {
    final day = DateTime(2026, 11, 6);
    await storage.addUsageSeconds(day, 90);
    final rows = await storage.getUsageDays(day, day);
    expect(rows.single.seconds, 90);
  });

  test('version 17 database without usage_days is repaired on upgrade',
      () async {
    final db = await storage.database;
    await db.execute('DROP TABLE usage_days');
    await db.execute('PRAGMA user_version = 17');
    await storage.close();
    storage = StorageService();
    final day = DateTime(2026, 11, 6);
    await storage.addUsageSeconds(day, 42);
    expect((await storage.getUsageDays(day, day)).single.seconds, 42);
  });

  test(
      'opening the offline sample twice preserves progress and avoids duplicates',
      () async {
    final book = await DemoLibraryService.open(storage);
    expect(await File(book.localPath!).exists(), isTrue);
    expect(
        await File(book.localPath!).readAsString(), contains('Libranote 使用体验'));
    await storage.updateProgress(book.id, 37);
    final reopened = await DemoLibraryService.open(storage);
    expect(reopened.progressPercent, 37);
    expect(await storage.getBookshelf(), hasLength(1));
  });
}
