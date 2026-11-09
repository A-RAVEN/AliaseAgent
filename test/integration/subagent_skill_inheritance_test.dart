// 子 Agent 继承技能目录的集成用例（change `add-skill-mechanism` 任务 6.5，
// 对应规范「技能对子 agent 自动可用」）。
//
// 用假 sidecar 驱动真实的父子 Agent：主会话调用 `spawn_subagent` 建子实例，断言
// **子 Agent 的首轮 systemPrompt** 含与父会话同一段技能目录（逐字相同），且它的
// tools 数组含 `load_skill` 定义 —— 也就是说技能目录与生效集合是进程内单份，
// `AgentFactory.create` 那条路径天然继承，不需要任何单独注册或开关。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 按句柄记录每次模型请求（FakeSidecar 只留最后一次）。
class _RecordingSidecar extends FakeSidecar {
  final List<({String handle, String systemPrompt, String toolsJson})> requests =
      [];

  @override
  Future<void> sendMessage({
    required String handle,
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required String thinkingMode,
    required String thinkingEffort,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) {
    requests.add((handle: handle, systemPrompt: systemPrompt, toolsJson: toolsJson));
    return super.sendMessage(
      handle: handle,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      systemPrompt: systemPrompt,
      messagesJson: messagesJson,
      toolsJson: toolsJson,
      thinkingMode: thinkingMode,
      thinkingEffort: thinkingEffort,
      onChunk: onChunk,
      onToolCall: onToolCall,
      onThinking: onThinking,
      onDone: onDone,
    );
  }
}

void main() {
  late _RecordingSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late Directory skillsRoot;

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

  void writeSkill(String dirName, String description) {
    final dir = Directory(
        '${skillsRoot.path}${Platform.pathSeparator}$dirName')
      ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}SKILL.md').writeAsStringSync(
        '---\nname: $dirName\ndescription: $description\n---\n# 正文\n');
  }

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      'spawn_subagent': def('spawn_subagent'),
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = _RecordingSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    skillsRoot = Directory.systemTemp.createTempSync('skill_subagent_');
    SkillCatalogService.instance.resetForTests();
    // change `refresh-skill-catalog-each-turn`：`scan()` 每轮装配前都会调用一次
    // （design D2），所以"缺省根"本身要指向临时目录，父子 Agent 的每轮装配才都
    // 落在同一份夹具上，而不是去扫用户主目录。
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

  List<String> toolNames(String json) => [
        for (final t in jsonDecode(json) as List<dynamic>)
          (t as Map<String, dynamic>)['name'] as String,
      ];

  test('子 Agent 首轮 systemPrompt 含同一技能目录段、tools 含 load_skill', () async {
    writeSkill('alpha-skill', 'A 开头的技能描述');
    writeSkill('pdf-tools', '处理 PDF：拆分与合并');
    await SkillCatalogService.instance.scan(rootPath: skillsRoot.path);
    final section = SkillCatalogService.instance.promptSection;
    expect(section, isNotEmpty);

    late AgentFactory factory;
    final runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
    factory = AgentFactory(
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
      subagentRunner: runner,
    );
    final parent = await factory.create(session('parent-1'));
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');

    // 父第一轮：调用 spawn_subagent。
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'spawn-1',
      'name': 'spawn_subagent',
      'input': {'task': '给一句话的结论'},
    }));
    sidecar.queueDone();
    // 子第一轮（也是最后一轮）：直接给结论。
    sidecar.queueChunk('子结论');
    sidecar.queueDone();
    // 父第二轮：最终回复。
    sidecar.queueChunk('父最终回复');
    sidecar.queueDone();

    await parent.send('父问题');

    final childSession =
        sessionRepo.sessions.firstWhere((s) => s.parentSessionId == 'parent-1');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    final childRequests =
        sidecar.requests.where((r) => r.handle == childSession.id).toList();
    // ignore: avoid_print
    print('[技能继承] 父请求数=${parentRequests.length} '
        '子请求数=${childRequests.length} 子会话=${childSession.id}');
    // ignore: avoid_print
    print('[技能继承] 子首轮 systemPrompt=\n${childRequests.first.systemPrompt}');
    // ignore: avoid_print
    print('[技能继承] 子首轮 tools=${toolNames(childRequests.first.toolsJson)}');

    expect(childRequests, isNotEmpty, reason: '子 Agent 必须真的发过请求');
    final childPrompt = childRequests.first.systemPrompt;
    final parentPrompt = parentRequests.first.systemPrompt;
    expect(childPrompt, contains(section),
        reason: '子 Agent 的首轮系统提示词必须含与父会话同一段技能目录（逐字相同）');
    expect(parentPrompt, contains(section), reason: '父会话同样含目录段');
    expect(childPrompt, contains('- alpha-skill: A 开头的技能描述'));
    expect(childPrompt, contains('- pdf-tools: 处理 PDF：拆分与合并'));
    expect(toolNames(childRequests.first.toolsJson), contains(kLoadSkillToolName),
        reason: '子 Agent 的 tools 也必须含装配层追加的 load_skill');
    expect(toolNames(childRequests.first.toolsJson), isNot(contains('spawn_subagent')),
        reason: '子 Agent 仍然不能嵌套（与本 change 无关的既有约束）');
  });
}
