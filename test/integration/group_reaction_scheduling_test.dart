// 组调度器 v3：**异步**群发送 + 自发反应链、@mention 强制、收敛（含每组轮数上限）、
// 生命周期与取消（change `group-reactive-mode` R.2 / R.5 / design D2~D7 / D13）。
//
// 隔离：`GroupHarness`（临时 configPath / attachmentsDir / 数据库 / lock / 工作区 +
// 假 sidecar + 假摘要 provider），绝不写用户真实 `~/.aliasagent`。
//
// 异步契约：`groups.send` 只返回 `started`；**所有断言前必须先 `waitForChain()` 等终态**
// （链没跑完就断言会查到半步现场，清理时还会销毁仍在跑的侧车 —— R.7 的硬约束）。
//
// 假 sidecar 的事件队列是 FIFO 的：按预期成员顺序排队，每个成员一轮消费一组；这样
// 「谁真的跑了几轮」由 `sendRequests` 计数与 `group.chain` 的 `steps` 双向核对。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/group_member.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/group_reaction.dart';
import 'package:alias_agent/services/group_service.dart';

import 'group_harness.dart';

/// 反应链用例的**测试侧**超时上界（不是产品上限；产品上限是每组 `maxRounds`）。
///
/// 出处（design R.6 推导公式）：假 sidecar 单轮预期 ≤ 1s × 用例最大成员数 4 ×
/// `min(该组上限或默认 8, 3)` × 安全系数 2 = 24s。它只用来让「链不收敛」的变异变成
/// **红**而不是永久挂起。
const Duration kReactionSchedulingTimeout = kTestChainTimeout;

/// 「`send` 在链结束前返回」这条断言的等待上界（测试侧，不是产品超时）。
///
/// 出处：`send` 的同步阶段只做前置校验 + 写一次用户消息，**不含模型生成**；假 sidecar
/// 单轮上界 1s，乘 2 倍余量 = 2s。被 gate 挂住时若 `send` 还在等链，这里会抛超时 ⇒ 红。
const Duration kSendReturnBudget = Duration(seconds: 2);

