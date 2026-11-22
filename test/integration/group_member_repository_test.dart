// `group_members` 表与仓储（change `agent-group-chat` 任务 1.4 / design D14、D17、D20）。
//
// 仓储类断言必须落在**真 SQLite** 上（设计 D20）：唯一约束、软删、同名重建新 id、
// 级联删除这些行为都是数据库层的，用假仓储证明不了。
//
// 隔离：临时库 `openAt` + 临时 config/attachments/lock（见 `group_test_support.dart`），
// 绝不写用户真实 `~/.aliasagent`。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_member_repository.dart';

import 'group_test_support.dart';

void main() {
  late GroupTestSupport support;
  late GroupMemberRepository members;

  setUp(() async {
    support = await GroupTestSupport.create(prefix: 'group_member_test_');
    members = GroupMemberRepository();
  });

  tearDown(() async {
    await support.dispose();
  });

  Future<String> newGroup() async {
    final session = await support.sessionRepo.create(title: '组', kind: 'group');
    return session.id;
  }

  group('group_members 仓储', () {
    test('未移除成员之间重名被拒（应用层可归因 + 行数不变）', () async {
      final groupId = await newGroup();
      await members.add(
          groupId: groupId, name: '甲', templateName: 'general');
      final before = await members.countByGroup(groupId);

      Object? error;
      try {
        await members.add(
            groupId: groupId, name: '甲', templateName: 'general');
      } catch (e) {
        error = e;
      }
      final after = await members.countByGroup(groupId);
      // ignore: avoid_print
      print('[OBS] 重名错误=$error 行数 before=$before after=$after');

      expect(error, isA<GroupMemberNameConflictException>());
      expect('$error', contains('甲'), reason: '错误里必须点名冲突的名字');
      expect(after, before, reason: '重名被拒后成员表不得发生任何改动');

      // 空名同样被拒（不许静默改名成"成员1"）。
      Object? emptyError;
      try {
        await members.add(
            groupId: groupId, name: '   ', templateName: 'general');
      } catch (e) {
        emptyError = e;
      }
      // ignore: avoid_print
      print('[OBS] 空名错误=$emptyError');
      expect(emptyError, isA<GroupMemberNameConflictException>());
    });

    test('移除是软删：行保留、removed_at 非空、列表仍返回', () async {
      final groupId = await newGroup();
      final member = await members.add(
          groupId: groupId, name: '乙', templateName: 'general');

      await members.softRemove(member.id);
      final rows = await members.listByGroup(groupId);
      // ignore: avoid_print
      print('[OBS] 软删后 rows=${rows.map((m) => "${m.id}:${m.name}:${m.removedAt}")}');

      expect(rows.map((m) => m.id), [member.id], reason: '软删的行必须保留');
      final row = rows.single;
      expect(row.removedAt, isNotNull);
      expect(row.isRemoved, isTrue);
      expect(row.name, '乙');
      expect(row.groupSessionId, groupId);
      expect(row.templateName, 'general');
    });

    test('移除后同名重建是新 id（旧 id 不变、两行共存）', () async {
      final groupId = await newGroup();
      final old = await members.add(
          groupId: groupId, name: '甲', templateName: 'general');
      await members.softRemove(old.id);

      final fresh = await members.add(
          groupId: groupId, name: '甲', templateName: 'general');
      final rows = await members.listByGroup(groupId);
      // ignore: avoid_print
      print('[OBS] 同名重建 old=${old.id} fresh=${fresh.id} '
          'rows=${rows.map((m) => "${m.id}:${m.name}:removed=${m.removedAt}")}');

      expect(fresh.id, isNot(old.id));
      expect(rows.length, 2);
      final oldRow = rows.firstWhere((m) => m.id == old.id);
      expect(oldRow.removedAt, isNotNull);
      expect(oldRow.id, old.id, reason: '旧行的成员 id 不变');
    });

    test('删除组会话级联删除成员行（真实行数）', () async {
      final groupId = await newGroup();
      final otherGroup = await newGroup();
      await members.add(groupId: groupId, name: '甲', templateName: 'general');
      await members.add(groupId: groupId, name: '乙', templateName: 'general');
      await members.add(
          groupId: otherGroup, name: '丙', templateName: 'general');

      await support.sessionRepo.delete(groupId);

      final remaining = await members.countByGroup(groupId);
      final otherRemaining = await members.countByGroup(otherGroup);
      // ignore: avoid_print
      print('[OBS] 级联后 group=$remaining other=$otherRemaining');
      expect(remaining, 0, reason: '删除组会话时成员行必须随外键级联删除');
      expect(otherRemaining, 1, reason: '其它组不受影响');
    });
  });
}
