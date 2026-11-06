import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/storage_service.dart';
import '../services/file_export_service.dart';

final storageServiceProvider = Provider<StorageService>((ref) {
  final storage = StorageService();
  ref.onDispose(() => storage.close());
  return storage;
});

final fileExportServiceProvider = Provider<FileExportService>((ref) {
  return FileExportService();
});
