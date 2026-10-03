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

/// Break-even regression: a valid fold must pay for itself.
///
/// REMOVED 2026-09-20, with the user's explicit authorisation (2026-09-13:
/// 「对于这种狗屎设计，没有任何留着的理由」 / "there is no reason to keep a design
/// this bad"): the `5.1 fold budget cap` case used to pin a per-session cap of 30
/// summaries and 500000 summary tokens. That cap was deleted from the product
/// (see the NOTE above `ChatScreenState._summaryStoreOpen` in lib/main.dart for
/// why it was a defect, not a guard). Deleting the case is a change to the
/// acceptance criteria and is authorised — it is NOT a quietly loosened
/// assertion: the behaviour it pinned no longer exists on purpose.
///
/// The break-even case below is a DIFFERENT property ("does compaction actually
/// save anything") and is kept.
void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
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
    List<SummaryReference> reference = const [],
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
