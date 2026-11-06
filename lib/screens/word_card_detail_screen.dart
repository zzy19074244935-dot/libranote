import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/word_card.dart';
import '../providers/providers.dart';

/// 单词卡片详情：大图 + 单词/音标/释义 + 英音/美音朗读。
class WordCardDetailScreen extends ConsumerStatefulWidget {
  final WordCard card;

  const WordCardDetailScreen({super.key, required this.card});

  @override
  ConsumerState<WordCardDetailScreen> createState() =>
      _WordCardDetailScreenState();
}

class _WordCardDetailScreenState extends ConsumerState<WordCardDetailScreen> {
  final AudioPlayer _player = AudioPlayer();

  /// 当前正在播放的音频：'uk' / 'us' / null。
  String? _playing;

  @override
  void initState() {
    super.initState();
    // 播放完成/失败都复位按钮状态。
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _play(String which) async {
    final card = widget.card;
    final path = which == 'uk' ? card.ukAudioPath : card.usAudioPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      _toast('这段发音还没有下载成功，可以重新生成一张卡片');
      return;
    }
    setState(() => _playing = which);
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(path));
    } catch (e) {
      debugPrint('[WordCard] play $which failed: $e');
      if (mounted) {
        setState(() => _playing = null);
        _toast('播放失败: $e');
      }
    }
  }

  Future<void> _delete() async {
    final card = widget.card;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除卡片'),
        content: Text('确定删除「${card.englishWord}」这张卡片吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || card.id == null || !mounted) return;
    await _player.stop();
    await ref
        .read(storageServiceProvider)
        .deleteWordCard(card.id!, deleteFiles: true);
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final card = widget.card;

    return Scaffold(
      appBar: AppBar(
        title: Text(card.englishWord),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除卡片',
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 卡片大图 ────────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE8EDF3)),
            ),
            clipBehavior: Clip.antiAlias,
            child: card.hasLocalImage
                ? Image.file(
                    File(card.cardImagePath!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      height: 260,
                      alignment: Alignment.center,
                      child: Icon(Icons.broken_image_outlined,
                          size: 48, color: colors.onSurfaceVariant),
                    ),
                  )
                : Container(
                    height: 260,
                    alignment: Alignment.center,
                    child: Icon(Icons.image_outlined,
                        size: 48, color: colors.onSurfaceVariant),
                  ),
          ),
          const SizedBox(height: 16),

          // ── 单词 + 中文 ─────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  card.englishWord,
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w900),
                ),
              ),
              if (card.chineseWord.isNotEmpty)
                Text(
                  card.chineseWord,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // ── 音标 ───────────────────────────────────────────────
          if (card.ukPhonetic.isNotEmpty || card.usPhonetic.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                [
                  if (card.ukPhonetic.isNotEmpty) '英 /${card.ukPhonetic}/',
                  if (card.usPhonetic.isNotEmpty) '美 /${card.usPhonetic}/',
                ].join('    '),
                style: const TextStyle(
                    fontSize: 15,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 16),

          // ── 发音按钮 ───────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed:
                      card.ukAudioPath == null ? null : () => _play('uk'),
                  icon: Icon(
                      _playing == 'uk'
                          ? Icons.graphic_eq
                          : Icons.volume_up_outlined,
                      size: 20),
                  label: Text(_playing == 'uk' ? '播放中…' : '英式发音'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed:
                      card.usAudioPath == null ? null : () => _play('us'),
                  icon: Icon(
                      _playing == 'us'
                          ? Icons.graphic_eq
                          : Icons.volume_up_outlined,
                      size: 20),
                  label: Text(_playing == 'us' ? '播放中…' : '美式发音'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── 释义 ───────────────────────────────────────────────
          if (card.definition.isNotEmpty) ...[
            _SectionTitle(colors: colors, title: '英文释义'),
            Text(card.definition,
                style: const TextStyle(fontSize: 15, height: 1.6)),
            const SizedBox(height: 14),
          ],
          if (card.chineseDefinition.isNotEmpty) ...[
            _SectionTitle(colors: colors, title: '中文释义'),
            Text(card.chineseDefinition,
                style: const TextStyle(fontSize: 15, height: 1.6)),
            const SizedBox(height: 14),
          ],
          _SectionTitle(
              colors: colors,
              title: '生成时间 · '
                  '${card.createdAt.year}-${card.createdAt.month.toString().padLeft(2, '0')}-${card.createdAt.day.toString().padLeft(2, '0')} '
                  '${card.createdAt.hour.toString().padLeft(2, '0')}:${card.createdAt.minute.toString().padLeft(2, '0')}'),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final ColorScheme colors;
  final String title;

  const _SectionTitle({required this.colors, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
