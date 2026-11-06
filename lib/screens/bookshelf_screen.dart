import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/app_providers.dart';
import '../services/cover_service.dart';
import '../widgets/app_shell.dart';
import 'reader_screen.dart';

/// 切到「书架」Tab 时自增，强制书架重绘（封面提取完成后能立刻显示，
/// 不必等滚动触发重建）。
final shelfRefreshProvider = StateProvider<int>((ref) => 0);

/// Local bookshelf — downloaded books with import, sort, search, and management.
class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends ConsumerState<BookshelfScreen> {
  final _searchCtrl = TextEditingController();
  String _localQuery = '';

  // 格式筛选 + 文件夹归类。
  String _formatFilter = 'all';
  String _folderFilter = 'all'; // 'all' 全部 / 'none' 未分类 / 其它为文件夹名
  List<String> _folders = [];

  /// Tracks cover extraction completions per book ID.
  /// Incrementing forces [_BookCover] to recreate with a fresh [FutureBuilder].
  final Map<String, int> _coverVersions = {};

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    try {
      final folders = await ref.read(storageServiceProvider).getFolders();
      if (mounted) setState(() => _folders = folders);
    } catch (e) {
      debugPrint('[Shelf] load folders failed: $e');
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Book> _filterAndSort(
      List<Book> books, String sort, String query, String format,
      String folder) {
    var filtered = List<Book>.from(books);
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      filtered = filtered.where((b) =>
          b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q)).toList();
    }

    // 格式筛选。
    if (format != 'all') {
      const known = ['epub', 'pdf', 'txt', 'md', 'docx'];
      filtered = filtered.where((b) {
        final ext = (b.extension ?? '').toLowerCase();
        return format == 'other' ? !known.contains(ext) : ext == format;
      }).toList();
    }

    // 文件夹筛选。
    if (folder == 'none') {
      filtered = filtered.where((b) => b.folder.isEmpty).toList();
    } else if (folder.isNotEmpty && folder != 'all') {
      filtered = filtered.where((b) => b.folder == folder).toList();
    }

