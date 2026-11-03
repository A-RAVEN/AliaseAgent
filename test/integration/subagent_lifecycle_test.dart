// 子运行的生命周期：取消、销毁、退役与清理边界（add-spawn-subagent-tool 任务 5.1）。
//
// 事件日志来自 `_LifecycleSidecar`（取消句柄顺序、disposeContext 顺序）与
// `SubagentRunner.activeRelations`。每条断言都指向一个具体的顺序或残留状态：
//   - 单独取消子运行只取消子，父继续并收到可区分的取消错误；
//   - 父 cancel / dispose 先取消活动子 Agent，再取消/销毁父，且等子清理结束；
//   - 父 retire（模板切换）不取消在途子调用，子整轮自然结束；
//   - 所有出口都销毁子上下文、移除子实例、解除关系，但保留子会话数据库记录；
//   - 清理失败返回 cleanup_failed，不伪装成资源已释放。
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 可以卡住"子句柄的 sendMessage"、并能让子上下文销毁失败的假 sidecar。
class _LifecycleSidecar extends FakeSidecar {
  /// 非空时，所有非父句柄（= 子 Agent）的 sendMessage 都等它完成才回放事件。
  Completer<void>? childGate;

  /// 子句柄的 disposeContext 在记录一次尝试后抛错（模拟排空失败）。
  bool failChildDispose = false;

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
  }) async {
    final gate = childGate;
    if (handle != 'parent-1' && gate != null) {
      await gate.future;
    }
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

  @override
  Future<void> disposeContext(String sessionId) async {
    await super.disposeContext(sessionId);
    if (sessionId != 'parent-1' && failChildDispose) {
      throw StateError('子上下文排空失败-独特');
    }
  }
}

