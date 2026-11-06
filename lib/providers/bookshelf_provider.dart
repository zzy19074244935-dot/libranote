import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/services.dart';
import 'app_providers.dart';

class BookshelfState {
  final List<Book> books;
  final bool isLoading;
  final String? errorMessage;

  const BookshelfState({
    this.books = const [],
    this.isLoading = false,
    this.errorMessage,
  });

  BookshelfState copyWith({
    List<Book>? books,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BookshelfState(
      books: books ?? this.books,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class BookshelfNotifier extends StateNotifier<BookshelfState> {
  final StorageService _storage;

  BookshelfNotifier(this._storage) : super(const BookshelfState()) {
    loadBooks();
  }

  Future<void> loadBooks() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 收养孤儿下载：后台下载完成但 App 已死时，文件在 books 目录但没入库。
      await _storage.adoptOrphanDownloads();
      final books = await _storage.getBookshelf();
      state = state.copyWith(books: books, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '加载书架失败: ${e.toString()}',
      );
    }
  }

  /// Update reading progress.
  Future<void> updateProgress(String bookId, int progress) async {
    await _storage.updateProgress(bookId, progress);
    // Update in-memory list
    state = state.copyWith(
      books: state.books.map((b) {
        if (b.id == bookId) {
          return b.copyWith(
            progressPercent: progress,
            lastReadAt: DateTime.now(),
          );
        }
        return b;
      }).toList(),
    );
  }

  /// Remove a book from the bookshelf.
  Future<void> removeBook(String bookId) async {
    await _storage.removeBook(bookId, deleteFile: true);
    state = state.copyWith(
      books: state.books.where((b) => b.id != bookId).toList(),
    );
  }
}

final bookshelfProvider =
    StateNotifierProvider<BookshelfNotifier, BookshelfState>((ref) {
  return BookshelfNotifier(
    ref.watch(storageServiceProvider),
  );
});
