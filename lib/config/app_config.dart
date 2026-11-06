import 'package:shared_preferences/shared_preferences.dart';

/// Local reading and display preferences. Network services are opt-in.
class AppConfig {
  AppConfig._();
  static final AppConfig instance = AppConfig._();
  SharedPreferences? _prefs;
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SharedPreferences get _p {
    assert(_prefs != null, 'Initialize AppConfig before use');
    return _prefs!;
  }
  // ── App preferences ──────────────────────────────────────────────────

  /// Reading mode: 'light', 'dark', 'sepia'.
  String get readingMode => _p.getString('reading_mode') ?? 'light';
  set readingMode(String mode) => _p.setString('reading_mode', mode);

  /// Bookshelf view mode: 'grid' or 'list'.
  String get bookshelfViewMode => _p.getString('bookshelf_view') ?? 'list';
  set bookshelfViewMode(String mode) => _p.setString('bookshelf_view', mode);

  /// Bookshelf sort: 'recent', 'title', 'author', 'added'.
  String get bookshelfSort => _p.getString('bookshelf_sort') ?? 'recent';
  set bookshelfSort(String sort) => _p.setString('bookshelf_sort', sort);

  // ── Word card (Serverless 单词卡片) ────────────────────────────────
  // 火山函数计算 HTTP 触发器的公网 URL 与 App 鉴权 Token。
  // 在「我的 → 单词卡片 → 右上角设置」里修改，无需改代码重编译。

  static const _keyWordCardFunctionUrl = 'word_card_function_url';
  static const _keyWordCardAppToken = 'word_card_app_token';

  String get wordCardFunctionUrl => _p.getString(_keyWordCardFunctionUrl) ?? '';
  set wordCardFunctionUrl(String url) =>
      _p.setString(_keyWordCardFunctionUrl, url.trim());

  String get wordCardAppToken => _p.getString(_keyWordCardAppToken) ?? '';
  set wordCardAppToken(String token) =>
      _p.setString(_keyWordCardAppToken, token.trim());

  // ── EPUB 精确续读位置 ─────────────────────────────────────────────
  // 格式 "sectionIndex:intraRatio"（intraRatio = 章节内滚动比例 0~1）。
  // progress 列只存章节级进度，章节内偏移存在这里，两者配合实现
  // 「退出后下次进入还在上次读到的那一段」。
  static const _keyEpubPosPrefix = 'epub_pos_';

  String? epubPosition(String bookId) =>
      _p.getString('$_keyEpubPosPrefix$bookId');

  void setEpubPosition(String bookId, String position) =>
      _p.setString('$_keyEpubPosPrefix$bookId', position);

  // ── readest 引擎阅读进度（CFI 精确锚点） ──────────────────────────
  static const _keyReadestCfiPrefix = 'readest_cfi_';

  String? readestCfi(String bookId) =>
      _p.getString('$_keyReadestCfiPrefix$bookId');

  void setReadestCfi(String bookId, String cfi) =>
      _p.setString('$_keyReadestCfiPrefix$bookId', cfi);

  // ── readest 阅读设置（全局持久化，readest 同款行为） ───────────────
  static const _keyReadestStyle = 'readest_style_json';
  static const _keyReadestAnimated = 'readest_animated';

  /// 阅读样式 JSON（ReadestStyleConfig.toJson/fromJson）。
  String? get readestStyleJson => _p.getString(_keyReadestStyle);

  void setReadestStyleJson(String json) => _p.setString(_keyReadestStyle, json);

  /// 翻页动画开关（默认关，与旧版本行为一致）。
  bool get readestAnimated => _p.getBool(_keyReadestAnimated) ?? false;

  void setReadestAnimated(bool v) => _p.setBool(_keyReadestAnimated, v);

  // ── 用户头像 ─────────────────────────────────────────────────────
  // 头像图片保存在 Documents/avatar/ 下（App 私有目录，随云同步备份）。
  static const _keyAvatarPath = 'user_avatar_path';

  String? get avatarPath => _p.getString(_keyAvatarPath);

  set avatarPath(String? path) {
    if (path == null || path.isEmpty) {
      _p.remove(_keyAvatarPath);
    } else {
      _p.setString(_keyAvatarPath, path);
    }
  }

  // ── 截屏/录屏开关 ─────────────────────────────────────────────────
  // 默认允许。App 自身从不主动加 FLAG_SECURE；这个开关配合原生通道
  // 显式清除/设置 flag（个别设备 ROM 或第三方组件可能运行时加上，
  // 导致「涉及隐私/版权的内容不能截屏」）。
  static const _keyAllowScreenshot = 'privacy.allow_screenshot';

  bool get allowScreenshot => _p.getBool(_keyAllowScreenshot) ?? true;

  set allowScreenshot(bool v) => _p.setBool(_keyAllowScreenshot, v);

  // ── 自建版本更新 ─────────────────────────────────────────────────
  // TOS（火山引擎对象存储）等静态托管上放 update.json + APK；
  // 这里配置 update.json 的公网地址。留空 = 不检查更新。
  static const _keyUpdateJsonUrl = 'update.json_url';
  static const _keyAutoUpdate = 'update.auto_enabled';
  static const _keyLastUpdateCheck = 'update.last_check';

  String get updateJsonUrl => _p.getString(_keyUpdateJsonUrl) ?? '';

  set updateJsonUrl(String url) => _p.setString(_keyUpdateJsonUrl, url.trim());

  /// 启动后自动检查更新（默认开，24h 节流）。
  bool get autoUpdateEnabled => _p.getBool(_keyAutoUpdate) ?? true;

  set autoUpdateEnabled(bool v) => _p.setBool(_keyAutoUpdate, v);

  int? get lastUpdateCheckMs => _p.getInt(_keyLastUpdateCheck);

  set lastUpdateCheckMs(int? ms) {
    if (ms == null) {
      _p.remove(_keyLastUpdateCheck);
    } else {
      _p.setInt(_keyLastUpdateCheck, ms);
    }
  }
}
