import 'package:uuid/uuid.dart';

import '../models/session.dart';
import 'database_service.dart';

class SessionRepository {
  static const _uuid = Uuid();

  Future<Session> create({String? title, String? agentType}) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = Session(
      id: _uuid.v4(),
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('sessions', session.toRow());
    return session;
  }

  Future<Session?> get(String id) async {
    final db = await DatabaseService.database;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Session.fromRow(rows.first);
  }

  Future<List<Session>> list() async {
    final db = await DatabaseService.database;
    final rows = await db.query('sessions', orderBy: 'updated_at DESC');
    return rows.map(Session.fromRow).toList();
  }

  Future<void> delete(String id) async {
    final db = await DatabaseService.database;
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateTitle(String id, String title) async {
    final db = await DatabaseService.database;
    await db.update('sessions', {'title': title},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> touch(String id) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('sessions', {'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
  }
}