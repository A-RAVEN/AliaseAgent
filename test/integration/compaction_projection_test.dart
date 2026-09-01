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
import 'helpers/real_context_fixture.dart';

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

/// Fake with controllable summary sizes so the measure→adjust loop (⑪.3) can be
/// forced off the "fits-budget" path: `l1Tokens` is what every level-1 summary
/// reports, `l2Tokens` what the level-2 "summary of summaries" reports.
class _SizedFakeSummaryProvider implements SummaryProvider {
  final int l1Tokens;
  final int l2Tokens;
  int summarizeCalls = 0;
  int summarizeTextCalls = 0;
  _SizedFakeSummaryProvider({required this.l1Tokens, required this.l2Tokens});

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    summarizeCalls++;
    return SummaryResult(
        text: 'L1 summary (${folded.length} msgs)', tokens: l1Tokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    summarizeTextCalls++;
    // l2Tokens lets the test simulate a compressing (small) or non-compressing
    // (large) level-2 roll-up.
    return SummaryResult(text: 'L2 rolled up', tokens: l2Tokens);
  }
}

/// Records EVERY folded span handed to the summarizer, so a test can assert that
/// a given message (e.g. a content-empty tool-call assistant) reached the fold
/// input regardless of how many L1 batches the measure→adjust loop produces.
class _RecordingSummaryProvider implements SummaryProvider {
  final List<List<Message>> foldedCalls = [];

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    foldedCalls.add(List.of(folded));
    return SummaryResult(
        text: 'FOLDED (${folded.length} msgs)', tokens: ContextEstimator.estimateTokens('FOLDED'));
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    return SummaryResult(text: text, tokens: ContextEstimator.estimateTokens(text));
  }
}

