import 'dart:async';
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
import 'package:alias_agent/services/compaction/seam_selector.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/context_estimator.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/ui/compaction_status_banner.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';
import 'helpers/real_context_fixture.dart';

/// 注册这个文件用的 general agent。
///
/// **[waitPercent] 的缺省值不是生产缺省**：本文件绝大多数用例验的是压缩与投影**规则
/// 本身**（怎么分批、按距离分档、每段恰好一种表示、阈值到了就合成），它们的前提是
/// "这一轮会在发送前压"。而生产缺省是 75%（用户 2026-10-02 的要求：不压就发的投影
/// 占比不到 75% 就不等），本文件那些几何大多只占容量的 30%～40%，用生产缺省就压不起来。
/// 所以这里把等待门槛缺省调到 1%（等于"永远等"），几何与判据一个字都不用动 ——
/// 这不是放松判据，而是把"这一轮会压"这个前提显式化。
/// **要验证"不等"那条路径的用例，必须显式传 `waitPercent: 75`（生产缺省）**。
void _setupAgentRegistry({
  int maxContextTokens = 200,
  List<String> standingRequirements = const [],
  int waitPercent = 1,
}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
    compactionWaitThresholdPercent: waitPercent,
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
  SeamSelector? seamSelector,
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
        seamSelector: seamSelector,
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

/// Like [_convOfRaw], but every message carries its own seq in its body
/// (`m<seq>:` + padding) at the SAME estimated size, so a test can read straight
/// out of the real projection which messages were sent as raw text and which
/// were covered by a summary span — instead of inferring it from lengths.
List<Message> _convLabeled(int n, int rawPerMsg, {int startSeq = 1}) {
  final len = (rawPerMsg - 4) * 4 - 3;
  final out = <Message>[];
  for (var i = 0; i < n; i++) {
    final seq = startSeq + i;
    final prefix = 'm$seq:';
    out.add(Message(
      id: 'p$i',
      seq: seq,
      sessionId: 's1',
      role: i.isEven ? 'user' : 'assistant',
      content: '$prefix${'A' * (len - prefix.length)}',
      createdAt: i,
    ));
  }
  return out;
}

/// The seq spans of the summary entries that reached the model, in the order
/// they appear. Summary text always carries its covered span (`seq a..b`: either
/// preset node text or the echo summarizer's label), so this reads the real
/// projection rather than a re-derived plan.
List<({int lo, int hi})> _summarySpansIn(String projected) =>
    RegExp(r'seq (\d+)\.\.(\d+)')
        .allMatches(projected)
        .map((m) => (lo: int.parse(m.group(1)!), hi: int.parse(m.group(2)!)))
        .toList();

/// How many representations of message [seq] the projection carries: once as
/// raw text (its body shows `m<seq>:`) and once per covering summary span.
/// "Exactly one representation" means this returns exactly 1 for every message.
int _representationsOf(int seq, String projected, List<({int lo, int hi})> spans) {
  var hits = 0;
  if (projected.contains('m$seq:')) hits++;
  for (final s in spans) {
    if (seq >= s.lo && seq <= s.hi) hits++;
  }
  return hits;
}

/// 「每一段内容都恰好有一种表示」这条不变量的**通用守卫**：把 1..[upToSeq] 每条消息在
/// 真实投影里数一遍，返回"一次都没出现"和"出现了不止一次"的 seq。
///
/// 为什么要有这么一条：这条不变量是本变更的核心（规范《Recency-gradient hierarchical
/// compaction》原文 `every span of history SHALL be projected with EXACTLY ONE
/// representation`），而投影是把"计划里的段""库里载入的摘要""本轮新压出来的批次"三路拼
/// 起来的，最容易出的错就是某一路因为对象对不上、位置排错、或者被顶替之后没人接手而**整
/// 段漏掉**（这次真的发生过：seq 41..91 曾经在投影里一条表示都没有）。
/// 要求 fixture 用 [_convLabeled]（正文里带 `m<seq>:`），否则读不出原文那一路。
({List<int> missing, List<int> doubled}) _accountEveryMessage(String projected,
    {required int upToSeq}) {
  final spans = _summarySpansIn(projected);
  final missing = <int>[];
  final doubled = <int>[];
  for (var seq = 1; seq <= upToSeq; seq++) {
    final n = _representationsOf(seq, projected, spans);
    if (n == 0) missing.add(seq);
    if (n > 1) doubled.add(seq);
  }
  return (missing: missing, doubled: doubled);
}

/// [_accountEveryMessage] 的断言版：一次都没出现的 seq、出现了不止一次的 seq，都必须为空。
void _expectEveryMessageExactlyOnce(String projected, {required int upToSeq}) {
  final account = _accountEveryMessage(projected, upToSeq: upToSeq);
  expect(account.missing, isEmpty,
      reason: '每一段都必须有一种表示 —— 这些 seq 在投影里凭空消失了：${account.missing}');
  expect(account.doubled, isEmpty,
      reason: '同一段内容只许出现一次 —— 这些 seq 出现了两种以上表示：${account.doubled}');
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
    List<SummaryReference> reference = const [],
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
  /// 报给调用方的实测 token 数（默认 1 / 300）。需要"按尺寸驱动收拢循环"的用例可以调，
  /// 这样它既能带上覆盖区间（`seq a..b`，供"每段恰好一种表示"那条通用守卫读），
  /// 又能控制尺寸。
  final int l1Tokens;
  final int l2Tokens;
  _EchoSummaryProvider({this.l1Tokens = 1, this.l2Tokens = 300});

  int summarizeCalls = 0;
  int summarizeTextCalls = 0;

  /// 每一次 summarize 收到的参考上下文（按调用顺序）—— 本变更的接线判据靠它：
  /// 只测挑选函数是测不到"main.dart 真的把参考传下来了"。
  final List<List<SummaryReference>> referencesPerCall = [];

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) async {
    summarizeCalls++;
    referencesPerCall.add(List.of(reference));
    final lo = folded.isEmpty ? 0 : (folded.first.seq ?? 0);
    final hi = folded.isEmpty ? 0 : (folded.last.seq ?? 0);
    return SummaryResult(text: '层级 1 摘要 seq $lo..$hi', tokens: l1Tokens);
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) async {
    summarizeTextCalls++;
    // The rolled-up summary keeps the labels of its inputs, in the order given.
    return SummaryResult(
        text: '合成结果[${text.replaceAll('\n', ' | ')}]', tokens: l2Tokens);
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
    List<SummaryReference> reference = const [],
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

    testWidgets('合成只试一次：二级不比那几条一级短 ⇒ 用压缩前那一侧，这一趟正常结束',
        timeout: const Timeout(Duration(seconds: 20)), (tester) async {
      // 容量 4000 ⇒ 阈值 = 1000。15 条 × 100 raw = 1500 已过阈值 ⇒ 远端 11 条
      // （1100 raw）压成一条 L1。假摘要器给这条 L1 报 1050（< 1100，是有效压缩），
      // 给"合成出来的更粗那条"报 1200（不小于它要替换的 1050）。
      // **旧规则**：这条二级"被拒"，靠"被拒即不再重试"结束这一趟。
      // **新规则**：不存在"被拒"这个态 —— 取小者取中了压缩前那一侧（1050 < 1200），
      // 二级的正文 = 那条一级的文本，这一趟照样结束（一组只试一次）。
      // 那条二级此刻还不够远（距离 400 < 2T = 2000）⇒ 这一趟先不顶替那条一级。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _EchoSummaryProvider(l1Tokens: 1050, l2Tokens: 1200);

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
          reason: '同一组只许试一次合成（旧规则靠"被拒即不再重试"，新规则下根本不存在'
              '"被拒"这个态 —— 取小者总会产出一条二级；这个数涨上去说明这一趟不终止）');
      expect(projected, contains(kSummaryMarker),
          reason: '那条二级还不够远（距离 400 < 2T）⇒ 这一趟仍然由那条有效的一级代表');
      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '二级还不够远时不许顶替一级（同一段同时出现两种表示就是缺陷）');
      expect(projected, contains('continue'),
          reason: '这趟压缩必须正常结束并把请求发出去');
      // 「每一段恰好一种表示」这条不变量在这一场也要成立：15 条消息里 1..11 该由那条 1 级
      // 摘要接走、12..15 该逐字发。通用守卫一次把"谁都少了一段"和"同一段发了两遍"都查了。
      _expectEveryMessageExactlyOnce(projected, upToSeq: 15);
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
      final msgRepo = FakeMessageRepository(_convLabeled(19, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _EchoSummaryProvider(l1Tokens: 500, l2Tokens: 300);

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
      // 投影口径（2026-09-26 的裁定）：这条 2 级盖住的整段还没落到最远档（它最新端就是
      // 刚压出来的那一批，离末尾不到一个 2T）⇒ 这一趟不许拿它顶替，该由它盖住的那几条
      // 1 级表示。旧断言写的是"2 级必须出现在投影里"，与这条口径相反，故按新口径改写。
      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '这条 2 级盖住的整段还没整段落到最远档 ⇒ 这一趟不进投影');
      expect(projected, contains(kSummaryMarker),
          reason: '该由它盖住的那几条 1 级表示这一段');
      final spans = _summarySpansIn(projected);
      for (final expect1 in [
        (lo: 1, hi: 4),
        (lo: 5, hi: 8),
      ]) {
        expect(spans, contains(expect1),
            reason: '被 2 级盖住的那条 1 级 $expect1 必须真的进投影');
      }
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].lo, greaterThan(spans[i - 1].hi),
            reason: '各段互不重叠、严格从旧到新：第 $i 段的起点 ${spans[i].lo} 必须大于'
                '前一段的终点 ${spans[i - 1].hi}');
      }
      expect(projected, contains('continue'));
      // 通用守卫：1..19 每条消息都恰好有一种表示（这一场是 1..4、5..8、9..19 三段 1 级接走）
      _expectEveryMessageExactlyOnce(projected, upToSeq: 19);
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
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
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
      // 发给模型的内容里，各段摘要覆盖的 seq 区间（摘要文本都带 "seq a..b" 标签）。
      final spans = _summarySpansIn(projected);
      // ignore: avoid_print
      print('  [OBS] 3.2/3.3 交错: summarizeCalls=${summaryProvider.summarizeCalls} '
          'summarizeTextCalls=${summaryProvider.summarizeTextCalls} '
          '层级2覆盖=${l2.map((n) => '[${n.coveredMinSeq},${n.coveredMaxSeq}]').join(",")} '
          '投影里的摘要段（按出现顺序）='
          '${spans.map((s) => '${s.lo}..${s.hi}').join(",")} '
          'hasL2Marker=${projected.contains(kLevel2SummaryMarker)} '
          'hasContinue=${projected.contains('continue')}');
      expect(summaryProvider.summarizeCalls, 0,
          reason: '前提：这一轮尾部没产生新的层级 1 批次（否则"只合成一次"不好归因）');
      expect(summaryProvider.summarizeTextCalls, 1,
          reason: '两条连续的层级 1（600+600=1200 > 阈值 1000）合成为一条更粗的；'
              '那条已落盘的层级 2 不参与 ⇒ 只合成这一次。合成照旧"阈值到了就做"，'
              '与它这一趟进不进投影无关');
      expect(
          l2.where((n) => n.coveredMinSeq == 1 && n.coveredMaxSeq == 8).length, 1,
          reason: '新合成的那条覆盖 seq 1..8（正好是被合成掉那两条的并集）');
      expect(l2.where((n) => n.coveredMinSeq == 9 && n.coveredMaxSeq == 12).length, 1,
          reason: '库里原有的那条层级 2 原样保留，没有被重新合成、也没有被删');
      // 投影口径（2026-09-26 的裁定）：两条 2 级盖住的整段都还贴着末尾（离最远档差得远）
      // ⇒ 这一趟都不进投影，由各自的 1 级摘要表示。旧断言写的是"2 级必须出现在投影里"，
      // 按新口径改写成"2 级还不该出现、1 级该出现"。
      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '两条 2 级的整段都还没落到最远档 ⇒ 这一趟都不进投影');
      expect(projected, contains(kSummaryMarker),
          reason: '这一段该由它的 1 级摘要表示');
      expect(projected, contains('continue'));
      // 顺序不变式（新口径）：发给模型的内容里，各段覆盖的 seq 区间**互不重叠**、起点严格
      // 从旧到新。旧断言只比"起点递增"（允许区间重叠），这里换成更强的一条。
      expect(spans.length, greaterThanOrEqualTo(2),
          reason: '前提：投影里确实有多段摘要，否则"顺序"无从谈起');
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].lo, greaterThan(spans[i - 1].hi),
            reason: '第 $i 段的覆盖起点（${spans[i].lo}）必须大于前一段的覆盖终点'
                '（${spans[i - 1].hi}）—— 各段互不重叠，且严格从旧到新');
      }
      // 通用守卫：1..15 每条消息都恰好有一种表示。这一场正好把三条路都走了一遍 ——
      // 1..4 / 5..8 由落盘的 1 级接走、9..12 那条 2 级还没进投影所以照原文发、
      // 13..15 是尾部原文。
      _expectEveryMessageExactlyOnce(projected, upToSeq: 15);
    });

    // ---------------------------------------------------------------------
    // 投影分档：一段内容离现在多远，决定它在投影里发的是原文、1 级摘要还是 2 级摘要。
    //
    // 两条用例共用同一套几何：容量 20000 ⇒ 阈值 T = 5000、外边界 2T = 10000；
    // 对话 130 条 × 100 raw（seq 1..130）+ 当前这条用户消息（raw 6）。按"它后面还有
    // 多少原文"算距离：distance(seq s) = 100 × (130 − s) + 6，于是
    //   · seq ≤ 30 的段：整段都在 2T 之外（2 级该在的档）
    //   · seq 31..80 的段：起点在 T 之外、但没到 2T（1 级该在的档）
    //   · seq > 80 的段：起点还没离开最近档（发原文）
    // 口径：一段内容的档按它**最旧那条消息**算；1 级只要起点够远就顶替，2 级要它盖住的
    // **整段**都落到最远档才顶替（刚合成出来的 2 级因此不会立刻把 1 级挤掉）。
    // ---------------------------------------------------------------------

    testWidgets('投影分档 · 状态 A：2 级还不够远 ⇒ 发它盖住的 1 级，2 级不进投影',
        (tester) async {
      // 库里预置：2 级 [1..40]，它最新端 seq 40 的距离是 9006 ≤ 2T ⇒ 整段还没落到
      // 最远档；它盖住的两条 1 级 [1..15]、[16..40] 起点都够远 ⇒ 该由它们表示。
      // 期望：投影里发的是那两条 1 级（1 级标记在、2 级标记不在），每一段恰好一种表示。
      _setupAgentRegistry(maxContextTokens: 20000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> put(int level, int lo, int hi, int tokens) =>
          repo.materialize(
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
      await put(1, 1, 15, 400);
      await put(1, 16, 40, 400);
      await put(2, 1, 40, 700);

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(130, 100));
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
      final spans = _summarySpansIn(projected);
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      final missing = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) == 0) s
      ];
      final doubled = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) > 1) s
      ];
      // ignore: avoid_print
      print('  [OBS] 状态A（2 级还不够远）: 发出去 '
          '${(jsonDecode(projected) as List).length} 条消息；'
          '1级标记=${projected.contains(kSummaryMarker)} '
          '2级标记=${projected.contains(kLevel2SummaryMarker)}；'
          '摘要段=${spans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '原文逐条出现的 seq 有 ${rawSeqs.length} 个'
          '（最小 ${rawSeqs.reduce((a, b) => a < b ? a : b)}，'
          '最大 ${rawSeqs.reduce((a, b) => a > b ? a : b)}）；'
          '没有任何表示的 seq=$missing；出现两次的 seq=$doubled');

      expect(projected, contains(kSummaryMarker),
          reason: '状态A：2 级还不够远 ⇒ 这一段必须由它的 1 级摘要表示，'
              '投影里要有 1 级标记');
      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '状态A：这条 2 级盖住的整段还没落到最远档（最新端 seq 40 的距离 '
              '9006 ≤ 2T=10000）⇒ 不许拿它顶替。改之前这里必然红：'
              '旧代码把最粗的那条当唯一表示，直接发 2 级');
      expect(spans, contains((lo: 1, hi: 15)),
          reason: '状态A：被 2 级盖住、但自己够远的 1 级 [1..15] 必须真的进投影');
      expect(spans, contains((lo: 16, hi: 40)),
          reason: '状态A：同上，[16..40] 这条也要在');
      expect(spans, contains((lo: 41, hi: 91)),
          reason: '状态A：本轮刚压出来的那一批起点 seq41 的距离是 8906 > T ⇒ '
              '按 1 级摘要发（一段内容的档按它最旧那条消息算）');
      expect(rawSeqs, containsAll(<int>[92, 130]),
          reason: '状态A：还没离开最近档的那一段与最新的原文都必须逐条原样发出去');
      expect(missing, isEmpty,
          reason: '状态A：每一段都必须有一种表示 —— 不许出现谁也不管的空档');
      expect(doubled, isEmpty,
          reason: '状态A：同一段内容只许出现一次（不许既有 1 级文本、又有覆盖它的 '
              '2 级文本）');
      expect(projected, contains('continue'), reason: '当前用户消息必须活下来');
    });

    testWidgets('投影分档 · 状态 B：2 级整段够远 ⇒ 2 级与中距的 1 级并存、互不重叠',
        (tester) async {
      // 库里预置：2 级 [1..26]，最新端 seq 26 的距离是 10406 > 2T ⇒ 整段落到最远档，
      // 可以用；它盖住的两条 1 级 [1..12]、[13..26] 不许再单独出现；另有一条中距的
      // 1 级 [31..60]（整段在 T 之外、没到 2T）该照常发。
      _setupAgentRegistry(maxContextTokens: 20000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> put(int level, int lo, int hi, int tokens) =>
          repo.materialize(
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
      await put(1, 1, 12, 400);
      await put(1, 13, 26, 400);
      await put(2, 1, 26, 700);
      await put(1, 31, 60, 400);

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(130, 100));
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
      final spans = _summarySpansIn(projected);
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      final missing = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) == 0) s
      ];
      final doubled = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) > 1) s
      ];
      // ignore: avoid_print
      print('  [OBS] 状态B（2 级整段够远）: 发出去 '
          '${(jsonDecode(projected) as List).length} 条消息；'
          '1级标记=${projected.contains(kSummaryMarker)} '
          '2级标记=${projected.contains(kLevel2SummaryMarker)}；'
          '摘要段=${spans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '原文逐条出现的 seq 有 ${rawSeqs.length} 个'
          '（最小 ${rawSeqs.reduce((a, b) => a < b ? a : b)}，'
          '最大 ${rawSeqs.reduce((a, b) => a > b ? a : b)}）；'
          '没有任何表示的 seq=$missing；出现两次的 seq=$doubled');

      expect(projected, contains(kLevel2SummaryMarker),
          reason: '状态B：这条 2 级盖住的整段都落到最远档了 ⇒ 该它上场');
      expect(spans, contains((lo: 1, hi: 26)),
          reason: '状态B：2 级覆盖 seq 1..26，整个跨度只由它一个表示');
      expect(projected, contains(kSummaryMarker),
          reason: '状态B：中距那一段（seq 31..60）自己的 1 级摘要必须同时还在');
      expect(spans, contains((lo: 31, hi: 60)),
          reason: '状态B：中距 1 级的覆盖范围要原样发出');
      expect(projected, isNot(contains('seq 13..26')),
          reason: '状态B：被这条 2 级盖住的 1 级不许再单独发一份（同一段两种表示）');
      expect(spans, contains((lo: 61, hi: 111)),
          reason: '状态B：本轮刚压出来的那一批起点 seq61 的距离是 6906 > T ⇒ '
              '按 1 级摘要发');
      expect(rawSeqs, containsAll(<int>[27, 30, 112, 130]),
          reason: '状态B：seq 27..30 这一段没有任何摘要盖住（夹在 2 级与中距 1 级之间）'
              '—— 必须按原文发出去，不许在投影里凭空消失；最近的原文同样要原样发');
      expect(missing, isEmpty,
          reason: '状态B：每一段都必须有一种表示 —— 不许出现谁也不管的空档');
      expect(doubled, isEmpty,
          reason: '状态B：同一段内容只许出现一次');
      expect(projected, contains('continue'), reason: '当前用户消息必须活下来');
    });

    testWidgets('投影分档 · 状态 C：某一段一条摘要都没有 ⇒ 照原文发，不许留下空档',
        (tester) async {
      // 库里只有一条 2 级 [1..40]，它还不够远（最新端 seq 40 的距离 9006 ≤ 2T），而且没有
      // 对应的 1 级节点可回落。期望：seq 1..40 这一段按原文发出去 —— 不许在投影里凭空
      // 消失（改之前这一段谁都不管：它不在任何已选摘要里，又被"已覆盖到 seq 40"挡在
      // 尾部之外，发出去的内容里根本没有它）。
      _setupAgentRegistry(maxContextTokens: 20000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      await repo.materialize(
        sessionId: dbSessionId,
        level: 2,
        startSeq: 1,
        endSeq: 40,
        nodeType: 'summary',
        summaryJson: jsonEncode({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '层级 2 摘要 seq 1..40'},
          ],
        }),
        tokenCost: 700,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: 1,
        coveredMaxSeq: 40,
      );

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(130, 100));
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
      final spans = _summarySpansIn(projected);
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      final missing = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) == 0) s
      ];
      final doubled = [
        for (var s = 1; s <= 130; s++)
          if (_representationsOf(s, projected, spans) > 1) s
      ];
      // ignore: avoid_print
      print('  [OBS] 状态C（这一段一条摘要都没有）: 发出去 '
          '${(jsonDecode(projected) as List).length} 条消息；'
          '1级标记=${projected.contains(kSummaryMarker)} '
          '2级标记=${projected.contains(kLevel2SummaryMarker)}；'
          '摘要段=${spans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '原文逐条出现的 seq 有 ${rawSeqs.length} 个'
          '（最小 ${rawSeqs.reduce((a, b) => a < b ? a : b)}，'
          '最大 ${rawSeqs.reduce((a, b) => a > b ? a : b)}）；'
          '没有任何表示的 seq=$missing；出现两次的 seq=$doubled');

      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '状态C：这条 2 级盖住的整段还没落到最远档 ⇒ 不进投影');
      expect(rawSeqs, containsAll(<int>[1, 20, 40]),
          reason: '状态C：seq 1..40 这一段没有任何摘要可发 ⇒ 必须按原文逐条发出去');
      expect(missing, isEmpty,
          reason: '状态C：每一段都必须有一种表示 —— 不许出现谁也不管的空档');
      expect(doubled, isEmpty,
          reason: '状态C：同一段内容只许出现一次');
      expect(projected, contains('continue'), reason: '当前用户消息必须活下来');
    });

    testWidgets(
        '7.1 投影里摘要段与原文段交错时，工具轮不会被拆（一个 tool_use 恰好一个 tool_result）',
        (tester) async {
      // 这一趟的投影是三段交错的：`[原文 1..40][摘要 41..91][原文 92..130]`（和状态 C 同一套
      // 几何：库里只有一条不够远的 2 级 [1..40]、没有对应的 1 级）。
      // 工具轮放在第一段原文里：seq2 是发起调用的 assistant（内容为空、带着 tool_use），
      // seq3 是这一轮结束时又把同一批 tool_calls 重带一遍的 assistant —— 生产里这两条都真实
      // 存在（这就是那条去重规则要处理的重复）。它们必须落在**同一段原文**里：拼装一旦把它
      // 们切开，`_buildApiMessages` 会各自合成一次 tool_result，同一条 tool_use 就被发两遍，
      // 请求非法。
      _setupAgentRegistry(maxContextTokens: 20000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      await repo.materialize(
        sessionId: dbSessionId,
        level: 2,
        startSeq: 1,
        endSeq: 40,
        nodeType: 'summary',
        summaryJson: jsonEncode({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '层级 2 摘要 seq 1..40'},
          ],
        }),
        tokenCost: 700,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: 1,
        coveredMaxSeq: 40,
      );

      const toolCallId = 'call_read_cfg';
      final toolCall = {
        'id': toolCallId,
        'toolName': 'read_file',
        'name': 'read_file',
        'input': {'path': kConfigPath},
        'result': '// connection timeout\nconst timeout = 120;',
      };
      final base = _convLabeled(130, 100);
      final msgs = <Message>[
        base[0], // seq1：用户文本，正文带 `m1:` 标签
        Message(
          id: 'm_tool',
          seq: 2,
          sessionId: 's1',
          role: 'assistant',
          content: '', // 内容为空：它的表示就是那个 tool_use 块
          toolCallsJson: jsonEncode([toolCall]),
          createdAt: 2,
        ),
        Message(
          id: 'm_tool_final',
          seq: 3,
          sessionId: 's1',
          role: 'assistant',
          content: base[2].content, // 保留 `m3:` 标签
          toolCallsJson: jsonEncode([toolCall]), // 重带同一批 tool_calls
          createdAt: 3,
        ),
        ...base.sublist(3),
      ];

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(msgs);
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
      final decoded = (jsonDecode(projected) as List);
      var toolUseCount = 0;
      var toolResultCount = 0;
      var toolUseAt = -1;
      var toolResultAt = -1;
      final roles = <String>[];
      for (var i = 0; i < decoded.length; i++) {
        final m = decoded[i] as Map<String, dynamic>;
        roles.add((m['role'] as String?) ?? '');
        final content = m['content'];
        if (content is! List) continue;
        for (final b in content) {
          if (b is! Map<String, dynamic>) continue;
          if (b['type'] == 'tool_use' && b['id'] == toolCallId) {
            toolUseCount++;
            toolUseAt = i;
          }
          if (b['type'] == 'tool_result' && b['tool_use_id'] == toolCallId) {
            toolResultCount++;
            toolResultAt = i;
          }
        }
      }
      final account = _accountEveryMessage(projected, upToSeq: 130);
      // ignore: avoid_print
      print('  [OBS] 7.1 发出去 ${decoded.length} 条消息；摘要段='
          '${_summarySpansIn(projected).map((s) => '${s.lo}..${s.hi}').join(",")}；'
          'tool_use=$toolUseCount（第 $toolUseAt 条）'
          'tool_result=$toolResultCount（第 $toolResultAt 条）；'
          '角色序列=${roles.join(",")}；'
          '没有任何表示的 seq=${account.missing}；出现两次的 seq=${account.doubled}');

      expect(projected, contains(kSummaryMarker),
          reason: '前提：这一趟确实有摘要段，否则"交错"无从谈起');
      expect(_summarySpansIn(projected), contains((lo: 41, hi: 91)),
          reason: '前提：摘要段夹在两段原文中间（就是交错的那种排法）');
      expect(toolUseCount, 1,
          reason: '同一条工具调用只许发一次 —— 工具轮被切开就会发两遍');
      expect(toolResultCount, 1,
          reason: '同一条工具调用的结果也只许一条');
      expect(toolResultAt, toolUseAt + 1,
          reason: 'tool_result 必须**紧跟**它的 tool_use（紧邻的下一条消息）');
      for (var i = 1; i < roles.length; i++) {
        expect('${roles[i - 1]},${roles[i]}', isNot('user,user'),
            reason: '相邻两条 role:user 会让请求非法（DeepSeek 没有文档说同角色消息会被合并）');
      }
      expect(account.missing, [2],
          reason: '只允许 seq2（内容为空的工具 assistant）没有文本表示 —— 它的表示就是那个 '
              'tool_use 块；别的 seq 一条都不许缺');
      expect(account.doubled, isEmpty,
          reason: '同一段内容不许出现两种表示');
    });

    testWidgets('7.2 某段回落成原文时，容量判定按原文算（不是按那条不会发的摘要算）',
        (tester) async {
      // 几何：容量 4000 ⇒ 阈值 1000；对话 200 条 × 100 raw（seq 1..200）+ 当前这条用户消息。
      // 距离按"它后面还有多少原文"算 ⇒ distance(seq s) = 100 × (200 − s) + 6。
      // 库里预置四条 1 级：
      //   · [1..60] / [61..130] / [131..190]，各实测 1200 —— 起点距离分别是 19906 / 13906 /
      //     6906，都超过阈值 ⇒ 够远（1 级的档按它**最旧那条消息**算），这一趟当摘要发，可丢；
      //   · [191..200]，实测 100 —— 起点距离只有 906 ≤ 1000 ⇒ **还不够远**，这一趟按原文发
      //     （1000 估算 token），它**不可以**被丢（丢了就是内容凭空消失）。
      // 两种口径的差别：按原文算 = 3600 + 1000 + 6 = 4606 > 容量 4000 ⇒ 超容量 ⇒ 丢掉最旧的
      // 那条可丢摘要（丢完 3406，装得下，停手）；按"存下来了、这一趟却不会发"的摘要实测算
      // = 3600 + 100 + 6 = 3706 ≤ 4000 ⇒ 判定为装得下 ⇒ 什么都不丢。
      // （那条更粗的摘要这一趟合不出来：假摘要器给它报 5000，不小于它要替换的 1200 ⇒ 被拒，
      // 所以容量压力不会被"合一条更小的"化解掉，只能看丢弃判定。）
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      Future<void> put(int lo, int hi, int tokens) => repo.materialize(
            sessionId: dbSessionId,
            level: 1,
            startSeq: lo,
            endSeq: hi,
            nodeType: 'summary',
            summaryJson: jsonEncode({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '层级 1 摘要 seq $lo..$hi'},
              ],
            }),
            tokenCost: tokens,
            summaryPromptVersion: 1,
            model: 'test-model',
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
      await put(1, 60, 1200); // 够远、当摘要发、可丢（最旧）
      await put(61, 130, 1200); // 同上
      await put(131, 190, 1200); // 同上
      await put(191, 200, 100); // 还不够远 ⇒ 这一趟发原文，不许丢

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(200, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      // 假摘要器报的尺寸有讲究：1 级报 1200（大于阈值 1000 ⇒ 会触发"再合成一条更粗的"），
      // 2 级报 5000（**不小于**它要替换的那条 ⇒ 合成被拒，容量压力只能靠丢弃解决）——
      // 这样"按哪种口径算容量"就成了唯一能决定丢不丢的东西。
      final summaryProvider = _EchoSummaryProvider(l1Tokens: 1200, l2Tokens: 5000);

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
      final spans = _summarySpansIn(projected);
      final account = _accountEveryMessage(projected, upToSeq: 200);
      // ignore: avoid_print
      print('  [OBS] 7.2 发出去 ${(jsonDecode(projected) as List).length} 条消息；'
          '摘要段=${spans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '没有任何表示的 seq 共 ${account.missing.length} 个'
          '（${account.missing.isEmpty ? "-" : '${account.missing.first}..${account.missing.last}'}）；'
          '出现两次的 seq=${account.doubled}');

      expect(spans, contains((lo: 61, hi: 130)),
          reason: '前提：够远的摘要照常发（它们是这一趟真正发出去的摘要）');
      expect(spans, contains((lo: 131, hi: 190)),
          reason: '同上');
      expect(spans, isNot(contains((lo: 191, hi: 200))),
          reason: '那一条"还不够远"的不许以摘要形式出现（它这一趟发原文）');
      expect(account.missing, [for (var s = 1; s <= 60; s++) s],
          reason: '按原文算 ⇒ 超容量 ⇒ 最旧那条够远的摘要被丢（这正是"按原文算"的可观测'
              '结果）；按摘要实测算就会判定为装得下、什么都不丢，那时这条会红');
      expect(account.doubled, isEmpty, reason: '同一段不许出现两种表示');
      // 反过来，回落成原文的那一段（191..200）一条都不许少 —— 丢内容是不允许的。
      for (final seq in [191, 195, 200]) {
        expect(account.missing.contains(seq), isFalse,
            reason: '回落成原文的那一段必须完整发出去（seq$seq 不许缺）');
      }
      expect(projected, contains('m191:'),
          reason: '那一段落回成原文后，原文真的出现在发出去的内容里');
      expect(projected, contains('continue'), reason: '当前用户消息必须活下来');
    });

    testWidgets('7.4 已经被压过的原文不会再进折卷；库里同等级的摘要跨度互不重叠',
        (tester) async {
      // 这一条钉的是"不会重复压缩同一段内容"：
      //   · 库里预置两条 1 级（覆盖 seq 1..4 与 5..8）；
      //   · 这一趟的可折尾部必须从 seq 9 开始 —— 交给摘要器的每一批都不许碰到 1..8；
      //   · 折完之后库里的同等级摘要（1 级与 1 级、2 级与 2 级）跨度都不许重叠。
      // 判据是"摘要器实际收到的每一批"（真实调用记录），不是从计划里推的。
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
      await put(1, 1, 4, 400);
      await put(1, 5, 8, 400);

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(19, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _RecordingSummaryProvider();

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

      // 摘要器实际收到的每一批覆盖了哪些 seq。
      final foldedSpans = <({int lo, int hi})>[
        for (final call in summaryProvider.foldedCalls)
          if (call.isNotEmpty)
            (lo: call.first.seq ?? 0, hi: call.last.seq ?? 0),
      ];
      final nodes = await repo.queryBySession(dbSessionId);
      final l1Spans = <({int lo, int hi})>[
        for (final n in nodes.where((n) => n.level == 1))
          (lo: n.coveredMinSeq, hi: n.coveredMaxSeq),
      ];
      final l2Spans = <({int lo, int hi})>[
        for (final n in nodes.where((n) => n.level == 2))
          (lo: n.coveredMinSeq, hi: n.coveredMaxSeq),
      ];
      ({int lo, int hi})? overlapping(
          List<({int lo, int hi})> a, List<({int lo, int hi})> b) {
        for (final x in a) {
          for (final y in b) {
            if (!(x.hi < y.lo || y.hi < x.lo)) return (lo: x.lo, hi: x.hi);
          }
        }
        return null;
      }

      /// 一组跨度里有没有两条互相重叠（只比不同的两条，不拿自己跟自己比）。
      ({int lo, int hi})? pairOverlap(List<({int lo, int hi})> a) {
        for (var i = 0; i < a.length; i++) {
          for (var j = i + 1; j < a.length; j++) {
            if (!(a[i].hi < a[j].lo || a[j].hi < a[i].lo)) return a[i];
          }
        }
        return null;
      }

      final presets = <({int lo, int hi})>[(lo: 1, hi: 4), (lo: 5, hi: 8)];
      final foldHitPreset = overlapping(foldedSpans, presets);
      // 这一趟**新落的** 1 级（把预置那两条自己排除掉）—— 它们不许碰到预置段落。
      final newL1 = [
        for (final s in l1Spans)
          if (!presets.any((p) => p.lo == s.lo && p.hi == s.hi)) s
      ];
      final newL1HitPreset = overlapping(newL1, presets);
      // ignore: avoid_print
      print('  [OBS] 7.4 摘要器收到的批次=${foldedSpans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '库里新落的 1 级=${newL1.map((s) => '${s.lo}..${s.hi}').join(",")}'
          '（另有预置的 1..4、5..8）；库里的 2 级=${l2Spans.map((s) => '${s.lo}..${s.hi}').join(",")}；'
          '折卷批次碰到预置段落=$foldHitPreset；'
          '新落的 1 级碰到预置段落=$newL1HitPreset；'
          '同级 1 级互相重叠=${pairOverlap(l1Spans)}；'
          '同级 2 级互相重叠=${pairOverlap(l2Spans)}');

      expect(foldedSpans, isNotEmpty,
          reason: '前提：这一趟确实折了（否则什么都没验证到）');
      expect(foldHitPreset, isNull,
          reason: '已经被压过的原文（预置的 1..4 / 5..8）不许再进折卷 —— 尾部必须从 seq 9 起');
      expect(pairOverlap(foldedSpans), isNull,
          reason: '同一趟里交给摘要器的各批之间不许重叠');
      expect(newL1HitPreset, isNull,
          reason: '库里新落的 1 级不许和已有的 1 级重叠（这就是"同一段被压两次"）');
      expect(pairOverlap(l1Spans), isNull,
          reason: '库里同等级的 1 级之间不许重叠');
      expect(pairOverlap(l2Spans), isNull,
          reason: '库里同等级的 2 级之间不许重叠');
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

    testWidgets('⑪.3 二级不比那几条一级短 ⇒ 取压缩前那一侧（拼起来当正文，不采用模型那条）', (tester) async {
      // l1Tokens=20（< 每一批的 raw ⇒ 每条一级都是**有效**压缩，压不短那一支不参与）
      // 而 l2Tokens=150（>= 它要替换的那几条一级之和）。
      // **旧规则**：这条二级"无效" ⇒ 拒绝它，并把最旧的一条一级从投影里省略掉。
      // **新规则（用户 2026-10-05：取小者、没有特殊情况）**：压缩前那一侧赢 ⇒ 二级的
      // 正文就是那几条一级文本按原顺序拼接，照常落盘；模型给的那条正文一个字都不用。
      // 断言不许放松：仍然要断言"模型那条更长的正文没进投影"，并且**新增**断言
      // "那条二级确实以拼接后的正文进了投影"（旧写法只断言了前者，后者正是新行为）。
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
          reason: '取小者取中了压缩前那一侧 ⇒ 模型给的那条更长的二级正文一个字都不许进投影');
      expect(projected, contains(kLevel2SummaryMarker),
          reason: '新行为：那条二级照样进投影，只是正文换成了压缩前那一侧的拼接');
      expect(projected, contains('L1 summary ('),
          reason: '二级的正文就是那几条一级文本按原顺序拼接（一级只在这里出现，不再单独发）');
      expect(projected, contains('## 更早上下文'),
          reason: '有效的一级/二级摘要都还在投影里');
      expect(projected, contains('continue'),
          reason: 'the current user message must survive');
    });

    testWidgets('⑪.3 压不短 ⇒ 那一段按原文发出去（不再折半、不再省略）', (tester) async {
      // l1Tokens=150（>= 每一批的 raw）⇒ 每一批的摘要都不比它替换的内容短。
      // **旧规则**：`_resolveOpenLevel1` 折半递归、把每个原子批 OMIT 掉（数据留在盘上），
      // 于是投影里那一整段内容一条表示都没有。
      // **新规则（用户 2026-10-05：取小者、没有特殊情况）**：压缩前那一侧赢 ⇒ 那一级的
      // 内容就是这批原文本身，按原文渲染路径发出去，工具块与思考块都保留。没有折半。
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
      // **改后（依据用户 2026-10-05「取小者，没有特殊情况」）**：那段原文必须真的发出去。
      expect(projected, contains('A' * 100),
          reason: '压不短 ⇒ 取压缩前那一侧：那段原文必须按原文发出去，一条都不许丢'
              '（旧规则下这一整段被省略，投影里一条都没有）');
      expect(projected, isNot(contains('## 更早上下文')),
          reason: '这一趟没有真的压出摘要（每一批都压不短）⇒ 投影里不该出现摘要标记');
      // 折半递归已经删掉：一次调用至少覆盖一条消息，所以调用数不可能超过消息条数。
      // 旧规则下折半会把这个数顶到 36（12 批 × 3 次），这里 <= 24 才说明折半确实没了。
      expect(summaryProvider.summarizeCalls, lessThanOrEqualTo(24),
          reason: '不许再有折半递归：调用次数不能超过消息条数（一条一次是上界）');
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
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
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
      // 这一场没有"每段恰好一种表示"的通用守卫：这条用例用的假摘要器给的是一句固定文本
      // （没有 `seq a..b` 标签），读不出它盖住了哪一段。退一步查能查的那半 —— 投影里
      // **逐字发出去的原文**必须正好是尾部那几条（seq 12..15）：远端 1..11 被那条 1 级
      // 摘要接走，既不许也逐字再发一遍，也不许少发后面几条。
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      // ignore: avoid_print
      print('  [OBS] 6.1 逐字发出去的 seq=$rawSeqs（远端 1..11 该由那条 1 级摘要接走）');
      expect(rawSeqs, {12, 13, 14, 15},
          reason: '逐字发的必须正好是尾部那四条 —— 少了说明有内容没发出去，'
              '多了说明被摘要盖住的原文又发了一遍');
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
      final msgRepo = FakeMessageRepository(_convLabeled(10, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _EchoSummaryProvider(l1Tokens: 1, l2Tokens: 300);

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
      // 投影口径（2026-09-26 的裁定）：这条 2 级盖住的整段（seq 1..8）离末尾还不到一个
      // 2T ⇒ 这一趟不进投影，那一段照原文发。旧断言写的是"合成出来的更粗摘要必须真的
      // 进入发给模型的内容"，按新口径改写成"合成照做、但还没轮到它上场"。
      expect(projected, isNot(contains(kLevel2SummaryMarker)),
          reason: '这条 2 级盖住的整段还没落到最远档 ⇒ 这一趟不进投影');
      expect((jsonDecode(projected) as List).length, 11,
          reason: '这一趟还没轮到 2 级上场 ⇒ seq 1..10 的原文加当前这条用户消息'
              '共 11 条必须一条不少地照发');
      // 通用守卫：seq 1..10 每条恰好一种表示（这一趟它们全该以原文出现 —— 库里那两条 1 级
      // 自己都还不够远，那条刚合出来的 2 级也还不够远）。
      _expectEveryMessageExactlyOnce(projected, upToSeq: 10);
      expect(projected, contains('continue'),
          reason: '当前用户消息必须活下来');
    });

    testWidgets('参考上下文 · 折叠真的把上一条摘要传给了摘要模型（接线判据）',
        (tester) async {
      // 接线判据：挑选函数写对、但 main.dart 一处都不接线（一律传空）时，这条必红。
      // 几何：容量 2000 ⇒ 阈值 500；seq 1..10 各 100 raw；库里预置一条覆盖 seq 1..4 的
      // 上一轮一级摘要（已冻结、已落盘）⇒ 这一趟要折的是尾部（累加首次超过 500 的那一段），
      // 它的参考只可能是那条 1..4 的摘要。
      _setupAgentRegistry(maxContextTokens: 2000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final repo = _FakeSummaryNodeRepository();
      const dbSessionId = 's1';
      const presetText = '上一轮压出来的 L1 摘要 seq 1..4';
      await repo.materialize(
        sessionId: dbSessionId,
        level: 1,
        startSeq: 1,
        endSeq: 4,
        nodeType: 'summary',
        summaryJson: jsonEncode({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': presetText},
          ],
        }),
        tokenCost: 60,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: 1,
        coveredMaxSeq: 4,
      );

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(10, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = _EchoSummaryProvider(l1Tokens: 1, l2Tokens: 300);

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

      final calls = summaryProvider.referencesPerCall;
      // ignore: avoid_print
      print('  [OBS] 参考上下文 · 折叠调用 ${calls.length} 次，每次参考='
          '${calls.map((r) => r.isEmpty ? '（空）' : r.map((x) => 'lvl${x.level}[${x.coveredMinSeq},${x.coveredMaxSeq}]').join('+')).join(' / ')}');
      final withReference = calls.where((r) => r.isNotEmpty).toList();
      expect(withReference, isNotEmpty,
          reason: '这一趟折的是尾部（seq 1..4 已经压过并落盘）⇒ 摘要请求必须带参考；'
              '一次都没带说明 main.dart 没把参考接线到 provider');
      expect(withReference.first.map((r) => r.text), contains(presetText),
          reason: '参考必须是库里那条覆盖 seq 1..4 的上一轮摘要的正文');
      expect(withReference.first.length, 1,
          reason: '只有一个候选 ⇒ "最近的一条一级"与"层级最高那条"是同一条，'
              '按覆盖范围去重后只该留一条');
    });

    testWidgets('压缩提示 · 发送前这条路径：卡住摘要期间对话视图出现提示，放行后消失',
        (tester) async {
      // 容量 4000 ⇒ 阈值 1000；15 条 × 100 raw = 1500 > 1000 ⇒ 这次发送要压。
      // 摘要生成被卡住 ⇒ 压缩正在进行，这段时间界面上必须能看到提示；而且此时请求
      // **还没发给模型**（FakeSidecar 什么都没收到）—— 说明用户等的是压缩，不是模型。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _GatedSummaryProvider()..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 发送前 banner=${banner.evaluate().length} [expect 0]');
      expect(banner, findsNothing, reason: '还没发送，不该有任何压缩提示');

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 压缩卡住期间 banner=${banner.evaluate().length} '
          'summarizeCalls=${provider.summarizeCalls} '
          '已发给模型=${sidecar.lastMessagesJson != null} '
          '文案="${_bannerTexts(tester, banner)}" [expect banner=1]');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '这次发送必须真的走到生成摘要这一步，这条用例才不是空跑');
      expect(sidecar.lastMessagesJson, isNull,
          reason: '压缩还没结束，请求不该已经发出去 —— 用户等的是压缩');
      expect(banner, findsOneWidget, reason: '压缩正在进行，对话视图必须出现提示');

      provider.gate!.complete(SummaryResult(text: 'gated L1', tokens: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 放行之后 banner=${banner.evaluate().length} '
          '已发给模型=${sidecar.lastMessagesJson != null} [expect 0 / true]');
      expect(banner, findsNothing, reason: '压缩结束后提示必须消失');
      expect(sidecar.lastMessagesJson, isNotNull,
          reason: '压缩结束后这次发送必须继续走下去（请求真的发出去）');
    });

    testWidgets('压缩提示 · 没触发压缩的普通发送：整场都不出现提示', (tester) async {
      // 容量 4000 ⇒ 阈值 1000；历史只有 4 条 × 100 raw = 400，远低于阈值 ⇒ 不压。
      // **它的正向对照是同文件的「压缩提示 · 发送前这条路径」与 8.2②**：那两条用同一类
      // 几何断言"该压的那一轮提示确实出现"。本条只钉"不压 ⇒ 不亮"这一侧，所以单看它
      // 自己无法区分"提示坏了"与"确实不该亮" —— 判据的可失败性由那两条对照 + 5.1 的
      // 变异（把提示改成从"正在发送"推断 ⇒ 本条变红）共同保证。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(4, 100));
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

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 未触发压缩的发送：summarizeCalls=${provider.summarizeCalls} '
          'banner=${banner.evaluate().length} 已发给模型=${sidecar.lastMessagesJson != null} '
          '[expect 0 / 0 / true]');
      expect(provider.summarizeCalls, 0,
          reason: '前提：这一轮低于阈值，没有触发压缩');
      expect(sidecar.lastMessagesJson, isNotNull,
          reason: '前提：这一轮真的发出去了（否则"没提示"是空跑）');
      expect(banner, findsNothing,
          reason: '没触发压缩的普通发送不许出现压缩提示');
    });

    testWidgets('压缩提示 · 真实上下文视图：压缩期间这一屏仍是上一次发出的内容',
        (tester) async {
      // 发送前这条路径读的是**界面上那串消息**（`_chatItemsToMessages`），不是库里的
      // 全量历史 —— 所以这里靠两轮长回复把界面上的历史撑过阈值，而不是往库里塞消息
      // （往库里塞只对后台那条路径有效，background_fold_test 用的是那个办法）。
      // 容量 4000 ⇒ 阈值 1000。逐轮估算：400（预置 4 条）→ 第 1 轮发出时 ≈406、
      // 第 2 轮 ≈915（都低于阈值，不压）→ 第 3 轮 ≈1425（超阈值 ⇒ 要压）。
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(4, 100));
      // 注意：不要在这里预置事件 —— FakeSidecar 每次 sendMessage 只消费到第一个 done，
      // 预置的那一份会被第 1 轮吃掉，后面几轮的回复长度就跟预期对不上了（实测踩过）。
      final sidecar = FakeSidecar();
      final provider = _GatedSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      Future<void> send(String text, {String reply = 'Reply'}) async {
        sidecar
          ..queueChunk(reply)
          ..queueDone();
        await tester.enterText(find.byType(TextField), text);
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
      }

      // 第 1、2 轮：都低于阈值 ⇒ 不压，只把界面上那串历史撑长（每轮一条 2000 字的回复
      // ≈ 504 raw）。第 2 轮结束后，"上一次实际发出的内容"就是这一份。
      await send('first', reply: 'R' * 2000);
      await send('grow', reply: 'R' * 2000);
      // ignore: avoid_print
      print('  [OBS] 前两轮之后：summarizeCalls=${provider.summarizeCalls} '
          '已发给模型=${sidecar.lastMessagesJson != null} '
          'banner=${banner.evaluate().length} [expect 0 / true / 0]');
      expect(provider.summarizeCalls, 0,
          reason: '前提：前两轮都低于阈值，不该触发压缩');

      // 第 3 轮：界面上历史已经超过阈值 ⇒ 发送前要压；卡住摘要让它停在"压缩中"。
      final histRaw = ContextEstimator.estimateConversation(msgRepo.messages);
      // ignore: avoid_print
      print('  [OBS] 第 3 轮之前：库里 ${msgRepo.messages.length} 条、估算 raw=$histRaw '
          '（阈值 1000，超了才会压）；每条"字符数/估算 raw"='
          '${msgRepo.messages.map((m) => '${m.content.length}/${ContextEstimator.estimateMessage(m)}').join(' ')}');
      provider.gate = Completer<SummaryResult>();
      await send('grow2', reply: 'Reply3');

      // 切到真实上下文视图（压缩还在进行）。
      await tester.tap(find.text('真实上下文'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 压缩期间真实上下文视图：banner=${banner.evaluate().length} '
          'summarizeCalls=${provider.summarizeCalls} '
          '有"grow2"=${find.textContaining('grow2').evaluate().length} '
          '有摘要标记=${find.textContaining('更早上下文').evaluate().length} '
          '文案="${_bannerTexts(tester, banner)}"');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '这次发送必须真的走到生成摘要这一步');
      expect(banner, findsOneWidget, reason: '压缩正在进行，这一屏顶部必须有提示');
      expect(find.textContaining('上一次实际发出'), findsWidgets,
          reason: '提示要写明这一屏显示的是上一次实际发出的内容');
      expect(find.textContaining('grow2'), findsNothing,
          reason: '这次还没发出去，这一屏不许出现还没发出去的内容');
      expect(find.textContaining('更早上下文'), findsNothing,
          reason: '压缩还没结束，新压出来的摘要还没发出去，不许出现在这一屏');

      // 放行：压缩结束、这一轮真的发出去 ⇒ 新投影（带摘要标记）才出现在这一屏。
      provider.gate!.complete(SummaryResult(text: 'gated L1', tokens: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 放行之后：banner=${banner.evaluate().length} '
          '已发给模型=${sidecar.lastMessagesJson != null} '
          '有摘要标记=${find.textContaining('更早上下文').evaluate().length} '
          '[expect 0 / true / >=1]');
      expect(banner, findsNothing, reason: '压缩结束后提示必须消失');
      expect(sidecar.lastMessagesJson, isNotNull,
          reason: '放行后这一轮必须真的发出去');
      expect(find.textContaining('更早上下文'), findsWidgets,
          reason: '压缩结果要在下一次发送时才出现在这一屏');
    });

    testWidgets('压缩提示 · 真实上下文视图：还没有任何快照时，提示与占位并存',
        (tester) async {
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      // 15 条 × 100 raw = 1500 > 阈值 1000 ⇒ 第一条消息的发送就要压。
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _GatedSummaryProvider()..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('真实上下文'));
      await tester.pump();
      await tester.pump();

      final placeholder = find.text('尚无捕获的上下文快照');
      // ignore: avoid_print
      print('  [OBS] 首次发送压缩期间：banner=${banner.evaluate().length} '
          '占位=${placeholder.evaluate().length} '
          'summarizeCalls=${provider.summarizeCalls} [expect 1 / 1]');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '这次发送必须真的走到生成摘要这一步');
      expect(banner, findsOneWidget, reason: '压缩进行中，提示必须出现');
      expect(placeholder, findsOneWidget,
          reason: '还没有发出过任何请求 ⇒ 占位文字仍在，提示与它并存');
    });

    testWidgets('压缩提示 · 挑选分段主题：冷缓存时显示这一步，选完换成生成摘要',
        (tester) async {
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      // 分段选择卡住；摘要也卡住 —— 好让"选完换成生成摘要"这一步停住看清楚。
      final seamSelector = _GatedSeamSelector()..gate = Completer<void>();
      final provider = _GatedSummaryProvider()..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
        seamSelector: seamSelector,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 分段选择卡住期间：banner=${banner.evaluate().length} '
          'ensures=${seamSelector.ensures} summarizeCalls=${provider.summarizeCalls} '
          '文案="${_bannerTexts(tester, banner)}"');
      expect(banner, findsOneWidget, reason: '压缩正在进行，必须有提示');
      expect(find.textContaining('挑选分段主题'), findsWidgets,
          reason: '冷缓存时这一步真的要发一次模型请求，界面必须显示它');
      expect(provider.summarizeCalls, 0,
          reason: '分段还没选完，摘要生成不该已经开始');

      // 放行分段选择 ⇒ 状态必须换成"正在生成第 k 段摘要"，不是同一句话。
      seamSelector.gate!.complete();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 分段选完之后：banner=${banner.evaluate().length} '
          'summarizeCalls=${provider.summarizeCalls} 文案="${_bannerTexts(tester, banner)}"');
      expect(find.textContaining('挑选分段主题'), findsNothing);
      expect(find.textContaining('正在生成第 1 段摘要'), findsWidgets,
          reason: '选完分段就进入生成摘要这一步');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1));

      // 放行摘要生成 ⇒ 这一趟结束，提示消失。
      provider.gate!.complete(SummaryResult(text: 'gated L1', tokens: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 全部放行之后：banner=${banner.evaluate().length} [expect 0]');
      expect(banner, findsNothing);
    });

    testWidgets('压缩提示 · 挑选分段主题：热缓存时不亮（不闪）', (tester) async {
      _setupAgentRegistry(maxContextTokens: 4000);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final seamSelector = _WarmSeamSelector();
      final provider = _GatedSummaryProvider()..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
        seamSelector: seamSelector,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      // ignore: avoid_print
      print('  [OBS] 热缓存期间：ensures=${seamSelector.ensures} '
          '文案="${_bannerTexts(tester, banner)}" [expect 有"生成第 1 段摘要"、没有"挑选分段主题"]');
      expect(seamSelector.ensures, 1,
          reason: 'ensure 照常被调用（它自己会因为热缓存直接返回）');
      expect(find.textContaining('挑选分段主题'), findsNothing,
          reason: '热缓存不会发请求 ⇒ 这一步不许亮（否则每次发送都闪一下）');
      expect(find.textContaining('正在生成第 1 段摘要'), findsWidgets,
          reason: '真正在跑的是生成摘要，提示要显示这个');
    });

    testWidgets('8.1 攒过阈值但这趟占比不到等待阈值 ⇒ 不等：零摘要调用、那段按原文发、界面无提示',
        (tester) async {
      // 容量 4000 ⇒ 压缩阈值 1000（4000 × 25%）、等待上界 3000（4000 × 75%）。
      // 这一趟"不压就发"的估算总量 = 15 条 × 100 = 1500 ⇒ 占比 37.8%：
      // 已经超过压缩阈值（按钉死的规则，压缩动作本身照做），但远不到等待上界
      // ⇒ 这一轮不该为它等待，也不该为此发任何一次摘要调用。
      _setupAgentRegistry(maxContextTokens: 4000, waitPercent: 75);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      // 摘要器**挂住**：新规则下这一轮根本不该调用它（所以挂住不影响这一轮），
      // 旧行为下它会被调用并把这一轮卡在发送前 —— 那样连"请求已发出"这条都会红。
      final provider = _GatedSummaryProvider()
        ..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      final rawBefore = ContextEstimator.estimateConversation(msgRepo.messages);
      // ignore: avoid_print
      print('  [OBS] 8.1 不压就发的估算总量≈$rawBefore（容量 4000 ⇒ 压缩阈值 1000、'
          '等待上界 3000，占比 '
          '${(rawBefore * 100 / 4000).toStringAsFixed(1)}%）；'
          '摘要调用次数=${provider.summarizeCalls}；'
          '逐字出现的 seq=$rawSeqs；界面提示节点数=${banner.evaluate().length}；'
          '已发给模型=${sidecar.lastMessagesJson != null}');
      expect(sidecar.lastMessagesJson, isNotEmpty,
          reason: '前提：这一轮必须真的发出去了，否则"没提示"是空跑');
      expect(provider.summarizeCalls, 0,
          reason: '占比约 37.8% 不到等待上界 3000 ⇒ 这一轮一次摘要调用都不许发');
      expect(rawSeqs, containsAll(<int>[for (var i = 1; i <= 11; i++) i]),
          reason: '那批已经攒过压缩阈值、但这一轮不等的内容（seq 1..11）要按原文发');
      expect(banner, findsNothing,
          reason: '没有在为压缩等待 ⇒ 界面上不该出现压缩提示');
      // 通用守卫（审查要求的补强）：新路径要重写一份投影拼装，漏发一整段这种
      // 缺陷光靠上面四条查不出来 —— 这一条钉"每段内容恰好一种表示"。
      _expectEveryMessageExactlyOnce(projected, upToSeq: 15);
      // 放行挂住的摘要器，别把未完成的异步链留给下一个用例。
      provider.gate!.complete(SummaryResult(text: '不该被用到', tokens: 1));
      await tester.pump();
    });

    testWidgets('8.2② 这趟占比超过等待上界 ⇒ 照旧等待：真的压、提示在、请求等它压完才发',
        (tester) async {
      // 容量 4000 ⇒ 压缩阈值 1000、等待上界 3000；历史 40 条 × 100 = 4000 raw
      // ⇒ 不压就发的占比 100% > 75% ⇒ 这一轮要等。
      _setupAgentRegistry(maxContextTokens: 4000, waitPercent: 75);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(40, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _GatedSummaryProvider()..gate = Completer<SummaryResult>();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 8.2② 占比 100% > 75% ⇒ 该等：摘要调用次数=${provider.summarizeCalls}；'
          '已发给模型=${sidecar.lastMessagesJson != null}；'
          '界面提示节点数=${banner.evaluate().length}（压缩中）');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '占比 100% 超过等待上界 ⇒ 这一轮必须真的压');
      expect(sidecar.lastMessagesJson, isNull,
          reason: '压缩还没结束，请求不该已经发出去');
      expect(banner, findsOneWidget, reason: '这一轮在为压缩等待 ⇒ 提示必须在');

      provider.gate!.complete(SummaryResult(text: 'L1', tokens: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 8.2② 放行之后：已发给模型=${sidecar.lastMessagesJson != null}；'
          '界面提示节点数=${banner.evaluate().length}');
      expect(sidecar.lastMessagesJson, isNotNull,
          reason: '压完这一轮必须真的发出去');
      expect(banner, findsNothing, reason: '压缩结束提示要消失');
    });

    testWidgets('8.2③ 占比超过等待上界 ⇒ 等完照发，且一条内容都不许丢', (tester) async {
      // 容量 4000 ⇒ 阈值 1000、等待上界 3000。历史 40 条 × 100 = 4000 raw（占比 100% ⇒ 该等）。
      // 摘要实测 200（远端每批约 1100 raw ⇒ 摘要比它小、合法；2 级给 5000 让它被拒）。
      // 这一条钉的是"等"不等于"丢"：等完之后投影是照既有规则拼的，一条内容都不许少。
      _setupAgentRegistry(maxContextTokens: 4000, waitPercent: 75);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(40, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _EchoSummaryProvider(l1Tokens: 200, l2Tokens: 5000);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final spans = _summarySpansIn(projected);
      final covered = <int>{};
      for (final s in spans) {
        for (var i = s.lo; i <= s.hi; i++) {
          covered.add(i);
        }
      }
      final tailRaw = ContextEstimator.estimateConversation(
          msgRepo.messages.where((m) => !covered.contains(m.seq ?? 0)).toList());
      final summaryTokens = spans.isEmpty ? 0 : 200;
      final projectedTotal = summaryTokens + tailRaw;
      // ignore: avoid_print
      print('  [OBS] 8.2③ 摘要调用次数=${provider.summarizeCalls}；摘要覆盖=$spans；'
          '尾部原文估算=$tailRaw ⇒ 压完投影估算≈$projectedTotal'
          '（等待上界 3000、容量 4000）；已发给模型=${sidecar.lastMessagesJson != null}');
      expect(sidecar.lastMessagesJson, isNotEmpty, reason: '这一轮必须真的发出去');
      expect(provider.summarizeCalls, greaterThanOrEqualTo(1),
          reason: '前提：占比 100% 超过等待上界，这一轮确实压了');
      expect(projectedTotal, lessThan(3000),
          reason: '几何前提：压完降到等待上界 3000 以下 —— 这正是"该等"要达到的效果');
      // 等不等于丢：这一轮不许有任何一段内容凭空消失。
      _expectEveryMessageExactlyOnce(projected, upToSeq: 40);
    });

    testWidgets('8.2④ 压完仍超过容量 ⇒ 按既有规则省略最旧，请求照发（不死等）',
        (tester) async {
      // 容量 2000 ⇒ 阈值 500、等待上界 1500。历史 30 条 × 100 = 3000 raw（占比 150%）。
      // 摘要按 400 实测（比它替换的每批约 1100 raw 小 ⇒ 合法），收拢成一条 2 级按 1900 实测
      // （比它替换的 6 条 1 级合计小 ⇒ 合法）⇒ 压完投影 ≈ 1900 + 尾部 ≈ 2600 > 容量 2000
      // ⇒ 必须有内容被留出这一轮投影，但请求必须照发（不许死等）。
      _setupAgentRegistry(maxContextTokens: 2000, waitPercent: 75);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(30, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final provider = _EchoSummaryProvider(l1Tokens: 400, l2Tokens: 1900);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final projected = sidecar.lastMessagesJson ?? '';
      final rawSeqs = RegExp(r'm(\d+):')
          .allMatches(projected)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      final covered = <int>{};
      for (final s in _summarySpansIn(projected)) {
        for (var i = s.lo; i <= s.hi; i++) {
          covered.add(i);
        }
      }
      final represented = <int>{...rawSeqs, ...covered};
      // ignore: avoid_print
      print('  [OBS] 8.2④ 逐字出现的 seq=$rawSeqs；摘要覆盖=$covered；'
          '这一轮有表示的 seq=${represented.length} 个（历史 30 条）；'
          '已发给模型=${sidecar.lastMessagesJson != null}');
      expect(sidecar.lastMessagesJson, isNotEmpty,
          reason: '不许死等：压完仍超容量也要照发');
      expect(represented.contains(1), isFalse,
          reason: '超容量 ⇒ 最旧那段被留出这一轮投影（数据仍在磁盘）');
      expect(represented.length, lessThan(30),
          reason: '超容量 ⇒ 必须有内容被留出这一轮投影，'
              '不许把 30 条原文一条不少地全塞进去');
    });

    testWidgets('8.12 不等的那一轮：连分段选择请求都不发', (tester) async {
      // 占比 37.8% < 75% ⇒ 这一轮不等。分叉点必须在 `_prepareSeamChooser` **之前**：
      // 生产环境的分段选择器自己要发一次模型请求（冷缓存时），放在它后面就等于
      // 没做到"不等" —— 而只看"假摘要器零调用"的用例查不出这件事。
      _setupAgentRegistry(maxContextTokens: 4000, waitPercent: 75);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final banner = find.byKey(CompactionStatusBanner.bannerKey);
      final sessionRepo = FakeSessionRepository(testSessions(1));
      final msgRepo = FakeMessageRepository(_convLabeled(15, 100));
      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      // 计数用的分段选择器：它自己的 ensure 被调用几次，这里数得出来（热缓存语义
      // 让它不会挂住，也正好符合"真被调用了才会计数"）。
      final seamSelector = _WarmSeamSelector();
      final provider = _EchoSummaryProvider();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: provider,
        seamSelector: seamSelector,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'continue');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 8.12 不等的那一轮：分段选择 ensure 次数=${seamSelector.ensures}；'
          '摘要调用次数=${provider.summarizeCalls}；'
          '界面提示节点数=${banner.evaluate().length}；'
          '已发给模型=${sidecar.lastMessagesJson != null} [expect 0 / 0 / 0 / true]');
      expect(sidecar.lastMessagesJson, isNotEmpty,
          reason: '前提：这一轮照发（不等）');
      expect(seamSelector.ensures, 0,
          reason: '不等的那一轮连分段选择都不该发起 —— 分叉点必须在它之前');
      expect(provider.summarizeCalls, 0, reason: '一个摘要调用都不发');
      expect(banner, findsNothing, reason: '没有在为压缩等待 ⇒ 不该有提示');
    });
  });
}

