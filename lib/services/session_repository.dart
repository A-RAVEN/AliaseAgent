import 'package:uuid/uuid.dart';

import '../models/session.dart';
import 'database_service.dart';

/// 把会话改到另一个 Agent 模板时，**没有更新到唯一既有行**。
///
/// 三种情况都会到这里：会话不存在 / 已被删除（0 行）、主键重复导致多行（>1 行），
/// 以及写入之后重新读取拿不到新值。调用方必须据此失败，不得创建新实例。
class SessionAgentTypeUpdateException implements Exception {
  final String sessionId;
  final String agentType;
  final int updatedRows;
  final String message;

  const SessionAgentTypeUpdateException({
    required this.sessionId,
    required this.agentType,
    required this.updatedRows,
    required this.message,
  });

  @override
  String toString() => message;
}

class SessionRepository {
  static const _uuid = Uuid();

  /// 建一条会话记录。普通顶层会话不传 [parentSessionId]（存 NULL）；一次性子
  /// Agent 的运行记录传入父会话 id。该字段只影响记录归属，不改写父会话。
  Future<Session> create({
    String? title,
    String? agentType,
    String? parentSessionId,
  }) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = Session(
      id: _uuid.v4(),
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      parentSessionId: parentSessionId,
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

  /// 普通会话列表：只返回顶层会话（`parent_session_id IS NULL`），按最近更新
  /// 倒序。一次性子 Agent 的运行记录不在侧栏出现，启动恢复也因此不会重建它们；
  /// 它们只能通过 [listChildren] 按父会话 id 读取。
  Future<List<Session>> list() async {
    final db = await DatabaseService.database;
    final rows = await db.query('sessions',
        where: 'parent_session_id IS NULL', orderBy: 'updated_at DESC');
    return rows.map(Session.fromRow).toList();
  }

  /// 按父会话 id 读取子运行记录（只读入口，按最近更新倒序）。第一版没有查看
  /// 子记录详情的界面，这个入口供测试与后续诊断使用。
  Future<List<Session>> listChildren(String parentSessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query('sessions',
        where: 'parent_session_id = ?',
        whereArgs: [parentSessionId],
        orderBy: 'updated_at DESC');
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

  /// Updates the session title from the first user message if it's still the
  /// default "New Chat". Returns true if the title was updated.
  Future<bool> updateTitleIfDefault(String id, String text) async {
    final session = await get(id);
    if (session == null || session.title != 'New Chat') return false;
    final title = text.length > 30 ? '${text.substring(0, 30)}...' : text;
    await updateTitle(id, title);
    return true;
  }

  Future<void> touch(String id) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update('sessions', {'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 把会话的 `agent_type` 改成 [agentType]，**重新读取该行**并返回。
  ///
  /// 必须确认实际更新了**恰好一行**：0 行（会话不存在或已被删除）或多行（主键
  /// 重复）都显式抛 [SessionAgentTypeUpdateException]。写入后重新读取仍是旧值、
  /// 或者读不到该行，同样算失败 —— 调用方据此不创建新实例，也不假装切换成功。
  Future<Session> updateAgentType(String id, String agentType) async {
    final db = await DatabaseService.database;
    final updated = await db.update('sessions', {'agent_type': agentType},
        where: 'id = ?', whereArgs: [id]);
    if (updated != 1) {
      throw SessionAgentTypeUpdateException(
        sessionId: id,
        agentType: agentType,
        updatedRows: updated,
        message: '会话 "$id" 的 agent_type 没有更新到唯一既有行'
            '（实际更新 $updated 行，期望 1 行）：不会创建新的 Agent 实例。',
      );
    }
    final reread = await get(id);
    if (reread == null) {
      throw SessionAgentTypeUpdateException(
        sessionId: id,
        agentType: agentType,
        updatedRows: updated,
        message: '会话 "$id" 写入 agent_type 后重新读取不到该行'
            '（可能已被删除）：不会创建新的 Agent 实例。',
      );
    }
    if (reread.agentType != agentType) {
      throw SessionAgentTypeUpdateException(
        sessionId: id,
        agentType: agentType,
        updatedRows: updated,
        message: '会话 "$id" 写入后重新读取的 agent_type 仍是 '
            '"${reread.agentType}"，不是 "$agentType"：不会创建新的 Agent 实例。',
      );
    }
    return reread;
  }
}