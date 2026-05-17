import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'database_service.dart';

class MessageRepository {
  static const _uuid = Uuid();

  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    int? tokenCount,
  }) async {
    final db = await DatabaseService.database;
    final msg = Message(
      id: _uuid.v4(),
      sessionId: sessionId,
      role: role,
      content: content,
      tokenCount: tokenCount,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert('messages', msg.toRow());
    return msg;
  }

  Future<List<Message>> queryBySession(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map(Message.fromRow).toList();
  }
}