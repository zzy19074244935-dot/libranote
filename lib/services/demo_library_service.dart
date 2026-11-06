import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import 'storage_service.dart';

/// Installs the original sample once, preserving later annotations and progress.
class DemoLibraryService {
  static const bookId = 'libranote-welcome-v1';
  static Future<Book> open(StorageService storage) async {
    final existing = await storage.getBook(bookId);
    if (existing != null &&
        existing.localPath != null &&
        await File(existing.localPath!).exists()) {
      return existing;
    }
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'books'));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, 'libranote-welcome.md'));
    await file
        .writeAsString(await rootBundle.loadString('assets/demo/welcome.md'));
    final book = Book(
        id: bookId,
        hash: '',
        title: 'Libranote 使用体验',
        author: 'Libranote',
        extension: 'md',
        isLocal: true,
        localPath: file.path,
        downloadDate: DateTime.now());
    await storage.upsertBook(book);
    return book;
  }
}
