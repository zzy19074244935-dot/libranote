import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/translate_service.dart';
import 'translate_history_screen.dart';

/// 拍照翻译：拍照/选图 → 本地 OCR 识别 → 翻译。
///
/// OCR 走 Google ML Kit 的**离线**中文识别模型（不依赖 Google Play 服务，
/// 华为/小米机型可用）；翻译优先 API 翻译（与 AI 配置共用）、退回免费接口。
/// 每次翻译成功自动保存记录（照片存 `Documents/photo_translate/`，
/// 原文/译文进 SQLite），右上角「历史记录」可查看/删除。
class PhotoTranslateScreen extends ConsumerStatefulWidget {
  const PhotoTranslateScreen({super.key});

  @override
  ConsumerState<PhotoTranslateScreen> createState() =>
      _PhotoTranslateScreenState();
}

class _PhotoTranslateScreenState extends ConsumerState<PhotoTranslateScreen> {
  final ImagePicker _picker = ImagePicker();
  TextRecognizer? _recognizer;

  String? _imagePath;
  bool _recognizing = false;
  bool _translating = false;

  final _sourceCtrl = TextEditingController();
  String _result = '';
  String _target = 'zh-CN';

  @override
  void dispose() {
    _recognizer?.close();
    _sourceCtrl.dispose();
    super.dispose();
  }

  TextRecognizer _getRecognizer() {
    return _recognizer ??= TextRecognizer(script: TextRecognitionScript.chinese);
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 88);
      if (file == null || !mounted) return;
      setState(() {
        _imagePath = file.path;
        _result = '';
      });
      await _recognize(file.path);
    } catch (e) {
      _toast('拍照/选图失败: $e');
    }
  }

  Future<void> _recognize(String path) async {
    setState(() => _recognizing = true);
    try {
      final recognized =
          await _getRecognizer().processImage(InputImage.fromFilePath(path));
      if (!mounted) return;
      setState(() {
        _sourceCtrl.text = recognized.text.trim();
        _recognizing = false;
      });
      if (recognized.text.trim().isEmpty) {
        _toast('没有识别到文字，试试更清晰的照片');
      }
    } catch (e) {
      debugPrint('[Translate] OCR failed: $e');
      if (mounted) {
        setState(() => _recognizing = false);
        _toast('文字识别失败: $e');
      }
    }
  }

  Future<void> _translate() async {
    final text = _sourceCtrl.text.trim();
    if (text.isEmpty) {
      _toast('请先识别出文字（或手动输入要翻译的内容）');
      return;
    }
    setState(() => _translating = true);
    try {
      final result = await TranslateService.instance.translate(text, _target);
      if (!mounted) return;
      setState(() {
        _result = result;
        _translating = false;
      });
      // 成功 → 自动保存记录（照片 + 原文/译文进库）。
      await _saveRecord(text, result);
    } catch (e) {
      if (mounted) {
        setState(() => _translating = false);
        _toast('翻译失败: $e');
      }
    }
  }

  /// 保存拍照翻译记录：照片复制到 Documents/photo_translate/，
  /// 原文/译文/目标语言写进 translate_records 表（拍照翻译页的历史记录）。
  Future<void> _saveRecord(String source, String translated) async {
    try {
      String? savedImage;
      final srcPath = _imagePath;
      if (srcPath != null && File(srcPath).existsSync()) {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(docs.path, 'photo_translate'));
        if (!await dir.exists()) await dir.create(recursive: true);
        final ext = p.extension(srcPath).isEmpty
            ? '.jpg'
            : p.extension(srcPath).toLowerCase();
        savedImage = p.join(dir.path,
            'pt_${DateTime.now().millisecondsSinceEpoch}$ext');
        await File(srcPath).copy(savedImage);
      }
      await ref
          .read(storageServiceProvider)
          .insertTranslateRecord(TranslateRecord(
            imagePath: savedImage,
            sourceText: source,
            translatedText: translated,
            target: _target,
            createdAt: DateTime.now(),
          ));
    } catch (e) {
      debugPrint('[Translate] save record failed: $e');
    }
  }

  void _copyResult() {
    if (_result.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _result));
    _toast('译文已复制');
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('拍照翻译'),
        actions: [
          IconButton(
            tooltip: '历史记录',
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const TranslateHistoryScreen()),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── 预览 / 空态 ───────────────────────────────────────
          Container(
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
                        Text('拍一张带文字的图片，自动识别并翻译',
                            style: TextStyle(
                                color: colors.onSurfaceVariant, fontSize: 13)),
                      ],
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(_imagePath!), fit: BoxFit.contain),
                      if (_recognizing)
                        Container(
                          color: Colors.black.withValues(alpha: 0.35),
                          alignment: Alignment.center,
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: Colors.white),
                              SizedBox(height: 10),
                              Text('正在识别文字…',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),

          // ── 拍照 / 相册 ───────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('拍照'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('相册'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── 识别出的原文（可编辑） ────────────────────────────
          Text('识别出的文字（可修改）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant)),
          const SizedBox(height: 8),
          TextField(
            controller: _sourceCtrl,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(
              hintText: '识别结果会显示在这里，也可以手动输入…',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── 目标语言 ──────────────────────────────────────────
          Text('翻译成',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final t in TranslateService.targets)
                ChoiceChip(
                  label: Text(t.$2),
                  selected: _target == t.$1,
                  onSelected: (_) => setState(() => _target = t.$1),
                ),
            ],
          ),
          const SizedBox(height: 16),

          FilledButton.icon(
            onPressed: _translating ? null : _translate,
            icon: _translating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.translate, size: 18),
            label: Text(_translating ? '翻译中…' : '翻译'),
          ),
          const SizedBox(height: 20),

          // ── 译文 ──────────────────────────────────────────────
          if (_result.isNotEmpty) ...[
            Row(
              children: [
                Text('译文',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurfaceVariant)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制译文',
                  onPressed: _copyResult,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                _result,
                style: const TextStyle(fontSize: 15, height: 1.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
