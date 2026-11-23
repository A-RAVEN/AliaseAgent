// 组成员生命周期（change `agent-group-chat` 任务 5.2 / 5.3 / 5.5 / design D3、D17）。
//
// 5.2：模板 + 覆盖层 → 实例；不建 `parent_session_id` 子运行记录；回合结束不销毁实例。
// 5.3：成员快照的系统提示词含 `kGroupMemberRolePrompt`（模板提示词在前、角色说明在后）。
// 5.5：`group.member.update` 原地改成员（id 不变）、重建实例、改名不改历史归属、
//      改覆盖层后下一次发言用新工具清单。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/instance_overrides.dart';
import 'package:alias_agent/services/group_member_context.dart';
import 'package:alias_agent/services/group_prompts.dart';

import 'group_harness.dart';

void main() {
  test('5.2 模板 + 覆盖层 → 实例；不是子运行；回合结束实例仍在', () async {
    final harness = await GroupHarness.create();
    final member = await harness.groups.addMember(
      groupId: harness.group.id,
      name: '甲',
      templateName: 'general',
      overrides: AgentInstanceOverrides.fromJson({
        'toolsSubset': ['read_file'],
        'systemPromptAppend': '成员专属追加段',
        'thinkingEffort': 'high',
      }),
    );

    final agent = harness.agents.lookup(member.handle);
    // ignore: avoid_print
    print('[OBS] 实例=${agent != null} handle=${member.handle} '
        'tools=${agent?.config.tools} effort=${agent?.config.thinkingEffort}');
    expect(agent, isNotNull, reason: '成员创建即得到实例');
    expect(agent!.sessionId, harness.group.id, reason: 'DB 作用域仍是组会话');
    expect(agent.handle, member.handle, reason: '实例句柄是成员专属句柄');
    expect(agent.config.tools, ['read_file'], reason: '覆盖层工具子集生效');
    expect(agent.config.systemPrompt, contains('成员专属追加段'));
    expect(agent.config.systemPrompt, contains(kGroupMemberRolePrompt),
        reason: '5.3：组角色说明必须追加进成员系统提示词');

    // 不建 parent_session_id 子运行记录。
    final children = await harness.support.sessionRepo.listChildren(harness.group.id);
    // ignore: avoid_print
    print('[OBS] 子运行记录=${children.map((s) => s.id)}');
    expect(children, isEmpty, reason: '群成员不是一次性子运行');

    harness.queueFinal('甲的公开结论：lib/a.dart（工具过程不可见）', thinking: '甲的私有思考');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '甲说一下');
    // 异步发送：等链终态再断言实例与上下文（R.7）。
    expect((await harness.waitForChain()).status, 'completed');

    final after = harness.agents.lookup(member.handle);
    // ignore: avoid_print
    print('[OBS] 回合后实例=${after != null} '
        'disposeContext=${harness.support.sidecar.disposeContextCalls}');
    expect(after, isNotNull, reason: '持久实例：回合结束不销毁');
    expect(harness.support.sidecar.disposeContextCalls,
        isNot(contains(member.handle)),
        reason: '回合结束不销毁上下文');
    expect(after!.config.systemPrompt, contains(kGroupMemberRolePrompt));
    await harness.dispose();
  });

  test('5.3 成员快照的系统提示词：模板在前、角色说明在后（逐字）', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    harness.queueSimpleReply('公开结论');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '甲说');
    await harness.waitForChain();

    final prompt = harness.support.sidecar.lastSystemPrompt ?? '';
    // ignore: avoid_print
    print('[OBS] 系统提示词前缀=「${prompt.split('\n').first}」 '
        '含角色说明=${prompt.contains(kGroupMemberRolePrompt)} '
        '角色说明在模板之后=${prompt.indexOf(kGroupMemberRolePrompt) > prompt.indexOf("你是测试模板")}');
    expect(prompt, contains('你是测试模板'), reason: '模板提示词开头');
    expect(prompt, contains(kGroupMemberRolePrompt));
    expect(prompt.indexOf(kGroupMemberRolePrompt),
        greaterThan(prompt.indexOf('你是测试模板')),
        reason: '角色说明追加在模板提示词之后');
    await harness.dispose();
  });

  test('5.5 改名不改历史归属；改覆盖层后下一次发言用新工具清单；重建实例', () async {
    final harness = await GroupHarness.create();
    final member = await harness.groups.addMember(
      groupId: harness.group.id,
      name: '甲',
      templateName: 'general',
    );
    harness.queueSimpleReply('甲的第一条公开结论');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '甲先说');
    await harness.waitForChain();

    final rowsBefore = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final publicBefore =
        rowsBefore.where((r) => r.author == member.id && !r.isPrivate).single;

    // 改名：id 不变。
    final renamed = await harness.groups.updateMember(
      groupId: harness.group.id,
      memberId: member.id,
      name: '甲二',
    );
    final rowsAfterName = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final publicAfterName =
        rowsAfterName.where((r) => r.id == publicBefore.id).single;
    final describe = await harness.groups.describeMembers(harness.group.id);
    // ignore: avoid_print
    print('[OBS] 改名后 id=${renamed.id} 显示名=${describe.single['name']} '
        '历史行 author=${publicAfterName.author}');

    expect(renamed.id, member.id, reason: '成员 id 不变');
    expect(describe.single['name'], '甲二');
    expect(publicAfterName.author, member.id, reason: '改名不改历史归属');

    // 编辑即重建：disposeContext 收到旧句柄；registry 里是新实例。
    final oldHandle = member.handle;
    // ignore: avoid_print
    print('[OBS] 重建时 disposeContext=${harness.support.sidecar.disposeContextCalls}');
    expect(harness.support.sidecar.disposeContextCalls, contains(oldHandle),
        reason: '改成员必须销毁旧实例（否则改了的配置不生效）');

    // 改覆盖层：工具子集收紧，下一次发言的 toolsJson 随之变化。
    final updated = await harness.groups.updateMember(
      groupId: harness.group.id,
      memberId: member.id,
      overrides: AgentInstanceOverrides.fromJson({
        'toolsSubset': ['list_dir'],
      }),
    );
    harness.queueSimpleReply('甲二的第二条');
    await harness.groups
        .send(groupId: harness.group.id, memberId: updated.id, text: '再说一句');
    await harness.waitForChain();

    final toolsJson = harness.support.sidecar.lastToolsJson ?? '';
    // ignore: avoid_print
    print('[OBS] 下一次发言 toolsJson=$toolsJson');
    expect(toolsJson, contains('list_dir'));
    expect(toolsJson, isNot(contains('"read_file"')),
        reason: '收紧后的子集必须真的进请求（不是界面显示改了、请求还是旧配置）');
    await harness.dispose();
  });

  test('5.5 改模板也走原地更新 + 重建（id 不变）', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    final updated = await harness.groups.updateMember(
      groupId: harness.group.id,
      memberId: member.id,
      templateName: 'narrow',
    );
    // ignore: avoid_print
    print('[OBS] id=${updated.id} 模板=${updated.templateName} '
        '实例模板=${harness.agents.lookup(member.handle)?.agentTypeName}');
    expect(updated.id, member.id);
    expect(updated.templateName, 'narrow');
    expect(harness.agents.lookup(member.handle)?.agentTypeName, 'narrow');
    expect(GroupMemberContext.fromMember(updated).templateName, 'narrow');
    await harness.dispose();
  });
}
