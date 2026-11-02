import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// Agent 真的拥有执行（change `add-agent-object-and-templates` 任务 2.2）。
///
/// 两个实例**不经过界面**交替跑：模型请求、工具结果、摘要调用与消息写入各自归属
/// 自己的会话。如果执行仍然住在 `ChatScreen` 里（只把调用名换成 Agent），这个用例
/// 连跑都跑不起来 —— 它根本没有构造界面。
void main() {
  late _RecordingSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;
  late _RecordingSummaryProvider summaryProvider;

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );

  /// 一段足够长的历史：80 条 × 100 字符，在 2000 token 窗口下必然触发压缩。
  List<Message> longHistory(String sessionId) => [
        for (var i = 0; i < 80; i++)
          Message(
            id: '$sessionId-p$i',
            seq: i + 1,
            sessionId: sessionId,
            role: i.isEven ? 'user' : 'assistant',
            content: 'A' * 100,
            createdAt: i,
          ),
      ];

  setUp(() {
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '你是助手',
      maxContextTokens: 2000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-recorded-key', baseUrl: ''),
      },
    ));
    sidecar = _RecordingSidecar();
    sessionRepo = FakeSessionRepository([session('s1'), session('s2')]);
    msgRepo = FakeMessageRepository();
    msgRepo.messages.addAll(longHistory('s1'));
    msgRepo.messages.addAll(longHistory('s2'));
    agents = AgentRegistry();
    summaryProvider = _RecordingSummaryProvider();
  });

  tearDown(() {
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
        summaryProvider: summaryProvider,
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => false,
      );

  test('两个实例交替执行：请求、工具结果、摘要与写库各归各会话', () async {
    final f = factory();
    final a1 = await f.create(session('s1'));
    final a2 = await f.create(session('s2'));

    // 甲这一轮先带一个工具调用，再给最终回复。
    sidecar.queueToolCall('{"type":"tool_use","id":"tc1","name":"read_file",'
        '"input":{"path":"note.txt"}}');
    sidecar.queueDone();
    sidecar.queueChunk('甲的最终回复');
    sidecar.queueDone();
    await a1.send('继续-甲');

    // 乙正常一轮。
    sidecar.queueChunk('乙的最终回复');
    sidecar.queueDone();
    await a2.send('继续-乙');

    final s1Requests = sidecar.requests.where((r) => r.handle == 's1').toList();
    final s2Requests = sidecar.requests.where((r) => r.handle == 's2').toList();
    final s1Summaries = summaryProvider.calls.where((c) => c == 's1').length;
    final s2Summaries = summaryProvider.calls.where((c) => c == 's2').length;
    // ignore: avoid_print
    print('  [OBS] 请求句柄=${sidecar.requests.map((r) => r.handle).toList()} '
        '工具句柄=${sidecar.toolHandles} '
        '摘要调用=${summaryProvider.calls} '
        '甲请求数=${s1Requests.length} 乙请求数=${s2Requests.length}');

    expect(s1Requests.length, 2, reason: '甲这一轮：工具轮 + 最终回复，两次请求');
    expect(s2Requests.length, 1);
    expect(s1Summaries, greaterThan(0), reason: '甲的长历史必须触发自己的摘要调用');
    expect(s2Summaries, greaterThan(0), reason: '乙的长历史必须触发自己的摘要调用');
    expect(sidecar.toolHandles.toSet(), {'s1'},
        reason: '甲的工具调用只打甲的句柄');

    // 每个请求的上下文只含自己会话的摘要标记，绝不串到另一个会话。
    for (final r in s1Requests) {
      expect(r.messagesJson, contains('SUMMARY s1'));
      expect(r.messagesJson, isNot(contains('SUMMARY s2')));
      expect(r.model, 'test-model');
    }
    for (final r in s2Requests) {
      expect(r.messagesJson, contains('SUMMARY s2'));
      expect(r.messagesJson, isNot(contains('SUMMARY s1')));
    }

    // 消息历史与写库按会话分开。
    expect(a1.messageHistory.every((m) => m.sessionId == 's1'), isTrue);
    expect(a2.messageHistory.every((m) => m.sessionId == 's2'), isTrue);
    expect(a1.messageHistory.any((m) => m.content == '甲的最终回复'), isTrue);
    expect(a1.messageHistory.any((m) => m.content == '乙的最终回复'), isFalse);
    expect(a2.messageHistory.any((m) => m.content == '乙的最终回复'), isTrue);
    expect(a2.messageHistory.any((m) => m.content == '甲的最终回复'), isFalse);

    final s1Writes = msgRepo.messages.where((m) => m.sessionId == 's1').toList();
    final s2Writes = msgRepo.messages.where((m) => m.sessionId == 's2').toList();
    expect(s1Writes.any((m) => m.content == '继续-甲'), isTrue);
    expect(s1Writes.any((m) => m.content == '甲的最终回复'), isTrue);
    expect(s1Writes.any((m) => m.content.contains('乙')), isFalse);
    expect(s2Writes.any((m) => m.content == '继续-乙'), isTrue);
    expect(s2Writes.any((m) => m.content == '乙的最终回复'), isTrue);

    // 甲的工具轮把结果补写进自己那条 assistant 消息（另一会话没有这条记录）。
    final toolMsgs =
        s1Writes.where((m) => m.toolCallsJson?.contains('read_file') == true);
    expect(toolMsgs, isNotEmpty);
    expect(toolMsgs.every((m) => m.sessionId == 's1'), isTrue);
    expect(toolMsgs.any((m) => m.toolCallsJson!.contains('fake content')), isTrue,
        reason: '工具结果必须补写进甲的 intermediate 消息，且不落到乙');
    expect(s2Writes.any((m) => m.toolCallsJson?.contains('read_file') == true),
        isFalse);
  });

  test('取消与销毁按实例归属：取消甲不结束乙的请求', () async {
    final f = factory();
    final a1 = await f.create(session('s1'));
    final a2 = await f.create(session('s2'));

    sidecar.queueChunk('甲回复');
    sidecar.queueDone();
    sidecar.gateNextSend();
    final send1 = a1.send('甲先发');
    for (var i = 0; i < 100 && sidecar.sendHandles.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    a1.cancel();
    sidecar.releaseGate();
    await send1;

    sidecar.queueChunk('乙回复');
    sidecar.queueDone();
    await a2.send('乙再发');

    // ignore: avoid_print
    print('  [OBS] cancelHandles=${sidecar.cancelHandles} '
        'sendHandles=${sidecar.sendHandles} '
        '乙历史含回复=${a2.messageHistory.any((m) => m.content == '乙回复')}');
    // 每个正常轮次收尾时 Agent 也会取消自己那一轮的请求（与旧路径一致），
    // 所以这里看的是"甲多出来的那一次取消"：显式 cancel 让甲的计数比乙多。
    final s1Cancels = sidecar.cancelHandles.where((h) => h == 's1').length;
    final s2Cancels = sidecar.cancelHandles.where((h) => h == 's2').length;
    expect(s1Cancels, greaterThan(s2Cancels),
        reason: '取消甲是额外的一次定向取消，且只打甲的句柄');
    expect(sidecar.sendHandles, ['s1', 's2'],
        reason: '乙的请求还在，且没有被甲的取消打断');
    expect(a2.messageHistory.any((m) => m.content == '乙回复'), isTrue);
    expect(a1.messageHistory.any((m) => m.content == '甲回复'), isFalse,
        reason: '被取消的甲这一轮不许落库');
  });
}

/// 记录每次请求的句柄、上下文与参数（FakeSidecar 只留最后一次）。
class _RecordingSidecar extends FakeSidecar {
  final List<
      ({
        String handle,
        String messagesJson,
        String model,
        String systemPrompt,
        String toolsJson,
        String thinkingMode,
        String thinkingEffort,
      })> requests = [];

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
    requests.add((
      handle: handle,
      messagesJson: messagesJson,
      model: model,
      systemPrompt: systemPrompt,
      toolsJson: toolsJson,
      thinkingMode: thinkingMode,
      thinkingEffort: thinkingEffort,
    ));
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

/// 记录每次摘要调用的会话句柄，并在正文里带上会话标记（用来核对不串）。
class _RecordingSummaryProvider implements SummaryProvider {
  final List<String> calls = [];

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
    String? sessionId,
  }) async {
    calls.add(sessionId ?? '(null)');
    final lo = folded.isEmpty ? 0 : (folded.first.seq ?? 0);
    final hi = folded.isEmpty ? 0 : (folded.last.seq ?? 0);
    return SummaryResult(
      text: 'SUMMARY ${sessionId ?? "(null)"} seq $lo..$hi',
      tokens: 20,
    );
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
    String? sessionId,
  }) async {
    calls.add(sessionId ?? '(null)');
    return SummaryResult(text: 'SUMMARY ${sessionId ?? "(null)"}', tokens: 20);
  }
}
