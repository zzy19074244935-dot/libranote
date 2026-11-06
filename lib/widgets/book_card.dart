import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/book.dart';

/// A card widget for displaying a book in a grid.
///
/// 参考稿风格：纯白卡片 + 发丝描边 + 极淡投影 + 圆角 16，点按有水波纹。
class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;

  const BookCard({super.key, required this.book, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cover image
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  book.coverUrl != null && book.coverUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: book.coverUrl!,
                          fit: BoxFit.cover,
                          // The image CDN may check the Referer header and return
                          // a placeholder/403 for cross-origin requests.
                                            placeholder: (_, __) => _titlePlaceholder(book, colors),
                          errorWidget: (_, __, ___) => _titlePlaceholder(book, colors),
                        )
                      : _titlePlaceholder(book, colors),
                  // 格式角标。
                  if (book.extension != null && book.extension!.isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          book.extension!.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Title + author
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      letterSpacing: -0.1,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// First character of the title on a stable tinted background.
  ///
  /// Both "no cover" and "image failed to load" land here. The background
  /// colour is derived from [Book.id.hashCode] so the same book always gets
  /// the same tint — this makes the shelf visually scannable even when covers
  /// are missing, unlike a uniform grey placeholder.
  static Widget _titlePlaceholder(Book book, ColorScheme colors) {
    final seed = book.id.hashCode.abs();
    // Pick a hue that stays readable on any background.
    final bg = Color.fromARGB(
      40,
      (seed % 156) + 50, // R
      ((seed ~/ 156) % 156) + 50, // G
      ((seed ~/ 24336) % 156) + 50, // B
    );
    final firstChar = book.title.isNotEmpty ? book.title.characters.first : '?';
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: Text(
        firstChar,
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: colors.primary.withAlpha(160),
        ),
      ),
    );
  }
}
