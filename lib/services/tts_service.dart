import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TTS 设置（引擎/语速/音高），SharedPreferences 持久化，设置页读写。
class TtsSettingsStore {
  TtsSettingsStore._();
  static final TtsSettingsStore instance = TtsSettingsStore._();

  static const _kRate = 'tts.rate';
  static const _kPitch = 'tts.pitch';
  static const _kEngine = 'tts.engine';
  static const _kVoice = 'tts.voice';

  Future<double> getRate() async =>
      (await SharedPreferences.getInstance()).getDouble(_kRate) ?? 0.5;

  Future<void> setRate(double v) async =>
      (await SharedPreferences.getInstance())
          .setDouble(_kRate, v.clamp(0.0, 1.0));

  Future<double> getPitch() async =>
      (await SharedPreferences.getInstance()).getDouble(_kPitch) ?? 1.0;

  Future<void> setPitch(double v) async =>
      (await SharedPreferences.getInstance())
          .setDouble(_kPitch, v.clamp(0.5, 2.0));

  Future<String?> getEngine() async =>
      (await SharedPreferences.getInstance()).getString(_kEngine);

  Future<void> setEngine(String? v) async {
    final prefs = await SharedPreferences.getInstance();
    if (v == null || v.isEmpty) {
      await prefs.remove(_kEngine);
    } else {
      await prefs.setString(_kEngine, v);
    }
  }

  Future<String?> getVoice() async =>
      (await SharedPreferences.getInstance()).getString(_kVoice);

  Future<void> setVoice(String? v) async {
    final prefs = await SharedPreferences.getInstance();
    if (v == null || v.isEmpty) {
      await prefs.remove(_kVoice);
    } else {
      await prefs.setString(_kVoice, v);
    }
  }
}

