import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

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
  SummaryNodeRepository? summaryNodeRepo,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: summaryNodeRepo,
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

/// A conversation where EVERY message has exactly [rawPerMsg] estimated tokens.
/// `ContextEstimator.estimateMessage` = ceil(len/4) + 4, so the content length
/// follows from the target: len = (rawPerMsg - 4) * 4 - 3. Several tests below
/// need exact batch geometry (which depends on the per-message raw size), so the
/// size is pinned here instead of being implied by a magic 'A' * 100.
List<Message> _convOfRaw(int n, int rawPerMsg, {int startSeq = 1}) {
  final len = (rawPerMsg - 4) * 4 - 3;
  return [
    for (var i = 0; i < n; i++)
      Message(
        id: 'p$i',
        seq: startSeq + i,
        sessionId: 's1',
        role: i.isEven ? 'user' : 'assistant',
        content: 'A' * len,
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

  /// How many level-1 summaries went into the LAST roll-up call, and the most any
  /// single roll-up call received. The roll-up rule is "adopt the coarser summary
  /// only if it measured SMALLER than the level-1s it replaces", so a test needs to
  /// know what it was replacing to check that "coarser" actually happened.
  int lastRollUpInputs = 0;
  int maxRollUpInputs = 0;

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
    // 一条"这一趟不许调太多次"的守卫。收拢循环的推进规则一旦被破坏（例如"被拒即不再
    // 重试"失效），同一组会被反复送进来 —— 那种情况下用例的失败表现是**永远不结束**
    // （case 体里声明的 Timeout 在 testWidgets 的假时钟下不会触发），整条流水线一直挂着
    // 而不是变红。这里主动抛错，把"挂死"变成"几毫秒内带着原因红掉"。
    if (summarizeTextCalls > 50) {
      throw StateError('summarizeText 在一趟压缩里被调用了 $summarizeTextCalls 次 —— '
          '"被拒即不再重试"这条推进规则没生效，这一趟不会结束');
    }
    // The caller joins the level-1 texts with a blank line, so counting the
    // non-empty chunks tells us how many level-1 summaries this roll-up replaces.
    lastRollUpInputs =
        text.split('\n\n').where((s) => s.trim().isNotEmpty).length;
    if (lastRollUpInputs > maxRollUpInputs) maxRollUpInputs = lastRollUpInputs;
    // l2Tokens lets the test simulate a compressing (small) or non-compressing
    // (large) level-2 roll-up.
    return SummaryResult(text: 'L2 rolled up', tokens: l2Tokens);
  }
}

/// Echoes whatever it was asked to summarize, and stamps each input span with a
/// `seq a..b` label. Tests need to read the ORDER in which summary segments reach
/// the model straight out of the real projection, so the text has to carry the
/// span it came from.
class _EchoSummaryProvider implements SummaryProvider {
  int summarizeCalls = 0;
  int summarizeTextCalls = 0;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
  }) async {
    summarizeCalls++;
    final lo = folded.isEmpty ? 0 : (folded.first.seq ?? 0);
    final hi = folded.isEmpty ? 0 : (folded.last.seq ?? 0);
    return SummaryResult(text: '层级 1 摘要 seq $lo..$hi', tokens: 1);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    summarizeTextCalls++;
    // The rolled-up summary keeps the labels of its inputs, in the order given.
    return SummaryResult(text: '合成结果[${text.replaceAll('\n', ' | ')}]', tokens: 300);
  }
}

/// Records EVERY folded span handed to the summarizer, so a test can assert that/// a given message (e.g. a content-empty tool-call assistant) reached the fold
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

/// An in-memory stand-in for the `summary_nodes` store.
///
/// `testWidgets` bodies run in a FakeAsync zone where a real sqflite database
/// never completes its I/O (measured: the test hangs with no output), so the
/// pipeline's persistence calls are captured here instead. This covers
/// "pipeline → repository call shape" (what it presets, what it writes back);
/// "repository → real SQLite" is covered by `summary_node_repository_test.dart`,
/// which uses a plain `test()` and a real temp database.
class _FakeSummaryNodeRepository implements SummaryNodeRepository {
  final List<SummaryNode> nodes = [];
  int _nextId = 1;
  final Map<String, int> _treeVersion = {};
  final Map<String, int> _dirtySince = {};

