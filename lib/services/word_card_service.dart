import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/word_card.dart';

/// 单词卡片业务错误（配置缺失 / 服务端返回的业务错误）。
class WordCardException implements Exception {
  final String message;
  const WordCardException(this.message);

  @override
  String toString() => message;
}

/// 服务端 `/create_card` 返回的资源与文本信息。
class CardApiResult {
  final String chineseWord;
  final String englishWord;
  final String ukPhonetic;
  final String usPhonetic;
  final String definition;
  final String chineseDefinition;
  final String cardImageUrl;
  final String? ukAudioUrl;
  final String? usAudioUrl;

  const CardApiResult({
    required this.chineseWord,
    required this.englishWord,
    required this.ukPhonetic,
    required this.usPhonetic,
    required this.definition,
    required this.chineseDefinition,
    required this.cardImageUrl,
    this.ukAudioUrl,
    this.usAudioUrl,
  });

  factory CardApiResult.fromJson(Map<String, dynamic> json) {
    final data = (json['data'] as Map<String, dynamic>?) ?? {};
    return CardApiResult(
      chineseWord: (data['chinese_word'] as String?) ?? '',
      englishWord: (data['english_word'] as String?) ?? '',
      ukPhonetic: (data['uk_phonetic'] as String?) ?? '',
      usPhonetic: (data['us_phonetic'] as String?) ?? '',
      definition: (data['definition'] as String?) ?? '',
      chineseDefinition: (data['chinese_definition'] as String?) ?? '',
      cardImageUrl: (data['card_image_url'] as String?) ?? '',
      ukAudioUrl: data['uk_audio_url'] as String?,
      usAudioUrl: data['us_audio_url'] as String?,
    );
  }
}

/// 单词卡片服务：把照片 POST 到火山函数计算（Serverless），
/// 拿到生成结果后把卡片图/音频下载到本地。
///
/// 重试策略：仅对网络层错误（超时/断连）自动重试 1 次；HTTP 业务错误
/// （403 token 不对、400 没图片、5xx 流水线失败）直接抛出，带服务端原因。
class WordCardService {
  WordCardService._();
  static final WordCardService instance = WordCardService._();

  /// 总尝试次数（网络层错误自动重试一次，共 2 次）。
  static const int _maxAttempts = 2;

  /// 阶段回调：'upload'（上传中）/ 'generate'（服务端流水线生成中）。
  /// 传 `(stage, progress)`，progress 仅 upload 阶段有意义（0~1）。
  void Function(String stage, double progress)? onStage;

