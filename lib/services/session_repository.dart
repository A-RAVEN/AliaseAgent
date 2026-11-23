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
  ///
  /// [kind]：`single`（缺省，变更前的行为）或 `group`（组会话，单 Agent 入口一律
  /// 拒绝/路由，见 `agent-group-chat` D16）。[overridesJson]：会话级覆盖层文本
  /// （单会话用；成员覆盖层在成员行里）。
  ///
  /// [reactionsEnabled]：组的**自发反应开关**（change `group-reactive-mode` D1 / D8）。
  /// 省略 = `true`（**新建组默认开启**；传 `false` 才是安静态）。单会话行也写该值，
  /// 但它不改变单 Agent 的任何行为。
  ///
  /// [maxRounds]：组的**反应轮数上限**（change `group-reactive-mode` R.1 / D13）。
  /// 省略 / `null` = 用产品默认 [kDefaultMaxReactionRounds]（列写 NULL）。范围校验在
  /// `group.create` / `group.update` 的入口做（`-32602`），仓储只负责如实写入。
  Future<Session> create({
    String? title,
    String? agentType,
    String? parentSessionId,
    String kind = Session.kindSingle,
    String? overridesJson,
    bool reactionsEnabled = true,
    int? maxRounds,
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
      kind: kind,
      overridesJson: overridesJson,
      reactionsEnabled: reactionsEnabled,
      maxRounds: maxRounds,
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

  /// Updates the session title from the first user message if it's still a
  /// **默认标题**. Returns true if the title was updated.
  ///
  /// 缺省判据**按 kind 泛化**（change `group-reactive-mode` D2 / 任务 3.4）：
  /// 组会话的缺省标题是 `新组`（`GroupService.createGroup` 写的），单会话仍是
  /// `New Chat`。两边都同时认这两个串 —— 否则组的标题永远停在「新组」。
  /// 标题**不是**缺省值 = 用户已经命名过，不覆盖。
  Future<bool> updateTitleIfDefault(String id, String text) async {
    final session = await get(id);
    if (session == null) return false;
    final defaults = session.isGroup
        ? const {'新组', 'New Chat'}
        : const {'New Chat'};
    if (!defaults.contains(session.title)) return false;
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

  /// 写会话级覆盖层（`overrides_json`）。[json] 为 null = 清空覆盖层（写 NULL）。
  ///
  /// **不改模板**：模板注册表与配置文件都不知情（`agent-instance-overrides` 的
  /// 「覆盖层持久化且单会话可用」要求）。
  Future<void> updateOverrides(String id, String? json) async {
    final db = await DatabaseService.database;
    await db.update('sessions', {'overrides_json': json},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 原地更新组的**自发反应开关**（`sessions.reactions_enabled`，change
  /// `group-reactive-mode` D1 / D8 第 6 条；`group.update` 的唯一写入口）。
  ///
  /// 只做这一件事：不碰标题、模板、覆盖层，也不改 `updated_at`（它是组的持久属性，
  /// 不是"会话最近活动"）。是否允许在链运行中改由组服务判定（它拿得到链状态）。
  Future<void> updateReactionsEnabled(String id, bool enabled) async {
    final db = await DatabaseService.database;
    await db.update('sessions', {'reactions_enabled': enabled ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 原地更新组的**反应轮数上限**（`sessions.max_reaction_rounds`，change
  /// `group-reactive-mode` R.1 / D13；`group.update` 的写入口）。
  ///
  /// [maxRounds] 为 `null` = **恢复默认**（列写 NULL，链下次用
  /// [kDefaultMaxReactionRounds]）。与 `updateReactionsEnabled` 同口径：只写这一列，
  /// 不碰标题/模板/覆盖层/`updated_at`；范围与链运行中的判定在组服务 / RPC 层做。
  Future<void> updateMaxRounds(String id, int? maxRounds) async {
    final db = await DatabaseService.database;
    await db.update('sessions', {'max_reaction_rounds': maxRounds},
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