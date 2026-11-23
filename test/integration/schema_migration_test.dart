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
        // 当前建库版本已随 group-reactive-mode 升到 11（v9 是 agent-group-chat，
        // v10 加 sessions.reactions_enabled、v11 补 sessions.max_reaction_rounds）；
        // 这里验的是「全新建库也带 attachments」，版本号取当前 schema 版本。
        expect(await freshDb.getVersion(), 11);
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
      // v10/v11（group-reactive-mode）再往上加两版：本用例只验 v8 的列在升级产物里。
      expect(await db.getVersion(), 11);

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
        // 当前 schema 版本（v11 = group-reactive-mode 的 sessions.max_reaction_rounds）。
        expect(await db.getVersion(), 11);

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

  _v9MigrationTests();
  _v10MigrationTests();
}

// -----------------------------------------------------------------------------
// v9 → v10（change `group-reactive-mode` 任务 0.1 / design D8）
// -----------------------------------------------------------------------------

/// 按 v9 的建表语句造一个旧库：**一条 group 会话 + 一条 single 会话**、两条消息、
/// 一条摘要、一条成员，索引与生产 v9 逐项对齐（结构指纹要比的就是这些）。
Future<void> _createV9Database(Directory dir) async {
  final dbPath = p.join(dir.path, 'aliasagent.db');
  final db9 = await openDatabase(dbPath, version: 9, onCreate: (db, v) async {
    await db.execute('''CREATE TABLE sessions (
      id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
      agent_type TEXT NOT NULL DEFAULT 'general',
      parent_session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      tree_version INTEGER NOT NULL DEFAULT 0,
      dirty_since_seq INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'single',
      overrides_json TEXT)''');
    await db.execute('''CREATE TABLE messages (
      id TEXT PRIMARY KEY, seq INTEGER,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK(role IN ('user','assistant')),
      content TEXT NOT NULL, tool_calls TEXT, thinking_json TEXT,
      token_count INTEGER, output_token_count INTEGER,
      attachments TEXT, created_at INTEGER NOT NULL,
      author TEXT, visibility TEXT NOT NULL DEFAULT 'public')''');
    await db.execute('CREATE INDEX idx_messages_session ON messages(session_id)');
    await db.execute('CREATE INDEX idx_messages_seq ON messages(session_id, seq)');
    await db.execute('CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC)');
    await db.execute('''CREATE TABLE summary_nodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      member_id TEXT,
      level INTEGER NOT NULL, start_seq INTEGER NOT NULL, end_seq INTEGER NOT NULL,
      node_type TEXT NOT NULL, parent_id INTEGER, summary_json TEXT,
      token_cost INTEGER, summary_prompt_version INTEGER, model TEXT,
      covered_min_seq INTEGER NOT NULL, covered_max_seq INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX idx_summary_nodes_session ON summary_nodes(session_id)');
    await db.execute('CREATE INDEX idx_summary_nodes_span ON summary_nodes(session_id, member_id, level, start_seq, end_seq)');
    await db.execute('CREATE INDEX idx_summary_nodes_leaf_owner ON summary_nodes(session_id, member_id, covered_min_seq, covered_max_seq)');
    await db.execute('''CREATE TABLE group_members (
      id TEXT PRIMARY KEY,
      group_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL, template_name TEXT NOT NULL, overrides_json TEXT,
      removed_at INTEGER, created_at INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX idx_group_members_group ON group_members(group_session_id)');
    await db.execute(
        'CREATE UNIQUE INDEX idx_group_members_active_name '
        'ON group_members(group_session_id, name) WHERE removed_at IS NULL');
  });
  await db9.insert('sessions', {
    'id': 'old-group',
    'title': '升级前的组',
    'agent_type': 'reviewer',
    'created_at': 11,
    'updated_at': 22,
    'tree_version': 3,
    'dirty_since_seq': 5,
    'kind': 'group',
    'overrides_json': null,
  });
  await db9.insert('sessions', {
    'id': 'old-single',
    'title': '升级前的单会话',
    'agent_type': 'reviewer',
    'created_at': 33,
    'updated_at': 44,
    'tree_version': 1,
    'dirty_since_seq': 0,
    'kind': 'single',
    'overrides_json': '{"toolsSubset":["read_file"]}',
  });
  await db9.insert('messages', {
    'id': 'old-group-msg',
    'seq': 1,
    'session_id': 'old-group',
    'role': 'user',
    'content': '组里的老消息',
    'attachments': '[{"path":"old.png"}]',
    'token_count': 7,
    'output_token_count': 3,
    'created_at': 11,
    'author': null,
    'visibility': 'public',
  });
  await db9.insert('messages', {
    'id': 'old-single-msg',
    'seq': 2,
    'session_id': 'old-single',
    'role': 'assistant',
    'content': '单会话的老消息',
    'created_at': 33,
    'author': null,
    'visibility': 'public',
  });
  await db9.insert('summary_nodes', {
    'session_id': 'old-group',
    'member_id': 'old-member',
    'level': 1,
    'start_seq': 1,
    'end_seq': 1,
    'node_type': 'leaf',
    'summary_json': '{"summary":"旧摘要"}',
    'token_cost': 9,
    'covered_min_seq': 1,
    'covered_max_seq': 1,
  });
  await db9.insert('group_members', {
    'id': 'old-member',
    'group_session_id': 'old-group',
    'name': '老成员',
    'template_name': 'general',
    'created_at': 11,
  });
  await db9.close();
}

/// 按 **v10（同步实现升上来的真实库）** 的建表语句造一个库：sessions 有
/// `reactions_enabled`，但**没有** `max_reaction_rounds`（同步实现当时把版本号升到
/// 10 却只加了开关列；异步返工把上限列塞进 `oldV <= 9`，而真实库已是 v10 ⇒ 永远不补）。
///
/// 这是 change `group-reactive-mode` R.1 的回归靶：修复前用它打开会停在 v10、缺列；
/// 修复后 `oldV <= 10` 分支补列并升到 v11。
Future<void> _createV10Database(Directory dir) async {
  final dbPath = p.join(dir.path, 'aliasagent.db');
  final db10 = await openDatabase(dbPath, version: 10, onCreate: (db, v) async {
    await db.execute('''CREATE TABLE sessions (
      id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
      agent_type TEXT NOT NULL DEFAULT 'general',
      parent_session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      tree_version INTEGER NOT NULL DEFAULT 0,
      dirty_since_seq INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL DEFAULT 'single',
      overrides_json TEXT,
      reactions_enabled INTEGER NOT NULL DEFAULT 1)''');
    await db.execute('''CREATE TABLE messages (
      id TEXT PRIMARY KEY, seq INTEGER,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK(role IN ('user','assistant')),
      content TEXT NOT NULL, tool_calls TEXT, thinking_json TEXT,
      token_count INTEGER, output_token_count INTEGER,
      attachments TEXT, created_at INTEGER NOT NULL,
      author TEXT, visibility TEXT NOT NULL DEFAULT 'public')''');
    await db.execute('CREATE INDEX idx_messages_session ON messages(session_id)');
    await db.execute('CREATE INDEX idx_messages_seq ON messages(session_id, seq)');
    await db.execute('CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC)');
    await db.execute('''CREATE TABLE summary_nodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      member_id TEXT,
      level INTEGER NOT NULL, start_seq INTEGER NOT NULL, end_seq INTEGER NOT NULL,
      node_type TEXT NOT NULL, parent_id INTEGER, summary_json TEXT,
      token_cost INTEGER, summary_prompt_version INTEGER, model TEXT,
      covered_min_seq INTEGER NOT NULL, covered_max_seq INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX idx_summary_nodes_session ON summary_nodes(session_id)');
    await db.execute('CREATE INDEX idx_summary_nodes_span ON summary_nodes(session_id, member_id, level, start_seq, end_seq)');
    await db.execute('CREATE INDEX idx_summary_nodes_leaf_owner ON summary_nodes(session_id, member_id, covered_min_seq, covered_max_seq)');
    await db.execute('''CREATE TABLE group_members (
      id TEXT PRIMARY KEY,
      group_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      name TEXT NOT NULL, template_name TEXT NOT NULL, overrides_json TEXT,
      removed_at INTEGER, created_at INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX idx_group_members_group ON group_members(group_session_id)');
    await db.execute(
        'CREATE UNIQUE INDEX idx_group_members_active_name '
        'ON group_members(group_session_id, name) WHERE removed_at IS NULL');
  });
  // 同步实现的迁移把**既有组行**回填成 0、单会话行保持 1；这里照真实产物造。
  await db10.insert('sessions', {
    'id': 'sync-group',
    'title': '同步实现升上来的组',
    'agent_type': 'reviewer',
    'created_at': 11,
    'updated_at': 22,
    'kind': 'group',
    'reactions_enabled': 0,
  });
  await db10.insert('sessions', {
    'id': 'sync-single',
    'title': '同步实现升上来的单会话',
    'agent_type': 'general',
    'created_at': 33,
    'updated_at': 44,
    'kind': 'single',
    'reactions_enabled': 1,
  });
  await db10.insert('messages', {
    'id': 'sync-msg',
    'seq': 1,
    'session_id': 'sync-group',
    'role': 'user',
    'content': '升级前的消息',
    'created_at': 11,
    'author': null,
    'visibility': 'public',
  });
  await db10.insert('summary_nodes', {
    'session_id': 'sync-group',
    'member_id': 'sync-member',
    'level': 1,
    'start_seq': 1,
    'end_seq': 1,
    'node_type': 'leaf',
    'summary_json': '{"summary":"同步实现的摘要"}',
    'token_cost': 5,
    'covered_min_seq': 1,
    'covered_max_seq': 1,
  });
  await db10.insert('group_members', {
    'id': 'sync-member',
    'group_session_id': 'sync-group',
    'name': '老成员',
    'template_name': 'general',
    'created_at': 11,
  });
  await db10.close();
}

void _v10MigrationTests() {
  group('Database schema migration v9 -> v11 / v10 -> v11', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mig_v11_test_');
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    // -------------------------------------------------------------------------
    // 版本撞车回归靶（同步实现把真实库升到 v10、只加了 reactions_enabled；异步返工
    // 把 max_reaction_rounds 塞进 oldV <= 9 ⇒ 真实库永远补不上列）。修复：版本升到
    // 11，`oldV <= 10` 单独补列。
    // -------------------------------------------------------------------------
    test('v10 库（同步实现升上来的真实库）升级到 v11：补 max_reaction_rounds、旧组开关保留、行数不变',
        () async {
      await _createV10Database(tempDir);
      // 前置事实：这个库真的**缺** max_reaction_rounds（否则本用例在测别的东西）。
      final probe = await openDatabase(p.join(tempDir.path, 'aliasagent.db'));
      final beforeCols = await probe.rawQuery('PRAGMA table_info(sessions)');
      await probe.close();
      final beforeNames = beforeCols.map((row) => row['name']).toSet();
      // ignore: avoid_print
      print('  [OBS] v10 升级前 sessions 列 => $beforeNames');
      expect(beforeNames, contains('reactions_enabled'));
      expect(beforeNames, isNot(contains('max_reaction_rounds')),
          reason: '夹具必须是同步实现的真实形状：有开关列、没有上限列');

      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;
      final version = await db.getVersion();
      final cols = await db.rawQuery('PRAGMA table_info(sessions)');
      final names = cols.map((row) => row['name']).toList();
      final sessions = await db.query('sessions', orderBy: 'id');
      final messages = await db.query('messages');
      final summaries = await db.query('summary_nodes');
      final members = await db.query('group_members');
      // ignore: avoid_print
      print('  [OBS] v10 -> v11 version=$version '
          'sessions=${sessions.length} messages=${messages.length} '
          'summaries=${summaries.length} members=${members.length}');
      // ignore: avoid_print
      print('  [OBS] v10 -> v11 sessions => '
          '${sessions.map((r) => '${r['id']}: reactions=${r['reactions_enabled']} '
              'max_rounds=${r['max_reaction_rounds']}').join(' | ')}');

      // ① 缺的列必须补上（红靶：修复前这里没有 max_reaction_rounds）。
      expect(names, contains('max_reaction_rounds'),
          reason: 'v10 库升级到 v11 必须补上 max_reaction_rounds 列');
      final added = cols.firstWhere((row) => row['name'] == 'max_reaction_rounds');
      expect(added['type'], 'INTEGER');
      expect(added['notnull'], 0, reason: '可空：NULL = 用产品默认');
      expect(added['dflt_value'], isNull);

      // ② 版本号必须到 11。
      expect(version, 11, reason: 'schema 版本必须是 11（v10→v11 补列）');

      // ③ 迁移不删行、不改既有值：旧组仍是安静态（同步实现的回填结果保留）。
      expect(sessions.length, 2, reason: '迁移不删行');
      expect(messages.length, 1, reason: '迁移不删行');
      expect(summaries.length, 1, reason: '迁移不删行');
      expect(members.length, 1, reason: '迁移不删行');
      final groupRow = sessions.firstWhere((r) => r['id'] == 'sync-group');
      final singleRow = sessions.firstWhere((r) => r['id'] == 'sync-single');
      expect(groupRow['reactions_enabled'], 0,
          reason: '旧组的关闭状态是同步实现的产物，升级不许改回 1');
      expect(singleRow['reactions_enabled'], 1);
      expect(groupRow['max_reaction_rounds'], isNull,
          reason: '补列后旧行上限为 NULL（用产品默认 8）');
      expect(singleRow['max_reaction_rounds'], isNull);
      // 既有数据原样。
      expect(summaries.first['member_id'], 'sync-member');
      expect(members.first['name'], '老成员');
      expect(messages.first['content'], '升级前的消息');

      // ④ 升级产物与全新建库的结构一致（两份都已是 v11）。
      final upgraded = await _structureFingerprint(db);
      await DatabaseService.close();
      final freshDir = Directory.systemTemp.createTempSync('mig_v11_fresh_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final fresh =
            await _structureFingerprint(await DatabaseService.database);
        for (final table in upgraded.keys) {
          expect(upgraded[table], equals(fresh[table]),
              reason: '表 $table 的列/索引在「v10 升级产物」与「全新建库」之间不一致');
        }
      } finally {
        await DatabaseService.close();
        if (freshDir.existsSync()) {
          try {
            freshDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    });

    test('v9 库无损升级：行数不变、旧组回填 0、旧单会话保持 1、结构指纹一致', () async {
      await _createV9Database(tempDir);
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;

      final version = await db.getVersion();
      final sessions = await db.query('sessions', orderBy: 'id');
      final messages = await db.query('messages');
      final summaries = await db.query('summary_nodes');
      final members = await db.query('group_members');
      // ignore: avoid_print
      print('  [OBS] v10 version=$version sessions=${sessions.length} '
          'messages=${messages.length} summaries=${summaries.length} '
          'members=${members.length}');
      // ignore: avoid_print
      print('  [OBS] v10 sessions => '
          '${sessions.map((r) => '${r['id']}: kind=${r['kind']} '
              'reactions=${r['reactions_enabled']} '
              'max_rounds=${r['max_reaction_rounds']} '
              'overrides=${r['overrides_json']}').join(' | ')}');
      // ignore: avoid_print
      print('  [OBS] v10 messages => '
          '${messages.map((r) => '${r['id']}: ${r['content']}').join(' | ')}');

      expect(version, 11, reason: 'schema 版本必须是 11（v9→v10 两列 + v10→v11 补上限列）');
      expect(sessions.length, 2, reason: '迁移不删行');
      expect(messages.length, 2, reason: '迁移不删行');
      expect(summaries.length, 1, reason: '迁移不删行');
      expect(members.length, 1, reason: '迁移不删行');

      final groupRow = sessions.firstWhere((r) => r['id'] == 'old-group');
      final singleRow = sessions.firstWhere((r) => r['id'] == 'old-single');

      // 迁移的核心语义：**既有组行回填 false**，既有单会话行保持列默认 1。
      expect(groupRow['reactions_enabled'], 0,
          reason: '旧组升级后必须是安静态（保留旧点名体验）');
      expect(singleRow['reactions_enabled'], 1,
          reason: '旧单会话行保持列默认 1（无行为意义，但必须可断言）');
      // v10 的**第二列**（change `group-reactive-mode` R.1 / design D13）：
      // 迁移只加可空列、不回填 ⇒ 旧行上限为 NULL（= 用产品默认 8）。
      expect(groupRow['max_reaction_rounds'], isNull,
          reason: '旧组上限保持 NULL（用产品默认 8）');
      expect(singleRow['max_reaction_rounds'], isNull);

      // 模型读出同一口径：旧组 false、旧单会话 true、两者 maxRounds 都为 null
      // （fromRow 各一次）。
      expect(Session.fromRow(groupRow).reactionsEnabled, isFalse);
      expect(Session.fromRow(singleRow).reactionsEnabled, isTrue);
      expect(Session.fromRow(groupRow).maxRounds, isNull);
      expect(Session.fromRow(singleRow).maxRounds, isNull);

      // 旧单会话的 kind / overrides 等字段不变。
      expect(singleRow['kind'], 'single');
      expect(singleRow['overrides_json'], '{"toolsSubset":["read_file"]}');
      expect(singleRow['agent_type'], 'reviewer');
      expect(singleRow['tree_version'], 1);
      expect(groupRow['kind'], 'group');
      expect(groupRow['agent_type'], 'reviewer');
      expect(groupRow['tree_version'], 3);
      expect(groupRow['dirty_since_seq'], 5);

      // 旧消息 / 摘要 / 成员原样。
      expect(
          messages
              .firstWhere((r) => r['id'] == 'old-group-msg')['attachments'],
          '[{"path":"old.png"}]');
      expect(summaries.first['member_id'], 'old-member');
      expect(members.first['name'], '老成员');

      // 结构指纹：升级产物 == 全新建库（逐表逐列逐索引）。
      final upgraded = await _structureFingerprint(db);
      await DatabaseService.close();
      final freshDir = Directory.systemTemp.createTempSync('mig_v10_fresh_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final fresh =
            await _structureFingerprint(await DatabaseService.database);
        // ignore: avoid_print
        print('  [OBS] 升级产物 sessions 列 => '
            '${((upgraded['sessions'] as Map)['columns'] as Map).keys.join(",")}');
        // ignore: avoid_print
        print('  [OBS] 全新建库 sessions 列 => '
            '${((fresh['sessions'] as Map)['columns'] as Map).keys.join(",")}');
        for (final table in upgraded.keys) {
          expect(upgraded[table], equals(fresh[table]),
              reason: '表 $table 的列/索引在「v9 升级产物」与「全新建库」之间不一致');
        }
      } finally {
        await DatabaseService.close();
        if (freshDir.existsSync()) {
          try {
            freshDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    });

    test('新建 v11 库直接含两个组设置列且新组读出 true / null', () async {
      final freshDir = Directory.systemTemp.createTempSync('mig_v10_new_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final db = await DatabaseService.database;
        final cols = await db.rawQuery('PRAGMA table_info(sessions)');
        final column = cols.firstWhere((c) => c['name'] == 'reactions_enabled');
        // ignore: avoid_print
        print('  [OBS] sessions.reactions_enabled => type=${column['type']} '
            'notnull=${column['notnull']} default=${column['dflt_value']}');
        expect(column['type'], 'INTEGER');
        expect(column['notnull'], 1);
        expect(column['dflt_value'], '1');

        // v10 的第二列：可空的轮数上限（change `group-reactive-mode` R.1）。
        final maxRoundsColumn =
            cols.firstWhere((c) => c['name'] == 'max_reaction_rounds');
        // ignore: avoid_print
        print('  [OBS] sessions.max_reaction_rounds => '
            'type=${maxRoundsColumn['type']} '
            'notnull=${maxRoundsColumn['notnull']} '
            'default=${maxRoundsColumn['dflt_value']}');
        expect(maxRoundsColumn['type'], 'INTEGER');
        expect(maxRoundsColumn['notnull'], 0, reason: '可空：NULL = 用产品默认');
        expect(maxRoundsColumn['dflt_value'], isNull);

        final repo = SessionRepository();
        final group = await repo.create(title: '新组', kind: Session.kindGroup);
        expect(group.reactionsEnabled, isTrue, reason: '新建组默认开启');
        expect(group.maxRounds, isNull, reason: '新建组上限为空 = 用产品默认');
        final reread = await repo.get(group.id);
        expect(reread!.reactionsEnabled, isTrue);
        expect(reread.maxRounds, isNull);
        final row = (await db.query('sessions',
                where: 'id = ?', whereArgs: [group.id]))
            .first;
        expect(row['reactions_enabled'], 1);
        expect(row['max_reaction_rounds'], isNull);
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

// -----------------------------------------------------------------------------
// v8 → v9（change `agent-group-chat` 任务 1.6 / design D14）
// -----------------------------------------------------------------------------

/// 按 v8 的建表语句造一个旧库：会话、消息（带附件）、摘要各一条 + 索引。
Future<void> _createV8Database(Directory dir) async {
  final dbPath = p.join(dir.path, 'aliasagent.db');
  final db8 = await openDatabase(dbPath, version: 8, onCreate: (db, v) async {
    await db.execute('''CREATE TABLE sessions (
      id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
      agent_type TEXT NOT NULL DEFAULT 'general',
      parent_session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
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
    await db.execute('CREATE INDEX idx_messages_session ON messages(session_id)');
    await db.execute('CREATE INDEX idx_messages_seq ON messages(session_id, seq)');
    await db.execute('CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC)');
    await db.execute('''CREATE TABLE summary_nodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      level INTEGER NOT NULL, start_seq INTEGER NOT NULL, end_seq INTEGER NOT NULL,
      node_type TEXT NOT NULL, parent_id INTEGER, summary_json TEXT,
      token_cost INTEGER, summary_prompt_version INTEGER, model TEXT,
      covered_min_seq INTEGER NOT NULL, covered_max_seq INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX idx_summary_nodes_session ON summary_nodes(session_id)');
    await db.execute('CREATE INDEX idx_summary_nodes_span ON summary_nodes(session_id, level, start_seq, end_seq)');
    await db.execute('CREATE INDEX idx_summary_nodes_leaf_owner ON summary_nodes(session_id, covered_min_seq, covered_max_seq)');
  });
  await db8.insert('sessions', {
    'id': 'old-8',
    'title': '升级前会话',
    'agent_type': 'reviewer',
    'created_at': 11,
    'updated_at': 22,
    'tree_version': 3,
    'dirty_since_seq': 5,
  });
  await db8.insert('messages', {
    'id': 'old-8-msg',
    'seq': 1,
    'session_id': 'old-8',
    'role': 'user',
    'content': '升级前的消息',
    'attachments': '[{"path":"old.png"}]',
    'token_count': 7,
    'output_token_count': 3,
    'created_at': 11,
  });
  await db8.insert('summary_nodes', {
    'session_id': 'old-8',
    'level': 1,
    'start_seq': 1,
    'end_seq': 1,
    'node_type': 'leaf',
    'summary_json': '{"summary":"旧摘要"}',
    'token_cost': 9,
    'covered_min_seq': 1,
    'covered_max_seq': 1,
  });
  await db8.close();
}

/// 结构指纹：每张表取 `PRAGMA table_info`（列名/类型/非空/默认值/主键）与
/// `PRAGMA index_list` + `index_info`（索引名、唯一、列序列）。逐项比对，不用
/// "看起来一样"糊过去（design D14 第 6 条）。
///
/// 列**按名字索引**而不是按位置：`ALTER TABLE ADD COLUMN` 只能把新列追加到表尾，
/// 物理列序与全新建库不可能一致，而 SQLite 的所有访问都按列名进行（列序没有语义）。
/// 除列序之外的每一项（类型 / 非空 / 默认值 / 主键）与索引的（唯一性 / 列序列）
/// 都逐项严格比较。
Future<Map<String, Object?>> _structureFingerprint(Database db) async {
  const tables = ['sessions', 'messages', 'summary_nodes', 'group_members'];
  final out = <String, Object?>{};
  for (final table in tables) {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final indexList = await db.rawQuery('PRAGMA index_list($table)');
    final indexes = <String, Object?>{};
    for (final index in indexList) {
      final name = index['name'] as String;
      if (name.startsWith('sqlite_autoindex')) continue;
      final info = await db.rawQuery('PRAGMA index_info($name)');
      indexes[name] = {
        'unique': index['unique'],
        'columns': [for (final row in info) row['name']],
      };
    }
    out[table] = {
      'columns': {
        for (final column in columns)
          column['name'] as String: {
            'type': column['type'],
            'notnull': column['notnull'],
            'default': column['dflt_value'],
            'pk': column['pk'],
          }
      },
      'indexes': indexes,
    };
  }
  return out;
}

void _v9MigrationTests() {
  group('Database schema migration v8 -> v9 (agent-group-chat)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mig_v9_test_');
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('v8 库无损升级：行数不变、旧行按默认语义读出、新列新表都在', () async {
      await _createV8Database(tempDir);
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;

      final version = await db.getVersion();
      final sessions = await db.query('sessions');
      final messages = await db.query('messages');
      final summaries = await db.query('summary_nodes');
      // ignore: avoid_print
      print('  [OBS] v9 version=$version sessions=${sessions.length} '
          'messages=${messages.length} summaries=${summaries.length}');
      // ignore: avoid_print
      print('  [OBS] 旧会话 => kind=${sessions.first['kind']} '
          'overrides=${sessions.first['overrides_json']} '
          'agent_type=${sessions.first['agent_type']} '
          'tree=${sessions.first['tree_version']} dirty=${sessions.first['dirty_since_seq']}');
      // ignore: avoid_print
      print('  [OBS] 旧消息 => author=${messages.first['author']} '
          'visibility=${messages.first['visibility']} '
          'content=${messages.first['content']}');
      // ignore: avoid_print
      print('  [OBS] 旧摘要 => member_id=${summaries.first['member_id']}');

      // v10/v11（group-reactive-mode）：v9 库再往上升，终点是 11；本用例验的是
      // v9 的列（kind / overrides_json / author / visibility / member_id）都还在。
      expect(version, 11);
      expect(sessions.length, 1, reason: '迁移不删行');
      expect(messages.length, 1, reason: '迁移不删行');
      expect(summaries.length, 1, reason: '迁移不删行');

      expect(sessions.first['agent_type'], 'reviewer', reason: '模板选择原样保留');
      expect(sessions.first['kind'], 'single');
      expect(sessions.first['overrides_json'], isNull);
      expect(sessions.first['tree_version'], 3);
      expect(sessions.first['dirty_since_seq'], 5);

      expect(messages.first['content'], '升级前的消息');
      expect(messages.first['attachments'], '[{"path":"old.png"}]');
      expect(messages.first['author'], isNull);
      expect(messages.first['visibility'], 'public');

      expect(summaries.first['member_id'], isNull,
          reason: '旧摘要的成员作用域为空 = 单会话路径');
      expect(summaries.first['summary_json'], '{"summary":"旧摘要"}');

      // group_members 新表（含 overrides_json 与 removed_at）。
      final memberCols = await db.rawQuery('PRAGMA table_info(group_members)');
      // ignore: avoid_print
      print('  [OBS] group_members cols => '
          '${memberCols.map((c) => c['name']).join(',')}');
      expect(memberCols.map((c) => c['name']).toSet(), containsAll([
        'id',
        'group_session_id',
        'name',
        'template_name',
        'overrides_json',
        'removed_at',
        'created_at',
      ]));

      // 模型读旧行也不炸。
      final session = Session.fromRow(sessions.first);
      expect(session.kind, 'single');
      expect(session.overrides, isNull);
      expect(Message.fromRow(messages.first).visibility, 'public');
      expect(Message.fromRow(messages.first).author, isNull);
    });

    test('升级产物 vs 全新建库：table_info / index_list 逐项一致', () async {
      await _createV8Database(tempDir);
      await DatabaseService.openAt(tempDir.path);
      final upgraded = await _structureFingerprint(
          await DatabaseService.database);
      await DatabaseService.close();

      final freshDir = Directory.systemTemp.createTempSync('mig_v9_fresh_');
      try {
        await DatabaseService.openAt(freshDir.path);
        final fresh =
            await _structureFingerprint(await DatabaseService.database);
        // ignore: avoid_print
        print('  [OBS] 升级产物 messages 列 => '
            '${((upgraded['messages'] as Map)['columns'] as Map).keys.join(",")}');
        // ignore: avoid_print
        print('  [OBS] 全新建库 messages 列 => '
            '${((fresh['messages'] as Map)['columns'] as Map).keys.join(",")}');
        // ignore: avoid_print
        print('  [OBS] 升级产物 summary_nodes 索引 => '
            '${(upgraded['summary_nodes'] as Map)['indexes']}');
        // ignore: avoid_print
        print('  [OBS] 全新建库 summary_nodes 索引 => '
            '${(fresh['summary_nodes'] as Map)['indexes']}');
        for (final table in upgraded.keys) {
          expect(upgraded[table], equals(fresh[table]),
              reason: '表 $table 的列/索引在「升级产物」与「全新建库」之间不一致');
        }
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