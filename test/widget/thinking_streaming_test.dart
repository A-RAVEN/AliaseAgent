import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';

import 'package:alias_agent/services/provider_resolver.dart';

import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';
import '../integration/helpers/fake_sidecar.dart';

void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
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
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

Map<String, dynamic> _delta(int index, String text) => {
      'type': 'thinking_delta',
      'index': index,
      'delta': text,
    };

Map<String, dynamic> _final(int index, String text, {String? sig}) => {
      'type': 'thinking',
      'index': index,
      'thinking': text,
      'signature': sig ?? 'sig_$index',
    };

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Thinking streaming (real-time delta rendering)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('5.1: delta events grow the card incrementally', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'Step one ')))
        ..queueThinking(jsonEncode(_delta(0, 'step two')))
        ..queueThinking(jsonEncode(_final(0, 'Step one step two', sig: 'sig_final')))
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'analyze this');
      await tester.pump();

      // Card appears on first delta; tap to expand and verify accumulated content
      final cardFinder = find.text('Thinking');
      expect(cardFinder, findsOneWidget);
      await tester.tap(cardFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // crossfade
      expect(find.text('Step one step two'), findsOneWidget);
      // Header shows char count after final block + turn completion
      await tester.pump();
      expect(find.textContaining('chars'), findsOneWidget);
    });

    testWidgets('5.2: final event replaces content and stores signature',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'partial')))
        ..queueThinking(jsonEncode(_final(0, 'COMPLETE THINKING', sig: 'sig_x')))
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'think');
      await tester.pump();

      await tester.tap(find.text('Thinking'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Final content replaces the partial delta text
      expect(find.text('COMPLETE THINKING'), findsOneWidget);
      expect(find.text('partial'), findsNothing);
    });

    testWidgets('5.3: multiple blocks with different indexes update independently',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'First block ')))
        ..queueThinking(jsonEncode(_delta(1, 'Second block ')))
        ..queueThinking(jsonEncode(_delta(0, 'grows')))
        ..queueThinking(jsonEncode(_delta(1, 'grows too')))
        ..queueThinking(jsonEncode(_final(0, 'First block grows', sig: 's0')))
        ..queueThinking(jsonEncode(_final(1, 'Second block grows too', sig: 's1')))
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'multi');
      await tester.pump();

      expect(find.text('Thinking'), findsNWidgets(2));

      // Expand both cards and verify independent content
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Thinking').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('First block grows'), findsOneWidget);
      expect(find.text('Second block grows too'), findsOneWidget);
    });

    testWidgets('5.5: thinking_delta events are NOT persisted', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'delta-a ')))
        ..queueThinking(jsonEncode(_delta(0, 'delta-b')))
        ..queueThinking(jsonEncode(_final(0, 'complete', sig: 's')))
        ..queueChunk('answer')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'persist?');
      await tester.pump();

      // Assistant message stored with thinkingJson containing ONLY the final block
      final inserted = msgRepo.messages
          .where((m) => m.role == 'assistant')
          .toList();
      expect(inserted, isNotEmpty);
      final thinkingJson = inserted.first.thinkingJson;
      expect(thinkingJson, isNotNull);
      final blocks = jsonDecode(thinkingJson!) as List<dynamic>;
      expect(blocks.length, 1);
      expect(blocks[0]['type'], 'thinking');
      expect(blocks[0]['thinking'], 'complete');
      expect(blocks[0]['signature'], 's');
      // No delta fragments leaked into persistence
      expect(jsonEncode(blocks), isNot(contains('thinking_delta')));
      expect(jsonEncode(blocks), isNot(contains('delta-a')));
    });

    testWidgets('5.6: new turn index 0 does not touch previous turn card',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        // Turn 1: thinking (index 0) + tool call
        ..queueThinking(jsonEncode(_delta(0, 'Turn1 thinking')))
        ..queueThinking(jsonEncode(_final(0, 'Turn1 thinking', sig: 't1')))
        ..queueToolCall(jsonEncode({
          'type': 'tool_use',
          'id': 'tool_1',
          'name': 'read_file',
          'input': {'path': 'a.txt'},
        }))
        ..queueDone(stopReason: 'tool_use')
        // Turn 2 (tool loop): fresh thinking with index 0 again
        ..queueThinking(jsonEncode(_delta(0, 'Turn2 thinking')))
        ..queueThinking(jsonEncode(_final(0, 'Turn2 thinking', sig: 't2')))
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'loop');
      await tester.pump();

      // Two separate cards — turn 2 delta created a NEW card, not mutated turn 1's
      expect(find.text('Thinking'), findsNWidgets(2));
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Turn1 thinking'), findsOneWidget);
      await tester.tap(find.text('Thinking').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Turn2 thinking'), findsOneWidget);
    });

    testWidgets('5.7: history rebuild derives indexes (legacy data without index)',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // Legacy thinking_json blocks WITHOUT index field (add-extended-thinking era)
      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final session = sessions.first;
      final msgRepo = FakeMessageRepository([
        Message(
          id: 'm1',
          sessionId: session.id,
          role: 'assistant',
          content: 'Answer',
          thinkingJson:
              '[{"type":"thinking","thinking":"legacy block one","signature":"s1"},'
              '{"type":"thinking","thinking":"legacy block two","signature":"s2"}]',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ]);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: FakeSidecar(),
      ));
      await tester.pump();
      await tester.pump();

      // Both legacy blocks render correctly after reload (derived indexes 0,1)
      expect(find.text('Thinking'), findsNWidgets(2));
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('legacy block one'), findsOneWidget);
      await tester.tap(find.text('Thinking').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('legacy block two'), findsOneWidget);
    });

    testWidgets('5.8: collapse state stays user-controlled during streaming',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        // Turn 1: streaming thinking, then a tool call
        ..queueThinking(jsonEncode(_delta(0, 'first delta')))
        ..queueThinking(jsonEncode(_delta(0, ' second delta')))
        ..queueThinking(jsonEncode(_final(0, 'first delta second delta')))
        ..queueToolCall(jsonEncode({
          'type': 'tool_use',
          'id': 'tool_1',
          'name': 'read_file',
          'input': {'path': 'a.txt'},
        }))
        ..queueDone(stopReason: 'tool_use')
        // Turn 2 (tool loop): new thinking stream with its own card
        ..queueThinking(jsonEncode(_delta(0, 'third delta')))
        ..queueThinking(jsonEncode(_final(0, 'third delta')))
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'stream');
      await tester.pump();

      // Card 1 is collapsed by default: body is NOT visible while collapsed
      // (AnimatedCrossFade keeps it in the tree at height 0 — use hitTestable)
      expect(find.text('first delta second delta').hitTestable(), findsNothing);

      // User expands card 1
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('first delta second delta').hitTestable(), findsOneWidget);

      // Turn 2's new card arrives — card 1 STAYS expanded (turn completion and
      // new-turn activity never change the user's collapse choice)
      await tester.pump();
      await tester.pump();
      expect(find.text('first delta second delta').hitTestable(), findsOneWidget);
      // New card is collapsed by default
      expect(find.text('third delta').hitTestable(), findsNothing);

      // User expands the new card too
      await tester.tap(find.text('Thinking').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('third delta').hitTestable(), findsOneWidget);

      // User collapses card 1 again — stays collapsed
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('first delta second delta').hitTestable(), findsNothing);
      // Card 2 unaffected by card 1's toggle
      expect(find.text('third delta').hitTestable(), findsOneWidget);
    });

