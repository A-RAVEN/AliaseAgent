import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
}
