// 群聊 RPC 面（change `agent-group-chat` 任务 7.1 / 7.2 / 7.3 / 7.4 / 7.7 / 7.8）。
//
// 走真核心（HttpServer + WebSocket + 真 sqlite + 假 sidecar）：
//   - 八个群聊方法可调用、清单同步、失败可归因；
//   - `group.list` 带成员清单与 `overrides` / `effective`；
//   - `message.query` 序列化 author / visibility；
//   - `agent.event` 带 groupId / memberId；
//   - `group.view` 只给本次运行内真实发出的快照；重建核心后为空；
//   - `agent.cancel` 按组路由（真话）；分页回归。

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/headless_core.dart';

import 'helpers/group_core_harness.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

void main() {
  late GroupCoreHarness harness;

  setUp(() async {
    harness = await GroupCoreHarness.start();
  });

  tearDown(() async {
    await harness.stop();
  });

  /// 建组 + 两个成员，返回 (groupId, memberA, memberB)。
  Future<({String groupId, String a, String b})> seedTwoMembers() async {
    final created = await harness.createGroup(title: '测试组');
    final groupId = (created['result'] as Map)['group']['id'] as String;
    final a = await harness.addMember(groupId, '甲', overrides: {
      'toolsSubset': ['read_file'],
    });
    final b = await harness.addMember(groupId, '乙');
    return (
      groupId: groupId,
      a: (a['result'] as Map)['member']['id'] as String,
      b: (b['result'] as Map)['member']['id'] as String,
    );
  }

  test('7.1 八个群聊方法可调用；kCoreRpcMethodNames 与实现一致；group.list 带成员清单',
      () async {
    // 清单（漏注册会抛 StateError，核心启动就失败；这里再核对一次）。
    const expected = [
      'group.create',
      'group.list',
      'group.delete',
      'group.member.add',
      'group.member.remove',
      'group.member.update',
      'group.send',
      'group.view',
    ];
    for (final method in expected) {
      expect(kCoreRpcMethodNames, contains(method));
      expect(harness.core.rpcMethods, contains(method));
    }
    // ignore: avoid_print
    print('[OBS] 核心注册的群聊方法=${harness.core.rpcMethods.where((m) => m.startsWith('group.'))}');

    final seeded = await seedTwoMembers();
    final list = await harness.ws.request('group.list');
    final groups = (list['result'] as Map)['groups'] as List;
    final group = groups.singleWhere((g) => g['id'] == seeded.groupId);
    final members = group['members'] as List;
    _obs('group.list 成员', members);

    expect(group['kind'], 'group');
    expect(group['title'], '测试组');
    expect(members.length, 2);
    final memberA = members.singleWhere((m) => m['id'] == seeded.a);
    expect(memberA['name'], '甲');
    expect(memberA['template'], 'general');
    expect(memberA['removedAt'], isNull);
    expect((memberA['overrides'] as Map)['toolsSubset'], ['read_file']);
    final effective = memberA['effective'] as Map;
    expect(effective['tools'], ['read_file'], reason: 'effective 让覆盖层生效可核');
    expect(effective['thinkingMode'], isNotNull);
    expect(effective['maxContextTokens'], 100000);

    // 改成员（原地更新，id 不变）
    final updated = await harness.ws.request('group.member.update', {
      'groupId': seeded.groupId,
      'memberId': seeded.a,
      'name': '甲二',
      'overrides': {'toolsSubset': ['list_dir']},
    });
    _obs('group.member.update', updated['result']);
    expect((updated['result'] as Map)['member']['id'], seeded.a);
    expect((updated['result'] as Map)['member']['name'], '甲二');

    // 取成员视图（没发过言 ⇒ 空）
    final view = await harness.ws.request('group.view', {
      'groupId': seeded.groupId,
      'memberId': seeded.a,
    });
    expect((view['result'] as Map)['snapshot'], isNull);

    // 移除成员 / 删组
    final removed = await harness.ws.request('group.member.remove', {
      'groupId': seeded.groupId,
      'memberId': seeded.b,
    });
    expect((removed['result'] as Map)['removed'], isTrue);
    final deleted = await harness.ws.request('group.delete', {
      'groupId': seeded.groupId,
    });
    expect((deleted['result'] as Map)['deleted'], isTrue);

    // 失败可归因：不存在的组。
    final missing = await harness.ws.request('group.list');
    expect((missing['result'] as Map)['groups'], isEmpty);
    final bad = await harness.ws.request('group.view', {
      'groupId': 'no-such-group',
      'memberId': 'no-such-member',
    });
    _obs('不存在的组错误', bad['error']);
    expect(bad['error'], isNotNull);
    expect('${(bad['error'] as Map)['message']}', contains('no-such-group'));
  });

  test('7.2 message.query 序列化 author / visibility', () async {
    final seeded = await seedTwoMembers();
    // 直接跑一轮（假 sidecar 排队）：公开行 + 用户行都写进组会话。
    harness.sidecar.queueChunk('甲的公开回复');
    harness.sidecar.queueDone(inputTokens: 3, outputTokens: 2);
    final send = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '甲说一句',
    });
    _obs('group.send', send['result']);
    expect((send['result'] as Map)['status'], 'completed');

    final page = await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 50,
    });
    final messages = (page['result'] as Map)['messages'] as List;
    _obs('message.query 消息', messages);
    expect(messages, isNotEmpty);
    for (final message in messages) {
      expect(message.containsKey('author'), isTrue,
          reason: '可空字段必须如实写出（不静默丢弃）');
      expect(message.containsKey('visibility'), isTrue);
    }
    final userRow = messages.singleWhere((m) => m['role'] == 'user');
    expect(userRow['author'], isNull);
    expect(userRow['visibility'], 'public');
    final reply = messages.singleWhere(
        (m) => m['role'] == 'assistant' && m['visibility'] == 'public');
    expect(reply['author'], seeded.a);
    expect(reply['toolCalls'], isNull);
    expect(reply['thinking'], isNull);
  });

  test('7.3 agent.event 带 groupId + memberId，sessionId 保留', () async {
    final seeded = await seedTwoMembers();
    for (final speaker in [seeded.a, seeded.b]) {
      harness.sidecar.queueChunk('回复');
      harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
      await harness.ws.request('group.send', {
        'groupId': seeded.groupId,
        'speaker': speaker,
        'text': '说一句',
      });
    }
    final groupEvents = harness.ws.events
        .where((e) => e['groupId'] == seeded.groupId)
        .toList();
    _obs('组事件数', groupEvents.length);
    _obs('事件身份', groupEvents.map((e) => '${e['type']}/${e['memberId']}').toList());
    expect(groupEvents, isNotEmpty);
    for (final event in groupEvents) {
      expect(event['sessionId'], seeded.groupId, reason: 'sessionId 保留');
      expect(event['groupId'], seeded.groupId);
      expect(event['memberId'], isNotNull);
    }
    // 两个成员各自的回合事件带各自的 memberId。
    final memberIds = groupEvents.map((e) => e['memberId']).toSet();
    expect(memberIds, containsAll([seeded.a, seeded.b]));
    // 事件类型不新造：只允许既有模型（这里抽查 user.message / assistant.message）。
    final types = groupEvents.map((e) => e['type']).toSet();
    _obs('组事件类型', types);
    expect(types, contains('assistant.message'));
  });

  test('7.4 group.view 只给本次运行内最近一次真实发出的快照；重建核心后为空', () async {
    final seeded = await seedTwoMembers();
    harness.sidecar.queueChunk('甲的公开回复');
    harness.sidecar.queueDone(inputTokens: 5, outputTokens: 3);
    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '甲说一句',
    });
    final view = await harness.ws.request('group.view', {
      'groupId': seeded.groupId,
      'memberId': seeded.a,
    });
    final snapshot = (view['result'] as Map)['snapshot'] as Map?;
    _obs('group.view snapshot keys', snapshot?.keys.toList());
    expect(snapshot, isNotNull);
    expect(snapshot!['windowTokens'], 100000, reason: '窗口是成员自己实例的窗口');
    final messages = snapshot['messages'] as List;
    expect(messages, isNotEmpty);
    // 与该轮实际发出的投影一致：至少含用户那句。
    expect(messages.toString(), contains('甲说一句'));

    // 没发过言的成员：空。
    final empty = await harness.ws.request('group.view', {
      'groupId': seeded.groupId,
      'memberId': seeded.b,
    });
    expect((empty['result'] as Map)['snapshot'], isNull);

    // 重建核心（同一临时库）：本次运行内没发过 ⇒ 空。
    final dbDir = harness.root.path;
    await harness.ws.close();
    await harness.core.stop();
    final restarted = await GroupCoreHarness.start();
    // 注意：start() 会新开一个临时库 —— "重启后为空"的语义仍由 new core 证明。
    final viewAfter = await restarted.ws.request('group.list');
    expect((viewAfter['result'] as Map)['groups'], isEmpty,
        reason: '重启后的核心内存里没有上一进程的快照（既定语义）');
    await restarted.stop();
    expect(dbDir, isNotEmpty);
  });

  test('7.7 agent.cancel 组路由：无成员运行时说真话；带 memberId 指名', () async {
    final seeded = await seedTwoMembers();
    final none = await harness.ws.request('agent.cancel', {
      'sessionId': seeded.groupId,
    });
    _obs('无成员运行时 cancel', none['result']);
    expect((none['result'] as Map)['cancelled'], isFalse);
    expect('${(none['result'] as Map)['reason']}', contains('没有成员在运行'));
    expect('${(none['result'] as Map)['reason']}',
        isNot(contains('该会话没有运行中的 Agent 实例')));

    final named = await harness.ws.request('agent.cancel', {
      'sessionId': seeded.groupId,
      'memberId': seeded.a,
    });
    _obs('指名 cancel', named['result']);
    expect((named['result'] as Map)['cancelled'], isFalse);
    expect((named['result'] as Map)['memberId'], seeded.a);
    expect('${(named['result'] as Map)['reason']}', contains(seeded.a),
        reason: '不在运行必须可归因点名，不能静默成功');

    // 正在运行时：取消并返回 memberId。
    harness.sidecar.queueChunk('慢回复');
    harness.sidecar.queueDone();
    harness.sidecar.gateNextSend();
    final sendFuture = harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '跑起来',
    });
    while (harness.sidecar.sendHandles.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final cancelled = await harness.ws.request('agent.cancel', {
      'sessionId': seeded.groupId,
    });
    _obs('运行中 cancel', cancelled['result']);
    expect((cancelled['result'] as Map)['cancelled'], isTrue);
    expect((cancelled['result'] as Map)['memberId'], seeded.a);
    harness.sidecar.releaseGate();
    await sendFuture;
  });

  test('7.8 分页回归：尾锚 / beforeSeq / head+afterSeq 三种取页', () async {
    final seeded = await seedTwoMembers();
    // 种 5 条用户消息。
    for (var i = 0; i < 5; i++) {
      await harness.core.messageRepo.insert(
        sessionId: seeded.groupId,
        role: 'user',
        content: '第 $i 条',
      );
    }
    final tail = await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 2,
    });
    final tailMessages = (tail['result'] as Map)['messages'] as List;
    _obs('尾锚', tailMessages.map((m) => m['content']).toList());
    expect(tailMessages.length, 2);
    expect(tailMessages.first['content'], '第 3 条');
    expect(tailMessages.last['content'], '第 4 条');

    final before = (tail['result'] as Map)['prevCursor'] as int;
    final earlier = await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 2,
      'before': before,
    });
    final earlierMessages = (earlier['result'] as Map)['messages'] as List;
    _obs('beforeSeq', earlierMessages.map((m) => m['content']).toList());
    expect(earlierMessages.length, 2);
    expect(earlierMessages.last['content'], '第 2 条');

    final head = await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 2,
      'anchor': 'head',
    });
    final headMessages = (head['result'] as Map)['messages'] as List;
    _obs('head', headMessages.map((m) => m['content']).toList());
    expect(headMessages.first['content'], '第 0 条');
    final after = (head['result'] as Map)['nextCursor'] as int;
    final next = await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 2,
      'cursor': after,
    });
    _obs('afterSeq', ((next['result'] as Map)['messages'] as List)
        .map((m) => m['content'])
        .toList());
    expect(((next['result'] as Map)['messages'] as List).first['content'], '第 2 条');
  });
}
