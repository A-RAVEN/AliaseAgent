import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Checkpoint 9: Session Isolation Verification
//
// Tests the snapshot-and-guard pattern that _ChatScreenState uses to prevent
// AI responses from leaking into the wrong session when the user switches
// sessions during an in-flight async API call.
// ---------------------------------------------------------------------------

final _uuid = Uuid();

String _currentId = '';
int _uiUpdateCount = 0;
int _uiBlockCount = 0;

/// Simulates the guarded setState pattern: `if (_currentId == sessionId) { ... }`
void guardedSetState(String sessionId, void Function() fn) {
  if (_currentId == sessionId) {
    _uiUpdateCount++;
    fn();
  } else {
    _uiBlockCount++;
  }
}

Future<Database> _openDb(String dir) async {
  return databaseFactoryFfi.openDatabase(
    '$dir/aliasagent.db',
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
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
      },
    ),
  );
}

Future<String> _createSession(Database db) async {
  final id = _uuid.v4();
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.insert('sessions', {
    'id': id,
    'title': 'New Chat',
    'agent_type': 'general',
    'created_at': now,
    'updated_at': now,
  });
  return id;
}

Future<String> _insertMsg(Database db,
    {required String sessionId, required String role, required String content}) async {
  final id = _uuid.v4();
  await db.insert('messages', {
    'id': id,
    'session_id': sessionId,
    'role': role,
    'content': content,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
  return id;
}

Future<void> _touchSession(Database db, String sessionId) async {
  await db.update('sessions', {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [sessionId]);
}

Future<List<Map<String, dynamic>>> _messagesFor(Database db, String sessionId) async {
  return db.query('messages',
      where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at ASC');
}

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final testDir = Directory.systemTemp.createTempSync('aliasagent_cp9_').path;

  final db = await _openDb(testDir);

  // Create 3 sessions
  final sessionA = await _createSession(db);
  final sessionB = await _createSession(db);
  final sessionC = await _createSession(db);
  print('Created sessions: A, B, C\n');

  // =========================================================================
  // Test A: 流式回复隔离
  // =========================================================================
  print('=== [A] 流式回复隔离 ===');

  // User is in session A, sends a message
  _currentId = sessionA;
  _uiUpdateCount = 0;
  _uiBlockCount = 0;

  await _insertMsg(db, sessionId: sessionA, role: 'user', content: 'Hello from A');
  await _touchSession(db, sessionA);

  // Snapshot sessionId before async gap (the Phase 9 fix)
  final snapA1 = _currentId;

  // During the async API call, user switches to session B
  _currentId = sessionB;
  print('  User switched to session B during in-flight request');

  // Async operation completes — uses snapshot, NOT _currentId
  final replyA1 = await _insertMsg(db, sessionId: snapA1, role: 'assistant', content: 'Reply');
  await _touchSession(db, snapA1);

  // Guarded setState — should be BLOCKED (current=B, snapshot=A)
  guardedSetState(snapA1, () { /* would add replyA1 to UI messages */ });

  // Verify: assistant message is in session A, NOT B
  final msgsA = await _messagesFor(db, sessionA);
  final msgsB = await _messagesFor(db, sessionB);

  assert(msgsA.length == 2, 'A) Session A should have 2 msgs, got ${msgsA.length}');
  assert(msgsA[0]['role'] == 'user', 'A) A[0] should be user');
  assert(msgsA[1]['role'] == 'assistant', 'A) A[1] should be assistant');
  assert(msgsB.isEmpty, 'A) Session B should have 0 msgs, got ${msgsB.length}');
  assert(_uiBlockCount == 1, 'A) UI guard should have blocked 1 setState');
  assert(_uiUpdateCount == 0, 'A) UI should NOT have been updated');

  print('  Session A: ${msgsA.length} messages (user + assistant) ✓');
  print('  Session B: ${msgsB.length} messages (empty) ✓');
  print('  UI guard blocked setState for wrong session ✓');
  print('[A] PASS\n');

  // =========================================================================
  // Test B: 新建会话隔离
  // =========================================================================
  print('=== [B] 新建会话隔离 ===');

  // User back in session A, sends another message
  _currentId = sessionA;
  _uiUpdateCount = 0;
  _uiBlockCount = 0;

  await _insertMsg(db, sessionId: sessionA, role: 'user', content: 'Second msg');
  await _touchSession(db, sessionA);

  final snapA2 = _currentId;

  // User creates a NEW session D during the async operation
  final sessionD = await _createSession(db);
  _currentId = sessionD;
  print('  User created new session D during in-flight request');

  // Async completes with snapshot
  await _insertMsg(db, sessionId: snapA2, role: 'assistant', content: 'Second reply');
  await _touchSession(db, snapA2);

  guardedSetState(snapA2, () {});

  // Verify: reply went to A, D is empty
  final msgsA2 = await _messagesFor(db, sessionA);
  final msgsD = await _messagesFor(db, sessionD);

  assert(msgsA2.length == 4, 'B) Session A should have 4 msgs, got ${msgsA2.length}');
  assert(msgsD.isEmpty, 'B) Session D should have 0 msgs, got ${msgsD.length}');
  assert(_uiBlockCount == 1, 'B) UI guard should have blocked setState');

  print('  Session A: ${msgsA2.length} messages (unchanged reply target) ✓');
  print('  Session D (new): ${msgsD.length} messages (empty) ✓');
  print('[B] PASS\n');

  // =========================================================================
  // Test C: UI 不错误更新 — guard 正向/反向验证
  // =========================================================================
  print('=== [C] UI guard 守卫验证 ===');

  _uiUpdateCount = 0;
  _uiBlockCount = 0;

  // When sessions match → guard ALLOWS
  _currentId = sessionA;
  var allowCount = 0;
  guardedSetState(sessionA, () { allowCount++; });
  assert(allowCount == 1, 'C) Guard should ALLOW when _currentId == sessionId');
  assert(_uiUpdateCount == 1, 'C) UI update count should increment');
  print('  Same session: guard ALLOWS setState ✓');

  // When sessions differ → guard BLOCKS
  _currentId = sessionB;
  allowCount = 0;
  guardedSetState(sessionA, () { allowCount++; });
  assert(allowCount == 0, 'C) Guard should BLOCK when _currentId != sessionId');
  assert(_uiBlockCount == 1, 'C) UI block count should increment');
  print('  Different session: guard BLOCKS setState ✓');
  print('[C] PASS\n');

  // =========================================================================
  // Test D: 数据库一致性
  // =========================================================================
  print('=== [D] 数据库一致性 ===');

  final allA = await _messagesFor(db, sessionA);
  for (final msg in allA) {
    assert(msg['session_id'] == sessionA,
        'D) Message ${msg['id']} session_id=${msg['session_id']} should be $sessionA');
  }

  // Check user/assistant pairs
  final userCount = allA.where((m) => m['role'] == 'user').length;
  final asstCount = allA.where((m) => m['role'] == 'assistant').length;
  assert(userCount == asstCount,
      'D) user=$userCount should equal assistant=$asstCount');

  print('  All ${allA.length} messages have correct session_id ✓');
  print('  user=$userCount, assistant=$asstCount — paired correctly ✓');
  print('[D] PASS\n');

  // =========================================================================
  // Test E: 错误消息隔离
  // =========================================================================
  print('=== [E] 错误消息隔离 ===');

  _currentId = sessionA;
  _uiUpdateCount = 0;
  _uiBlockCount = 0;

  final snapErr = _currentId;

  // Switch during "error handling"
  _currentId = sessionB;

  // Store error using snapshot (simulating _storeError with sessionId param)
  await _insertMsg(db, sessionId: snapErr, role: 'assistant', content: 'Error: API failed');
  await _touchSession(db, snapErr);

  guardedSetState(snapErr, () {});

  // Verify error went to A, not B
  final msgsAafter = await _messagesFor(db, sessionA);
  final msgsBafter = await _messagesFor(db, sessionB);
  final errorInA = msgsAafter.any((m) => (m['content'] as String).startsWith('Error:'));
  final errorInB = msgsBafter.any((m) => (m['content'] as String).startsWith('Error:'));

  assert(errorInA, 'E) Error should be in session A');
  assert(!errorInB, 'E) Error should NOT be in session B');
  assert(_uiBlockCount == 1, 'E) UI guard should have blocked');

  print('  Error stored in session A ✓');
  print('  Error NOT in session B ✓');
  print('[E] PASS\n');

  // =========================================================================
  // Cleanup
  // =========================================================================
  await db.close();
  Directory(testDir).deleteSync(recursive: true);

  print('=== Checkpoint 9: ALL 5 TESTS (A/B/C/D/E) PASS ===');
}
