// 软删、历史归属与组级联删除（change `agent-group-chat` 任务 5.6 / 5.7 /
// design D17 / spec「组会话与成员」）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/group_member_repository.dart';

import 'group_harness.dart';

void main() {
  test('5.6 移除成员：行保留、removedAt 非空、组列表仍返回（带 removedAt）', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    final rowBefore = await harness.members.get(member.id);

    await harness.groups.removeMember(harness.group.id, member.id);

    final rowAfter = await harness.members.get(member.id);
    final describe = await harness.groups.describeMembers(harness.group.id);
    // ignore: avoid_print
    print('[OBS] 移除前=${rowBefore?.removedAt} 移除后=${rowAfter?.removedAt} '
        '列表项=$describe');

    expect(rowAfter, isNotNull, reason: '软删：行必须保留');
    expect(rowAfter!.removedAt, isNotNull);
    expect(describe.length, 1);
    expect(describe.single['id'], member.id);
    expect(describe.single['removedAt'], isNotNull,
        reason: 'group.list 必须返回已移除成员（历史行才有去处）');
    await harness.dispose();
  });

  test('5.6 上翻历史每条行都能按成员 id 归属（含已移除成员）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    harness.queueSimpleReply('甲的公开发言');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    await harness.groups.removeMember(harness.group.id, a.id);

    final rows = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final members = await harness.groups.describeMembers(harness.group.id);
    final knownIds = {for (final m in members) m['id']};
    final unattributed = [
      for (final row in rows)
        if (row.author != null && !knownIds.contains(row.author)) row.id,
    ];
    // ignore: avoid_print
    print('[OBS] 行=${rows.length} 成员=${members.length} '
        '归属不到的行=$unattributed');
    expect(rows, isNotEmpty);
    expect(unattributed, isEmpty,
        reason: '每条成员行都必须能归属到 group.list 里的成员（含已移除）');
    await harness.dispose();
  });

  test('5.6 移除后同名重建是新 id，新成员看不到旧成员的私有行', () async {
    final harness = await GroupHarness.create();
    final oldA = await harness.addMember('甲');
    // 旧甲做一轮工具：私有标记只应留在旧甲的 private 行里。
    harness.queueToolTurn(
      toolName: 'read_file',
      id: 'tool-old-a',
      input: const {'path': 'lib/old-a.dart'},
      thinking: '旧甲的私有思路 OLD-A-MARK-77',
      stubResult: '{"ok":true,"content":"旧甲的私有结果 OLD-A-MARK-77"}',
    );
    harness.queueFinal('旧甲的公开结论：lib/old-a.dart');
    await harness.groups
        .send(groupId: harness.group.id, memberId: oldA.id, text: '旧甲做点事');

    final oldPrivateRows = (await harness.support.messageRepo
            .queryBySession(harness.group.id))
        .where((r) => r.isPrivate && r.author == oldA.id)
        .toList();
    expect(oldPrivateRows, isNotEmpty);

    await harness.groups.removeMember(harness.group.id, oldA.id);
    final newA = await harness.addMember('甲');
    // ignore: avoid_print
    print('[OBS] 旧 id=${oldA.id} 新 id=${newA.id} 旧私有行=${oldPrivateRows.length}');
    expect(newA.id, isNot(oldA.id), reason: '同名重建是新身份');

    harness.queueSimpleReply('新甲的公开结论');
    await harness.groups
        .send(groupId: harness.group.id, memberId: newA.id, text: '新甲说一句');
    final sent = harness.support.sidecar.lastMessagesJson ?? '';
    // ignore: avoid_print
    print('[OBS] 新甲请求含旧私有标记=${sent.contains('OLD-A-MARK-77')}');
    expect(sent, isNot(contains('OLD-A-MARK-77')),
        reason: '新成员看不到旧成员的私有行');
    expect(sent, contains('甲 说：旧甲的公开结论'),
        reason: '但旧成员的公开结论仍以「甲 说：」出现在视图里（归属显示名）');
    await harness.dispose();
  });

  test('5.6 移除成员先取消并销毁其实例', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    expect(harness.agents.lookup(member.handle), isNotNull);
    await harness.groups.removeMember(harness.group.id, member.id);
    // ignore: avoid_print
    print('[OBS] 移除后实例=${harness.agents.lookup(member.handle)} '
        'dispose=${harness.support.sidecar.disposeContextCalls}');
    expect(harness.agents.lookup(member.handle), isNull);
    expect(harness.support.sidecar.disposeContextCalls, contains(member.handle));
    await harness.dispose();
  });

  test('5.7 删除组级联：成员/消息/摘要行均为 0（真实 COUNT）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueSimpleReply('甲的发言');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    harness.queueSimpleReply('乙的发言');
    await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙再说');

    // 直接写一条摘要行（模拟压缩产物），证明删除时也级联清掉。
    await harness.support.summaryNodeRepo.materialize(
      sessionId: harness.group.id,
      memberId: a.id,
      level: 1,
      startSeq: 1,
      endSeq: 2,
      nodeType: 'summary',
      summaryJson: '{"role":"user","content":[{"type":"text","text":"摘要"}]}',
      tokenCost: 3,
      summaryPromptVersion: 1,
      model: 'test-model',
      coveredMinSeq: 1,
      coveredMaxSeq: 2,
    );

    final other = await harness.groups.createGroup(title: '另一个组');
    final db = await DatabaseService.database;
    Future<int> count(String table, String where, List<Object?> args) async {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table WHERE $where', args);
      return (rows.first['c'] as int?) ?? 0;
    }

    final before = {
      'members': await count('group_members', 'group_session_id = ?', [harness.group.id]),
      'messages': await count('messages', 'session_id = ?', [harness.group.id]),
      'summaries': await count('summary_nodes', 'session_id = ?', [harness.group.id]),
    };

    await harness.groups.deleteGroup(harness.group.id);

    final after = {
      'members': await count('group_members', 'group_session_id = ?', [harness.group.id]),
      'messages': await count('messages', 'session_id = ?', [harness.group.id]),
      'summaries': await count('summary_nodes', 'session_id = ?', [harness.group.id]),
    };
    final otherSessions = await count('sessions', 'id = ?', [other.id]);
    // ignore: avoid_print
    print('[OBS] 删除前=$before 删除后=$after 其它组仍在=$otherSessions');
    expect(before['members'], 2);
    expect(before['messages'], greaterThan(0));
    expect(before['summaries'], 1);
    expect(after, {'members': 0, 'messages': 0, 'summaries': 0},
        reason: '验收读真实 SQLite 行数，不只看外键声明');
    expect(otherSessions, 1, reason: '其它组不受影响');
    expect(harness.agents.lookup(a.handle), isNull);
    expect(harness.agents.lookup(b.handle), isNull);
    await harness.dispose();
  });

  test('5.6 组内重名成员被拒（可归因并点名）', () async {
    final harness = await GroupHarness.create();
    await harness.addMember('甲');
    Object? error;
    try {
      await harness.addMember('甲');
    } catch (e) {
      error = e;
    }
    // ignore: avoid_print
    print('[OBS] 重名错误=$error');
    expect(error, isA<GroupMemberNameConflictException>());
    expect('$error', contains('甲'));
    await harness.dispose();
  });
}
