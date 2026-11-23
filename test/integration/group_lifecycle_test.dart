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
    await harness.waitForChain();
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
    await harness.waitForChain();

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
    await harness.waitForChain();
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
    await harness.waitForChain();
    harness.queueSimpleReply('乙的发言');
    await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙再说');
    await harness.waitForChain();

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

  // ---------------------------------------------------------------------------
  // 自发反应开关的持久化（change `group-reactive-mode` 任务 0.2）
  // ---------------------------------------------------------------------------

  test('0.2 新建组默认开启（reactionsEnabled == true，库里 1）', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.groups.createGroup(title: '新组');
    final reread = await harness.support.sessionRepo.get(created.id);
    final rows = await (await DatabaseService.database)
        .query('sessions', where: 'id = ?', whereArgs: [created.id]);
    // ignore: avoid_print
    print('[OBS] 新建组 reactionsEnabled=${created.reactionsEnabled} '
        '读回=${reread?.reactionsEnabled} 行=${rows.first['reactions_enabled']}');
    expect(created.reactionsEnabled, isTrue);
    expect(reread!.reactionsEnabled, isTrue);
    expect(rows.first['reactions_enabled'], 1);
    await harness.dispose();
  });

  test('0.2 create(reactionsEnabled: false) 落 0 且读回 false', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.support.sessionRepo.create(
      title: '安静组',
      kind: 'group',
      reactionsEnabled: false,
    );
    final reread = await harness.support.sessionRepo.get(created.id);
    final rows = await (await DatabaseService.database)
        .query('sessions', where: 'id = ?', whereArgs: [created.id]);
    // ignore: avoid_print
    print('[OBS] 显式关闭 reactionsEnabled=${created.reactionsEnabled} '
        '读回=${reread?.reactionsEnabled} 行=${rows.first['reactions_enabled']}');
    expect(created.reactionsEnabled, isFalse);
    expect(reread!.reactionsEnabled, isFalse);
    expect(rows.first['reactions_enabled'], 0);
    await harness.dispose();
  });

  test('0.2 updateReactionsEnabled 持久化（关闭 → 重读仍 false；再打开 → true）', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.groups.createGroup(title: '可切组');

    await harness.support.sessionRepo
        .updateReactionsEnabled(created.id, false);
    final off = await harness.support.sessionRepo.get(created.id);
    final offRow = (await (await DatabaseService.database)
            .query('sessions', where: 'id = ?', whereArgs: [created.id]))
        .first;
    // ignore: avoid_print
    print('[OBS] 关闭后 读回=${off?.reactionsEnabled} '
        '行=${offRow['reactions_enabled']}');
    expect(off!.reactionsEnabled, isFalse);
    expect(offRow['reactions_enabled'], 0);

    await harness.support.sessionRepo.updateReactionsEnabled(created.id, true);
    final on = await harness.support.sessionRepo.get(created.id);
    // ignore: avoid_print
    print('[OBS] 再打开后 读回=${on?.reactionsEnabled}');
    expect(on!.reactionsEnabled, isTrue);
    await harness.dispose();
  });

  // ---------------------------------------------------------------------------
  // 反应轮数上限的持久化（change `group-reactive-mode` 任务 R.1 / design D13）
  // ---------------------------------------------------------------------------

  test('R.1 新建组 maxRounds 为 null（库列 NULL = 用产品默认）', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.groups.createGroup(title: '新组');
    final reread = await harness.support.sessionRepo.get(created.id);
    final row = (await (await DatabaseService.database)
            .query('sessions', where: 'id = ?', whereArgs: [created.id]))
        .first;
    // ignore: avoid_print
    print('[OBS] 新建组 maxRounds=${created.maxRounds} '
        '读回=${reread?.maxRounds} 行=${row['max_reaction_rounds']}');
    expect(created.maxRounds, isNull);
    expect(reread!.maxRounds, isNull);
    expect(row['max_reaction_rounds'], isNull);
    await harness.dispose();
  });

  test('R.1 create(maxRounds: 6) 落 6 且读回 6', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.support.sessionRepo.create(
      title: '限轮数组',
      kind: 'group',
      maxRounds: 6,
    );
    final reread = await harness.support.sessionRepo.get(created.id);
    final row = (await (await DatabaseService.database)
            .query('sessions', where: 'id = ?', whereArgs: [created.id]))
        .first;
    // ignore: avoid_print
    print('[OBS] create(maxRounds:6) 读回=${reread?.maxRounds} '
        '行=${row['max_reaction_rounds']}');
    expect(created.maxRounds, 6);
    expect(reread!.maxRounds, 6);
    expect(row['max_reaction_rounds'], 6);
    await harness.dispose();
  });

  test('R.1 updateMaxRounds 持久化，显式 null 恢复默认（库列 NULL）', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.groups.createGroup(title: '可改上限组');

    await harness.support.sessionRepo.updateMaxRounds(created.id, 6);
    var reread = await harness.support.sessionRepo.get(created.id);
    var row = (await (await DatabaseService.database)
            .query('sessions', where: 'id = ?', whereArgs: [created.id]))
        .first;
    // ignore: avoid_print
    print('[OBS] 设 6 后 读回=${reread?.maxRounds} 行=${row['max_reaction_rounds']}');
    expect(reread!.maxRounds, 6);
    expect(row['max_reaction_rounds'], 6);

    await harness.support.sessionRepo.updateMaxRounds(created.id, null);
    reread = await harness.support.sessionRepo.get(created.id);
    row = (await (await DatabaseService.database)
            .query('sessions', where: 'id = ?', whereArgs: [created.id]))
        .first;
    // ignore: avoid_print
    print('[OBS] 显式 null 后 读回=${reread?.maxRounds} '
        '行=${row['max_reaction_rounds']}');
    expect(reread!.maxRounds, isNull, reason: '显式 null = 恢复默认');
    expect(row['max_reaction_rounds'], isNull);
    await harness.dispose();
  });
}
