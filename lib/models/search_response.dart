import 'book.dart';

/// Response from POST /eapi/book/search
class SearchResponse {
  final List<Book> books;
  final int totalResults;
  final int currentPage;
  final int totalPages;

  const SearchResponse({
    required this.books,
    required this.totalResults,
    required this.currentPage,
    required this.totalPages,
  });

  factory SearchResponse.fromJson(Map<String, dynamic> json) {
    final rawBooks = json['books'] as List<dynamic>? ?? [];
    final books = rawBooks
        .map((b) => Book.fromJson(b as Map<String, dynamic>))
        .toList();

    return SearchResponse(
      books: books,
      totalResults: json['total'] as int? ?? json['totalResults'] as int? ?? 0,
      currentPage: json['page'] as int? ?? json['currentPage'] as int? ?? 1,
      totalPages: json['totalPages'] as int? ?? 1,
    );
  }

  bool get hasMore => currentPage < totalPages;
}