/// 文本朗读服务（听书）。
///
/// v2 设计（修「点了朗读没声音」）：
/// - 句子循环由**系统完成回调驱动**（`setCompletionHandler`），不再
///   `awaitSpeakCompletion(true)` 等 speak() 返回——部分设备/引擎的完成
///   回调不触发时 speak() 永不返回，整个朗读直接哑火；
/// - 每句一个**看门狗**：15 秒内既没有完成回调也没有进度回调（引擎死了）
///   就自动跳过这一句，保证循环永远往前走；
/// - 中文语音包按 `zh-CN → zh → cmn-CN → zh-TW → zh-HK → zh-Hans` 逐个探测，
///   设备上没有中文包就退回系统默认并提示用户；
/// - 无引擎 / 引擎报错通过 [onError] 上报，UI 显示真实原因而不是无声；
/// - Android 上开始朗读时拉起**前台服务**（通知栏常驻），退回桌面/熄屏后
///   进程不被系统杀掉，朗读继续（后台播放）。
///
/// 暂停/继续：统一用「记住句子下标 + stop + 重读当前句」实现，跨平台一致。
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  /// Android 前台服务桥（MainActivity 里实现 start/stop）。
  static const MethodChannel _fgChannel = MethodChannel('io.github.zzy19074244935.libranote/tts');

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  bool _stopped = true;
  bool _paused = false;
  int _index = 0;
  List<String> _sentences = const [];
  double _rate = 0.5;

  Timer? _watchdog;
  DateTime _lastAdvance = DateTime.fromMillisecondsSinceEpoch(0);

  /// 是否正在播放（含暂停）。
  bool get active => !_stopped;

  bool get paused => _paused;

  void Function(int index, String sentence)? onProgress;
  VoidCallback? onDone;

  /// 引擎级错误提示（无引擎 / 初始化失败 / 引擎报错），UI 负责展示。
  void Function(String message)? onError;

  Future<void> _init() async {
    if (_ready) return;
    try {
      await _tts.awaitSpeakCompletion(false);
      _tts.setErrorHandler((msg) {
        debugPrint('[TTS] engine error: $msg');
        onError?.call('语音引擎报错：$msg');
      });
      _tts.setCompletionHandler(_onComplete);
      // 进度回调（词级）用于给看门狗喂食：有进度说明引擎活着。
      _tts.setProgressHandler(
          (String text, int start, int end, String word) => _kickWatchdog());

      // 设备连一个引擎都没有（精简 ROM / 未装 TTS）——直接告诉用户。
      try {
        final engines = await _tts.getEngines;
        if (engines != null && engines.isEmpty) {
          _ready = false;
          onError?.call('系统没有可用的语音引擎，请在系统设置里安装'
              '（如 Google 语音服务 / 讯飞语记）');
          return;
        }
      } catch (e) {
        debugPrint('[TTS] getEngines failed: $e');
      }

      // 中文优先：按常见区域码逐个试，设备没有中文包时退回系统默认。
      for (final lang in const [
        'zh-CN', 'zh', 'cmn-CN', 'zh-TW', 'zh-HK', 'zh-Hans',
      ]) {
        try {
          final ok = await _tts.isLanguageAvailable(lang);
          if (ok == true) {
            final set = await _tts.setLanguage(lang);
            if (set == true) {
              debugPrint('[TTS] using language $lang');
              break;
            }
          }
        } catch (e) {
          debugPrint('[TTS] language probe $lang failed: $e');
        }
      }

      await _tts.setVolume(1.0);
      // 应用用户设置（设置页持久化）：引擎 / 音色 / 语速 / 音高。
      try {
        final engine = await TtsSettingsStore.instance.getEngine();
        if (engine != null && engine.isNotEmpty) {
          await _tts.setEngine(engine);
        }
        await _applyStoredVoice();
      } catch (e) {
        debugPrint('[TTS] apply engine/voice failed: $e');
      }
      _rate = await TtsSettingsStore.instance.getRate();
      await _tts.setSpeechRate(_rate);
      try {
        await _tts.setPitch(await TtsSettingsStore.instance.getPitch());
      } catch (e) {
        debugPrint('[TTS] apply pitch failed: $e');
      }
      _ready = true;
      debugPrint('[TTS] engine ready');
    } catch (e) {
      debugPrint('[TTS] init failed: $e');
      onError?.call('初始化语音引擎失败：$e');
    }
  }

  /// 设置语速（0.4 慢 ~ 0.8 快，0.5 正常）。立即对后续句子生效，
  /// 并持久化（设置页与阅读器朗读条共用）。
  Future<void> setRate(double rate) async {
    _rate = rate;
    await TtsSettingsStore.instance.setRate(rate);
    if (_ready) {
      try {
        await _tts.setSpeechRate(rate);
      } catch (e) {
        debugPrint('[TTS] set rate failed: $e');
      }
    }
  }

  /// 设置音高（0.5 低 ~ 2.0 高，1.0 正常），持久化。
  Future<void> setPitch(double pitch) async {
    await TtsSettingsStore.instance.setPitch(pitch);
    if (_ready) {
      try {
        await _tts.setPitch(pitch);
      } catch (e) {
        debugPrint('[TTS] set pitch failed: $e');
      }
    }
  }

  /// 系统可用的语音引擎名列表（设置页展示；设备没有引擎时为空）。
  Future<List<String>> availableEngines() async {
    try {
      final engines = await _tts.getEngines;
      return engines ?? const [];
    } catch (e) {
      debugPrint('[TTS] getEngines failed: $e');
      return const [];
    }
  }

  /// 当前引擎可用的音色（name/locale），切换引擎后要重取。
  Future<List<Map<dynamic, dynamic>>> availableVoices() async {
    try {
      final voices = await _tts.getVoices;
      return voices ?? const [];
    } catch (e) {
      debugPrint('[TTS] getVoices failed: $e');
      return const [];
    }
  }

  /// 试听：读一句示例（设置页用）。
  Future<void> preview(String text) async {
    await _init();
    if (!_ready) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  /// 切换引擎（清掉已选音色，避免引擎 A 的音色在引擎 B 上失效）。
  Future<void> applyEngine(String? engine) async {
    await TtsSettingsStore.instance.setEngine(engine);
    await TtsSettingsStore.instance.setVoice(null);
    if (_ready && engine != null && engine.isNotEmpty) {
      try {
        await _tts.setEngine(engine);
      } catch (e) {
        debugPrint('[TTS] set engine failed: $e');
      }
    }
  }

  /// 切换音色（传音色名；flutter_tts 的 setVoice 需要完整的
  /// {name, locale} Map，这里从 getVoices 里按名字找回来）。
  Future<void> applyVoice(String voiceName) async {
    await TtsSettingsStore.instance.setVoice(voiceName);
    if (_ready) {
      try {
        await _setVoiceByName(voiceName);
      } catch (e) {
        debugPrint('[TTS] set voice failed: $e');
      }
    }
  }

  /// 按名字设置音色（找不到就跳过——引擎切换后旧音色可能已不在列表里）。
  Future<void> _setVoiceByName(String name) async {
    final voices = await _tts.getVoices;
    for (final v in (voices ?? const [])) {
      if (v['name']?.toString() == name) {
        await _tts.setVoice(Map<String, String>.from(v));
        return;
      }
    }
    debugPrint('[TTS] voice not found: $name');
  }

  /// 应用存储的音色（初始化时）。
  Future<void> _applyStoredVoice() async {
    final name = await TtsSettingsStore.instance.getVoice();
    if (name == null || name.isEmpty) return;
    await _setVoiceByName(name);
  }

  /// 从头播放一批句子（会自动停掉上一段）。
  Future<void> play(
    List<String> sentences, {
    int startIndex = 0,
    void Function(int index, String sentence)? onProgress,
    VoidCallback? onDone,
    void Function(String message)? onError,
  }) async {
    this.onProgress = onProgress;
    this.onDone = onDone;
    if (onError != null) this.onError = onError;
    // 先标记停止并取消看门狗，再 stop 引擎：部分平台的 stop() 会触发上一段
    // 的完成回调，此时旧回调必须被 _stopped=true 挡住，否则会把旧句子列表
    // 的索引推进、甚至抢读旧内容（「换起点朗读却从别处出声」的根因之一）。
    _stopped = true;
    _cancelWatchdog();
    await _init();
    await _tts.stop();
    _sentences = sentences;
    _stopped = false;
    _paused = false;
    _index = startIndex.clamp(0, sentences.length);
    if (!_ready || _index >= _sentences.length) {
      _finish();
      return;
    }
    await _startForeground();
    _speakCurrent();
  }

  /// 暂停：停止发声，记住当前句；[resume] 从当前句继续。
  Future<void> pause() async {
    _paused = true;
    _cancelWatchdog();
    await _tts.stop();
  }

  /// 继续：从暂停时的那一句重新读。
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    _speakCurrent();
  }

  /// 完全停止本次朗读。
  Future<void> stop() async {
    _stopped = true;
    _paused = false;
    _cancelWatchdog();
    await _tts.stop();
    await _stopForeground();
  }

  /// 读当前句；完成回调 / 看门狗驱动下一句。
  void _speakCurrent() {
    if (_stopped || _paused) return;
    if (_index >= _sentences.length) {
      _finish();
      return;
    }
    onProgress?.call(_index, _sentences[_index]);
    _startWatchdog();
    try {
      _tts.speak(_sentences[_index]);
    } catch (e) {
      debugPrint('[TTS] speak failed: $e');
      _onComplete();
    }
  }

  /// 系统完成回调：一句读完 → 下一句。
  void _onComplete() {
    // 暂停中 stop() 触发的迟到完成回调绝不能推进索引，否则恢复朗读时
    // 会从下一句开始（「选了起点却从别处读」的根因之一）。
    if (_stopped || _paused) return;
    // 看门狗刚跳过一句后，旧句的迟到完成回调不能再推进（会跳句）。
    final sinceAdvance = DateTime.now().difference(_lastAdvance);
    if (sinceAdvance < const Duration(milliseconds: 600)) return;
    _lastAdvance = DateTime.now();
    _cancelWatchdog();
    _index++;
    if (_index >= _sentences.length) {
      _finish();
      return;
    }
    if (!_paused) _speakCurrent();
  }

  /// 看门狗：本句开始后固定 18 秒没有任何完成回调 → 当引擎死了，跳过本句。
  ///
  /// 旧版本用 progress 回调无限重置看门狗：部分引擎读完一句后仍持续发
  /// progress 但 completion 永不触发，看门狗被一直喂食 → 索引永不前进，
  /// 表现为「读到下一段就停了」。现在看门狗只在本句开始/结束时重置。
  void _startWatchdog() {
    _cancelWatchdog();
    _watchdog = Timer(const Duration(seconds: 18), () {
      debugPrint('[TTS] watchdog: no completion from engine, skipping sentence');
      _lastAdvance = DateTime.now();
      _onComplete();
    });
  }

  void _kickWatchdog() {
    // 保留接口：progress 回调仍会调用，但不再重置看门狗
    // （见 _startWatchdog 注释，重置会掩盖「completion 丢失」的引擎 bug）。
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _finish() {
    _stopped = true;
    _cancelWatchdog();
    unawaited(_stopForeground());
    final cb = onDone;
    if (cb != null) {
      // 在微任务里派发，而不是直接调用：onDone 会同步触发下一章/下一批的
      // play()（里面又 stop 引擎）。若留在 completion handler 的调用栈里，
      // 平台引擎的重入会串句——「读到下一段就停了/乱跳」的诱因之一。
      Future<void>.microtask(cb);
    }
  }

  // ── Android 前台服务（后台播放） ─────────────────────────────────

  Future<void> _startForeground() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      // Android 13+ 通知需要运行时授权；被拒绝也不影响朗读本身。
      await Permission.notification.request();
    } catch (e) {
      debugPrint('[TTS] notification permission failed: $e');
    }
    try {
      await _fgChannel.invokeMethod('start', {'title': '正在朗读'});
    } catch (e) {
      debugPrint('[TTS] foreground service start failed: $e');
    }
  }

  Future<void> _stopForeground() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _fgChannel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[TTS] foreground service stop failed: $e');
    }
  }

  /// 按中文标点把文本切成句子（保留标点），长句再按逗号切，避免一次读太长。
  static List<String> splitSentences(String text) {
    if (text.trim().isEmpty) return const [];
    final pieces = text
        .split(RegExp(r'(?<=[。！？；!?;\n])'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final out = <String>[];
    for (final p in pieces) {
      if (p.length <= 200) {
        out.add(p);
        continue;
      }
      final sub = p
          .split(RegExp(r'(?<=[，,、])'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      out.addAll(sub);
    }
    return out;
  }

  /// 去掉 Markdown 行首的常见标记（#、*、-、>、` 等），让朗读内容更干净。
  static String stripMarkdown(String md) {
    return md
        .split('\n')
        .map((line) => line.replaceFirst(
            RegExp(r'^\s{0,4}(#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+|```.*|~~~.*)'),
            ''))
        .map((line) => line.replaceAll('`', '').replaceAll('*', '').replaceAll('_', ''))
        .join('\n');
  }
}
