import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
// `show` keeps the plugin-backed `openDatabase`/`databaseFactory` from
// `sqflite` in scope on mobile; only the desktop backend comes from here.
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit, databaseFactoryFfi;

import '../config/constants.dart';
import '../models/models.dart';

/// SQLite-backed local storage for bookshelf and annotations.
class StorageService {
  Database? _db;

  /// 数据变更钩子：笔记/画布/备忘录/AI 对话写入后触发一次（Phase 5
  /// 云同步的「文件变更后同步」入口）。main.dart 里指到
  /// `SyncService.notifyFileChanged`；null = 不触发（无副作用）。
  static void Function()? onDataChanged;

  void _notifyDataChanged() {
    onDataChanged?.call();
  }

  /// In-flight open, so two concurrent callers share one `openDatabase`.
  ///
  /// `_db ??= await _initDb()` has an await between the read and the write, so
  /// the bookshelf provider and the reader provider both opened the file on
  /// startup.
  Future<Database>? _opening;

  /// Whether the desktop FFI backend has been installed on [databaseFactory].
  static bool _ffiInstalled = false;

  /// Point sqflite at a backend that actually exists on this platform.
  ///
  /// The `sqflite` plugin ships implementations for Android, iOS and macOS
  /// only — on Windows and Linux there is no registered platform channel, so
  /// `openDatabase` throws `MissingPluginException`. Every call site here sits
  /// behind a `try`/`catch`, so the failure surfaced as an empty bookshelf and
  /// a "导入失败" snackbar rather than as a crash: imported files were copied
  /// to `Documents/books` and then never recorded.
  static void _ensureFactory() {
    if (_ffiInstalled) return;
    _ffiInstalled = true;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      debugPrint('[Storage] using sqflite FFI backend (desktop)');
    }
  }

  // ── Init ───────────────────────────────────────────────────────────

  Future<Database> get database async {
    final open = _db;
    if (open != null) return open;
    return _opening ??= _initDb().then((db) {
      _db = db;
      _opening = null;
      return db;
    });
  }

  Future<Database> _initDb() async {
    _ensureFactory();

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, AppConstants.dbName);
    debugPrint('[Storage] opening $path');

    return openDatabase(
      path,
      version: AppConstants.dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// SQLite ignores `ON DELETE CASCADE` unless foreign keys are switched on
  /// per connection — [removeBook] relies on it to clear a book's annotations.
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE bookshelf (
        id          TEXT PRIMARY KEY,
        hash        TEXT NOT NULL DEFAULT '',
        title       TEXT NOT NULL,
        author      TEXT NOT NULL,
        cover_url   TEXT,
        format      TEXT,
        local_path  TEXT,
        progress    INTEGER DEFAULT 0,
        last_read   INTEGER,
        download_date INTEGER,
        folder      TEXT NOT NULL DEFAULT ''
      )
    ''');

    // The `location` and `text` columns are kept from v1 for backward compat.
    // SQLite 3.35.0+ supports DROP COLUMN, but the Windows sqlite3.dll bundled
    // with sqflite_common_ffi 2.3.7 is older, so these columns must stay and
    // must still be written on every insert (both are NOT NULL with no default).
    await db.execute('''
      CREATE TABLE annotations (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id       TEXT NOT NULL,
        type          TEXT NOT NULL DEFAULT 'highlight',
        location      TEXT NOT NULL,
        text          TEXT NOT NULL,
        color         TEXT,
        created_at    INTEGER NOT NULL,
        anchor_kind   TEXT,
        section_index INTEGER,
        page_index    INTEGER,
        start_offset  INTEGER,
        end_offset    INTEGER,
        rects         TEXT,
        prefix        TEXT,
        suffix        TEXT,
        quoted_text   TEXT,
        note          TEXT,
        tags          TEXT,
        book_title    TEXT,
        updated_at    INTEGER,
        source        TEXT NOT NULL DEFAULT 'manual',
        style         TEXT NOT NULL DEFAULT 'highlight',
        image_path    TEXT,
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('CREATE INDEX idx_annotations_book ON annotations(book_id)');

    // Word（DOCX）批注：锚点 = 段落索引 + 字符偏移（Phase 4）。
    // x/y/w/font_size/rotation = 浮动文本框（style='textbox'）的几何属性
    //（x/y/w 相对正文区 0~1，font_size 为 pt，0 = 用阅读器默认字号）。
    await db.execute('''
      CREATE TABLE docx_notes (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id      TEXT NOT NULL,
        para_index   INTEGER NOT NULL,
        start_offset INTEGER NOT NULL,
        end_offset   INTEGER NOT NULL,
        quoted_text  TEXT NOT NULL,
        note         TEXT NOT NULL DEFAULT '',
        color        TEXT,
        style        TEXT NOT NULL DEFAULT 'highlight',
        source       TEXT NOT NULL DEFAULT 'manual',
        image_path   TEXT,
        x            REAL NOT NULL DEFAULT 0,
        y            REAL NOT NULL DEFAULT 0,
        w            REAL NOT NULL DEFAULT 0.4,
        font_size    REAL NOT NULL DEFAULT 0,
        rotation     REAL NOT NULL DEFAULT 0,
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_docx_notes_book ON docx_notes(book_id)');

    // 小说书签：结构化锚点（与批注同一套 AnchorKind），可精确跳回章节/页。
    await db.execute('''
      CREATE TABLE bookmarks (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id       TEXT NOT NULL,
        label         TEXT,
        anchor_kind   TEXT NOT NULL DEFAULT 'plain',
        section_index INTEGER,
        page_index    INTEGER,
        start_offset  INTEGER,
        created_at    INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_bookmarks_book ON bookmarks(book_id)');

    // 备忘录：内容为 JSON 数组字符串（块列表），font_family 控制整篇字体。
    await db.execute('''
      CREATE TABLE memo (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        title       TEXT NOT NULL DEFAULT '',
        content     TEXT NOT NULL DEFAULT '[]',
        font_family TEXT NOT NULL DEFAULT 'default',
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )
    ''');

    // 无边记画布：内容为 JSON 字符串（笔迹/文本/图片/表格四块）。
    await db.execute('''
      CREATE TABLE whiteboard (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        title      TEXT NOT NULL DEFAULT '',
        content    TEXT NOT NULL DEFAULT '{}',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // PDF 手写批注：每页一行，strokes 是 InkStroke 的 JSON 数组（归一化坐标）。
    await db.execute('''
      CREATE TABLE pdf_ink (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id    TEXT NOT NULL,
        page_index INTEGER NOT NULL,
        strokes    TEXT NOT NULL DEFAULT '[]',
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pdf_ink_book_page ON pdf_ink(book_id, page_index)');
    // 每页只允许一行笔迹：配合 upsert 语义，防止历史版本的重复行问题。
    await db.execute(
        'CREATE UNIQUE INDEX ux_pdf_ink_book_page ON pdf_ink(book_id, page_index)');

    // 单词卡片：拍照 → 火山函数生成 → 下载到本地，离线查看/朗读。
    await db.execute('''
      CREATE TABLE word_cards (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        chinese_word        TEXT NOT NULL DEFAULT '',
        english_word        TEXT NOT NULL DEFAULT '',
        uk_phonetic         TEXT NOT NULL DEFAULT '',
        us_phonetic         TEXT NOT NULL DEFAULT '',
        definition          TEXT NOT NULL DEFAULT '',
        chinese_definition  TEXT NOT NULL DEFAULT '',
        card_image_url      TEXT,
        card_image_path     TEXT,
        uk_audio_url        TEXT,
        uk_audio_path       TEXT,
        us_audio_url        TEXT,
        us_audio_path       TEXT,
        created_at          INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_word_cards_created ON word_cards(created_at)');

    // readest 引擎笔记（CFI 锚点：书签/高亮/笔记）。
    await db.execute('''
      CREATE TABLE readest_notes (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id    TEXT NOT NULL,
        cfi        TEXT NOT NULL,
        text       TEXT NOT NULL DEFAULT '',
        color      TEXT,
        style      TEXT NOT NULL DEFAULT 'highlight',
        note       TEXT NOT NULL DEFAULT '',
        image_path TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_readest_notes_book ON readest_notes(book_id)');

    // ── AI 轨道（v11）──────────────────────────────────────────────
    // ai_notes.quoted_text 是 NOT NULL：原文必填（方案 §2.8 铁律）。
    // ai_conversations.file_id 不设外键——书籍删除后对话历史仍保留。
    await db.execute('''
      CREATE TABLE ai_conversations (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id    TEXT,
        file_type  TEXT,
        file_name  TEXT NOT NULL DEFAULT '',
        title      TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_ai_conv_updated ON ai_conversations(updated_at)');

    await db.execute('''
      CREATE TABLE ai_messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        role            TEXT NOT NULL,
        content         TEXT NOT NULL,
        token_usage     INTEGER NOT NULL DEFAULT 0,
        created_at      INTEGER NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES ai_conversations(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_ai_msg_conv ON ai_messages(conversation_id)');

    await db.execute('''
      CREATE TABLE ai_prompts (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        title      TEXT NOT NULL,
        content    TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_notes (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id         TEXT NOT NULL,
        file_type       TEXT NOT NULL DEFAULT 'epub',
        anchor          TEXT NOT NULL DEFAULT '{}',
        quoted_text     TEXT NOT NULL,
        content         TEXT NOT NULL DEFAULT '',
        image_path      TEXT,
        conversation_id INTEGER,
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL,
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_ai_notes_book ON ai_notes(book_id)');

    await db.execute('''
      CREATE TABLE tags (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        name  TEXT NOT NULL UNIQUE,
        color TEXT NOT NULL DEFAULT '#4ade80'
      )
    ''');

    await db.execute('''
      CREATE TABLE book_tags (
        book_id TEXT NOT NULL,
        tag_id  INTEGER NOT NULL,
        PRIMARY KEY (book_id, tag_id),
        FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE,
        FOREIGN KEY (tag_id)  REFERENCES tags(id) ON DELETE CASCADE
      )
    ''');

    // 拍照翻译记录（v14）：识别原文 + 译文 + 图片路径 + 目标语言。
    await db.execute('''
      CREATE TABLE translate_records (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        image_path      TEXT,
        source_text     TEXT NOT NULL,
        translated_text TEXT NOT NULL DEFAULT '',
        target          TEXT NOT NULL DEFAULT 'zh-CN',
        created_at      INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_translate_records_created ON translate_records(created_at)');

    await _ensureUsageTable(db);

    // Agent 任务（v16）：计划/步骤/结果，后台执行与历史。
    // ⚠️ 必须在这里建：onCreate 只在「全新安装」时跑，缺了它全新库
    // 会报 no such table: ai_tasks（v16 修复：曾只写在 onUpgrade 里）。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_tasks (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        goal       TEXT NOT NULL,
        status     TEXT NOT NULL DEFAULT 'planning',
        steps      TEXT NOT NULL DEFAULT '[]',
        result     TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_ai_tasks_created ON ai_tasks(created_at)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      debugPrint('[Storage] migrating DB 1 → 2: annotation anchor columns');
      try {
        // Add new structured-anchor columns (safe to re-run with IF NOT EXISTS
        // pattern; sqflite throws on duplicate column, so catch-and-skip).

        // The try/catch-per-column pattern handles the case where a previous
        // migration attempt partially succeeded before crashing.
        for (final col in [
          'ALTER TABLE annotations ADD COLUMN anchor_kind TEXT',
          'ALTER TABLE annotations ADD COLUMN section_index INTEGER',
          'ALTER TABLE annotations ADD COLUMN page_index INTEGER',
          'ALTER TABLE annotations ADD COLUMN start_offset INTEGER',
          'ALTER TABLE annotations ADD COLUMN end_offset INTEGER',
          'ALTER TABLE annotations ADD COLUMN rects TEXT',
          'ALTER TABLE annotations ADD COLUMN prefix TEXT',
          'ALTER TABLE annotations ADD COLUMN suffix TEXT',
          'ALTER TABLE annotations ADD COLUMN quoted_text TEXT',
          'ALTER TABLE annotations ADD COLUMN note TEXT',
          'ALTER TABLE annotations ADD COLUMN tags TEXT',
          'ALTER TABLE annotations ADD COLUMN book_title TEXT',
          'ALTER TABLE annotations ADD COLUMN updated_at INTEGER',
        ]) {
          try {
            await db.execute(col);
          } catch (e) {
            // Column already exists — previous partial migration, ignore.
            debugPrint('[Storage] migration skip (already present): $e');
          }
        }

        // Migrate old rows: text → quoted_text, anchor_kind = 'plain',
        // updated_at = created_at. Only touches rows that haven't been
        // migrated yet.
        await db.execute('''
          UPDATE annotations
          SET quoted_text = text,
              anchor_kind = 'plain',
              updated_at = created_at
          WHERE quoted_text IS NULL
        ''');

        debugPrint('[Storage] migration 1 → 2 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration 1 → 2 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 3) {
      debugPrint('[Storage] migrating DB → 3: bookmarks + memo tables');
      try {
        // IF NOT EXISTS 保证老库升级、以及半途失败的迁移都能安全重跑。
        await db.execute('''
          CREATE TABLE IF NOT EXISTS bookmarks (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id       TEXT NOT NULL,
            label         TEXT,
            anchor_kind   TEXT NOT NULL DEFAULT 'plain',
            section_index INTEGER,
            page_index    INTEGER,
            start_offset  INTEGER,
            created_at    INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_id)');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS memo (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT NOT NULL DEFAULT '',
            content     TEXT NOT NULL DEFAULT '[]',
            font_family TEXT NOT NULL DEFAULT 'default',
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL
          )
        ''');
        debugPrint('[Storage] migration → 3 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 3 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 4) {
      debugPrint('[Storage] migrating DB → 4: whiteboard table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS whiteboard (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            title      TEXT NOT NULL DEFAULT '',
            content    TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        debugPrint('[Storage] migration → 4 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 4 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 5) {
      debugPrint('[Storage] migrating DB → 5: pdf_ink table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS pdf_ink (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id    TEXT NOT NULL,
            page_index INTEGER NOT NULL,
            strokes    TEXT NOT NULL DEFAULT '[]',
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_pdf_ink_book_page ON pdf_ink(book_id, page_index)');
        debugPrint('[Storage] migration → 5 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 5 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 6) {
      debugPrint('[Storage] migrating DB → 6: folder + source columns');
      try {
        for (final col in [
          "ALTER TABLE bookshelf ADD COLUMN folder TEXT NOT NULL DEFAULT ''",
          "ALTER TABLE annotations ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'",
        ]) {
          try {
            await db.execute(col);
          } catch (e) {
            // Column already exists — previous partial migration, ignore.
            debugPrint('[Storage] migration skip (already present): $e');
          }
        }
        debugPrint('[Storage] migration → 6 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 6 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 7) {
      debugPrint('[Storage] migrating DB → 7: pdf_ink unique index');
      try {
        // 历史版本的 savePdfInk 用 INSERT OR REPLACE 但表没有唯一约束，
        // 会在同一 (book_id, page_index) 攒出多行——删掉旧的，只留每页
        // 最新一条（id 最大），再建唯一索引防止复发。
        await db.execute('''
          DELETE FROM pdf_ink
          WHERE id NOT IN (
            SELECT MAX(id) FROM pdf_ink GROUP BY book_id, page_index
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS ux_pdf_ink_book_page
          ON pdf_ink(book_id, page_index)
        ''');
        debugPrint('[Storage] migration → 7 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 7 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 8) {
      debugPrint('[Storage] migrating DB → 8: word_cards table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS word_cards (
            id                  INTEGER PRIMARY KEY AUTOINCREMENT,
            chinese_word        TEXT NOT NULL DEFAULT '',
            english_word        TEXT NOT NULL DEFAULT '',
            uk_phonetic         TEXT NOT NULL DEFAULT '',
            us_phonetic         TEXT NOT NULL DEFAULT '',
            definition          TEXT NOT NULL DEFAULT '',
            chinese_definition  TEXT NOT NULL DEFAULT '',
            card_image_url      TEXT,
            card_image_path     TEXT,
            uk_audio_url        TEXT,
            uk_audio_path       TEXT,
            us_audio_url        TEXT,
            us_audio_path       TEXT,
            created_at          INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_word_cards_created '
            'ON word_cards(created_at)');
        debugPrint('[Storage] migration → 8 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 8 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 9) {
      debugPrint('[Storage] migrating DB → 9: readest_notes table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS readest_notes (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id    TEXT NOT NULL,
            cfi        TEXT NOT NULL,
            text       TEXT NOT NULL DEFAULT '',
            color      TEXT,
            style      TEXT NOT NULL DEFAULT 'highlight',
            note       TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_readest_notes_book '
            'ON readest_notes(book_id)');
        debugPrint('[Storage] migration → 9 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 9 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 10) {
      debugPrint('[Storage] migrating DB → 10: usage_days table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS usage_days (
            date       TEXT PRIMARY KEY,
            seconds    INTEGER NOT NULL DEFAULT 0,
            logins     INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        debugPrint('[Storage] migration → 10 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 10 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 11) {
      debugPrint('[Storage] migrating DB → 11: AI tables');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_conversations (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id    TEXT,
            file_type  TEXT,
            file_name  TEXT NOT NULL DEFAULT '',
            title      TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_conv_updated '
            'ON ai_conversations(updated_at)');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL,
            role            TEXT NOT NULL,
            content         TEXT NOT NULL,
            token_usage     INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL,
            FOREIGN KEY (conversation_id) REFERENCES ai_conversations(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_msg_conv '
            'ON ai_messages(conversation_id)');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_prompts (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            title      TEXT NOT NULL,
            content    TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_notes (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id         TEXT NOT NULL,
            file_type       TEXT NOT NULL DEFAULT 'epub',
            anchor          TEXT NOT NULL DEFAULT '{}',
            quoted_text     TEXT NOT NULL,
            content         TEXT NOT NULL DEFAULT '',
            image_path      TEXT,
            conversation_id INTEGER,
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_notes_book ON ai_notes(book_id)');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS tags (
            id    INTEGER PRIMARY KEY AUTOINCREMENT,
            name  TEXT NOT NULL UNIQUE,
            color TEXT NOT NULL DEFAULT '#4ade80'
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS book_tags (
            book_id TEXT NOT NULL,
            tag_id  INTEGER NOT NULL,
            PRIMARY KEY (book_id, tag_id),
            FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE,
            FOREIGN KEY (tag_id)  REFERENCES tags(id) ON DELETE CASCADE
          )
        ''');
        debugPrint('[Storage] migration → 11 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 11 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 12) {
      debugPrint('[Storage] migrating DB → 12: readest_notes image_path');
      try {
        // 部分迁移重跑保护：列已存在则跳过（老 Windows sqlite3 无
        // DROP COLUMN 支持，不能先删再加）。
        try {
          await db.execute(
              "ALTER TABLE readest_notes ADD COLUMN image_path TEXT");
        } catch (e) {
          debugPrint('[Storage] migration skip (already present): $e');
        }
        debugPrint('[Storage] migration → 12 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 12 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 13) {
      debugPrint('[Storage] migrating DB → 13: annotations.style + docx_notes');
      try {
        try {
          await db.execute(
              "ALTER TABLE annotations ADD COLUMN style TEXT NOT NULL "
              "DEFAULT 'highlight'");
        } catch (e) {
          debugPrint('[Storage] migration skip (already present): $e');
        }
        await db.execute('''
          CREATE TABLE IF NOT EXISTS docx_notes (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id      TEXT NOT NULL,
            para_index   INTEGER NOT NULL,
            start_offset INTEGER NOT NULL,
            end_offset   INTEGER NOT NULL,
            quoted_text  TEXT NOT NULL,
            note         TEXT NOT NULL DEFAULT '',
            color        TEXT,
            style        TEXT NOT NULL DEFAULT 'highlight',
            source       TEXT NOT NULL DEFAULT 'manual',
            image_path   TEXT,
            x            REAL NOT NULL DEFAULT 0,
            y            REAL NOT NULL DEFAULT 0,
            w            REAL NOT NULL DEFAULT 0.4,
            font_size    REAL NOT NULL DEFAULT 0,
            rotation     REAL NOT NULL DEFAULT 0,
            created_at   INTEGER NOT NULL,
            updated_at   INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES bookshelf(id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_docx_notes_book '
            'ON docx_notes(book_id)');
        debugPrint('[Storage] migration → 13 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 13 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 14) {
      debugPrint('[Storage] migrating DB → 14: translate_records table + '
          'annotations.image_path');
      try {
        try {
          await db.execute(
              "ALTER TABLE annotations ADD COLUMN image_path TEXT");
        } catch (e) {
          debugPrint('[Storage] migration skip (already present): $e');
        }
        await db.execute('''
          CREATE TABLE IF NOT EXISTS translate_records (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            image_path      TEXT,
            source_text     TEXT NOT NULL,
            translated_text TEXT NOT NULL DEFAULT '',
            target          TEXT NOT NULL DEFAULT 'zh-CN',
            created_at      INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_translate_records_created '
            'ON translate_records(created_at)');
        debugPrint('[Storage] migration → 14 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 14 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 15) {
      debugPrint('[Storage] migrating DB → 15: docx_notes textbox geometry');
      try {
        for (final col in [
          'ALTER TABLE docx_notes ADD COLUMN x REAL NOT NULL DEFAULT 0',
          'ALTER TABLE docx_notes ADD COLUMN y REAL NOT NULL DEFAULT 0',
          'ALTER TABLE docx_notes ADD COLUMN w REAL NOT NULL DEFAULT 0.4',
          'ALTER TABLE docx_notes ADD COLUMN font_size REAL NOT NULL DEFAULT 0',
          'ALTER TABLE docx_notes ADD COLUMN rotation REAL NOT NULL DEFAULT 0',
        ]) {
          try {
            await db.execute(col);
          } catch (e) {
            debugPrint('[Storage] migration skip (already present): $e');
          }
        }
        debugPrint('[Storage] migration → 15 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 15 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 16) {
      debugPrint('[Storage] migrating DB → 16: ai_tasks');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_tasks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            goal       TEXT NOT NULL,
            status     TEXT NOT NULL DEFAULT 'planning',
            steps      TEXT NOT NULL DEFAULT '[]',
            result     TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_tasks_created ON ai_tasks(created_at)');
        debugPrint('[Storage] migration → 16 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 16 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 17) {
      // v17：修复 ai_tasks 只写在 onUpgrade、没写在 onCreate 的问题——
      // 已经升到 v16 的库不会重跑 v16 迁移，这里幂等补建一次。
      debugPrint('[Storage] migrating DB → 17: ensure ai_tasks exists');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_tasks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            goal       TEXT NOT NULL,
            status     TEXT NOT NULL DEFAULT 'planning',
            steps      TEXT NOT NULL DEFAULT '[]',
            result     TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_tasks_created ON ai_tasks(created_at)');
        debugPrint('[Storage] migration → 17 complete');
      } catch (e, st) {
        debugPrint('[Storage] migration → 17 FAILED: $e\n$st');
        rethrow;
      }
    }
    if (oldVersion < 18) await _ensureUsageTable(db);

  }

  Future<void> _ensureUsageTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS usage_days (
        date TEXT PRIMARY KEY,
        seconds INTEGER NOT NULL DEFAULT 0,
        logins INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ── Bookshelf CRUD ─────────────────────────────────────────────────

  /// Add or update a downloaded book.
  ///
  /// ⚠️ 不能用 `ConflictAlgorithm.replace`：SQLite 的 REPLACE 是「先 DELETE 再
  /// INSERT」，而本库开着 `PRAGMA foreign_keys = ON`，DELETE 会**级联删掉这本
  /// 书的所有批注、书签和 PDF 手写笔迹**——用户重新下载/重新导入同一本书时，
  /// 之前的笔记和笔迹全没了（「PDF 笔迹无法保存」的根因之一）。
  /// 改用「先 UPDATE、影响 0 行再 INSERT」的纯 upsert，级联不会触发。
  Future<void> upsertBook(Book book) async {
    final db = await database;
    final values = {
      'hash': book.hash,
      'title': book.title,
      'author': book.author,
      'cover_url': book.coverUrl,
      'format': book.extension,
      'local_path': book.localPath,
      'progress': book.progressPercent ?? 0,
      'last_read': book.lastReadAt?.millisecondsSinceEpoch,
      'download_date': (book.downloadDate ?? DateTime.now()).millisecondsSinceEpoch,
      'folder': book.folder,
    };
    final updated = await db.update(
      'bookshelf',
      values,
      where: 'id = ?',
      whereArgs: [book.id],
    );
    if (updated == 0) {
      await db.insert('bookshelf', {'id': book.id, ...values});
    }
  }

  /// 把书移动到某个文件夹（空字符串 = 未分类）。
  Future<void> updateBookFolder(String bookId, String folder) async {
    final db = await database;
    await db.update(
      'bookshelf',
      {'folder': folder},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// 所有非空文件夹名（去重排序）。
  Future<List<String>> getFolders() async {
    final db = await database;
    final rows = await db.query(
      'bookshelf',
      columns: ['folder'],
      distinct: true,
      where: "folder != ''",
    );
    final result = <String>{
      for (final row in rows) row['folder'] as String,
    };
    final list = result.toList()..sort();
    return list;
  }

  /// Get all books in the local bookshelf, most-recent first.
  Future<List<Book>> getBookshelf() async {
    final db = await database;
    final rows = await db.query('bookshelf', orderBy: 'last_read DESC');
    return rows.map(Book.fromDbRow).toList();
  }

  /// Get a single book by id.
  Future<Book?> getBook(String id) async {
    final db = await database;
    final rows = await db.query('bookshelf', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Book.fromDbRow(rows.first);
  }

  /// Update reading progress (0-100).
  Future<void> updateProgress(String bookId, int progress) async {
    final db = await database;
    await db.update(
      'bookshelf',
      {'progress': progress, 'last_read': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// Remove a book from the bookshelf (optionally delete local file).
  Future<void> removeBook(String bookId, {bool deleteFile = false}) async {
    final db = await database;
    if (deleteFile) {
      final book = await getBook(bookId);
      if (book?.localPath != null) {
        try {
          await File(book!.localPath!).delete();
        } catch (_) {}
      }
    }
    // Annotations are cascade-deleted.
    await db.delete('bookshelf', where: 'id = ?', whereArgs: [bookId]);
  }

  // ── Annotations CRUD ───────────────────────────────────────────────

  /// Save a new annotation.
  ///
  /// Writes both the legacy `location`/`text` columns (NOT NULL, cannot be
  /// dropped on this SQLite version) and the new structured columns.
  Future<int> insertAnnotation(Annotation a) async {
    final db = await database;
    final id = await db.insert('annotations', {
      'book_id': a.bookId,
      'book_title': a.bookTitle,
      'type': a.type.name,
      // Legacy NOT NULL columns — still required.
      'location': a.anchor.display,
      'text': a.quotedText,
      // New structured columns.
      'anchor_kind': a.anchor.kind.name,
      'section_index': a.anchor.sectionIndex,
      'page_index': a.anchor.pageIndex,
      'start_offset': a.anchor.startOffset,
      'end_offset': a.anchor.endOffset,
      'rects': a.anchor.rects.isNotEmpty
          ? NormRect.listToJson(a.anchor.rects)
          : null,
      'prefix': a.anchor.prefix,
      'suffix': a.anchor.suffix,
      'quoted_text': a.quotedText,
      'note': a.note,
      'color': a.color,
      'style': a.style,
      'tags': a.tags.isNotEmpty ? jsonEncode(a.tags) : null,
      'created_at': a.createdAt.millisecondsSinceEpoch,
      'updated_at': a.updatedAt.millisecondsSinceEpoch,
      'source': a.source,
      'image_path': a.imagePath,
    });
    _notifyDataChanged();
    return id;
  }

  /// Get all annotations for a book, ordered by position (in-book order).
  /// The reader panel wants them in reading order, not creation order.
  Future<List<Annotation>> getAnnotations(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'annotations',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy:
          'section_index ASC, page_index ASC, start_offset ASC, created_at ASC',
    );
    return rows.map(Annotation.fromJson).toList();
  }

  /// Get all annotations across all books, newest first.
  Future<List<Annotation>> getAllAnnotations() async {
    final db = await database;
    final rows = await db.query('annotations', orderBy: 'created_at DESC');
    return rows.map(Annotation.fromJson).toList();
  }

  /// Delete a single annotation by id.
  Future<void> deleteAnnotation(int id) async {
    final db = await database;
    await db.delete('annotations', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  /// Update annotation note text and colour (e.g. editing a note).
  Future<void> updateAnnotation(int id, String newText) async {
    final db = await database;
    await db.update(
      'annotations',
      {
        'note': newText,
        'text': newText, // legacy column — keep in sync for old readers
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyDataChanged();
  }

  /// Full update — note, colour, tags, and refreshed updated_at.
  Future<void> updateAnnotationFull(Annotation a) async {
    final db = await database;
    await db.update(
      'annotations',
      {
        'note': a.note,
        'text': a.quotedText, // legacy
        'location': a.anchor.display, // legacy
        'color': a.color,
        'tags': a.tags.isNotEmpty ? jsonEncode(a.tags) : null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [a.id],
    );
    _notifyDataChanged();
  }

  /// Full-text search across quoted text and notes.
  Future<List<Annotation>> searchAnnotations(String kw) async {
    final db = await database;
    final like = '%$kw%';
    final rows = await db.query(
      'annotations',
      where: 'quoted_text LIKE ? OR note LIKE ?',
      whereArgs: [like, like],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Annotation.fromJson).toList();
  }

  /// All distinct tags across every annotation.
  Future<List<String>> allTags() async {
    final db = await database;
    final rows = await db.query('annotations',
        columns: ['tags'], where: 'tags IS NOT NULL');
    final seen = <String>{};
    for (final row in rows) {
      final raw = row['tags'] as String?;
      if (raw == null || raw.isEmpty) continue;
      try {
        for (final t in (jsonDecode(raw) as List)) {
          if (t is String && t.isNotEmpty) seen.add(t);
        }
      } catch (_) {}
    }
    return seen.toList()..sort();
  }

  // ── Bookmarks CRUD ─────────────────────────────────────────────────

  /// Save a new bookmark. Returns the new row id.
  Future<int> insertBookmark(Bookmark b) async {
    final db = await database;
    return db.insert('bookmarks', {
      'book_id': b.bookId,
      'label': b.label,
      'anchor_kind': b.kind.name,
      'section_index': b.sectionIndex,
      'page_index': b.pageIndex,
      'start_offset': b.startOffset,
      'created_at': b.createdAt.millisecondsSinceEpoch,
    });
  }

  /// All bookmarks for a book, newest first.
  Future<List<Bookmark>> getBookmarks(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'bookmarks',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Bookmark.fromJson).toList();
  }

  /// Delete a single bookmark by id.
  Future<void> deleteBookmark(int id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  // ── Memo CRUD ──────────────────────────────────────────────────────

  /// Create a memo and return its new id.
  Future<int> insertMemo(Memo m) async {
    final db = await database;
    final id = await db.insert('memo', {
      'title': m.title,
      'content': m.contentJson,
      'font_family': m.fontFamily,
      'created_at': m.createdAt.millisecondsSinceEpoch,
      'updated_at': m.updatedAt.millisecondsSinceEpoch,
    });
    _notifyDataChanged();
    return id;
  }

  /// Update an existing memo (title, blocks, font) and refresh updated_at.
  Future<void> updateMemo(Memo m) async {
    final db = await database;
    await db.update(
      'memo',
      {
        'title': m.title,
        'content': m.contentJson,
        'font_family': m.fontFamily,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [m.id],
    );
    _notifyDataChanged();
  }

  /// All memos, most-recently-updated first.
  Future<List<Memo>> getMemos() async {
    final db = await database;
    final rows = await db.query('memo', orderBy: 'updated_at DESC');
    return rows.map(Memo.fromJson).toList();
  }

  /// Delete a memo by id.
  Future<void> deleteMemo(int id) async {
    final db = await database;
    await db.delete('memo', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  // ── Whiteboard CRUD ────────────────────────────────────────────────

  /// Create a whiteboard and return its new id.
  Future<int> insertWhiteboard(Whiteboard wb) async {
    final db = await database;
    final id = await db.insert('whiteboard', {
      'title': wb.title,
      'content': wb.contentJson,
      'created_at': wb.createdAt.millisecondsSinceEpoch,
      'updated_at': wb.updatedAt.millisecondsSinceEpoch,
    });
    _notifyDataChanged();
    return id;
  }

  /// Update an existing whiteboard (title + content) and refresh updated_at.
  Future<void> updateWhiteboard(Whiteboard wb) async {
    final db = await database;
    await db.update(
      'whiteboard',
      {
        'title': wb.title,
        'content': wb.contentJson,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [wb.id],
    );
    _notifyDataChanged();
  }

  /// All whiteboards, most-recently-updated first.
  Future<List<Whiteboard>> getWhiteboards() async {
    final rows = await getWhiteboardRows();
    return rows.map(Whiteboard.fromJson).toList();
  }

  /// 原始画布行（列表页逐行容错解析用：单条坏数据不影响其余画布显示）。
  Future<List<Map<String, Object?>>> getWhiteboardRows() async {
    final db = await database;
    return db.query('whiteboard', orderBy: 'updated_at DESC');
  }

  /// Delete a whiteboard by id.
  Future<void> deleteWhiteboard(int id) async {
    final db = await database;
    await db.delete('whiteboard', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  // ── PDF 手写批注 CRUD ─────────────────────────────────────────────

  /// 读取某本书某一页的手写笔迹（无则返回空列表）。
  ///
  /// 按 id 降序取最新一条——历史版本的 savePdfInk 用 INSERT OR REPLACE 写库，
  /// 而 pdf_ink 表没有唯一约束，会产生同一页多条旧行，`rows.first` 会拿到
  /// **最旧**的一批笔迹，表现为「笔迹无法保存」。
  Future<List<InkStroke>> getPdfInk(String bookId, int pageIndex) async {
    return (await getPdfInkPage(bookId, pageIndex)).strokes;
  }

  /// v2 版：读一页的完整手写内容（笔迹 + 文本框），兼容 v1 旧格式。
  Future<PdfInkPage> getPdfInkPage(String bookId, int pageIndex) async {
    final db = await database;
    final rows = await db.query(
      'pdf_ink',
      where: 'book_id = ? AND page_index = ?',
      whereArgs: [bookId, pageIndex],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return const PdfInkPage();
    final raw = rows.first['strokes'] as String?;
    if (raw == null || raw.isEmpty) return const PdfInkPage();
    return PdfInkPage.decode(raw);
  }

  /// 覆盖保存某页的手写笔迹（纯 upsert：UPDATE 优先，0 行再 INSERT）。
  /// 不用 INSERT OR REPLACE——表没有唯一约束时 REPLACE 只会不断插新行。
  Future<void> savePdfInk(
      String bookId, int pageIndex, List<InkStroke> strokes) async {
    await savePdfInkPage(bookId, pageIndex, PdfInkPage(strokes: strokes));
  }

  /// v2 版：保存一页的完整手写内容（笔迹 + 文本框）。
  Future<void> savePdfInkPage(
      String bookId, int pageIndex, PdfInkPage page) async {
    final db = await database;
    final json = page.encode();
    final updated = await db.update(
      'pdf_ink',
      {
        'strokes': json,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'book_id = ? AND page_index = ?',
      whereArgs: [bookId, pageIndex],
    );
    if (updated == 0) {
      await db.insert('pdf_ink', {
        'book_id': bookId,
        'page_index': pageIndex,
        'strokes': json,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _notifyDataChanged();
  }

  /// 同步笔记中心的「手写批注」合成条目。
  ///
  /// PDF 某页有笔迹 → 在 annotations 里维护一条 source='ink' 的条目（点它可跳回
  /// 该页）；笔迹清空 → 删掉该条目。这样手写批注自然出现在笔记中心、可搜索、
  /// 可随导出走（quoted_text 为空、note 为摘要文本）。
  Future<void> syncPdfInkAnnotation(
      String bookId, int pageIndex, int strokeCount, String bookTitle) async {
    final db = await database;
    final rows = await db.query(
      'annotations',
      where: "book_id = ? AND page_index = ? AND anchor_kind = 'pdf' "
          "AND source = 'ink'",
      whereArgs: [bookId, pageIndex],
    );

    if (strokeCount <= 0) {
      if (rows.isNotEmpty) {
        await db.delete('annotations',
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
      return;
    }

    final note = '第 $pageIndex 页手写批注（$strokeCount 条笔迹）';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rows.isEmpty) {
      await db.insert('annotations', {
        'book_id': bookId,
        'book_title': bookTitle,
        'type': 'note',
        // Legacy NOT NULL 列照旧要写。
        'location': '第 $pageIndex 页',
        'text': '',
        'anchor_kind': 'pdf',
        'page_index': pageIndex,
        'quoted_text': '',
        'note': note,
        'created_at': now,
        'updated_at': now,
        'source': 'ink',
      });
    } else {
      await db.update(
        'annotations',
        {'note': note, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [rows.first['id']],
      );
    }
  }

  // ── 拍照翻译记录 ──────────────────────────────────────────────────

  /// 保存一条拍照翻译记录。
  Future<int> insertTranslateRecord(TranslateRecord r) async {
    final db = await database;
    final id = await db.insert('translate_records', r.toDbRow());
    _notifyDataChanged();
    return id;
  }

  /// 全部拍照翻译记录，新的在前。
  Future<List<TranslateRecord>> getTranslateRecords() async {
    final db = await database;
    final rows = await db.query('translate_records',
        orderBy: 'created_at DESC', limit: 500);
    return rows.map(TranslateRecord.fromDbRow).toList();
  }

  /// 删除一条记录（可选同时删除本地照片文件）。
  Future<void> deleteTranslateRecord(int id,
      {bool deleteImage = true}) async {
    final db = await database;
    final rows = await db.query('translate_records',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty && deleteImage) {
      final img = rows.first['image_path'] as String?;
      if (img != null && img.isNotEmpty) {
        try {
          final f = File(img);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await db.delete('translate_records', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  // ── Word card CRUD ──────────────────────────────────────────────────

  /// Save a generated word card and return its new id.
  Future<int> insertWordCard(WordCard c) async {
    final db = await database;
    return db.insert('word_cards', c.toDbRow());
  }

  /// All word cards, newest first.
  Future<List<WordCard>> getWordCards() async {
    final db = await database;
    final rows = await db.query('word_cards', orderBy: 'created_at DESC');
    return rows.map(WordCard.fromDbRow).toList();
  }

  /// Delete a word card by id (optionally also its local files).
  Future<void> deleteWordCard(int id, {bool deleteFiles = false}) async {
    final db = await database;
    if (deleteFiles) {
      final rows = await db
          .query('word_cards', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty) {
        final c = WordCard.fromDbRow(rows.first);
        for (final p in [
          c.cardImagePath,
          c.ukAudioPath,
          c.usAudioPath,
        ]) {
          if (p != null && p.isNotEmpty) {
            try {
              await File(p).delete();
            } catch (_) {}
          }
        }
      }
    }
    await db.delete('word_cards', where: 'id = ?', whereArgs: [id]);
  }

  // ── readest 引擎笔记 CRUD ──────────────────────────────────────────

  /// 保存一条 readest 笔记（同 CFI 已存在则更新，返回 id）。
  ///
  /// 更新时 image_path 只允许**非空覆盖**：新截图会替换旧截图，但没有新
  /// 截图（普通高亮/笔记）不冲掉已有截图（方案 §2.8 四要素捆绑）。
  Future<int> upsertReadestNote(ReadestNote n) async {
    final db = await database;
    final existing = await db.query(
      'readest_notes',
      where: 'book_id = ? AND cfi = ?',
      whereArgs: [n.bookId, n.cfi],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'readest_notes',
        {
          'text': n.text,
          'color': n.color,
          'style': n.style,
          'note': n.note,
          if (n.imagePath != null && n.imagePath!.isNotEmpty)
            'image_path': n.imagePath,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      _notifyDataChanged();
      return id;
    }
    final id = await db.insert('readest_notes', n.toDbRow());
    _notifyDataChanged();
    return id;
  }

  Future<List<ReadestNote>> getReadestNotes(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'readest_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at ASC',
    );
    return rows.map(ReadestNote.fromDbRow).toList();
  }

  /// 全部 readest 引擎笔记（笔记中心按书统计用）。
  Future<List<ReadestNote>> getAllReadestNotes() async {
    final db = await database;
    final rows = await db.query('readest_notes', orderBy: 'created_at ASC');
    return rows.map(ReadestNote.fromDbRow).toList();
  }

  /// 某本书全部页面的手写笔迹（pageNumber → strokes；v2 格式只取笔迹）。
  Future<Map<int, List<InkStroke>>> getAllPdfInk(String bookId) async {
    final all = await getAllPdfInkPages(bookId);
    return {
      for (final e in all.entries)
        if (e.value.strokes.isNotEmpty) e.key: e.value.strokes,
    };
  }

  /// 某本书全部页面的完整手写内容（pageNumber → PdfInkPage，笔迹+文本）。
  Future<Map<int, PdfInkPage>> getAllPdfInkPages(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'pdf_ink',
      columns: ['page_index', 'strokes'],
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'id DESC',
    );
    final result = <int, PdfInkPage>{};
    for (final row in rows) {
      final page = (row['page_index'] as num?)?.toInt() ?? 0;
      final raw = row['strokes'] as String?;
      if (page <= 0 || raw == null || raw.isEmpty) continue;
      final ink = PdfInkPage.decode(raw);
      if (!ink.isEmpty) result.putIfAbsent(page, () => ink);
    }
    return result;
  }

  Future<void> deleteReadestNote(int id) async {
    final db = await database;
    await db.delete('readest_notes', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  Future<void> deleteReadestNoteByCfi(String bookId, String cfi) async {
    final db = await database;
    await db.delete(
      'readest_notes',
      where: 'book_id = ? AND cfi = ?',
      whereArgs: [bookId, cfi],
    );
    _notifyDataChanged();
  }

  // ── Word（DOCX）批注 CRUD（Phase 4）────────────────────────────────

  /// 保存一条 DOCX 批注（高亮/下划线/波浪线/笔记/AI 标注/文本框的载体）。
  Future<int> insertDocxNote(DocxNote n) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('docx_notes', {
      'book_id': n.bookId,
      'para_index': n.paraIndex,
      'start_offset': n.startOffset,
      'end_offset': n.endOffset,
      'quoted_text': n.quotedText,
      'note': n.note,
      'color': n.color,
      'style': n.style,
      'source': n.source,
      'image_path': n.imagePath,
      'x': n.x,
      'y': n.y,
      'w': n.w,
      'font_size': n.fontSize,
      'rotation': n.rotation,
      'created_at': now,
      'updated_at': now,
    });
    _notifyDataChanged();
    return id;
  }

  /// 按选区（段落 + 偏移）upsert：同一段选中文字上的复制/截图/批注/AI
  /// 操作全部更新同一条记录，四要素（原文/截图/笔记/AI 内容）不丢
  /// （方案 §2.8）。返回记录 id。
  Future<int> upsertDocxNote(DocxNote n) async {
    final db = await database;
    final existing = await db.query(
      'docx_notes',
      where: 'book_id = ? AND para_index = ? AND start_offset = ? '
          'AND end_offset = ?',
      whereArgs: [n.bookId, n.paraIndex, n.startOffset, n.endOffset],
      limit: 1,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'docx_notes',
        {
          'quoted_text': n.quotedText,
          'note': n.note,
          'color': n.color,
          'style': n.style,
          'source': n.source,
          // 截图只允许非空覆盖：普通批注不冲掉已有截图。
          if (n.imagePath != null && n.imagePath!.isNotEmpty)
            'image_path': n.imagePath,
          if (n.style == 'textbox') ...{
            'x': n.x,
            'y': n.y,
            'w': n.w,
            'font_size': n.fontSize,
            'rotation': n.rotation,
          },
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      _notifyDataChanged();
      return id;
    }
    return insertDocxNote(n);
  }

  /// 更新浮动文本框（拖动/缩放后落盘：几何 + 内容）。
  Future<void> updateDocxTextBox(DocxNote n) async {
    final db = await database;
    await db.update(
      'docx_notes',
      {
        'note': n.note,
        'x': n.x,
        'y': n.y,
        'w': n.w,
        'font_size': n.fontSize,
        'rotation': n.rotation,
        'color': n.color,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [n.id],
    );
    _notifyDataChanged();
  }

  /// 某本书的全部 DOCX 批注（按段落顺序）。
  Future<List<DocxNote>> getDocxNotes(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'docx_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'para_index ASC, start_offset ASC, created_at ASC',
    );
    return rows.map(DocxNote.fromJson).toList();
  }

  /// 全部 DOCX 批注（笔记中心按书统计用）。
  Future<List<DocxNote>> getAllDocxNotes() async {
    final db = await database;
    final rows = await db.query('docx_notes', orderBy: 'created_at DESC');
    return rows.map(DocxNote.fromJson).toList();
  }

  Future<void> deleteDocxNote(int id) async {
    final db = await database;
    await db.delete('docx_notes', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  /// 段落编辑（插入/删除）后迁移批注锚点：para_index >= [from] 的全部
  /// 加上 [delta]（插入 +1 / 删除 -1）。
  Future<void> shiftDocxNoteIndices(String bookId, int from, int delta) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE docx_notes SET para_index = para_index + ? '
      'WHERE book_id = ? AND para_index >= ?',
      [delta, bookId, from],
    );
    _notifyDataChanged();
  }

  /// 删除段落时同步删除挂在该段上的批注（含图片批注的磁盘文件，
  /// best-effort）。
  Future<void> deleteDocxNotesAtPara(String bookId, int paraIndex) async {
    final db = await database;
    final rows = await db.query(
      'docx_notes',
      where: 'book_id = ? AND para_index = ?',
      whereArgs: [bookId, paraIndex],
    );
    for (final r in rows) {
      final img = r['image_path'] as String?;
      if (img != null && img.isNotEmpty) {
        try {
          final f = File(img);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await db.delete(
      'docx_notes',
      where: 'book_id = ? AND para_index = ?',
      whereArgs: [bookId, paraIndex],
    );
    _notifyDataChanged();
  }

  /// 编辑 DOCX 笔记正文。
  Future<void> updateDocxNote(int id, String newNote) async {
    final db = await database;
    await db.update(
      'docx_notes',
      {
        'note': newNote,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyDataChanged();
  }

  // ── AI 标注 CRUD（Phase 2：阅读器 AI 闭环） ─────────────────────────

  /// 保存一条 AI 标注（用户在对话框里确认过的生成内容）。
  Future<int> insertAiNote(AiNote n) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('ai_notes', {
      'book_id': n.bookId,
      'file_type': n.fileType,
      'anchor': n.anchor,
      'quoted_text': n.quotedText,
      'content': n.content,
      'image_path': n.imagePath,
      'conversation_id': n.conversationId,
      'created_at': n.createdAt > 0 ? n.createdAt : now,
      'updated_at': n.updatedAt > 0 ? n.updatedAt : now,
    });
    _notifyDataChanged();
    return id;
  }

  Future<List<AiNote>> getAiNotes(String bookId) async {
    final db = await database;
    final rows = await db.query(
      'ai_notes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return rows
        .map((r) => AiNote(
              id: r['id'] as int,
              bookId: r['book_id'] as String? ?? '',
              fileType: r['file_type'] as String? ?? 'epub',
              anchor: r['anchor'] as String? ?? '{}',
              quotedText: r['quoted_text'] as String? ?? '',
              content: r['content'] as String? ?? '',
              imagePath: r['image_path'] as String?,
              conversationId: r['conversation_id'] as int?,
              createdAt: r['created_at'] as int? ?? 0,
              updatedAt: r['updated_at'] as int? ?? 0,
            ))
        .toList();
  }

  /// 全部 AI 标注（笔记中心按书统计用）。
  Future<List<AiNote>> getAllAiNotes() async {
    final db = await database;
    final rows = await db.query('ai_notes', orderBy: 'created_at DESC');
    return rows
        .map((r) => AiNote(
              id: r['id'] as int,
              bookId: r['book_id'] as String? ?? '',
              fileType: r['file_type'] as String? ?? 'epub',
              anchor: r['anchor'] as String? ?? '{}',
              quotedText: r['quoted_text'] as String? ?? '',
              content: r['content'] as String? ?? '',
              imagePath: r['image_path'] as String?,
              conversationId: r['conversation_id'] as int?,
              createdAt: r['created_at'] as int? ?? 0,
              updatedAt: r['updated_at'] as int? ?? 0,
            ))
        .toList();
  }

  Future<void> deleteAiNote(int id) async {
    final db = await database;
    await db.delete('ai_notes', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  /// 更新一条 AI 笔记的正文内容（AI 工具 edit_note 用）。
  Future<void> updateAiNoteContent(int id, String content) async {
    final db = await database;
    await db.update(
      'ai_notes',
      {
        'content': content,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyDataChanged();
  }

  // ── 使用时长统计（主页 GitHub 热力格数据源） ─────────────────────

  /// 日期键：本地时区的 `yyyy-MM-dd`（热力格按自然日统计）。
  static String usageDateKey(DateTime day) {
    final d = day.toLocal();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// 累计某天的使用秒数（事务内 SELECT+UPDATE/INSERT）。
  ///
  /// 不能用 `ON CONFLICT DO UPDATE`（UPSERT 语法）：Android 系统 SQLite
  /// 到 API 28 还是 3.22，UPSERT 要 3.24+——旧设备上会直接抛
  /// SQLiteException，导致热力格永远不绿。
  Future<void> addUsageSeconds(DateTime day, int seconds) async {
    if (seconds <= 0) return;
    final db = await database;
    final key = usageDateKey(day);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'usage_days',
        columns: ['seconds'],
        where: 'date = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('usage_days', {
          'date': key,
          'seconds': seconds,
          'logins': 0,
          'updated_at': now,
        });
      } else {
        final cur = (rows.first['seconds'] as int?) ?? 0;
        await txn.update(
          'usage_days',
          {'seconds': cur + seconds, 'updated_at': now},
          where: 'date = ?',
          whereArgs: [key],
        );
      }
    });
  }

  /// 记录一次登录（登录当天热力格至少一档绿）。同 [addUsageSeconds] 的
  /// 兼容性约束，事务内 SELECT+UPDATE/INSERT，不用 UPSERT。
  Future<void> markLogin(DateTime day) async {
    final db = await database;
    final key = usageDateKey(day);
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'usage_days',
        columns: ['logins'],
        where: 'date = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('usage_days', {
          'date': key,
          'seconds': 0,
          'logins': 1,
          'updated_at': now,
        });
      } else {
        final cur = (rows.first['logins'] as int?) ?? 0;
        await txn.update(
          'usage_days',
          {'logins': cur + 1, 'updated_at': now},
          where: 'date = ?',
          whereArgs: [key],
        );
      }
    });
  }

  /// 读取一段日期范围内的使用统计（含 start/end 当天）。
  Future<List<UsageDay>> getUsageDays(DateTime start, DateTime end) async {
    final db = await database;
    final rows = await db.query(
      'usage_days',
      where: 'date >= ? AND date <= ?',
      whereArgs: [usageDateKey(start), usageDateKey(end)],
    );
    return rows
        .map((r) => UsageDay(
              date: r['date'] as String,
              seconds: (r['seconds'] as int?) ?? 0,
              logins: (r['logins'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 热力格起始日期 = 用户最早的一条活动记录（≈ 下载 App 开始使用的第一天）。
  /// 取 usage_days 最早日期与书架最早下载日期的较小者；完全没有记录返回 null。
  ///
  /// 用户反馈热力格「只显示今天之前的格子、不变绿」：旧实现固定画最近
  /// 70 天，窄卡片里横向滚动只能看到开头几周（全是无记录的老日子），
  /// 今天这一列在视野外。改为从第一条记录画到今天，今天永远可见。
  Future<DateTime?> getFirstActivityDate() async {
    final db = await database;
    DateTime? min;
    void consider(Object? v) {
      if (v is int && v > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(v);
        if (min == null || dt.isBefore(min!)) min = dt;
      }
    }
    try {
      final u = await db.rawQuery('SELECT MIN(date) AS d FROM usage_days');
      final ud = u.isNotEmpty ? u.first['d'] : null;
      if (ud is String && ud.isNotEmpty) {
        final parts = ud.split('-');
        if (parts.length == 3) {
          final dt = DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
          if (min == null || dt.isBefore(min!)) min = dt;
        }
      }
    } catch (e) {
      debugPrint('[Storage] MIN(usage_days) failed: $e');
    }
    try {
      final b = await db.rawQuery(
        'SELECT MIN(download_date) AS d FROM bookshelf '
        'WHERE download_date IS NOT NULL AND download_date > 0',
      );
      consider(b.isNotEmpty ? b.first['d'] : null);
    } catch (e) {
      debugPrint('[Storage] MIN(bookshelf.download_date) failed: $e');
    }
    return min;
  }

  /// 收养孤儿下载：`Documents/books` 里不在书架中的书文件自动入库。
  ///
  /// 场景：后台下载（flutter_downloader）把文件写进 books 目录，但如果
  /// App 在下载完成的瞬间已被系统杀掉，`DownloadService.download` 的
  /// 自动入库没机会执行——文件就成了孤儿。书架每次刷新都收养一次，
  /// 「下载后导入看不到文件」的问题就此闭环（书名取文件名，ID 稳定）。
  Future<void> adoptOrphanDownloads() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(dir.path, 'books'));
      if (!await booksDir.exists()) return;

      final shelf = await getBookshelf();
      final shelfPaths = <String>{
        for (final b in shelf)
          if (b.localPath != null && b.localPath!.isNotEmpty)
            File(b.localPath!).absolute.path,
      };
      const exts = {'epub', 'pdf', 'txt', 'md', 'docx'};
      var adopted = 0;
      for (final f in booksDir.listSync().whereType<File>()) {
        final ext = p.extension(f.path).replaceAll('.', '').toLowerCase();
        if (!exts.contains(ext)) continue;
        if (shelfPaths.contains(f.absolute.path)) continue;
        // 跳过 HTML 跳转页/坏文件：镜像把下载回成网页时落盘的文件不是书，
        // 收养进来就会变成「封面空白 + 书名 redirection」的坏书。
        // 头部魔数校验：epub 必须 PK、pdf 必须 %PDF，HTML 一律拦。
        try {
          final len = await f.length();
          if (len == 0) continue;
          final raf = await f.open();
          final head = await raf.read(len < 4096 ? len : 4096);
          await raf.close();
          final lower = String.fromCharCodes(head).toLowerCase();
          final isHtml = lower.contains('<html') ||
              lower.contains('<!doctype') ||
              lower.contains('<head') ||
              lower.contains('<body') ||
              lower.contains('<meta http-equiv') ||
              lower.contains('window.location') ||
              (lower.startsWith('redirection') ||
                  lower.contains('redirecting'));
          if (isHtml) {
            debugPrint('[Storage] skip orphan (HTML page): ${f.path}');
            continue;
          }
          if (ext == 'pdf' && !lower.contains('%pdf')) {
            debugPrint('[Storage] skip orphan (not a PDF): ${f.path}');
            continue;
          }
          if (ext == 'epub' &&
              !(head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B)) {
            debugPrint('[Storage] skip orphan (not a ZIP/EPUB): ${f.path}');
            continue;
          }
        } catch (_) {}
        final title = p.basenameWithoutExtension(f.path);
        if (title.isEmpty) continue;
        await upsertBook(Book(
          id: 'local-orphan-${title.hashCode.abs()}-$ext',
          hash: '',
          title: title,
          author: '',
          extension: ext,
          isLocal: true,
          localPath: f.path,
          downloadDate: f.statSync().modified,
        ));
        adopted++;
        debugPrint('[Storage] adopted orphan download: ${f.path}');
      }
      if (adopted > 0) debugPrint('[Storage] adopted $adopted orphan(s)');
    } catch (e) {
      debugPrint('[Storage] adopt orphan downloads failed: $e');
    }
  }

  // ── AI 对话 CRUD（Phase 1：AI 中心用） ────────────────────────────

  /// 新建一条 AI 对话，返回自增 id。
  Future<int> insertAiConversation(AiConversation c) async {
    final db = await database;
    final now = c.createdAt > 0 ? c.createdAt : DateTime.now().millisecondsSinceEpoch;
    return db.insert('ai_conversations', {
      'file_id': c.fileId,
      'file_type': c.fileType,
      'file_name': c.fileName,
      'title': c.title,
      'created_at': now,
      'updated_at': c.updatedAt > 0 ? c.updatedAt : now,
    });
  }

  /// 取某本书的 AI 对话，没有则创建（一本书一条会话，多轮对话都归进去）。
  ///
  /// 书内对话按 (file_id, file_type) 复用：同一次阅读里的多轮 AI 问答都进
  /// 同一条记录，AI 中心侧栏按文件分组时天然成组。
  Future<AiConversation> getOrCreateAiConversation({
    required String fileId,
    required String fileType,
    required String fileName,
  }) async {
    final db = await database;
    final rows = await db.query(
      'ai_conversations',
      where: 'file_id = ? AND file_type = ?',
      whereArgs: [fileId, fileType],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return AiConversation(
        id: rows.first['id'] as int,
        fileId: rows.first['file_id'] as String?,
        fileType: rows.first['file_type'] as String?,
        fileName: rows.first['file_name'] as String? ?? '',
        title: rows.first['title'] as String? ?? '',
        createdAt: rows.first['created_at'] as int,
        updatedAt: rows.first['updated_at'] as int,
      );
    }
    final id = await insertAiConversation(AiConversation(
      fileId: fileId,
      fileType: fileType,
      fileName: fileName,
      title: fileName,
    ));
    return AiConversation(
      id: id,
      fileId: fileId,
      fileType: fileType,
      fileName: fileName,
      title: fileName,
    );
  }

  /// 全部 AI 对话（按更新时间倒序，附消息条数）。
  Future<List<AiConversation>> listAiConversations() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT c.*, (SELECT COUNT(*) FROM ai_messages m
                   WHERE m.conversation_id = c.id) AS msg_count
      FROM ai_conversations c
      ORDER BY c.updated_at DESC
    ''');
    return rows
        .map((r) => AiConversation(
              id: r['id'] as int,
              fileId: r['file_id'] as String?,
              fileType: r['file_type'] as String?,
              fileName: r['file_name'] as String? ?? '',
              title: r['title'] as String? ?? '',
              createdAt: r['created_at'] as int,
              updatedAt: r['updated_at'] as int,
              messageCount: (r['msg_count'] as int?) ?? 0,
            ))
        .toList();
  }

  /// 删除对话（FK CASCADE 会连消息一起删；删除前调用方负责让用户确认）。
  Future<void> deleteAiConversation(int id) async {
    final db = await database;
    await db.delete('ai_conversations', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  // ── Agent 任务（ai_tasks，Phase 1 任务式 Agent）────────────────────

  /// 新建任务行（planning 状态），返回自增 id。
  Future<int> insertAiTask(AiTask task) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('ai_tasks', {
      'goal': task.goal,
      'status': task.status,
      'steps': task.encodeSteps(),
      'result': task.result,
      'created_at': task.createdAt > 0 ? task.createdAt : now,
      'updated_at': now,
    });
    _notifyDataChanged();
    return id;
  }

  /// 更新任务状态/步骤/结果（引擎每步都会调用）。
  Future<void> updateAiTask(AiTask task) async {
    final db = await database;
    await db.update(
      'ai_tasks',
      {
        'goal': task.goal,
        'status': task.status,
        'steps': task.encodeSteps(),
        'result': task.result,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [task.id],
    );
    _notifyDataChanged();
  }

  /// 按 id 读单个任务（不存在返回 null）。
  Future<AiTask?> getAiTask(int id) async {
    final db = await database;
    final rows =
        await db.query('ai_tasks', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return AiTask.fromJson(rows.first);
  }

  /// 全部任务（新的在前），可选过滤未完成。
  Future<List<AiTask>> listAiTasks({bool onlyActive = false}) async {
    final db = await database;
    final rows = await db.query(
      'ai_tasks',
      where: onlyActive
          ? "status NOT IN ('done','failed','cancelled')"
          : null,
      orderBy: 'created_at DESC',
      limit: onlyActive ? null : 200,
    );
    return rows.map(AiTask.fromJson).toList();
  }

  /// 删除任务（含历史清理）。
  Future<void> deleteAiTask(int id) async {
    final db = await database;
    await db.delete('ai_tasks', where: 'id = ?', whereArgs: [id]);
    _notifyDataChanged();
  }

  /// 清理已完成任务的旧历史（保留最近 [keep] 条）。
  Future<void> pruneAiTasks({int keep = 100}) async {
    final db = await database;
    await db.rawDelete('''
      DELETE FROM ai_tasks WHERE id NOT IN (
        SELECT id FROM ai_tasks ORDER BY created_at DESC LIMIT ?
      )
    ''', [keep]);
  }

  /// 刷新对话的 updated_at（排序依据）并可选更新标题。
  Future<void> touchAiConversation(int id, {String? title}) async {
    final db = await database;
    final values = <String, Object?>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (title != null) values['title'] = title;
    await db.update('ai_conversations', values,
        where: 'id = ?', whereArgs: [id]);
  }

  /// 存一条消息，返回自增 id。
  Future<int> insertAiMessage(AiMessage m) async {
    final db = await database;
    final id = await db.insert('ai_messages', {
      'conversation_id': m.conversationId,
      'role': m.role,
      'content': m.content,
      'token_usage': m.tokenUsage,
      'created_at': m.createdAt > 0
          ? m.createdAt
          : DateTime.now().millisecondsSinceEpoch,
    });
    _notifyDataChanged();
    return id;
  }

  /// 某条对话的消息（按时间正序）。[limit] 非空时取最近的 N 条。
  Future<List<AiMessage>> getAiMessages(int conversationId,
      {int? limit}) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT * FROM ai_messages
      WHERE conversation_id = ?
      ORDER BY created_at DESC
      ${limit != null ? 'LIMIT $limit' : ''}
    ''', [conversationId]);
    return rows.reversed
        .map((r) => AiMessage(
              id: r['id'] as int,
              conversationId: r['conversation_id'] as int,
              role: r['role'] as String,
              content: r['content'] as String? ?? '',
              tokenUsage: (r['token_usage'] as int?) ?? 0,
              createdAt: r['created_at'] as int,
            ))
        .toList();
  }

  // ── AI 提示词 CRUD（Phase 6） ─────────────────────────────────────

  Future<int> insertAiPrompt(AiPrompt p) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert('ai_prompts', {
      'title': p.title,
      'content': p.content,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> updateAiPrompt(AiPrompt p) async {
    final db = await database;
    await db.update(
      'ai_prompts',
      {
        'title': p.title,
        'content': p.content,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [p.id],
    );
  }

  Future<void> deleteAiPrompt(int id) async {
    final db = await database;
    await db.delete('ai_prompts', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<AiPrompt>> getAiPrompts() async {
    final db = await database;
    final rows = await db.query('ai_prompts', orderBy: 'updated_at DESC');
    return rows
        .map((r) => AiPrompt(
              id: r['id'] as int,
              title: r['title'] as String? ?? '',
              content: r['content'] as String? ?? '',
              createdAt: r['created_at'] as int? ?? 0,
              updatedAt: r['updated_at'] as int? ?? 0,
            ))
        .toList();
  }

  // ── 书架标签 CRUD（Phase 6：tags/book_tags 表 v11 已建，这里补方法） ──

  /// 全部标签（按名称排序）。
  Future<List<BookTag>> listTags() async {
    final db = await database;
    final rows = await db.query('tags', orderBy: 'name ASC');
    return rows
        .map((r) => BookTag(
              id: r['id'] as int,
              name: r['name'] as String? ?? '',
              color: r['color'] as String? ?? '#4ade80',
            ))
        .toList();
  }

  /// 新建标签，返回 id。重名时返回已有标签的 id（name 有 UNIQUE 约束）。
  Future<int> insertTag(String name, {String color = '#4ade80'}) async {
    final db = await database;
    final existing = await db.query(
      'tags',
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return db.insert('tags', {'name': name, 'color': color});
  }

  Future<void> deleteTag(int id) async {
    final db = await database;
    await db.delete('tags', where: 'id = ?', whereArgs: [id]);
  }

  /// 某本书的标签列表（按名称排序）。
  Future<List<BookTag>> getBookTags(String bookId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.id, t.name, t.color
      FROM tags t
      INNER JOIN book_tags bt ON bt.tag_id = t.id
      WHERE bt.book_id = ?
      ORDER BY t.name ASC
    ''', [bookId]);
    return rows
        .map((r) => BookTag(
              id: r['id'] as int,
              name: r['name'] as String? ?? '',
              color: r['color'] as String? ?? '#4ade80',
            ))
        .toList();
  }

  /// 覆盖设置某本书的标签（事务内先删后插，避免旧标签残留）。
  Future<void> setBookTags(String bookId, List<int> tagIds) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('book_tags', where: 'book_id = ?', whereArgs: [bookId]);
      for (final id in tagIds.toSet()) {
        await txn.insert('book_tags', {'book_id': bookId, 'tag_id': id});
      }
    });
  }

  /// 每本书的标签（AI 工具「查看书架」附带标签信息用）。
  Future<Map<String, List<BookTag>>> getTagsByBook() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT bt.book_id, t.id, t.name, t.color
      FROM tags t
      INNER JOIN book_tags bt ON bt.tag_id = t.id
      ORDER BY t.name ASC
    ''');
    final result = <String, List<BookTag>>{};
    for (final r in rows) {
      final bookId = r['book_id'] as String? ?? '';
      result.putIfAbsent(bookId, () => []).add(BookTag(
            id: r['id'] as int,
            name: r['name'] as String? ?? '',
            color: r['color'] as String? ?? '#4ade80',
          ));
    }
    return result;
  }

  // ── AI 统计（Phase 6：AI 中心侧栏统计卡） ─────────────────────────

  Future<AiStats> getAiStats() async {
    final db = await database;
    try {
      final rows = await db.rawQuery('''
        SELECT
          (SELECT COUNT(*) FROM ai_conversations) AS convs,
          (SELECT COUNT(*) FROM ai_messages) AS msgs,
          (SELECT COALESCE(SUM(token_usage), 0) FROM ai_messages) AS tokens
      ''');
      if (rows.isEmpty) return const AiStats();
      final r = rows.first;
      return AiStats(
        conversations: (r['convs'] as num?)?.toInt() ?? 0,
        messages: (r['msgs'] as num?)?.toInt() ?? 0,
        tokens: (r['tokens'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('[Storage] getAiStats failed: $e');
      return const AiStats();
    }
  }

  // ── Cleanup ────────────────────────────────────────────────────────

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }
}
