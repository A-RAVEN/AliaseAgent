@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/ui/chat_area.dart';

import '../test/integration/helpers/real_context_fixture.dart';
import 'live_observability.dart';

/// A-2 — live real-context compression QUALITY test, in the COMPLIANT window
/// real-model form (`integration_test/` + `-d windows`), per Docs/TESTING.md
/// §2.4. It replaces the deleted headless `test/integration/compaction_fidelity_live_test.dart`.
///
/// WHAT IT DOES: pump the REAL app (`AppShell(configLoader: ...)`) against its
/// OWN temp DB, feeding it the A-1 config-refactor fixture (load-bearing
/// re-execution keys = `/Users/acme/src/config.dart` + decision `timeout 120 →
/// 30` in the OLDEST, foldable messages). A small injected `maxContextTokens`
/// forces the real fold: `_resolveSummaries` summarizes the far span with the
/// REAL model (`ModelSummaryProvider` over the real `/v1/messages`) and
/// materializes the summary text into `summary_nodes.summary_json`
/// (main.dart:1576-1587). The test then READS the real summary text back from
/// its own temp DB (`SummaryNodeRepository.queryBySession`) and asserts it
/// preserves the re-execution keys — the "摘要措辞质量" signal the user asked for.
///
/// LIVE (needs a real apiKey + network). Skipped only when: (a) no real
/// provider key/model is configured (offline, test kept), or (b) the model
/// endpoint ERRORS (`Error:`-prefix reply — environmental, prevents a quality
/// verdict). A summary that RETURNS but does NOT preserve the keys — or an empty
/// `summary_nodes` (bloat-omit / fold-error) — is a REAL QUALITY failure and
/// FAILS (never fabricated into a skip/pass).
///
/// Honest calibration (docs/context-compression-reference.md:165, design.md:87):
/// this is a LITERAL key-presence rod — STRONGER than the design's lossy
/// "semantic retention" contract — so a compliant-but-largely-lossy summarizer
/// may false-fail; it is a supplementary signal over the P1 behavior-continuity
/// assertion (③c), NOT the design guarantee, to be calibrated across benchmarks.
void main() {
  // The model context allowance (`max_context_tokens`) is SELF-TUNED below from
  // the fixture's real raw-token total. A FIXED small allowance (e.g. 300) makes
  // the threshold tiny, which fragments the far span into dozens of tiny
  // summaries, each its own summarize call — measured at 33+ calls and still
  // running, i.e. the fold never finishes → the window appeared hung.
  // Self-tuning to ~2 large batches makes each a REAL compression target.

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // Load-bearing (design notes): `sqfliteFfiInit()` does NOT set the global
  // `databaseFactory`; integration_test runs the TEST's own main() (lib/main.dart:46
  // does not execute), so the global is unset and `openAt`'s openDatabase would
  // throw StateError('databaseFactory not initialized'). All DB live-test
  // precedents (real_api_test.dart) set this line explicitly.
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_compact_');
    await DatabaseService.openAt(tempDir.path);
    // Remove every PNG left by a prior run BEFORE anything can be captured, so a
    // stale file can never be read as this run's screenshot. Load-bearing for the
    // skip path: `_resolveLiveConfig()` returning null bails out BEFORE the
    // try/finally that captures, so neither delete-on-fail nor capture runs —
    // without this the previous run's PNG would sit there looking like a result.
    clearLiveVisualDir();
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows file lock — OS will clean temp dir.
      }
    }
  });

  testWidgets('real summarizer preserves re-execution keys in summary_nodes (window live)',
      (tester) async {
    // ------------------------------------------------------------------
    // Config gate (offline → skip). Resolve the real provider/model/apiKey.
    final cfg = _resolveLiveConfig();
    if (cfg == null) {
      markTestSkipped('no real provider apiKey/model (offline): A-2 needs a live model '
          'to judge summary quality — skipped, test kept for networked runs.');
      return;
    }

    // ------------------------------------------------------------------
    // Seed the session + A-1 fixture FIRST, so we self-tune the model context
    // allowance from
    // the TRUE raw-token total, and `sessions.first` (list() orders by updated_at
    // DESC) is the fixture session — else _loadSessions (main.dart:574-585)
    // selects an EMPTY session and _sendMessage auto-_newChat() orphans it.
    final sessionRepo = SessionRepository();
    final msgRepo = MessageRepository();
    final session = await sessionRepo.create(title: 'compaction-quality');
    // fillerTurns=480 → ~965 messages → ~13k raw. 2026-09-20: the size matters MORE
    // than it used to, because the summary profile no longer carries a hardcoded
    // max_tokens — the model's own default governs how long a summary may be, so the
    // batch has to DWARF a plausible summary. Measured at fillerTurns=200 the raw
    // total was only 5471, giving a threshold of 911 and first batches of ~912 raw:
    // far too tight (a real summary is ~600 tokens). The longer fixture puts the
    // threshold around 2000, so each batch is a comfortable compression target.
    // Tool-call round + keys live in the OLDEST messages.
    final fixture = buildConfigRefactorConversation(
        sessionId: session.id, fillerTurns: 480);

    // The outgoing message forces the assistant to reference the EARLY decision
    // (P1 behavior continuity): the decision messages are the OLDEST/folded, so
    // the model must draw the value from the folded summary, not near verbatim.
    final prompt = '请确认你把 config.dart 的连接超时改成了多少秒。';

    // Self-tune the model context allowance from the real raw total:
    // allowance = 2/3*totalRaw → the threshold is 25% of it, so the far span comes
    // out as ~2 batches (few, LARGE compression targets). A too-small allowance
    // makes the threshold tiny and fragments the far into dozens of tiny batches
    // (the earlier hang). Keys (oldest) stay in the folded part — verified in
    // the pre-send check below, so a mis-tuned allowance fails at SETUP, never hangs.
    final preHistory = [
      ...fixture,
      Message(
        id: 'm_current',
        seq: (fixture.last.seq ?? 0) + 1,
        sessionId: session.id,
        role: 'user',
        content: prompt,
        createdAt: (fixture.last.seq ?? 0) + 1,
      ),
    ];
    final totalRaw = CompactionEngine.rawTokens(preHistory);
    // 2026-09-20: the threshold is 25% of the allowance, so the allowance is set to
    // ~1.5x the raw total to land the far span in a handful of LARGE batches (few,
    // big compression targets). A too-small allowance makes the threshold tiny and
    // fragments the far into dozens of tiny batches — that is what produced the
    // earlier 33-call cascade that never finished.
    final kBudget = (totalRaw * 2) ~/ 3;

    // Pre-send fold classification ([OBS] + assert): A-1 ② (fold triggers) +
    // A-1 ① (keys in the foldable far span / NOT the newest verbatim chunk).
    final prePlan =
        CompactionEngine.buildTree(history: preHistory, maxContextTokens: kBudget);
    final preFar = prePlan.folded;
    final preNear = prePlan.verbatim;
    final preFarText = preFar.map((m) => m.content).join('\n');
    final preNearText = preNear.map((m) => m.content).join('\n');
    final preSummarySegs =
        prePlan.segments.where((s) => s.summary && s.messages.isNotEmpty).toList();
    final firstSeg = preSummarySegs.isEmpty ? null : preSummarySegs.first;
    final firstSegMsgs = firstSeg?.messages ?? const [];
    final firstSegRaw =
        firstSegMsgs.isEmpty ? 0 : CompactionEngine.rawTokens(firstSegMsgs);
    debugPrint('[OBS] pre-send totalRaw=$totalRaw kBudget=$kBudget '
        'T=${CompactionEngine.thresholdTokens(kBudget, null)} '
        'shouldCompact=${prePlan.shouldCompact} farMsgs=${preFar.length} '
        'nearMsgs=${preNear.length} summarySegments=${preSummarySegs.length} '
        'firstSegMsgs=${firstSegMsgs.length} firstSegRaw=$firstSegRaw');
    debugPrint('[OBS] pre-send keysInFar=${preFarText.contains(kConfigPath)} '
        'keysInNear=${preNearText.contains(kConfigPath)} '
        'keyFieldInFar=${preFarText.toLowerCase().contains(kDecisionKeyword)}');
    expect(prePlan.shouldCompact, isTrue,
        reason: 'budget must trigger a fold (A-1 ②): totalRaw=$totalRaw');
    // Root-cause guard for the earlier hang, on the ARITHMETIC (seam-free) plan
    // that the fixture's budget determines: a fold batch must be LARGE, so that the
    // model's real summary comes out SMALLER than the batch it replaced. If the
    // batch were small, the model's output could be larger than it and
    // split-if-invalid would recurse (the 33-call cascade, now avoided).
    //
    // 2026-09-20: this used to assert "batch raw > 1024", because the sidecar sent a
    // hardcoded max_tokens of 1024 for the summary profile and 1025 was therefore
    // the true compressibility floor. That constant is GONE — the summary's output
    // length is the model's default now, so 1024 is no longer a bound this test can
    // lean on. The guard is restated as a floor on the BATCH (so the batch dwarfs
    // any plausible summary), and the honest verdict still comes from ③b (the real
    // measured summary must be smaller than its batch) — if the model does produce a
    // bloated summary, ③b fails and says so.
    // NOTE — this is a BASELINE, not a guarantee: the production fold runs a
    // ModelSeamSelector (enabled because no summaryProvider is injected), and
    // the LLM seam can cut batches SMALLER than the arithmetic plan. A seam-cut
    // tiny batch may then bloat-omit (D3/D4) a dense span — that is surfaced HONESTLY
    // by ③a (or the empty-summary_nodes gate), not hidden. The seam plan cannot be
    // pre-computed here (it needs the LLM), so the guard validates the baseline
    // only; the ③a/empty gates are the seam-sensitive truth.
    expect(firstSegRaw, greaterThan(2000),
        reason: 'the first ARITHMETIC fold batch raw ($firstSegRaw) must be large '
            '(> 2000) so the model\'s real summary is a valid compression of it; if the '
            'batch were small, a longer model summary could bloat it and split-if-invalid '
            'would cascade summarize calls (the earlier hang). Fix: a LONGER fixture / '
            'larger batch. (This is the seam-free baseline; the LLM seam chooser may still '
            'cut a smaller batch, surfaced honestly by ③a/empty-summary.)');
    expect(preFarText, contains(kConfigPath),
        reason: 'keys must be in the foldable far span, not the newest verbatim chunk (A-1 ①)');
    expect(preFarText.toLowerCase(), contains(kDecisionKeyword),
        reason: 'the decision field must be in the foldable far span (A-1 ①)');
    expect(preNearText, isNot(contains(kConfigPath)),
        reason: 'the path must NOT be in the newest verbatim chunk (else no summary touches it)');

    // Inject the self-tuned maxContextTokens into the REAL app so the fold fires,
    // keeping the REAL model/provider/apiKey for a genuine /v1/messages summary.
    // NOT `const MyApp()` — it hardcodes AppShell(configLoader:null) → reads
    // ~/.aliasagent/config.json and cannot set a small maxContextTokens.
    final smallConfig = AppConfig(
      version: 1,
      providers: {
        cfg.providerName: ProviderConfig(apiKey: cfg.apiKey, baseUrl: cfg.baseUrl),
      },
      agentTypes: {
        cfg.agentName: AgentTypeConfig(
          name: cfg.agentName,
          provider: cfg.providerName,
          model: cfg.model,
          systemPrompt: cfg.systemPrompt,
          maxContextTokens: kBudget,
          standingRequirements: cfg.standingRequirements,
        ),
      },
    );

    // Insert the A-1 fixture messages into the seeded session.
    for (final m in fixture) {
      await msgRepo.insert(
        sessionId: session.id,
        role: m.role,
        content: m.content,
        toolCallsJson: m.toolCallsJson,
      );
    }

    // ------------------------------------------------------------------
    // Pump the real window app with the injected small-config. AppShell's
    // _populateRegistry registers the small maxContextTokens + provokes the real
    // resolver; initState wires the real SidecarBridge + ModelSummaryProvider.
    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: AppShell(configLoader: () => ConfigResult.ok(smallConfig)),
      ),
    ));
    await tester.pump(const Duration(seconds: 2)); // AppShell init + _loadSessions

    // ------------------------------------------------------------------
    // Capture a live screenshot on EVERY exit (pass/fail/skip/timeout), while the
    // tree is still mounted — Docs/TESTING.md §5.9 requires a real-model run to
    // leave an image for visual acceptance.
    try {

      // ------------------------------------------------------------------
      // Send a message that forces the assistant to REFERENCE the EARLY decision
      // (P1 behavior continuity — the decision messages are the OLDEST/folded, so
      // the model must draw it from the folded summary, not the near verbatim).
      try {
        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: 'chat input TextField should exist');
        await tester.enterText(textField, prompt);
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: 'send button should exist');
        await tester.tap(sendButton);
        await tester.pump();

        await pumpUntilReplyOrTurnDone(tester, timeoutSec: 300);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'compact_quality reply timeout');
        fail('conversation still streaming after 300s — possible pipe deadlock or FFI crash');
      }

      // ------------------------------------------------------------------
      // Gates (TESTING.md §3.2 mirror of real_api_test.dart:177-182): ONLY an
      // Error: reply is environmental → skip. Silent completion / empty summary /
      // missing keys are REAL quality verdicts → fail.
      final reply = readFinalAssistantReply(tester);
      if (reply == null) {
        await dumpToolCards(tester, phase: 'compact_quality silent completion');
        fail('no assistant reply (silent completion) — model empty reply or internal '
            'exception (see [OBS] dump and sidecar log)');
      }
      debugPrint('[OBS] final assistant reply (${reply.length} chars):\n$reply');
      if (reply.startsWith('Error:')) {
        await dumpToolCards(tester, phase: 'compact_quality API error reply');
        markTestSkipped('API unavailable: $reply');
        return;
      }

      // [OBS] dump the REAL context-view snapshot (system + messages + tools) of
      // the model request that actually ran this turn — the live/real-model path of
      // the real-context-view feature (task 4.6). Observability only; never asserts.
      dumpContext(tester, 'compact_quality real context');

      // ------------------------------------------------------------------
      // Read back the REAL summary text from the window live's OWN temp DB. The
      // real fold materialized it into summary_nodes.summary_json (main.dart:
      // 1576-1587) with token_cost = the REAL /v1/messages output tokens (⑪).
      final nodes = await SummaryNodeRepository().queryBySession(session.id);

      // [OBS] dump every summary node's coverage + token_cost + text BEFORE any
      // assertion, so a failure is attributable (CLAUDE.md test observability).
      for (final n in nodes) {
        debugPrint('[OBS] summary node level=${n.level} nodeType=${n.nodeType} '
            'covered=[${n.coveredMinSeq},${n.coveredMaxSeq}] token_cost=${n.tokenCost}');
        debugPrint('[OBS] summary node text:\n${_summaryText(n)}');
      }

      if (nodes.isEmpty) {
        // Empty summary_nodes is NOT an environment skip: it means the far span was
        // split-omit (real model BLOAT: every batch's summary >= its raw → omitted,
        // main.dart:1638-1646/1782-1825) OR the fold's summary provider threw and
        // degraded to verbatim (main.dart:870-885). Either way the re-execution keys
        // were NEVER preserved in a summary — a REAL quality failure that must
        // surface, not be hidden.
        await dumpToolCards(tester, phase: 'compact_quality empty summary_nodes');
        expect(nodes, isNotEmpty,
            reason: 'no summary persisted — the fold errored OR split-omitted (bloat: '
                'summary >= its batch). The far-span re-execution keys were never '
                'preserved in a summary; this is a REAL quality failure, not an '
                'environment skip.');
      }

      // ------------------------------------------------------------------
      // ③a — at least one real summary preserves the load-bearing re-execution
      // keys (absolute path + decision field + decision value).
      final keyNode = _findKeyNode(nodes);
      // [OBS] dump the key-bearing node's FULL text so a reviewer can judge.
      debugPrint('[OBS] key-bearing node found=${keyNode != null}');
      expect(keyNode, isNotNull,
          reason: '③a: at least one real summary must preserve the re-execution keys '
              '(path + timeout + 30) — the summarizer dropped the load-bearing keys. '
              'If the model summary text above DOES carry the decision/invariant but NOT '
              'the literal path, the mechanism is the LLM seam chooser (production, enabled '
              'because no summaryProvider is injected) cutting a DENSE early batch (seq 1-4) '
              'that split-if-invalid then bloat-omits (D3/D4), so the path never enters a '
              'summary — a real fold quality signal, not a test artifact.');
      final keyText = _summaryText(keyNode!);
      expect(keyText, contains('/Users/acme/src/config.dart'),
          reason: '③a: real summary must preserve the absolute-path re-execution key');
      expect(keyText.toLowerCase(), contains('timeout'),
          reason: '③a: real summary must preserve the decision field (timeout)');
      expect(keyText, contains('30'),
          reason: '③a: real summary must preserve the decision value (30)');

      // ------------------------------------------------------------------
      // ③b — the key-bearing summary is a VALID compression: real output tokens
      // (token_cost) < the raw tokens of the batch it replaced. Otherwise it would
      // be a bloat that the mechanism should have split/omitted, not a quality win.
      final batchRaw = CompactionEngine.rawTokens(
        fixture.where((m) => (m.seq ?? 0) >= keyNode.coveredMinSeq &&
                (m.seq ?? 0) <= keyNode.coveredMaxSeq).toList(),
      );
      debugPrint('[OBS] key node token_cost=${keyNode.tokenCost} rawBatch=$batchRaw '
          'validCompression=${(keyNode.tokenCost ?? 0) < batchRaw}');
      expect(keyNode.tokenCost ?? 0, lessThan(batchRaw),
          reason: '③b: the key-bearing summary must be a valid compression (its real '
              'output fewer tokens than the batch it replaced); if it is NOT, the '
              'fold should have split/omitted, not sent a bloat.');

      // ------------------------------------------------------------------
      // ③c — P1 behavior continuity: the assistant's real reply REFERENCES a
      // preserved key, proving the key reached the model from the folded summary
      // (the decision messages are OLDEST/folded, not near-verbatim).
      final lower = reply.toLowerCase();
      final referenced = lower.contains('30') || lower.contains('timeout') ||
          lower.contains('config.dart');
      debugPrint('[OBS] reply references preserved key: $referenced');
      expect(referenced, isTrue,
          reason: '③c: the assistant reply must reference a preserved key (30/timeout/'
              'config.dart) — proving the re-execution key survived the fold INTO the '
            'projection the model saw (P1 behavior continuity).');

      // ------------------------------------------------------------------
      // ④ — 层级 2：真实模型下，这一趟压出来的那几条层级 1 摘要，实测 token 加起来已经
      // 超过阈值（模型能装下的总量 × 配置百分比）⇒ **同一趟里**就要合成出一条更粗的，
      // 而且它必须真的进了发给模型的内容。
      //
      // **不需要再发第二轮**（2026-09-20 收尾审查后的更正）：阈值的判据是"攒够就压，
      // 不等窗口装满"，所以这 5 条层级 1 的实测总和（约 2400）一超过阈值（约 2165），
      // 收拢循环就在**这一次**折叠里把它们合成掉了 —— 第一轮发出去的请求里就已经带着
      // 那条层级 2 了（现场可见：`level=2` 那行出现在本阶段之前）。
      //
      // 原先那版写的是"把模型容量调小、再发一轮"，实际执行时**那一轮从来没发出去**：
      // `pumpUntilReplyOrTurnDone` 在"存下最终回复"时就立刻返回，而那一刻 `_isStreaming`
      // 仍是 true，紧接着的点击被 `_sendMessage` 开头的 `if (_isStreaming) return;` 静默
      // 吞掉；于是断言其实是靠第一轮的数据满足的 —— 一个**假动作**。收尾审查指出了这一点
      // （见 `tasks.md` 的 7.6），现已按事实改成不留假动作的写法。
      final l1Nodes = nodes.where((n) => n.level == 1).toList();
      final l1TokenSum = l1Nodes.fold<int>(0, (m, n) => m + (n.tokenCost ?? 0));
      final l2Nodes = nodes.where((n) => n.level == 2).toList();
      debugPrint('[OBS] ④ 层级 2：层级 1 条数=${l1Nodes.length} '
          '层级 1 实测 token 合计=$l1TokenSum '
          '层级 2 条数=${l2Nodes.length} '
          '阈值=${CompactionEngine.thresholdTokens(kBudget, null)}');
      expect(l1Nodes.length, greaterThanOrEqualTo(2),
          reason: '④ 前提：至少要有两条层级 1 摘要，才谈得上"再合成一条更粗的"');
      expect(l1TokenSum, greaterThan(0),
          reason: '④ 前提：这些摘要的实测 token 要被记下来（否则拿什么跟阈值比）');
      expect(l1TokenSum,
          greaterThan(CompactionEngine.thresholdTokens(kBudget, null)),
          reason: '④ 前提：这几条层级 1 的实测合计确实超过了阈值 —— 这正是"够得着"的'
              '证据；够不着就说明阈值取值或实现有问题，必须如实红出来');
      expect(l2Nodes, isNotEmpty,
          reason: '④ 层级 1 的实测合计超过阈值 ⇒ 必须真的合成出层级 2；这里空着就说明'
              '"攒够阈值就压"没有实现');
      expect(l2Nodes.first.coveredMinSeq,
          lessThanOrEqualTo(l1Nodes.map((n) => n.coveredMinSeq).reduce((a, b) => a < b ? a : b)),
          reason: '④ 合成出来的那条更粗摘要，覆盖范围要从最旧那条层级 1 开始');
      expect(l2Nodes.first.coveredMaxSeq,
          greaterThanOrEqualTo(l1Nodes.map((n) => n.coveredMaxSeq).reduce((a, b) => a > b ? a : b)),
          reason: '④ 合成出来的那条更粗摘要，覆盖范围要包住所有被它替换的层级 1');

      // 合成出来的那条更粗的摘要，必须真的进了发给模型的内容。
      final sentJson = _snapshotMessagesJson(tester);
      debugPrint('[OBS] ④ sent messages contain L2 marker='
          '${sentJson.contains(kLevel2SummaryMarker)} '
          'contain L1 marker=${sentJson.contains(kSummaryMarker)} '
          'sentChars=${sentJson.length}');
      expect(sentJson, isNotEmpty,
          reason: '④ 前提：要能读到这一轮真正发给模型的内容');
      // 解开发给模型的 JSON，逐条取文本块来比对。**不能**直接拿 JSON 字符串做子串
      // 匹配：库里的摘要文本带换行，进了 JSON 会变成 `\n` 转义，匹配不上（我第一版
      // 就是这么写错的）。
      final sentTexts = <String>[];
      for (final m in (jsonDecode(sentJson) as List)) {
        final content = (m as Map<String, dynamic>)['content'];
        if (content is! List) continue;
        for (final b in content) {
          if (b is Map<String, dynamic> && b['type'] == 'text') {
            sentTexts.add((b['text'] as String?) ?? '');
          }
        }
      }
      final l2Text = _summaryText(l2Nodes.first).trim();
      final l2Head = l2Text.length <= 40 ? l2Text : l2Text.substring(0, 40);
      debugPrint('[OBS] ④ sent text blocks=${sentTexts.length} '
          'l2TextChars=${l2Text.length} l2Head="$l2Head"');
      expect(sentTexts, isNotEmpty,
          reason: '④ 前提：要能从发给模型的内容里解出文本块');
      expect(sentTexts.any((t) => t.contains(kLevel2SummaryMarker)), isTrue,
          reason: '④ 合成出来的层级 2 摘要必须真的出现在发给模型的内容里 '
              '（只写进数据库不算数）');
      // 被合成掉的那 5 条层级 1 摘要，文本不应再作为独立条目重复出现（它们的内容
      // 已经被那条更粗的摘要接过去了）。
      expect(sentTexts.any((t) => t.contains(kSummaryMarker)), isFalse,
          reason: '④ 被合成掉的层级 1 摘要不该再单独出现在投影里');
      expect(sentTexts.any((t) => t.contains(l2Head)), isTrue,
          reason: '④ 发给模型的那条更粗摘要，文本要和库里存的一致（取开头 40 字比对）');

      // ------------------------------------------------------------------
      // 切到「真实上下文」视图再截图：这一屏显示的就是**真正发给模型的内容**，
      // 那条"更早上下文(压缩xN,层级2,非用户发言)"会直接出现在画面里 —— 这样
      // 截图验收（TESTING.md §5.9）看到的就是本变更要证明的东西，而不只是一张
      // 能打开的窗口。
      await tester.tap(find.text('真实上下文'));
      await tester.pump(const Duration(seconds: 1));
      final contextShotValid = _snapshotMessagesJson(tester).isNotEmpty;
      debugPrint('[OBS] ④ 真实上下文视图可用=$contextShotValid');
    } finally {
      await captureLiveShot(tester, captureKey, 'compact_quality_live');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));
}

