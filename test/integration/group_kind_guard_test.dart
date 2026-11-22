// kind 分派守卫（change `agent-group-chat` 任务 7.5 / design D16）。
//
// 组会话出现在顶层列表 ⇒ 三条现状入口都会把它当单会话（启动恢复 / agent.send /
// session.switchTemplate）。任何一条命中，`Agent.restore()` 就会把组原文（含他人
// private 行）全量喂给模型 —— 这就是投影之外的第二条出口。五条用例逐条堵。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';


import 'helpers/group_core_harness.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

void main() {
  late GroupCoreHarness harness;
  final realDirBefore = GroupCoreHarness.realUserDirFingerprint();

  setUp(() async {
    harness = await GroupCoreHarness.start();
  });

  tearDown(() async {
    await harness.stop();
  });

  test('① session.list 同时返回组会话与单会话，各带自己的 kind', () async {
    final group = await harness.createGroup(title: '组一');
    final groupId = (group['result'] as Map)['group']['id'] as String;
    final single = await harness.ws.request('session.create', {});
    final singleId = (single['result'] as Map)['session']['id'] as String;

    final list = await harness.ws.request('session.list');
    final sessions = (list['result'] as Map)['sessions'] as List;
    _obs('session.list', sessions.map((s) => '${s['title']}:${s['kind']}').toList());
    expect(sessions.length, 2);
    final groupRow = sessions.singleWhere((s) => s['id'] == groupId);
    final singleRow = sessions.singleWhere((s) => s['id'] == singleId);
    expect(groupRow['kind'], 'group');
    expect(singleRow['kind'], 'single');
    expect(groupRow.containsKey('overrides'), isTrue);
    expect(groupRow['overrides'], isNull);
  });

  test('② 单会话入口不为组会话建 Agent（启动恢复/列表不建实例）', () async {
    final group = await harness.createGroup(title: '组二');
    final groupId = (group['result'] as Map)['group']['id'] as String;
    // ignore: avoid_print
    print('[OBS] 建组后的实例句柄=${harness.core.agents.handles}');
    expect(harness.core.agents.handles, isNot(contains(groupId)),
        reason: '组会话不建单 Agent 实例');

    // 恢复路径（Flutter 的 _loadSessions 走 ensure 同一个决策点）
    final before = harness.core.agents.handles.length;
    // `session.list` 不触发 ensure；这里再显式核对一次"没有为组建的实例"。
    await harness.ws.request('session.list');
    expect(harness.core.agents.handles.length, before);
    expect(harness.core.agents.handles.any((h) => h.startsWith('$groupId::')),
        isFalse,
        reason: '仅列组会话不创建成员实例');
  });

  test('③ agent.send 对组会话可归因拒绝（指明走 group.send）', () async {
    final group = await harness.createGroup(title: '组三');
    final groupId = (group['result'] as Map)['group']['id'] as String;
    final response = await harness.ws.request('agent.send', {
      'sessionId': groupId,
      'text': '谁来说一句',
    });
    _obs('agent.send 组会话错误', response['error']);
    expect(response['error'], isNotNull);
    final message = '${(response['error'] as Map)['message']}';
    expect(message, contains(groupId));
    expect(message, contains('组会话'));
    expect(message, contains('group.send'));
    // 没有发出任何模型请求，也没有任何消息行。
    expect(harness.sidecar.sendHandles, isEmpty);
    final rows = await harness.core.messageRepo.queryBySession(groupId);
    expect(rows, isEmpty);
  });

  test('④ session.switchTemplate 对组会话拒绝，agent_type 与成员配置不变', () async {
    final group = await harness.createGroup(title: '组四');
    final groupId = (group['result'] as Map)['group']['id'] as String;
    final before = await harness.core.sessionRepo.get(groupId);
    final response = await harness.ws.request('session.switchTemplate', {
      'sessionId': groupId,
      'templateName': 'general',
    });
    _obs('switchTemplate 组会话错误', response['error']);
    expect(response['error'], isNotNull);
    final message = '${(response['error'] as Map)['message']}';
    expect(message, contains('组会话'));
    expect(message, contains('模板'));
    final after = await harness.core.sessionRepo.get(groupId);
    expect(after!.agentType, before!.agentType, reason: '组会话 agent_type 不变');
    expect(harness.core.agents.handles, isNot(contains(groupId)));
  });

  test('⑤ 任何单 Agent 请求的 messages 不含他人 private 行', () async {
    final group = await harness.createGroup(title: '组五');
    final groupId = (group['result'] as Map)['group']['id'] as String;
    final added = await harness.addMember(groupId, '甲');
    final memberId = (added['result'] as Map)['member']['id'] as String;
    final member = await harness.core.groups.memberRepo.get(memberId);
    // 种一条甲的私有行（带唯一标记）。
    await harness.core.messageRepo.insert(
      sessionId: groupId,
      role: 'assistant',
      content: '',
      thinkingJson:
          '[{"type":"thinking","thinking":"PRIVATE-ONLY-MARK","signature":"s"}]',
      author: memberId,
      visibility: 'private-to-author',
    );

    // 组路径发言：只有成员自己的请求，含自己的私有行（反证）。
    harness.sidecar.queueChunk('甲的回复');
    harness.sidecar.queueDone();
    await harness.ws.request('group.send', {
      'groupId': groupId,
      'speaker': memberId,
      'text': '甲说一句',
    });
    final memberRequest = harness.sidecar.lastMessagesJson ?? '';
    expect(memberRequest, contains('PRIVATE-ONLY-MARK'),
        reason: '反证：甲自己的请求里私有证据仍在');

    // 单 Agent 入口被拒：没有任何一次单 Agent 请求发出。
    final singleSend = await harness.ws.request('agent.send', {
      'sessionId': groupId,
      'text': '伪装成单会话',
    });
    expect(singleSend['error'], isNotNull);
    final groupHandleRequests = harness.sidecar.sendHandles
        .where((h) => h == groupId)
        .toList();
    // ignore: avoid_print
    print('[OBS] 单 Agent 入口请求=${singleSend['error']} '
        '以组 id 为句柄的请求=$groupHandleRequests '
        '成员句柄=${member?.handle}');
    expect(groupHandleRequests, isEmpty,
        reason: '没有任何请求用组 id 当单会话句柄（第二条出口被堵死）');
    final singleAgentMessages = harness.sidecar.sendHandles
        .where((h) => h == groupId)
        .toList();
    expect(singleAgentMessages, isEmpty);

    // 整条通道还活着；隔离仍然成立。
    final ping = await harness.ws.request('core.ping');
    expect((ping['result'] as Map)['ok'], isTrue);
    expect(GroupCoreHarness.realUserDirFingerprint(), realDirBefore,
        reason: '测试没有写用户真实 ~/.aliasagent（db/config/core.lock）');
    expect(Directory(harness.root.path).existsSync(), isTrue);
  });
}
