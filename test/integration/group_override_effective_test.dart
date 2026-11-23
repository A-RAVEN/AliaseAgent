// 覆盖层在创建/恢复时生效、思考强度逐轮热更新（change `agent-group-chat` 任务 4.8 /
// design D8 / spec「覆盖层的生效时机」）。
//
// 三条用例：
//   ① 编辑前 vs 重建后：两次真实请求的 `toolsJson` 与系统提示词差异可逐字指出；
//   ② 不重建实例就改覆盖层的思考强度：下一条消息用新档位，工具与提示词不变；
//   ③ 模型与窗口不被覆盖层改变。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/instance_overrides.dart';

import 'group_harness.dart';

void main() {
  test('① 编辑覆盖层前 / 重建后的两次请求可逐字对比', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');

    harness.queueSimpleReply('重建前的回复');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '第一次');
    await harness.waitForChain();
    final toolsBefore = harness.support.sidecar.lastToolsJson ?? '';
    final promptBefore = harness.support.sidecar.lastSystemPrompt ?? '';

    // 编辑覆盖层（服务会重建实例）。
    await harness.groups.updateMember(
      groupId: harness.group.id,
      memberId: member.id,
      overrides: AgentInstanceOverrides.fromJson({
        'toolsSubset': ['list_dir'],
        'systemPromptAppend': '新的协作纪律：只读不动手。',
      }),
    );
    harness.queueSimpleReply('重建后的回复');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '第二次');
    await harness.waitForChain();
    final toolsAfter = harness.support.sidecar.lastToolsJson ?? '';
    final promptAfter = harness.support.sidecar.lastSystemPrompt ?? '';

    // ignore: avoid_print
    print('[OBS] 工具：前=${toolsBefore.contains('read_file')} '
        '后=${toolsAfter.contains('read_file')} 后含 list_dir='
        '${toolsAfter.contains('list_dir')}');
    // ignore: avoid_print
    print('[OBS] 提示词：前含追加=${promptBefore.contains('新的协作纪律')} '
        '后含追加=${promptAfter.contains('新的协作纪律')}');

    expect(toolsBefore, contains('read_file'));
    expect(toolsAfter, isNot(contains('"read_file"')));
    expect(toolsAfter, contains('list_dir'));
    expect(promptBefore, isNot(contains('新的协作纪律')));
    expect(promptAfter, contains('新的协作纪律'));
    expect(promptAfter, contains('你是测试模板'), reason: '模板提示词仍在（append 不替换）');
    await harness.dispose();
  });

  test('② 不重建实例时：思考强度下一消息变，工具与提示词不变', () async {
    final harness = await GroupHarness.create();
    final member = await harness.addMember('甲');
    harness.queueSimpleReply('第一条');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '第一次');
    await harness.waitForChain();
    final toolsBefore = harness.support.sidecar.lastToolsJson ?? '';
    final promptBefore = harness.support.sidecar.lastSystemPrompt ?? '';
    final effortBefore = harness.support.sidecar.lastThinkingEffort ?? '';
    final instanceBefore = harness.agents.lookup(member.handle);

    // **直接改成员行**（不经过 group.member.update ⇒ 不重建实例）：模拟"编辑了覆盖层
    // 但实例还是旧的那个"。
    await harness.members.update(
      member.id,
      overridesJson: AgentInstanceOverrides.fromJson({
        'thinkingEffort': 'high',
      }).toJsonString(),
    );

    harness.queueSimpleReply('第二条');
    await harness.groups
        .send(groupId: harness.group.id, memberId: member.id, text: '第二次');
    await harness.waitForChain();
    final toolsAfter = harness.support.sidecar.lastToolsJson ?? '';
    final promptAfter = harness.support.sidecar.lastSystemPrompt ?? '';
    final effortAfter = harness.support.sidecar.lastThinkingEffort ?? '';
    final instanceAfter = harness.agents.lookup(member.handle);

    // ignore: avoid_print
    print('[OBS] 实例未重建=${identical(instanceBefore, instanceAfter)} '
        'effort before=$effortBefore after=$effortAfter '
        'tools 相同=${toolsBefore == toolsAfter} '
        'prompt 相同=${promptBefore == promptAfter}');

    expect(identical(instanceBefore, instanceAfter), isTrue,
        reason: '这条用例的前提就是不重建实例');
    expect(effortBefore, isNot('high'));
    expect(effortAfter, 'high', reason: '思考强度沿用既有热更新口径（下一消息生效）');
    expect(toolsAfter, toolsBefore, reason: '工具子集创建/恢复时生效，不逐轮热替换');
    expect(promptAfter, promptBefore, reason: '提示词追加同样不逐轮热替换');
    await harness.dispose();
  });

  test('③ 模型与窗口不被覆盖层改变', () async {
    final harness = await GroupHarness.create();
    final member = await harness.groups.addMember(
      groupId: harness.group.id,
      name: '甲',
      templateName: 'general',
      overrides: AgentInstanceOverrides.fromJson({
        'toolsSubset': ['read_file'],
        'thinkingEffort': 'max',
      }),
    );
    final agent = harness.agents.lookup(member.handle)!;
    // ignore: avoid_print
    print('[OBS] model=${agent.config.model} window=${agent.config.maxContextTokens} '
        'template=${agent.agentTypeName}');
    expect(agent.config.model, 'test-model');
    expect(agent.config.maxContextTokens, 200000);
    expect(agent.config.templateName, 'general');
    // 覆盖层里的替换类字段被拒（保存路径）——这里再确认解析结果里没有它们。
    expect(() => AgentInstanceOverrides.fromJson({'model': 'other'}),
        throwsA(isA<AgentOverridesException>()));
    await harness.dispose();
  });
}