/// Pump until the conversation resolves:
///  (a) the app has STORED a final assistant reply (read from state — normal or
///      "Error:" reply), OR
///  (b) the turn completes (streaming was observed true, then false) with no
///      final reply stored — "silent completion" (empty reply OR internal
///      exception), OR
///  (c) [timeoutSec] elapses while streaming never stopped (genuine hang).
/// Throws TimeoutException only for (c).
Future<void> pumpUntilReplyOrTurnDone(WidgetTester tester,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  var sawStreaming = false;
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
    if (stillStreaming) sawStreaming = true;
    if (readFinalAssistantReply(tester) != null) return;   // (a) final reply stored
    if (sawStreaming && !stillStreaming) {
      // (b) streaming stopped: grace period so a pending _storeError insert
      // (which runs AFTER _endStreaming) lands and finalAssistantReply is set.
      await tester.pump(const Duration(milliseconds: 500));
      if (readFinalAssistantReply(tester) != null) return; // (a) error reply stored
      return;                                              // (b) silent completion
    }
    // !sawStreaming && !stillStreaming: still in the pre-stream DB preamble — poll on.
  }
  throw TimeoutException('Conversation still streaming after ${timeoutSec}s'); // (c)
}

/// Resolve the live provider/model/apiKey (env-overridable). Null → offline.
({String agentName, String providerName, String apiKey, String baseUrl,
    String model, String systemPrompt, List<String> standingRequirements})?
    _resolveLiveConfig() {
  final overrideKey = Platform.environment['ALIASAGENT_API_KEY']?.trim();
  final overrideBase = Platform.environment['ALIASAGENT_BASE_URL']?.trim();
  final overrideModel = Platform.environment['ALIASAGENT_MODEL']?.trim();
  if (overrideKey != null && overrideKey.isNotEmpty) {
    // Strict hasCompleteConfig (TESTING.md §2.4:58): NO fallback to a default
    // endpoint/model — api_key + base_url + model must ALL be present, else skip.
    // An empty base_url would otherwise silently target the wrong provider.
    if (overrideBase == null || overrideBase.isEmpty ||
        overrideModel == null || overrideModel.isEmpty) {
      return null;
    }
    return (
      agentName: 'general',
      providerName: 'live',
      apiKey: overrideKey,
      baseUrl: overrideBase,
      model: overrideModel,
      systemPrompt: '',
      standingRequirements: const [],
    );
  }
  final result = ConfigService.load();
  if (result.status != ConfigStatus.ok || result.config == null) return null;
  final appConfig = result.config!;
  final base = appConfig.agentTypes['general'] ??
      (appConfig.agentTypes.isNotEmpty ? appConfig.agentTypes.values.first : null);
  if (base == null) return null;
  final providerCfg = appConfig.providers[base.provider];
  if (providerCfg == null || providerCfg.apiKey.trim().isEmpty) return null;
  // Strict hasCompleteConfig: base_url + model must be non-empty (no fallback
  // default), else skip — a null model or empty base_url would send a broken
  // request, not a clean offline skip.
  if (providerCfg.baseUrl.trim().isEmpty || base.model.trim().isEmpty) return null;
  return (
    agentName: base.name,
    providerName: base.provider,
    apiKey: providerCfg.apiKey,
    baseUrl: providerCfg.baseUrl,
    model: base.model,
    systemPrompt: base.systemPrompt,
    standingRequirements: base.standingRequirements,
  );
}

