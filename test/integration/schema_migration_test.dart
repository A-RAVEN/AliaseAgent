import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/session_repository.dart';

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
        // 当前建库版本已随 add-spawn-subagent-tool 升到 8；这里验的是「全新建库
        // 也带 attachments」，版本号取当前 schema 版本。
        expect(await freshDb.getVersion(), 8);
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

  group('Database schema migration v7 -> v8 (parent_session_id)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('mig_v8_test_');
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// 按 v7 的建表语句造一个旧库：会话、消息（带附件）、摘要各一条。
    Future<void> createV7Database(Directory dir) async {
      final dbPath = p.join(dir.path, 'aliasagent.db');
      final db7 = await openDatabase(dbPath, version: 7, onCreate: (db, v) async {
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
          attachments TEXT, created_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE summary_nodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          level INTEGER NOT NULL, start_seq INTEGER NOT NULL, end_seq INTEGER NOT NULL,
          node_type TEXT NOT NULL, parent_id INTEGER, summary_json TEXT,
          token_cost INTEGER, summary_prompt_version INTEGER, model TEXT,
          covered_min_seq INTEGER NOT NULL, covered_max_seq INTEGER NOT NULL)''');
      });
      await db7.insert('sessions', {
        'id': 'old-parent',
        'title': '升级前会话',
        'agent_type': 'reviewer',
        'created_at': 11,
        'updated_at': 22,
        'tree_version': 3,
        'dirty_since_seq': 5,
      });
      await db7.insert('messages', {
        'id': 'old-msg',
        'seq': 1,
        'session_id': 'old-parent',
        'role': 'user',
        'content': '升级前的消息',
        'attachments': '[{"path":"old.png"}]',
        'token_count': 7,
        'output_token_count': 3,
        'created_at': 11,
      });
      await db7.insert('summary_nodes', {
        'session_id': 'old-parent',
        'level': 1,
        'start_seq': 1,
        'end_seq': 1,
        'node_type': 'leaf',
        'summary_json': '{"summary":"旧的摘要"}',
        'token_cost': 9,
        'covered_min_seq': 1,
        'covered_max_seq': 1,
      });
      await db7.close();
    }

    test('v7 库升级到 v8：旧会话/消息/摘要原样保留，旧行父 id 为 NULL', () async {
      await createV7Database(tempDir);
      // 用当前版本打开 → onUpgrade(7, 8)
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;

      final sessionCols = await db.rawQuery('PRAGMA table_info(sessions)');
      // ignore: avoid_print
      print('  [OBS] v8 sessions cols => '
          '${sessionCols.map((c) => c['name']).join(',')}');
      expect(sessionCols.any((c) => c['name'] == 'parent_session_id'), isTrue,
          reason: 'v7→v8 必须给 sessions 加上 parent_session_id');
      expect(await db.getVersion(), 8);

      final sessions = await db.query('sessions');
      // ignore: avoid_print
      print('  [OBS] v8 migrated sessions => '
          '${sessions.map((r) => '${r['id']}: ${r['title']} '
              'agent_type=${r['agent_type']} parent=${r['parent_session_id']} '
              'tree=${r['tree_version']} dirty=${r['dirty_since_seq']}').join(' | ')}');
      expect(sessions.length, 1, reason: '旧会话数量必须不变');
      expect(sessions.first['title'], '升级前会话');
      expect(sessions.first['agent_type'], 'reviewer');
      expect(sessions.first['parent_session_id'], isNull,
          reason: '既有顶层会话升级后父 id 必须是 NULL');
      expect(sessions.first['tree_version'], 3);
      expect(sessions.first['dirty_since_seq'], 5);

      final messages = await db.query('messages');
      // ignore: avoid_print
      print('  [OBS] v8 migrated messages => '
          '${messages.map((r) => '${r['id']}:${r['content']} '
              'attachments=${r['attachments']}').join(' | ')}');
      expect(messages.length, 1, reason: '旧消息数量必须不变');
      expect(messages.first['content'], '升级前的消息');
      expect(messages.first['attachments'], '[{"path":"old.png"}]');
      expect(messages.first['seq'], 1);
      expect(messages.first['token_count'], 7);
      expect(messages.first['output_token_count'], 3);

      final summaries = await db.query('summary_nodes');
      // ignore: avoid_print
      print('  [OBS] v8 migrated summaries => '
          '${summaries.map((r) => '${r['id']}:${r['summary_json']}').join(' | ')}');
      expect(summaries.length, 1, reason: '旧摘要数量必须不变');
      expect(summaries.first['summary_json'], '{"summary":"旧的摘要"}');

      // 从行读出的 Session 也带父字段（NULL → null，不是空串）。
      final session = Session.fromRow(sessions.first);
      expect(session.parentSessionId, isNull);
    });

    test('新建 v8 库直接带父子字段：普通会话 NULL，子记录保存父 id', () async {
      final freshDir = Directory.systemTemp.createTempSync('mig_v8_fresh_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final db = await DatabaseService.database;
        final cols = await db.rawQuery('PRAGMA table_info(sessions)');
        expect(cols.any((c) => c['name'] == 'parent_session_id'), isTrue,
            reason: 'CREATE TABLE 里也要带 parent_session_id（v8 全新建库）');
        expect(await db.getVersion(), 8);

        final repo = SessionRepository();
        final parent = await repo.create(title: '父会话');
        final child = await repo.create(
            title: '子运行', agentType: 'general', parentSessionId: parent.id);
        final olderChild = await repo.create(
            title: '更早的子运行', parentSessionId: parent.id);
        final otherTop = await repo.create(title: '另一个顶层会话');

        // 用受控的 updated_at 核对排序，避免同一毫秒建行导致顺序不确定。
        await db.update('sessions', {'updated_at': 100},
            where: 'id = ?', whereArgs: [parent.id]);
        await db.update('sessions', {'updated_at': 300},
            where: 'id = ?', whereArgs: [otherTop.id]);
        await db.update('sessions', {'updated_at': 200},
            where: 'id = ?', whereArgs: [child.id]);
        await db.update('sessions', {'updated_at': 150},
            where: 'id = ?', whereArgs: [olderChild.id]);

        final rows = await db.query('sessions');
        // ignore: avoid_print
        print('  [OBS] v8 fresh sessions => '
            '${rows.map((r) => '${r['id']}:${r['title']} '
                'parent=${r['parent_session_id']} '
                'updated=${r['updated_at']}').join(' | ')}');
        expect(rows.length, 4);
        final parentRow =
            rows.firstWhere((r) => r['id'] == parent.id);
        final childRow = rows.firstWhere((r) => r['id'] == child.id);
        expect(parentRow['parent_session_id'], isNull,
            reason: '普通顶层会话的父 id 必须是 NULL');
        expect(childRow['parent_session_id'], parent.id,
            reason: '子记录必须准确保存父会话 id');
        expect(child.parentSessionId, parent.id);
        expect(parent.parentSessionId, isNull);
        // 重新读回来的模型也保留该字段。
        final reread = await repo.get(child.id);
        expect(reread!.parentSessionId, parent.id);

        // 真实 SessionRepository.list 只返回顶层会话，按 updated_at 倒序。
        final topLevel = await repo.list();
        // ignore: avoid_print
        print('  [OBS] repo.list() => '
            '${topLevel.map((s) => '${s.id}:${s.title}').join(' | ')}');
        expect(topLevel.map((s) => s.id).toList(), [otherTop.id, parent.id],
            reason: '普通列表必须排除子记录，并按最近更新倒序');
        expect(topLevel.any((s) => s.parentSessionId != null), isFalse);

        // 按父 id 查询子记录的只读入口：只有这一位父亲的子记录，倒序。
        final children = await repo.listChildren(parent.id);
        // ignore: avoid_print
        print('  [OBS] repo.listChildren(${parent.id}) => '
            '${children.map((s) => '${s.id}:${s.title}').join(' | ')}');
        expect(children.map((s) => s.id).toList(), [child.id, olderChild.id],
            reason: '子记录按父 id 查询，按最近更新倒序');
        expect(await repo.listChildren(otherTop.id), isEmpty);
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
