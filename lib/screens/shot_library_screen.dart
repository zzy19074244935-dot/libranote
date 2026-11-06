import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/file_export_service.dart';
import '../services/shot_library.dart';

/// App 截图库（设置 → 截图库）：阅读器/画布框选截图统一存在这里。
///
/// 能力：网格浏览、点开大图、分享、删除；数据来自 Documents/shots/。
class ShotLibraryScreen extends StatefulWidget {
  const ShotLibraryScreen({super.key});

  @override
  State<ShotLibraryScreen> createState() => _ShotLibraryScreenState();
}

class _ShotLibraryScreenState extends State<ShotLibraryScreen> {
  List<File>? _shots;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shots = await ShotLibrary.instance.listShots();
    if (mounted) setState(() => _shots = shots);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _view(File f) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.basename(f.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.file(
                  f,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 200,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                    onPressed: () async {
                      try {
                        if (f.existsSync()) f.deleteSync();
                      } catch (_) {}
                      Navigator.pop(ctx);
                      _toast('已删除');
                      _load();
                    },
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40)),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('分享'),
                    onPressed: () async {
                      try {
                        await FileExportService()
                            .shareFile(filePath: f.path);
                      } catch (e) {
                        _toast('分享失败: $e');
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shots = _shots;
    return Scaffold(
      appBar: AppBar(title: const Text('截图库')),
      body: shots == null
          ? const Center(child: CircularProgressIndicator())
          : shots.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_library_outlined,
                          size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('截图库还是空的',
                          style: TextStyle(color: Colors.grey)),
                      SizedBox(height: 4),
                      Text('在 PDF / Word / 画布里点「框选截图」→「保存到截图库」',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: shots.length,
                  itemBuilder: (_, i) {
                    final f = shots[i];
                    return GestureDetector(
                      onTap: () => _view(f),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          f,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.black12,
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
