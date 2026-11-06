import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/word_card.dart';
import '../providers/providers.dart';
import '../services/word_card_service.dart';

/// 生成阶段（用于 UI 展示进度文案）。
enum _Stage { idle, uploading, generating, downloading, done, error }

/// 拍照 → 火山函数生成单词卡片 → 下载资源 → 存入本地卡片库。
///
/// 图片在选图时即压缩（长边 ≤1280、70% 质量），符合服务端要求；
/// 生成中的整条流水线（抠图/识别/翻译/DeepSeek/TTS/合成）都在云端。
class WordCardCreateScreen extends ConsumerStatefulWidget {
  const WordCardCreateScreen({super.key});

  @override
  ConsumerState<WordCardCreateScreen> createState() =>
      _WordCardCreateScreenState();
}

class _WordCardCreateScreenState extends ConsumerState<WordCardCreateScreen> {
  final ImagePicker _picker = ImagePicker();

  String? _imagePath;
  _Stage _stage = _Stage.idle;
  double _uploadProgress = 0;
  String _error = '';

  /// 生成成功的卡片（资源已下载到本地，等待入库）。
  WordCard? _resultCard;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    WordCardService.instance.onStage = _onStage;
  }

  @override
  void dispose() {
    WordCardService.instance.onStage = null;
    super.dispose();
  }

  void _onStage(String stage, double progress) {
    if (!mounted) return;
    setState(() {
      if (stage == 'upload') {
        _stage = _Stage.uploading;
        _uploadProgress = progress;
      } else if (stage == 'generate') {
        _stage = _Stage.generating;
      } else if (stage == 'download') {
        _stage = _Stage.downloading;
      }
    });
  }

  // ── 选图 ───────────────────────────────────────────────────────────

  Future<void> _pick(ImageSource source) async {
    try {
      // 长边 ≤1280 + 70% 质量：满足服务端压缩要求，又省上传流量。
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 70,
      );
      if (file == null || !mounted) return;
      setState(() {
        _imagePath = file.path;
        _resultCard = null;
        _saved = false;
        _error = '';
        _stage = _Stage.idle;
      });
    } catch (e) {
      _toast('拍照/选图失败: $e');
    }
  }

  // ── 生成 ───────────────────────────────────────────────────────────

  Future<void> _generate() async {
    if (_imagePath == null) return;
    if (!WordCardService.instance.configured) {
      setState(() {
        _stage = _Stage.error;
        _error = '尚未配置函数地址或 Token。请返回卡片库，点右上角设置，'
            '填入火山函数公网 URL 和 APP_TOKEN。';
      });
      return;
    }
    setState(() {
      _stage = _Stage.uploading;
      _uploadProgress = 0;
      _error = '';
      _resultCard = null;
      _saved = false;
    });
    try {
      final api = await WordCardService.instance
          .createCard(File(_imagePath!));
      if (!mounted) return;
      setState(() => _stage = _Stage.downloading);
      final card = WordCard(
        chineseWord: api.chineseWord,
        englishWord: api.englishWord,
        ukPhonetic: api.ukPhonetic,
        usPhonetic: api.usPhonetic,
        definition: api.definition,
        chineseDefinition: api.chineseDefinition,
        cardImageUrl: api.cardImageUrl,
        ukAudioUrl: api.ukAudioUrl,
        usAudioUrl: api.usAudioUrl,
      );
      final local =
          await WordCardService.instance.downloadResources(card);
      if (!mounted) return;
      setState(() {
        _resultCard = local;
        _stage = _Stage.done;
      });
    } on WordCardException catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.error;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.error;
          _error = '生成失败: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    final card = _resultCard;
    if (card == null || _saved) return;
    try {
      await ref
          .read(storageServiceProvider)
          .insertWordCard(card);
      if (!mounted) return;
      setState(() => _saved = true);
      _toast('已保存到卡片库');
      // 稍等片刻让用户看到提示，再返回列表。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('拍照生成单词卡片')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPreview(colors),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('拍照'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('相册'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_resultCard == null) ...[
            FilledButton.icon(
              onPressed:
                  _imagePath != null && !_busy ? _generate : null,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(_imagePath == null ? '先拍照或选一张图片' : '生成单词卡片'),
            ),
            const SizedBox(height: 8),
            Text(
              '云端流水线：抠图 → 识别物体 → 翻译 → 音标释义 → 语音 → 合成卡片，'
              '约需 10~30 秒',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
          if (_stage == _Stage.uploading) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _uploadProgress),
            const SizedBox(height: 6),
            Text(
              '正在上传图片… ${(_uploadProgress * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
          if (_stage == _Stage.generating) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(
              '云端正在生成卡片（抠图/识别/翻译/音标/语音/合成），请稍候…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
          if (_stage == _Stage.downloading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(
              '生成成功，正在下载卡片图与音频…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
          if (_stage == _Stage.error) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                _error,
                style: TextStyle(fontSize: 13, color: colors.onErrorContainer),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
          if (_resultCard != null) _buildResult(colors),
        ],
      ),
    );
  }

  bool get _busy =>
      _stage == _Stage.uploading ||
      _stage == _Stage.generating ||
      _stage == _Stage.downloading;

  Widget _buildPreview(ColorScheme colors) {
    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8EDF3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: _imagePath == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.camera_alt_outlined,
                      size: 48, color: colors.onSurfaceVariant),
                  const SizedBox(height: 10),
                  Text('拍下身边的物体，自动生成英文单词卡片',
                      style: TextStyle(
                          color: colors.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            )
          : Image.file(File(_imagePath!), fit: BoxFit.contain),
    );
  }

  /// 生成成功后的结果卡片预览 + 保存按钮。
  Widget _buildResult(ColorScheme colors) {
    final c = _resultCard!;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('生成成功 🎉',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: colors.primary)),
          const SizedBox(height: 10),
          if (c.hasLocalImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(c.cardImagePath!),
                height: 220,
                width: double.infinity,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          const SizedBox(height: 10),
          Text.rich(TextSpan(children: [
            TextSpan(
              text: c.englishWord,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800),
            ),
            if (c.chineseWord.isNotEmpty)
              TextSpan(
                text: '  ${c.chineseWord}',
                style: TextStyle(
                    fontSize: 16,
                    color: colors.onSurfaceVariant),
              ),
          ])),
          if (c.ukPhonetic.isNotEmpty || c.usPhonetic.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (c.ukPhonetic.isNotEmpty) '英 /${c.ukPhonetic}/',
                if (c.usPhonetic.isNotEmpty) '美 /${c.usPhonetic}/',
              ].join('   '),
              style: TextStyle(
                  fontSize: 14,
                  color: colors.onSurfaceVariant,
                  fontFamily: 'monospace'),
            ),
          ],
          if (c.definition.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(c.definition,
                style: const TextStyle(fontSize: 14, height: 1.5)),
          ],
          if (c.chineseDefinition.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(c.chineseDefinition,
                style: TextStyle(
                    fontSize: 14, color: colors.onSurfaceVariant)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saved ? null : _save,
              icon: Icon(_saved ? Icons.check : Icons.save_alt, size: 18),
              label: Text(_saved ? '已保存' : '保存到卡片库'),
            ),
          ),
        ],
      ),
    );
  }
}
