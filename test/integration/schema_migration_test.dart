import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/database_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Database schema migration v3 -> v4', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mig_test_');
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('v3->v4 adds seq + summary_nodes + tree_version, preserves data, no legacy rollups',
        () async {
      // Build a v3 (old-schema) database with one session + one message.
      final dbPath = p.join(tempDir.path, 'aliasagent.db');
      final db3 = await openDatabase(dbPath, version: 3, onCreate: (db, v) async {
        await db.execute('''CREATE TABLE sessions (
          id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
          agent_type TEXT NOT NULL DEFAULT 'general',
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE messages (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          role TEXT NOT NULL CHECK(role IN ('user','assistant')),
          content TEXT NOT NULL, tool_calls TEXT, thinking_json TEXT,
          token_count INTEGER, created_at INTEGER NOT NULL)''');
      });
      await db3.insert('sessions', {'id': 's1', 'title': 'Old', 'created_at': 1, 'updated_at': 1});
      await db3.insert('messages', {
        'id': 'm1', 'session_id': 's1', 'role': 'user', 'content': 'legacy', 'created_at': 1,
      });
      await db3.close();

      // Reopen under the app's current (v4) schema -> onUpgrade(3, 4).
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;

      // [OBS] dump the actual migrated schema/data before asserting, so a
      // failure is attributable (test observability).
      // ignore: avoid_print
      print('  [OBS] migrated messages => '
          '${(await db.query('messages')).map((r) => '${r['role']}:${r['content']} seq=${r['seq']}').join(' | ')}');
      // ignore: avoid_print
      print('  [OBS] sessions cols => ${(await db.rawQuery('PRAGMA table_info(sessions)')).map((c) => c['name']).join(',')}');
      // ignore: avoid_print
      print('  [OBS] summary_nodes cols => ${(await db.rawQuery('PRAGMA table_info(summary_nodes)')).map((c) => c['name']).join(',')}');

      // seq column added + backfilled (rowid), data preserved.
      final msgs = await db.query('messages', where: 'id = ?', whereArgs: ['m1']);
      expect(msgs, isNotEmpty, reason: 'existing data must be preserved');
      expect(msgs.first['seq'], isNotNull, reason: 'legacy rows must be backfilled seq = rowid');
      expect(msgs.first['seq'], greaterThan(0));

      // v6 adds output_token_count to messages (persist measured output usage).
      expect(msgs.first.containsKey('output_token_count'), isTrue,
          reason: 'v5→v6 must add output_token_count to messages');

      // summary_nodes table created.
      final cols = await db.rawQuery("PRAGMA table_info(summary_nodes)");
      expect(cols, isNotEmpty, reason: 'summary_nodes table must be created on v3->v4');
      final hasCoveredMax = cols.any((c) => c['name'] == 'covered_max_seq');
      expect(hasCoveredMax, isTrue);

      // Per-session tree_version column added.
      final sessCols = await db.rawQuery("PRAGMA table_info(sessions)");
      expect(sessCols.any((c) => c['name'] == 'tree_version'), isTrue,
          reason: 'sessions.tree_version must be added on v3->v4');

      // No legacy rollup rows are pre-built for old data.
      final rollups = await db.query('summary_nodes');
      expect(rollups, isEmpty, reason: 'legacy messages must NOT be pre-built into rollups');
    });
  });

  group('Database schema migration v6 -> v7 (attachments)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mig_v7_test_');
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('v6 库升级到 v7：旧消息仍在、attachments 为空', () async {
      final dbPath = p.join(tempDir.path, 'aliasagent.db');
      // 按 v6 的建表语句造一个旧库（含 v6 的全部列，不含 attachments）
      final db6 = await openDatabase(dbPath, version: 6, onCreate: (db, v) async {
        await db.execute('''CREATE TABLE sessions (
          id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
          agent_type TEXT NOT NULL DEFAULT 'general',
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          tree_version INTEGER NOT NULL DEFAULT 0,
          dirty_since_seq INTEGER NOT NULL DEFAULT 0)''');
        await db.execute('''CREATE TABLE messages (
          id TEXT PRIMARY KEY, seq INTEGER,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          role TEXT NOT NULL CHECK(role IN ('user','assistant')),
          content TEXT NOT NULL, tool_calls TEXT, thinking_json TEXT,
          token_count INTEGER, output_token_count INTEGER,
          created_at INTEGER NOT NULL)''');
      });
      await db6.insert('sessions', {'id': 's1', 'title': 'Old', 'created_at': 1, 'updated_at': 1});
      await db6.insert('messages', {
        'id': 'm1', 'seq': 1, 'session_id': 's1', 'role': 'user',
        'content': '升级前的老消息', 'created_at': 1,
      });
      await db6.close();

      // 用当前（v7）打开 → onUpgrade(6, 7)
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;

      final msgCols = await db.rawQuery('PRAGMA table_info(messages)');
      // ignore: avoid_print
      print('  [OBS] messages cols => ${msgCols.map((c) => c['name']).join(',')}');
      expect(msgCols.any((c) => c['name'] == 'attachments'), isTrue,
          reason: 'v6→v7 必须给 messages 加上 attachments 列');

      final rows = await db.query('messages');
      // ignore: avoid_print
      print('  [OBS] migrated rows => '
          '${rows.map((r) => '${r['id']}:${r['content']} attachments=${r['attachments']}').join(' | ')}');
      expect(rows.length, 1, reason: '旧数据必须原样保留');
      expect(rows.first['content'], '升级前的老消息');
      expect(rows.first['attachments'], isNull,
          reason: '旧行没有附件，升级后也必须是 NULL（不是空串、不是 []）');

      // 从行读出来是空附件列表，不抛
      final message = Message.fromRow(rows.first);
      expect(message.attachments, isEmpty);

      // 新库（from scratch）同样带这一列
      await DatabaseService.close();
      final freshDir = Directory.systemTemp.createTempSync('mig_v7_fresh_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final freshDb = await DatabaseService.database;
        final freshCols = await freshDb.rawQuery('PRAGMA table_info(messages)');
        expect(freshCols.any((c) => c['name'] == 'attachments'), isTrue,
            reason: 'CREATE TABLE 里也要带 attachments（v7 全新建库）');
        expect(await freshDb.getVersion(), 7);
      } finally {
        await DatabaseService.close();
        if (freshDir.existsSync()) {
          try {
            freshDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    });
  });
}
