import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/context_ring.dart';

import '../widget/helpers/fakes.dart';
import '../integration/helpers/fake_sidecar.dart';

/// 占用环的分母来自**产生该快照的 Agent 实例**（任务 3.4）。
///
/// 固定的是：模板窗口后来改小不改变旧实例的环；新实例才用新窗口；环永远不超过
/// 100%；非法窗口在创建时显式失败，而不是靠"窗口为 0 就不画环"掩盖。
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

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  AgentTypeConfig template(int window) => AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'test-model',
        systemPrompt: '',
        tools: const ['read_file'],
        maxContextTokens: window,
      );

  setUp(() {
    ToolCatalog.instance.seed({'read_file': def('read_file')});
    registry.clear();
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  AgentFactory factory({
    required FakeSidecar sidecar,
    required FakeMessageRepository msgRepo,
    required AgentRegistry agents,
    required AgentTypeRegistry templates,
  }) =>
      AgentFactory(
        templates: templates,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: sidecar,
        sessionRepo: FakeSessionRepository([]),
        messageRepo: msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  test('模板窗口改小后旧实例仍用创建时窗口；新实例才用新窗口；占比不超过 100%', () async {
    final tempDir = Directory.systemTemp.createTempSync('ring_window_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(configPath).writeAsStringSync('{}');

    final templates = AgentTypeRegistry()..register(template(200000));
    final controller = AgentTemplateController(
      registry: templates,
      config: AppConfig(
        version: 1,
        providers: const {
          'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
        },
        agentTypes: {'general': template(200000)},
      ),
      configPath: configPath,
      knownTools: () => const {'read_file'},
    );
    final sidecar = FakeSidecar();
    final msgRepo = FakeMessageRepository();
    final agents = AgentRegistry();
    final f = factory(
        sidecar: sidecar, msgRepo: msgRepo, agents: agents, templates: templates);

    final old = await f.create(session('s-old'));
    sidecar.queueChunk('old');
    sidecar.queueDone();
    await old.send('第一次');
    final oldWindow = old.contextSnapshot!.windowTokens;
    // ignore: avoid_print
    print('  [OBS] 旧实例快照窗口=$oldWindow '
        '拆分窗口=${old.contextSnapshot!.breakdown!.windowTokens} '
        '模板名=${old.contextSnapshot!.agentType}');

    // 模板改小（保存不是热更新）。
    controller.save(const AgentTemplateDraft(
      originalName: 'general',
      name: 'general',
      provider: 'test',
      model: 'test-model',
      thinkingEffort: '',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokensText: '2000',
    ));

    sidecar.queueChunk('old-again');
    sidecar.queueDone();
    await old.send('第二次');
    final oldWindowAfter = old.contextSnapshot!.windowTokens;
    // ignore: avoid_print
    print('  [OBS] 保存窗口=2000 后旧实例再发：窗口=$oldWindowAfter '
        '拆分窗口=${old.contextSnapshot!.breakdown!.windowTokens}');
    expect(oldWindow, 200000);
    expect(oldWindowAfter, 200000, reason: '旧实例不许跟着模板换分母');
    expect(old.contextSnapshot!.breakdown!.windowTokens, 200000);

    // 新实例才用新窗口。
    final fresh = await f.create(session('s-new'));
    sidecar.queueChunk('new');
    sidecar.queueDone();
    await fresh.send('新实例');
    // ignore: avoid_print
    print('  [OBS] 新实例快照窗口=${fresh.contextSnapshot!.windowTokens} '
        '拆分窗口=${fresh.contextSnapshot!.breakdown!.windowTokens}');
    expect(fresh.contextSnapshot!.windowTokens, 2000);
    expect(fresh.contextSnapshot!.breakdown!.windowTokens, 2000);

    for (final agent in [old, fresh]) {
      final label = ContextRingLabeled.labelOf(agent.contextSnapshot!.breakdown);
      final percent = double.parse(label!.replaceAll('%', ''));
      // ignore: avoid_print
      print('  [OBS] 环旁占比：${agent.sessionId} => $label '
          '（${agent.contextSnapshot!.breakdown!.conversationTokens} / '
          '${agent.contextSnapshot!.windowTokens}）');
      expect(percent, lessThanOrEqualTo(100.0),
          reason: '环不能超过 100%（超出说明分母取错了）');
    }
  });

  testWidgets('界面环：模板窗口改小后旧快照的环不变，新会话才换分母', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('ring_ui_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(configPath).writeAsStringSync('{}');
    final configured = AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      tools: const ['read_file'],
      maxContextTokens: 200000,
    );
    registry.register(configured);
    final controller = AgentTemplateController(
      registry: registry,
      config: AppConfig(
        version: 1,
        providers: const {
          'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
        },
        agentTypes: {'general': configured},
      ),
      configPath: configPath,
      knownTools: () => const {'read_file'},
    );

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessionRepo = FakeSessionRepository([session('s1')]);
    final sidecar = FakeSidecar();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
          backgroundFoldEnabled: false,
          agentTemplateController: controller,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    sidecar.queueChunk('reply');
    sidecar.queueDone();
    await tester.enterText(find.byType(TextField), '第一问');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final ringBefore = tester.widget<ContextRing>(find.byType(ContextRing));
    // ignore: avoid_print
    print('  [OBS] 保存前环窗口=${ringBefore.breakdown?.windowTokens}');
    expect(ringBefore.breakdown?.windowTokens, 200000);

    // 保存模板窗口改小；强制界面重画（切一次视图再切回来）。
    controller.save(const AgentTemplateDraft(
      originalName: 'general',
      name: 'general',
      provider: 'test',
      model: 'test-model',
      thinkingEffort: '',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokensText: '2000',
    ));
    await tester.tap(find.text('真实上下文'));
    await tester.pump();
    await tester.tap(find.text('对话视图'));
    await tester.pump();
    final ringAfter =
        tester.widget<ContextRing>(find.byType(ContextRing));
    // ignore: avoid_print
    print('  [OBS] 保存窗口=2000 后旧快照环窗口=${ringAfter.breakdown?.windowTokens}');
    expect(ringAfter.breakdown?.windowTokens, 200000,
        reason: '绘制时重新读取模板窗口就会在这里变成 2000');

    // 新会话：新实例用新窗口。
    sidecar.queueChunk('reply2');
    sidecar.queueDone();
    await tester.tap(find.text('New Chat'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '第二问');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final ringNew = tester.widget<ContextRing>(find.byType(ContextRing));
    // ignore: avoid_print
    print('  [OBS] 新会话环窗口=${ringNew.breakdown?.windowTokens}');
    expect(ringNew.breakdown?.windowTokens, 2000);
  });

  testWidgets('非法窗口：创建时显式失败并在界面报出模板名，不靠隐藏圆环掩盖', (tester) async {
    registry.register(const AgentTypeConfig(
      name: 'bad',
      provider: 'test',
      model: 'm',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 0,
    ));
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final badSession = Session(
      id: 'bad-session',
      title: '坏窗口会话',
      agentType: 'bad',
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: FakeSessionRepository([badSession]),
          msgRepo: FakeMessageRepository(),
          sidecar: FakeSidecar(),
          summaryProvider: FakeSummaryProvider(),
          backgroundFoldEnabled: false,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // ignore: avoid_print
    print('  [OBS] 错误提示数=${find.byKey(const ValueKey('agent-error-notice')).evaluate().length} '
        '环数=${find.byType(ContextRing).evaluate().length}');
    expect(find.byKey(const ValueKey('agent-error-notice')), findsOneWidget);
    expect(find.textContaining('"bad"'), findsOneWidget,
        reason: '错误必须显示模板名，用户才知道是哪个模板坏了');
    expect(find.byType(ContextRing), findsOneWidget,
        reason: '环仍渲染为空盒子；关键判据是错误已经显式出现，不是把环藏起来');
    expect(
        tester.widget<ContextRing>(find.byType(ContextRing)).breakdown, isNull,
        reason: '还没捕获快照 ⇒ 没有拆分 ⇒ 环不渲染内容');
  });
}
