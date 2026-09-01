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
  // The fold budget is SELF-TUNED below from the fixture's real raw-token total.
  // A FIXED small budget (e.g. 300) fragments the far span into dozens of tiny
  // L1 batches (T=budget/2), each its own summarize call — measured at 33+ calls
  // and still running, i.e. the fold never finishes → the window appeared hung.
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
    // Seed the session + A-1 fixture FIRST, so we self-tune the fold budget from
    // the TRUE raw-token total, and `sessions.first` (list() orders by updated_at
    // DESC) is the fixture session — else _loadSessions (main.dart:574-585)
    // selects an EMPTY session and _sendMessage auto-_newChat() orphans it.
    final sessionRepo = SessionRepository();
    final msgRepo = MessageRepository();
    final session = await sessionRepo.create(title: 'compaction-quality');
    // fillerTurns=200 → ~405 messages → raw total well over 2× the summary profile
    // max_tokens (1024), so each fold batch exceeds 1024 raw and a real summary
    // (≤1024) is a GUARANTEED valid compression. The default 40-turn fixture is
    // only ~1206 raw — too short: batches came out ~400 tokens, the model's output
    // (near/over 400) bloated, and split-if-invalid cascaded (the earlier hang; 33+)
    // summary calls, never finishing). Tool-call round + keys live in the OLDEST.
    final fixture = buildConfigRefactorConversation(
        sessionId: session.id, fillerTurns: 200);

    // The outgoing message forces the assistant to reference the EARLY decision
    // (P1 behavior continuity): the decision messages are the OLDEST/folded, so
    // the model must draw the value from the folded summary, not near verbatim.
    final prompt = '请确认你把 config.dart 的连接超时改成了多少秒。';

    // Self-tune the fold budget from the real raw total: budget = 2/3*totalRaw →
    // near cap T = budget/2 = totalRaw/3, far = 2*totalRaw/3 → ~2 L1 batches (few,
    // LARGE compression targets). A too-small budget fragments the far into dozens
    // of tiny batches (the earlier hang). Keys (oldest) stay in far — verified in
    // the pre-send check below, so a mis-tuned budget fails at SETUP, never hangs.
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
    debugPrint('[OBS] pre-send totalRaw=$totalRaw kBudget=$kBudget T=${kBudget ~/ 2} '
        'shouldCompact=${prePlan.shouldCompact} farMsgs=${preFar.length} '
        'nearMsgs=${preNear.length} summarySegments=${preSummarySegs.length} '
        'firstSegMsgs=${firstSegMsgs.length} firstSegRaw=$firstSegRaw');
    debugPrint('[OBS] pre-send keysInFar=${preFarText.contains(kConfigPath)} '
        'keysInNear=${preNearText.contains(kConfigPath)} '
        'keyFieldInFar=${preFarText.toLowerCase().contains(kDecisionKeyword)}');
    expect(prePlan.shouldCompact, isTrue,
        reason: 'budget must trigger a fold (A-1 ②): totalRaw=$totalRaw');
    // Root-cause guard for the earlier hang, on the ARITHMETIC (seam-free) plan
    // that the fixture's budget determines: a fold batch must EXCEED the summary
    // profile max_tokens (1024) so a real summary (≤1024) is a valid compression
    // (< the batch); if the batch were ≤1024 the model's output could bloat it and
    // split-if-invalid recurses (the 33-call cascade, now avoided). NOTE — this is
    // a BASELINE, not a guarantee: the production fold runs a ModelSeamSelector
    // (main.dart:274-276/857, enabled because no summaryProvider is injected), and
    // the LLM seam can cut batches SMALLER than the arithmetic plan. A seam-cut
    // tiny batch may then bloat-omit (D3/D4) a dense span — that is surfaced HONESTLY
    // by ③a (or the empty-summary_nodes gate), not hidden. The seam plan cannot be
    // pre-computed here (it needs the LLM), so the guard validates the baseline
    // only; the ③a/empty gates are the seam-sensitive truth.
    expect(firstSegRaw, greaterThan(1024),
        reason: 'the first ARITHMETIC fold batch raw ($firstSegRaw) must exceed the '
            'summary profile max_tokens (1024), else a real summary can bloat the batch and '
            'split-if-invalid cascades more and more summarize calls (the earlier hang). '
            'Fix: a LONGER fixture / larger batch. (This is the seam-free baseline; the LLM '
            'seam chooser may still cut a smaller batch, surfaced honestly by ③a/empty-summary.)');
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
