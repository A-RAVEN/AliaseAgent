import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
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

/// Summary provider whose summarize can be made to hang on a Completer, so a test
/// can hold a background fold "in flight" and then release it (simulating a cancel
/// via completeError). When [gate] is null the call completes immediately — used
/// for inline folds that must not hang.
class _GatedSummaryProvider implements SummaryProvider {
  int summarizeCalls = 0;
  Completer<SummaryResult>? gate;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    summarizeCalls++;
    final g = gate;
    if (g == null) {
      return SummaryResult(
          text: 'GATED summary (${folded.length} msgs)', tokens: folded.length);
    }
    return g.future; // hang until the test releases it
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    final g = gate;
    if (g == null) {
      return SummaryResult(text: 'GATED L2', tokens: text.length);
    }
    return g.future;
  }
}

void main() {
  group('Background folding (2.6, idle-gated + preemptible)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    Future<void> growConversation(FakeMessageRepository repo, int n) async {
      final len = repo.messages.length;
      for (var i = 0; i < n; i++) {
        await repo.insert(
          sessionId: 's1',
          role: (len + i).isEven ? 'user' : 'assistant',
          content: 'A' * 100,
        );
      }
    }

    Widget buildApp({
      required FakeSidecar sidecar,
      required SummaryProvider summaryProvider,
      required FakeMessageRepository msgRepo,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            config: const AppConfig(version: 1),
            sessionRepo: FakeSessionRepository(testSessions(1)),
            msgRepo: msgRepo,
            sidecar: sidecar,
            summaryProvider: summaryProvider,
            backgroundFoldEnabled: true,
          ),
        ),
      );
    }

    testWidgets('background fold runs when idle and folds the far span',
        (tester) async {
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = FakeSummaryProvider();
      // Seed a couple of messages so turn 1 is UNDER the fold budget (no inline
      // fold), then grow the conversation out-of-band so the IDLE fold sees an
      // over-budget history.
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // Turn 1: under budget -> NO inline fold, so the provider is never called.
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] after turn-1 (under-budget) inline send: '
          'lastFolded=${summaryProvider.lastFolded} '
          '[expect null — no inline fold]');
      expect(summaryProvider.lastFolded, isNull,
          reason: 'an under-budget turn must NOT fold inline, so any provider '
              'call below is evidence of the BACKGROUND fold');

      // Grow the history out-of-band (no user turn) so the idle fold over-budgets.
      await growConversation(mgr, 80);

      // Idle: fire the 2s debounce timer; the background fold runs and folds.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] after idle background fold: lastFolded='
          '${summaryProvider.lastFolded != null} '
          'foldedMsgs=${summaryProvider.lastFolded?.length}');
      expect(summaryProvider.lastFolded, isNotNull,
          reason: 'the idle background fold must drive the summary provider '
              '(reuse the same fold path as the inline send)');
    });

    testWidgets('a user send during a background fold fires the preempt path and the user turn completes',
        (tester) async {
      // HONEST SCOPING: this hermetic test uses a FakeSidecar that is SYNCHRONOUS
      // and does NOT serialize requests (unlike the real SidecarBridge._chain gate),
      // so it CANNOT assert the real "the fold's in-flight request delayed/serialized
      // behind the user" effect, nor directly observe the fold object aborting. What
      // it DOES genuinely verify is narrower: (a) the background fold was IN FLIGHT
      // (it reached a summarize call) when the user sent, (b) `_sendMessage` invoked
      // the preempt path (the ONLY place that bumps cancelCount while a fold is in
      // flight — asserted with a reset so it FAILS if the preempt block were removed),
      // and (c) the user's turn still completed. This is an honest subset, not a claim
      // of "not delayed" (which a serializing sidecar would be needed to prove).
      _setupAgentRegistry(2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final mgr = FakeMessageRepository();
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _GatedSummaryProvider();
      await growConversation(mgr, 2);

      await tester.pumpWidget(buildApp(
          sidecar: sidecar, summaryProvider: summaryProvider, msgRepo: mgr));
      await tester.pump();
      await tester.pump();

      // Turn 1 (under budget -> no inline fold, no provider call).
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Grow the history out-of-band, gate the provider, then fire the idle
      // debounce so the BACKGROUND fold starts and hangs on the gate (in flight).
      await growConversation(mgr, 80);
      summaryProvider.gate = Completer<SummaryResult>();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      // The background fold must have genuinely started: it reached a summarize
      // call BEFORE the user sends. At this point turn 1 (under budget) and turn 2
      // (not sent yet) have both called summarize zero times, so a count >= 1 can
      // only be the BACKGROUND fold's summary call — proving it is really in flight.
      // (The full-history fold reads _msgRepo.queryBySession, which includes the 80
      // grown messages -> over budget; the widget's _chatItems is unaffected.)
      // ignore: avoid_print
      print('  [OBS] before user send: summarizeCalls=${summaryProvider.summarizeCalls} '
          '[expect >=1 — background fold reached its summary call]');
      expect(summaryProvider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: 'the background fold must have reached a summarize call before the '
              'user sends (only the fold could have bumped the count so far)');

      // Reset the cancel counter so the ONLY cancelRequest that can occur between
      // here and the assertion is (preempt path) + (turn-2 _endStreaming). Asserting
      // >= 2 therefore FAILS if _sendMessage's preempt block were removed (then only
      // _endStreaming would fire once). This makes the preempt guard non-vacuous.
      // The fold is in flight; user sends -> the preempt path bumps _foldGen +
      // calls cancelRequest (modelling production: cancelRequest makes the fold's
      // ModelSummaryProvider.summarize throw). Release the gate with an error to let
      // the preempted fold unwind cleanly.
      // NOTE: FakeSidecar consumes its event queue up to the FIRST done on each
      // sendMessage; turn 1 already consumed the single queued 'Reply'+done, so the
      // queue is EMPTY. We re-queue a DISTINCT chunk for turn 2 so that a rendered
      // 'Turn2 done' text is unambiguous proof turn-2 actually replied+completed
      // (find.text('Reply') would wrongly match turn-1's already-rendered reply).
      sidecar.cancelCount = 0;
      sidecar..queueChunk('Turn2 done')..queueDone();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      summaryProvider.gate!.completeError(StateError('preempted/fold cancelled'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] preempt: cancelCount=${sidecar.cancelCount} '
          'turn2ReplyPresent=${find.text('Turn2 done').evaluate().isNotEmpty} '
          '[expect cancelCount>=2 (preempt + turn-endStreaming); turn2 reply present]');
      // The background fold was genuinely in-flight at send-time (proven by the >=1
      // summarizeCalls assertion right before the send). The preempt path fired: its
      // cancelRequest (1) + the turn-completion _endStreaming cancel (2). _endStreaming
      // is only reached on a NORMALLY-completed turn, so >=2 also evidences turn 2
      // reached completion. Removing the preempt block drops this below 2 -> non-vacuous.
      expect(sidecar.cancelCount, greaterThanOrEqualTo(2),
          reason: 'a send while a fold is in flight must fire _sendMessage preempt '
              '(cancel) AND the turn-completion _endStreaming cancel; removing the '
              'preempt block would drop this below 2 -> the assertion is non-vacuous');
      // turn 2 rendered its OWN reply -> it completed (not stuck behind the fold).
      expect(find.text('Turn2 done'), findsOneWidget,
          reason: 'a user message sent during a background fold must still complete '
              '(turn 2 renders a distinct reply)');
    });
  });
}