  @override
  Future<SummaryNode> insert(SummaryNode node) async {
    final stored = _copy(node, id: _nextId++);
    nodes.add(stored);
    return stored;
  }

  @override
  Future<SummaryNode> materialize({
    required String sessionId,
    required int level,
    required int startSeq,
    required int endSeq,
    required String nodeType,
    int? parentId,
    String? summaryJson,
    int? tokenCost,
    int? summaryPromptVersion,
    String? model,
    required int coveredMinSeq,
    required int coveredMaxSeq,
  }) async {
    // Mirrors the repository's upsert: one row per covered span per level.
    nodes.removeWhere((n) =>
        n.sessionId == sessionId &&
        n.level == level &&
        n.coveredMinSeq == coveredMinSeq &&
        n.coveredMaxSeq == coveredMaxSeq);
    final stored = SummaryNode(
      id: _nextId++,
      sessionId: sessionId,
      level: level,
      startSeq: startSeq,
      endSeq: endSeq,
      nodeType: nodeType,
      parentId: parentId,
      summaryJson: summaryJson,
      tokenCost: tokenCost,
      summaryPromptVersion: summaryPromptVersion,
      model: model,
      coveredMinSeq: coveredMinSeq,
      coveredMaxSeq: coveredMaxSeq,
    );
    nodes.add(stored);
    _treeVersion[sessionId] = (_treeVersion[sessionId] ?? 0) + 1;
    return stored;
  }

  @override
  Future<List<SummaryNode>> queryBySession(String sessionId) async =>
      nodes.where((n) => n.sessionId == sessionId).toList();

  @override
  Future<SummaryNode?> findCovering(
      String sessionId, int startSeq, int endSeq, {int? level}) async {
    final hits = nodes
        .where((n) =>
            n.sessionId == sessionId &&
            n.coveredMinSeq == startSeq &&
            n.coveredMaxSeq == endSeq &&
            (level == null || n.level == level))
        .toList()
      ..sort((a, b) => b.level - a.level);
    return hits.isEmpty ? null : hits.first;
  }

  @override
  Future<int> treeVersion(String sessionId) async => _treeVersion[sessionId] ?? 0;

  @override
  Future<void> bumpTreeVersion(String sessionId) async {
    _treeVersion[sessionId] = (_treeVersion[sessionId] ?? 0) + 1;
  }

  @override
  Future<int> dirtySinceSeq(String sessionId) async => _dirtySince[sessionId] ?? 0;

  @override
  Future<void> markDirty(String sessionId, int seq) async {
    final prev = _dirtySince[sessionId] ?? 0;
    _dirtySince[sessionId] = (prev == 0 || prev > seq) ? seq : prev;
  }

  @override
  Future<void> clearDirty(String sessionId) async {
    _dirtySince[sessionId] = 0;
  }

  static SummaryNode _copy(SummaryNode n, {required int id}) => SummaryNode(
        id: id,
        sessionId: n.sessionId,
        level: n.level,
        startSeq: n.startSeq,
        endSeq: n.endSeq,
        nodeType: n.nodeType,
        parentId: n.parentId,
        summaryJson: n.summaryJson,
        tokenCost: n.tokenCost,
        summaryPromptVersion: n.summaryPromptVersion,
        model: n.model,
        coveredMinSeq: n.coveredMinSeq,
        coveredMaxSeq: n.coveredMaxSeq,
      );
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

