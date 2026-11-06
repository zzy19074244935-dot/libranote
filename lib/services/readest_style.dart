/// readest 阅读样式系统（移植自 readest 前端 `styles/themes.ts`、
/// `services/constants.ts` 与 `utils/style.ts` 的常量与生成逻辑）。
///
/// 生成 foliate-js `renderer.setStyles()` 所需的 CSS 文本，主题色值 1:1
/// 取自 readest 的 11 套内置主题（light/dark 各一套 fg/bg/primary）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 一套阅读主题（fg = 正文色、bg = 纸面背景、primary = 强调色/链接色）。
class ReadestThemeColors {
  final int fg;
  final int bg;
  final int primary;

  const ReadestThemeColors(this.fg, this.bg, this.primary);
}

/// readest 11 套内置主题（styles/themes.ts:120-209）。
const Map<String, ({ReadestThemeColors light, ReadestThemeColors dark})>
    readestThemes = {
  'default': (
    light: ReadestThemeColors(0xFF171717, 0xFFFFFFFF, 0xFF0066CC),
    dark: ReadestThemeColors(0xFFE0E0E0, 0xFF222222, 0xFF77BBEE),
  ),
  'gray': (
    light: ReadestThemeColors(0xFF222222, 0xFFE0E0E0, 0xFF4488CC),
    dark: ReadestThemeColors(0xFFC6C6C6, 0xFF444444, 0xFF88CCEE),
  ),
  'sepia': (
    light: ReadestThemeColors(0xFF5B4636, 0xFFF1E8D0, 0xFF008B8B),
    dark: ReadestThemeColors(0xFFFFD595, 0xFF342E25, 0xFF48D1CC),
  ),
  'grass': (
    light: ReadestThemeColors(0xFF232C16, 0xFFD7DBBD, 0xFF177B4D),
    dark: ReadestThemeColors(0xFFD8DEBA, 0xFF333627, 0xFFA6D608),
  ),
  'cherry': (
    light: ReadestThemeColors(0xFF4E1609, 0xFFF0D1D5, 0xFFDE3838),
    dark: ReadestThemeColors(0xFFE5C4C8, 0xFF462F32, 0xFFFF646E),
  ),
  'sky': (
    light: ReadestThemeColors(0xFF262D48, 0xFFCEDEF5, 0xFF2D53E5),
    dark: ReadestThemeColors(0xFFBABEE1, 0xFF282E47, 0xFFFF646E),
  ),
  'solarized': (
    light: ReadestThemeColors(0xFF586E75, 0xFFFDF6E3, 0xFF268BD2),
    dark: ReadestThemeColors(0xFF93A1A1, 0xFF002B36, 0xFF268BD2),
  ),
  'gruvbox': (
    light: ReadestThemeColors(0xFF3C3836, 0xFFFBF1C7, 0xFF076678),
    dark: ReadestThemeColors(0xFFEBDDB2, 0xFF282828, 0xFF83A598),
  ),
  'nord': (
    light: ReadestThemeColors(0xFF2E3440, 0xFFECEFF4, 0xFF5E81AC),
    dark: ReadestThemeColors(0xFFD8DEE9, 0xFF2E3440, 0xFF88C0D0),
  ),
  'contrast': (
    light: ReadestThemeColors(0xFF000000, 0xFFFFFFFF, 0xFF4488CC),
    dark: ReadestThemeColors(0xFFFFFFFF, 0xFF000000, 0xFF88CCEE),
  ),
  'sunset': (
    light: ReadestThemeColors(0xFF423126, 0xFFFFF7F0, 0xFFFE6B64),
    dark: ReadestThemeColors(0xFFF6E1D7, 0xFF3C2B25, 0xFFFF9C94),
  ),
};

/// 高亮色（constants.ts:263-269，tailwind 400 系列）。
const Map<String, int> readestHighlightColors = {
  'red': 0xFFF87171,
  'yellow': 0xFFFACC15,
  'green': 0xFF4ADE80,
  'blue': 0xFF60A5FA,
  'violet': 0xFFA78BFA,
};

