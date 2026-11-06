import 'package:flutter/material.dart';

import '../services/tts_service.dart';

/// 朗读（TTS）设置：引擎 / 音色 / 语速 / 音高 / 试听。
///
/// 引擎与音色依赖设备安装的语音包（Android Google TTS / 厂商引擎；
/// Windows 需装中文语音如 Microsoft Huihui）——没装中文包时 App 已
/// 自动回退系统默认，这里也能手动挑。
class TtsSettingsScreen extends StatefulWidget {
  const TtsSettingsScreen({super.key});

  @override
  State<TtsSettingsScreen> createState() => _TtsSettingsScreenState();
}

class _TtsSettingsScreenState extends State<TtsSettingsScreen> {
  List<String> _engines = [];
  String? _engine;
  List<Map<dynamic, dynamic>> _voices = [];
  String? _voice;
  double _rate = 0.5;
  double _pitch = 1.0;
  bool _loaded = false;
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _engines = await TtsService.instance.availableEngines();
    _engine = await TtsSettingsStore.instance.getEngine();
    // 保存的引擎不在可用列表里（换设备/引擎被删）→ 清掉回默认。
    if (_engine != null && _engines.isNotEmpty && !_engines.contains(_engine)) {
      _engine = null;
      await TtsSettingsStore.instance.setEngine(null);
    }
    _voices = await TtsService.instance.availableVoices();
    _voice = await TtsSettingsStore.instance.getVoice();
    _rate = await TtsSettingsStore.instance.getRate();
    _pitch = await TtsSettingsStore.instance.getPitch();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _selectEngine(String? engine) async {
    await TtsService.instance.applyEngine(engine);
    _voices = await TtsService.instance.availableVoices();
    _voice = null;
    if (mounted) setState(() => _engine = engine);
  }

  Future<void> _selectVoice(String voice) async {
    await TtsService.instance.applyVoice(voice);
    if (mounted) setState(() => _voice = voice);
  }

  Future<void> _preview() async {
    setState(() => _previewing = true);
    await TtsService.instance.preview('你好，这是 Libranote 的朗读试听。');
    if (mounted) setState(() => _previewing = false);
  }

  String _voiceLabel(Map<dynamic, dynamic> v) {
    final name = v['name']?.toString() ?? '';
    final locale = v['locale']?.toString() ?? '';
    return locale.isEmpty ? name : '$name（$locale）';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('朗读（TTS）设置')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 引擎 ──────────────────────────────────────────
                Text('语音引擎', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _engines.isEmpty
                      ? '系统没有检测到语音引擎：请安装（如 Google 语音服务 / '
                          '讯飞语记；Windows 装中文语音包）。'
                      : '选择设备上的语音引擎（不选 = 系统默认）。',
                  style: TextStyle(
                      fontSize: 12.5, color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                RadioGroup<String?>(
                  groupValue: _engine,
                  onChanged: _selectEngine,
                  child: Column(
                    children: [
                      const RadioListTile<String?>(
                        value: null,
                        title: Text('系统默认'),
                        contentPadding: EdgeInsets.zero,
                      ),
                      for (final e in _engines)
                        RadioListTile<String?>(
                          value: e,
                          title: Text(e),
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
                if (_voices.isNotEmpty) ...[
                  const Divider(height: 24),
                  Text('音色', style: Theme.of(context).textTheme.titleMedium),
                  RadioGroup<String?>(
                    groupValue: _voice,
                    onChanged: (v) {
                      if (v != null) _selectVoice(v);
                    },
                    child: Column(
                      children: [
                        const RadioListTile<String?>(
                          value: null,
                          title: Text('默认音色'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        for (final v in _voices)
                          RadioListTile<String?>(
                            value: v['name']?.toString(),
                            title: Text(_voiceLabel(v)),
                            contentPadding: EdgeInsets.zero,
                          ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 24),

                // ── 语速 ──────────────────────────────────────────
                Text('语速（0.5 为正常）',
                    style: Theme.of(context).textTheme.titleMedium),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _rate.clamp(0.0, 1.0),
                        min: 0.0,
                        max: 1.0,
                        divisions: 20,
                        label: _rate.toStringAsFixed(2),
                        onChanged: (v) async {
                          setState(() => _rate = v);
                          await TtsService.instance.setRate(v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(_rate.toStringAsFixed(2),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),

                // ── 音高 ──────────────────────────────────────────
                Text('音高（1.0 为正常）',
                    style: Theme.of(context).textTheme.titleMedium),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _pitch.clamp(0.5, 2.0),
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: _pitch.toStringAsFixed(2),
                        onChanged: (v) async {
                          setState(() => _pitch = v);
                          await TtsService.instance.setPitch(v);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(_pitch.toStringAsFixed(2),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: _previewing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.volume_up_outlined),
                  label: const Text('试听'),
                  onPressed: _previewing ? null : _preview,
                ),
                const SizedBox(height: 12),
                Text(
                  '说明：朗读质量取决于设备语音包；没装中文语音时自动退回'
                  '系统默认语音。PDF 只对文字版有效（扫描版无文字层读不出来）。',
                  style: TextStyle(
                      fontSize: 12.5, height: 1.6, color: colors.onSurfaceVariant),
                ),
              ],
            ),
    );
  }
}