    switch (sort) {
      case 'title':
        filtered.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'author':
        filtered.sort((a, b) => a.author.compareTo(b.author));
        break;
      case 'added':
        filtered.sort((a, b) =>
            (b.downloadDate ?? DateTime(2000)).compareTo(
                a.downloadDate ?? DateTime(2000)));
        break;
      case 'recent':
      default:
        filtered.sort((a, b) =>
            (b.lastReadAt ?? b.downloadDate ?? DateTime(2000)).compareTo(
                a.lastReadAt ?? a.downloadDate ?? DateTime(2000)));
        break;
    }
    return filtered;
  }

  /// Extensions we accept from the file picker.
  ///
  /// Only `epub` and `pdf` have an in-app reader; the rest are stored so the
  /// user can open them elsewhere (see [_buildUnsupportedReader]).
  static const _importableExtensions = [
    'epub', 'pdf', 'txt', 'mobi', 'azw3', 'fb2', 'djvu', 'rtf', 'md', 'docx',
  ];

  Future<void> _importFile() async {
    String step = '选择文件';
    try {
      // FileType.any rather than FileType.custom: on Android 13+ the custom
      // filter maps extensions to MIME types and silently returns nothing for
      // the ones the system does not recognise (epub/azw3/fb2 among them).
      // Filtering by extension ourselves is the only reliable option.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;

      step = '检查文件格式';
      final ext = p.extension(file.name).replaceAll('.', '').toLowerCase();
      if (!_importableExtensions.contains(ext)) {
        _toast(ext.isEmpty
            ? '无法识别文件格式'
            : '不支持 .$ext 格式，支持 EPUB / PDF / TXT / MD / DOCX');
        return;
      }

      step = '读取文件内容';
      // On Android a picked document can arrive as a SAF `content://` URI with
      // no filesystem path. file_picker usually caches it for us, but when it
      // does not, the in-memory bytes are the only way through.
      Uint8List? bytes;
      final sourcePath = file.path;
      if (sourcePath == null || !await File(sourcePath).exists()) {
        bytes = file.bytes ?? await _readPickedBytes(file);
        if (bytes == null) {
          _toast('读不到这个文件，请把它复制到手机存储后重试');
          return;
        }
      }

      step = '创建书籍目录';
      final dir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(dir.path, 'books'));
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }

      step = '保存到书架目录';
      final safeName = file.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final destPath = p.join(booksDir.path, safeName);

      // Avoid overwriting
      String finalPath = destPath;
      int counter = 1;
      while (await File(finalPath).exists()) {
        final fileExt = p.extension(destPath);
        final base = p.basenameWithoutExtension(destPath);
        finalPath = p.join(booksDir.path, '$base ($counter)$fileExt');
        counter++;
      }

      if (bytes != null) {
        await File(finalPath).writeAsBytes(bytes, flush: true);
      } else {
        await File(sourcePath!).copy(finalPath);
      }

      step = '校验文件';
      final problem = await _validateBookFile(finalPath, ext);
      if (problem != null) {
        // Do not leave a broken file lying around in the books directory.
        try {
          await File(finalPath).delete();
        } catch (_) {}
        _toast(problem);
        return;
      }

      final title = p.basenameWithoutExtension(file.name);
      final size = await File(finalPath).length();

      step = '写入书架数据库';
      // 用文件内容指纹做稳定 id（而不是时间戳）：同一本书重复导入
      // 会得到同一个 id，批注/PDF 手写批注不会因为「重新导入」而
      // 变成另一个 bookId 下的孤儿数据（笔记消失的根因之一）。
      final bookId = _stableFileId(File(finalPath));
      final book = Book(
        id: bookId,
        hash: '',
        title: title,
        author: '导入的书籍',
        extension: ext,
        isLocal: true,
        localPath: finalPath,
        downloadDate: DateTime.now(),
        fileSize: size > 0 ? _formatSize(size) : null,
      );

      final storage = ref.read(storageServiceProvider);
      await storage.upsertBook(book);
      await ref.read(bookshelfProvider.notifier).loadBooks();

      // Cover extraction is best-effort and must not fail the import, so it
      // runs after the book is already on the shelf.
      if (ext == 'epub' || ext == 'pdf') {
        CoverService.instance
            .extractThumbnail(bookId: bookId, filePath: finalPath, format: ext)
            .then((_) {
          if (mounted) {
            setState(() {
              _coverVersions[bookId] = (_coverVersions[bookId] ?? 0) + 1;
            });
          }
        }).catchError((Object e) {
          debugPrint('[Import] cover extraction failed: $e');
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导入: ${book.title}'),
            action: SnackBarAction(
              label: '打开',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
                );
              },
            ),
          ),
        );
      }
    } catch (e, s) {
      debugPrint('[Import] failed at "$step": $e\n$s');
      // Naming the step matters: the previous version reported a bare
      // exception, which made a missing SQLite backend look like a file error.
      _toast('导入失败（$step）：$e');
    }
  }

  /// Last-resort read for a picked file that exposes no usable path.
  Future<Uint8List?> _readPickedBytes(PlatformFile file) async {
    final stream = file.readStream;
    if (stream == null) return null;
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (e) {
      debugPrint('[Import] read stream failed: $e');
      return null;
    }
  }

  /// Reject files that carry the right extension but the wrong content.
  ///
  /// A book "downloaded" while logged out is often the login page saved as
  /// `.epub`; opening it later fails deep inside the reader with a confusing
  /// message, so it is cheaper to check the magic bytes up front.
  Future<String?> _validateBookFile(String path, String ext) async {
    final file = File(path);
    final length = await file.length();
    if (length < 4) {
      return '文件太小（$length 字节），不是有效的文档';
    }

    final head = await file.openRead(0, 8).fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );

    switch (ext) {
      case 'epub':
        // EPUB is a ZIP container: "PK\x03\x04".
        if (head.length < 4 ||
            head[0] != 0x50 ||
            head[1] != 0x4B ||
            head[2] != 0x03 ||
            head[3] != 0x04) {
          return 'EPUB 文件已损坏（不是有效的 ZIP 容器）';
        }
        break;
      case 'pdf':
        if (head.length < 4 ||
            String.fromCharCodes(head.sublist(0, 4)) != '%PDF') {
          return 'PDF 文件已损坏（缺少 %PDF 文件头）';
        }
        break;
      case 'docx':
        // DOCX is also ZIP — but we additionally check that word/document.xml
        // exists inside the archive so we don't silently accept renamed .zip
        // files or corrupt EPUBs misnamed as .docx.
        if (head.length < 4 ||
            head[0] != 0x50 ||
            head[1] != 0x4B ||
            head[2] != 0x03 ||
            head[3] != 0x04) {
          return 'DOCX 文件已损坏（不是有效的 ZIP 容器）';
        }
        // Deeper check: open the ZIP and look for word/document.xml.
        try {
          final bytes = await file.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);
          if (archive.findFile('word/document.xml') == null) {
            return '不是有效的 DOCX 文件（缺少 word/document.xml）';
          }
        } catch (e) {
          return 'DOCX 文件已损坏：$e';
        }
        break;
      case 'txt':
      case 'md':
      case 'markdown':
        // Text files: must be at least 1 byte and decode as UTF-8 or GBK.
        if (length < 1) {
          return '文件是空的';
        }
        // Quick read of first 4 KB to verify it's readable text.
        try {
          final sample = await file.openRead(0, 4096).fold<List<int>>(
                <int>[],
                (acc, chunk) => acc..addAll(chunk),
              );
          try {
            // Try UTF-8 first.
            const Utf8Decoder(allowMalformed: false).convert(sample);
          } on FormatException {
            // Not UTF-8 — try GBK before rejecting.
            try {
              gbk.decode(sample);
            } catch (_) {
              return '无法识别文件编码，请用记事本另存为 UTF-8 后重新导入';
            }
          }
        } catch (e) {
          return '读取文件失败: $e';
        }
        break;
    }
    return null;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  /// 用文件内容指纹生成稳定 id：FNV-1a 64 位，采样文件头/尾各 64KB +
  /// 文件大小。同一文件重复导入 → 同一个 id → 批注与手写批注不丢。
  String _stableFileId(File file) {
    final raf = file.openSync();
    try {
      final size = raf.lengthSync();
      var hash = 0xcbf29ce484222325;
      void mix(int b) {
        hash ^= b & 0xff;
        hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      }

      void sample(int pos, int len) {
        if (len <= 0 || pos >= size) return;
        final realLen = (pos + len > size) ? size - pos : len;
        raf.setPositionSync(pos);
        final buf = raf.readSync(realLen);
        for (final b in buf) {
          mix(b);
        }
      }

      sample(0, 65536);
      if (size > 131072) sample(size - 65536, 65536);
      for (final b in '$size'.codeUnits) {
        mix(b);
      }
      return 'local_${hash.toRadixString(16)}';
    } finally {
      raf.closeSync();
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _confirmRemove(Book book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除《${book.title}》'),
        content: const Text('确定要删除这本书吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref.read(bookshelfProvider.notifier).removeBook(book.id);
      _loadFolders();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除《${book.title}》')),
        );
      }
    }
  }

  String? _localPathOf(Book book) {
    final path = book.localPath;
    if (path == null || !File(path).existsSync()) return null;
    return path;
  }

  /// 分享书到其它 App（QQ / 微信 / WPS 走系统分享面板）。
  Future<void> _shareBook(Book book) async {
    final path = _localPathOf(book);
    if (path == null) {
      _toast('这本书还没下载到本地，无法分享');
      return;
    }
    try {
      await ref.read(fileExportServiceProvider).shareFile(
            filePath: path,
            text: '《${book.title}》',
          );
    } catch (e) {
      _toast('分享失败: $e');
    }
  }

  /// 把书复制到系统「文件」App（公共 Downloads）。
  Future<void> _saveToFiles(Book book) async {
    final path = _localPathOf(book);
    if (path == null) {
      _toast('这本书还没下载到本地，无法保存');
      return;
    }
    final fileName = p.basename(path);
    final saved = await ref.read(fileExportServiceProvider).saveToDownloads(
          filePath: path,
          fileName: fileName,
        );
    _toast(saved != null ? '已保存到「文件」App' : '保存失败，请重试');
  }

  /// 长按弹出的操作菜单：阅读 / 分享 / 保存到文件 / 删除。
  Future<void> _showBookActions(Book book) async {
    final colors = Theme.of(context).colorScheme;
    final hasLocal = _localPathOf(book) != null;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('阅读'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('分享（QQ / 微信 / WPS）'),
              enabled: hasLocal,
              onTap: () {
                Navigator.pop(ctx);
                _shareBook(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存到「文件」App'),
              enabled: hasLocal,
              onTap: () {
                Navigator.pop(ctx);
                _saveToFiles(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('移动到文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                _moveToFolder(book);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: colors.error),
              title: Text('删除', style: TextStyle(color: colors.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmRemove(book);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shelf = ref.watch(bookshelfProvider);
    final colors = Theme.of(context).colorScheme;
    final viewMode = AppConfig.instance.bookshelfViewMode;
    final sort = AppConfig.instance.bookshelfSort;

    // 切到「书架」Tab 时重绘一次：封面提取是在下载/导入之后异步完成的，
    // IndexedStack 下本页常驻不会自己重建，不重绘封面会一直显示占位图。
    ref.listen(shelfRefreshProvider, (_, __) {
      if (mounted) setState(() {});
    });

    final filtered = _filterAndSort(
        shelf.books, sort, _localQuery, _formatFilter, _folderFilter);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            tooltip: '导入本地书籍',
            onPressed: _importFile,
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppAvatar()),
          ),
        ],
      ),
      // 右下角悬浮导入按钮——新用户一眼就能看到入口
      floatingActionButton: FloatingActionButton(
        onPressed: _importFile,
        tooltip: '导入本地书籍',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          // ── Search bar ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索书架...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: _localQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _localQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _localQuery = v),
            ),
          ),

          // ── Sort chips ───────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _sortChip('最近阅读', 'recent', sort),
                const SizedBox(width: 6),
                _sortChip('书名', 'title', sort),
                const SizedBox(width: 6),
                _sortChip('作者', 'author', sort),
                const SizedBox(width: 6),
                _sortChip('最近添加', 'added', sort),
                const SizedBox(width: 12),
                // View toggle
                IconButton(
                  icon: Icon(
                    viewMode == 'grid' ? Icons.list : Icons.grid_view,
                    size: 20,
                  ),
                  tooltip: viewMode == 'grid' ? '切换为列表' : '切换为网格',
                  onPressed: () {
                    setState(() {
                      AppConfig.instance.bookshelfViewMode =
                          viewMode == 'grid' ? 'list' : 'grid';
                    });
                  },
                ),
              ],
            ),
          ),

          // ── Format filter chips ──────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                _filterChip('全部格式', 'all'),
                _filterChip('EPUB', 'epub'),
                _filterChip('PDF', 'pdf'),
                _filterChip('TXT', 'txt'),
                _filterChip('MD', 'md'),
                _filterChip('DOCX', 'docx'),
                _filterChip('其他', 'other'),
              ],
            ),
          ),

          // ── Folder chips ─────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                _folderChip('全部', 'all', Icons.folder_open),
                _folderChip('未分类', 'none', Icons.folder_off_outlined),
                for (final f in _folders)
                  _folderChip(f, f, Icons.folder_outlined),
              ],
            ),
          ),

          const SizedBox(height: 4),
          Text('${filtered.length} 本书',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),

          // ── Load failure ─────────────────────────────────────────
          // Without this the shelf renders as merely "empty" when the
          // database cannot be opened at all, which is what hid the missing
          // desktop SQLite backend behind a blank page.
          if (shelf.errorMessage != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: colors.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      shelf.errorMessage!,
                      style: TextStyle(
                          fontSize: 12, color: colors.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(bookshelfProvider.notifier).loadBooks(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),

          // ── Book list / grid ─────────────────────────────────────
          Expanded(
            child: shelf.isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.library_books_outlined,
                                size: 64, color: colors.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text(
                              _localQuery.isNotEmpty ? '未找到匹配的书籍' : '书架为空',
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            if (_localQuery.isEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                '点右下角「＋」导入 EPUB / PDF / TXT / MD / DOCX\n'
                                '（MOBI / AZW3 / DJVU 不支持内置阅读）',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 13,
                                    height: 1.5),
                              ),
                            ],
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(bookshelfProvider.notifier).loadBooks(),
                        child: viewMode == 'grid'
                            ? _buildGrid(filtered, colors)
                            : _buildList(filtered, colors),
                      ),
          ),
        ],
      ),
    );
  }

  /// 统一的筛选 chip 样式：白色风格下与纸色背景区分开——
  /// 未选中 = 白底 + 描边 + 深色字；选中 = 主题色淡底 + 主题色描边 + 主题色字。
  Widget _sortChip(String label, String value, String current) {
    final colors = Theme.of(context).colorScheme;
    final selected = current == value;
    return FilterChip(
      label: Text(label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? colors.primary : colors.onSurface,
          )),
      selected: selected,
      onSelected: (_) {
        AppConfig.instance.bookshelfSort = value;
        setState(() {});
      },
      visualDensity: VisualDensity.compact,
      backgroundColor: colors.surface,
      selectedColor: colors.primaryContainer,
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
        width: selected ? 1.4 : 1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      showCheckmark: false,
    );
  }

  Widget _filterChip(String label, String value) {
    final colors = Theme.of(context).colorScheme;
    final selected = _formatFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? colors.primary : colors.onSurface,
            )),
        selected: selected,
        onSelected: (_) => setState(() => _formatFilter = value),
        visualDensity: VisualDensity.compact,
        backgroundColor: colors.surface,
        selectedColor: colors.primaryContainer,
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        showCheckmark: false,
      ),
    );
  }

  Widget _folderChip(String label, String value, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final selected = _folderFilter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        avatar: Icon(icon,
            size: 16,
            color: selected ? colors.primary : colors.onSurfaceVariant),
        label: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? colors.primary : colors.onSurface,
            )),
        selected: selected,
        onSelected: (_) => setState(() => _folderFilter = value),
        visualDensity: VisualDensity.compact,
        backgroundColor: colors.surface,
        selectedColor: colors.primaryContainer,
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        showCheckmark: false,
      ),
    );
  }

  // ── 文件夹归类 ─────────────────────────────────────────────────────

  Future<void> _applyFolder(Book book, String folder) async {
    await ref.read(storageServiceProvider).updateBookFolder(book.id, folder);
    await ref.read(bookshelfProvider.notifier).loadBooks();
    _loadFolders();
    if (mounted) {
      _toast(folder.isEmpty ? '已移出文件夹' : '已移动到「$folder」');
    }
  }

  Future<void> _moveToFolder(Book book) async {
    final folders = await ref.read(storageServiceProvider).getFolders();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('未分类'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, f),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建文件夹…'),
              onTap: () {
                Navigator.pop(ctx);
                _promptFolderName().then((name) {
                  if (name != null && name.isNotEmpty && mounted) {
                    _applyFolder(book, name);
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _applyFolder(book, chosen);
  }

  Future<String?> _promptFolderName() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '文件夹名',
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) return null;
    final name = ctrl.text.trim();
    return name.isEmpty ? null : name;
  }

  // ── Grid view ─────────────────────────────────────────────────────────

  Widget _buildGrid(List<Book> books, ColorScheme colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Wider thresholds than the old <400/700: a 2-column grid is usable
        // up to ~600 px on most phones, and 3 columns to ~900 px.
        final crossAxisCount = width < 600 ? 2 : width < 900 ? 3 : 4;
        final itemWidth = (width - (crossAxisCount - 1) * 10 - 24) / crossAxisCount;
        // image ~ square (itemWidth / 0.66 height) + 44 px for text labels.
        // This keeps the text from being squeezed out on narrow screens.
        final ratio = itemWidth / (itemWidth / 0.66 + 44);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: ratio,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            return _buildGridItem(book, colors);
          },
        );
      },
    );
  }

  Widget _buildGridItem(Book book, ColorScheme colors) {
    final ext = (book.extension ?? '').toUpperCase();
    final progress = book.progressPercent ?? 0;
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
        );
      },
      onLongPress: () => _showBookActions(book),
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _BookCover(
                    key: ValueKey(
                        'cover-${book.id}-${_coverVersions[book.id] ?? 0}'),
                    book: book,
                    colors: colors,
                  ),
                  // 格式角标。
                  if (ext.isNotEmpty)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          ext,
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  // 阅读进度叠在封面底部。
                  if (progress > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress / 100,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.35),
                        color: colors.primary,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
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

  // ── List view ─────────────────────────────────────────────────────────

  Widget _buildList(List<Book> books, ColorScheme colors) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return Slidable(
          startActionPane: ActionPane(
            motion: const ScrollMotion(),
            children: [
              SlidableAction(
                onPressed: (_) => _shareBook(book),
                backgroundColor: colors.primary,
                foregroundColor: colors.onPrimary,
                icon: Icons.share,
                label: '分享',
              ),
            ],
          ),
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            children: [
              SlidableAction(
                onPressed: (_) => _confirmRemove(book),
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
                icon: Icons.delete,
                label: '删除',
              ),
            ],
          ),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 64,
                child: _BookCover(
                  key: ValueKey('cover-${book.id}-${_coverVersions[book.id] ?? 0}'),
                  book: book,
                  colors: colors,
                ),
              ),
            ),
            title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              // Single-line: author + optional progress%.
              // A Column + LinearProgressIndicator here overflows the ListTile
              // height and triggers the yellow/black-stripe layout warning.
              book.progressPercent != null && book.progressPercent! > 0
                  ? '${book.author} · ${book.progressPercent}%'
                  : book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: ConstrainedBox(
              // A Row inside ListTile.trailing has unbounded width and will
              // red-screen when its children grow. Constrain it to give the
              // Chip + progress text a safe ceiling.
              constraints: const BoxConstraints(maxWidth: 96),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (book.extension != null)
                    Chip(
                      label: Text(book.extension!.toUpperCase(),
                          style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (book.progressPercent != null &&
                      book.progressPercent! > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text('${book.progressPercent}%',
                          style: TextStyle(
                              fontSize: 11, color: colors.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
              );
            },
            onLongPress: () => _showBookActions(book),
          ),
        );
      },
    );
  }

}

