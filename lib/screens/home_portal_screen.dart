import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/demo_library_service.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/cover_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/today_study_card.dart';
import 'reader_screen.dart';

/// Reading dashboard with an offline sample and recent documents.
class HomePortalScreen extends ConsumerStatefulWidget {
  const HomePortalScreen({super.key});

  @override
  ConsumerState<HomePortalScreen> createState() => _HomePortalScreenState();
}

class _HomePortalScreenState extends ConsumerState<HomePortalScreen> {
  bool _openingDemo = false;

  Future<void> _openDemo() async {
    if (_openingDemo) return;
    setState(() => _openingDemo = true);
    try {
      final book =
          await DemoLibraryService.open(ref.read(storageServiceProvider));
      await ref.read(bookshelfProvider.notifier).loadBooks();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReaderScreen(book: book),
      ));
      if (mounted) ref.read(bookshelfProvider.notifier).loadBooks();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('示例打开失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingDemo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                Row(children: [
                  Expanded(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主页',
                          style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurface)),
                      const SizedBox(height: 6),
                      const _ClockText(),
                    ],
                  )),
                  const AppAvatar(),
                ]),
                const SizedBox(height: 24),
                Material(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _openingDemo ? null : _openDemo,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Icon(Icons.search_rounded,
                            size: 22, color: colors.primary),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('打开示例文档',
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(_openingDemo ? '正在打开…' : '离线体验阅读、批注与笔记',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant)),
                          ],
                        )),
                        Icon(Icons.arrow_forward_rounded,
                            size: 18, color: colors.onSurfaceVariant),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(builder: (context, constraints) {
                  final recent = _RecentBooksPanel(onOpened: () {
                    ref.read(bookshelfProvider.notifier).loadBooks();
                  });
                  if (constraints.maxWidth < 560 ||
                      MediaQuery.textScalerOf(context).scale(14) > 21) {
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const TodayStudyCard(),
                          const SizedBox(height: 16),
                          recent,
                        ]);
                  }
                  return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(flex: 3, child: TodayStudyCard()),
                        const SizedBox(width: 16),
                        Expanded(flex: 2, child: recent),
                      ]);
                }),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.auto_stories_rounded,
                          size: 32, color: colors.onPrimaryContainer),
                      const SizedBox(height: 12),
                      Text('让阅读留下思考',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: colors.onPrimaryContainer)),
                      const SizedBox(height: 8),
                      Text('从书架导入自己的文档，在阅读中记录、整理与回顾。',
                          style: TextStyle(color: colors.onPrimaryContainer)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 秒级实时日期时间（独立组件，只有它自己每秒重建）。
class _ClockText extends StatefulWidget {
  const _ClockText();

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  Timer? _timer;
  DateTime _now = DateTime.now();
  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final now = _now;
    return Text(
      '${now.month}月${now.day}日 · 星期${_weekdays[now.weekday - 1]} · ${_two(now.hour)}:${_two(now.minute)}',
      style: TextStyle(
          fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// 最近阅读面板：活跃日历右侧，显示最近读过的书 + 进度条。
class _RecentBooksPanel extends ConsumerWidget {
  final VoidCallback onOpened;

  const _RecentBooksPanel({required this.onOpened});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final shelf = ref.watch(bookshelfProvider).books;
    final recent = shelf
        .where(
            (b) => b.lastReadAt != null && (b.localPath?.isNotEmpty ?? false))
        .toList()
      ..sort((a, b) => (b.lastReadAt ?? b.downloadDate ?? DateTime(0))
          .compareTo(a.lastReadAt ?? a.downloadDate ?? DateTime(0)));

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '最近阅读',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有阅读记录，去书架打开一本书吧',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final book in recent.take(4)) ...[
              _RecentBookTile(
                book: book,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
                  );
                  onOpened();
                },
              ),
              if (book != recent.take(4).last) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _RecentBookTile extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;

  const _RecentBookTile({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = (book.progressPercent ?? 0).clamp(0, 100);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 34,
                  height: 46,
                  child: _cover(context, colors),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${book.progressPercent ?? 0}%',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress / 100,
              minHeight: 5,
              backgroundColor: colors.surfaceContainerHighest,
              color: colors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(BuildContext context, ColorScheme colors) {
    final ext = (book.extension ?? '').toLowerCase();
    if (ext == 'epub' || ext == 'pdf') {
      return FutureBuilder<String?>(
        future: CoverService.instance.getThumbnailPath(book.id),
        builder: (context, snap) {
          if (snap.hasData && snap.data != null) {
            return Image.file(
              File(snap.data!),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(colors),
            );
          }
          return _placeholder(colors);
        },
      );
    }
    return _placeholder(colors);
  }

  Widget _placeholder(ColorScheme colors) {
    return Container(
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        (book.extension ?? '').toLowerCase() == 'pdf'
            ? Icons.picture_as_pdf
            : Icons.menu_book,
        size: 18,
        color: colors.primary,
      ),
    );
  }
}
