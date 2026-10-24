import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/context_snapshot.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/ui/context_ring.dart';
import 'package:alias_agent/ui/context_view.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// 占用拆分真的被记进了快照、而且和同一份请求对得上。
///
/// **观测通道**：`_contextSnapshot` 是 `ChatScreenState` 的私有状态，测试读不到它。
/// 能读到的只有两处 —— 顶部那个环（`ContextRing.breakdown`）与切到「真实上下文」后
/// 那一屏拿到的快照（`ContextView.snapshot`）。两条通道都用上：环证明它被送进了界面，
/// 快照证明它与同一份请求绑在一起。

void _setupAgentRegistry({int maxContextTokens = 100000, int waitPercent = 1}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
    compactionWaitThresholdPercent: waitPercent,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Widget _buildApp({
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
  required SummaryProvider summaryProvider,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ),
    ),
  );
}

/// 每条消息的估算 token 数 = [rawPerMsg]。
List<Message> _conv(int n, int rawPerMsg) {
  final len = (rawPerMsg - 4) * 4 - 3;
  return [
    for (var i = 0; i < n; i++)
      Message(
        id: 'p$i',
        seq: i + 1,
        sessionId: 's1',
        role: i.isEven ? 'user' : 'assistant',
        content: 'm${i + 1}:${'A' * (len - 'm${i + 1}:'.length)}',
        createdAt: i,
      ),
  ];
}

