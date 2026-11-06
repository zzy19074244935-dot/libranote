import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/appearance.dart';

/// 外观总设置：主题模式（浅色/深色/跟随系统）+ 主色调 + 自定义 App 背景。
///
/// 直接改 appearanceProvider —— app.dart 订阅它即时重建 MaterialApp。
class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  /// 预设主色调（App 参考稿的柔和配色 + 经典色）。
  static const seeds = <(String, Color)>[
    ('青绿（默认）', Color(0xFF1B5E5E)),
    ('靛蓝', Color(0xFF3B5BDB)),
    ('墨蓝', Color(0xFF0F172A)),
    ('绛紫', Color(0xFF7C3AED)),
    ('玫红', Color(0xFFC0265A)),
    ('琥珀', Color(0xFFB45309)),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('外观总设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('主题模式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: appearance.mode,
            onChanged: (v) {
              if (v != null) {
                ref.read(appearanceProvider.notifier).setMode(v);
              }
            },
            child: const Column(
              children: [
                RadioListTile<String>(
                  value: 'light',
                  title: Text('浅色（默认，简约柔和白）'),
                  contentPadding: EdgeInsets.zero,
                ),
                RadioListTile<String>(
                  value: 'dark',
                  title: Text('深色'),
                  contentPadding: EdgeInsets.zero,
                ),
                RadioListTile<String>(
                  value: 'system',
                  title: Text('跟随系统'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          const Divider(height: 28),
          Text('主色调', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('改动立刻全局生效（按钮/图标/强调色一起变）',
              style: TextStyle(
                  fontSize: 12.5, color: colors.onSurfaceVariant)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, color) in seeds)
                _seedChip(context, ref, label, color, appearance.seedColor),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '深色主题此前未跟进参考稿设计（历史原因锁定浅色），'
            '若观感有瑕疵请反馈，后续版本打磨。',
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
          ),
          const Divider(height: 28),
          // ── 自定义 App 背景 ────────────────────────────────────
          Text('自定义 App 背景',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '选择一张图片作为整个 App 的背景（页面会盖一层半透明白保持可读性）。'
            '图片保存在 App 内并随云同步备份。',
            style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _backgroundCard(context, ref, appearance),
        ],
      ),
    );
  }

  /// 背景设置卡：预览 + 选择/清除。
  Widget _backgroundCard(BuildContext context, WidgetRef ref,
      AppearanceSettings appearance) {
    final path = appearance.backgroundImagePath;
    final hasBg = path != null && path.isNotEmpty && File(path).existsSync();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 96,
                    height: 64,
                    color: const Color(0xFFF1F5F9),
                    child: hasBg
                        ? Image.file(File(path),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.grey))
                        : const Center(
                            child: Text('默认背景',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey))),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasBg ? '已设置自定义背景' : '未设置（使用主题默认背景）',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36)),
                  icon: const Icon(Icons.add_photo_alternate_outlined,
                      size: 16),
                  label: const Text('选择背景图片',
                      style: TextStyle(fontSize: 12)),
                  onPressed: () => _pickBackground(context, ref),
                ),
                if (hasBg)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36)),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('清除背景',
                        style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      final old = appearance.backgroundImagePath;
                      await ref
                          .read(appearanceProvider.notifier)
                          .setBackgroundImage(null);
                      if (old != null && old.isNotEmpty) {
                        try {
                          final f = File(old);
                          if (await f.exists()) await f.delete();
                        } catch (_) {}
                      }
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 选图 → 复制到 Documents/appearance/ → 应用为全局背景。
  Future<void> _pickBackground(BuildContext context, WidgetRef ref) async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 2400,
      );
      if (file == null || !context.mounted) return;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'appearance'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = p.extension(file.path).isEmpty
          ? '.jpg'
          : p.extension(file.path).toLowerCase();
      final target = p.join(dir.path, 'background$ext');
      // 覆盖旧背景文件（同名扩展名不同时清掉旧的）。
      try {
        for (final f in dir.listSync().whereType<File>()) {
          if (p.basename(f.path).startsWith('background') &&
              f.path != target) {
            await f.delete();
          }
        }
      } catch (_) {}
      await File(file.path).copy(target);
      await ref.read(appearanceProvider.notifier).setBackgroundImage(target);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('背景已更新'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置背景失败: $e')),
        );
      }
    }
  }

  Widget _seedChip(BuildContext context, WidgetRef ref, String label,
      Color color, int current) {
    final selected = color.toARGB32() == current;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => ref
          .read(appearanceProvider.notifier)
          .setSeedColor(color.toARGB32()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFFE2E8F0),
                width: selected ? 3 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
