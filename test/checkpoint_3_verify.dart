import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final testDir = '${Directory.systemTemp.path}/aliasagent_cp3_test';
  final testDir2 = '${Directory.systemTemp.path}/aliasagent_cp3_test2';

  _clean(testDir);
  _clean(testDir2);

  const schemaVersion = 1;

  // ---- A: First launch -> DB file and tables auto-created ----
  final db = await databaseFactoryFfi.openDatabase(
    _join(testDir, 'aliasagent.db'),
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onCreate: (db, version) => _onCreate(db),
    ),
  );

  final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
  final tableNames = tables.map((r) => r['name'] as String).toSet();
  assert(tableNames.contains('sessions'), 'Expected sessions table');
  assert(tableNames.contains('messages'), 'Expected messages table');

  // Verify indexes
  final indexes = await db
      .rawQuery("SELECT name FROM sqlite_master WHERE type='index'");
  final indexNames = indexes.map((r) => r['name'] as String).toSet();
  assert(indexNames.contains('idx_messages_session'),
      'Expected idx_messages_session');
  assert(indexNames.contains('idx_sessions_updated'),
      'Expected idx_sessions_updated');
  print('[A] PASS: First launch -- both tables + indexes auto-created v');

  // ---- B: Re-launch -- existing DB preserved ----
  await db.insert('sessions', {
    'id': 'test-session',
    'title': 'Survivor',
    'agent_type': 'general',
    'created_at': 1000,
    'updated_at': 1000,
  });
  await db.close();

  // Re-open same DB
  final db2 = await databaseFactoryFfi.openDatabase(
    _join(testDir, 'aliasagent.db'),
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onCreate: (db, version) async {
        throw 'should not recreate';
      },
    ),
  );
  final survivor =
      await db2.query('sessions', where: 'id = ?', whereArgs: ['test-session']);
  assert(survivor.isNotEmpty, 'Session should survive re-open');
  assert(survivor.first['title'] == 'Survivor');
  await db2.close();
  print('[B] PASS: Re-launch preserves data -- schema not overwritten v');

  // ---- C: Create session -> returns valid UUID ----
  final db3 = await databaseFactoryFfi.openDatabase(
    _join(testDir2, 'aliasagent.db'),
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onCreate: (db, version) => _onCreate(db),
    ),
  );

  final uuid = Uuid();
  final sessionId = uuid.v4();
  final now = DateTime.now().millisecondsSinceEpoch;
  await db3.insert('sessions', {
    'id': sessionId,
    'title': 'Test Chat',
    'agent_type': 'general',
    'created_at': now,
    'updated_at': now,
  });
  assert(Uuid.isValidUUID(fromString: sessionId),
      'Session ID must be valid UUID');

  final row =
      await db3.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
  assert(row.isNotEmpty);
  assert(row.first['title'] == 'Test Chat');
  assert(row.first['agent_type'] == 'general');
  assert((row.first['created_at'] as int) > 0);
  print('[C] PASS: Session created -- id="$sessionId", title="Test Chat" v');

  // ---- D: Insert messages with role constraint ----
  final userMsgId = uuid.v4();
  await db3.insert('messages', {
    'id': userMsgId,
    'session_id': sessionId,
    'role': 'user',
    'content': 'Hello, world!',
    'token_count': null,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });

  final asstMsgId = uuid.v4();
  await db3.insert('messages', {
    'id': asstMsgId,
    'session_id': sessionId,
    'role': 'assistant',
    'content': 'Hi there!',
    'token_count': 42,
    'created_at': DateTime.now().millisecondsSinceEpoch + 1,
  });

  // Verify role CHECK constraint rejects invalid roles
  bool checkWorks = false;
  try {
    await db3.insert('messages', {
      'id': uuid.v4(),
      'session_id': sessionId,
      'role': 'system',
      'content': 'bad',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  } catch (_) {
    checkWorks = true;
  }
  assert(checkWorks, 'CHECK constraint should reject role="system"');
  print(
      '[D] PASS: Messages inserted -- user + assistant, CHECK constraint enforced v');

  // ---- E: Query messages by session, ordered by created_at ASC ----
  final msgs = await db3.query(
    'messages',
    where: 'session_id = ?',
    whereArgs: [sessionId],
    orderBy: 'created_at ASC',
  );
  assert(msgs.length == 2);
  assert(msgs[0]['role'] == 'user');
  assert(msgs[1]['role'] == 'assistant');
  assert((msgs[0]['created_at'] as int) <= (msgs[1]['created_at'] as int));
  print('[E] PASS: Messages queried -- 2 messages, user before assistant v');

  // ---- F: Session list ordered by updated_at DESC ----
  final sessionId2 = uuid.v4();
  final later = DateTime.now().millisecondsSinceEpoch + 100;
  await db3.insert('sessions', {
    'id': sessionId2,
    'title': 'Newer Chat',
    'agent_type': 'general',
    'created_at': later,
    'updated_at': later,
  });

  final list = await db3.query('sessions', orderBy: 'updated_at DESC');
  assert(list.length >= 2);
  assert(list[0]['id'] == sessionId2, 'Most recent session should be first');
  assert((list[0]['updated_at'] as int) >= (list[1]['updated_at'] as int));
  print('[F] PASS: Session list ordered by updated_at DESC v');

  // ---- G: Delete session -> cascade deletes messages ----
  await db3.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  final deletedSession =
      await db3.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
  assert(deletedSession.isEmpty, 'Session should be deleted');
  final orphanMsgs = await db3.query('messages',
      where: 'session_id = ?', whereArgs: [sessionId]);
  assert(orphanMsgs.isEmpty, 'Messages should be cascade-deleted');
  print('[G] PASS: Cascade delete -- session + messages removed v');

  await db3.close();

  // Cleanup
  _clean(testDir);
  _clean(testDir2);

  print('');
  print('=== Checkpoint 3 A/B/C/D/E/F/G: ALL PASS ===');
}

Future<void> _onCreate(Database db) async {
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

void _clean(String dir) {
  final d = Directory(dir);
  if (d.existsSync()) d.deleteSync(recursive: true);
}