class _EchoSummaryProvider implements SummaryProvider {
  /// 这个几何下窗口（10 万）远大于对话（几百 token），压根不会触发压缩，
  /// 所以这个数只是满足接口用，不需要从外面传。
  final int l1Tokens = 40;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) async {
    final lo = folded.isEmpty ? 0 : (folded.first.seq ?? 0);
    final hi = folded.isEmpty ? 0 : (folded.last.seq ?? 0);
    return SummaryResult(text: 'L1 seq $lo..$hi', tokens: l1Tokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async =>
      SummaryResult(text: 'L2 rolled up', tokens: l1Tokens);
}

/// 发一条消息并把帧推进完（假 sidecar 的分片是排好的）。
///
/// 2026-10-18：环的拆分改成按"各层摘要的 tokenCost"算之后，发送路径里多了一次
/// `_summaryNodeRepo.queryBySession` 的 await，快照比原来晚一个异步拍落地 ——
/// 所以要多推一帧。**这是用例跟随时序变化，不是放松判据**：断言本身没动。
Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// 切到「真实上下文」那一屏，读它拿到的快照。
Future<ContextSnapshot> _switchAndReadSnapshot(WidgetTester tester) async {
  await tester.tap(find.text('真实上下文'));
  await tester.pump();
  final view = tester.widget<ContextView>(find.byType(ContextView));
  return view.snapshot!;
}

void main() {
  group('占用拆分的记录（端到端）', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('4.1 快照与拆分同一次写入；窗口对得上、固定开销可独立重算', (tester) async {
      _setupAgentRegistry(maxContextTokens: 100000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_conv(6, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _EchoSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      final ringBefore = tester.widget<ContextRing>(find.byType(ContextRing));
      await _send(tester, '你好');
      final ring = tester.widget<ContextRing>(find.byType(ContextRing));
      final b = ring.breakdown;
      // ignore: avoid_print
      print('  [OBS] 4.1 发送前 breakdown=${ringBefore.breakdown} '
          '发送后 level2=${b?.level2Tokens} level1=${b?.level1Tokens} '
          'raw=${b?.rawTokens} 固定=${b?.fixedOverheadTokens} '
          '窗口=${b?.windowTokens} 合计=${b?.usedTokens}');

      expect(ringBefore.breakdown, isNull,
          reason: '还没发过请求 ⇒ 没有拆分，环渲染成空盒子（D7）');
      expect(b, isNotNull, reason: '发送一次之后必须有拆分');

      final snapshot = await _switchAndReadSnapshot(tester);
      final rebuilt = ContextEstimator.estimateTokens(snapshot.systemPrompt) +
          ContextEstimator.estimateTokens(snapshot.toolsJson);
      // ignore: avoid_print
      print('  [OBS] 4.1 快照里的固定开销重算=$rebuilt（拆分里记的是=${b!.fixedOverheadTokens}）'
          ' 快照消息条数=${(snapshot.messages as List).length}');

      expect(b.windowTokens, 100000, reason: '窗口必须等于配置里的 max_context_tokens');
      expect(b.fixedOverheadTokens, rebuilt,
          reason: '固定开销必须等于拿这份快照自己的 systemPrompt 与 toolsJson 重算的结果'
              ' —— 这一条把拆分与同一份请求绑在一起');
      expect(b.conversationTokens, greaterThan(0),
          reason: '这一轮确实发了内容 ⇒ 环上三项之和不能是 0');
    });

    testWidgets('4.2 再发一条更长的消息 ⇒ 原文那一段严格变大（说明被替换了）', (tester) async {
      _setupAgentRegistry(maxContextTokens: 100000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_conv(4, 100));
      final sidecar = FakeSidecar()
        ..queueChunk('Reply')
        ..queueDone()
        ..queueChunk('Reply2')
        ..queueDone();
      final provider = _EchoSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, '短');
      final first =
          tester.widget<ContextRing>(find.byType(ContextRing)).breakdown!;
      await _send(tester, '这是一条长得多得多的消息，${'B' * 400}');
      final second =
          tester.widget<ContextRing>(find.byType(ContextRing)).breakdown!;
      // ignore: avoid_print
      print('  [OBS] 4.2 第一次 raw=${first.rawTokens} '
          '第二次 raw=${second.rawTokens} '
          '（第一次 固定=${first.fixedOverheadTokens} 第二次 固定=${second.fixedOverheadTokens}）');

      expect(second.rawTokens, greaterThan(first.rawTokens),
          reason: '历史变长了 ⇒ 原文那一段必须跟着变大，不许停在上一次的数上');
    });

    testWidgets('4.4 带图历史：图片按 1024/张计入原文段，分项之和等于合计', (tester) async {
      _setupAgentRegistry(maxContextTokens: 100000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionId = testSessions(1).first.id;
      // 故意只给很短的文字 + 一张图：如果图片没被计入，原文段会小到只有几十 token，
      // 那条 `>= 1024` 的断言就会红 —— 所以它是能判死的。
      final history = <Message>[
        Message(
          id: 'u1',
          seq: 1,
          sessionId: sessionId,
          role: 'user',
          content: '看图',
          createdAt: 1,
          attachments: const ['C:/tmp/one.png'],
        ),
        Message(
          id: 'a1',
          seq: 2,
          sessionId: sessionId,
          role: 'assistant',
          content: '好',
          createdAt: 2,
        ),
      ];

      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(history),
        sidecar: sidecar,
        summaryProvider: _EchoSummaryProvider(),
      ));
      await tester.pump();
      await tester.pump();
      await _send(tester, '继续');

      final b = tester.widget<ContextRing>(find.byType(ContextRing)).breakdown!;
      // ignore: avoid_print
      print('  [OBS] 4.4 raw=${b.rawTokens} 合计=${b.usedTokens} '
          '(L2=${b.level2Tokens} L1=${b.level1Tokens} '
          '固定=${b.fixedOverheadTokens})');

      expect(b.usedTokens,
          b.level2Tokens + b.level1Tokens + b.rawTokens + b.fixedOverheadTokens,
          reason: '分项之和必须等于合计（面板上那个数就是四项相加）');
      expect(b.rawTokens, greaterThanOrEqualTo(ContextEstimator.kImageTokens),
          reason: '这一段历史里只有一张图和几个字：图片没被计入的话原文段只有几十 token，'
              '这条就会红');
    });

    testWidgets('4.3 切到另一屏之后环还在同一个位置', (tester) async {
      _setupAgentRegistry(maxContextTokens: 100000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_conv(4, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _EchoSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();
      await _send(tester, '你好');

      final onConversation = tester.getTopLeft(find.byType(ContextRing));
      await tester.tap(find.text('真实上下文'));
      await tester.pump();
      final onContext = tester.getTopLeft(find.byType(ContextRing));
      // ignore: avoid_print
      print('  [OBS] 4.3 对话视图下环位置=$onConversation 真实上下文下=$onContext '
          '两屏都找得到=${find.byType(ContextRing).evaluate().isNotEmpty}');

      expect(find.byType(ContextRing), findsOneWidget,
          reason: '切到「真实上下文」之后环仍然要在');
      expect(onContext, onConversation,
          reason: '环在输入行里（2026-10-18 从工具栏搬到发送按钮左侧），两屏共用同一份输入行 '
            '⇒ 切换视图后位置必须一样');
    });
  });
}
