import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/services.dart';
import 'app_providers.dart';

/// Represents the current book being read.
class ReaderState {
  final Book? book;
  final String? localPath;
  final int progressPercent;
  final bool isLoading;
  final String? errorMessage;
  final List<Annotation> annotations;

  const ReaderState({
    this.book,
    this.localPath,
    this.progressPercent = 0,
    this.isLoading = false,
    this.errorMessage,
    this.annotations = const [],
  });

  ReaderState copyWith({
    Book? book,
    String? localPath,
    int? progressPercent,
    bool? isLoading,
    String? errorMessage,
    List<Annotation>? annotations,
    bool clearError = false,
  }) {
    return ReaderState(
      book: book ?? this.book,
      localPath: localPath ?? this.localPath,
      progressPercent: progressPercent ?? this.progressPercent,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      annotations: annotations ?? this.annotations,
    );
  }
}

class ReaderNotifier extends StateNotifier<ReaderState> {
  final StorageService _storage;

  ReaderNotifier(this._storage) : super(const ReaderState());

  /// Open a book for reading.
  Future<void> openBook(Book book) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final path = book.localPath;
      if (path == null || !File(path).existsSync()) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: '文件不存在，请重新下载',
        );
        return;
      }

      final annotations = await _storage.getAnnotations(book.id);

      state = state.copyWith(
        book: book,
        localPath: path,
        progressPercent: book.progressPercent ?? 0,
        annotations: annotations,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '打开书籍失败: ${e.toString()}',
      );
    }
  }

  /// Update reading progress (0-100).
  Future<void> updateProgress(int percent) async {
    if (state.book == null) return;
    final clamped = percent.clamp(0, 100);
    state = state.copyWith(progressPercent: clamped);
    await _storage.updateProgress(state.book!.id, clamped);
  }

  /// Add a highlight or note with a structured anchor.
  /// [imagePath] = 选区截图（先截图再高亮/记笔记时捆绑保存，§2.8 四要素）。
  Future<void> addAnnotation({
    required TextAnchor anchor,
    required String quotedText,
    String note = '',
    AnnotationType type = AnnotationType.highlight,
    String? color,
    String style = 'highlight',
    String? imagePath,
  }) async {
    if (state.book == null) return;

    final annotation = Annotation(
      bookId: state.book!.id,
      bookTitle: state.book!.title,
      type: type,
      anchor: anchor,
      quotedText: quotedText,
      note: note,
      color: color,
      style: style,
      imagePath: imagePath,
    );

    final id = await _storage.insertAnnotation(annotation);
    state = state.copyWith(
      annotations: [...state.annotations, annotation.copyWith(id: id)],
    );
  }

  /// Delete an annotation.
  Future<void> deleteAnnotation(int id) async {
    await _storage.deleteAnnotation(id);
    state = state.copyWith(
      annotations: state.annotations.where((a) => a.id != id).toList(),
    );
  }

  /// Replace the in-memory annotation list（批注面板从 DB 现读后同步回内存，
  /// 让正文高亮渲染与笔记中心保持一致）。
  void setAnnotations(List<Annotation> annotations) {
    state = state.copyWith(annotations: annotations);
  }

  /// Close the reader.
  void close() {
    state = const ReaderState();
  }
}

final readerProvider = StateNotifierProvider<ReaderNotifier, ReaderState>((ref) {
  return ReaderNotifier(ref.watch(storageServiceProvider));
});
