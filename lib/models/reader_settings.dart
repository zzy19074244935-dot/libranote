import 'package:flutter/material.dart';

import '../services/readest_style.dart';

/// Per-user reading preferences persisted via SharedPreferences.
///
/// Kept in [lib/models] rather than [lib/config] because it is user state, not
/// application-wide constants — different people reading on the same device
/// (unlikely on mobile, common on shared desktops) may want different text
/// sizes and themes.
class ReaderSettings {
  // ── Typography ──────────────────────────────────────────────────────────

  /// Body font size in logical pixels.  Range 14–28, default 17.
  final double fontSize;

  /// Line-height multiplier.  Range 1.4–2.2, default 1.75.
  final double lineHeight;

  /// Reading-area horizontal padding in logical pixels.  Range 12–40, default 20.
  final double pageMargin;

  /// When true the reader renders text in a serif typeface instead of the
  /// system default sans-serif.
  final bool useSerif;

  // ── Theme ───────────────────────────────────────────────────────────────

  /// One of `'day'`, `'night'`, or `'sepia'`.
  ///
  /// The [backgroundColor] / [textColor] getters translate this to concrete
  /// [Color] values so callers never need to switch on the string.
  final String theme;

  // ── Behaviour ───────────────────────────────────────────────────────────

  /// When true a single tap on the left/right third of the screen turns the
  /// page (EPUB scrolls one viewport-height; PDF flips one page).
  /// Desktop-only for now — mobile gestures are a separate task.
  final bool tapToTurn;

  /// When true the AppBar, bottom page-controls, and other chrome are hidden
  /// so the reader uses the entire screen.  Tapping the centre third brings
  /// them back.
  final bool immersive;

  // ── Construction ────────────────────────────────────────────────────────

  const ReaderSettings({
    this.fontSize = 17,
    this.lineHeight = 1.75,
    this.pageMargin = 20,
    this.useSerif = false,
    this.theme = 'day',
    this.tapToTurn = false,
    this.immersive = false,
  });

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
    bool? useSerif,
    String? theme,
    bool? tapToTurn,
    bool? immersive,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      pageMargin: pageMargin ?? this.pageMargin,
      useSerif: useSerif ?? this.useSerif,
      theme: theme ?? this.theme,
      tapToTurn: tapToTurn ?? this.tapToTurn,
      immersive: immersive ?? this.immersive,
    );
  }

  // ── Computed colours ────────────────────────────────────────────────────

  /// Background colour for the reading area.
  Color get backgroundColor {
    switch (theme) {
      case 'night':
        return const Color(0xFF121212);
      case 'sepia':
        return const Color(0xFFF5ECD9);
      default: // day
        if (theme.startsWith('readest:')) {
          final id = theme.substring('readest:'.length);
          final entry = readestThemes[id];
          if (entry != null) return Color(entry.light.bg);
        }
        return Colors.transparent; // inherit from parent / Material surface
    }
  }

  /// Body text colour.
  Color get textColor {
    switch (theme) {
      case 'night':
        return const Color(0xFFC8C8C8);
      case 'sepia':
        return const Color(0xFF5B4636);
      default: // day
        if (theme.startsWith('readest:')) {
          final id = theme.substring('readest:'.length);
          final entry = readestThemes[id];
          if (entry != null) return Color(entry.light.fg);
        }
        return Colors.transparent; // inherit from parent / Material onSurface
    }
  }

  /// Font family string to pass to Flutter's [TextStyle].
  ///
  /// Returns `null` for the system default; `'serif'` (which maps to the
  /// platform's generic serif face) otherwise.
  String? get fontFamily => useSerif ? 'serif' : null;
}
