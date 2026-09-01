import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

void _setupAgentRegistry(int maxContextTokens) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

List<Message> _longConversation(int n) => [
      for (var i = 0; i < n; i++)
        Message(
          id: 'pre$i',
          sessionId: 's1',
          role: i.isEven ? 'user' : 'assistant',
          content: 'A' * 100,
          createdAt: i,
        ),
    ];

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

/// Phase 4 cost discipline (D10): 5.1 per-session fold budget cap + 5.2
/// break-even regression.
void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  // 5.1 — per-session fold budget cap (D10 cost discipline): a session whose
  // accumulated fold accounting exceeds the cap stops auto-folding, so it cannot
  // pay unbounded summarization cost. Tested as the pure cap check
  // (deterministic; no DB/FakeAsync). The widget GATE wiring — the on-demand fold
  // path (main.dart _callModel) + the idle background fold both call
  // `_foldBudgetExceeded`, which queries the persisted nodes then invokes
  // [ChatScreenState.isFoldBudgetExceeded] — uses the public static pinned here.
  // (The full widget+real-DB path is a known FakeAsync black-hole harness
  // limitation; the accounting LOGIC is thus tested directly.)
  test('5.1 fold budget cap: count cap, token cap, at-cap-not-exceeded', () {
    // ignore: avoid_print
    print('  [OBS] 5.1 fold caps: count=${ChatScreenState.maxFoldsPerSession} '
        'tokens=${ChatScreenState.maxFoldTokensPerSession}');
    expect(ChatScreenState.maxFoldsPerSession, greaterThan(0),
        reason: '5.1 a fold-count cap is defined');
    expect(ChatScreenState.maxFoldTokensPerSession, greaterThan(0),
        reason: '5.1 a fold-token cap is defined');

    // Count cap: 1 fold over the limit trips.
    expect(
        ChatScreenState.isFoldBudgetExceeded(
            foldCount: ChatScreenState.maxFoldsPerSession + 1, foldTokens: 0),
        isTrue,
        reason: '5.1 fold COUNT over the cap must trip the budget');
    // Token cap: 1 token over the limit trips.
    expect(
        ChatScreenState.isFoldBudgetExceeded(
            foldCount: 0, foldTokens: ChatScreenState.maxFoldTokensPerSession + 1),
        isTrue,
        reason: '5.1 fold TOKENS over the cap must trip the budget');
    // Exactly at the cap is NOT exceeded.
    expect(
        ChatScreenState.isFoldBudgetExceeded(
            foldCount: ChatScreenState.maxFoldsPerSession,
            foldTokens: ChatScreenState.maxFoldTokensPerSession),
        isFalse,
        reason: '5.1 at the cap is within budget (not exceeded)');
  });

  // 5.2 — break-even regression: a valid fold must be repaid by the per-request
  // savings within a bounded number of requests. Guards against a regression that
  // makes the fold bloated (summary >= raw → no per-request saving) or so
  // expensive it is never repaid. Measures the WHOLE fold (all L1 batches), not a
  // single batch.
  testWidgets('5.2 break-even: fold input repaid by per-request savings within bound',
      (tester) async {
    _setupAgentRegistry(200);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sessions = testSessions(1);
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository(_longConversation(24));
    final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
    // A genuinely compressing summary provider that accumulates the WHOLE fold's
    // raw input + summary output across every L1 batch.
    final summaryProvider = _AccumulatingSummaryProvider(text: 'k' * 90);

    await tester.pumpWidget(_buildApp(
      sessionRepo: sessionRepo,
      msgRepo: msgRepo,
      sidecar: sidecar,
      summaryProvider: summaryProvider,
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'continue');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    expect(summaryProvider.totalFoldedRaw, greaterThan(0),
        reason: 'an over-budget conversation must fold a non-empty span');
    final savingsPerRequest =
        summaryProvider.totalFoldedRaw - summaryProvider.totalSummaryTokens;
    const kBreakEvenRequests = 8; // amortized: fold repaid within 8 requests
    final repaid = summaryProvider.totalFoldedRaw <
        kBreakEvenRequests * savingsPerRequest;
    // ignore: avoid_print
    print('  [OBS] 5.2 break-even: totalFoldedRaw=${summaryProvider.totalFoldedRaw} '
        'totalSummaryTokens=${summaryProvider.totalSummaryTokens} '
        'savingsPerRequest=$savingsPerRequest foldInput(${summaryProvider.totalFoldedRaw}) '
        '< $kBreakEvenRequests*$savingsPerRequest='
        '${kBreakEvenRequests * savingsPerRequest} repaid=$repaid');
    expect(savingsPerRequest, greaterThan(0),
        reason: '5.2 a valid fold must shrink the per-request payload (summary < raw)');
    expect(repaid, isTrue,
        reason: '5.2 the fold input cost must be repaid by per-request savings within '
            '$kBreakEvenRequests requests (else the fold is a net cost, not a saving)');
  });
}

/// Summary provider that accumulates the whole fold's RAW input tokens and the
/// total summary output tokens across every L1 batch, so a break-even regression
/// measures the entire fold (not just the last batch). Returns a genuinely
/// compressing summary.
class _AccumulatingSummaryProvider implements SummaryProvider {
  final String text;
  int totalFoldedRaw = 0;
  int totalSummaryTokens = 0;
  _AccumulatingSummaryProvider({required this.text});

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    totalFoldedRaw += ContextEstimator.estimateConversation(folded);
    final tokens = ContextEstimator.estimateTokens(text);
    totalSummaryTokens += tokens;
    return SummaryResult(text: text, tokens: tokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    final tokens = ContextEstimator.estimateTokens(text);
    totalSummaryTokens += tokens;
    return SummaryResult(text: text, tokens: tokens);
  }
}
