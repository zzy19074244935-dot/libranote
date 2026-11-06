import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../providers/app_providers.dart';
import 'shot_library.dart';

/// 截图去向。
enum ShotAction { saveLocal, saveLibrary, insert, cancel }

/// 框选截图后的去向选择与保存逻辑（PDF / Word / 画布三处共用）。
class ShotActions {
  ShotActions._();

  /// 弹「截图下一步」面板：保存到本机下载 / 保存到截图库 / 插入当前文件。
  static Future<ShotAction> pick(BuildContext context,
      {bool canInsert = false}) async {
    final choice = await showModalBottomSheet<ShotAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('截图下一步',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存到本机下载'),
              subtitle: const Text('系统「文件」App 下载目录里可见'),
              onTap: () => Navigator.pop(ctx, ShotAction.saveLocal),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('保存到截图库'),
              subtitle: const Text('App 内截图库（设置 → 截图库查看）'),
              onTap: () => Navigator.pop(ctx, ShotAction.saveLibrary),
            ),
            if (canInsert)
              ListTile(
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: const Text('插入当前文件'),
                subtitle: const Text('作为图片插入正在编辑的 PDF / Word / 画布'),
                onTap: () => Navigator.pop(ctx, ShotAction.insert),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx, ShotAction.cancel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    return choice ?? ShotAction.cancel;
  }

  /// 保存到系统下载目录（文件 App 可见），返回是否成功。
  static Future<bool> saveToLocal(
      BuildContext context, WidgetRef ref, Uint8List png,
      {String prefix = 'shot'}) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(
          dir.path,
          '${prefix}_${DateTime.now().millisecondsSinceEpoch}.png'));
      await file.writeAsBytes(png, flush: true);
      final export = ref.read(fileExportServiceProvider);
      final saved = await export.saveToDownloads(
          filePath: file.path, fileName: p.basename(file.path));
      return saved != null && saved.isNotEmpty;
    } catch (e) {
      debugPrint('[Shot] save local failed: $e');
      return false;
    }
  }

  /// 保存到 App 截图库（Documents/shots/，设置里可查看）。
  static Future<String?> saveToLibrary(Uint8List png,
      {String prefix = 'shot'}) {
    return ShotLibrary.instance.savePng(png, prefix: prefix);
  }
}