/// 字体栈（constants.ts 的字体列表；移动端用合理 fallback）。
const Map<String, String> readestFontStacks = {
  'Serif':
      "'Bitter', 'Literata', 'Georgia', 'Times New Roman', 'Noto Serif SC', serif",
  'Sans-serif':
      "'Roboto', 'Helvetica Neue', 'Noto Sans SC', sans-serif",
  'Monospace': "'Consolas', 'Cascadia Mono', monospace",
};

/// 阅读排版配置（对应 readest ViewSettings 的核心项与默认值）。
class ReadestStyleConfig {
  double fontSize; // 8~30，默认 16（readest 移动端 ×1.25，这里直接用绝对 px）
  double lineHeight; // 0.8~2.4，默认 1.4
  double marginTop; // 默认 44
  double marginBottom; // 默认 44
  double marginLeft; // 默认 16
  double marginRight; // 默认 16
  double paragraphMarginEm; // 默认 0.6
  double textIndentEm; // 默认 0（CJK 2）
  bool fullJustification; // 默认 false（移动端）
  bool hyphenation; // 默认 true
  int fontWeight; // 默认 400（readest DEFAULT_BOOK_FONT.fontWeight）
  double letterSpacingEm; // 默认 0
  double wordSpacingEm; // 默认 0
  String fontFamily; // 'Serif' | 'Sans-serif' | 'Monospace'
  String themeId; // readestThemes 的 key
  bool dark; // 使用该主题的 dark 配色

  // ── 布局（readest DEFAULT_BOOK_LAYOUT，随样式一起持久化） ─────────
  bool scrolled; // false=分页 paginated / true=连续滚动 scrolled
  int maxColumns; // 1~2（分页模式的分栏数）
  double gapPercent; // 列间距百分比，默认 5
  String pdfZoomMode; // fit-page | fit-width | original-size | custom
  double pdfScale; // custom 模式的缩放百分比 50~500
  bool pdfThemeApplied; // 主题应用到 PDF 纸面（applyThemeToPDF）

  ReadestStyleConfig({
    this.fontSize = 16,
    this.lineHeight = 1.4,
    this.marginTop = 44,
    this.marginBottom = 44,
    this.marginLeft = 16,
    this.marginRight = 16,
    this.paragraphMarginEm = 0.6,
    this.textIndentEm = 0,
    this.fullJustification = false,
    this.hyphenation = true,
    this.fontWeight = 400,
    this.letterSpacingEm = 0,
    this.wordSpacingEm = 0,
    this.fontFamily = 'Serif',
    this.themeId = 'default',
    this.dark = false,
    this.scrolled = false,
    this.maxColumns = 1,
    this.gapPercent = 5,
    this.pdfZoomMode = 'fit-page',
    this.pdfScale = 100,
    this.pdfThemeApplied = false,
  });

