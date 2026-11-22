// 覆盖层持久化且不改模板（change `agent-group-chat` 任务 2.5 /
// spec `agent-instance-overrides`「覆盖层持久化且单会话可用」）。
//
// 五条断言：
//   ① 成员行与会话行的 `overrides_json` 由**同一个解析器**读写（往返后逐字段相同）；
//   ② 重启（关库再开）后两处覆盖层仍然生效；
//   ③ 保存覆盖层不动模板（临时 config.json 逐字节不变、模板注册表内容不变）；
//   ④ 其它会话使用同一模板时不受影响；
//   ⑤ 生效工具清单与追加提示词能从落库数据重算（界面可核）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/instance_overrides.dart';
import 'package:alias_agent/services/agent_config_resolver.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/group_member_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import 'group_test_support.dart';

void main() {
  late GroupTestSupport support;
  late GroupMemberRepository members;
  late String groupId;

  setUp(() async {
    support = await GroupTestSupport.create(prefix: 'overrides_persist_test_');
    members = GroupMemberRepository();
    final group = await support.sessionRepo.create(title: '组', kind: 'group');
    groupId = group.id;
  });

  tearDown(() async {
    await support.dispose();
  });

  test('成员行与会话行用同一个解析器读写；重启后仍生效；模板不被改动', () async {
    final config = support.minimalConfig(
      tools: ['read_file', 'list_dir', 'run_command'],
      systemPrompt: '模板提示词：你是审阅者。',
    );
    support.writeConfig(config);
    final configBytesBefore = File(support.configPath).readAsBytesSync();

    final resolver = AgentConfigResolver(ProviderResolver(config));
    final template = config.agentTypes['reviewer'] ?? config.agentTypes['general']!;
    final base = resolver.resolve(template: template, spillPreviewChars: 1000);

    // 同一份覆盖层内容，分别写进成员行与会话行。
    final overrides = AgentInstanceOverrides.fromJson({
      'toolsSubset': ['read_file', 'run_command'],
      'systemPromptAppend': '协作纪律：先读文件再动手。',
      'thinkingEffort': 'high',
    });
    overrides.validateForSave(
        template: template, knownTools: {'read_file', 'list_dir', 'run_command'});
    final json = overrides.toJsonString();

    final member = await members.add(
      groupId: groupId,
      name: '甲',
      templateName: template.name,
      overridesJson: json,
    );
    final session = await support.sessionRepo.create(title: '单会话');
    await support.sessionRepo.updateOverrides(session.id, json);

    // ① 同一个解析器、同一格式。
    final memberParsed = (await members.get(member.id))!.overrides!;
    final sessionParsed = (await support.sessionRepo.get(session.id))!.overrides!;
    // ignore: avoid_print
    print('[OBS] 成员解析=${memberParsed.toJson()} 会话解析=${sessionParsed.toJson()}');
    expect(memberParsed.toJson(), sessionParsed.toJson(),
        reason: '两处覆盖层必须由同一个解析器读写（字段名与格式一致）');

    final memberConfig = memberParsed.applyTo(base);
    // ignore: avoid_print
    print('[OBS] 生效工具=${memberConfig.tools} '
        '生效提示词含追加=${memberConfig.systemPrompt.contains("协作纪律")} '
        'mode=${memberConfig.thinkingMode}/${memberConfig.thinkingEffort}');
    expect(memberConfig.tools, ['read_file', 'run_command']);
    expect(memberConfig.systemPrompt, startsWith('模板提示词：你是审阅者。'));
    expect(memberConfig.systemPrompt, endsWith('协作纪律：先读文件再动手。'));
    expect(memberConfig.thinkingMode, 'adaptive');
    expect(memberConfig.thinkingEffort, 'high');

    // ③ 保存覆盖层不动模板：临时配置文件逐字节不变。
    final configBytesAfter = File(support.configPath).readAsBytesSync();
    expect(configBytesAfter, configBytesBefore,
        reason: '保存覆盖层不得改写 agent_types 配置');

    // ④ 其它会话使用同一模板时不受影响。
    final other = await support.sessionRepo.create(title: '另一个会话');
    final otherSession = (await support.sessionRepo.get(other.id))!;
    expect(otherSession.overrides, isNull);
    final otherConfig = (otherSession.overrides ?? AgentInstanceOverrides.none)
        .applyTo(base);
    // ignore: avoid_print
    print('[OBS] 其它会话工具=${otherConfig.tools} '
        '提示词=${otherConfig.systemPrompt}');
    expect(otherConfig.tools, base.tools);
    expect(otherConfig.systemPrompt, base.systemPrompt);

    // ② 重启（关库再开）后仍然生效。
    await DatabaseService.close();
    await DatabaseService.openAt(support.databaseDir);
    final memberAfterRestart = (await members.get(member.id))!.overrides!;
    final sessionAfterRestart =
        (await support.sessionRepo.get(session.id))!.overrides!;
    // ignore: avoid_print
    print('[OBS] 重启后 成员=${memberAfterRestart.toJson()} '
        '会话=${sessionAfterRestart.toJson()}');
    expect(memberAfterRestart.applyTo(base).tools, ['read_file', 'run_command']);
    expect(sessionAfterRestart.applyTo(base).systemPrompt,
        endsWith('协作纪律：先读文件再动手。'));
    expect(sessionAfterRestart.effectiveThinking(),
        (mode: 'adaptive', effort: 'high'));
  });
}
