// `load_skill` 派发、生效集合闸与结果文本的集成用例（change
// `add-skill-mechanism` 任务 5.3，FakeSidecar）。
//
// 覆盖三件事：
//   ① 生效技能名走到 FFI（`FakeSidecar.loadSkill` 被调一次），请求里带 `preview_chars`
//      与技能名；
//   ② **校验失败的技能在 Dart 侧就被挡下**：`FakeSidecar` 一次都没被调用，工具结果是
//      `ok:false` 且原因里点名"校验失败"与该技能（design D6 第一道闸）；
//   ③ 结果文本形状：首行 `skill "<名字>"`（带 file 时是 `skill "<名字>" (file: …)`），
//      末行是 spill 引用说明（含总字节、省略量与 `read_spill` 取回参数）。
//
// 断言的是**发给模型的 tool_result 内容**（从第二次请求的 messagesJson 里取）与卡片
// 拿到的那份字符串，不是内部变量。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late Directory skillsRoot;
  late List<ToolCallActivity> activities;

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  void writeSkill(String dirName, String nameField) {
    final dir = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}$dirName')
      ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: $nameField\ndescription: fake $dirName\n---\n# 正文\n');
  }

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      kLoadSkillToolName: kLoadSkillToolDefinition,
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    skillsRoot = Directory.systemTemp.createTempSync('skill_dispatch_');
    activities = [];
    SkillCatalogService.instance.resetForTests();
    // change `refresh-skill-catalog-each-turn`：`scan()` 现在**每轮装配前都会调用**
    // （design D2），而生产调用不传 rootPath。用例必须把"缺省根"本身指到临时目录，
    // 否则一轮之后会去扫用户主目录的真实技能目录（结果随机器而变）。
    SkillCatalogService.instance.setRootForTests(skillsRoot.path);
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
    SkillCatalogService.instance.resetForTests();
    SkillCatalogService.instance.setRootForTests(null);
    if (skillsRoot.existsSync()) skillsRoot.deleteSync(recursive: true);
  });

  Future<Agent> buildAgent(String id) async {
    final factory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    return factory.create(session(id),
        callbacks: AgentCallbacks(onToolResult: activities.add));
  }

  /// 从第二次请求的 messagesJson 里取出 tool_result 的 content 文本。
  String toolResultText(String messagesJson, String toolUseId) {
    final messages = jsonDecode(messagesJson) as List<dynamic>;
    for (final message in messages.reversed) {
      final map = message as Map<String, dynamic>;
      if (map['role'] != 'user') continue;
      final content = map['content'];
      if (content is! List) continue;
      for (final block in content) {
        final b = block as Map<String, dynamic>;
        if (b['type'] != 'tool_result' || b['tool_use_id'] != toolUseId) continue;
        return (b['content'] as String?) ?? '';
      }
    }
    return '';
  }

  test('生效技能走 FFI 且请求带 preview_chars；结果文本首行名字、末行 spill 引用', () async {
    writeSkill('pdf-tools', 'pdf-tools');
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);
    expect(SkillCatalogService.instance.isActive('pdf-tools'), isTrue);

    // C++ 侧会返回的形状：内联头尾 + 省略量 + spill 信封（这里由桩给出）。
    sidecar.stubLoadSkill(jsonEncode({
      'ok': true,
      'content': 'HEAD-PART\n[... 198000 bytes omitted of 200000; full output: '
          'C:\\spill\\000001-skill.txt — read it back with read_spill (ref, '
          'offset=1000, limit=198000)]\nTAIL-PART',
      'truncated': true,
      'spill': {
        'skill': {
          'ref': 'C:\\spill\\000001-skill.txt',
          'total_bytes': 200000,
          'omitted_bytes': 198000,
          'head': 'HEAD-PART',
          'tail': 'TAIL-PART',
        }
      },
    }));
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'skill-1',
      'name': 'load_skill',
      'input': {'skill': 'pdf-tools'},
    }));
    sidecar.queueDone();
    sidecar.queueChunk('好的');
    sidecar.queueDone();

    final agent = await buildAgent('s1');
    await agent.send('用一下 pdf-tools');

    // ① 真走了 FFI，且请求形态对
    // ignore: avoid_print
    print('[派发] loadSkill 调用次数=${sidecar.loadSkillCallCount} '
        '请求=${sidecar.lastLoadSkillRequest}');
    expect(sidecar.loadSkillCallCount, 1);
    final request = jsonDecode(sidecar.lastLoadSkillRequest!) as Map<String, dynamic>;
    expect(request['skill'], 'pdf-tools');
    expect(request['preview_chars'], 1000,
        reason: '与 web_fetch 同形：Dart 读 spill.preview_chars 后透传（缺省 1000）');
    expect(request.containsKey('file'), isFalse, reason: '不带 file 时不编一个空键');

    // ② 发给模型的 tool_result 文本形状
    final resultText = toolResultText(
        sidecar.lastMessagesJson ?? '[]', 'skill-1');
    // ignore: avoid_print
    print('[派发] tool_result 文本：\n$resultText');
    final lines = resultText.split('\n');
    expect(lines.first, 'skill "pdf-tools"');
    expect(resultText, contains('HEAD-PART'));
    expect(resultText, contains('TAIL-PART'));
    expect(resultText, contains('198000 bytes omitted'));
    expect(lines.last, contains('[spill refs: skill=C:\\spill\\000001-skill.txt '
        '(200000 bytes, 198000 omitted)'));
    expect(lines.last, contains('read_spill(ref, offset, limit)'));
    expect(activities.single.toolName, 'load_skill');
    expect(activities.single.result, resultText,
        reason: '卡片拿到的就是发给模型的那一份字符串');
  });

  test('带 file 时首行写明相对路径', () async {
    writeSkill('with-ref', 'with-ref');
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);
    sidecar.stubLoadSkill(jsonEncode({
      'ok': true,
      'content': 'REFERENCE-BODY',
      'truncated': false,
      'spill': {
        'skill': {
          'ref': 'C:\\spill\\000002-skill.txt',
          'total_bytes': 14,
          'omitted_bytes': 0,
        }
      },
    }));
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'skill-2',
      'name': 'load_skill',
      'input': {'skill': 'with-ref', 'file': 'references/REFERENCE.md'},
    }));
    sidecar.queueDone();
    sidecar.queueChunk('好的');
    sidecar.queueDone();

    final agent = await buildAgent('s2');
    await agent.send('读附属文件');

    final request = jsonDecode(sidecar.lastLoadSkillRequest!) as Map<String, dynamic>;
    // ignore: avoid_print
    print('[派发] 带 file 的请求=$request');
    expect(request['file'], 'references/REFERENCE.md');

    final resultText = toolResultText(
        sidecar.lastMessagesJson ?? '[]', 'skill-2');
    // ignore: avoid_print
    print('[派发] 带 file 的 tool_result 文本：\n$resultText');
    expect(resultText.split('\n').first,
        'skill "with-ref" (file: references/REFERENCE.md)');
    expect(resultText, contains('REFERENCE-BODY'));
    expect(resultText.split('\n').last, contains('[spill refs: skill='));
  });

  test('校验失败的技能在 Dart 侧被挡：FFI 一次都没调、结果 ok:false 且原因可见', () async {
    // 目录名合法（broken-skill），但 frontmatter 的 name 是 65 字符 ⇒ 校验失败。
    writeSkill('broken-skill', 'a' * 65);
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);
    expect(SkillCatalogService.instance.isActive('broken-skill'), isFalse);
    // ignore: avoid_print
    print('[派发] 启动期失败清单=${SkillCatalogService.instance.noticeLines}');
    expect(SkillCatalogService.instance.failureReasonFor('broken-skill'),
        contains('name 超过 64 字符'));

    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'skill-3',
      'name': 'load_skill',
      'input': {'skill': 'broken-skill'},
    }));
    sidecar.queueDone();
    sidecar.queueChunk('好的');
    sidecar.queueDone();

    final agent = await buildAgent('s3');
    await agent.send('加载坏技能');

    // ignore: avoid_print
    print('[派发] 被挡后 loadSkill 调用次数=${sidecar.loadSkillCallCount}');
    expect(sidecar.loadSkillCallCount, 0,
        reason: '校验失败的技能不许触 FFI（design D6 第一道闸）');
    expect(sidecar.lastLoadSkillRequest, isNull);

    final resultText = toolResultText(
        sidecar.lastMessagesJson ?? '[]', 'skill-3');
    // ignore: avoid_print
    print('[派发] 被挡的 tool_result 文本：$resultText');
    expect(resultText, contains('未生效'));
    expect(resultText, contains('校验失败'));
    expect(resultText, contains('broken-skill'));
    expect(resultText, contains('name 超过 64 字符'));
    expect(resultText, isNot(contains('正文')),
        reason: '校验失败技能的正文不许进入模型上下文');
    expect(activities.single.status, ToolCallStatus.error);
  });

  test('根本不存在的技能名同样被挡，且错误里列出当前生效技能', () async {
    writeSkill('known-skill', 'known-skill');
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);

    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'skill-4',
      'name': 'load_skill',
      'input': {'skill': 'nope-skill'},
    }));
    sidecar.queueDone();
    sidecar.queueChunk('好的');
    sidecar.queueDone();

    final agent = await buildAgent('s4');
    await agent.send('加载不存在的技能');

    // ignore: avoid_print
    print('[派发] 未知技能 loadSkill 调用次数=${sidecar.loadSkillCallCount}');
    expect(sidecar.loadSkillCallCount, 0);
    final resultText = toolResultText(
        sidecar.lastMessagesJson ?? '[]', 'skill-4');
    // ignore: avoid_print
    print('[派发] 未知技能的 tool_result 文本：$resultText');
    expect(resultText, contains('nope-skill'));
    expect(resultText, contains('未生效'));
    expect(resultText, contains('known-skill'),
        reason: '报错要告诉模型现在有哪些技能可用');
  });
}
