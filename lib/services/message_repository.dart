import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'database_service.dart';

class MessageRepository {
  static const _uuid = Uuid();

  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    String? toolCallsJson,
    String? thinkingJson,
    int? tokenCount,
    int? outputTokenCount,
  }) async {
    final db = await DatabaseService.database;
    final msg = Message(
      id: _uuid.v4(),
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    // seq is the message's stable ordering key. Assign it from the SQLite
    // rowid (monotonic per insert, unique even under same-millisecond inserts)
    // so compaction tree spans are stable. Two-step: insert (seq NULL) then
    // set seq = rowid.
    final rowId = await db.insert('messages', msg.toRow());
    await db.update('messages', {'seq': rowId}, where: 'id = ?', whereArgs: [msg.id]);
    final inserted = Message(
      id: msg.id,
      seq: rowId,
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      createdAt: msg.createdAt,
    );
    return inserted;
  }

  Future<void> updateToolCalls(String id, String toolCallsJson) async {
    final db = await DatabaseService.database;
    await db.update(
      'messages',
      {'tool_calls': toolCallsJson},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Message>> queryBySession(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      // seq is the deterministic tiebreaker when created_at collides
      // (same-millisecond tool-loop inserts).
      orderBy: 'created_at ASC, seq ASC',
    );
    return rows.map(Message.fromRow).toList();
  }
}