/// 读出提示里的文案（现场证据用）。提示还不存在时返回空串。
String _bannerTexts(WidgetTester tester, Finder banner) {
  if (banner.evaluate().isEmpty) return '';
  return tester
      .widgetList<Text>(find.descendant(of: banner, matching: find.byType(Text)))
      .map((t) => t.data)
      .whereType<String>()
      .join(' | ');
}

/// 摘要生成能被卡住的假摘要器：卡住期间压缩仍在进行，用来观察界面提示。
class _GatedSummaryProvider implements SummaryProvider {
  Completer<SummaryResult>? gate;
  int summarizeCalls = 0;
  int summarizeTextCalls = 0;

  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
  }) {
    summarizeCalls++;
    final g = gate;
    if (g != null) return g.future;
    return Future.value(SummaryResult(text: 'GATED L1', tokens: 1));
  }

  @override
  Future<SummaryResult> summarizeText({
    required String text,
    required AgentTypeConfig config,
  }) {
    summarizeTextCalls++;
    final g = gate;
    if (g != null) return g.future;
    return Future.value(SummaryResult(text: 'GATED L2', tokens: 1));
  }
}

/// 分段选择能被卡住的假选择器：卡住期间"正在挑选分段主题"这一步应该显示在界面上。
/// `memoizedSeams` 在 [ensure] 跑完之前返回 null（= 冷缓存，符合接口约定：
/// "null when ensure has never run for this exact key"）。
class _GatedSeamSelector implements SeamSelector {
  Completer<void>? gate;
  int ensures = 0;
  bool _done = false;

