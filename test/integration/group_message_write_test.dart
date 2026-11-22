// 组成员写入的落库形状（change `agent-group-chat` 任务 4.3 / design D1、D12 /
// spec「单一共享原文」）。
//
// 四条断言：
//   ① 组成员的**最终公开行只存正文**：`tool_calls` 与 `thinking_json` 均为 NULL、无附件；
//   ② 私有中间行同时带 thinking 与工具证据（visibility = private-to-author）；
//   ③ 单会话最终行行为不变（仍写 thinking 与聚合工具）；
//   ④ 用户行的 author 为 NULL。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/agent.dart';

import 'group_harness.dart';

void main() {
  test('① 组公开行两个 JSON 列均 NULL、无附件；② 私有行带工具与思考证据', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');

    // 一轮：thinking + 一次工具调用 → 最终公开回复。
    harness.queueToolTurn(
      toolName: 'read_file',
      id: 'tool-1',
      input: const {'path': 'lib/a.dart'},
      thinking: '甲的私有思考 A-THINK',
      stubResult: '{"ok":true,"content":"A 的内容 A-RESULT"}',
    );
    harness.queueFinal('甲的公开结论：lib/a.dart 已看过', thinking: '最终轮的私有思考');
    final outcome = await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '甲看一下 lib/a.dart');
    expect(outcome.status, 'completed');

    final rows =
        await harness.support.messageRepo.queryBySession(harness.group.id);
    final userRow = rows.singleWhere((r) => r.role == 'user');
    final publicRows = rows
        .where((r) => r.role == 'assistant' && !r.isPrivate)
        .toList();
    final privateRows =
        rows.where((r) => r.role == 'assistant' && r.isPrivate).toList();
    // ignore: avoid_print
    print('[OBS] 用户行 author=${userRow.author} visibility=${userRow.visibility}');
    // ignore: avoid_print
    print('[OBS] 公开行=${publicRows.map((r) => 'author=${r.author} '
        'tools=${r.toolCallsJson} thinking=${r.thinkingJson} '
        'attachments=${r.attachments}')}');
    // ignore: avoid_print
    print('[OBS] 私有行=${privateRows.map((r) => 'author=${r.author} '
        'visibility=${r.visibility} tools=${r.toolCallsJson != null} '
        'thinking=${r.thinkingJson != null}')}');

    // ④ 用户行没有成员作者。
    expect(userRow.author, isNull);
    expect(userRow.visibility, 'public');

    // ① 最终公开行只存正文。
    expect(publicRows.length, 1);
    final publicRow = publicRows.single;
    expect(publicRow.author, member.id);
    expect(publicRow.visibility, 'public');
    expect(publicRow.content, contains('甲的公开结论'));
    expect(publicRow.toolCallsJson, isNull,
        reason: '组成员的最终公开行 tool_calls 必须为 NULL');
    expect(publicRow.thinkingJson, isNull,
        reason: '组成员的最终公开行 thinking_json 必须为 NULL');
    expect(publicRow.attachments, isEmpty);

    // ② 私有中间行同时有工具与 thinking 证据。
    expect(privateRows.length, 1);
    final privateRow = privateRows.single;
    expect(privateRow.author, member.id);
    expect(privateRow.visibility, 'private-to-author');
    expect(privateRow.toolCallsJson, contains('read_file'));
    expect(privateRow.toolCallsJson, contains('A-RESULT'));
    expect(privateRow.thinkingJson, contains('甲的私有思考 A-THINK'));
    await harness.dispose();
  });

  test('③ 单会话最终行行为不变：仍写 thinking 与聚合工具', () async {
    final harness = await GroupHarness.create(createGroup: false);
    final session = await harness.support.sessionRepo.create(title: '单会话');
    final agent =
        await harness.factory.create(session, callbacks: const AgentCallbacks());

    harness.queueToolTurn(
      toolName: 'read_file',
      id: 'tool-single',
      input: const {'path': 'lib/s.dart'},
      thinking: '单会话的思考',
      stubResult: '{"ok":true,"content":"S 的内容"}',
    );
    harness.queueFinal('单会话的最终回复', thinking: '单会话最终轮思考');
    final result = await agent.send('读一下 lib/s.dart');
    expect(result.status.name, 'completed');

    final rows = await harness.support.messageRepo.queryBySession(session.id);
    final finalRow =
        rows.where((r) => r.role == 'assistant').toList().last;
    // ignore: avoid_print
    print('[OBS] 单会话最终行 author=${finalRow.author} '
        'visibility=${finalRow.visibility} tools=${finalRow.toolCallsJson} '
        'thinking=${finalRow.thinkingJson}');
    expect(finalRow.author, isNull, reason: '单会话没有成员作者');
    expect(finalRow.visibility, 'public');
    expect(finalRow.toolCallsJson, isNotNull,
        reason: '单会话最终行仍聚合整轮工具调用（行为不变）');
    expect(finalRow.toolCallsJson, contains('read_file'));
    expect(finalRow.thinkingJson, isNotNull,
        reason: '单会话最终行仍写 thinking（行为不变）');
    expect(finalRow.thinkingJson, contains('单会话最终轮思考'));
    await harness.dispose();
  });

  test('④ 用户消息 author 为空、公开（组会话里也只写一次）', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    harness.queueSimpleReply('回复');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '用户说的');
    final rows =
        await harness.support.messageRepo.queryBySession(harness.group.id);
    final users = rows.where((r) => r.role == 'user').toList();
    // ignore: avoid_print
    print('[OBS] 用户行=${users.map((r) => 'author=${r.author} '
        'visibility=${r.visibility} content=${r.content}')}');
    expect(users.length, 1, reason: '一次发送只写一条用户消息');
    expect(users.single.author, isNull);
    expect(users.single.visibility, 'public');
    await harness.dispose();
  });
}
