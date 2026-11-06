import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/reader_settings_provider.dart';

/// 阅读设置（更多设置入口版）：复用 readerSettingsProvider，
/// 与阅读器内「Aa」面板同一份数据、同一套持久化。
class ReadingSettingsScreen extends ConsumerStatefulWidget {
  const ReadingSettingsScreen({super.key});

  @override
  ConsumerState<ReadingSettingsScreen> createState() =>
      _ReadingSettingsScreenState();
}

class _ReadingSettingsScreenState extends ConsumerState<ReadingSettingsScreen> {
  double? _fontSize;
  double? _lineHeight;
  double? _pageMargin;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    final notifier = ref.read(readerSettingsProvider.notifier);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('阅读设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _slider(
            context,
            title: '字号',
            value: _fontSize ?? settings.fontSize,
            min: 14,
            max: 28,
            divisions: 14,
            display: '${(_fontSize ?? settings.fontSize).round()}',
            onChanged: (v) => setState(() => _fontSize = v),
            onChangeEnd: (v) async {
              await notifier.setFontSize(v);
              setState(() => _fontSize = null);
            },
          ),
          _slider(
            context,
            title: '行距',
            value: _lineHeight ?? settings.lineHeight,
            min: 1.4,
            max: 2.2,
            divisions: 8,
            display: (_lineHeight ?? settings.lineHeight).toStringAsFixed(1),
            onChanged: (v) => setState(() => _lineHeight = v),
            onChangeEnd: (v) async {
              await notifier.setLineHeight(v);
              setState(() => _lineHeight = null);
            },
          ),
          _slider(
            context,
            title: '页边距',
            value: _pageMargin ?? settings.pageMargin,
            min: 12,
            max: 40,
            divisions: 28,
            display: '${(_pageMargin ?? settings.pageMargin).round()}',
            onChanged: (v) => setState(() => _pageMargin = v),
            onChangeEnd: (v) async {
              await notifier.setPageMargin(v);
              setState(() => _pageMargin = null);
            },
          ),
          const SizedBox(height: 8),

          // ── 主题 ──────────────────────────────────────────────
          Text('阅读主题', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _themeChip(context, '日间 ☀️', 'day', const Color(0xFFFFFFFF),
                  settings.theme, notifier),
              _themeChip(context, '夜间 🌙', 'night', const Color(0xFF121212),
                  settings.theme, notifier),
              _themeChip(context, '纸黄 📜', 'sepia', const Color(0xFFF5ECD9),
                  settings.theme, notifier),
            ],
          ),
          const SizedBox(height: 16),

          // ── 开关 ──────────────────────────────────────────────
          SwitchListTile(
            title: const Text('衬线字体'),
            subtitle: const Text('正文使用衬线（宋体风格）字体'),
            value: settings.useSerif,
            onChanged: (v) => notifier.setUseSerif(v),
          ),
          SwitchListTile(
            title: const Text('点击翻页'),
            subtitle: const Text('点屏幕左右 1/3 翻页（非沉浸模式下生效）'),
            value: settings.tapToTurn,
            onChanged: (v) => notifier.setTapToTurn(v),
          ),
          SwitchListTile(
            title: const Text('沉浸式阅读'),
            subtitle: const Text('隐藏顶栏底栏，点屏幕中间唤出'),
            value: settings.immersive,
            onChanged: (v) => notifier.setImmersive(v),
          ),
          const SizedBox(height: 12),
          Text(
            '这些设置与阅读器右上角「Aa」面板完全同步，改动实时生效。',
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: Theme.of(context).textTheme.titleMedium),
              Text(display, style: const TextStyle(fontSize: 12)),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }

  Widget _themeChip(
    BuildContext context,
    String label,
    String value,
    Color preview,
    String current,
    ReaderSettingsNotifier notifier,
  ) {
    final selected = current == value;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => notifier.setTheme(value),
      child: Container(
        width: 96,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: preview,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : const Color(0xFFE2E8F0),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.25),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: value == 'night'
                ? const Color(0xFFC8C8C8)
                : value == 'sepia'
                    ? const Color(0xFF5B4636)
                    : const Color(0xFF0F172A),
          ),
        ),
      ),
    );
  }
}