  @override
  Future<void> ensure({
    required List<Message> far,
    required int k,
    required AgentTypeConfig config,
  }) async {
    ensures++;
    final g = gate;
    if (g != null) await g.future;
    _done = true;
  }

  @override
  List<int>? memoizedSeams({required List<Message> far, required int k}) =>
      _done ? const [] : null;

  @override
  int get llmCallCount => 0;
}

/// 已经跑过这个键的假选择器（`memoizedSeams` 返回非空 = 热缓存）：这时
/// `ensure` 不会发请求，界面不该为这一步亮提示。
class _WarmSeamSelector implements SeamSelector {
  int ensures = 0;

  @override
  Future<void> ensure({
    required List<Message> far,
    required int k,
    required AgentTypeConfig config,
  }) async {
    ensures++;
  }

  @override
  List<int>? memoizedSeams({required List<Message> far, required int k}) =>
      const [];

  @override
  int get llmCallCount => 0;
}

/// A SummaryProvider that always throws (simulating done!=0 or empty-content
/// summarization) — used to pin the R1-5 "never a silent placeholder; fall back to
/// the full verbatim conversation" guarantee on the INLINE _callModel path.
class _ThrowingSummaryProvider implements SummaryProvider {
  @override
  Future<SummaryResult> summarize({
    required List<Message> folded,
    required AgentTypeConfig config,
    List<SummaryReference> reference = const [],
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
