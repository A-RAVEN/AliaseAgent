// 群聊 RPC 面 v3：**异步发送** + `group.chain` + 每组轮数上限 + 链结束事件
// （change `group-reactive-mode` R.2 / R.3 / R.5 / design D7 / D9 / D13）。
//
// 走真核心（HttpServer + WebSocket + 真 sqlite + 假 sidecar）：
//   - 十个群聊方法注册且清单一致（含 `group.chain`）；
//   - `group.update` 的两个字段（开关 / 上限）与四种失败形态；
//   - `group.send` 的异步形状（只回 started/busy + triggerSeq，不带 steps/rounds）；
//   - `group.chain` 的 idle / running / 终态与 `stopReason`；
//   - `group.chain.completed` 事件（唯一新增事件类型，steps 不进事件）；
//   - `group.list` 的 busy / runningMemberId / maxRounds；
//   - `agent.cancel` 停链回包带 reactionChainStopped，链状态变 cancelled；
//   - 组服务写的 user.message 不带 memberId；forced_pass 不发 turn.failed；
//   - `group.view(乙)` 反应轮后非空且 systemPrompt 含反应提示词。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/services/group_prompts.dart';
import 'package:alias_agent/services/group_reaction.dart';

import 'helpers/group_core_harness.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 链的时间上界（测试侧，不是产品上限）：出处见 `kTestChainTimeout`。
const Duration kRpcChainTimeout = kTestChainTimeout;

/// `group.send` 必须"立刻"返回的等待上界（测试侧，不是产品超时）：同步阶段不含
/// 模型生成，假 sidecar 单轮上界 1s × 2 倍余量 = 2s；被 gate 挂住时仍不返回 ⇒ 红。
const Duration kSendReturnBudget = Duration(seconds: 2);

