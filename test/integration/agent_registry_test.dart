import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// Agent 的创建、登记与销毁（change `add-agent-object-and-templates` 任务 2.1）。
///
/// 固定的是：工厂确保上下文并**只在 created:true 时设置缺省工作区**、运行实例按
/// 句柄登记、销毁先等整轮 Future（含写库）再 `disposeContext`、其它实例不受影响。
void main() {
  Session session(String id, {String agentType = 'general'}) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;

  setUp(() {
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-fake', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
  });

  tearDown(() {
    registry.clear();
    resolver = null;
  });

  AgentFactory factory({bool backgroundFold = false}) => AgentFactory(
        templates: registry,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        messageRepo: msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: backgroundFold,
        summaryStoreOpen: () => false,
      );

  test('工厂确保上下文；只在 created:true 时设置记录的缺省工作区', () async {
    sidecar.stubCreated('s-fresh', true);
    sidecar.stubCreated('s-existing', false);
    final f = factory();

    final fresh = await f.create(session('s-fresh'));
    final existing = await f.create(session('s-existing'));

    // ignore: avoid_print
    print('  [OBS] ensureContext 收到的缺省工作区=${sidecar.ensureContextDefaultWorkspaces}；'
        'fresh.workspaceInitialized=${fresh.workspaceInitialized} '
        'existing.workspaceInitialized=${existing.workspaceInitialized}');

    expect(sidecar.ensureContextCalls, containsAll(['s-fresh', 's-existing']));
    expect(sidecar.ensureContextDefaultWorkspaces,
        everyElement(ConfigService.homeDir),
        reason: '工厂把用户主目录作为缺省工作区交下去');
    expect(fresh.workspaceInitialized, isTrue,
        reason: 'created:true ⇒ 这个实例确实设置了缺省工作区');
    expect(existing.workspaceInitialized, isFalse,
        reason: 'created:false ⇒ 已有工作区不能被覆盖');
  });

  test('运行实例按句柄登记；再次 ensure 复用同一实例', () async {
    final f = factory();
    final a1 = await f.create(session('s1'));
    final a2 = await f.ensure(session('s1'));
    final a3 = await f.create(session('s2'));

    // ignore: avoid_print
    print('  [OBS] registry.handles=${agents.handles} '
        'same instance=${identical(a1, a2)} 不同会话同一对象=${identical(a1, a3)} '
        'ensureContext 次数=${sidecar.ensureContextCalls}');

    expect(agents.lookup('s1'), same(a1));
    expect(a2, same(a1), reason: '已有实例必须复用，不许为同一会话建两份');
    expect(a3, isNot(same(a1)));
    expect(agents.handles.toSet(), {'s1', 's2'});
    expect(a1.config.templateName, 'general');
    expect(a1.config.maxContextTokens, 100000);
  });

  test('销毁先等整轮 Future（含写库），再调 disposeContext；其它实例不受影响', () async {
    // 用一个记录"dispose 那一刻库里已有几条消息"的 sidecar，证明顺序。
    final recording = _RecordingDisposeSidecar(msgRepo);
    sidecar = recording;
    final f = factory();
    final a1 = await f.create(session('s1'));
    final a2 = await f.create(session('s2'));

    // 甲这一轮卡在 sendMessage 里：用户消息已经写库，整轮还没结束。
    sidecar.queueChunk('reply');
    sidecar.queueDone();
    sidecar.gateNextSend();
    final sendFuture = a1.send('第一条消息');
    for (var i = 0; i < 100 && sidecar.sendHandles.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sidecar.sendHandles, ['s1'], reason: '这一轮已经进入甲自己的句柄');

    final disposeFuture = agents.disposeAndRemove('s1');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // ignore: avoid_print
    print('  [OBS] dispose 等待中：disposeContextCalls=${sidecar.disposeContextCalls} '
        '库里消息=${msgRepo.messages.map((m) => '${m.sessionId}:${m.role}').toList()}');
    expect(sidecar.disposeContextCalls, isEmpty,
        reason: '整轮还卡着，不许提前 disposeContext');
    expect(msgRepo.messages.any((m) => m.role == 'user' && m.content == '第一条消息'),
        isTrue,
        reason: '整轮的写库（用户消息）已经发生，dispose 必须等它所在的整轮结束');
    expect(agents.lookup('s2'), same(a2),
        reason: '销毁甲不许把乙从注册表里去掉');

    sidecar.releaseGate();
    await sendFuture;
    await disposeFuture;

    // ignore: avoid_print
    print('  [OBS] dispose 完成后：disposeContextCalls=${sidecar.disposeContextCalls} '
        'dispose 时库里消息数=${recording.messageCountAtDispose} '
        '最终消息数=${msgRepo.messages.length} 注册表=${agents.handles}');

    expect(sidecar.disposeContextCalls, ['s1']);
    expect(recording.messageCountAtDispose, msgRepo.messages.length,
        reason: 'disposeContext 必须发生在最后一次写库之后');
    expect(a1.isDisposed, isTrue);
    expect(agents.lookup('s1'), isNull);
    expect(agents.lookup('s2'), same(a2));

    // 乙照常能发（自己的句柄、自己的历史）。
    sidecar.queueChunk('reply-2');
    sidecar.queueDone();
    await a2.send('乙的消息');
    // ignore: avoid_print
    print('  [OBS] 乙发送后 sendHandles=${sidecar.sendHandles} '
        '乙历史=${a2.messageHistory.map((m) => '${m.role}:${m.content}').toList()}');
    expect(sidecar.sendHandles.last, 's2');
    expect(a2.messageHistory.any((m) => m.content == 'reply-2'), isTrue);
    expect(a2.messageHistory.any((m) => m.content == '第一条消息'), isFalse,
        reason: '两个实例的消息历史不共用');
  });
}

/// 记录 `disposeContext` 被调用那一刻库里的消息条数。
class _RecordingDisposeSidecar extends FakeSidecar {
  final FakeMessageRepository repo;
  int? messageCountAtDispose;

  _RecordingDisposeSidecar(this.repo);

  @override
  Future<void> disposeContext(String sessionId) async {
    messageCountAtDispose = repo.messages.length;
    await super.disposeContext(sessionId);
  }
}
