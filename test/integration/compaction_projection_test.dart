import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

void _setupAgentRegistry({
  int maxContextTokens = 200,
  List<String> standingRequirements = const [],
}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
    standingRequirements: standingRequirements,
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
  required FakeSummaryProvider summaryProvider,
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

List<Message> _longConversation(int n) {
  return [
    for (var i = 0; i < n; i++)
      Message(
        id: 'pre$i',
        sessionId: 's1',
        role: i.isEven ? 'user' : 'assistant',
        content: 'A' * 100,
        createdAt: i,
      ),
  ];
}

void main() {
  group('Compaction projection (Phase 1 MVP)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('over-budget conversation is compacted into summary + near verbatim',
        (tester) async {
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1); // 's1'
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(10));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = FakeSummaryProvider(text: 'FOLDED SUMMARY');

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

      // [OBS] front/back conversation token comparison (R3-3): show the original
      // conversation proxy tokens vs the compacted projection size, so a reader
      // sees compaction actually shrank the context (task 2.8 claims "前后 token").
      final beforeTokens = ContextEstimator.estimateConversation(msgRepo.messages);
      final projectedJson = sidecar.lastMessagesJson!;
      final projectedMsgs = (jsonDecode(projectedJson) as List).length;
      // ignore: avoid_print
      print('  [OBS] before/after compaction: originalProxyTokens=$beforeTokens '
          '-> projectedMsgs=$projectedMsgs projectedChars=${projectedJson.length}');

      // The summary provider must have received a folded (non-empty) span.
      expect(summaryProvider.lastFolded, isNotNull);
      expect(summaryProvider.lastFolded!, isNotEmpty,
          reason: 'an over-budget conversation must fold an older span');

      // The actual projection sent to the sidecar must lead with the summary
      // marker (role:user prefix) and still carry the current user message.
      final projected = sidecar.lastMessagesJson!;
      // ignore: avoid_print
      print('  [OBS] projected messagesJson: ${projected.length} chars');
      expect(projected, contains('## 更早上下文'),
          reason: 'the compacted projection must be prefixed with the summary marker');
      expect(projected, contains('continue'),
          reason: 'the current user message must survive compaction');
      // ignore: avoid_print
      print('  [OBS] summary marker present + current user message preserved');
    });

    testWidgets('guard anchors are seeded from agent standing requirements and injected into systemPrompt',
        (tester) async {
      // R2-3: _guard was created empty and never seeded in production, so
      // inject() returned '' on every turn — the non-compressible anchor never
      // fired. This verifies initState now seeds the guard from the active agent
      // type's explicit standingRequirements.
      _setupAgentRegistry(
        maxContextTokens: 100000, // under budget -> no folding, focus on guard
        standingRequirements: ['keep the workspace root', 'never fold the config'],
      );
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(2));
      final sidecar = FakeSidecar()..queueChunk('Hi')..queueDone();
      final summaryProvider = FakeSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final sp = sidecar.lastSystemPrompt ?? '';
      // [OBS] dump the actual system prompt guard slice before asserting.
      // ignore: avoid_print
      print('  [OBS] systemPrompt has guard marker=${sp.contains('## 不可压缩约束')} '
          'has req1=${sp.contains('keep the workspace root')} has req2=${sp.contains('never fold the config')}');
      expect(sp, contains('## 不可压缩约束'),
          reason: 'standing requirements must seed the guard and be injected');
      expect(sp, contains('keep the workspace root'));
      expect(sp, contains('never fold the config'));
    });

    testWidgets('multi-segment projection has no consecutive role:user messages', (tester) async {
      _setupAgentRegistry(maxContextTokens: 400);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      // Large far span -> multiple level-1 summary segments (>=2).
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = FakeSummaryProvider(text: 'FOLDED SUMMARY');

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

      final parsed = jsonDecode(sidecar.lastMessagesJson!) as List<dynamic>;
      var consecutiveUser = 0;
      for (var i = 1; i < parsed.length; i++) {
        final cur = (parsed[i] as Map<String, dynamic>)['role'];
        final prev = (parsed[i - 1] as Map<String, dynamic>)['role'];
        if (cur == 'user' && prev == 'user') consecutiveUser++;
      }
      // ignore: avoid_print
      print('  [OBS] consecutive role:user pairs in projection: $consecutiveUser (roles=${parsed.map((m) => (m as Map)['role']).join(",")})');
      expect(consecutiveUser, 0,
          reason: 'the compacted projection must keep valid role alternation (no consecutive user messages)');
    });

    testWidgets('under-budget conversation is sent verbatim (no summary)', (tester) async {
      _setupAgentRegistry(maxContextTokens: 100000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(2));
      final sidecar = FakeSidecar()..queueChunk('Hi')..queueDone();
      final summaryProvider = FakeSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // [OBS] dump the actual projection before asserting (test observability).
      // ignore: avoid_print
      print('  [OBS] under-budget projection: summaryMarkerPresent='
          '${sidecar.lastMessagesJson?.contains('## 更早上下文')} '
          'projectedChars=${sidecar.lastMessagesJson?.length} lastFolded=${summaryProvider.lastFolded}');
      expect(summaryProvider.lastFolded, isNull,
          reason: 'no folding should happen under budget');
      expect(sidecar.lastMessagesJson, isNot(contains('## 更早上下文')),
          reason: 'under budget the conversation must be sent verbatim');
    });
  });
}
