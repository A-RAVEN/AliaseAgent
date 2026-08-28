import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'config_service.dart';

class DatabaseService {
  static const _schemaVersion = 6;
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
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Only for testing — inject a database opened at a custom path.
  static Future<void> openAt(String dirPath) async {
    _db = await openDatabase(
      p.join(dirPath, 'aliasagent.db'),
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Create the current schema. Used by both _init and openAt so the test path
  /// mirrors the production path exactly (spec: openAt mirrors schema).
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT 'New Chat',
        agent_type TEXT NOT NULL DEFAULT 'general',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        tree_version INTEGER NOT NULL DEFAULT 0,
        dirty_since_seq INTEGER NOT NULL DEFAULT 0
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
        created_at INTEGER NOT NULL
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
  }

  /// Compaction tree table. Derived index over messages — originals are never
  /// deleted/overwritten by compaction. Keyed by (session_id, level, start_seq,
  /// end_seq) with a leaf-owner index and dense non-overlap constraint via
  /// covered_min/covered_max_seq.
  static Future<void> _createSummaryNodes(Database db) async {
    await db.execute('''
      CREATE TABLE summary_nodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
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
        'CREATE INDEX idx_summary_nodes_session ON summary_nodes(session_id)');
    await db.execute(
        'CREATE INDEX idx_summary_nodes_span ON summary_nodes(session_id, level, start_seq, end_seq)');
    await db.execute(
        'CREATE INDEX idx_summary_nodes_leaf_owner ON summary_nodes(session_id, covered_min_seq, covered_max_seq)');
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