void main() {
  late _LifecycleSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late SubagentRunner runner;
  late AgentFactory factory;

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

  Future<Agent> buildParent() async {
    final parent =
        await factory.create(session('parent-1', 'general'));
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');
    return parent;
  }

  void queueSpawnToolCall() {
    sidecar.queueToolCall('{"type":"tool_use","id":"spawn-1",'
        '"name":"spawn_subagent","input":{"task":"子任务-生命周期","agent_type":"worker"}}');
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
      model: 'parent-model',
      systemPrompt: 'PARENT-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'worker',
      provider: 'test',
      model: 'worker-model',
      systemPrompt: 'WORKER-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      maxContextTokens: 80000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = _LifecycleSidecar();
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
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
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  Future<String> waitChildRunning() async {
    for (var i = 0; i < 200; i++) {
      final relation = runner.activeRelations['parent-1'];
      if (relation != null && relation.isNotEmpty) return relation.single;
      await Future<void>.delayed(Duration.zero);
    }
    fail('子运行没有进入活动关系表，后面的取消/清理断言测不到');
  }

  test('单独取消子运行：只取消子，父继续；子清理完成且记录保留', () async {
    final parent = await buildParent();
    sidecar.childGate = Completer<void>();
    queueSpawnToolCall();
    sidecar.queueDone();
    // 子的事件：取消后即使回放也只会得到 cancelled。
    sidecar.queueChunk('子被取消前的文本');
    sidecar.queueDone();
    // 父第二轮：收到取消错误后继续。
    sidecar.queueChunk('父收到子取消后继续-独特');
    sidecar.queueDone();

    final sendFuture = parent.send('父问题');
    final childId = await waitChildRunning();
    expect(runner.cancelChild(childId), isTrue, reason: '活动关系里应能找到该子运行');
    sidecar.childGate!.complete();
    final result = await sendFuture;

    final parentSecond = sidecar.lastMessagesJson ?? '';
    // ignore: avoid_print
    print('[OBS] 子单独取消：父结果=${result.status.name}/${result.finalText} '
        '子句柄=$childId 关系表=${runner.activeRelations} '
        'cancelHandles=${sidecar.cancelHandles} '
        'disposeContext=${sidecar.disposeContextCalls} '
        '子实例还在注册表=${agents.contains(childId)} '
        '子记录还在=${sessionRepo.sessions.any((s) => s.id == childId)}');

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '父收到子取消后继续-独特');
    expect(parentSecond, contains('子 Agent 被取消'),
        reason: '父模型必须收到可区分的取消结果');
    expect(runner.activeRelations, isEmpty, reason: '活动关系必须解除');
    expect(sidecar.disposeContextCalls, contains(childId),
        reason: '子上下文必须被销毁');
    expect(sidecar.disposeContextCalls, isNot(contains('parent-1')),
        reason: '单独取消子不得销毁父上下文');
    expect(agents.contains(childId), isFalse, reason: '子实例必须从注册表移除');
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue,
        reason: '子会话数据库记录不因清理而删除');
  });

  test('父取消：先取消子再取消父请求，父轮次以取消结束', () async {
    final parent = await buildParent();
    sidecar.childGate = Completer<void>();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子文本');
    sidecar.queueDone();

    final sendFuture = parent.send('父问题');
    final childId = await waitChildRunning();
    parent.cancel();
    final cancels = List<String>.from(sidecar.cancelHandles);
    final childAt = cancels.indexOf(childId);
    final parentAt = cancels.indexOf('parent-1');
    // ignore: avoid_print
    print('[OBS] 父取消：取消顺序=$cancels 子位置=$childAt 父位置=$parentAt');
    expect(childAt, isNot(-1), reason: '父取消必须先取消活动子 Agent');
    expect(parentAt, isNot(-1), reason: '父自己的请求也要取消');
    expect(childAt, lessThan(parentAt), reason: '顺序必须是先子后父');

    sidecar.childGate!.complete();
    final result = await sendFuture;
    // ignore: avoid_print
    print('[OBS] 父取消：结果=${result.status.name} 关系表=${runner.activeRelations} '
        'disposeContext=${sidecar.disposeContextCalls}');
    expect(result.status, AgentRunStatus.cancelled);
    expect(runner.activeRelations, isEmpty);
    expect(sidecar.disposeContextCalls, contains(childId),
        reason: '取消出口也要完成子清理');
    expect(agents.contains(childId), isFalse);
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue,
        reason: '取消不删除子会话记录');
  });

  test('父销毁：等子整轮与清理结束后才销毁父上下文', () async {
    final parent = await buildParent();
    sidecar.childGate = Completer<void>();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子文本');
    sidecar.queueDone();

    final sendFuture = parent.send('父问题');
    final childId = await waitChildRunning();
    final disposeFuture = parent.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(runner.activeRelations, isNotEmpty,
        reason: '子还在跑时父销毁不得提前完成');
    sidecar.childGate!.complete();
    await disposeFuture;
    final result = await sendFuture;

    // ignore: avoid_print
    print('[OBS] 父销毁：销毁顺序=${sidecar.disposeContextCalls} '
        '父结果=${result.status.name} 关系表=${runner.activeRelations}');
    final disposes = sidecar.disposeContextCalls;
    expect(disposes, contains(childId));
    expect(disposes, contains('parent-1'));
    expect(disposes.indexOf(childId), lessThan(disposes.indexOf('parent-1')),
        reason: '先销毁子上下文，再销毁父上下文');
    expect(result.status, AgentRunStatus.cancelled);
    expect(runner.activeRelations, isEmpty);
    expect(agents.contains(childId), isFalse);
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue,
        reason: '父销毁不删除子会话记录');
  });

  test('模板切换（父退役）：不取消在途子调用，子整轮自然结束后才退役', () async {
    final parent = await buildParent();
    sidecar.childGate = Completer<void>();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子自然结论-独特');
    sidecar.queueDone();
    sidecar.queueChunk('父最终回复-独特');
    sidecar.queueDone();

    final sendFuture = parent.send('父问题');
    final childId = await waitChildRunning();
    final cancelsBefore = sidecar.cancelCount;
    final retireFuture = parent.retire();
    await Future<void>.delayed(Duration.zero);
    // ignore: avoid_print
    print('[OBS] 退役等待中：父退役=${parent.isRetiring} '
        '取消增量=${sidecar.cancelCount - cancelsBefore} '
        '关系表=${runner.activeRelations}');
    expect(parent.isRetiring, isTrue);
    expect(sidecar.cancelCount, cancelsBefore,
        reason: '退役不得取消子调用或父在途整轮');

    sidecar.childGate!.complete();
    final result = await sendFuture;
    await retireFuture;
    // ignore: avoid_print
    print('[OBS] 退役结束：父结果=${result.status.name}/${result.finalText} '
        '关系表=${runner.activeRelations} disposeContext=${sidecar.disposeContextCalls}');

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '父最终回复-独特');
    expect(runner.activeRelations, isEmpty);
    expect(sidecar.disposeContextCalls, contains(childId),
        reason: '子整轮自然结束后仍要清理子上下文');
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue);
  });

  test('清理失败：返回 cleanup_failed，不假装资源已释放；记录仍保留', () async {
    sidecar.failChildDispose = true;
    final parent = await buildParent();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子正常结论-独特');
    sidecar.queueDone();
    sidecar.queueChunk('父收到清理失败后继续-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题');
    final parentSecond = sidecar.lastMessagesJson ?? '';
    final childId =
        sessionRepo.sessions.firstWhere((s) => s.parentSessionId == 'parent-1').id;
    // ignore: avoid_print
    print('[OBS] 清理失败：父结果=${result.status.name}/${result.finalText} '
        '父第二请求=$parentSecond 关系表=${runner.activeRelations} '
        '子实例还在注册表=${agents.contains(childId)} '
        'disposeContext=${sidecar.disposeContextCalls}');

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '父收到清理失败后继续-独特');
    expect(parentSecond, contains('cleanup_failed'),
        reason: '清理失败必须以可区分错误交给父模型，不得返回成功资源已释放');
    expect(parentSecond, contains('子上下文排空失败-独特'));
    expect(runner.activeRelations, isEmpty, reason: '关系仍要解除');
    expect(agents.contains(childId), isFalse, reason: '实例仍要从注册表移除');
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue,
        reason: '清理失败也不删子会话记录');
    debugPrint('[OBS] 清理失败时父的最终助手消息='
        '${parent.messageHistory.map((m) => m.content).toList()}');
  });

  // ---------------------------------------------------------------------------
  // 5.2 应用销毁路径：ChatScreen.dispose 调的就是 AgentRegistry.disposeAll()
  // （先取消、再等整轮与子清理）。这里走同一个入口，验证活动子运行不会留下。
  // ---------------------------------------------------------------------------
  test('应用销毁（disposeAll）：取消并清理活动子运行，再销毁父上下文', () async {
    final parent = await buildParent();
    sidecar.childGate = Completer<void>();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子文本');
    sidecar.queueDone();

    final sendFuture = parent.send('父问题');
    final childId = await waitChildRunning();
    final disposeAllFuture = agents.disposeAll();
    await Future<void>.delayed(Duration.zero);
    final cancelsBeforeRelease = List<String>.from(sidecar.cancelHandles);
    // ignore: avoid_print
    print('[OBS] 应用销毁等待中：关系表=${runner.activeRelations} '
        '取消记录=$cancelsBeforeRelease');
    expect(cancelsBeforeRelease, contains(childId),
        reason: 'disposeAll 必须先取消活动子 Agent');

    sidecar.childGate!.complete();
    await disposeAllFuture;
    final result = await sendFuture;
    // ignore: avoid_print
    print('[OBS] 应用销毁完成：父结果=${result.status.name} '
        'disposeContext=${sidecar.disposeContextCalls} '
        '关系表=${runner.activeRelations} 注册表=${agents.handles}');

    expect(result.status, AgentRunStatus.cancelled);
    expect(runner.activeRelations, isEmpty);
    expect(sidecar.disposeContextCalls, contains(childId));
    expect(sidecar.disposeContextCalls, contains('parent-1'));
    expect(sidecar.disposeContextCalls.indexOf(childId),
        lessThan(sidecar.disposeContextCalls.indexOf('parent-1')),
        reason: '子上下文必须先于父上下文销毁');
    expect(agents.handles, isEmpty, reason: 'disposeAll 之后注册表为空');
    expect(sessionRepo.sessions.any((s) => s.id == childId), isTrue,
        reason: '应用销毁不删除子会话记录');
  });
}