// ============================================================================
// Round 2 regression tests (9.10)
// ============================================================================

    testWidgets('9.10a: error path transitions thinking card to done',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'partial thinking')))
        ..queueDone(code: -1, error: 'API error');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'trigger error');
      await tester.pump();

      // Card exists and is NOT stuck in streaming: char count shown (done)
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.textContaining('chars'), findsOneWidget);
      // Content preserved
      await tester.tap(find.text('Thinking'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('partial thinking').hitTestable(), findsOneWidget);
    });

    testWidgets('9.10b: after error, next turn index 0 does not touch old card',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        // Turn 1: thinking then error
        ..queueThinking(jsonEncode(_delta(0, 'errored turn')))
        ..queueThinking(jsonEncode(_final(0, 'errored turn')))
        ..queueDone(code: -1, error: 'API error')
        // Turn 2 (user retries): fresh thinking with index 0
        ..queueThinking(jsonEncode(_delta(0, 'new turn')))
        ..queueThinking(jsonEncode(_final(0, 'new turn')))
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'first');
      await tester.pump();

      // Turn 1 errored — its card is done (no longer streaming)
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.textContaining('chars'), findsOneWidget);

      // Turn 2: new message in the SAME session — new card must be created
      // (the old card is no longer streaming, so index 0 can't match it)
      await _send(tester, 'retry');
      await tester.pump();

      expect(find.text('Thinking'), findsNWidgets(2));
      await tester.tap(find.text('Thinking').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('new turn').hitTestable(), findsOneWidget);
      // Old card untouched by turn 2's index 0 delta
      await tester.tap(find.text('Thinking').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('errored turn').hitTestable(), findsOneWidget);
      expect(find.text('errored turnnew turn'), findsNothing);
    });

    testWidgets('10.4: cancelled error is not persisted into history',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode(_delta(0, 'thinking...')))
        ..queueDone(code: -1, error: 'cancelled');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'cancel me');
      await tester.pump();

      // No 'Error: cancelled' card in the DB (9.5/10.2)
      final stored = msgRepo.messages
          .where((m) => m.content.startsWith('Error'))
          .toList();
      expect(stored, isEmpty);
      // No error bubble rendered either
      expect(find.textContaining('Error'), findsNothing);
    });

    testWidgets('11.4: mid-stream session switch does not persist error card',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sessions = testSessions(2); // s1, s2
      final sidecar = FakeSidecar()
        ..gateNextSend() // suspend event delivery mid-stream
        ..queueThinking(jsonEncode(_delta(0, 'thinking...')))
        ..queueDone(code: -1, error: 'cancelled');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(sessions),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Send in session 1 — sendMessage suspends on the gate
      await tester.enterText(find.byType(TextField), 'streaming');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // Switch to session 2 mid-stream (cancelRequest + cancel-context capture)
      await tester.tap(find.text('Session 2'));
      await tester.pump();

      // Release the gate — the cancelled done now arrives
      sidecar.releaseGate();
      await tester.pump();
      await tester.pump();

      // Cancel was issued, and no error card was persisted anywhere
      expect(sidecar.cancelCount, greaterThan(0));
      expect(
          msgRepo.messages.where((m) => m.content.startsWith('Error')),
          isEmpty);
    });

    testWidgets('12.4a: switch-cancelled request completing successfully '
        'does not persist an error card',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sessions = testSessions(2);
      final sidecar = FakeSidecar()
        ..gateNextSend()
        ..queueThinking(jsonEncode(_delta(0, 'stale thinking')))
        ..queueDone(); // doneCode 0 (lost-cancel window: cancel was swallowed)

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(sessions),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'stream');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // Switch mid-stream, then release — the stale request completes OK
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      sidecar.releaseGate();
      await tester.pump();
      await tester.pump();

      // No error card persisted (the stale completion must not be treated
      // as an error), and cancel was issued
      expect(sidecar.cancelCount, greaterThan(0));
      expect(
          msgRepo.messages.where((m) => m.content.startsWith('Error')),
          isEmpty);
    });

    testWidgets('12.4b: session switch aborts the remaining tool loop',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()
        ..gateNextSend()
        // Turn 1: thinking + tool call
        ..queueThinking(jsonEncode(_delta(0, 'turn1')))
        ..queueThinking(jsonEncode(_final(0, 'turn1')))
        ..queueToolCall(jsonEncode({
          'type': 'tool_use',
          'id': 'tool_1',
          'name': 'read_file',
          'input': {'path': 'a.txt'},
        }))
        ..queueDone(stopReason: 'tool_use')
        // Turn 2 events — must NEVER be consumed (loop aborted on switch)
        ..queueThinking(jsonEncode(_delta(0, 'TURN2')))
        ..queueThinking(jsonEncode(_final(0, 'TURN2')))
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(2)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'loop');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // Switch session while turn 1 is in flight
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      sidecar.releaseGate();
      await tester.pump();
      await tester.pump();

      // Turn 2 events remain queued — the tool loop was aborted (12.1)
      expect(sidecar.hasQueuedEvents, isTrue);
    });

    testWidgets('16.6: A->B->A switch-back — stale call reply is not persisted '
        'and does not disturb the new request (epoch semantics)', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sessions = testSessions(2); // s1 = A, s2 = B
      final sidecar = FakeSidecar()
        ..gateNextSend()
        // Turn 1 (stale call, epoch 1): thinking + tool call
        ..queueThinking(jsonEncode(_delta(0, 't1')))
        ..queueThinking(jsonEncode(_final(0, 't1')))
        ..queueToolCall(jsonEncode({
          'type': 'tool_use',
          'id': 'tool_1',
          'name': 'read_file',
          'input': {'path': 'a.txt'},
        }))
        ..queueDone(stopReason: 'tool_use')
        // Turn 2 events: consumed by the NEW request (epoch 2) after the
        // stale call is aborted
        ..queueChunk('NEW REPLY')
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(sessions),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Request 1 in A — suspended on the gate
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // A -> B (invalidates epoch 1), then B -> A
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      await tester.tap(find.text('Session 1'));
      await tester.pump();

      // New request in A (epoch 2)
      sidecar.gateNextSend();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      sidecar.releaseGate();
      await tester.pump();
      await tester.pump();
      sidecar.releaseGate();
      await tester.pump();
      await tester.pump();

      // No error card; no tool-use intermediate message from the stale call
      expect(
          msgRepo.messages.where((m) => m.content.startsWith('Error')),
          isEmpty);
      expect(msgRepo.messages.where((m) => m.toolCallsJson != null), isEmpty);
      // The NEW request completed normally with its reply persisted
      expect(
          msgRepo.messages.any((m) =>
              m.role == 'assistant' && m.content == 'NEW REPLY'),
          isTrue);
    });

    testWidgets('17.2: stale no-tool round — late reply not persisted, '
        'new request streaming cards survive (16.1/16.2 surface)', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgRepo = FakeMessageRepository();
      final sessions = testSessions(2); // s1 = A, s2 = B
      final sidecar = FakeSidecar()
        ..gateNextSend()
        // Stale call (epoch 1): NO tool call — plain text reply
        ..queueChunk('STALE REPLY')
        ..queueDone(stopReason: 'end_turn')
        // New request (epoch 2): fresh reply
        ..queueChunk('NEW REPLY')
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(sessions),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Request 1 in A — suspended
      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      // A -> B -> A (invalidates epoch 1), then new request in A
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      await tester.tap(find.text('Session 1'));
      await tester.pump();
      sidecar.gateNextSend();
      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      sidecar.releaseGate(); // stale call proceeds
      await tester.pump();
      await tester.pump();
      sidecar.releaseGate(); // new request proceeds
      await tester.pump();
      await tester.pump();

      // Stale reply NOT persisted (16.1); new reply persisted
      expect(
          msgRepo.messages.any(
              (m) => m.role == 'assistant' && m.content == 'STALE REPLY'),
          isFalse);
      expect(
          msgRepo.messages.any(
              (m) => m.role == 'assistant' && m.content == 'NEW REPLY'),
          isTrue);
      // New request's streaming card still present (16.2: stale done did not
      // tear it down) — NEW REPLY rendered in the UI
      expect(find.text('NEW REPLY'), findsOneWidget);
      expect(find.text('STALE REPLY'), findsNothing);
    });


  });
}