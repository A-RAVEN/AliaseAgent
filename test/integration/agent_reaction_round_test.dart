// Agent 反应轮的结构化 PASS（change `group-reactive-mode` R.10 / design D5、D6）。
//
// 这里把 `Agent.send` 单独拿出来测（不经过组调度器）：
//   - 反应轮（`reaction: true`）⇒ 注入 `group_react` 终态工具、按 `pass`/`message` 判定；
//   - 普通轮（单会话 / 关闭态纯 speaker）⇒ 行为**逐字不变**（不注入、不看 pass，
//     `[PASS]` 是普通正文）。
//
// 隔离：`GroupTestSupport`（临时 configPath / attachmentsDir / 数据库 / lock / 工作区 +
// 假 sidecar），绝不写用户真实 `~/.aliasagent`。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/group_prompts.dart';
import 'package:alias_agent/services/group_reaction.dart';

import 'group_harness.dart';

/// 一行消息的摘要（观测用）。
String _rowsSummary(List<dynamic> rows) => rows
    .map((row) => '[${row.role}/${row.visibility}/author=${row.author}]'
        '「${row.content}」')
    .join(' | ');

/// 直接排一个参数非法的 `group_react`（解析器要判 `invalid_group_react`）。
void _queueRawReact(GroupHarness harness, Map<String, dynamic> input) {
  harness.support.sidecar.queueToolCall(jsonEncode({
    'type': 'tool_use',
    'id': 'gr-raw',
    'name': 'group_react',
    'input': input,
  }));
  harness.support.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
}