void main() {
  group('Compaction projection (Phase 1 MVP)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('R-A2-5d FIX: a content-empty tool-call assistant reaches the fold input',
        (tester) async {
      // A content-empty tool-call assistant (carrying tool_use input.path = a
      // re-execution key) must survive `_buildChatItems`/`_chatItemsToMessages` so
      // buildTree's `folded` includes it and the summarizer sees the tool round.
      // Before the fix `_buildChatItems` dropped it (old `continue`), so `folded`
      // never contained it and the summarizer never saw the tool input. Pumps a
      // real ChatScreen with the message repo so the message goes through
      // `_loadMessages` -> `_buildChatItems`, then triggers an over-budget fold.
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final toolAssistant = Message(
        id: 'm_tool',
        seq: 2,
        sessionId: 's1',
        role: 'assistant',
        content: '', // content-empty (D7): the ToolCallCard represents the response
        toolCallsJson: jsonEncode([
          {
            'id': 'call_read_config',
            'toolName': 'read_file',
            'name': 'read_file',
            'input': {'path': kConfigPath},
            'result': '// connection timeout\nconst timeout = 120;',
          }
        ]),
        createdAt: 2,
      );
      final msgs = [
        Message(id: 'm_u1', seq: 1, sessionId: 's1', role: 'user',
            content: '请读取 $kConfigPath。', createdAt: 1),
        toolAssistant,
        for (var i = 0; i < 12; i++)
          Message(id: 'm_f$i', seq: 3 + i, sessionId: 's1',
              role: i.isEven ? 'user' : 'assistant', content: 'A' * 100, createdAt: 3 + i),
      ];
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(msgs);
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _RecordingSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), '继续');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final foldedAll = summaryProvider.foldedCalls;
      final hasToolRound = foldedAll.any((folded) => folded.any((m) =>
          m.role == 'assistant' && (m.toolCallsJson ?? '').isNotEmpty));
      final hasPathKey = foldedAll.any((folded) => folded.any((m) =>
          (m.toolCallsJson ?? '').contains(kConfigPath)));
      // ignore: avoid_print
      print('  [OBS] R-A2-5d foldedCalls=${foldedAll.length} '
          'hasToolRound=$hasToolRound hasPathKey=$hasPathKey');
      expect(foldedAll, isNotEmpty,
          reason: 'an over-budget conversation must fold a span into the summarizer');
      expect(hasToolRound, isTrue,
          reason: 'R-A2-5d: the content-empty tool-call assistant must reach the fold '
              'input (folded), so the summarizer sees the tool round — it was dropped '
              'before (_buildChatItems old `continue`)');
      expect(hasPathKey, isTrue,
          reason: 'R-A2-5d: the tool_use input absolute path (re-execution key) must '
              'reach the summarizer in the folded span');
    });

    testWidgets(
        'R-A2-5d-1 DEDUP: an intermediate tool round + the final allTurnToolCalls superset emit exactly one tool_use/tool_result',
        (tester) async {
      // R-A2-5d-1 regression: the round-1 HIGH finding. Production persists a tool
      // round BOTH as the intermediate tool-call assistant (its own turnToolCalls,
      // main.dart:1179-1187) AND as the FINAL assistant which redundantly re-carries
      // the accumulated superset (allTurnToolCalls, main.dart:1143-1144). If
      // _buildApiMessages re-emitted the round from BOTH (no dedup), the request
      // would carry the same tool_use_id/tool_result TWICE. This drives the REAL
      // send path (under budget -> _buildApiMessages) and asserts exactly one
      // tool_use + one tool_result for the id. Reverting the dedup makes it fail.
      _setupAgentRegistry(maxContextTokens: 100000); // under budget -> verbatim send
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final toolCall = {
        'id': 'call_read',
        'toolName': 'read_file',
        'name': 'read_file',
        'input': {'path': kConfigPath},
        'result': '// connection timeout\nconst timeout = 120;',
      };
      final msgs = [
        Message(id: 'm_u0', seq: 1, sessionId: 's1', role: 'user',
            content: '请读取 $kConfigPath。', createdAt: 1),
        // Intermediate: the tool-call assistant that actually made the call.
        Message(id: 'm_int', seq: 2, sessionId: 's1', role: 'assistant',
            content: '', toolCallsJson: jsonEncode([toolCall]), createdAt: 2),
        // Final: the turn-ending assistant that redundantly re-carries the superset.
        Message(id: 'm_fin', seq: 3, sessionId: 's1', role: 'assistant',
            content: '已读取 $kConfigPath。', toolCallsJson: jsonEncode([toolCall]),
            createdAt: 3),
      ];
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(msgs);
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

      await tester.enterText(find.byType(TextField), '继续');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson!;
      final msgsDecoded = (jsonDecode(projected) as List);
      var toolUseCount = 0;
      var toolResultCount = 0;
      for (final m in msgsDecoded) {
        final content = (m as Map<String, dynamic>)['content'];
        if (content is! List) continue;
        for (final block in content) {
          if (block is Map<String, dynamic>) {
            if (block['type'] == 'tool_use' && block['id'] == 'call_read') toolUseCount++;
            if (block['type'] == 'tool_result' && block['tool_use_id'] == 'call_read') {
              toolResultCount++;
            }
          }
        }
      }
      // ignore: avoid_print
      print('  [OBS] R-A2-5d-1 dedup toolUseCount=$toolUseCount toolResultCount=$toolResultCount');
      expect(toolUseCount, 1,
          reason: 'R-A2-5d-1: the intermediate + final double-carry must yield '
              'exactly ONE tool_use for the id (the first owner emits it); the '
              'redundant final allTurnToolCalls must NOT re-emit it (duplicate)');
      expect(toolResultCount, 1,
          reason: 'R-A2-5d-1: exactly ONE tool_result for the id (paired with the '
              'single tool_use), not a duplicate');
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

    testWidgets('⑪.3 coarsen: over-budget L1 summaries are rolled into a level-2', (tester) async {
      // l1Tokens=75×6 L1 batches (+verbatim) exceed budget 200 → the measure-adjust
      // loop coarsens the OLDEST L1s into a level-2; l2Tokens=20 (compressing)
      // makes the roll-up smaller so it eventually fits. This exercises ⑪.3.
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 75, l2Tokens: 20);

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

      // [OBS] show the coarsen actually ran and the projection the model received.
      final projected = sidecar.lastMessagesJson ?? '';
      // ignore: avoid_print
      print('  [OBS] coarsen: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'projectedChars=${projected.length} '
          'hasL2=${projected.contains('L2 rolled up')}');
      expect(summaryProvider.summarizeTextCalls, greaterThanOrEqualTo(1),
          reason: 'over-budget L1 summaries must be coarsened into a level-2 (⑪.3)');
      // The final projection carries the coarsened level-2 summary + the current
      // user message, and stays under control (some far content folded).
      expect(projected, contains('## 更早上下文'),
          reason: 'a coarsened projection must still lead with the summary marker');
      expect(projected, contains('continue'),
          reason: 'the current user message must survive coarsening');
    });

    testWidgets('⑪.3 reject-bloated-L2: a non-compressing level-2 is rejected, valid L1s kept', (tester) async {
      // l1Tokens=20 (< every batch's raw → each L1 is a VALID compression, so
      // split-if-invalid never fires) but l2Tokens=150 (>= the L1s it would roll
      // up → the L2 is INVALID, "measured < replaced" fails). ⑪.3 must NOT accept
      // a bloated L2; it rejects the coarsen and omits the oldest L1 instead, so
      // the projection keeps the (valid) L1 summaries and drops one, never sending
      // a summary larger than the content it replaced.
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 20, l2Tokens: 150);

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

      final projected = sidecar.lastMessagesJson ?? '';
      // ignore: avoid_print
      print('  [OBS] reject-bloated-L2: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'projectedChars=${projected.length} '
          'hasMarker=${projected.contains('## 更早上下文')} '
          'hasL2=${projected.contains('L2 rolled up')} '
          'hasContinue=${projected.contains('continue')}');
      // The coarsen was ATTEMPTED (summarizeText called) but the invalid (>= the
      // L1s it replaces) L2 was REJECTED — not sent as a bloated summary.
      expect(summaryProvider.summarizeTextCalls, greaterThanOrEqualTo(1),
          reason: 'coarsening must be attempted before the invalid L2 is rejected');
      expect(projected, isNot(contains('L2 rolled up')),
          reason: 'a level-2 that is not smaller than the L1s it replaces must be rejected, never sent');
      expect(projected, contains('## 更早上下文'),
          reason: 'the valid L1 summaries are still kept (rejected L2 does not drop them)');
      expect(projected, contains('continue'),
          reason: 'the current user message must survive');
    });

    testWidgets('⑪.3 split-if-invalid: an un-compressible batch is split down to atomics and omitted', (tester) async {
      // l1Tokens=150 (>= every batch's raw) so a batch's summary is NEVER smaller
      // than the batch it replaced — invalid. _resolveOpenLevel1 splits it in half,
      // recurses, and omits each atomic batch (data kept, D9) rather than send a
      // bloated summary. The projection must therefore be verbatim-only (no marker)
      // and summarize must have been called MORE than once per batch (split ran).
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 150, l2Tokens: 150);

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

      final projected = sidecar.lastMessagesJson ?? '';
      // ignore: avoid_print
      print('  [OBS] split: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'projectedChars=${projected.length} '
          'hasMarker=${projected.contains('## 更早上下文')} '
          'hasContinue=${projected.contains('continue')}');
      // More summarize calls than line-batches → the split recursion ran, and each
      // atomic un-compressible batch was omitted (no bloated summary was sent).
      expect(summaryProvider.summarizeCalls, greaterThan(6),
          reason: 'an un-compressible batch must be split down several times before omission');
      expect(projected, isNot(contains('## 更早上下文')),
          reason: 'un-compressible far content is omitted (never sent as a bloated summary)');
      expect(projected, contains('continue'),
          reason: 'the current user message must survive the split-omit');
    });

    testWidgets('R1-5: a FAILED summarization falls back to the full verbatim conversation',
        (tester) async {
      // R1-5: a failed summary must NEVER silently replace the folded context with a
      // placeholder ("(empty summary)" / a provider-not-found text). The throwing
      // provider simulates done!=0 / empty-content; _callModel must catch it and send
      // the FULL conversation verbatim (no summary marker, no placeholder).
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _ThrowingSummaryProvider();

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

      final projected = sidecar.lastMessagesJson ?? '';
      // [OBS] dump the actual projection before asserting (observability).
      // ignore: avoid_print
      print('  [OBS] R1-5 fallback: hasMarker=${projected.contains('## 更早上下文')} '
          'hasPlaceholder=${projected.contains('(empty summary)') || projected.contains('could not summarize')} '
          'hasFullConversation=${projected.contains('continue')} '
          'projectedChars=${projected.length}');
      expect(projected, isNot(contains('## 更早上下文')),
          reason: 'R1-5 a failed summarization must NOT send a summary marker (no compaction)');
      expect(projected, isNot(contains('(empty summary)')),
          reason: 'R1-5 a failed summarization must NOT leak a placeholder');
      expect(projected, isNot(contains('could not summarize')),
          reason: 'R1-5 a failed summarization must NOT leak a provider placeholder');
      expect(projected, contains('continue'),
          reason: 'R1-5 the current user message must survive the verbatim fallback');
    });
  });
}

/// A SummaryProvider that always throws (simulating done!=0 or empty-content
/// summarization) — used to pin the R1-5 "never a silent placeholder; fall back to
/// the full verbatim conversation" guarantee on the INLINE _callModel path.
class _ThrowingSummaryProvider implements SummaryProvider {
  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    throw StateError('summarization failed (simulated done!=0/empty)');
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    throw StateError('summarization failed (simulated done!=0/empty)');
  }
}
