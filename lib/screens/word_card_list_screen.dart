import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';
import '../models/word_card.dart';
import '../providers/providers.dart';
import '../widgets/app_shell.dart';
import 'word_card_create_screen.dart';
import 'word_card_detail_screen.dart';

/// 单词卡片库：拍照生成的卡片列表，支持查看、朗读、删除。
class WordCardListScreen extends ConsumerStatefulWidget {
  const WordCardListScreen({super.key});

  @override
  ConsumerState<WordCardListScreen> createState() =>
      _WordCardListScreenState();
}

class _WordCardListScreenState extends ConsumerState<WordCardListScreen> {
  List<WordCard>? _cards;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cards =
          await ref.read(storageServiceProvider).getWordCards();
      if (mounted) setState(() => _cards = cards);
    } catch (e) {
      debugPrint('[WordCard] load failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  // ── 操作 ───────────────────────────────────────────────────────────

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WordCardCreateScreen()),
    );
    if (created == true) _load();
  }

  Future<void> _openDetail(WordCard card) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WordCardDetailScreen(card: card)),
    );
    _load();
  }

  Future<void> _delete(WordCard card) async {
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
    await ref
        .read(storageServiceProvider)
        .deleteWordCard(card.id!, deleteFiles: true);
    _load();
  }

  /// 设置：函数公网 URL + APP_TOKEN（应用内可改，无需重编译）。
  Future<void> _openSettings() async {
    final urlCtrl = TextEditingController(
        text: AppConfig.instance.wordCardFunctionUrl);
    final tokenCtrl = TextEditingController(
        text: AppConfig.instance.wordCardAppToken);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('单词卡片服务设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('火山函数计算 HTTP 触发器的公网地址（不带 /create_card）'),
              const SizedBox(height: 6),
              TextField(
                controller: urlCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://xxx.volces.com',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              ),
              const SizedBox(height: 14),
              const Text('APP_TOKEN（与函数环境变量保持一致）'),
              const SizedBox(height: 6),
              TextField(
                controller: tokenCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: 'your_secure_token',
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '密钥只存在函数环境变量，App 里只需要函数地址和这个约定 Token。',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppConfig.instance.wordCardFunctionUrl = urlCtrl.text;
    AppConfig.instance.wordCardAppToken = tokenCtrl.text;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('单词卡片'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '服务设置',
            onPressed: _openSettings,
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: AppAvatar()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreate,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('拍照生成'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_cards?.isEmpty ?? true)
              ? _buildEmpty(colors)
              : _buildList(colors),
    );
  }

  Widget _buildEmpty(ColorScheme colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.style_outlined, size: 64, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('还没有单词卡片', style: TextStyle(color: colors.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('拍下身边的物体，自动生成带音标、释义和发音的卡片',
              style: TextStyle(
                  fontSize: 13, color: colors.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildList(ColorScheme colors) {
    final cards = _cards!;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: cards.length,
      itemBuilder: (_, i) => _CardTile(
        card: cards[i],
        colors: colors,
        onTap: () => _openDetail(cards[i]),
        onDelete: () => _delete(cards[i]),
      ),
    );
  }
}

/// 列表项：缩略图 + 英文单词/音标 + 中文释义 + 日期。
class _CardTile extends StatelessWidget {
  final WordCard card;
  final ColorScheme colors;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CardTile({
    required this.card,
    required this.colors,
    required this.onTap,
    required this.onDelete,
  });

  String get _date =>
      DateFormat('yyyy-MM-dd').format(card.createdAt);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // 缩略图（本地文件；被清理时回退到网络 URL）。
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: card.hasLocalImage
                      ? Image.file(
                          File(card.cardImagePath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _thumbFallback(colors),
                        )
                      : _thumbFallback(colors),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            card.englishWord,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除',
                          onPressed: onDelete,
                        ),
                      ],
                    ),
                    if (card.ukPhonetic.isNotEmpty)
                      Text(
                        '/${card.ukPhonetic}/',
                        style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                            fontFamily: 'monospace'),
                      ),
                    if (card.chineseWord.isNotEmpty ||
                        card.chineseDefinition.isNotEmpty)
                      Text(
                        [
                          card.chineseWord,
                          card.chineseDefinition,
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: colors.onSurfaceVariant),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _date,
                      style: TextStyle(
                          fontSize: 11, color: colors.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbFallback(ColorScheme colors) => Container(
        color: colors.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.image_outlined,
            size: 28, color: colors.onSurfaceVariant),
      );
}
