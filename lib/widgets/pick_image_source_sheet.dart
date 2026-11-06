import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/shot_library.dart';

/// 图片来源选择（画布 / PDF / Word 插入图片共用）：
/// 设备相册 或 App 截图库。
enum PickImageSource { gallery, shotLibrary }

/// 弹「插入图片来源」底部弹层：设备相册 / App 截图库。
/// 返回 null = 用户取消。
Future<PickImageSource?> showPickImageSourceSheet(BuildContext context) async {
  return showModalBottomSheet<PickImageSource>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('插入图片',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从 App 截图库选择'),
              subtitle: const Text('阅读器/画布截的图都在这里（含随笔记保存的选区截图）'),
              onTap: () => Navigator.pop(ctx, PickImageSource.shotLibrary),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('从设备相册选择'),
              subtitle: const Text('打开系统相册选一张图片'),
              onTap: () => Navigator.pop(ctx, PickImageSource.gallery),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
}

/// App 截图库选择器：缩略图网格，点选返回文件路径；null = 取消/无图。
Future<String?> showShotLibraryPicker(BuildContext context) async {
  final shots = await ShotLibrary.instance.listShots();
  if (!context.mounted) return null;
  if (shots.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('截图库还是空的，先截几张图吧（阅读器/画布顶栏的截图键）')),
    );
    return null;
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('从 App 截图库插入',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 110,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: shots.length,
                itemBuilder: (ctx, i) {
                  final f = shots[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(ctx, f.path),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              f,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (_, __, ___) => Container(
                                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          p.basenameWithoutExtension(f.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 组合入口：来源选择 → 返回图片文件路径（相册选图 / 截图库选图）。
/// null = 取消。
Future<String?> pickImagePathFromSource(BuildContext context) async {
  final source = await showPickImageSourceSheet(context);
  if (source == null || !context.mounted) return null;
  switch (source) {
    case PickImageSource.shotLibrary:
      return showShotLibraryPicker(context);
    case PickImageSource.gallery:
      return ShotLibrary.instance.pickLocalImage();
  }
}

/// 把 [path] 读成字节（空/失败返回 null）。
Future<Uint8List?> readImageBytes(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}
