// Agent 的句柄与成员上下文（change `agent-group-chat` 任务 4.1 / design D3）。
//
// ① 单会话实例 `handle == sessionId`，注册表按它登记（行为不变）；
// ② 两个成员各有**成员专属句柄**，各自登记、互不覆盖，取消只打自己的句柄。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/resolved_agent_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/guard_anchors.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../integration/helpers/fake_sidecar.dart';
import '../widget/helpers/fakes.dart';

const ResolvedAgentConfig _resolved = ResolvedAgentConfig(
  templateName: 'general',
  providerName: 'test-provider',
  model: 'test-model',
  thinkingMode: 'disabled',
  thinkingEffort: '',
  systemPrompt: '模板',
  tools: ['read_file'],
  maxContextTokens: 200000,
  compactionThresholdPercent: 25,
  compactionWaitThresholdPercent: 75,
  inputModalities: ['text'],
  commandTimeoutMs: 120000,
  commandMaxTimeoutMs: 600000,
  standingRequirements: [],
  spillPreviewChars: 1000,
);

const AgentTypeConfig _template = AgentTypeConfig(
  name: 'general',
  provider: 'test-provider',
  model: 'test-model',
  systemPrompt: '模板',
  tools: ['read_file'],
  maxContextTokens: 200000,
);

void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late AgentFactory factory;
  late AgentTypeRegistry templates;
  late AppConfig config;

  setUp(() {
    sidecar = FakeSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository([]);
    agents = AgentRegistry();
    config = AppConfig(
      version: 1,
      providers: {
        'test-provider': const ProviderConfig(
            apiKey: 'k', baseUrl: 'http://127.0.0.1:9'),
      },
      agentTypes: {'general': _template},
    );
    ToolCatalog.instance.seed({
      'read_file': {'name': 'read_file'},
    });
    templates = AgentTypeRegistry()..register(_template);
    factory = AgentFactory(
      templates: templates,
      providerResolver: () => ProviderResolver(config),
      config: config,
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
  });

  Agent buildMember(String memberId) => Agent(
        sessionId: 'group-1',
        handle: 'group-1::$memberId',
        agentTypeName: 'general',
        config: _resolved,
        template: _template,
        provider: const ProviderConfig(
            apiKey: 'k', baseUrl: 'http://127.0.0.1:9'),
        sessionRepo: sessionRepo,
        messageRepo: msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        sidecar: sidecar,
        summaryProvider: FakeSummaryProvider(),
        seamSelector: null,
        guard: GuardAnchors(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: false,
      );

  test('单会话 handle == sessionId（行为不变）', () async {
    final session = Session(
      id: 'single-1',
      title: '单会话',
      agentType: 'general',
      createdAt: 1,
      updatedAt: 1,
    );
    final agent = await factory.create(session);
    // ignore: avoid_print
    print('[OBS] handle=${agent.handle} sessionId=${agent.sessionId} '
        'registry=${agents.handles}');
    expect(agent.handle, 'single-1');
    expect(agent.sessionId, 'single-1');
    expect(agent.member, isNull);
    expect(agents.lookup('single-1'), same(agent));
  });

  test('两个成员各自注册互不覆盖，取消只打自己的句柄', () async {
    final a = buildMember('member-a');
    final b = buildMember('member-b');
    agents.register(a);
    agents.register(b);

    // ignore: avoid_print
    print('[OBS] handles=${agents.handles}');
    expect(agents.handles,
        containsAll(['group-1::member-a', 'group-1::member-b']));
    expect(agents.lookup('group-1::member-a'), same(a));
    expect(agents.lookup('group-1::member-b'), same(b));

    a.cancel();
    // ignore: avoid_print
    print('[OBS] 取消句柄=${sidecar.cancelHandles}');
    expect(sidecar.cancelHandles, ['group-1::member-a'],
        reason: '取消只打成员自己的句柄，不碰另一个成员');
    b.cancel();
    expect(sidecar.cancelHandles,
        ['group-1::member-a', 'group-1::member-b']);
  });
}
