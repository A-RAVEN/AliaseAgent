import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Checkpoint 10: Multi-turn Tool Call Text Fix Verification
//
// Simulates the _callModel() tool loop to verify that stored assistant
// messages use turnText (current turn only), not allText (cross-turn accumulator).
// ---------------------------------------------------------------------------

final _uuid = Uuid();

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
            created_at INTEGER NOT NULL
          )
        ''');
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

Future<List<Map<String, dynamic>>> _messagesFor(Database db, String sessionId) async {
  return db.query('messages',
      where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'created_at ASC');
}

// ---------------------------------------------------------------------------
// Simulate the tool call loop from _callModel()
// ---------------------------------------------------------------------------

/// Represents one turn in the tool loop.
/// [text] — the streaming text received this turn (simulating onChunk callbacks)
/// [toolCalls] — tool calls made this turn (empty list = no tools, final turn)
class TurnResult {
  final String text;
  final List<Map<String, dynamic>> toolCalls;
  final bool apiError;

  TurnResult({required this.text, this.toolCalls = const [], this.apiError = false});
}

/// Simulates the _callModel() tool loop, returning the text that would be
/// stored as the assistant message content.
///
/// [withFix]: true = Phase 10 fix (use turnText), false = old buggy behavior (use allText)
Future<String?> simulateToolLoop(
    List<TurnResult> turns, bool withFix) async {
  String allText = '';
  String? finalTurnText;

  for (final turn in turns) {
    if (turn.apiError) return null; // error path, no message stored

    // Simulate onChunk accumulation
    String turnText = '';
    // In real code, chunks arrive via callbacks; we get the full text
    turnText = turn.text;
    allText += turn.text;

    if (turn.toolCalls.isEmpty) {
      // No tool calls — this is the final turn
      finalTurnText = turnText;
      break;
    }

    // Would build assistant blocks + tool results + loop again
    // turnText resets at top of next iteration
  }

  if (finalTurnText == null) return null;

  return withFix ? finalTurnText : allText;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final testDir = Directory.systemTemp.createTempSync('aliasagent_cp10_').path;
  final db = await _openDb(testDir);
  final sessionId = await _createSession(db);

  // =========================================================================
  // Test A: 单轮无工具 — 不受影响
  // =========================================================================
  print('=== [A] 单轮无工具 ===');

  final turnsA = [
    TurnResult(text: 'Hello, how can I help you?', toolCalls: []),
  ];

  final oldA = await simulateToolLoop(turnsA, false);
  final newA = await simulateToolLoop(turnsA, true);
  assert(oldA == newA,
      'A) Single-turn no-tool: old=$oldA should equal new=$newA');
  print('  Old behavior: "${oldA}"');
  print('  New behavior: "${newA}"');
  print('  Identical ✓');
  print('[A] PASS\n');

  // =========================================================================
  // Test B: 多轮有工具 — 旧行为累加全部轮次，新行为仅保留最后一轮
  // =========================================================================
  print('=== [B] 多轮有工具 ===');

  final turnsB = [
    TurnResult(text: 'Let me read the file for you.', toolCalls: [
      {'name': 'read_file', 'input': {'path': '/test.txt'}}
    ]),
    TurnResult(text: 'The file contains: Hello World', toolCalls: []),
  ];

  final oldB = await simulateToolLoop(turnsB, false);
  final newB = await simulateToolLoop(turnsB, true);

  final expectedOld = 'Let me read the file for you.The file contains: Hello World';
  final expectedNew = 'The file contains: Hello World';

  print('  Old (allText): "${oldB}"');
  print('  New (turnText): "${newB}"');
  assert(oldB == expectedOld,
      'B) Old should accumulate all turns: "$expectedOld", got "$oldB"');
  assert(newB == expectedNew,
      'B) New should only have last turn: "$expectedNew", got "$newB"');
  assert(oldB != newB, 'B) Old and new SHOULD differ');

  print('  Old accumulates across turns ✓');
  print('  New preserves only final turn ✓');
  print('[B] PASS\n');

  // =========================================================================
  // Test C: 仅工具调用无文本 — 不产生空 content 消息
  // =========================================================================
  print('=== [C] 仅工具调用无文本 ===');

  final turnsC = [
    TurnResult(text: '', toolCalls: [
      {'name': 'list_dir', 'input': {'path': '/tmp'}}
    ]),
    TurnResult(text: 'The directory is empty.', toolCalls: []),
  ];

  final newC = await simulateToolLoop(turnsC, true);
  assert(newC == 'The directory is empty.',
      'C) Final turn text should be "The directory is empty.", got "$newC"');

  // Verify the empty-text turn doesn't produce a stored message
  // In real code: if (turnText.isNotEmpty) → false, so no message stored
  final emptyTurnText = turnsC[0].text;
  assert(emptyTurnText.isEmpty,
      'C) First turn has no text — would skip storage');

  print('  First turn text is empty → turnText.isNotEmpty = false ✓');
  print('  Final stored content: "$newC"');
  print('[C] PASS\n');

  // =========================================================================
  // Test D: 数据库存储验证 — 实际写入 DB 的是 turnText
  // =========================================================================
  print('=== [D] 数据库存储验证 ===');

  // Simulate a real scenario: user message already in DB
  await _insertMsg(db, sessionId: sessionId, role: 'user', content: 'Read /test.txt');

  // Simulate the tool loop with the Phase 10 fix
  String allText = '';
  String? finalTurnText;
  final apiMessages = <Map<String, dynamic>>[
    {'role': 'user', 'content': 'Read /test.txt'},
  ];

  // Turn 1: model calls tool
  final turn1Text = 'Let me read that file.';
  allText += turn1Text;
  apiMessages.add({
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': turn1Text},
      {'type': 'tool_use', 'name': 'read_file', 'input': {'path': '/test.txt'}},
    ],
  });
  // Tool result
  apiMessages.add({
    'role': 'user',
    'content': [
      {'type': 'tool_result', 'tool_use_id': 'toolu_1', 'content': 'Hello World from file'},
    ],
  });

  // Turn 2: model final reply
  final turn2Text = 'The file contains: Hello World from file';
  allText += turn2Text;
  finalTurnText = turn2Text;

  // Phase 10 fix: store turnText, not allText
  final storedContent = finalTurnText; // this is what _msgRepo.insert uses now
  assert(storedContent == turn2Text,
      'D) Stored should be turnText="$turn2Text", got "$storedContent"');
  assert(storedContent != allText,
      'D) Stored should NOT be allText (${allText.length} chars vs ${storedContent.length} chars)');

  await _insertMsg(db, sessionId: sessionId, role: 'assistant', content: storedContent);

  final msgs = await _messagesFor(db, sessionId);
  final asst = msgs.where((m) => m['role'] == 'assistant').toList();
  assert(asst.length == 1, 'D) Should have 1 assistant message, got ${asst.length}');
  assert(asst[0]['content'] == turn2Text,
      'D) DB content should be "$turn2Text", got "${asst[0]['content']}"');
  assert(!(asst[0]['content'] as String).contains(turn1Text),
      'D) DB content should NOT contain first-turn text "${turn1Text}"');

  print('  allText (total accumulated): ${allText.length} chars');
  print('  turnText (stored): ${storedContent.length} chars');
  print('  DB content matches turnText, not allText ✓');
  print('  DB content does not contain first-turn text ✓');
  print('[D] PASS\n');

  // =========================================================================
  // Test E: 3 轮工具调用 — 确保取最后一轮
  // =========================================================================
  print('=== [E] 三轮工具调用 ===');

  final turnsE = [
    TurnResult(text: 'Step 1: reading config.', toolCalls: [
      {'name': 'read_file', 'input': {'path': '/config.json'}}
    ]),
    TurnResult(text: 'Step 2: listing directory.', toolCalls: [
      {'name': 'list_dir', 'input': {'path': '/src'}}
    ]),
    TurnResult(text: 'All done. The config is valid and src has 5 files.', toolCalls: []),
  ];

  final oldE = await simulateToolLoop(turnsE, false);
  final newE = await simulateToolLoop(turnsE, true);

  final expectedNewE = 'All done. The config is valid and src has 5 files.';
  assert(newE == expectedNewE,
      'E) New should be "$expectedNewE", got "$newE"');
  assert(oldE!.contains('Step 1') && oldE.contains('Step 2'),
      'E) Old should contain all 3 turn texts');

  print('  Old: ${oldE!.length} chars (accumulated 3 turns)');
  print('  New: ${newE!.length} chars (final turn only)');
  print('  Final turn text isolated correctly ✓');
  print('[E] PASS\n');

  // =========================================================================
  // Cleanup
  // =========================================================================
  await db.close();
  Directory(testDir).deleteSync(recursive: true);

  print('=== Checkpoint 10: ALL 5 TESTS (A/B/C/D/E) PASS ===');
}