    testWidgets('一条 L1 摘要自己就超过阈值时仍然尝试合成更粗的 L2（不再被"至少两条"拦下）',
        (tester) async {
      // 阈值只认 token：模型容量 400 ⇒ 阈值 = 400 × 25 ÷ 100 = 100。
      // 每条消息 raw = 60；共 9 条 = 540 raw > 容量 400 ⇒ 进入压缩路径。
      // 远端被切成 4 批、每批 2 条 = 120 raw；假摘要器给每条 L1 报 110 token
      // （110 < 120 ⇒ 是有效压缩；110 > 阈值 100 ⇒ 它自己就超过阈值）。
      // 于是"要合成的这一组"只有 1 条。改之前有一道"至少两条"的条数门槛，会
      // 把这种情形直接跳过、一次 summarizeText 都不调；只有 token 判据才该管
      // 这件事，所以这里断言它真的被尝试调用。
      _setupAgentRegistry(maxContextTokens: 400);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_convOfRaw(9, 60));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 110, l2Tokens: 110);

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
      print('  [OBS] 单条超阈值: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'projectedChars=${projected.length} '
          'hasContinue=${projected.contains('continue')}');
      expect(summaryProvider.summarizeCalls, greaterThan(0),
          reason: '前提：这一趟确实压出了 L1 摘要（否则下面那条是空转）');
      expect(summaryProvider.summarizeTextCalls, greaterThanOrEqualTo(1),
          reason: '一条 L1 摘要自己就超过阈值 ⇒ 必须尝试把它合成更粗的 L2；'
              '改之前被"至少两条"的条数门槛拦下，这个数是 0');
      expect(projected, contains('continue'),
          reason: '当前用户消息必须活下来');
    });

    testWidgets('合成被拒后不再重试：这一趟正常结束，那一组只试一次',
        timeout: const Timeout(Duration(seconds: 20)), (tester) async {
      // 容量 4000 ⇒ 阈值 = 1000。15 条 × 100 raw = 1500 已过阈值 ⇒ 远端 11 条
      // （1100 raw）压成一条 L1。假摘要器给这条 L1 报 1050（< 1100，是有效压缩），
      // 给"合成出来的更粗那条"报 1200（不小于它要替换的 1050）⇒ 合成被拒。
      // 此时投影 = 1050 + 剩下的 400 原文 = 1450，离容量 4000 还差得远 —— 正是
      // "因为超过阈值进来、但并没有超容量"的情形。规则：被拒即不再重试，这一趟
      // 到此结束（否则同一组会被反复送进模型，既不终止也不是"只调一次"）。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_convOfRaw(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 1050, l2Tokens: 1200);

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
      print('  [OBS] 合成被拒: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'hasMarker=${projected.contains(kSummaryMarker)} '
          'hasL2=${projected.contains(kLevel2SummaryMarker)} '
          'hasContinue=${projected.contains('continue')}');
      expect(summaryProvider.summarizeCalls, 1,
          reason: '前提：远端只切出一批 L1（否则下面那条"只试一次"不成立）');
      expect(summaryProvider.summarizeTextCalls, 1,
          reason: '被拒的那一组只许试一次：改之前（没有"被拒即不再试"这条规则时）'
              '同一组会被反复送进模型，这个数会一直涨、这趟压缩不结束');
      expect(projected, contains('continue'),
          reason: '这趟压缩必须正常结束并把请求发出去');
    });

    testWidgets('3.4/6.4 跨轮次累加：上一轮的两条层级 1 + 本轮新压的一条 ⇒ 合成同一条更粗的',
        (tester) async {
      // 容量 4000 ⇒ 阈值 1000。库里预置两条上一轮的层级 1（各 400，覆盖 seq 1..4 /
      // 5..8）。这一轮的消息 seq 1..19（每条 100 raw）：已覆盖到 seq 8，尾部
      // seq 9..19 共 1100 raw 超过阈值 ⇒ 本轮新压出一批层级 1（报 500）。
      // 合并看：连续三段层级 1 合计 400+400+500 = 1300 > 阈值 ⇒ 应该被合成成
      // **同一条**覆盖 seq 1..19 的更粗摘要 —— 这就是"累加能跨轮次攒到阈值"。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> putL1(int lo, int hi) => repo.materialize(
            sessionId: dbSessionId,
            level: 1,
            startSeq: lo,
            endSeq: hi,
            nodeType: 'summary',
            summaryJson: jsonEncode({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '上一轮的层级 1 摘要 seq $lo..$hi'},
              ],
            }),
            tokenCost: 400,
            summaryPromptVersion: 1,
            model: 'test-model',
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
      await putL1(1, 4);
      await putL1(5, 8);

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convOfRaw(19, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 500, l2Tokens: 300);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: repo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final nodesAfter = await repo.queryBySession(dbSessionId);
      final l2 = nodesAfter.where((n) => n.level == 2).toList();
      // ignore: avoid_print
      print('  [OBS] 3.4/6.4 跨轮次: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '层级2覆盖=${l2.map((n) => '[${n.coveredMinSeq},${n.coveredMaxSeq}]').join(",")} '
          'hasL2Marker=${projected.contains(kLevel2SummaryMarker)} '
          'hasContinue=${projected.contains('continue')}');
      expect(summaryProvider.summarizeCalls, 1,
          reason: '3.4：本轮只新压出一批层级 1 —— 库里已有的两条不重新压原文，'
              '所以这个数只等于本轮新批次数，不受既有节点数量影响');
      expect(summaryProvider.summarizeTextCalls, 1, reason: '只合成一次');
      expect(l2.length, 1, reason: '只产生一条更粗的摘要');
      expect(l2.first.coveredMinSeq, 1,
          reason: '6.4：合成出来的那条要包含上一轮那两条的范围（从 seq 1 起）');
      expect(l2.first.coveredMaxSeq, greaterThanOrEqualTo(9),
          reason: '6.4：也要包含本轮新压那一批的范围（到 seq 9 之后）');
      expect(projected, contains(kLevel2SummaryMarker));
      expect(projected, contains('continue'));
    });

    testWidgets('3.2/3.3/6.5 交错场景：层级 1 照常成组合成，层级 2 不参与，条目顺序严格从旧到新',
        (tester) async {
      // 容量 4000 ⇒ 阈值 1000。库里预置：层级 1 覆盖 seq 1..4（600）、层级 1 覆盖
      // seq 5..8（600）、层级 2 覆盖 seq 9..12（500）。
      //  - 前两条是同一段连续的层级 1，合计 1200 > 阈值 ⇒ 应该被合成成一条覆盖
      //    seq 1..8 的层级 2；
      //  - 那条已落盘的层级 2 是"冻结"的：只打断成组，自己绝不再被拿去合成；
      //  - 发给模型的条目，覆盖范围必须严格从旧到新递增。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> put(int level, int lo, int hi, int tokens) => repo.materialize(
            sessionId: dbSessionId,
            level: level,
            startSeq: lo,
            endSeq: hi,
            nodeType: 'summary',
            summaryJson: jsonEncode({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '层级 $level 摘要 seq $lo..$hi'},
              ],
            }),
            tokenCost: tokens,
            summaryPromptVersion: 1,
            model: 'test-model',
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
      await put(1, 1, 4, 600);
      await put(1, 5, 8, 600);
      await put(2, 9, 12, 500);

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convOfRaw(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _EchoSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: repo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final nodesAfter = await repo.queryBySession(dbSessionId);
      final l2 = nodesAfter.where((n) => n.level == 2).toList();
      // 发给模型的内容里，各段摘要按出现顺序留下的覆盖起点。每条摘要文本都带
      // "seq a..b" 标签（假摘要器把输入原样回显），所以能直接从真实投影里读顺序。
      final startSeqInOrder = RegExp(r'seq (\d+)\.\.')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      // ignore: avoid_print
      print('  [OBS] 3.2/3.3 交错: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '层级2覆盖=${l2.map((n) => '[${n.coveredMinSeq},${n.coveredMaxSeq}]').join(",")} '
          '投影里的覆盖起点（按出现顺序）=$startSeqInOrder '
          'hasL2Marker=${projected.contains(kLevel2SummaryMarker)} '
          'hasContinue=${projected.contains('continue')}');
      expect(summaryProvider.summarizeCalls, 0,
          reason: '前提：这一轮尾部没产生新的层级 1 批次（否则"只合成一次"不好归因）');
      expect(summaryProvider.summarizeTextCalls, 1,
          reason: '两条连续的层级 1（600+600=1200 > 阈值 1000）合成为一条更粗的；'
              '那条已落盘的层级 2 不参与 ⇒ 只合成这一次');
      expect(
          l2.where((n) => n.coveredMinSeq == 1 && n.coveredMaxSeq == 8).length, 1,
          reason: '新合成的那条覆盖 seq 1..8（正好是被合成掉那两条的并集）');
      expect(l2.where((n) => n.coveredMinSeq == 9 && n.coveredMaxSeq == 12).length, 1,
          reason: '库里原有的那条层级 2 原样保留，没有被重新合成、也没有被删');
      expect(projected, contains(kLevel2SummaryMarker));
      expect(projected, contains('continue'));
      // 顺序不变式：发给模型的内容里，各段覆盖起点严格从旧到新递增。
      expect(startSeqInOrder.length, greaterThanOrEqualTo(2),
          reason: '前提：投影里确实有多段摘要，否则"顺序"无从谈起');
      for (var i = 1; i < startSeqInOrder.length; i++) {
        expect(startSeqInOrder[i], greaterThan(startSeqInOrder[i - 1]),
            reason: '第 $i 段的覆盖起点（${startSeqInOrder[i]}）必须严格大于前一段的'
                '（${startSeqInOrder[i - 1]}）—— 改成单一有序表之后顺序不能乱');
      }
    });

    testWidgets('⑪.3 coarsen: over-budget L1 summaries are rolled into a level-2', (tester) async {
      // 2026-09-20 按新阈值重新取尺寸参数：容量 200 ⇒ 阈值 = 200 × 25 ÷ 100 = 50。
      // 每条消息 29 raw ⇒ 每批 2 条（58 > 50）⇒ 24 条切成 12 批 L1。
      // 假摘要器给每条 L1 报 30（< 58 ⇒ 是有效压缩，不会触发"拆半重压"），
      // 给合成出来的那条报 20（< 两条之和 60 ⇒ 是**更粗**的）⇒ 合成被接受，
      // 12×30 = 360 > 容量 200 ⇒ 会持续合成直到装得下。
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_longConversation(24));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 30, l2Tokens: 20);

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
          'maxRollUpInputs=${summaryProvider.maxRollUpInputs} '
          'l1Tokens=${summaryProvider.l1Tokens} l2Tokens=${summaryProvider.l2Tokens} '
          'projectedChars=${projected.length} '
          'hasL2=${projected.contains('L2 rolled up')}');
      expect(summaryProvider.summarizeTextCalls, greaterThanOrEqualTo(1),
          reason: 'over-budget L1 summaries must be coarsened into a level-2 (⑪.3)');
      // ⑥.6 补的那条：光"调用过合成"证明不了"更粗"。真正确认"更粗"的是
      // **实测**：合成出来的那条比它替换掉的那几条 L1 之和更小。若不成立，
      // 代码会走拒绝分支（见下一条 reject-bloated-L2 用例）。
      expect(summaryProvider.maxRollUpInputs, greaterThanOrEqualTo(2),
          reason: '前提：确实有一次合成是把 2 条以上的 L1 合成成一条');
      expect(summaryProvider.l2Tokens,
          lessThan(summaryProvider.l1Tokens * summaryProvider.maxRollUpInputs),
          reason: '合成出来的那条必须**实测小于**被它替换掉的那几条 L1 之和');
      // The final projection carries the coarsened level-2 summary + the current
      // user message, and stays under control (some far content folded).
      expect(projected, contains('## 更早上下文'),
          reason: 'a coarsened projection must still lead with the summary marker');
      expect(projected, contains('L2 rolled up'),
          reason: '真正进入投影的是那条更粗的摘要');
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

  // ── 触发口径：只看 token 累计有没有超过阈值（不等窗口装满）────────────────
  group('阈值触发（不等窗口装满）', () {
    testWidgets('6.1 原文攒够阈值就压：内容远没到模型容量、但已超过阈值', (tester) async {
      // 模型容量 4000 ⇒ 阈值 = 4000 × 25 ÷ 100 = 1000。
      // 对话 15 条 × 100 raw = 1500 raw —— 只占容量的 37.5%，还空着一大半，
      // 但已经超过阈值 ⇒ 按用户钉死的规则就该压。改之前这里什么都不做：
      // 内容没超容量就直接原样全发，一条摘要都不会产出。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_convOfRaw(15, 100));
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

      final projected = sidecar.lastMessagesJson ?? '';
      final raw = ContextEstimator.estimateConversation(msgRepo.messages);
      // ignore: avoid_print
      print('  [OBS] 6.1 阈值 1000 / 容量 4000 / 原文 raw=$raw '
          'lastFolded=${summaryProvider.lastFolded?.length} '
          'hasSummaryMarker=${projected.contains(kSummaryMarker)} '
          'hasContinue=${projected.contains('continue')}');
      expect(raw, greaterThan(1000),
          reason: '前提：原文 raw 确实超过了阈值（否则这条用例是空转）');
      expect(raw, lessThan(4000),
          reason: '前提：原文 raw 远没到模型容量 —— 这正是"不等装满也要压"的场景');
      expect(summaryProvider.lastFolded, isNotNull,
          reason: '超过阈值就该压，不等窗口装满；改之前这里从不触发压缩');
      expect(projected, contains(kSummaryMarker),
          reason: '压出来的更早上下文摘要必须真的进入发给模型的内容');
      expect(projected, contains('continue'),
          reason: '当前用户消息必须活下来');
    });

    testWidgets('6.2 没超容量也合成更粗的摘要：库里两条 L1 实测相加超过阈值',
        (tester) async {
      // 模型容量 4000 ⇒ 阈值 = 1000。库里已有两条上一轮压出来的 L1 摘要，
      // 各 600 token，合计 1200 > 阈值 ⇒ 即使当前投影离容量还差得远，也应该
      // 把它们合成一条更粗的摘要。改之前：这两条被当成"已冻结"、根本不参与
      // 合成，而且收拢循环的进入条件是"还超容量"，所以一条层级 2 的摘要都
      // 不会出现。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> putL1(int lo, int hi) => repo.materialize(
            sessionId: dbSessionId,
            level: 1,
            startSeq: lo,
            endSeq: hi,
            nodeType: 'summary',
            summaryJson: jsonEncode({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '上一轮压出来的 L1 摘要 seq $lo..$hi'},
              ],
            }),
            tokenCost: 600,
            summaryPromptVersion: 1,
            model: 'test-model',
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
      await putL1(1, 4);
      await putL1(5, 8);
      final presetNodes = await repo.queryBySession(dbSessionId);
      // ignore: avoid_print
      print('  [OBS] 6.2 预置节点: '
          '${presetNodes.map((n) => 'lvl${n.level}[${n.coveredMinSeq},${n.coveredMaxSeq}]'
              '=${n.tokenCost}').join(' | ')}');

      // 消息 seq 1..10（每条 100 raw）；已冻结范围只到 seq 8，所以 seq 9/10
      // 与当前这条用户消息留在尾部原样发送。整体 raw ≈ 1200，容量 4000。
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convOfRaw(10, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _SizedFakeSummaryProvider(l1Tokens: 1, l2Tokens: 300);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
        summaryNodeRepo: repo,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final nodesAfter = await repo.queryBySession(dbSessionId);
      final l2 = nodesAfter.where((n) => n.level == 2).toList();
      // ignore: avoid_print
      print('  [OBS] 6.2 summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          'L2节点数=${l2.length} '
          'L2覆盖=${l2.map((n) => '[${n.coveredMinSeq},${n.coveredMaxSeq}]').join(",")} '
          'hasL2Marker=${projected.contains(kLevel2SummaryMarker)} '
          'hasContinue=${projected.contains('continue')} '
          'projectedChars=${projected.length}');
      expect(l2, isNotEmpty,
          reason: '库里 L1 摘要累计 1200 已超过阈值 1000 ⇒ 必须合成出一条 level = 2 '
              '的摘要，哪怕当前投影离模型容量还差得远；改之前一条都不会有');
      expect(projected, contains(kLevel2SummaryMarker),
          reason: '合成出来的更粗摘要必须真的进入发给模型的内容');
      expect(projected, contains('continue'),
          reason: '当前用户消息必须活下来');
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