void main() {
  late GroupCoreHarness harness;

  setUp(() async {
    harness = await GroupCoreHarness.start();
  });

  tearDown(() async {
    await harness.stop();
  });

  Future<({String groupId, String a, String b})> seed({
    bool? reactionsEnabled,
    int? maxRounds,
    List<String> names = const ['甲', '乙'],
  }) async {
    final created = await harness.createGroup(
        title: '反应组', reactionsEnabled: reactionsEnabled, maxRounds: maxRounds);
    final groupId = (created['result'] as Map)['group']['id'] as String;
    final ids = <String>[];
    for (final name in names) {
      final member = await harness.addMember(groupId, name);
      ids.add((member['result'] as Map)['member']['id'] as String);
    }
    return (groupId: groupId, a: ids[0], b: ids.length > 1 ? ids[1] : ids[0]);
  }

  Future<void> waitForSends(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (harness.sidecar.sendRequests.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('等到 $count 次模型请求超时'
            '（实际 ${harness.sidecar.sendRequests.length}）');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// 结构化发言（R.10）：`group_react {pass:false, message: text}` 后结束该请求。
  void queueSpeak(String text) {
    harness.sidecar.queueGroupReact(pass: false, message: text);
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
  }

  /// 结构化沉默（R.10）：`group_react {pass:true}` 后结束该请求。
  void queuePass() {
    harness.sidecar.queueGroupReact(pass: true);
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
  }

  test('R.3 十个群聊方法注册且与 kCoreRpcMethodNames 一致', () async {
    const expected = [
      'group.create',
      'group.update',
      'group.chain',
      'group.list',
      'group.delete',
      'group.member.add',
      'group.member.remove',
      'group.member.update',
      'group.send',
      'group.view',
    ];
    // ignore: avoid_print
    print('[OBS] 核心注册的群聊方法='
        '${harness.core.rpcMethods.where((m) => m.startsWith('group.')).toList()}');
    expect(expected.length, 10);
    for (final method in expected) {
      expect(kCoreRpcMethodNames, contains(method));
      expect(harness.core.rpcMethods, contains(method));
    }
    expect(kCoreRpcMethodNames.where((m) => m.startsWith('group.')).length, 10);
  });

  test('R.3 group.create 带 reactionsEnabled / maxRounds 可回读；越界 -32602', () async {
    // 显式传 `reactionsEnabled: null` = **省略该字段**（夹具缺省是 false，见任务 0.3）；
    // 这里要验的是产品默认「新建组开启」与默认上限 null。
    final defaults =
        await harness.createGroup(title: '默认组', reactionsEnabled: null);
    final defaultGroup = (defaults['result'] as Map)['group'] as Map;
    _obs('省略时的返回值', {
      'reactionsEnabled': defaultGroup['reactionsEnabled'],
      'maxRounds': defaultGroup['maxRounds'],
    });
    expect(defaultGroup['reactionsEnabled'], isTrue);
    expect(defaultGroup['maxRounds'], isNull, reason: '省略 = 用产品默认（列 NULL）');

    final limited = await harness.createGroup(
        title: '上限组', reactionsEnabled: true, maxRounds: 6);
    final limitedGroup = (limited['result'] as Map)['group'] as Map;
    expect(limitedGroup['maxRounds'], 6);

    final list = await harness.ws.request('group.list');
    final groups = (list['result'] as Map)['groups'] as List;
    expect(
        groups.singleWhere((g) => g['id'] == defaultGroup['id'])['maxRounds'],
        isNull);
    expect(
        groups.singleWhere((g) => g['id'] == limitedGroup['id'])['maxRounds'],
        6);

    // 越界 / 非整数 ⇒ -32602（不静默截断）。
    for (final bad in [0, 51, -1, '6']) {
      final rejected = await harness.createGroup(
          title: '非法组', reactionsEnabled: true, maxRounds: bad);
      _obs('非法 maxRounds=$bad', rejected['error']);
      expect((rejected['error'] as Map)['code'], -32602,
          reason: 'maxRounds=$bad 必须被拒绝');
    }
  });

  test('R.3 group.update 改开关 / 上限并回读；显式 null 恢复默认', () async {
    final seeded = await seed(reactionsEnabled: true);
    final updated = await harness.ws.request('group.update', {
      'groupId': seeded.groupId,
      'reactionsEnabled': false,
    });
    _obs('group.update 返回', updated['result']);
    expect(((updated['result'] as Map)['group'] as Map)['reactionsEnabled'],
        isFalse);

    // 上限：设 6 → 读 6；显式 null → 读 null；两者都不能顺带改别的字段。
    final setRounds = await harness.ws.request('group.update', {
      'groupId': seeded.groupId,
      'maxRounds': 6,
    });
    _obs('设上限返回', (setRounds['result'] as Map)['group']);
    expect(((setRounds['result'] as Map)['group'] as Map)['maxRounds'], 6);
    expect(((setRounds['result'] as Map)['group'] as Map)['reactionsEnabled'],
        isFalse, reason: '只给 maxRounds 时开关不变');

    final groups = ((await harness.ws.request('group.list'))['result']
        as Map)['groups'] as List;
    final listed = groups.singleWhere((g) => g['id'] == seeded.groupId);
    expect(listed['reactionsEnabled'], isFalse);
    expect(listed['maxRounds'], 6);

    final sessions = ((await harness.ws.request('session.list'))['result']
        as Map)['sessions'] as List;
    final listedSession =
        sessions.singleWhere((s) => s['id'] == seeded.groupId);
    expect(listedSession['reactionsEnabled'], isFalse);
    expect(listedSession['maxRounds'], 6);

    final cleared = await harness.ws.request('group.update', {
      'groupId': seeded.groupId,
      'maxRounds': null,
    });
    _obs('显式 null 恢复默认', (cleared['result'] as Map)['group']);
    expect(((cleared['result'] as Map)['group'] as Map)['maxRounds'], isNull,
        reason: '显式 null = 恢复默认，与字段缺席不同');

    // 单会话行也写这两个字段（客户端只对组使用）。
    final single =
        await harness.ws.request('session.create', {'title': '单会话'});
    final singleId = (single['result'] as Map)['session']['id'];
    final sessions2 = ((await harness.ws.request('session.list'))['result']
        as Map)['sessions'] as List;
    final singleRow = sessions2.singleWhere((s) => s['id'] == singleId);
    expect(singleRow.containsKey('reactionsEnabled'), isTrue);
    expect(singleRow.containsKey('maxRounds'), isTrue);
  });

  test('R.3 group.update 缺字段 / 非布尔 / 上限非法 / 组不存在 ⇒ -32602', () async {
    final seeded = await seed(reactionsEnabled: true);

    final missing = await harness.ws.request('group.update', {
      'groupId': seeded.groupId,
    });
    _obs('缺字段', missing['error']);
    expect((missing['error'] as Map)['code'], -32602);
    expect('${(missing['error'] as Map)['message']}', contains('reactionsEnabled'));

    final wrongType = await harness.ws.request('group.update', {
      'groupId': seeded.groupId,
      'reactionsEnabled': 'yes',
    });
    _obs('非布尔', wrongType['error']);
    expect((wrongType['error'] as Map)['code'], -32602);

    for (final bad in [0, 51, -2, '6']) {
      final rejected = await harness.ws.request('group.update', {
        'groupId': seeded.groupId,
        'maxRounds': bad,
      });
      _obs('非法上限 $bad', rejected['error']);
      expect((rejected['error'] as Map)['code'], -32602,
          reason: 'maxRounds=$bad 必须返回 -32602');
    }

    final missingGroup = await harness.ws.request('group.update', {
      'groupId': 'no-such-group',
      'reactionsEnabled': false,
    });
    _obs('组不存在', missingGroup['error']);
    expect((missingGroup['error'] as Map)['code'], -32602);
    expect('${(missingGroup['error'] as Map)['message']}',
        contains('no-such-group'));

    // 所有失败都不许改到设置。
    final groups = ((await harness.ws.request('group.list'))['result']
        as Map)['groups'] as List;
    final listed = groups.singleWhere((g) => g['id'] == seeded.groupId);
    expect(listed['reactionsEnabled'], isTrue);
    expect(listed['maxRounds'], isNull);
  });

  test('R.3 group.chain：没有链时 idle（steps 空、rounds 0、stopReason null）', () async {
    final seeded = await seed(reactionsEnabled: true);
    final chain = await harness.groupChain(seeded.groupId);
    _obs('空闲链', chain);
    expect(chain['status'], 'idle');
    expect(chain['steps'], isEmpty);
    expect(chain['rounds'], 0);
    expect(chain['stopReason'], isNull);
    expect(chain['triggerSeq'], isNull);
    // 不存在的组可归因。
    final missing = await harness.ws.request('group.chain', {
      'groupId': 'no-such-group',
    });
    expect((missing['error'] as Map)['code'], -32602);
    expect('${(missing['error'] as Map)['message']}', contains('no-such-group'));
  });

  test('R.3 group.send 异步形状：立刻回 started + triggerSeq，不含 steps/rounds/memberId',
      () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queuePass();

    // 第二反应轮（乙对甲的公开回复）沉默，避免缺 group_react。
    queuePass();
    harness.sidecar.gateNextSend();

    final response = await harness.ws
        .request('group.send', {
          'groupId': seeded.groupId,
          'text': '讲个笑话',
        })
        .timeout(kSendReturnBudget,
            onTimeout: () => throw TimeoutException(
                'group.send 没有在链结束前返回（同步等待了模型调用？）',
                kSendReturnBudget));
    final result = response['result'] as Map;
    _obs('group.send 结果', result);
    expect(result['status'], 'started');
    expect(result['groupId'], seeded.groupId);
    expect(result['sessionId'], seeded.groupId);
    expect(result['triggerSeq'], isA<int>());
    for (final forbidden in ['steps', 'rounds', 'finalText', 'memberId']) {
      expect(result.containsKey(forbidden), isFalse,
          reason: '异步契约不再带 $forbidden（从 group.chain 读）');
    }

    // 用户消息在返回前已写入一条。
    final messages = ((await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 50,
    }))['result'] as Map)['messages'] as List;
    final userRows = messages.where((row) => (row as Map)['role'] == 'user');
    expect(userRows.length, 1);
    expect(result['triggerSeq'], (userRows.single as Map)['seq']);

    // 链已经在跑；模型请求已发出（被 gate 挂住）。
    final running = await harness.groupChain(seeded.groupId);
    _obs('运行中的链', running);
    expect(running['status'], 'running');
    expect(running['stopReason'], isNull);
    await waitForSends(1);

    harness.sidecar.releaseGate();
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('链终态', chain);
    expect(chain['status'], 'completed');
    expect(kGroupChainStopReasons, contains(chain['stopReason']));
    expect(chain['rounds'], greaterThanOrEqualTo(1));
    final steps = chain['steps'] as List;
    expect(steps, isNotEmpty);
    for (final step in steps) {
      expect(kReactionStepSources, contains((step as Map)['source']));
      expect(kReactionStepStatuses, contains(step['status']));
      expect(step['memberId'], isNotNull);
    }
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.8 group.send 永不 busy：链中再发仍回 started 并写第二条用户消息', () async {
    final seeded = await seed(reactionsEnabled: true, names: const ['甲']);
    queueSpeak('甲对第一条的回复');
    queueSpeak('甲对第二条的回复');
    harness.sidecar.gateNextSend();
    final first = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '第一条',
    });
    await waitForSends(1);
    final second = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '第二条',
    });
    final firstResult = first['result'] as Map;
    final secondResult = second['result'] as Map;
    // ignore: avoid_print
    print('[OBS] 链中两次 group.send => '
        '${firstResult['status']} / ${secondResult['status']}');
    expect(firstResult['status'], 'started');
    expect(secondResult['status'], 'started', reason: 'R.8：永不 busy');
    expect(secondResult.containsKey('error'), isFalse);
    final userRows =
        (await harness.core.groups.messageRepo.queryBySession(seeded.groupId))
            .where((row) => row.role == 'user')
            .toList();
    expect(userRows.map((row) => row.content).toList(), ['第一条', '第二条']);
    harness.sidecar.releaseGate();
    final chain = await harness.waitForChain(seeded.groupId);
    // ignore: avoid_print
    print('[OBS] 连发后的链终态: $chain');
    expect(chain['status'], 'completed');
    expect((chain['steps'] as List).length, 2,
        reason: '两条用户触发各跑一轮，都产生公开回复');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 链结束事件 group.chain.completed：只在终态发、带 stopReason、steps 不进事件',
      () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queuePass();

    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '讲个笑话',
    });
    final chain = await harness.waitForChain(seeded.groupId);
    final events = harness.ws.events
        .where((event) =>
            event['type'] == 'group.chain.completed' &&
            event['groupId'] == seeded.groupId)
        .toList();
    _obs('链结束事件', events);
    expect(events.length, 1, reason: '一条链进入终态只发一次');
    final data = events.single['data'] as Map;
    expect(data['status'], chain['status']);
    expect(data['stopReason'], chain['stopReason']);
    expect(data['rounds'], chain['rounds']);
    expect(data['triggerSeq'], chain['triggerSeq']);
    expect(data.containsKey('steps'), isFalse,
        reason: 'steps 不塞进事件（需要时查 group.chain）');
    expect(events.single['sessionId'], seeded.groupId);
    // 事件类型封闭：唯一新增的就是它（其余仍是既有类型）。
    final otherNew = harness.ws.events
        .map((event) => event['type'])
        .whereType<String>()
        .where((type) => type.startsWith('group.'))
        .toSet();
    _obs('group.* 事件类型', otherNew);
    expect(otherNew, {'group.chain.completed'});
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 group.list 带 busy / runningMemberId（链中 true + 成员 id，链后 false）',
      () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queuePass();

    harness.sidecar.gateNextSend();

    final started = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '讲个笑话',
    });
    expect((started['result'] as Map)['status'], 'started');
    await waitForSends(1);
    final during = ((await harness.ws.request('group.list'))['result']
        as Map)['groups'] as List;
    final busyGroup = during.singleWhere((g) => g['id'] == seeded.groupId);
    _obs('链中 group.list', {
      'busy': busyGroup['busy'],
      'runningMemberId': busyGroup['runningMemberId'],
    });
    expect(busyGroup['busy'], isTrue);
    expect(busyGroup['runningMemberId'], seeded.a);

    harness.sidecar.releaseGate();
    await harness.waitForChain(seeded.groupId);
    final after = ((await harness.ws.request('group.list'))['result']
        as Map)['groups'] as List;
    final idleGroup = after.singleWhere((g) => g['id'] == seeded.groupId);
    expect(idleGroup['busy'], isFalse);
    expect(idleGroup['runningMemberId'], isNull);
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 没有可反应成员 ⇒ started；chain completed steps=[] rounds=0 no_members',
      () async {
    final created = await harness.createGroup(
        title: '空组', reactionsEnabled: true);
    final groupId = (created['result'] as Map)['group']['id'] as String;
    final member = await harness.addMember(groupId, '甲');
    final memberId = (member['result'] as Map)['member']['id'] as String;
    await harness.ws.request('group.member.remove', {
      'groupId': groupId,
      'memberId': memberId,
    });

    final response = await harness.ws.request('group.send', {
      'groupId': groupId,
      'text': '有人吗',
    });
    final result = response['result'] as Map;
    _obs('异步回包', result);
    expect(result['status'], 'started');
    final chain = await harness.waitForChain(groupId);
    _obs('空步骤链', chain);
    expect(chain['status'], 'completed');
    expect(chain['steps'], isEmpty);
    expect(chain['rounds'], 0);
    expect(chain['stopReason'], 'no_members');
    expect(chain['triggerSeq'], isNotNull);

    final messages = ((await harness.ws.request('message.query', {
      'sessionId': groupId,
      'pageSize': 50,
    }))['result'] as Map)['messages'] as List;
    final userRows = messages.where((row) => (row as Map)['role'] == 'user');
    expect(userRows.length, 1, reason: '用户消息照常写入一条');
    expect(harness.sidecar.sendRequests, isEmpty);
  });

  test('R.3 关闭态省略 speaker ⇒ -32602 且原因 no_speaker（不写消息、不建链）', () async {
    final seeded = await seed(reactionsEnabled: false);
    final response = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '谁来说',
    });
    _obs('关闭态省略 speaker', response['error']);
    expect((response['error'] as Map)['code'], -32602);
    expect('${(response['error'] as Map)['message']}', contains('no_speaker'));
    final messages = ((await harness.ws.request('message.query', {
      'sessionId': seeded.groupId,
      'pageSize': 50,
    }))['result'] as Map)['messages'] as List;
    expect(messages, isEmpty);
    expect((await harness.groupChain(seeded.groupId))['status'], 'idle',
        reason: '被拒的发送不建链');
  });

  test('R.3 speaker 类型不对 ⇒ -32602；空串也拒绝', () async {
    final seeded = await seed(reactionsEnabled: false);
    final wrongType = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': 42,
      'text': '说',
    });
    expect((wrongType['error'] as Map)['code'], -32602);
    final empty = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': '',
      'text': '说',
    });
    _obs('空串 speaker', empty['error']);
    expect((empty['error'] as Map)['code'], -32602);
  });

  test('R.3 user.message 事件带 groupId 且 memberId 为空（组服务写的）', () async {
    final seeded = await seed(reactionsEnabled: true, names: ['甲']);
    queuePass();

    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '开个话头',
    });
    await harness.waitForChain(seeded.groupId);
    final userEvents = harness.ws.events
        .where((event) =>
            event['type'] == 'user.message' &&
            event['groupId'] == seeded.groupId)
        .toList();
    _obs('user.message 事件', userEvents);
    expect(userEvents.length, 1, reason: '组服务只写一次用户消息');
    expect(userEvents.single['sessionId'], seeded.groupId);
    expect(userEvents.single['memberId'], isNull,
        reason: '用户消息没有成员作者：不伪造 memberId');
    expect('${(userEvents.single['data'] as Map)['content']}', '开个话头');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 forced_pass 不发 turn.failed，只在 group.chain 的 steps 里可观察', () async {
    final seeded = await seed(reactionsEnabled: true);
    queuePass();

    // 链从用户消息起：乙被点名 → 强制回应。
    queueSpeak('乙的回应');

    queuePass();


    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '@乙 你怎么看',
    });
    final chain = await harness.waitForChain(seeded.groupId);
    final steps = chain['steps'] as List;
    _obs('steps', steps);
    expect((steps.first as Map)['status'], 'forced_pass');
    final failed = harness.ws.events
        .where((event) =>
            event['type'] == 'turn.failed' &&
            event['groupId'] == seeded.groupId)
        .toList();
    _obs('turn.failed 事件', failed);
    expect(failed, isEmpty, reason: 'forced_pass 不是整轮失败，不许走 turn.failed');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 agent.cancel 停链：回包 reactionChainStopped=true + 链状态 cancelled',
      () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queueSpeak('乙不该跑');

    harness.sidecar.gateNextSend();

    final started = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '讲个笑话',
    });
    expect((started['result'] as Map)['status'], 'started');
    await waitForSends(1);
    final cancelled = await harness.ws.request('agent.cancel', {
      'sessionId': seeded.groupId,
    });
    _obs('cancel 结果', cancelled['result']);
    expect((cancelled['result'] as Map)['cancelled'], isTrue);
    expect((cancelled['result'] as Map)['reactionChainStopped'], isTrue);
    expect((cancelled['result'] as Map)['memberId'], seeded.a);
    harness.sidecar.releaseGate();
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('取消后的链', chain);
    expect(chain['status'], 'cancelled');
    expect(chain['stopReason'], 'cancelled');
    final events = harness.ws.events
        .where((event) =>
            event['type'] == 'group.chain.completed' &&
            event['groupId'] == seeded.groupId)
        .toList();
    expect(events.length, 1);
    expect((events.single['data'] as Map)['stopReason'], 'cancelled');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 达上限的链终态：completed + round_cap（不是失败、不再起轮）', () async {
    final seeded = await seed(reactionsEnabled: true, maxRounds: 1);
    // 轮1 两人各一条公开回复（触发都是用户消息）；第 2 轮会被上限拦住。
    queueSpeak('甲的第一轮');

    queueSpeak('乙的第一轮');

    queueSpeak('不该跑到的第二轮');


    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '大家聊聊',
    });
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('链终态', chain);
    expect(chain['status'], 'completed');
    expect(chain['stopReason'], 'round_cap');
    expect(chain['rounds'], 1);
    expect(harness.sidecar.sendRequests.length, 2,
        reason: '上限 1 轮 ⇒ 只跑这一轮的两位成员；第 2 轮不许开始');
    expect(harness.sidecar.hasQueuedEvents, isTrue,
        reason: '达上限立即停 ⇒ 第 2 轮的模型回复一次都没被消费');
    final events = harness.ws.events
        .where((event) =>
            event['type'] == 'group.chain.completed' &&
            event['groupId'] == seeded.groupId)
        .toList();
    expect((events.single['data'] as Map)['stopReason'], 'round_cap');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 group.view(乙) 反应轮后非空且 systemPrompt 含反应提示词', () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queueSpeak('乙的反应');

    queuePass();

    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '讲个笑话',
    });
    await harness.waitForChain(seeded.groupId);
    final view = await harness.ws.request('group.view', {
      'groupId': seeded.groupId,
      'memberId': seeded.b,
    });
    final snapshot = (view['result'] as Map)['snapshot'] as Map?;
    _obs('group.view(乙) snapshot 是否非空', snapshot != null);
    expect(snapshot, isNotNull, reason: '反应轮也算真实发出');
    final system = '${snapshot!['system']}';
    expect(system, contains(kGroupReactionPrompt),
        reason: '快照必须是该轮实际发出的系统提示词（含自愿反应提示词）');
    expect(system, contains('你是一个群聊组的成员'),
        reason: '成员角色说明仍在（追加不是替换）');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 安静态纯点名：结果只有异步回包字段，链终态 no_members / rounds 0',
      () async {
    final seeded = await seed(reactionsEnabled: false);
    harness.sidecar.queueChunk('甲的回复');
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    final response = await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '甲先说',
    });
    final result = response['result'] as Map;
    _obs('安静态异步回包', result);
    expect(result['status'], 'started');
    expect(result['triggerSeq'], isA<int>());
    expect(result.containsKey('steps'), isFalse);
    expect(result.containsKey('rounds'), isFalse);
    expect(result.containsKey('finalText'), isFalse);
    expect(result.containsKey('memberId'), isFalse);
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('安静态链终态', chain);
    expect(chain['status'], 'completed');
    expect(chain['stopReason'], 'no_members', reason: '安静态没有反应轮可跑');
    expect(chain['rounds'], 0);
    expect((chain['steps'] as List).single['source'], 'speaker');
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.3 group.chain 的 steps 状态取自封闭枚举（含 forced_empty 用例）', () async {
    final seeded = await seed(reactionsEnabled: true);
    // speaker 强制轮输出纯空白 ⇒ forced_empty。
    harness.sidecar.queueGroupReact(pass: false, message: '');
    harness.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    // 后续反应轮（乙）沉默，让链自然停。
    queuePass();
    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'speaker': seeded.a,
      'text': '甲你来说',
    });
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('steps', chain['steps']);
    final steps = chain['steps'] as List;
    expect((steps.first as Map)['status'], 'forced_empty');
    for (final step in steps) {
      expect(kReactionStepStatuses, contains((step as Map)['status']));
    }
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.15 失败链 group.chain 带可归因 error（provider boom）', () async {
    final seeded = await seed(reactionsEnabled: true);
    // 模型请求硬失败（done code=1 + error 文本）：链进入 failed，真因必须能读到。
    harness.sidecar.queueDone(code: 1, error: 'provider boom');
    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '这条链会失败',
    });
    final chain = await harness.waitForChain(seeded.groupId);
    _obs('失败链的 group.chain', chain);
    expect(chain['status'], 'failed');
    expect(chain['stopReason'], 'failed');
    expect('${chain['error']}', contains('provider boom'),
        reason: 'group.chain 必须带失败真因，不能只回 failed 把原因吞掉');
    final steps = chain['steps'] as List;
    _obs('失败链 steps', steps);
    expect(steps.any((step) => (step as Map)['status'] == 'failed'), isTrue);
  }, timeout: Timeout(kRpcChainTimeout));

  test('R.15 completed / cancelled 链的 error 为 null（回归守卫）', () async {
    final seeded = await seed(reactionsEnabled: true);
    queueSpeak('甲的公开回复');

    queuePass();

    queuePass();

    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '先跑一条成功的链',
    });
    final completed = await harness.waitForChain(seeded.groupId);
    _obs('completed 链的 error', completed['error']);
    expect(completed['status'], 'completed');
    expect(completed['error'], isNull,
        reason: 'completed 链不得带任何失败真因');

    // 第二条链跑到一半取消：cancelled 也不许带旧 error。
    final sendsBefore = harness.sidecar.sendRequests.length;
    queueSpeak('乙不该跑完');
    harness.sidecar.gateNextSend();
    await harness.ws.request('group.send', {
      'groupId': seeded.groupId,
      'text': '这条链会被取消',
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (harness.sidecar.sendRequests.length <= sendsBefore) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('等待第二次模型请求超时'
            '（实际 ${harness.sidecar.sendRequests.length}）');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final cancelledResponse = await harness.ws.request('agent.cancel', {
      'sessionId': seeded.groupId,
    });
    _obs('取消回包', cancelledResponse['result']);
    harness.sidecar.releaseGate();
    final cancelled = await harness.waitForChain(seeded.groupId);
    _obs('cancelled 链的 error', cancelled['error']);
    expect(cancelled['status'], 'cancelled');
    expect(cancelled['error'], isNull,
        reason: 'cancelled 链不得带失败真因（旧 error 不许残留）');
  }, timeout: Timeout(kRpcChainTimeout));
}