void main() {
  /// 建组 + 一个成员，返回该成员的实例与组 id。
  Future<({GroupHarness harness, String groupId, String memberId, Agent agent})>
      setUpMember({String groupTitle = '反应组'}) async {
    final harness = await GroupHarness.create(groupTitle: groupTitle);
    final member = await harness.addMember('甲');
    final groupId = harness.group.id;
    // 先种一条用户公开消息：成员视图非空，请求里才有真实投影。
    await harness.support.messageRepo.insert(
      sessionId: groupId,
      role: 'user',
      content: '用户说：讲个笑话',
    );
    final agent = await harness.groups.ensureMemberAgent(member);
    return (harness: harness, groupId: groupId, memberId: member.id, agent: agent);
  }

  test('pass=true 吞掉元话术、不写公开行；私有工具行仍在', () async {
    final env = await setUpMember();
    // 一轮工具轮（私有思考 + 工具调用）→ 终态调用 group_react {pass:true}。
    env.harness.queueToolTurn(
      toolName: 'read_file',
      id: 't-pass',
      input: {'path': 'lib/a.dart'},
      thinking: '我要不要接话？没有贡献。',
    );
    env.harness.queueReact(
      pass: true,
      message: '我这回合不发言，等其它模型',
      thinking: '沉默是常态。',
    );

    final result = await env.agent.send(
      '',
      writeUserMessage: false,
      reaction: true,
    );
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] status=${result.status} reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage} finalText="${result.finalText}"');
    // ignore: avoid_print
    print('[OBS] 行 => ${_rowsSummary(rows)}');

    expect(result.reactionPassed, isTrue, reason: '结构化 pass=true ⇒ 沉默');
    expect(result.publicMessage, isNull, reason: 'pass=true 不该写公开行');
    expect(result.finalText, '我这回合不发言，等其它模型',
        reason: 'finalText 保留 message 供观察，但时间线看不到');
    final publicRows =
        rows.where((row) => row.visibility == 'public').toList();
    expect(publicRows.any((row) => row.content.contains('不发言')), isFalse,
        reason: '元话术不得进入公开时间线');
    expect(publicRows.any((row) => row.author == env.memberId), isFalse,
        reason: '该成员这一轮没有任何公开行');
    // 私有工具行仍在（作者 = 该成员、private-to-author）。
    final privateRows = rows
        .where((row) =>
            row.author == env.memberId && row.visibility == 'private-to-author')
        .toList();
    expect(privateRows, isNotEmpty, reason: '沉默轮的私有工具行必须照常落库');
    expect('${privateRows.first.toolCallsJson}', contains('read_file'));
    await env.harness.dispose();
  });

  test('正文写「我选择 PASS」但 pass=true ⇒ 以结构化标记为准（沉默）', () async {
    final env = await setUpMember();
    env.harness.support.sidecar.queueChunk('我选择 PASS，等大家。');
    env.harness.queueReact(pass: true, message: '');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage} 行 => ${_rowsSummary(rows)}');
    expect(result.reactionPassed, isTrue);
    expect(result.publicMessage, isNull);
    expect(rows.any((row) => row.content.contains('我选择 PASS')), isFalse,
        reason: '正文里的 PASS 叙述不进入时间线');
    await env.harness.dispose();
  });

  test('正文含 [PASS] 但 pass=false ⇒ 按 message 公开（正文不进入公开行）', () async {
    final env = await setUpMember();
    env.harness.support.sidecar.queueChunk('[PASS] 这个词只是我在引用哨兵');
    env.harness.queueReact(pass: false, message: '我认为路径应改成 lib/b.dart');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage?.content}');
    expect(result.reactionPassed, isFalse);
    expect(result.publicMessage!.content, '我认为路径应改成 lib/b.dart');
    expect(rows.any((row) => row.content.contains('[PASS]')), isFalse,
        reason: '正文（含字面 [PASS]）不进入公开行，只有 message 会');
    await env.harness.dispose();
  });

  test('pass=false 的公开行只写 message（不是正文解释）', () async {
    final env = await setUpMember();
    env.harness.support.sidecar.queueChunk('先解释一大段理由……');
    env.harness.queueReact(pass: false, message: '结论：改用 lib/b.dart');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    final publicRows = rows.where((row) =>
        row.author == env.memberId && row.visibility == 'public');
    // ignore: avoid_print
    print('[OBS] 公开行 => ${publicRows.map((row) => row.content).toList()}');
    expect(publicRows.length, 1);
    expect(publicRows.single.content, '结论：改用 lib/b.dart');
    expect(result.publicMessage!.content, '结论：改用 lib/b.dart');
    await env.harness.dispose();
  });

  test('pass=false + 空 message ⇒ 空输出（不写公开行、不算 passed）', () async {
    final env = await setUpMember();
    env.harness.queueReact(pass: false, message: '   ');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    final publicOfMember = rows.where((row) =>
        row.author == env.memberId && row.visibility == 'public');
    // ignore: avoid_print
    print('[OBS] reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage} 公开行=${publicOfMember.length}');
    expect(result.publicMessage, isNull, reason: '空 message 不写公开行');
    expect(result.reactionPassed, isFalse, reason: '空输出是 empty，不是 passed');
    expect(publicOfMember, isEmpty);
    await env.harness.dispose();
  });

  test('缺 group_react 先纠正重试：第二次合规 ⇒ 正常 replied（不是 failed）', () async {
    final env = await setUpMember();
    // 第一次：只有正文、没有调用 group_react（触发纠正）。
    env.harness.queueFinal('我先想想怎么说。');
    // 第二次：正确调用。
    env.harness.queueReact(pass: false, message: '纠正后的公开回复');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    final sends = env.harness.support.sidecar.sendRequests
        .where((request) => request.handle == env.agent.handle)
        .length;
    // ignore: avoid_print
    print('[OBS] 重试后 status=${result.status} 请求数=$sends '
        'public=${result.publicMessage?.content} 行 => ${_rowsSummary(rows)}');
    expect(sends, 2, reason: '缺调用应追加一次纠正请求（初始 + 1 次重试）');
    expect(result.isCompleted, isTrue, reason: '重试合规后应正常完成');
    expect(result.publicMessage!.content, '纠正后的公开回复');
    expect(result.reactionPassed, isFalse);
    expect(rows.any((row) => row.content == '我先想想怎么说。'), isFalse,
        reason: '不合规那次的正文不写公开行');
    await env.harness.dispose();
  });

  test('缺 group_react 重试超限 ⇒ failed missing_group_react（保留可失败性）', () async {
    final env = await setUpMember();
    // 首次 + kMaxGroupReactRetries 次重试，全都不调用工具。
    for (var i = 0; i <= kMaxGroupReactRetries; i++) {
      env.harness.queueFinal('第 $i 次仍然没有调用工具');
    }
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final sends = env.harness.support.sidecar.sendRequests
        .where((request) => request.handle == env.agent.handle)
        .length;
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] 超限 status=${result.status} error=${result.error} 请求数=$sends');
    expect(result.isFailed, isTrue);
    expect(result.error, kMissingGroupReactError);
    expect(sends, 1 + kMaxGroupReactRetries,
        reason: '初始请求 + 上限次数的纠正重试，超过就 failed');
    expect(rows.where((row) => row.author == env.memberId), isEmpty,
        reason: '超限失败不写公开行');
    await env.harness.dispose();
  });

  test('参数非法先纠正重试：第二次合规 ⇒ 正常完成', () async {
    final env = await setUpMember();
    _queueRawReact(env.harness, {'pass': 'true', 'message': ''});
    env.harness.queueReact(pass: false, message: '重试后的合法内容');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    // ignore: avoid_print
    print('[OBS] 非法重试 status=${result.status} '
        'public=${result.publicMessage?.content}');
    expect(result.isCompleted, isTrue);
    expect(result.publicMessage!.content, '重试后的合法内容');
    await env.harness.dispose();
  });

  test('参数非法重试超限 ⇒ failed invalid_group_react', () async {
    final env = await setUpMember();
    for (var i = 0; i <= kMaxGroupReactRetries; i++) {
      _queueRawReact(env.harness, {'pass': i, 'message': i});
    }
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    // ignore: avoid_print
    print('[OBS] 非法超限 status=${result.status} error=${result.error}');
    expect(result.isFailed, isTrue);
    expect(result.error, kInvalidGroupReactError);
    await env.harness.dispose();
  });

  test('纠正重试不泄漏元话术：首次说「我这回合不发言」，重试 pass=true ⇒ 时间线无它', () async {
    final env = await setUpMember();
    env.harness.queueFinal('我这回合不发言，等其它模型。');
    env.harness.queueReact(pass: true, message: '我这回合不发言，等其它模型。');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] reactionPassed=${result.reactionPassed} '
        '公开行=${_rowsSummary(rows.where((row) => row.visibility == 'public').toList())}');
    expect(result.reactionPassed, isTrue);
    expect(result.publicMessage, isNull);
    expect(rows.any((row) => row.content.contains('我这回合不发言')), isFalse,
        reason: '纠正前的元话术与 pass=true 的 message 都不得进时间线');
    await env.harness.dispose();
  });

  test('强制轮纠正重试后 pass=true ⇒ 仍记 forced_pass 的 Agent 侧', () async {
    final env = await setUpMember();
    env.harness.queueFinal('我先写一句正文。');
    env.harness.queueReact(pass: true, message: '被点名也还是没话说');
    final result = await env.agent.send(
      '',
      writeUserMessage: false,
      reaction: true,
      mustRespond: true,
    );
    // ignore: avoid_print
    print('[OBS] 强制轮重试 reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage}');
    expect(result.reactionPassed, isTrue);
    expect(result.publicMessage, isNull);
    await env.harness.dispose();
  });

  test('缺 group_react 重试超限 ⇒ failed missing_group_react 且不写公开行', () async {
    final env = await setUpMember();
    for (var i = 0; i <= kMaxGroupReactRetries; i++) {
      env.harness.queueFinal('我觉得这里可以直接说，但我没调用工具');
    }
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] status=${result.status} error=${result.error} '
        'reactionPassed=${result.reactionPassed}');
    expect(result.isFailed, isTrue);
    expect(result.error, kMissingGroupReactError);
    expect(result.publicMessage, isNull);
    expect(rows.where((row) => row.author == env.memberId), isEmpty,
        reason: '缺工具不写公开行，也不写公开 Error 行');
    await env.harness.dispose();
  });

  test('参数非法重试超限 ⇒ failed invalid_group_react（不回退文本匹配）', () async {
    final env = await setUpMember();
    for (var i = 0; i <= kMaxGroupReactRetries; i++) {
      _queueRawReact(env.harness, {'pass': 'true', 'message': ''});
    }
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] status=${result.status} error=${result.error}');
    expect(result.isFailed, isTrue);
    expect(result.error, kInvalidGroupReactError);
    expect(rows.where((row) => row.author == env.memberId), isEmpty);
    await env.harness.dispose();
  });

  test('同一轮多次调用重试超限 ⇒ failed invalid_group_react', () async {
    final env = await setUpMember();
    for (var i = 0; i <= kMaxGroupReactRetries; i++) {
      env.harness.support.sidecar
          .queueGroupReact(pass: true, message: '');
      env.harness.support.sidecar
          .queueGroupReact(pass: false, message: '又说一句');
      env.harness.support.sidecar.queueDone(inputTokens: 1, outputTokens: 1);
    }
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    expect(result.isFailed, isTrue);
    // ignore: avoid_print
    print('[OBS] 多次调用的错误=${result.error}');
    expect(result.error, kInvalidGroupReactError);
    await env.harness.dispose();
  });

  test('强制轮 pass=true ⇒ reactionPassed（上层记 forced_pass）', () async {
    final env = await setUpMember();
    env.harness.queueReact(pass: true, message: '被点名了但还是没话说');
    final result = await env.agent.send(
      '',
      writeUserMessage: false,
      reaction: true,
      mustRespond: true,
    );
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] 强制轮 pass=true reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage}');
    expect(result.reactionPassed, isTrue);
    expect(result.publicMessage, isNull, reason: '强制轮 pass=true 也不写公开行');
    expect(rows.where((row) => row.author == env.memberId), isEmpty);
    await env.harness.dispose();
  });

  test('强制轮 pass=false + 空 message ⇒ forced_empty 的 Agent 侧', () async {
    final env = await setUpMember();
    env.harness.queueReact(pass: false, message: '');
    final result = await env.agent.send(
      '',
      writeUserMessage: false,
      reaction: true,
      mustRespond: true,
    );
    // ignore: avoid_print
    print('[OBS] reactionPassed=${result.reactionPassed} '
        'publicMessage=${result.publicMessage}');
    expect(result.publicMessage, isNull);
    expect(result.reactionPassed, isFalse);
    await env.harness.dispose();
  });

  test('group_react 与普通工具同轮出现时以 group_react 为终态（不执行普通工具）', () async {
    final env = await setUpMember();
    // 同一轮里先排一个普通工具调用，再排 group_react（终态）：后者截断本轮。
    env.harness.support.sidecar.queueToolCall(
        '{"type":"tool_use","id":"t-other","name":"read_file","input":{"path":"lib/a.dart"}}');
    env.harness.queueReact(pass: false, message: '只公开 message');
    final result = await env.agent
        .send('', writeUserMessage: false, reaction: true);
    final rows =
        await env.harness.support.messageRepo.queryBySession(env.groupId);
    // ignore: avoid_print
    print('[OBS] 工具调用记录=${env.harness.support.sidecar.toolCalls} '
        '公开行=${result.publicMessage?.content}');
    expect(result.publicMessage!.content, '只公开 message');
    expect(env.harness.support.sidecar.toolCalls, isEmpty,
        reason: 'group_react 是终态控制工具：同轮的普通工具不执行');
    expect(rows.any((row) => row.visibility == 'private-to-author'), isFalse,
        reason: 'group_react 不写 tool 行');
    await env.harness.dispose();
  });

  test('普通轮不注入 group_react，[PASS] 按旧行为是普通正文', () async {
    // 单会话（非成员）实例：走 `_callModel` 的普通路径。
    final support = await GroupHarness.create(createGroup: false);
    final session = await support.support.sessionRepo
        .create(title: '单会话', kind: Session.kindSingle);
    final agent = await support.factory.create(session);
    support.queueFinal(kGroupPassSentinel);
    final result = await agent.send('用户说一句');
    final rows = await support.support.messageRepo.queryBySession(session.id);
    final toolsJson = support.support.sidecar.lastToolsJson ?? '';
    // ignore: avoid_print
    print('[OBS] 普通轮 toolsJson 含 group_react？'
        '${toolsJson.contains('group_react')} 公开行=${result.publicMessage?.content}');
    expect(toolsJson, isNot(contains(kGroupReactToolName)),
        reason: '普通轮不注入终态控制工具');
    expect(result.reactionPassed, isFalse);
    expect(result.publicMessage!.content, kGroupPassSentinel,
        reason: '普通轮 [PASS] 仍是普通正文');
    expect(rows.where((row) => row.content == kGroupPassSentinel), isNotEmpty);
    await support.dispose();
  });

  test('关闭态纯 speaker 输出 [PASS] 按普通正文落公开行（组服务真实路径）', () async {
    final harness = await GroupHarness.create(groupTitle: '安静组');
    final member = await harness.addMember('甲');
    harness.queueFinal(kGroupPassSentinel);
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '甲你说说');
    final chain = await harness.waitForChain();
    final rows =
        await harness.support.messageRepo.queryBySession(harness.group.id);
    final publicOfMember = rows.where((row) =>
        row.author == member.id && row.visibility == 'public');
    // ignore: avoid_print
    print('[OBS] 关闭态纯点名 status=${chain.status} '
        '公开行=${publicOfMember.map((row) => row.content).toList()}');
    expect(publicOfMember.length, 1,
        reason: '关闭态纯 speaker 不做结构化判定：哨兵是普通正文');
    expect(publicOfMember.single.content, kGroupPassSentinel);
    expect(harness.support.sidecar.lastToolsJson,
        isNot(contains(kGroupReactToolName)));
    expect(harness.support.sidecar.lastSystemPrompt,
        isNot(contains(kGroupReactionPrompt)));
    expect(harness.support.sidecar.lastSystemPrompt,
        isNot(contains(kGroupMustRespondPrompt)));
    await harness.dispose();
  });

  test('反应轮注入 group_react；mustRespond 轮用必应常量、自愿轮用反应常量', () async {
    final mustEnv = await setUpMember();
    mustEnv.harness.queueReact(pass: false, message: '实质回应');
    await mustEnv.agent.send(
      '',
      writeUserMessage: false,
      reaction: true,
      mustRespond: true,
    );
    final mustPrompt = mustEnv.harness.support.sidecar.lastSystemPrompt!;
    final mustTools = mustEnv.harness.support.sidecar.lastToolsJson!;
    // ignore: avoid_print
    print('[OBS] mustRespond tools 含 group_react？'
        '${mustTools.contains(kGroupReactToolName)}');
    expect(mustPrompt, contains(kGroupMustRespondPrompt));
    expect(mustPrompt, isNot(contains(kGroupReactionPrompt)));
    expect(mustPrompt, contains(kGroupMemberRolePrompt));
    expect(mustTools, contains(kGroupReactToolName),
        reason: '强制轮同样注入终态工具（pass=true 记 forced_pass）');
    await mustEnv.harness.dispose();

    final selfEnv = await setUpMember();
    selfEnv.harness.queuePass();
    await selfEnv.agent.send('', writeUserMessage: false, reaction: true);
    final selfPrompt = selfEnv.harness.support.sidecar.lastSystemPrompt!;
    final selfTools = selfEnv.harness.support.sidecar.lastToolsJson!;
    expect(selfPrompt, contains(kGroupReactionPrompt));
    expect(selfPrompt, isNot(contains(kGroupMustRespondPrompt)));
    expect(selfPrompt, contains(kGroupMemberRolePrompt));
    expect(selfTools, contains(kGroupReactToolName));
    await selfEnv.harness.dispose();
  });

  test('反应轮快照可观察：contextSnapshot 的 systemPrompt 含追加常量', () async {
    final env = await setUpMember();
    env.harness.queueReact(pass: false, message: '我的公开回复');
    await env.agent
        .send('', writeUserMessage: false, reaction: true, mustRespond: true);
    final snapshot = env.agent.contextSnapshot;
    // ignore: avoid_print
    print('[OBS] 快照 systemPrompt 长度=${snapshot?.systemPrompt.length}');
    expect(snapshot, isNotNull);
    expect(snapshot!.systemPrompt, contains(kGroupMustRespondPrompt),
        reason: '快照必须是本轮真实发出的那份上下文');
    expect(snapshot.systemPrompt, contains(kGroupMemberRolePrompt));
    expect(snapshot.toolsJson, contains(kGroupReactToolName),
        reason: '快照的工具清单也必须含真实注入的 group_react');
    await env.harness.dispose();
  });
}