  /// 流程总超时：函数 30s 超时 + 上传与余量。超时属于可重试错误。
  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 45);

  // ── 配置 ──────────────────────────────────────────────────────────

  bool get configured {
    final url = AppConfig.instance.wordCardFunctionUrl.trim();
    final token = AppConfig.instance.wordCardAppToken.trim();
    return url.isNotEmpty && token.isNotEmpty;
  }

  // ── 生成卡片 ──────────────────────────────────────────────────────

  /// 上传图片并等待服务端生成卡片。
  Future<CardApiResult> createCard(File imageFile) async {
    final url = AppConfig.instance.wordCardFunctionUrl.trim();
    final token = AppConfig.instance.wordCardAppToken.trim();
    if (url.isEmpty) {
      throw const WordCardException('尚未配置函数地址，请先在卡片库右上角设置');
    }
    if (token.isEmpty) {
      throw const WordCardException('尚未配置鉴权 Token，请先在卡片库右上角设置');
    }
    if (!await imageFile.exists()) {
      throw const WordCardException('图片文件不存在，请重新拍照/选图');
    }

    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        return await _postCreateCard(url, token, imageFile);
      } on WordCardException {
        rethrow; // 业务错误：重试无意义。
      } on DioException catch (e) {
        lastError = e;
        if (!_isRetryable(e) || attempt == _maxAttempts) break;
        debugPrint('[WordCard] attempt $attempt failed (${e.type}), retrying');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    final msg = _describeDioError(lastError);
    throw WordCardException('网络请求失败：$msg');
  }

  Future<CardApiResult> _postCreateCard(
      String url, String token, File imageFile) async {
    final dio = Dio(BaseOptions(
      connectTimeout: _connectTimeout,
      receiveTimeout: _receiveTimeout,
      // 4xx/5xx 不抛异常，自己解析 body 里的错误信息给用户看。
      validateStatus: (s) => s != null,
      headers: {'Authorization': 'Bearer $token'},
    ));

    try {
      final form = FormData.fromMap({
        'image': await MultipartFile.fromFile(
          imageFile.path,
          filename: 'card.jpg',
          contentType: DioMediaType('image', 'jpeg'),
        ),
      });

      onStage?.call('upload', 0);
      final resp = await dio.post<Map<String, dynamic>>(
        _joinUrl(url, '/create_card'),
        data: form,
        onSendProgress: (sent, total) {
          if (total > 0) onStage?.call('upload', sent / total);
        },
      );
      // 上传完成后等待服务端整条流水线（抠图/识别/翻译/DeepSeek/TTS/合成）。
      onStage?.call('generate', 0);

      final body = resp.data;
      if (resp.statusCode == 200 && body != null) {
        final success = body['success'] == true;
        if (!success) {
          final err = (body['error'] as String?) ?? '服务端返回未知错误';
          throw WordCardException('生成失败：$err');
        }
        return CardApiResult.fromJson(body);
      }
      if (resp.statusCode == 403) {
        throw const WordCardException('鉴权失败（403）：Token 与服务端不一致，'
            '请检查右上角设置里的 APP_TOKEN');
      }
      final err = _extractError(resp);
      throw WordCardException('生成失败（HTTP ${resp.statusCode}）：$err');
    } finally {
      dio.close();
    }
  }

  // ── 资源下载 ──────────────────────────────────────────────────────

  /// 把卡片图与音频下载到 Documents/word_cards/，返回带本地路径的新卡片。
  ///
  /// 卡片图下载失败会抛错（没有图卡片没意义）；音频失败只置空并打印日志。
  Future<WordCard> downloadResources(WordCard card) async {
    final dir = await getApplicationDocumentsDirectory();
    final base = Directory(p.join(dir.path, 'word_cards'));
    await base.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      validateStatus: (s) => s != null && s < 500,
    ));
    try {
      final cardPath = await _download(
        dio,
        card.cardImageUrl,
        p.join(base.path, 'img_$ts.png'),
        requireSuccess: true,
      );

      String? ukPath;
      String? usPath;
      if (card.ukAudioUrl != null && card.ukAudioUrl!.isNotEmpty) {
        ukPath = await _download(
          dio,
          card.ukAudioUrl!,
          p.join(base.path, 'uk_$ts.mp3'),
        );
      }
      if (card.usAudioUrl != null && card.usAudioUrl!.isNotEmpty) {
        usPath = await _download(
          dio,
          card.usAudioUrl!,
          p.join(base.path, 'us_$ts.mp3'),
        );
      }

      return WordCard(
        id: card.id,
        chineseWord: card.chineseWord,
        englishWord: card.englishWord,
        ukPhonetic: card.ukPhonetic,
        usPhonetic: card.usPhonetic,
        definition: card.definition,
        chineseDefinition: card.chineseDefinition,
        cardImageUrl: card.cardImageUrl,
        cardImagePath: cardPath,
        ukAudioUrl: card.ukAudioUrl,
        ukAudioPath: ukPath,
        usAudioUrl: card.usAudioUrl,
        usAudioPath: usPath,
        createdAt: card.createdAt,
      );
    } finally {
      dio.close();
    }
  }

  /// 下载单个资源到 [destPath]。失败时：requireSuccess=true 抛异常，
  /// 否则返回 null（音频丢失不阻断保存）。
  Future<String?> _download(
    Dio dio,
    String url,
    String destPath, {
    bool requireSuccess = false,
  }) async {
    try {
      final resp = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      if (resp.statusCode == 200 && resp.data != null) {
        await File(destPath).writeAsBytes(resp.data!, flush: true);
        return destPath;
      }
      if (requireSuccess) {
        throw WordCardException('下载卡片图失败（HTTP ${resp.statusCode}）');
      }
      debugPrint('[WordCard] download $url → HTTP ${resp.statusCode}, skipped');
      return null;
    } catch (e) {
      if (requireSuccess) {
        throw WordCardException('下载卡片图失败：$e');
      }
      debugPrint('[WordCard] audio download failed, skipped: $e');
      return null;
    }
  }

  // ── 错误辅助 ──────────────────────────────────────────────────────

  bool _isRetryable(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      default:
        return false;
    }
  }

  String _describeDioError(Object? e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
          return '连接函数超时，请检查网络后重试';
        case DioExceptionType.receiveTimeout:
          return '生成超时（服务端流水线超过 45 秒），'
              '可能是函数超时设置太短或第三方 API 波动，请重试';
        case DioExceptionType.connectionError:
          return '无法连接函数地址（${e.message ?? ''}），请检查网络与函数 URL';
        case DioExceptionType.badCertificate:
          return 'HTTPS 证书校验失败';
        case DioExceptionType.cancel:
          return '请求已取消';
        default:
          return e.message ?? '未知网络错误';
      }
    }
    return e?.toString() ?? '未知错误';
  }

  String _extractError(Response<Map<String, dynamic>> resp) {
    final body = resp.data;
    if (body is Map<String, dynamic>) {
      final err = body['error'];
      if (err is String && err.isNotEmpty) return err;
      final msg = body['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
    return '服务端没有返回有效信息';
  }

  String _joinUrl(String base, String path) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://$b';
    }
    return '$b$path';
  }
}