/// Parse a persisted `summary_json` (role blocks: {"role":"user","content":
/// [{"type":"text","text":...}]}) into the summary TEXT. The tests parses it
/// itself — it CANNOT call the private ChatScreenState._summaryTextFromJson
/// (a different library).
String _summaryText(SummaryNode node) {
  final raw = node.summaryJson;
  if (raw == null || raw.isEmpty) return '';
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final content = decoded['content'] as List<dynamic>;
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'text') {
        buf.write(block['text']);
      }
    }
    return buf.toString();
  } catch (e) {
    debugPrint('[OBS] _summaryText parse failed: $e');
    return raw;
  }
}

/// Find the summary node whose text preserves ALL the re-execution keys (the
/// oldest foldable batch carries them). Returns null if none does (③a fails).
SummaryNode? _findKeyNode(List<SummaryNode> nodes) {
  for (final n in nodes) {
    if (n.nodeType != 'summary' || n.summaryJson == null) continue;
    final t = _summaryText(n);
    if (t.contains('/Users/acme/src/config.dart') &&
        t.toLowerCase().contains('timeout') &&
        t.contains('30')) {
      return n;
    }
  }
  return null;
}

/// 这一轮**真正发给模型**的 messages 的 JSON（从窗口状态里最近一次上下文快照读，
/// 不是从库里读）。用来断言"合成出来的那条更粗摘要确实进了请求"，而不只是写进了库。
/// 读不到（界面没挂 / 还没发过请求）就返回空串，调用方自己断言非空。
String _snapshotMessagesJson(WidgetTester tester) {
  final screen = find.byType(ChatScreen);
  if (screen.evaluate().isEmpty) return '';
  final snap = tester.state<ChatScreenState>(screen).contextSnapshot;
  if (snap == null) return '';
  return const JsonEncoder().convert(snap.messages);
}
