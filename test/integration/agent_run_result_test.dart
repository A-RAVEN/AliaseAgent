// Agent.send 的结构化运行结果（add-spawn-subagent-tool 任务 3.1）。
//
// 四类结果（完成 / 失败 / 取消 / 实例忙）必须在同一入口上可区分：
//   - 最终文本只来自**没有工具调用的最终模型轮**，不能从历史里随便取最后一条；
//   - 模型错误、未预期异常进入失败结果，错误消息不重复写库；
//   - 取消不伪装成成功；实例正忙时第二次调用不开始、不发请求。
//
// 每条断言前都打印实际结果与落库消息，失败时能直接看出是哪一类被混淆了。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 写助手消息时抛异常：用来制造模型循环里的**未预期异常**。
/// （用户消息要正常写，否则异常发生在 try 之外，测不到这条路径。）
class _ExplodingAssistantRepo extends FakeMessageRepository {
  @override
  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    String? toolCallsJson,
    String? thinkingJson,
    int? tokenCount,
    int? outputTokenCount,
    List<String> attachments = const [],
  }) async {
    if (role == 'assistant') {
      throw StateError('写库炸了-独特');
    }
    return super.insert(
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      attachments: attachments,
    );
  }
}

void main() {
  late FakeSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late List<Message> assistantEvents;
  late List<bool> streamingEvents;
  late AgentCallbacks callbacks;

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  setUp(() {
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '你是助手',
      maxContextTokens: 100000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: ''),
      },
    ));
    sidecar = FakeSidecar();
    sessionRepo = FakeSessionRepository([session('s1')]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
    assistantEvents = [];
    streamingEvents = [];
    callbacks = AgentCallbacks(
      onAssistantMessage: (m, isFinal) => assistantEvents.add(m),
      onStreamingChanged: (v) => streamingEvents.add(v),
    );
  });

  tearDown(() {
    registry.clear();
    resolver = null;
  });

  AgentFactory factory({MessageRepository? messageRepo}) => AgentFactory(
        templates: registry,
        providerResolver: () => resolver,
        config: const AppConfig(version: 1),
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        messageRepo: messageRepo ?? msgRepo,
        summaryNodeRepo: SummaryNodeRepository(),
        registry: agents,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  Future<Agent> create({MessageRepository? messageRepo}) =>
      factory(messageRepo: messageRepo).create(session('s1'), callbacks: callbacks);

  /// 等实例真的进入流式状态（send 的第一次 await 之后才置位）。
  Future<void> waitStreaming(Agent agent) async {
    for (var i = 0; i < 100; i++) {
      if (agent.isStreaming) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('实例没有进入流式状态，后面的取消 / 忙用例测不到目标路径');
  }

  void dump(String label, AgentRunResult result) {
    // ignore: avoid_print
    print('[OBS] $label => status=${result.status.name} '
        'finalText=${result.finalText} error=${result.error} '
        'metering=${result.metering.toJson()} '
        '落库=${msgRepo.messages.map((m) => '${m.role}:${m.content}').toList()} '
        '助手回调=${assistantEvents.length} 流式事件=$streamingEvents');
  }

  test('中间工具轮后成功：最终文本只来自无工具调用的最终轮', () async {
    final agent = await create();
    // 第一轮：带文字的中间回复 + 一个工具调用。
    sidecar.queueChunk('中间文本-独特');
    sidecar.queueToolCall('{"type":"tool_use","id":"tc1","name":"read_file",'
        '"input":{"path":"note.txt"}}');
    sidecar.queueDone(inputTokens: 11, outputTokens: 3);
    // 第二轮：没有工具调用的最终回复。
    sidecar.queueChunk('最终回复-独特');
    sidecar.queueDone(inputTokens: 7, outputTokens: 5);

    final result = await agent.send('做一件事');
    dump('工具轮后成功', result);

    expect(result.status, AgentRunStatus.completed);
    expect(result.isCompleted, isTrue);
    expect(result.finalText, '最终回复-独特',
        reason: '最终文本必须是最后一轮回复，不能是中间工具轮或工具输出');
    expect(result.finalText, isNot('中间文本-独特'));
    expect(result.error, isNull);
    // 计量快照是这次发送自己的真实累计值，不是示例里的零。
    expect(result.metering.requests, 2);
    expect(result.metering.toolCalls, 1);
    expect(result.metering.inputTokens, 18);
    expect(result.metering.outputTokens, 8);
    expect(result.metering.totalTokens, 26);
    // 中间消息与最终消息都照旧写库，界面事件最后一条是最终回复。
    expect(msgRepo.messages.length, 3, reason: '用户 + 中间助手 + 最终助手');
    expect(msgRepo.messages.last.content, '最终回复-独特');
    expect(assistantEvents.last.content, '最终回复-独特');
    expect(agent.isStreaming, isFalse);
  });

  test('模型错误：失败结果带原始错误，错误消息只写一条', () async {
    final agent = await create();
    sidecar.queueDone(code: 1, error: '模型炸了-独特');

    final result = await agent.send('会失败的一轮');
    dump('模型错误', result);

    expect(result.status, AgentRunStatus.failed);
    expect(result.error, '模型炸了-独特');
    expect(result.finalText, isNull, reason: '失败不得携带成功结论');
    final errorMsgs =
        msgRepo.messages.where((m) => m.content.startsWith('Error:')).toList();
    expect(errorMsgs.length, 1,
        reason: '错误消息只写一条，界面与运行结果两条路径不得重复写库');
    expect(errorMsgs.single.content, 'Error: 模型炸了-独特');
    expect(assistantEvents.length, 1, reason: '界面只收到这一条错误消息');
    expect(agent.isStreaming, isFalse);
  });

  test('取消：返回取消结果，不产生成功结论', () async {
    final agent = await create();
    sidecar.gateNextSend();
    sidecar.queueChunk('取消前的半截文本');
    sidecar.queueDone();

    final sendFuture = agent.send('会被取消的一轮');
    await waitStreaming(agent);
    agent.cancel();
    sidecar.releaseGate();
    final result = await sendFuture;
    dump('取消', result);

    expect(result.status, AgentRunStatus.cancelled);
    expect(result.isCancelled, isTrue);
    expect(result.finalText, isNull, reason: '取消不得返回成功文本');
    expect(
        msgRepo.messages.where((m) => m.role == 'assistant'), isEmpty,
        reason: '取消的轮次不该有助手消息落库');
    expect(agent.isStreaming, isFalse);
  });

  test('空最终文本：完成但文本为空，不伪造助手消息', () async {
    final agent = await create();
    // 只有 done、没有任何文本：模型循环自然结束但没有最终文本。
    sidecar.queueDone();

    final result = await agent.send('得到一个空回复');
    dump('空最终文本', result);

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '');
    expect(
        msgRepo.messages.where((m) => m.role == 'assistant'), isEmpty,
        reason: '空文本不写助手消息（与既有界面行为一致）');
    expect(assistantEvents, isEmpty);
    expect(agent.isStreaming, isFalse);
  });

  test('实例忙：第二次调用立即返回忙，不发第二个请求', () async {
    final agent = await create();
    sidecar.gateNextSend();
    sidecar.queueChunk('第一条的回复');
    sidecar.queueDone();

    final first = agent.send('第一条');
    await waitStreaming(agent);
    final busy = await agent.send('第二条');
    dump('实例忙', busy);

    expect(busy.status, AgentRunStatus.busy);
    expect(busy.isBusy, isTrue);
    expect(busy.finalText, isNull);
    expect(sidecar.sendHandles.length, 1,
        reason: '忙实例不得为第二次调用发起模型请求');
    expect(
        msgRepo.messages.where((m) => m.content == '第二条'), isEmpty,
        reason: '忙实例不得把第二次调用写进历史');

    sidecar.releaseGate();
    final firstResult = await first;
    // ignore: avoid_print
    print('[OBS] 第一条结果 => status=${firstResult.status.name} '
        'finalText=${firstResult.finalText}');
    expect(firstResult.isCompleted, isTrue);
    expect(firstResult.finalText, '第一条的回复');
  });

  test('未预期异常：进入失败结果，不写重复错误消息，流式状态收尾', () async {
    final explodingRepo = _ExplodingAssistantRepo();
    final agent = await create(messageRepo: explodingRepo);
    sidecar.queueChunk('要写库的回复');
    sidecar.queueDone();

    final result = await agent.send('会触发写库异常的一轮');
    // ignore: avoid_print
    print('[OBS] 未预期异常 => status=${result.status.name} '
        'error=${result.error} 落库=${
        explodingRepo.messages.map((m) => '${m.role}:${m.content}').toList()} '
        '助手回调=${assistantEvents.length} 流式事件=$streamingEvents');

    expect(result.status, AgentRunStatus.failed);
    expect(result.error, contains('写库炸了-独特'));
    expect(result.finalText, isNull);
    expect(
        explodingRepo.messages.where((m) => m.content.startsWith('Error:')),
        isEmpty,
        reason: '未预期异常走既有路径不额外写错误消息，避免重复');
    expect(assistantEvents, isEmpty);
    expect(agent.isStreaming, isFalse, reason: '异常后流式标记必须收尾');
  });
}