  // ── 持久化（AppConfig.readestStyleJson 存取，readest 全局设置同款行为） ──

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'marginTop': marginTop,
        'marginBottom': marginBottom,
        'marginLeft': marginLeft,
        'marginRight': marginRight,
        'paragraphMarginEm': paragraphMarginEm,
        'textIndentEm': textIndentEm,
        'fullJustification': fullJustification,
        'hyphenation': hyphenation,
        'fontWeight': fontWeight,
        'letterSpacingEm': letterSpacingEm,
        'wordSpacingEm': wordSpacingEm,
        'fontFamily': fontFamily,
        'themeId': themeId,
        'dark': dark,
        'scrolled': scrolled,
        'maxColumns': maxColumns,
        'gapPercent': gapPercent,
        'pdfZoomMode': pdfZoomMode,
        'pdfScale': pdfScale,
        'pdfThemeApplied': pdfThemeApplied,
      };

  /// 从 JSON 恢复；任何字段缺失/损坏都回落默认值（设置不能崩阅读器）。
  factory ReadestStyleConfig.fromJson(String? json) {
    final cfg = ReadestStyleConfig();
    if (json == null || json.isEmpty) return cfg;
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      cfg.fontSize = (m['fontSize'] as num?)?.toDouble() ?? cfg.fontSize;
      cfg.lineHeight = (m['lineHeight'] as num?)?.toDouble() ?? cfg.lineHeight;
      cfg.marginTop = (m['marginTop'] as num?)?.toDouble() ?? cfg.marginTop;
      cfg.marginBottom =
          (m['marginBottom'] as num?)?.toDouble() ?? cfg.marginBottom;
      cfg.marginLeft = (m['marginLeft'] as num?)?.toDouble() ?? cfg.marginLeft;
      cfg.marginRight =
          (m['marginRight'] as num?)?.toDouble() ?? cfg.marginRight;
      cfg.paragraphMarginEm = (m['paragraphMarginEm'] as num?)?.toDouble() ??
          cfg.paragraphMarginEm;
      cfg.textIndentEm =
          (m['textIndentEm'] as num?)?.toDouble() ?? cfg.textIndentEm;
      cfg.fullJustification =
          (m['fullJustification'] as bool?) ?? cfg.fullJustification;
      cfg.hyphenation = (m['hyphenation'] as bool?) ?? cfg.hyphenation;
      cfg.fontWeight = (m['fontWeight'] as num?)?.toInt() ?? cfg.fontWeight;
      cfg.letterSpacingEm =
          (m['letterSpacingEm'] as num?)?.toDouble() ?? cfg.letterSpacingEm;
      cfg.wordSpacingEm =
          (m['wordSpacingEm'] as num?)?.toDouble() ?? cfg.wordSpacingEm;
      cfg.fontFamily =
          (m['fontFamily'] as String?) ?? cfg.fontFamily;
      cfg.themeId = (m['themeId'] as String?) ?? cfg.themeId;
      cfg.dark = (m['dark'] as bool?) ?? cfg.dark;
      cfg.scrolled = (m['scrolled'] as bool?) ?? cfg.scrolled;
      cfg.maxColumns = (m['maxColumns'] as num?)?.toInt() ?? cfg.maxColumns;
      cfg.gapPercent =
          (m['gapPercent'] as num?)?.toDouble() ?? cfg.gapPercent;
      cfg.pdfZoomMode =
          (m['pdfZoomMode'] as String?) ?? cfg.pdfZoomMode;
      cfg.pdfScale = (m['pdfScale'] as num?)?.toDouble() ?? cfg.pdfScale;
      cfg.pdfThemeApplied =
          (m['pdfThemeApplied'] as bool?) ?? cfg.pdfThemeApplied;
    } catch (e) {
      debugPrint('[Reader] style restore failed: $e');
    }
    return cfg;
  }

  /// 当前主题色。
  ReadestThemeColors get colors {
    final entry = readestThemes[themeId] ?? readestThemes['default']!;
    return dark ? entry.dark : entry.light;
  }

  /// 生成 foliate-js `setStyles()` 用的 CSS。
  String buildCss() {
    final c = colors;
    final bg = '#${(c.bg & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final fg = '#${(c.fg & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final primary =
        '#${(c.primary & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final stack = readestFontStacks[fontFamily] ?? readestFontStacks['Serif']!;
    final align = fullJustification ? 'justify' : 'left';

    return '''
html {
  color-scheme: ${dark ? 'dark' : 'light'};
  background: $bg;
}
body {
  margin: 0;
  padding: ${marginTop}px ${marginRight}px ${marginBottom}px ${marginLeft}px;
  color: $fg;
  background: transparent;
  font-size: ${fontSize}px;
  line-height: $lineHeight;
  font-family: $stack;
  font-weight: $fontWeight;
  letter-spacing: ${letterSpacingEm}em;
  word-spacing: ${wordSpacingEm}em;
  hyphens: ${hyphenation ? 'auto' : 'manual'};
}
p, blockquote, dd, li {
  margin-block: ${paragraphMarginEm}em;
  text-align: $align;
}
p { text-indent: ${textIndentEm}em; }
::selection { background: ${primary}55; }
a { color: $primary; }
img { max-width: 100%; height: auto; }
''';
  }
}
