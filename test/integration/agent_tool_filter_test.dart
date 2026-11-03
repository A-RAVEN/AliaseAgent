import 'dart:convert';

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
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 工具清单过滤与请求参数归属（change `add-agent-object-and-templates` 任务 2.3）。
///
/// 固定的是：请求只带模板允许的、且目录里真实存在的工具；未知工具在创建时**显式
/// 报错并列名**；模型 / 推理模式 / 系统提示词来自本实例生效配置；`general` 或
/// 条件注册工具都不许绕过目录。
void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;

  Session session(String id, {String agentType = 'general'}) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      'write_file': def('write_file'),
      'list_dir': def('list_dir'),
      'run_command': def('run_command'),
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL-PROMPT',
      tools: ['read_file', 'write_file'],
      thinkingEffort: 'high',
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'ops',
      provider: 'test',
      model: 'ops-model',
      systemPrompt: 'OPS-PROMPT',
      tools: ['run_command', 'list_dir'],
      thinkingEffort: 'xhigh',
      maxContextTokens: 50000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-hidden', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar()..stubBrowserAvailable('{"ok":true,"available":false}');
    // 没有任何搜索 provider：web_search / web_fetch 不进目录。
    sidecar.stubSearchProviders('[]');
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  AgentFactory factory() => AgentFactory(
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

  List<String> sentToolNames(String toolsJson) => [
        for (final t in jsonDecode(toolsJson) as List<dynamic>)
          (t as Map<String, dynamic>)['name'] as String,
      ];

  test('请求只含模板允许的工具；模型、推理与系统提示词来自本实例', () async {
    final f = factory();
    final general = await f.create(session('s1', agentType: 'general'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await general.send('你好');

    final generalTools = sentToolNames(sidecar.lastToolsJson!);
    // ignore: avoid_print
    print('  [OBS] general 请求工具=$generalTools '
        'model=${sidecar.lastModel} mode=${sidecar.lastThinkingMode} '
        'effort=${sidecar.lastThinkingEffort} '
        'systemPrompt 含模板提示=${sidecar.lastSystemPrompt?.contains("GENERAL-PROMPT")}');
    expect(generalTools, ['read_file', 'write_file']);
    expect(generalTools, isNot(contains('run_command')));
    expect(sidecar.lastModel, 'general-model');
    expect(sidecar.lastThinkingMode, 'adaptive');
    expect(sidecar.lastThinkingEffort, 'high');
    expect(sidecar.lastSystemPrompt, contains('GENERAL-PROMPT'));

    final ops = await f.create(session('s2', agentType: 'ops'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await ops.send('执行');

    final opsTools = sentToolNames(sidecar.lastToolsJson!);
    // ignore: avoid_print
    print('  [OBS] ops 请求工具=$opsTools model=${sidecar.lastModel} '
        'mode=${sidecar.lastThinkingMode} effort=${sidecar.lastThinkingEffort}');
    expect(opsTools, ['run_command', 'list_dir'],
        reason: '命令工具不依赖搜索或浏览器，模板允许就发送');
    expect(sidecar.lastModel, 'ops-model');
    expect(sidecar.lastThinkingEffort, 'xhigh');
    expect(sidecar.lastSystemPrompt, contains('OPS-PROMPT'));
    expect(sidecar.lastSystemPrompt, isNot(contains('GENERAL-PROMPT')));
  });

  test('未知工具名在创建时显式报错并列名，不静默少给', () async {
    registry.register(const AgentTypeConfig(
      name: 'broken',
      provider: 'test',
      model: 'm',
      systemPrompt: '',
      tools: ['read_file', 'rm_rf', 'also_missing'],
      maxContextTokens: 1000,
    ));
    var message = '';
    try {
      await factory().create(session('s3', agentType: 'broken'));
      fail('含未知工具的模板必须让创建失败');
    } on UnknownToolsException catch (e) {
      message = e.toString();
      expect(e.names, ['rm_rf', 'also_missing']);
    }
    // ignore: avoid_print
    print('  [OBS] 未知工具创建失败：$message');
    expect(message, contains('rm_rf'));
    expect(message, contains('also_missing'));
    expect(message, contains('不会静默丢弃'));
    expect(agents.contains('s3'), isFalse,
        reason: '创建失败不许把一个半成品实例登记进注册表');
  });

  test('条件注册的工具也不许被跳过：目录里没有 web_search 时创建失败', () async {
    registry.register(const AgentTypeConfig(
      name: 'wants-search',
      provider: 'test',
      model: 'm',
      systemPrompt: '',
      tools: ['read_file', 'web_search'],
      maxContextTokens: 1000,
    ));
    // 没有任何搜索 provider ⇒ web_search 还没被条件注册进目录。
    expect(ToolCatalog.instance.contains('web_search'), isFalse);
    var message = '';
    try {
      await factory().create(session('s4', agentType: 'wants-search'));
      fail('目录里没有的工具必须报错，不许为 general 或条件注册留静默绕过');
    } on UnknownToolsException catch (e) {
      message = e.toString();
    }
    // ignore: avoid_print
    print('  [OBS] 条件未注册的工具：$message');
    expect(message, contains('web_search'));
  });

  test('旧默认清单迁移后基础工具不减少（请求包含十项基础工具）', () async {
    // 先用迁移把 general 的旧两项升级成当前十项基础工具。
    final migrated = ToolListMigration.migrate(AppConfig(
      version: 1,
      providers: const {},
      agentTypes: {
        'general': const AgentTypeConfig(
          name: 'general',
          provider: 'test',
          model: 'general-model',
          systemPrompt: '',
          tools: ['read_file', 'list_dir'],
          maxContextTokens: 100000,
        ),
      },
    ));
    registry.clear();
    for (final t in migrated.config.agentTypes.values) {
      registry.register(t);
    }
    // 目录里放齐这十项（模拟 `_initSearchAndTools()` 已注册基础工具）。
    ToolCatalog.instance.seed({
      for (final n in ToolCatalog.kBaseToolNames) n: def(n),
    });

    final agent = await factory().create(session('s5'));
    sidecar.queueChunk('ok');
    sidecar.queueDone();
    await agent.send('你好');
    final tools = sentToolNames(sidecar.lastToolsJson!);
    // ignore: avoid_print
    print('  [OBS] 迁移后请求工具=${tools.length} 项：$tools');
    expect(tools.length, ToolCatalog.kBaseToolNames.length);
    expect(tools, containsAll(['read_file', 'list_dir', 'run_command']));
    expect(tools, contains('spawn_subagent'),
        reason: '旧两项迁移到当前基础清单后，请求必须含新增的 spawn_subagent');
    expect(tools, isNot(contains('web_search')),
        reason: '没注册的搜索工具不能凭空出现');
  });
}