/// 等到假 sidecar 收到至少 [count] 次模型请求（否则断言会查到空）。
Future<void> _waitForRequests(GroupHarness harness, int count,
    {Duration limit = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(limit);
  while (harness.support.sidecar.sendRequests.length < count) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
          '等到 $count 次模型请求超时（实际 ${harness.support.sidecar.sendRequests.length}）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

List<String> _stepView(List<GroupSendStep> steps) => [
      for (final step in steps)
        '${step.source}/${step.status}/trigger=${step.triggerSeq}/public=${step.publicSeq}',
    ];

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

/// 某成员的模型请求（按句柄过滤）。
List<String> _requestsOf(GroupHarness harness, GroupMember member) => [
      for (final request in harness.support.sidecar.sendRequests)
        if (request.handle == member.handle) request.messagesJson,
    ];

Future<List<Message>> _rowsOf(GroupHarness harness) =>
    harness.support.messageRepo.queryBySession(harness.group.id);

List<Message> _publicMessages(List<Message> rows) =>
    rows.where((row) => row.visibility == 'public').toList();

void main() {
  // ---------------------------------------------------------------------------
  // 3.1 开关与默认
  // ---------------------------------------------------------------------------

  test('3.1 新建组默认开启；关闭后读回 false；链中改设置 busy 且值不变', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final created = await harness.groups.createGroup(title: '新组');
    _obs('新建组 reactionsEnabled', created.reactionsEnabled);
    expect(created.reactionsEnabled, isTrue, reason: '新建组默认开启');

    final updated = await harness.groups.updateReactionsEnabled(created.id, false);
    _obs('关闭后读回', updated.reactionsEnabled);
    expect(updated.reactionsEnabled, isFalse);

    // 切回开启，然后起一条链，在链中改设置。
    await harness.groups.updateReactionsEnabled(created.id, true);
    await harness.groups.addMember(
        groupId: created.id, name: '甲', templateName: 'general');
    harness.group = created;
    harness.queueReact(pass: false, message: '甲讲了笑话'); // 甲
    harness.queuePass(); // 甲（下一轮）
    harness.support.sidecar.gateNextSend();
    final started = await harness.groups
        .send(groupId: created.id, memberId: null, text: '甲讲个笑话');
    expect(started.status, 'started');
    await _waitForRequests(harness, 1);

    Object? error;
    try {
      await harness.groups.updateReactionsEnabled(created.id, false);
    } catch (e) {
      error = e;
    }
    _obs('链中改开关错误', error);
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'busy');
    final reread = await harness.support.sessionRepo.get(created.id);
    expect(reread!.reactionsEnabled, isTrue, reason: '链中改开关：值不变（不排队）');

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain(created.id);
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(chain.steps, isNotEmpty);
    await harness.dispose();
  });

  test('3.1 开启态空 speaker + 空文本 ⇒ no_trigger 且零消息', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    final before = (await _rowsOf(harness)).length;
    Object? error;
    try {
      await harness.groups.send(groupId: harness.group.id, memberId: null);
    } catch (e) {
      error = e;
    }
    final after = (await _rowsOf(harness)).length;
    _obs('no_trigger 错误', error);
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'no_trigger');
    expect(after, before, reason: '被拒的发送不得写入任何消息');
    expect(harness.support.sidecar.sendRequests, isEmpty);
    expect(harness.chainOf().status, 'idle',
        reason: '被拒的发送不建链（不留下 running 的幽灵链）');
    await harness.dispose();
  });

  test('3.1 开启态 speaker 不带文本：两个前置门同步拒绝，且不建链', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    Object? emptyView;
    try {
      await harness.groups.send(groupId: harness.group.id, memberId: a.id);
    } catch (e) {
      emptyView = e;
    }
    _obs('开启态空视图错误', emptyView);
    expect(emptyView, isA<GroupException>());
    expect((emptyView as GroupException).code, 'empty_view');
    expect(harness.support.sidecar.sendRequests, isEmpty,
        reason: '被前置门挡住时一次模型请求都不该发出');
    expect(harness.chainOf().status, 'idle', reason: '前置门失败不建链');

    // 最后一条可见项是本人 assistant ⇒ prefill 拒绝。
    harness.queueReact(pass: false, message: '甲的第一句');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    await harness.waitForChain();
    final sendsBefore = harness.support.sidecar.sendRequests.length;
    Object? prefill;
    try {
      await harness.groups.send(groupId: harness.group.id, memberId: a.id);
    } catch (e) {
      prefill = e;
    }
    _obs('开启态 prefill 错误', prefill);
    expect(prefill, isA<GroupException>());
    expect((prefill as GroupException).code, 'prefill');
    expect(harness.support.sidecar.sendRequests.length, sendsBefore,
        reason: 'prefill 退化请求必须被挡住，不发出去');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.1 关闭态空 speaker 且无 mention ⇒ no_speaker 且零消息', () async {
    final harness = await GroupHarness.create();
    await harness.addMember('甲');
    final before = (await _rowsOf(harness)).length;
    Object? error;
    try {
      await harness.groups
          .send(groupId: harness.group.id, memberId: null, text: '谁来说');
    } catch (e) {
      error = e;
    }
    final after = (await _rowsOf(harness)).length;
    _obs('no_speaker 错误', error);
    expect(error, isA<GroupException>());
    expect((error as GroupException).code, 'no_speaker');
    expect(after, before);
    expect(harness.support.sidecar.sendRequests, isEmpty);
    expect(harness.chainOf().status, 'idle');
    await harness.dispose();
  });

  // ---------------------------------------------------------------------------
  // R.2 异步发送契约
  // ---------------------------------------------------------------------------

  test('R.2 send 在第一次模型调用返回前就返回 started，链在后台继续', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    harness.queueReact(pass: false, message: '甲的公开回复');
    harness.queuePass();
    harness.support.sidecar.gateNextSend();

    final started = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '讲个笑话')
        .timeout(kSendReturnBudget,
            onTimeout: () => throw TimeoutException(
                'group.send 没有在链结束前返回（同步等待了模型调用？）',
                kSendReturnBudget));
    _obs('send 回包', {'status': started.status, 'triggerSeq': started.triggerSeq});
    expect(started.status, 'started');
    expect(started.isStarted, isTrue);
    expect(started.triggerSeq, isNotNull, reason: '带文本 ⇒ triggerSeq = 用户消息 seq');

    // 用户消息在返回前就已写入（组服务写，一次）。
    final userRows = (await _rowsOf(harness)).where((row) => row.role == 'user');
    expect(userRows.length, 1);
    expect(started.triggerSeq, userRows.single.seq);
    // 链已经在跑，且第一次模型请求已经发出（被 gate 挂住）。
    expect(harness.chainOf().status, 'running');
    await _waitForRequests(harness, 1);
    expect(harness.support.sidecar.sendRequests.single.handle, a.handle);

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} rounds=${chain.rounds}');
    expect(chain.status, 'completed');
    expect(_requestsOf(harness, a), isNotEmpty);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.2 链开始后 group.chain 为 running（stopReason 为 null），终态才有 stopReason',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    harness.queueReact(pass: false, message: '甲说了话');
    harness.queuePass();
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    final running = harness.chainOf();
    _obs('运行中的链', '${running.status}/${running.stopReason} rounds=${running.rounds}');
    expect(running.status, 'running');
    expect(running.stopReason, isNull);

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    expect(chain.stopReason, isNotNull);
    expect(kGroupChainStopReasons, contains(chain.stopReason));
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.2 达每组上限优雅停：stopReason=round_cap、rounds==上限、第 N+1 轮不开始',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true, maxRounds: 2);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    // 两轮 × 两人各一条公开回复；第 3 轮若开始会再消费两条（下面故意多排）。
    harness.queueReact(pass: false, message: '甲的第一轮');
    harness.queueReact(pass: false, message: '乙的第一轮');
    harness.queueReact(pass: false, message: '甲的第二轮');
    harness.queueReact(pass: false, message: '乙的第二轮');
    harness.queueReact(pass: false, message: '不该跑到的第三轮甲');
    harness.queueReact(pass: false, message: '不该跑到的第三轮乙');

    final started = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '大家聊聊');
    expect(started.status, 'started');
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} rounds=${chain.rounds}');
    _obs('steps', _stepView(chain.steps));
    _obs('模型请求数', harness.support.sidecar.sendRequests.length);
    expect(chain.status, 'completed', reason: '达上限是优雅停，不是失败');
    expect(chain.stopReason, 'round_cap');
    expect(chain.rounds, 2);
    // 轮1 两人各一条（2 次请求）；轮2 触发是乙那条回复的作者排除后只剩甲（1 次）
    // ⇒ 共 3 次。第 3 轮若开始会再消费下面排的「不该跑到」回复。
    expect(harness.support.sidecar.sendRequests.length, 3,
        reason: '上限 2 轮内只跑这 3 次请求；第 3 轮不许开始');
    expect(harness.support.sidecar.hasQueuedEvents, isTrue,
        reason: '达上限立即停 ⇒ 后面排的模型回复一次都没被消费（上限真的生效）');
    expect(_requestsOf(harness, a).length, 2);
    expect(_requestsOf(harness, b).length, 1);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.2 定向轮不受上限影响：maxRounds=1 时 speaker 强制轮照常执行', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true, maxRounds: 1);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的强制回复');
    harness.queueReact(pass: false, message: '乙的反应');

    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲你来说');
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} rounds=${chain.rounds}');
    _obs('steps', _stepView(chain.steps));
    expect(chain.steps.first.source, 'speaker', reason: '定向轮照常执行（不被上限拦截）');
    expect(chain.steps.first.status, 'replied');
    expect(chain.rounds, 1, reason: '上限只约束之后的反应轮');
    expect(chain.stopReason, 'round_cap');
    expect(_requestsOf(harness, a), isNotEmpty);
    expect(_requestsOf(harness, b).length, 1, reason: '反应轮跑了一轮');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.2 链终态发 group.chain.completed（唯一新增事件）且 payload 带 stopReason',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    harness.queuePass();
    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '随口一说');
    final chain = await harness.waitForChain();
    _obs('链结束事件', harness.chainEvents.map((c) => c.toJson()).toList());
    expect(harness.chainEvents.length, 1);
    final event = harness.chainEvents.single;
    expect(event.groupId, harness.group.id);
    expect(event.status, chain.status);
    expect(event.stopReason, chain.stopReason);
    expect(event.rounds, chain.rounds);
    expect(event.triggerSeq, chain.triggerSeq);
    // 事件的 payload 由核心组装（`group.chain.completed` 只带
    // groupId/status/stopReason/rounds/triggerSeq，**steps 不进事件**）——
    // 这条在 `group_reaction_rpc_test` 里按真实 `agent.event` 断言。
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  // ---------------------------------------------------------------------------
  // 3.2 触发、串行与作者排除
  // ---------------------------------------------------------------------------

  test('3.2 用户消息触发反应链（甲先、乙后）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的评价：这个笑点在双关');
    harness.queueReact(pass: false, message: '乙的评价：结构上先抑后扬');
    harness.queuePass(); // 甲对乙这条反应 → PASS

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '甲讲个笑话，乙评价');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    _obs('rounds', chain.rounds);
    final rows = _publicMessages(await _rowsOf(harness));
    _obs('公开行', rows.map((row) => '${row.author ?? 'user'}:${row.content}').toList());

    expect(chain.status, 'completed');
    final steps = chain.steps;
    expect(steps.length, greaterThanOrEqualTo(2));
    expect(steps[0].memberId, a.id);
    expect(steps[0].source, 'reaction');
    expect(steps[0].status, 'replied');
    expect(steps[0].publicSeq, isNotNull);
    expect(steps[1].memberId, b.id);
    expect(steps[1].status, 'replied');
    expect(chain.rounds, greaterThanOrEqualTo(1));
    // 两条成员公开行都在时间线里。
    expect(rows.where((row) => row.author == a.id), isNotEmpty);
    expect(rows.where((row) => row.author == b.id), isNotEmpty);
    // 用户消息只写了一条。
    expect(rows.where((row) => row.role == 'user').length, 1);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 轮末最后一条决定下一触发，后跑者看到先跑者的「X 说：」', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的评价：这个笑点在双关');
    harness.queueReact(pass: false, message: '乙的评价：结构上先抑后扬');
    harness.queuePass(); // 甲对乙这条
    harness.queuePass(); // 乙对甲那条（若有第三轮）

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '讲个笑话');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));

    // 乙在**同一轮**里已经看到甲的公开回复（串行可见）。
    final bRequests = _requestsOf(harness, b);
    expect(bRequests, isNotEmpty, reason: '乙那次请求必须真的被捕获');
    expect(bRequests.first, contains('甲 说：'));
    expect(bRequests.first, contains('这个笑点在双关'));

    // 下一轮触发是**乙**那条回复的 seq（不是甲、乙各再起一轮）。
    final bStep = chain.steps.firstWhere((step) => step.memberId == b.id);
    _obs('乙的 publicSeq', bStep.publicSeq);
    expect(bStep.publicSeq, isNotNull);
    final stepsTriggeredByB = chain.steps
        .where((step) => step.triggerSeq == bStep.publicSeq)
        .toList();
    _obs('以乙的 seq 为触发的步骤', _stepView(stepsTriggeredByB));
    expect(stepsTriggeredByB, isNotEmpty,
        reason: '下一轮触发 = 乙的 seq（不是把轮内每条再各排一轮）');
    expect(stepsTriggeredByB.single.source, 'reaction');
    expect(stepsTriggeredByB.single.memberId, a.id,
        reason: '对乙那条反应的是甲（作者不反应自己）');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 作者不反应自己', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的评价一');
    harness.queueReact(pass: false, message: '乙的评价一');
    harness.queuePass();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '讲个笑话');
    final chain = await harness.waitForChain();
    final aStep = chain.steps.firstWhere((step) => step.memberId == a.id);
    _obs('steps', _stepView(chain.steps));
    // 甲的第一条公开回复作为触发时，甲不在可反应成员里：
    // 所以甲的下一次出现只能是对**乙**那条回复的反应。
    final afterA = chain.steps
        .where((step) => step.memberId == a.id && step.triggerSeq == aStep.publicSeq);
    expect(afterA, isEmpty, reason: '作者不反应自己');
    expect(chain.steps.where((step) => step.memberId == b.id), isNotEmpty);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 串行可见：丙的视图含乙的「乙 说：…」', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    final c = await harness.addMember('丙');
    harness.queueReact(pass: false, message: '甲的公开回复');
    harness.queueReact(pass: false, message: '乙的公开回复');
    harness.queueReact(pass: false, message: '丙的公开回复');
    // 后续轮次全部 PASS，让链收敛。
    harness.queuePass();
    harness.queuePass();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '讲个笑话');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    final cRequests = _requestsOf(harness, c);
    expect(cRequests, isNotEmpty, reason: '丙那次请求必须真的被捕获（否则串行可见无从谈起）');
    _obs('丙的请求含乙的归属前缀?', cRequests.first.contains('乙 说：'));
    expect(cRequests.first, contains('乙 说：'));
    expect(cRequests.first, contains('乙的公开回复'));
    // 三个成员各落一条公开行。
    final rows = _publicMessages(await _rowsOf(harness));
    for (final member in [a, b, c]) {
      expect(rows.where((row) => row.author == member.id), isNotEmpty,
          reason: '${member.name} 必须有公开行');
    }
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 没有可反应成员时 steps=[] rounds=0 stopReason=no_members（仍是成功链）',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final only = await harness.addMember('甲');
    await harness.groups.removeMember(harness.group.id, only.id);
    final started = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '有人吗');
    final chain = await harness.waitForChain();
    final rows = await _rowsOf(harness);
    _obs('steps', chain.steps);
    _obs('rounds', chain.rounds);
    _obs('triggerSeq', chain.triggerSeq);
    expect(started.status, 'started');
    expect(chain.status, 'completed');
    expect(chain.steps, isEmpty);
    expect(chain.rounds, 0);
    expect(chain.stopReason, 'no_members');
    final userRows = rows.where((row) => row.role == 'user').toList();
    expect(userRows.length, 1, reason: '用户消息照常写入一条（不返回错误）');
    expect(chain.triggerSeq, userRows.single.seq);
    expect(harness.support.sidecar.sendRequests, isEmpty);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 全 PASS 自然停：rounds==1、步骤数==成员数、stopReason=all_passed、无额外调用',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    await harness.addMember('乙');
    harness.queuePass();
    harness.queuePass();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '随口一说');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    _obs('rounds', chain.rounds);
    _obs('模型请求数', harness.support.sidecar.sendRequests.length);
    expect(chain.status, 'completed');
    expect(chain.stopReason, 'all_passed');
    expect(chain.rounds, 1);
    expect(chain.steps.length, 2);
    expect(chain.steps.every((step) => step.status == 'passed'), isTrue);
    expect(harness.support.sidecar.sendRequests.length, 2,
        reason: '全 PASS ⇒ 没有新公开消息 ⇒ 下一轮规划为空 ⇒ 没有额外模型调用');
    final publicRows = _publicMessages(await _rowsOf(harness));
    expect(publicRows.where((row) => row.role == 'assistant'), isEmpty,
        reason: '全 PASS 不写公开行');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 last-reacted-seq：同一条公开消息不重复反应（链收敛）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的公开回复');
    harness.queuePass(); // 乙对甲那条 PASS
    harness.queuePass(); // 若 lastReacted 失效，乙会再被选中（第 3 条）

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '讲个笑话');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    _obs('rounds', chain.rounds);
    _obs('模型请求数', harness.support.sidecar.sendRequests.length);
    // 轮1：甲 replied + 乙 passed；轮2：乙对甲那条 passed；轮3 规划为空 ⇒ 停。
    expect(chain.rounds, 2);
    expect(chain.stopReason, 'all_passed');
    expect(harness.support.sidecar.sendRequests.length, 3,
        reason: '乙只对甲那条反应一次；last-reacted-seq 失效会无限接话');
    expect(_requestsOf(harness, b).length, 2);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 关闭态只有被点名者跑（其它成员零消息行、零请求）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueFinal('甲的回复');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    final chain = await harness.waitForChain();
    final rows = await _rowsOf(harness);
    _obs('steps', _stepView(chain.steps));
    _obs('行', rows.map((row) => '${row.author ?? 'user'}:${row.content}').toList());
    expect(chain.status, 'completed');
    expect(chain.stopReason, 'no_members', reason: '安静态没有反应轮可跑');
    expect(chain.rounds, 0);
    expect(chain.steps.single.source, 'speaker');
    expect(rows.where((row) => row.author == b.id), isEmpty);
    expect(_requestsOf(harness, b), isEmpty);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 关闭态点名甲+@乙 ⇒ steps 甲 speaker / 乙 mention（两者都跑）', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueFinal('甲的普通回复');
    harness.queueReact(pass: false, message: '乙的强制回复');

    await harness.groups.send(
        groupId: harness.group.id, memberId: a.id, text: '甲先说，@乙 你怎么看');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    final steps = chain.steps;
    expect(steps.length, 2);
    expect(steps[0].memberId, a.id);
    expect(steps[0].source, 'speaker');
    expect(steps[0].status, 'replied');
    expect(steps[1].memberId, b.id);
    expect(steps[1].source, 'mention');
    expect(steps[1].status, 'replied');
    expect(steps[1].publicSeq, isNotNull);
    expect(chain.rounds, 0, reason: '安静态定向轮不计反应轮');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 关闭态 @mention 是强制轮：输出 [PASS] 记 forced_pass 且不写公开行', () async {
    final harness = await GroupHarness.create();
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueFinal('甲的普通回复');
    harness.queuePass(); // 乙被点名却 PASS

    await harness.groups.send(
        groupId: harness.group.id, memberId: a.id, text: '甲先说，@乙 表个态');
    final chain = await harness.waitForChain();
    final rows = await _rowsOf(harness);
    _obs('steps', _stepView(chain.steps));
    expect(chain.steps[1].status, 'forced_pass');
    expect(chain.steps[1].publicSeq, isNull);
    expect(rows.where((row) => row.author == b.id && row.visibility == 'public'),
        isEmpty, reason: '哨兵不进公开时间线');
    // forced_pass 不是整轮失败：不发 turn.failed。
    expect(harness.turnFailedEvents, isEmpty);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 开启态点名回复后接反应链', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲讲的笑话'); // speaker 强制轮
    harness.queueReact(pass: false, message: '乙的评价'); // 乙对甲那条的反应
    harness.queuePass(); // 甲对乙那条

    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲讲个笑话');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    final steps = chain.steps;
    expect(steps[0].memberId, a.id);
    expect(steps[0].source, 'speaker');
    expect(steps[0].status, 'replied');
    final reaction = steps.firstWhere((step) => step.source == 'reaction');
    expect(reaction.memberId, b.id);
    expect(reaction.status, 'replied');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.2 开启态 speaker PASS ⇒ 链从用户消息起，@mention 仍强制 (mention/replied)',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queuePass(); // 甲被点名却 PASS
    harness.queueReact(pass: false, message: '乙的具体回应'); // 乙被 @ 强制
    harness.queuePass(); // 甲对乙这条 PASS

    await harness.groups.send(
        groupId: harness.group.id, memberId: a.id, text: '@乙 具体说说哪里好笑');
    final chain = await harness.waitForChain();
    _obs('steps', _stepView(chain.steps));
    final steps = chain.steps;
    expect(steps[0].memberId, a.id);
    expect(steps[0].source, 'speaker');
    expect(steps[0].status, 'forced_pass');
    final bStep = steps.firstWhere((step) => step.memberId == b.id);
    expect(bStep.source, 'mention');
    expect(bStep.status, 'replied');
    expect(bStep.publicSeq, isNotNull);
    expect(steps.where((step) => step.status == 'forced_pass').length, 1,
        reason: '乙那条不是 forced_pass（它真的回应了）');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  // ---------------------------------------------------------------------------
  // 3.3 生命周期、失败与取消
  // ---------------------------------------------------------------------------

  test('R.8 链中再发被接受：两条用户消息都写入，第二条被吸收进反应', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲对第一条的反应');
    harness.queueReact(pass: false, message: '乙对第一条的反应');
    harness.queueReact(pass: false, message: '甲对第二条的反应');
    harness.queueReact(pass: false, message: '乙对第二条的反应');
    harness.queuePass(); // 第三轮（甲对乙那条）沉默，链自然停
    harness.support.sidecar.gateNextSend();

    final first = harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第一条');
    await _waitForRequests(harness, 1);
    final second = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第二条');
    _obs('第二条', '${second.status} ${second.error}');
    expect(second.status, 'started',
        reason: 'R.8：链运行中再发也接受，永不返回 busy');
    final userRowsDuring = (await _rowsOf(harness))
        .where((row) => row.role == 'user')
        .toList();
    _obs('链中用户消息', userRowsDuring.map((row) => row.content).toList());
    expect(userRowsDuring.length, 2,
        reason: '两条发送各自写入一条用户消息（不拒绝、不丢内容）');
    final secondUserSeq = userRowsDuring.last.seq!;

    harness.support.sidecar.releaseGate();
    final firstOutcome = await first;
    expect(firstOutcome.status, 'started');
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(chain.status, 'completed');
    // 吸收后新用户消息成为触发：至少有一个步骤的 triggerSeq 就是第二条用户消息。
    expect(chain.steps.any((step) => step.triggerSeq == secondUserSeq), isTrue,
        reason: '执行器在轮边界吸收了第二条用户消息');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.8 连发多条都接受（三条都 started、三条用户消息都写入）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    harness.queueReact(pass: true);
    harness.queueReact(pass: true);
    harness.queueReact(pass: true);
    harness.support.sidecar.gateNextSend();

    final first = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第一条');
    await _waitForRequests(harness, 1);
    final second = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第二条');
    final third = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第三条');
    _obs('三条回包', [first.status, second.status, third.status]);
    expect([first.status, second.status, third.status],
        everyElement('started'));
    final userRows = (await _rowsOf(harness))
        .where((row) => row.role == 'user')
        .toList();
    _obs('用户消息', userRows.map((row) => row.content).toList());
    expect(userRows.map((row) => row.content).toList(),
        ['第一条', '第二条', '第三条']);
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason}');
    expect(chain.status, 'completed');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.8 新用户触发重置预算：cap=1，新消息让反应再跑一轮', () async {
    final harness =
        await GroupHarness.create(reactionsEnabled: true, maxRounds: 1);
    await harness.addMember('甲');
    await harness.addMember('乙');
    // 第一条触发的轮（2 人）→ 吸收第二条 → 新预算再跑一轮（2 人）= 4 个反应。
    harness.queueReact(pass: false, message: '甲对第一条');
    harness.queueReact(pass: false, message: '乙对第一条');
    harness.queueReact(pass: false, message: '甲对第二条');
    harness.queueReact(pass: false, message: '乙对第二条');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第一条');
    await _waitForRequests(harness, 1);
    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '第二条');
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} rounds=${chain.rounds} '
        '${_stepView(chain.steps)}');
    expect(chain.stopReason, 'round_cap');
    expect(chain.steps.length, 4,
        reason: 'cap=1 是**每条用户触发**的预算：新消息重置后应再跑一轮（2 步）');
    expect(chain.rounds, 1, reason: 'rounds 是当前（最新）用户触发的已耗轮数');
    // 两轮分别对应两条用户消息的 seq。
    final userRows = (await _rowsOf(harness))
        .where((row) => row.role == 'user')
        .toList();
    final firstSeq = userRows.first.seq!;
    final secondSeq = userRows.last.seq!;
    expect(chain.steps.where((step) => step.triggerSeq == firstSeq).length, 2);
    expect(chain.steps.where((step) => step.triggerSeq == secondSeq).length, 2);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('R.8 取消会清空排队：链中排队的定向请求不再执行', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '链在跑');
    await _waitForRequests(harness, 1);
    // 排队一条定向请求（乙），随后取消：它必须被清掉。
    final queued = await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙插一句');
    expect(queued.status, 'started');
    final cancel = await harness.groups.cancel(harness.group.id);
    expect(cancel.reactionChainStopped, isTrue);
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(chain.status, 'cancelled');
    expect(_requestsOf(harness, b), isEmpty, reason: '取消清空排队：乙一次都不跑');
    // 已写入的用户消息保留（用户可重发）。
    final userRows = (await _rowsOf(harness))
        .where((row) => row.role == 'user')
        .toList();
    expect(userRows.map((row) => row.content).toList(), ['链在跑', '乙插一句']);
    expect(_requestsOf(harness, a).length, 1, reason: '甲被取消的那一轮记录仍在');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 取消停链：后续成员零调用、链状态 cancelled', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    final cancel = await harness.groups.cancel(harness.group.id);
    _obs('取消结果', cancel.toJson());
    expect(cancel.cancelled, isTrue);
    expect(cancel.reactionChainStopped, isTrue);
    expect(cancel.memberId, a.id);

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(_requestsOf(harness, b), isEmpty, reason: '链停：乙一轮都不跑');
    expect(chain.status, 'cancelled');
    expect(chain.stopReason, 'cancelled');
    expect(chain.steps.last.status, 'cancelled');
    // 链结束事件带 cancelled。
    expect(harness.chainEvents.single.stopReason, 'cancelled');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 取消后 group.chain 的状态是 cancelled（不是 completed）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.support.sidecar.gateNextSend();
    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    await harness.groups.cancel(harness.group.id);
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('取消后的链', 'status=${chain.status} stopReason=${chain.stopReason}');
    expect(chain.status, 'cancelled');
    expect(kGroupChainStatuses, contains(chain.status));
    expect(chain.stopReason, 'cancelled');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 带 memberId 取消链中排队成员 ⇒ cancelled:false + reactionChainStopped:true',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    final cancel = await harness.groups.cancel(harness.group.id, memberId: b.id);
    _obs('取消排队成员', cancel.toJson());
    expect(cancel.cancelled, isFalse, reason: '它确实没在运行：不谎报 cancelled');
    expect(cancel.reactionChainStopped, isTrue);
    expect(cancel.memberId, b.id);

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status} ${_stepView(chain.steps)}');
    expect(_requestsOf(harness, b), isEmpty);
    expect(chain.steps.length, 1, reason: '只有甲那一步跑完，乙不再开始');
    expect(chain.steps.single.memberId, a.id);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 带 memberId 取消链外未运行成员 ⇒ 不冒领停链，链继续', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.queuePass();
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    // 链开始后才加入的成员：不在链的参与快照里（也不在运行）。
    final late = await harness.addMember('丙');
    final cancel = await harness.groups.cancel(harness.group.id, memberId: late.id);
    _obs('取消链外成员', cancel.toJson());
    expect(cancel.cancelled, isFalse);
    expect(cancel.reactionChainStopped, isFalse);

    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status} ${_stepView(chain.steps)}');
    expect(chain.steps.any((step) => step.memberId == b.id), isTrue,
        reason: '链继续：乙仍然跑');
    expect(_requestsOf(harness, late), isEmpty, reason: '中途加入的成员不进当前链');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 成员失败中止链（有公开 Error 行，不再引发下一轮）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.support.sidecar.queueDone(code: 1, error: 'provider boom');

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    final chain = await harness.waitForChain();
    final rows = await _rowsOf(harness);
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    _obs('公开行', rows
        .where((row) => row.visibility == 'public')
        .map((row) => '${row.author ?? 'user'}:${row.content}')
        .toList());
    expect(chain.status, 'failed');
    expect(chain.stopReason, 'failed');
    expect(chain.steps.single.status, 'failed');
    expect(chain.steps.single.memberId, a.id);
    expect(_requestsOf(harness, b), isEmpty, reason: '失败中止链：乙不跑');
    // 硬失败发 turn.failed（带 memberId）。
    expect(harness.turnFailedEvents.single.step.memberId, a.id);
    // 错误行留在时间线（诚实），但它不再触发下一轮。
    final errorRows = rows.where((row) =>
        row.visibility == 'public' && row.content.contains('Error:'));
    expect(errorRows, isNotEmpty, reason: 'provider 报错路径会写公开 Error 行');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 无错误行的失败也中止链（假 sidecar 注入 send 抛错）', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.support.sidecar.nextSendError = Exception('unexpected boom');

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    final chain = await harness.waitForChain();
    final rows = await _rowsOf(harness);
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(chain.status, 'failed');
    expect(chain.stopReason, 'failed');
    expect(chain.steps.single.memberId, a.id);
    expect(chain.steps.single.error, contains('未预期异常'));
    expect(_requestsOf(harness, b), isEmpty);
    expect(
        rows.where((row) =>
            row.visibility == 'public' && row.content.contains('Error:')),
        isEmpty,
        reason: '未预期异常路径不写公开错误行，但同样中止链并可归因');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 链中移除成员先停链', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    // 停链是同步的，但 `removeMember` 会等当前轮收尾（它挂在 gate 上）——先排一个
    // 到点释放 gate 的定时器，再 await（否则测试自己死锁）。
    final removal = harness.groups.removeMember(harness.group.id, a.id);
    final releaseTimer = Timer(const Duration(milliseconds: 30),
        () => harness.support.sidecar.releaseGate());
    await removal;
    releaseTimer.cancel();
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status}/${chain.stopReason} ${_stepView(chain.steps)}');
    expect(_requestsOf(harness, b), isEmpty, reason: '移除成员先停链：乙不再开始');
    expect(chain.status, 'cancelled');
    expect(harness.agents.lookup(a.handle), isNull);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 链中编辑成员先停链', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    final update = harness.groups
        .updateMember(groupId: harness.group.id, memberId: b.id, name: '乙二');
    final releaseTimer = Timer(const Duration(milliseconds: 30),
        () => harness.support.sidecar.releaseGate());
    await update;
    releaseTimer.cancel();
    harness.support.sidecar.releaseGate();
    final chain = await harness.waitForChain();
    _obs('链终态', '${chain.status} ${_stepView(chain.steps)}');
    expect(_requestsOf(harness, b), isEmpty,
        reason: '编辑成员先停链：旧实例被销毁、链不再调用它');
    expect(chain.status, 'cancelled');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 链中删组先停链', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queueReact(pass: false, message: '乙不该跑');
    harness.support.sidecar.gateNextSend();

    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    final delete = harness.groups.deleteGroup(harness.group.id);
    final releaseTimer = Timer(const Duration(milliseconds: 30),
        () => harness.support.sidecar.releaseGate());
    await delete;
    releaseTimer.cancel();
    harness.support.sidecar.releaseGate();
    // 组删了：链状态随之移除（没有可查的组）。
    await harness.groups.waitForChain(harness.group.id);
    expect(_requestsOf(harness, b), isEmpty);
    expect(await harness.support.sessionRepo.get(harness.group.id), isNull);
    expect(harness.agents.lookup(a.handle), isNull);
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 不并行：同一时刻至多一个成员在流式运行', () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    await harness.addMember('甲');
    await harness.addMember('乙');
    harness.queueReact(pass: false, message: '甲的回复');
    harness.queuePass();
    harness.support.sidecar.gateNextSend();
    harness.support.sidecar.gateNextSend();

    var maxConcurrent = 0;
    var polling = true;
    final poller = () async {
      while (polling) {
        final running =
            harness.agents.instances.where((agent) => agent.isStreaming).length;
        if (running > maxConcurrent) maxConcurrent = running;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }();
    await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(harness, 1);
    harness.support.sidecar.releaseGate();
    await _waitForRequests(harness, 2);
    harness.support.sidecar.releaseGate();
    await harness.waitForChain();
    polling = false;
    await poller;
    _obs('峰值并发流式成员数', maxConcurrent);
    expect(maxConcurrent, 1, reason: '链 SHALL NOT 并行运行成员');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.3 steps 状态词表：empty/cancelled/failed/forced_pass/forced_empty 各有可失败断言',
      () async {
    // 每个子场景用独立组，避免排队串味。
    // ① empty：开启态自愿轮空输出
    final emptyHarness = await GroupHarness.create(reactionsEnabled: true);
    await emptyHarness.addMember('甲');
    emptyHarness.queueReact(pass: false, message: '');
    await emptyHarness.groups
        .send(groupId: emptyHarness.group.id, memberId: null, text: '说点什么');
    final emptyChain = await emptyHarness.waitForChain();
    _obs('empty 场景', _stepView(emptyChain.steps));
    expect(emptyChain.steps.single.status, 'empty');
    expect(emptyChain.steps.single.publicSeq, isNull);
    await emptyHarness.dispose();

    // ② forced_pass / forced_empty：开启态 speaker 强制轮
    final forcedHarness = await GroupHarness.create(reactionsEnabled: true);
    final speaker = await forcedHarness.addMember('甲');
    forcedHarness.queuePass();
    await forcedHarness.groups.send(
        groupId: forcedHarness.group.id, memberId: speaker.id, text: '甲你来说');
    final forcedPass = await forcedHarness.waitForChain();
    _obs('forced_pass 场景', _stepView(forcedPass.steps));
    expect(forcedPass.steps.first.status, 'forced_pass');
    forcedHarness.queueReact(pass: false, message: '');
    await forcedHarness.groups.send(
        groupId: forcedHarness.group.id, memberId: speaker.id, text: '甲你再说');
    final forcedEmpty = await forcedHarness.waitForChain();
    _obs('forced_empty 场景', _stepView(forcedEmpty.steps));
    expect(forcedEmpty.steps.first.status, 'forced_empty');
    await forcedHarness.dispose();

    // ③ failed：provider 报错
    final failedHarness = await GroupHarness.create(reactionsEnabled: true);
    await failedHarness.addMember('甲');
    failedHarness.support.sidecar.queueDone(code: 1, error: 'provider boom');
    await failedHarness.groups
        .send(groupId: failedHarness.group.id, memberId: null, text: '说点什么');
    final failed = await failedHarness.waitForChain();
    _obs('failed 场景', _stepView(failed.steps));
    expect(failed.steps.single.status, 'failed');
    expect(failed.status, 'failed');
    await failedHarness.dispose();

    // ④ cancelled：链中取消
    final cancelledHarness = await GroupHarness.create(reactionsEnabled: true);
    await cancelledHarness.addMember('甲');
    cancelledHarness.queueReact(pass: false, message: '不该跑完');
    cancelledHarness.support.sidecar.gateNextSend();
    await cancelledHarness.groups
        .send(groupId: cancelledHarness.group.id, memberId: null, text: '说点什么');
    await _waitForRequests(cancelledHarness, 1);
    await cancelledHarness.groups.cancel(cancelledHarness.group.id);
    cancelledHarness.support.sidecar.releaseGate();
    final cancelled = await cancelledHarness.waitForChain();
    _obs('cancelled 场景', _stepView(cancelled.steps));
    expect(cancelled.steps.single.status, 'cancelled');
    expect(cancelled.status, 'cancelled');
    await cancelledHarness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  // ---------------------------------------------------------------------------
  // 3.4 用户消息、标题与事件
  // ---------------------------------------------------------------------------

  test('3.4 开启态有/无 speaker 两条路径都只写一次用户消息 + onUserMessage 带 groupId',
      () async {
    final harness = await GroupHarness.create(reactionsEnabled: true);
    final a = await harness.addMember('甲');
    harness.queueReact(pass: false, message: '甲讲的笑话'); // speaker 强制轮
    harness.queuePass(); // 下一轮（若被选中）

    // 路径一：带 speaker。
    final withSpeaker = await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    await harness.waitForChain();
    var userRows = (await _rowsOf(harness)).where((row) => row.role == 'user');
    _obs('带 speaker 用户行', userRows.map((row) => row.content).toList());
    expect(userRows.length, 1);
    expect(harness.userMessageEvents.length, 1);
    expect(harness.userMessageEvents.single.groupId, harness.group.id);
    expect(harness.userMessageEvents.single.message.author, isNull,
        reason: '用户消息没有成员作者（不伪造 memberId）');
    expect(withSpeaker.triggerSeq, isNotNull);

    // 路径二：不带 speaker（等待上一条链收尾后再发）。
    harness.queuePass();
    final withoutSpeaker = await harness.groups
        .send(groupId: harness.group.id, memberId: null, text: '大家怎么看');
    await harness.waitForChain();
    userRows = (await _rowsOf(harness)).where((row) => row.role == 'user');
    _obs('两条路径后用户行', userRows.map((row) => row.content).toList());
    expect(userRows.length, 2, reason: '每次发送只写一次用户消息（两次发送共两条）');
    expect(harness.userMessageEvents.length, 2);
    final lastUser = userRows.last;
    expect(withoutSpeaker.triggerSeq, lastUser.seq,
        reason: 'seq 作为首个 triggerSeq');
    await harness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));

  test('3.4 新组首条消息自动命名；用户已命名的组不被改名', () async {
    // 缺省标题「新组」⇒ 首条消息命名。
    final newHarness = await GroupHarness.create(
        createGroup: false, reactionsEnabled: true);
    final created = await newHarness.groups.createGroup();
    newHarness.group = created;
    await newHarness.groups
        .addMember(groupId: created.id, name: '甲', templateName: 'general');
    newHarness.queuePass();
    await newHarness.groups.send(
        groupId: created.id, memberId: null, text: '这是第一条用户消息，应该变成标题');
    final createdChain = await newHarness.waitForChain(created.id);
    expect(createdChain.status, 'completed');
    final reread = await newHarness.support.sessionRepo.get(created.id);
    _obs('新组标题', reread?.title);
    expect(reread!.title, isNot('新组'), reason: '缺省标题必须被首条消息替换');
    expect(reread.title, startsWith('这是第一条用户消息'));
    expect(newHarness.titleEvents, isNotEmpty, reason: '标题变化要发回调');
    expect(newHarness.titleEvents.last.groupId, created.id);
    await newHarness.dispose();

    // 用户已命名 ⇒ 不改。
    final namedHarness = await GroupHarness.create(
        groupTitle: '我的组名', reactionsEnabled: true);
    await namedHarness.addMember('甲');
    namedHarness.queuePass();
    await namedHarness.groups
        .send(groupId: namedHarness.group.id, memberId: null, text: '随便一条消息');
    await namedHarness.waitForChain();
    final named = await namedHarness.support.sessionRepo.get(namedHarness.group.id);
    _obs('已命名组的标题', named?.title);
    expect(named!.title, '我的组名', reason: '用户已命名的组不许被首条消息改名');
    expect(namedHarness.titleEvents, isEmpty);
    await namedHarness.dispose();
  }, timeout: Timeout(kReactionSchedulingTimeout));
}
