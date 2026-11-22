// 组成员仓储（change `agent-group-chat` 任务 1.4 / design D17、D20）。
//
// 所有成员身份行为都在真 SQLite 上证明（唯一约束 / 软删 / 同名重建 / 级联删除）。
// 应用层在写入前给出**可归因**错误（点名冲突的名字），不把 SQLite 的唯一约束错误
// 直接甩给界面。
import 'package:sqflite_common/sqflite.dart' show DatabaseException;
import 'package:uuid/uuid.dart';

import '../models/group_member.dart';
import 'database_service.dart';

/// 成员名冲突 / 空名：可归因，且**不做任何改动**（不静默改名、不留半行数据）。
class GroupMemberNameConflictException implements Exception {
  const GroupMemberNameConflictException({
    required this.groupSessionId,
    required this.name,
    required this.reason,
  });

  final String groupSessionId;
  final String name;

  /// `empty` / `duplicate`。
  final String reason;

  @override
  String toString() => reason == 'empty'
      ? '成员名不能为空（组 $groupSessionId）：拒绝加入，成员表没有改动'
      : '组 $groupSessionId 里已有未移除的成员 "$name"：拒绝重名，成员表没有改动';
}

/// 成员不存在：可归因（带成员 id）。
class GroupMemberNotFoundException implements Exception {
  const GroupMemberNotFoundException(this.memberId);

  final String memberId;

  @override
  String toString() => '组成员 "$memberId" 不存在（或不属于该组）：拒绝操作';
}

class GroupMemberRepository {
  static const _uuid = Uuid();

  /// 加入一个成员。名字必须非空且在**未移除**成员之间唯一。
  Future<GroupMember> add({
    required String groupId,
    required String name,
    required String templateName,
    String? overridesJson,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw GroupMemberNameConflictException(
        groupSessionId: groupId,
        name: name,
        reason: 'empty',
      );
    }
    final existing = await findActiveByName(groupId, trimmed);
    if (existing != null) {
      throw GroupMemberNameConflictException(
        groupSessionId: groupId,
        name: trimmed,
        reason: 'duplicate',
      );
    }
    final db = await DatabaseService.database;
    final member = GroupMember(
      id: _uuid.v4(),
      groupSessionId: groupId,
      name: trimmed,
      templateName: templateName,
      overridesJson: overridesJson,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await db.insert('group_members', member.toRow());
    } on DatabaseException catch (e) {
      // 应用层查过一次，但两个并发请求仍可能同时通过：唯一索引是最后一道守卫，
      // 撞上时同样给出可归因错误（不把 SQL 错误甩给界面）。
      if ('$e'.toLowerCase().contains('unique')) {
        throw GroupMemberNameConflictException(
          groupSessionId: groupId,
          name: trimmed,
          reason: 'duplicate',
        );
      }
      rethrow;
    }
    return member;
  }

  /// 组内全部成员（**含已移除**，按加入时间升序）：已移除成员也有历史行要归属。
  Future<List<GroupMember>> listByGroup(String groupId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'group_members',
      where: 'group_session_id = ?',
      whereArgs: [groupId],
      orderBy: 'created_at ASC, rowid ASC',
    );
    return rows.map(GroupMember.fromRow).toList();
  }

  Future<GroupMember?> get(String memberId) async {
    final db = await DatabaseService.database;
    final rows = await db.query('group_members',
        where: 'id = ?', whereArgs: [memberId], limit: 1);
    if (rows.isEmpty) return null;
    return GroupMember.fromRow(rows.first);
  }

  /// 组内按名字找**未移除**成员（唯一性判据的唯一实现）。
  Future<GroupMember?> findActiveByName(String groupId, String name) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'group_members',
      where: 'group_session_id = ? AND name = ? AND removed_at IS NULL',
      whereArgs: [groupId, name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return GroupMember.fromRow(rows.first);
  }

  Future<int> countByGroup(String groupId) async {
    final db = await DatabaseService.database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM group_members WHERE group_session_id = ?',
        [groupId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 原地更新成员（**id 不变**）：显示名 / 模板 / 覆盖层。
  ///
  /// 改名仍要过唯一性判据；覆盖层写 NULL 用 [clearOverrides]。
  Future<GroupMember> update(
    String memberId, {
    String? name,
    String? templateName,
    String? overridesJson,
    bool clearOverrides = false,
  }) async {
    final existing = await get(memberId);
    if (existing == null) throw GroupMemberNotFoundException(memberId);
    var newName = existing.name;
    if (name != null) {
      newName = name.trim();
      if (newName.isEmpty) {
        throw GroupMemberNameConflictException(
          groupSessionId: existing.groupSessionId,
          name: name,
          reason: 'empty',
        );
      }
      if (newName != existing.name) {
        final clash =
            await findActiveByName(existing.groupSessionId, newName);
        if (clash != null && clash.id != memberId) {
          throw GroupMemberNameConflictException(
            groupSessionId: existing.groupSessionId,
            name: newName,
            reason: 'duplicate',
          );
        }
      }
    }
    final updated = existing.copyWith(
      name: newName,
      templateName: templateName,
      overridesJson: overridesJson,
      clearOverrides: clearOverrides,
    );
    final db = await DatabaseService.database;
    await db.update(
      'group_members',
      {
        'name': updated.name,
        'template_name': updated.templateName,
        'overrides_json': updated.overridesJson,
      },
      where: 'id = ?',
      whereArgs: [memberId],
    );
    return updated;
  }

  /// 软删：写 `removed_at`，行与历史一律保留（同名重建因此是新 id）。
  Future<void> softRemove(String memberId) async {
    final existing = await get(memberId);
    if (existing == null) throw GroupMemberNotFoundException(memberId);
    if (existing.isRemoved) return;
    final db = await DatabaseService.database;
    await db.update(
      'group_members',
      {'removed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [memberId],
    );
  }
}
