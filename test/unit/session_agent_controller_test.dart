import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_session_controller.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../integration/helpers/fake_sidecar.dart';
import '../widget/helpers/fakes.dart';

/// Session 切换 Agent 模板的控制器（任务 3.5）。
///
/// 固定的是：同名无需操作；合法顺序是"预检 → 退役 → 持久化 → 重读 → 创建"；界面
/// 回调真的传给了新实例；预检失败没有任何副作用；重复切换被拒；退役 / 写库 / 创建
/// 失败各自报出阶段与候选名；未找到 Session 不创建实例；退役不调用 `cancelRequest`
/// 与 `disposeContext`；删除与切换互斥并重读 Session。
void main() {
  late FakeSidecar sidecar;
  late FakeMessageRepository msgRepo;
  late _RecordingSessionRepo sessionRepo;
  late AgentRegistry agents;
  late AgentTypeRegistry templates;
  late ProviderResolver providerResolver;
  late Session session;

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
      for (final n in ['read_file', 'write_file', 'run_command', 'list_dir'])
        n: def(n),
    });
    templates = AgentTypeRegistry()
      ..register(const AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'general-model',
        systemPrompt: 'GENERAL',
        tools: ['read_file'],
        maxContextTokens: 100000,
      ))
      ..register(const AgentTypeConfig(
        name: 'reviewer',
        provider: 'test',
        model: 'reviewer-model',
        systemPrompt: 'REVIEWER',
        tools: ['read_file', 'run_command'],
        thinkingEffort: 'max',
        maxContextTokens: 64000,
      ));
    providerResolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    msgRepo = FakeMessageRepository();
    session = Session(
      id: 's1',
      title: 'Session s1',
      agentType: 'general',
      createdAt: 1,
      updatedAt: 1,
    );
    sessionRepo = _RecordingSessionRepo([session]);
    agents = AgentRegistry();
  });

  tearDown(() {
    ToolCatalog.instance.reset();
  });

  AgentFactory factory({AgentTypeRegistry? templateRegistry}) => AgentFactory(
        templates: templateRegistry ?? templates,
        providerResolver: () => providerResolver,
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

  AgentSessionController controllerFor(AgentFactory f,
          {Future<void> Function(Agent agent)? retireAgent}) =>
      AgentSessionController(
        factory: f,
        sessionRepo: sessionRepo,
        retireAgent: retireAgent,
      );

  test('候选名与当前模板相同时无需操作：不退役、不写库', () async {
    final f = factory();
    final first = await f.create(session);
    final controller = controllerFor(f);
    var retired = 0;
    final sameNameController = controllerFor(f, retireAgent: (a) async {
      retired++;
      await a.retire();
    });

    final again = await sameNameController.switchTemplate(
      session,
      'general',
      callbacks: const AgentCallbacks(),
    );

    // ignore: avoid_print
    print('  [OBS] 同名切换返回实例=${identityHashCode(again)} 原实例=${identityHashCode(first)} '
        '写库次数=${sessionRepo.updateCalls} 退役次数=$retired');
    expect(identical(again, first), isTrue, reason: '同名必须返回同一个实例');
    expect(sessionRepo.updateCalls, 0, reason: '同名不写数据库');
    expect(retired, 0, reason: '同名不退役旧实例');
    expect(identical(controller.agentFor('s1'), first), isTrue);
  });

  test('合法顺序：预检 → 退役 → 持久化 → 重读 → 创建新实例', () async {
    final f = factory();
    final old = await f.create(session);
    final events = <String>[];
    sidecar.ensureContextCalls.clear();
    final controller = controllerFor(
      f,
      retireAgent: (a) async {
        events.add('retire-start');
        await a.retire();
        events.add('retire-end');
      },
    );
    sessionRepo.onUpdate = () => events.add('persist');

    final callbacks = AgentCallbacks(onUserMessage: (_) {});
    final fresh = await controller.switchTemplate(session, 'reviewer',
        callbacks: callbacks);

    // ignore: avoid_print
    print('  [OBS] 切换顺序=$events '
        '新实例模板=${fresh.agentTypeName} 数据库=${sessionRepo.sessions.single.agentType} '
        'ensureContext=${sidecar.ensureContextCalls}');
    expect(events, ['retire-start', 'retire-end', 'persist']);
    expect(fresh.agentTypeName, 'reviewer');
    expect(fresh.config.model, 'reviewer-model');
    expect(old.isRetiring, isTrue, reason: '旧对象必须已进入退役状态');
    expect(identical(agents.lookup('s1'), fresh), isTrue);
    expect(sessionRepo.sessions.single.agentType, 'reviewer');
    expect(sessionRepo.getCalls, greaterThan(0), reason: '持久化后必须重新读取 Session');
    expect(sidecar.ensureContextCalls, ['s1'],
        reason: '新实例沿用同一 Session 句柄，只 ensure 一次');
  });

  test('新实例使用调用方给的界面回调（消息能到聊天区）', () async {
    final f = factory();
    await f.create(session);
    final received = <String>[];
    final controller = controllerFor(f);
    final fresh = await controller.switchTemplate(
      session,
      'reviewer',
      callbacks: AgentCallbacks(onUserMessage: (m) => received.add(m.content)),
    );
    sidecar.queueChunk('切换后的回复');
    sidecar.queueDone();
    await fresh.send('切换后发送');

    // ignore: avoid_print
    print('  [OBS] 新实例回调收到的用户消息=$received 请求 model=${sidecar.lastModel}');
    expect(received, ['切换后发送'],
        reason: '新实例必须使用界面回调，不能用默认空回调');
    expect(sidecar.lastModel, 'reviewer-model');
  });

  test('预检失败没有任何副作用：旧实例、数据库、界面状态都不变', () async {
    final f = factory();
    final old = await f.create(session);
    final controller = controllerFor(f);
    final error = await _errorOf(
        controller.switchTemplate(session, 'ghost-template', callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 预检失败：$error');
    expect(error.stage, AgentSwitchStage.preflight);
    expect(error.candidateName, 'ghost-template');
    expect(error.message, contains('ghost-template'));
    expect(old.isRetiring, isFalse, reason: '预检失败不得退役旧实例');
    expect(identical(agents.lookup('s1'), old), isTrue, reason: '旧实例仍注册着');
    expect(sessionRepo.updateCalls, 0, reason: '预检失败不得写数据库');
    expect(sessionRepo.sessions.single.agentType, 'general');
  });

  test('非法窗口在预检阶段失败并带模板名，旧实例仍可用', () async {
    templates.register(const AgentTypeConfig(
      name: 'bad-window',
      provider: 'test',
      model: 'm',
      systemPrompt: '',
      tools: ['read_file'],
      maxContextTokens: 0,
    ));
    final f = factory();
    final old = await f.create(session);
    final error = await _errorOf(
        controllerFor(f).switchTemplate(session, 'bad-window', callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 非法窗口预检失败：$error');
    expect(error.stage, AgentSwitchStage.preflight);
    expect(error.message, contains('bad-window'));
    expect(old.isRetiring, isFalse);
    expect(sessionRepo.updateCalls, 0);
  });

  test('重复切换被拒绝：第二个切换在第一个结束前报"重复切换"', () async {
    final f = factory();
    await f.create(session);
    final gate = Completer<void>();
    final started = Completer<void>();
    final controller = controllerFor(f, retireAgent: (a) async {
      started.complete();
      await gate.future;
      await a.retire();
    });

    final first = controller.switchTemplate(session, 'reviewer',
        callbacks: const AgentCallbacks());
    await started.future;
    final secondError = await _errorOf(
        controller.switchTemplate(session, 'general', callbacks: const AgentCallbacks()));
    // ignore: avoid_print
    print('  [OBS] 重复切换报错：$secondError');
    expect(secondError.stage, AgentSwitchStage.busy);
    expect(controller.isSwitching('s1'), isTrue);

    gate.complete();
    final fresh = await first;
    expect(fresh.agentTypeName, 'reviewer');
    expect(controller.isSwitching('s1'), isFalse);
  });

  test('退役失败：报退役阶段与候选名，旧实例仍注册、数据库不变', () async {
    final f = factory();
    final old = await f.create(session);
    final controller = controllerFor(f,
        retireAgent: (_) async => throw StateError('退役注入失败'));
    final error = await _errorOf(controller.switchTemplate(session, 'reviewer',
        callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 退役失败：$error');
    expect(error.stage, AgentSwitchStage.retire);
    expect(error.candidateName, 'reviewer');
    expect(error.message, contains('退役注入失败'));
    expect(identical(agents.lookup('s1'), old), isTrue,
        reason: '退役失败时旧实例不得被移除');
    expect(old.isRetiring, isFalse);
    expect(sessionRepo.updateCalls, 0);
    expect(sessionRepo.sessions.single.agentType, 'general');
  });

  test('写库失败：报持久化阶段与候选名，不创建新实例', () async {
    final f = factory();
    final old = await f.create(session);
    sessionRepo.failUpdate = true;
    final error = await _errorOf(controllerFor(f).switchTemplate(session, 'reviewer',
        callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 写库失败：$error');
    expect(error.stage, AgentSwitchStage.persist);
    expect(error.candidateName, 'reviewer');
    expect(agents.lookup('s1'), isNull);
    expect(old.isRetiring, isTrue, reason: '退役已经发生（顺序要求先退役再写库）');
    expect(sessionRepo.sessions.single.agentType, 'general');
  });

  test('创建失败：报创建阶段与候选名，数据库已是新模板但没有实例', () async {
    final failing = _FailingCreateFactory(
      templates: templates,
      providerResolver: () => providerResolver,
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
    await failing.create(session);
    failing.failNextCreate = true;
    final error = await _errorOf(controllerFor(failing).switchTemplate(
        session, 'reviewer', callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 创建失败：$error');
    expect(error.stage, AgentSwitchStage.create);
    expect(error.candidateName, 'reviewer');
    expect(error.message, contains('创建注入失败'));
    expect(agents.lookup('s1'), isNull, reason: '创建失败不得登记新实例');
    expect(sessionRepo.sessions.single.agentType, 'reviewer',
        reason: '数据库已经持久化（界面必须回读它才与实际一致）');
  });

  test('未找到 Session：写库阶段失败，不创建实例', () async {
    final f = factory();
    final ghost = Session(
      id: 'ghost-session',
      title: 'ghost',
      agentType: 'general',
      createdAt: 1,
      updatedAt: 1,
    );
    final error = await _errorOf(
        controllerFor(f).switchTemplate(ghost, 'reviewer', callbacks: const AgentCallbacks()));

    // ignore: avoid_print
    print('  [OBS] 未找到 Session：$error');
    expect(error.stage, AgentSwitchStage.persist);
    expect(agents.lookup('ghost-session'), isNull);
    expect(sidecar.ensureContextCalls, isEmpty, reason: '不得为已删除的 Session 建上下文');
    expect(sessionRepo.updateCalls, 1);
  });

  test('退役不调用 cancelRequest / disposeContext，且在途整轮自然结束', () async {
    final f = factory();
    final received = <String>[];
    final replies = <String>[];
    final old = await f.create(session,
        callbacks: AgentCallbacks(
          onUserMessage: (m) => received.add(m.content),
          onAssistantMessage: (m, _) => replies.add(m.content),
        ));
    sidecar.queueChunk('在途回复');
    sidecar.queueDone();
    sidecar.gateNextSend();
    final sendFuture = old.send('在途消息');

    final switched = <Agent>[];
    final controller = controllerFor(f);
    final switchFuture = controller.switchTemplate(
        session, 'reviewer',
        callbacks: AgentCallbacks(
          onUserMessage: (m) => received.add(m.content),
          onAssistantMessage: (m, _) => replies.add(m.content),
        ));
    // 让预检与退役真正开始等待在途整轮。
    await Future<void>.delayed(Duration.zero);
    expect(old.isRetiring, isTrue);
    // 在途请求还停在闸门上：此时若退役调了 cancelRequest 就会出现在这里。
    expect(sidecar.cancelHandles, isEmpty,
        reason: '退役不得中断在途请求（cancelRequest）');
    expect(sidecar.disposeContextCalls, isEmpty, reason: '退役不得 disposeContext');

    sidecar.releaseGate();
    await switchFuture;
    switched.add(agents.lookup('s1')!);
    await sendFuture;

    // ignore: avoid_print
    print('  [OBS] 退役后 cancel=${sidecar.cancelHandles} '
        'dispose=${sidecar.disposeContextCalls} ensure=${sidecar.ensureContextCalls} '
        '新实例 workspaceInitialized=${switched.single.workspaceInitialized} '
        '旧实例收到的回复=$replies');
    expect(sidecar.disposeContextCalls, isEmpty);
    expect(switched.single.agentTypeName, 'reviewer');
    expect(switched.single.workspaceInitialized, isFalse,
        reason: '同一 Session 再次 ensureContext 必须 created:false（不重设工作区）');
    expect(sidecar.ensureContextCalls, ['s1', 's1'],
        reason: '旧实例与新实例用的是同一个 Session 句柄');
    expect(replies, ['在途回复'], reason: '旧实例的在途整轮自然完成，回复照常送达');
    expect(received, ['在途消息']);
    expect(old.isDisposed, isFalse, reason: '退役不等于销毁');
  });

  test('删除进行中切换被拒绝；切换进行中删除等待结束后重读 Session', () async {
    final f = factory();
    await f.create(session);
    final gate = Completer<void>();
    final started = Completer<void>();
    final controller = controllerFor(f, retireAgent: (a) async {
      started.complete();
      await gate.future;
      await a.retire();
    });

    final switchFuture =
        controller.switchTemplate(session, 'reviewer', callbacks: const AgentCallbacks());
    await started.future;

    // 切换进行中删除：必须等切换结束，并重读到新模板名。
    var deleteDone = false;
    final deleteFuture = controller.beginDelete('s1').then((s) {
      deleteDone = true;
      return s;
    });
    await Future<void>.delayed(Duration.zero);
    expect(deleteDone, isFalse, reason: '切换还没结束，删除不得先返回');
    final deletingError = await _errorOf(
        controller.switchTemplate(session, 'general', callbacks: const AgentCallbacks()));
    // ignore: avoid_print
    print('  [OBS] 删除期间切换报错：$deletingError');
    expect(deletingError.stage, AgentSwitchStage.deleting);

    gate.complete();
    final fresh = await switchFuture;
    final reread = await deleteFuture;
    // ignore: avoid_print
    print('  [OBS] 删除前重读 Session：agentType=${reread?.agentType} '
        '新实例模板=${fresh.agentTypeName}');
    expect(reread, isNotNull);
    expect(reread!.agentType, 'reviewer', reason: '删除前必须重读到切换后的值');
    expect(identical(fresh, agents.lookup('s1')), isTrue);
    controller.endDelete('s1');
    expect(controller.isDeleting('s1'), isFalse);
  });
}

/// 取一次切换失败的具体异常（同时断言它确实是 [AgentSwitchException]）。
Future<AgentSwitchException> _errorOf(Future<Agent> future) async {
  try {
    await future;
  } on AgentSwitchException catch (e) {
    return e;
  }
  fail('这次切换必须失败，但成功了');
}

/// 记录写库次数 / 调用顺序，并按需注入写库失败。
class _RecordingSessionRepo extends FakeSessionRepository {
  _RecordingSessionRepo(super.sessions);

  int updateCalls = 0;
  int getCalls = 0;
  bool failUpdate = false;
  void Function()? onUpdate;

  @override
  Future<Session?> get(String id) async {
    getCalls++;
    return super.get(id);
  }

  @override
  Future<Session> updateAgentType(String id, String agentType) async {
    updateCalls++;
    if (failUpdate) throw StateError('写库注入失败');
    onUpdate?.call();
    return super.updateAgentType(id, agentType);
  }
}

/// 创建可以注入失败的工厂（只覆盖 [AgentFactory.create] 这一个出口）。
class _FailingCreateFactory extends AgentFactory {
  _FailingCreateFactory({
    required super.templates,
    required super.providerResolver,
    required super.config,
    required super.sidecar,
    required super.sessionRepo,
    required super.messageRepo,
    required super.summaryNodeRepo,
    required super.registry,
    super.summaryProvider,
    super.backgroundFoldEnabled,
    super.summaryStoreOpen,
  });

  bool failNextCreate = false;

  @override
  Future<Agent> create(Session session,
      {AgentCallbacks callbacks = const AgentCallbacks()}) {
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('创建注入失败');
    }
    return super.create(session, callbacks: callbacks);
  }
}
