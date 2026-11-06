import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_settings.dart';

/// Holds the current [ReaderSettings] and persists every change to
/// [SharedPreferences] so the reader preferences survive a restart.
class ReaderSettingsNotifier extends StateNotifier<ReaderSettings> {
  SharedPreferences? _prefs;
  bool _init = false;

  ReaderSettingsNotifier() : super(const ReaderSettings());

  /// Must be called once before the settings are read or written.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> ensureInit() async {
    if (_init) return;
    _prefs = await SharedPreferences.getInstance();
    state = _load();
    _init = true;
  }

  // ── Individual setters — each persists immediately ──────────────────────

  Future<void> setFontSize(double v) async {
    state = state.copyWith(fontSize: v.clamp(14, 28));
    await _save();
  }

  Future<void> setLineHeight(double v) async {
    state = state.copyWith(lineHeight: v.clamp(1.4, 2.2));
    await _save();
  }

  Future<void> setPageMargin(double v) async {
    state = state.copyWith(pageMargin: v.clamp(12, 40));
    await _save();
  }

  Future<void> setUseSerif(bool v) async {
    state = state.copyWith(useSerif: v);
    await _save();
  }

  Future<void> setTheme(String v) async {
    state = state.copyWith(theme: v);
    await _save();
  }

  Future<void> setTapToTurn(bool v) async {
    state = state.copyWith(tapToTurn: v);
    await _save();
  }

  Future<void> setImmersive(bool v) async {
    state = state.copyWith(immersive: v);
    await _save();
  }

  // ── Persistence ─────────────────────────────────────────────────────────

  static const _kFontSize = 'rs.fontSize';
  static const _kLineHeight = 'rs.lineHeight';
  static const _kPageMargin = 'rs.pageMargin';
  static const _kUseSerif = 'rs.useSerif';
  static const _kTheme = 'rs.theme';
  static const _kTapToTurn = 'rs.tapToTurn';
  static const _kImmersive = 'rs.immersive';

  double _clampD(double v, double lo, double hi) => v.clamp(lo, hi);

  ReaderSettings _load() {
    final p = _prefs!;
    return ReaderSettings(
      fontSize: _clampD(p.getDouble(_kFontSize) ?? 17, 14, 28),
      lineHeight: _clampD(p.getDouble(_kLineHeight) ?? 1.75, 1.4, 2.2),
      pageMargin: _clampD(p.getDouble(_kPageMargin) ?? 20, 12, 40),
      useSerif: p.getBool(_kUseSerif) ?? false,
      theme: _validTheme(p.getString(_kTheme)),
      tapToTurn: p.getBool(_kTapToTurn) ?? false,
      immersive: p.getBool(_kImmersive) ?? false,
    );
  }

  Future<void> _save() async {
    final p = _prefs;
    if (p == null) return;
    final s = state;
    await Future.wait([
      p.setDouble(_kFontSize, s.fontSize),
      p.setDouble(_kLineHeight, s.lineHeight),
      p.setDouble(_kPageMargin, s.pageMargin),
      p.setBool(_kUseSerif, s.useSerif),
      p.setString(_kTheme, s.theme),
      p.setBool(_kTapToTurn, s.tapToTurn),
      p.setBool(_kImmersive, s.immersive),
    ]);
  }

  String _validTheme(String? s) {
    if (s == null) return 'day';
    if (s == 'night' || s == 'sepia') return s;
    if (s.startsWith('readest:')) return s;
    return 'day';
  }
}

final readerSettingsProvider =
    StateNotifierProvider<ReaderSettingsNotifier, ReaderSettings>((ref) {
  final notifier = ReaderSettingsNotifier();
  // Fire-and-forget init — the UI will get defaults on the first frame and
  // real values on the next rebuild after SharedPreferences loads.
  notifier.ensureInit();
  return notifier;
});
