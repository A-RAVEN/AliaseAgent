import 'dart:io';

// 用 sqflite_common（纯 Dart）而不是 sqflite Flutter 插件：无头核心在纯 Dart VM
// 下也要能打开同一个数据库。`databaseFactory` 由组合根/测试在启动时用
// `sqfliteFfiInit()` + `databaseFactoryFfi` 注入（change `web-ui-core-shim`）。
import 'package:sqflite_common/sqflite.dart';
import 'package:path/path.dart' as p;

import 'config_service.dart';

class DatabaseService {
  static const _schemaVersion = 9;
  static Database? _db;

  /// Whether a database is currently open. Compaction-tree persistence
  /// (summary_nodes) is gated on this: hermetic widget tests inject fake
  /// repositories and never open a DB, so those paths must NOT lazily open the
  /// real user database as a side effect.
  static bool get isOpen => _db != null;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  static Future<Database> _init() async {
    final dir = ConfigService.configDir;
    await Directory(dir).create(recursive: true);
    return openDatabase(
      p.join(dir, 'aliasagent.db'),
      version: _schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Only for testing — inject a database opened at a custom path.
  static Future<void> openAt(String dirPath) async {
    _db = await openDatabase(
      p.join(dirPath, 'aliasagent.db'),
      version: _schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 每条连接都要显式打开外键：SQLite 默认关闭，关闭时删除父会话不会级联删除
  /// 子运行记录、消息与摘要（`REFERENCES … ON DELETE CASCADE` 形同虚设）。
  /// onConfigure 在 onCreate / onUpgrade 之前执行，生产与测试走同一条路径。
  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Create the current schema. Used by both _init and openAt so the test path
  /// mirrors the production path exactly (spec: openAt mirrors schema).
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT 'New Chat',
        agent_type TEXT NOT NULL DEFAULT 'general',
        parent_session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        tree_version INTEGER NOT NULL DEFAULT 0,
        dirty_since_seq INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'single',
        overrides_json TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        seq INTEGER,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
        content TEXT NOT NULL,
        tool_calls TEXT,
        thinking_json TEXT,
        token_count INTEGER,
        output_token_count INTEGER,
        attachments TEXT,
        created_at INTEGER NOT NULL,
        author TEXT,
        visibility TEXT NOT NULL DEFAULT 'public'
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_messages_session ON messages(session_id)');
    // Stable ordering key for compaction tree spans (per-session, monotonic).
    await db.execute(
        'CREATE INDEX idx_messages_seq ON messages(session_id, seq)');
    await db.execute(
        'CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC)');
    await _createSummaryNodes(db);
    await _createGroupMembers(db);
  }

  /// 组成员表（change `agent-group-chat` D14 / D17）。
  ///
  /// 成员 id 是**稳定身份**（`messages.author` 存它，改名不改归属）。移除是软删
  /// （写 `removed_at`、行保留）：唯一性只在**未移除**成员之间成立，靠部分唯一索引
  /// `WHERE removed_at IS NULL`，删掉之后同名重建是新 id、不撞旧行。
  static Future<void> _createGroupMembers(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_members (
        id TEXT PRIMARY KEY,
        group_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        template_name TEXT NOT NULL,
        overrides_json TEXT,
        removed_at INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_group_members_group ON group_members(group_session_id)');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_group_members_active_name '
        'ON group_members(group_session_id, name) WHERE removed_at IS NULL');
  }

  /// Compaction tree table. Derived index over messages — originals are never
  /// deleted/overwritten by compaction. Keyed by (session_id, member_id, level,
  /// start_seq, end_seq) with a leaf-owner index and dense non-overlap constraint
  /// via covered_min/covered_max_seq.
  ///
  /// `member_id` 是**成员作用域**（change `agent-group-chat`）：单 Agent 会话为空
  /// （NULL），组会话按成员的投影视图各存一条；同一 span 两个成员各一行、互不覆盖。
  static Future<void> _createSummaryNodes(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS summary_nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        member_id TEXT,
        level INTEGER NOT NULL,
        start_seq INTEGER NOT NULL,
        end_seq INTEGER NOT NULL,
        node_type TEXT NOT NULL,
        parent_id INTEGER,
        summary_json TEXT,
        token_cost INTEGER,
        summary_prompt_version INTEGER,
        model TEXT,
        covered_min_seq INTEGER NOT NULL,
        covered_max_seq INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_summary_nodes_session ON summary_nodes(session_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_summary_nodes_span ON summary_nodes(session_id, member_id, level, start_seq, end_seq)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_summary_nodes_leaf_owner ON summary_nodes(session_id, member_id, covered_min_seq, covered_max_seq)');
  }

  /// Migrate schema versions 1→current sequentially.
  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV <= 1) {
      await db.execute(
          'ALTER TABLE messages ADD COLUMN tool_calls TEXT');
    }
    if (oldV <= 2) {
      await db.execute(
          'ALTER TABLE messages ADD COLUMN thinking_json TEXT');
    }
    if (oldV <= 3) {
      // v3 → v4: stable seq ordering key + compaction tree table + per-session
      // tree_version. Legacy messages are NOT pre-built into rollups — they
      // remain uncompressed leaves, built lazily forward (design: no legacy
      // rollup). seq is backfilled best-effort by rowid (monotonic per insert).
      await db.execute('ALTER TABLE messages ADD COLUMN seq INTEGER');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_seq ON messages(session_id, seq)');
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN tree_version INTEGER NOT NULL DEFAULT 0');
      await _createSummaryNodes(db);
      // Backfill seq for existing rows: rowid is unique + monotonic, giving a
      // stable total order even for same-millisecond inserts. Best-effort.
      await db.execute('UPDATE messages SET seq = rowid WHERE seq IS NULL');
    }
    if (oldV <= 4) {
      // v4 → v5: dirty-since-seq watermark for lazy compaction recompute. The
      // low watermark (min changed seq) lets _resolveSummaries reuse cached
      // summaries for spans strictly below it (clean) and regenerate stale ones.
      await db.execute('ALTER TABLE sessions ADD COLUMN dirty_since_seq INTEGER NOT NULL DEFAULT 0');
    }
    if (oldV <= 5) {
      // v5 → v6: persist measured output tokens alongside input (task 7.3) so the
      // usage telemetry is complete, not just input-only.
      await db.execute('ALTER TABLE messages ADD COLUMN output_token_count INTEGER');
    }
    if (oldV <= 6) {
      // v6 → v7: 图片附件只记路径（add-image-input，用户要求"历史先只存路径"）。
      // 存的是 `[{"path":"…"}]`；旧行保持 NULL，等价于"没有附件"。
      await db.execute('ALTER TABLE messages ADD COLUMN attachments TEXT');
    }
    if (oldV <= 7) {
      // v7 → v8：一次性子 Agent 的运行记录指向父会话（add-spawn-subagent-tool）。
      // 既有顶层会话保持 NULL；列上的外键让删除父会话时子记录随父删除。
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN parent_session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE');
    }
    if (oldV <= 8) {
      // v8 → v9：群聊（change `agent-group-chat` D14）。只加列 / 加表 / 加索引，
      // 不删任何行；旧行语义：visibility='public'、author=NULL、kind='single'、
      // overrides_json=NULL、member_id=NULL（= 单会话路径）。
      await db.execute('ALTER TABLE messages ADD COLUMN author TEXT');
      await db.execute(
          "ALTER TABLE messages ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'");
      await db.execute(
          "ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'single'");
      await db.execute('ALTER TABLE sessions ADD COLUMN overrides_json TEXT');
      // 从更老的版本（≤3）升上来时 `_createSummaryNodes` 已经带 member_id，这里不能
      // 再 ADD 一次（SQLite 会报 duplicate column）；按真实列名判断。手工造的残缺
      // 旧库可能根本没有这张表（真实 v4 起一定有），那就不动它。
      final summaryTables = (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'summary_nodes'"))
          .isNotEmpty;
      final summaryColumns = summaryTables
          ? (await db.rawQuery('PRAGMA table_info(summary_nodes)'))
              .map((row) => row['name'])
              .toSet()
          : const <String>{};
      if (summaryTables && !summaryColumns.contains('member_id')) {
        await db.execute('ALTER TABLE summary_nodes ADD COLUMN member_id TEXT');
      }
      await _createGroupMembers(db);
      // 含成员作用域的索引：span 查询与 leaf_owner 查询都按 (session, member) 先过滤。
      // 旧索引（不含 member）在纯新增的升级里可以直接重建：它们只是索引，不承载数据。
      if (summaryTables) {
        await db.execute('DROP INDEX IF EXISTS idx_summary_nodes_span');
        await db.execute('DROP INDEX IF EXISTS idx_summary_nodes_leaf_owner');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_summary_nodes_span ON summary_nodes(session_id, member_id, level, start_seq, end_seq)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_summary_nodes_leaf_owner ON summary_nodes(session_id, member_id, covered_min_seq, covered_max_seq)');
      }
    }
    if (oldV < 1 || oldV > _schemaVersion) {
      await db.execute('DROP TABLE IF EXISTS messages');
      await db.execute('DROP TABLE IF EXISTS sessions');
    }
  }

  /// Only for testing — reset singleton.
  static void reset() {
    _db = null;
  }

  /// Close the database connection. Must be called before deleting temp DB files.
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
