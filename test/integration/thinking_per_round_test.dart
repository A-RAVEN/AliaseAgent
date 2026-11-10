import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 推理强度的生效时机（change `model-truth-from-gateway` 3.4 / D7）。
///
/// 钉死三件事：
/// 1. 保存模板改 `thinking_effort` 后，**同一个 Agent 的下一条消息**就用新档；
/// 2. 该 Agent 的**第一条消息**用的还是旧档（= 冻结快照里的那个值）；
/// 3. 同一次保存里的模型与窗口修改**不**热更新（只有思考档例外）。
///
/// 另外钉住"缺省档随目录走"：模板没有显式档时，Provider 目录刷新后下一轮装配按新
/// 目录的中间档发送（D6 的推导在 D7 的解析点上真的被执行，不是只在创建时算一次）。
void main() {
  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  Session session(String id, String agentType) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
      );

  late Directory tempDir;
  late String configPath;
  late FakeSidecar sidecar;
  late AgentRegistry agents;
  late AgentTemplateController controller;

  const baseJson = {
    'version': 1,
    'providers': {
      'gateway': {'api_key': 'k', 'base_url': 'http://127.0.0.1:1'},
    },
    'agent_types': {
      'general': {
        'provider': 'gateway',
        'model': 'old-model',
        'system_prompt': '老提示词',
        'tools': ['read_file'],
        'thinking_effort': 'high',
        'max_context_tokens': 200000,
      },
    },
  };

  AgentFactory factory() => AgentFactory(
        templates: registry,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: sidecar,
        sessionRepo: FakeSessionRepository([]),
        messageRepo: FakeMessageRepository(),
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('thinking_per_round_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(configPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(baseJson));
    final config = ConfigService.load(configPath: configPath).config!;
    registry.clear();
    for (final t in config.agentTypes.values) {
      registry.register(t);
    }
    resolver = ProviderResolver(config);
    sidecar = FakeSidecar();
    agents = AgentRegistry();
    ToolCatalog.instance.seed({'read_file': def('read_file')});
    controller = AgentTemplateController(
      registry: registry,
      config: config,
      configPath: configPath,
      knownTools: () => ToolCatalog.instance.nameSet,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  test('保存模板改强度：第一条消息旧档、第二条消息新档；模型与窗口不热更新', () async {
    final agent = await factory().create(session('s-hot', 'general'));

    // 第一条消息：创建时的显式档 high。
    sidecar.queueChunk('第一条回复');
    sidecar.queueDone();
    await agent.send('第一条');
    // ignore: avoid_print
    print('  [OBS] 保存前：请求 model=${sidecar.lastModel} '
        'thinking=${sidecar.lastThinkingMode}/${sidecar.lastThinkingEffort} '
        '窗口=${agent.contextSnapshot?.windowTokens}');
    expect(sidecar.lastThinkingEffort, 'high', reason: '第一条消息用创建时的旧档');

    // 用户保存模板：强度 high → max，同时改模型与窗口（它们**不该**热更新）。
    controller.save(const AgentTemplateDraft(
      originalName: 'general',
      name: 'general',
      provider: 'gateway',
      model: 'new-model',
      thinkingEffort: 'max',
      systemPrompt: '新提示词',
      tools: ['read_file'],
      maxContextTokensText: '300000',
    ));

    // 第二条消息（同一个 Agent，新的一轮装配）：强度立刻吃新档。
    sidecar.queueChunk('第二条回复');
    sidecar.queueDone();
    await agent.send('第二条');
    // ignore: avoid_print
    print('  [OBS] 保存后同一 Agent：请求 model=${sidecar.lastModel} '
        'thinking=${sidecar.lastThinkingMode}/${sidecar.lastThinkingEffort} '
        '窗口=${agent.contextSnapshot?.windowTokens}；'
        '冻结快照 effort=${agent.config.thinkingEffort} '
        'model=${agent.config.model} window=${agent.config.maxContextTokens}');
    expect(sidecar.lastThinkingEffort, 'max',
        reason: 'D7：推理强度从下一条消息起对运行中对话生效');
    expect(sidecar.lastThinkingMode, 'adaptive');
    expect(agent.config.thinkingEffort, 'high',
        reason: '冻结快照本身不许被改写（发的值与快照里的值可以不同，这正是 D7 的语义）');
    expect(sidecar.lastModel, 'old-model',
        reason: '模型仍创建时生效：保存不改运行实例的模型');
    expect(agent.config.model, 'old-model');
    expect(agent.contextSnapshot?.windowTokens, 200000,
        reason: '窗口仍创建时生效：保存不改运行实例的窗口（也不许按未加载的配置重算）');
  });

  test('模板无显式档：目录刷新后下一轮按新目录的中间档发送（D6 x D7）', () async {
    // 目录 v1：flash 档位 low/high/max ⇒ 中间档 high。
    resolver = ProviderResolver(AppConfig(
      version: 1,
      providers: {
        'gateway': ProviderConfig(
          apiKey: 'k',
          baseUrl: 'http://127.0.0.1:1',
          models: const [
            ModelCatalogEntry(
              id: 'old-model',
              contextWindow: 200000,
              reasoningEfforts: ['none', 'low', 'high', 'max'],
            ),
          ],
          discoveredAt: '2026-11-09T00:00:00.000Z',
        ),
      },
    ));
    // 模板去掉显式档（缺键 ⇒ 走目录推导）。
    registry.update(const AgentTypeConfig(
      name: 'general',
      provider: 'gateway',
      model: 'old-model',
      systemPrompt: '老提示词',
      tools: ['read_file'],
      maxContextTokens: 200000,
    ));

    final agent = await factory().create(session('s-dir', 'general'));
    sidecar.queueChunk('一');
    sidecar.queueDone();
    await agent.send('第一条');
    // ignore: avoid_print
    print('  [OBS] 目录 v1（low/high/max）⇒ 请求 effort=${sidecar.lastThinkingEffort} '
        'mode=${sidecar.lastThinkingMode}');
    expect(sidecar.lastThinkingEffort, 'high',
        reason: '目录中间档 high 必须真的发出去（不是只在创建时算）');

    // 目录 v2：同一模型改成 low/medium/xhigh ⇒ 中间档 medium。
    resolver = ProviderResolver(AppConfig(
      version: 1,
      providers: {
        'gateway': ProviderConfig(
          apiKey: 'k',
          baseUrl: 'http://127.0.0.1:1',
          models: const [
            ModelCatalogEntry(
              id: 'old-model',
              contextWindow: 200000,
              reasoningEfforts: ['none', 'low', 'medium', 'xhigh'],
            ),
          ],
          discoveredAt: '2026-11-10T00:00:00.000Z',
        ),
      },
    ));
    sidecar.queueChunk('二');
    sidecar.queueDone();
    await agent.send('第二条');
    // ignore: avoid_print
    print('  [OBS] 目录 v2（low/medium/xhigh）⇒ 请求 effort=${sidecar.lastThinkingEffort} '
        'mode=${sidecar.lastThinkingMode}');
    expect(sidecar.lastThinkingEffort, 'medium',
        reason: '下一轮装配要读最新目录的中间档（D6 的推导在每轮解析点上执行）');
  });
}
