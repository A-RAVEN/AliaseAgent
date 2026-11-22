// 调度 v1：用户点名 + 组级单运行门 + 两个前置门（change `agent-group-chat` 任务 5.4 /
// design D5 / spec「成员发言调度：用户点名」）。
//
// 六条用例：
//   ① 点名谁就只有谁发言；
//   ② 甲运行中点名乙 ⇒ 可归因 busy（**组级**门：不是只查乙的忙闲）；
//   ③ 未点名 ⇒ 可归因拒绝；
//   ④ 不带文本且视图为空 ⇒ 可归因错误（绝不发 messages: []）；
//   ⑤ 不带文本且最后可见项是本人 assistant ⇒ 可归因错误（不退化成 prefill）；
//   ⑥ 不带文本但最后可见项是用户消息 ⇒ 正常发言且不写空用户行。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_service.dart';

import 'group_harness.dart';

void main() {
  test('① 点名谁就只有谁发言', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueSimpleReply('甲说过：已改完 lib/a.dart');

    final outcome = await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    final rows = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final byAuthor = <String?, int>{};
    for (final row in rows) {
      byAuthor[row.author] = (byAuthor[row.author] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('[OBS] status=${outcome.status} 行数=${rows.length} 作者分布=$byAuthor');

    expect(outcome.status, 'completed');
    expect(rows.where((r) => r.author == b.id), isEmpty,
        reason: '乙不产生任何消息行');
    expect(rows.any((r) => r.author == a.id && !r.isPrivate), isTrue,
        reason: '甲必须有公开回复行');
    await harness.dispose();
  });

  test('② 甲运行中点名乙 ⇒ 可归因 busy（组级单运行门）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueSimpleReply('甲的回复');
    harness.support.sidecar.gateNextSend();

    final futureA = harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲开始');
    // 等甲的请求真的进了 sidecar（在发送门里挂着）。
    while (harness.support.sidecar.sendHandles.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final outcomeB = await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙插一句');
    // ignore: avoid_print
    print('[OBS] 乙的结果 status=${outcomeB.status} error=${outcomeB.error}');
    expect(outcomeB.isBusy, isTrue,
        reason: '组内已有成员在跑时，点名任何成员都必须 busy');
    expect('${outcomeB.error}', contains('已有成员在运行'));

    final rowsDuring = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    // ignore: avoid_print
    print('[OBS] busy 期间原文行数=${rowsDuring.length} '
        '含乙=${rowsDuring.any((r) => r.author == b.id)}');
    expect(rowsDuring.any((r) => r.author == b.id), isFalse,
        reason: 'busy 的那次发送没有产生任何消息（不排队、不静默）');

    harness.support.sidecar.releaseGate();
    final outcomeA = await futureA;
    expect(outcomeA.status, 'completed');
    await harness.dispose();
  });

  test('③ 未点名（speaker 为空）⇒ 可归因拒绝，库中不新增消息', () async {
    final harness = await GroupHarness.create();
    await harness.addMember('甲');
    final before = (await harness.support.messageRepo
            .queryBySession(harness.group.id))
        .length;
    Object? error;
    try {
      await harness.groups
          .send(groupId: harness.group.id, memberId: null, text: '谁来说');
    } catch (e) {
      error = e;
    }
    final after = (await harness.support.messageRepo
            .queryBySession(harness.group.id))
        .length;
    // ignore: avoid_print
    print('[OBS] 未点名错误=$error 行数 before=$before after=$after');
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'no_speaker');
    expect('$error', contains('发言者'));
    expect(after, before, reason: '被拒的发送不得写入任何消息');
    await harness.dispose();
  });

  test('④ 不带文本且视图为空 ⇒ 可归因错误（不发 messages: []）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    Object? error;
    try {
      await harness.groups.send(groupId: harness.group.id, memberId: a.id);
    } catch (e) {
      error = e;
    }
    // ignore: avoid_print
    print('[OBS] 空视图错误=$error');
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'empty_view');
    expect('$error', contains('视图为空'));
    expect(harness.support.sidecar.sendHandles, isEmpty,
        reason: '被前置门挡住时一次模型请求都不该发出');
    await harness.dispose();
  });

  test('⑤ 不带文本且最后可见项是本人 assistant ⇒ 可归因错误（不许 prefill）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    harness.queueSimpleReply('甲的第一句');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先发言');

    final sendsBefore = harness.support.sidecar.sendHandles.length;
    Object? error;
    try {
      await harness.groups.send(groupId: harness.group.id, memberId: a.id);
    } catch (e) {
      error = e;
    }
    // ignore: avoid_print
    print('[OBS] prefill 错误=$error 新增请求='
        '${harness.support.sidecar.sendHandles.length - sendsBefore}');
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'prefill');
    expect('$error', contains('本人'));
    expect(harness.support.sidecar.sendHandles.length, sendsBefore,
        reason: 'prefill 退化请求必须被挡住，不发出去');
    await harness.dispose();
  });

  test('⑥ 不带文本但最后可见项是用户消息 ⇒ 正常发言且不写空用户行', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    // 用户消息（author 为空、public）先落库，成为"最后一条可见项"。
    await harness.support.messageRepo.insert(
      sessionId: harness.group.id,
      role: 'user',
      content: '用户说了：甲你看一下 lib/a.dart',
    );
    final usersBefore = (await harness.support.messageRepo
            .queryBySession(harness.group.id))
        .where((r) => r.role == 'user')
        .length;

    harness.queueSimpleReply('甲看过 lib/a.dart 了');
    final outcome = await harness.groups
        .send(groupId: harness.group.id, memberId: a.id);
    final rows = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final usersAfter = rows.where((r) => r.role == 'user').length;
    // ignore: avoid_print
    print('[OBS] status=${outcome.status} 用户行 before=$usersBefore '
        'after=$usersAfter 空内容用户行='
        '${rows.where((r) => r.role == 'user' && r.content.trim().isEmpty).length}');

    expect(outcome.status, 'completed');
    expect(usersAfter, usersBefore, reason: '不带文本时不写空用户行');
    expect(rows.any((r) => r.role == 'user' && r.content.trim().isEmpty), isFalse);
    await harness.dispose();
  });
}
