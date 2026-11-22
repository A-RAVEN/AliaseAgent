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
    List<String> attachments = const [],
    String? author,
    String visibility = Message.visibilityPublic,
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
      attachments: attachments,
      author: author,
      visibility: visibility,
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
      attachments: attachments,
      author: author,
      visibility: visibility,
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

  /// 按 `seq` 区间读**原始行**（成员视图的增量装配入口，change `agent-group-chat`
  /// 任务 4.2 / design D9）。
  ///
  /// 只读 `seq > afterSeq` 的那一段，**不**提供"整条会话"的形态：成员装配不允许
  /// 退化成 `queryBySession` 全量载入（那条路径有专门的红靶用例）。
  Future<List<Map<String, dynamic>>> queryRawAfterSeq(
      String sessionId, int afterSeq) async {
    final db = await DatabaseService.database;
    return db.query(
      'messages',
      where: 'session_id = ? AND seq > ?',
      whereArgs: [sessionId, afterSeq],
      orderBy: 'seq ASC',
    );
  }

  /// 按 `seq` 闭区间读原始行（被成员摘要覆盖的区间"需要时按需读"）。
  Future<List<Map<String, dynamic>>> queryRawInRange(
      String sessionId, int minSeq, int maxSeq) async {
    final db = await DatabaseService.database;
    return db.query(
      'messages',
      where: 'session_id = ? AND seq >= ? AND seq <= ?',
      whereArgs: [sessionId, minSeq, maxSeq],
      orderBy: 'seq ASC',
    );
  }
}