/// Lazily loads and displays a book cover thumbnail.
class _BookCover extends StatelessWidget {
  final Book book;
  final ColorScheme colors;

  const _BookCover({super.key, required this.book, required this.colors});

  @override
  Widget build(BuildContext context) {
    if (book.localPath == null) {
      // No local file — fall back to the network cover if we have one.
      return _networkCoverOrPlaceholder();
    }

    final ext = book.extension?.toLowerCase() ?? '';
    if (ext != 'epub' && ext != 'pdf') {
      return _networkCoverOrPlaceholder();
    }

    // 注意：future 每次 build 都新建，不缓存——封面提取在下载/导入之后
    // 异步完成，缓存 future 会让缩略图永远显示旧结果（封面「不显示」）。
    return FutureBuilder<String?>(
      future: CoverService.instance.getThumbnailPath(book.id),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return Image.file(
            File(snapshot.data!),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _networkCoverOrPlaceholder(),
          );
        }
        return _networkCoverOrPlaceholder();
      },
    );
  }

  /// 网络封面兜底（仅使用文档自身提供的封面地址）。
  Widget _networkCoverOrPlaceholder() {
    final url = book.coverUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        (book.extension?.toLowerCase() == 'pdf')
            ? Icons.picture_as_pdf
            : Icons.menu_book,
        size: 32,
        color: colors.primary,
      ),
    );
  }
}
