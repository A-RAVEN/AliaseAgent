import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'config_service.dart';

class DatabaseService {
  static const _schemaVersion = 1;
  static Database? _db;

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
      onUpgrade: (db, oldV, newV) => _onUpgrade(db),
    );
  }

  static Future<void> _onCreate(Database db) async {
    await db.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT 'New Chat',
        agent_type TEXT NOT NULL DEFAULT 'general',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
        content TEXT NOT NULL,
        token_count INTEGER,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute(
        'CREATE INDEX idx_messages_session ON messages(session_id)');
    await db.execute(
        'CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC)');
  }

  static Future<void> _onUpgrade(Database db) async {
    await db.execute('DROP TABLE IF EXISTS messages');
    await db.execute('DROP TABLE IF EXISTS sessions');
    await _onCreate(db);
  }

  /// Only for testing — inject a database opened at a custom path.
  static Future<void> openAt(String dirPath) async {
    _db = await openDatabase(
      p.join(dirPath, 'aliasagent.db'),
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: (db, oldV, newV) => _onUpgrade(db),
    );
  }

  /// Only for testing — reset singleton.
  static void reset() {
    _db = null;
  }
}