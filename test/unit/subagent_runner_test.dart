// 一次性子运行的创建路径（add-spawn-subagent-tool 任务 4.2）。
//
// 固定的是：
//   - 空任务 / 非法模板 / 父工作区读取失败都在**创建任何东西之前**失败，
//     子会话、子上下文与运行实例的计数保持不变；
//   - 省略 agent_type 时继承父 Agent 的模板，不固定退回 general；
//   - 子配置冻结父模板的模型 / 推理 / 工具，系统提示词附加子角色说明，
//     工具清单排除 spawn_subagent；
//   - 子上下文初始化到父句柄实际读取到的工作区；
//   - 父模板与父实例都不被改写，创建阶段不发起任何模型请求。
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
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import '../integration/helpers/fake_sidecar.dart';

void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late AgentFactory factory;
  late SubagentRunner runner;

  Session session(String id, {String agentType = 'general'}) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
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
      'run_command': def('run_command'),
      'spawn_subagent': def('spawn_subagent'),
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'general-model',
      systemPrompt: 'GENERAL-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      thinkingEffort: 'high',
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'writer',
      provider: 'test',
      model: 'writer-model',
      systemPrompt: 'WRITER-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      thinkingEffort: 'max',
      maxContextTokens: 80000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-secret-key', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
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
    );
    runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  ({int sessions, int contexts, int instances}) counts() => (
        sessions: sessionRepo.sessions.length,
        contexts: sidecar.ensureContextCalls.length,
        instances: agents.handles.length,
      );

  test('空 / 纯空白 / 缺失 task：invalid_task，且不创建子会话或子上下文', () async {
    final parent = await factory.create(session('parent-1', agentType: 'writer'));
    final before = counts();

    for (final input in <Map<String, dynamic>>[
      {'task': ''},
      {'task': '   '},
      <String, dynamic>{},
      {'task': 42},
    ]) {
      final prepared = await runner.prepare(parent: parent, input: input);
      // ignore: avoid_print
      print('  [OBS] 空任务 $input -> ok=${prepared.ok} '
          'failure=${prepared.failure}');
      expect(prepared.ok, isFalse);
      expect(prepared.failure!.code, 'invalid_task');
      expect(prepared.child, isNull);
      expect(prepared.childSession, isNull);
    }
    final after = counts();
    expect(after.sessions, before.sessions, reason: '不许创建子会话');
    expect(after.contexts, before.contexts, reason: '不许创建子上下文');
    expect(after.instances, before.instances, reason: '不许创建运行实例');
    expect(sidecar.getWorkspaceCalls, isEmpty,
        reason: '任务都没通过校验，不应去读父工作区');
  });

  test('非法模板：可区分错误带候选名，且不创建子会话或子上下文', () async {
    final parent = await factory.create(session('parent-1'));
    final before = counts();

    final prepared = await runner.prepare(
        parent: parent,
        input: {'task': '查一下', 'agent_type': 'ghost-template'});
    // ignore: avoid_print
    print('  [OBS] 非法模板 -> ok=${prepared.ok} failure=${prepared.failure}');
    expect(prepared.ok, isFalse);
    expect(prepared.failure!.code, 'invalid_agent_type');
    expect(prepared.failure!.message, contains('ghost-template'));

    final after = counts();
    expect(after.sessions, before.sessions);
    expect(after.contexts, before.contexts);
    expect(after.instances, before.instances);
  });

  test('父工作区读取失败：workspace_unavailable，且不创建子会话或子上下文', () async {
    final parent = await factory.create(session('parent-1'));
    final before = counts();
    sidecar.workspaceFailureCode = 'unknown_context';

    final prepared = await runner.prepare(
        parent: parent, input: {'task': '查一下', 'agent_type': 'general'});
    // ignore: avoid_print
    print('  [OBS] 工作区读取失败 -> ok=${prepared.ok} '
        'failure=${prepared.failure} 查询句柄=${sidecar.getWorkspaceCalls}');
    expect(prepared.ok, isFalse);
    expect(prepared.failure!.code, 'workspace_unavailable');
    expect(prepared.failure!.message, contains('unknown_context'));
    expect(sidecar.getWorkspaceCalls, ['parent-1'],
        reason: '必须按父句柄查询，不能读界面当前会话或假定主目录');

    final after = counts();
    expect(after.sessions, before.sessions);
    expect(after.contexts, before.contexts);
    expect(after.instances, before.instances);
  });

  test('省略 agent_type 继承父模板；子会话带父会话 id', () async {
    final parent = await factory.create(session('parent-1', agentType: 'writer'));
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');
    final sessionsBefore = sessionRepo.sessions.length;

    final prepared = await runner.prepare(
        parent: parent, input: {'task': '写一份结论'});
    // ignore: avoid_print
    print('  [OBS] 缺省继承 -> ok=${prepared.ok} 模板=${prepared.templateName} '
        '子句柄=${prepared.childSession?.id} 父会话=${parent.sessionId} '
        '子会话 agentType=${prepared.childSession?.agentType} '
        '子实例模板=${prepared.child?.agentTypeName} '
        '工作区=${sidecar.defaultWorkspaceByHandle[prepared.childSession?.id]}');
    expect(prepared.ok, isTrue);
    expect(prepared.templateName, 'writer');
    expect(prepared.child!.agentTypeName, 'writer',
        reason: '省略 agent_type 时必须继承父模板，不能固定 general');
    expect(prepared.childSession!.agentType, 'writer');
    expect(prepared.childSession!.parentSessionId, 'parent-1',
        reason: '子会话记录必须指向父会话');
    expect(sessionRepo.sessions.length, sessionsBefore + 1);
    expect(agents.contains(prepared.child!.sessionId), isTrue);
    expect(sidecar.defaultWorkspaceByHandle[prepared.child!.sessionId],
        'E:/parent-workspace',
        reason: '子上下文必须初始化到父句柄实际读取到的工作区');
    expect(sidecar.sendHandles, isEmpty, reason: '创建阶段不发模型请求');
  });

  test('子实例冻结配置：工具排除 spawn_subagent、角色说明附加，父模板与父实例不变',
      () async {
    final parent = await factory.create(session('parent-1', agentType: 'writer'));
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');
    final parentToolsBefore = List<String>.from(parent.config.tools);
    final writerTemplateBefore =
        registry.lookup('writer')!;

    final prepared = await runner.prepare(
        parent: parent,
        input: {'task': '做一件事', 'agent_type': 'general'});
    expect(prepared.ok, isTrue);
    final child = prepared.child!;
    // ignore: avoid_print
    print('  [OBS] 子配置模板=${child.config.templateName} '
        'model=${child.config.model} effort=${child.config.thinkingEffort} '
        'tools=${child.config.tools}\n'
        '        子提示词含角色说明=${child.config.systemPrompt.contains(kSubagentRolePrompt)} '
        '父工具=${parent.config.tools} 模板工具=${registry.lookup('writer')!.tools}');

    expect(child.config.model, 'general-model');
    expect(child.config.thinkingEffort, 'high');
    expect(child.config.tools, ['read_file'],
        reason: '子配置的实际工具清单必须排除 spawn_subagent');
    expect(child.config.tools, isNot(contains('spawn_subagent')));
    expect(child.config.systemPrompt, contains('GENERAL-PROMPT'));
    expect(child.config.systemPrompt, contains(kSubagentRolePrompt),
        reason: '子角色说明必须附加到子配置的系统提示词');
    // 父实例与模板保持原样。
    expect(parent.config.tools, parentToolsBefore);
    expect(parent.config.tools, contains('spawn_subagent'));
    expect(registry.lookup('writer')!.tools, writerTemplateBefore.tools);
    expect(registry.lookup('writer')!.tools, contains('spawn_subagent'));

    // 模板随后被改：已创建子实例继续用创建时快照。
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'changed-model',
      systemPrompt: 'CHANGED-PROMPT',
      tools: ['run_command'],
      maxContextTokens: 50000,
    ));
    sidecar.queueChunk('子回复');
    sidecar.queueDone();
    await child.send('继续');
    // ignore: avoid_print
    print('  [OBS] 模板改动后子请求 model=${sidecar.lastModel} '
        'systemPrompt 含角色说明=${sidecar.lastSystemPrompt?.contains(kSubagentRolePrompt)} '
        'toolsJson=${sidecar.lastToolsJson}');
    expect(sidecar.lastModel, 'general-model',
        reason: '子实例继续用创建时冻结的模型');
    expect(sidecar.lastSystemPrompt, contains(kSubagentRolePrompt));
    expect(sidecar.lastSystemPrompt, contains('GENERAL-PROMPT'));
    expect(sidecar.lastToolsJson, contains('read_file'));
    expect(sidecar.lastToolsJson, isNot(contains('spawn_subagent')),
        reason: '子请求的工具定义不含 spawn_subagent');
    expect(sidecar.lastToolsJson, isNot(contains('run_command')),
        reason: '模板后改的工具清单不得热更新到已创建子实例');
    expect(child.config.model, 'general-model');
    expect(parent.config.model, 'writer-model', reason: '父实例配置不被改写');
  });
}
