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
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/thinking_card.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'live_observability.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pump until [finder] matches, using manual pump loops (pumpAndSettle
/// hangs because _StreamingDots uses an infinite AnimationController).
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int timeoutSec = 150,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Widget not found within ${timeoutSec}s');
}

/// Pump until the conversation resolves:
///  (a) the app has STORED a final assistant reply (read from state — normal or
///      "Error:" reply), OR
///  (b) the turn completes (streaming was observed true, then false) with no
///      final reply stored — "silent completion" (empty reply OR internal
///      exception), OR
///  (c) [timeoutSec] elapses while streaming never stopped (genuine hang).
/// Throws TimeoutException only for (c).
///
/// The reply is detected by reading STATE (readFinalAssistantReply), NOT the
/// widget tree, so a reply the app stored (main.dart insert) but whose bubble
/// was momentarily unbuilt (ListView lazy-build/recycle) is still detected
/// (fix-live-test-reply-detection D1/D2 — the 3.3 false-fail fix). On the error
/// path _endStreaming sets isStreaming=false BEFORE _storeError inserts the
/// Error reply, so a bounded grace period waits for that pending insert before
/// concluding silent-completion (design D4).
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  bool apiAvailable = true;

  // 5.2: clear any prior run's test/live_visual/*.png before the suite, so a
  // stale capture (or one from a case skipped before registering capture) is
  // never misread as this run's result.
  setUpAll(clearLiveVisualDir);

  // Check config before all tests
  final configResult = ConfigService.load();
  final configExists = configResult.status == ConfigStatus.ok;
  // search config presence indicates providers are likely configured
  final hasSearchConfig = configExists && configResult.config!.search != null;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_test_');
    await DatabaseService.openAt(tempDir.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows file lock — OS will clean temp dir
      }
    }
  });

  // =========================================================================
  // 3.1 Basic conversation
  // =========================================================================
  testWidgets('basic conversation: send message and get completed reply',
      (tester) async {
    // Skip if config missing
    if (!configExists) {
      markTestSkipped('Config not found at ${ConfigService.configPath}');
      return;
    }

    // Spike: captureKey for RepaintBoundary.toImage() — wrap MyApp so the full
    // real window render (sidebar + chat) is captured at the end of the case.
    final captureKey = GlobalKey();

    // Pump full AppShell (lets _initSearchAndTools run naturally)
    await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const MyApp()));
    await tester.pump(const Duration(seconds: 2)); // let AppShell init

    // 5.1: ride the body in try/finally (NOT addTearDown) so the capture runs
    // while the widget tree is still mounted — a teardown-registered shot fires
    // AFTER _runTestBody resets the tree (runApp(_postTestMessage)), which would
    // break the pass path. try/finally covers pass/fail/skip/timeout.
    try {
    // Type message
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget, reason: 'Chat input TextField should exist');
    await tester.enterText(textField, '你好，请用一句话介绍你自己');

    // Tap send
    final sendButton = find.byTooltip('Send');
    expect(sendButton, findsOneWidget, reason: 'Send button should exist');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for the turn to resolve: completed bubble, silent completion, or hang
    try {
      await pumpUntilReplyOrTurnDone(tester, timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.1 reply timeout');
      fail('Conversation still streaming after 150s — possible pipe deadlock or FFI crash');
    }
    if (readFinalAssistantReply(tester) == null) {
      // 静默完成：模型空回复或内部异常（测试视角不可区分）→ fail 诚实归因。
      await dumpToolCards(tester, phase: '3.1 silent completion');
      fail('Conversation completed without an assistant reply — model empty reply '
          'or internal exception (see [OBS] dump and sidecar log)');
    }

    // No-tool-call case: confirm the chat list really holds no ToolCallCard
    // before reporting "无工具调用" (if the model deviated and called a tool,
    // dump the real cards instead of falsely reporting no tools).
    await dumpNoTool(tester, '3.1 basic conversation');

    // Check for API error
    final text = readFinalAssistantReply(tester);
    expect(text, isNotNull, reason: 'Assistant reply should exist');
    if (text!.startsWith('Error:')) {
      await dumpToolCards(tester, phase: '3.1 API error reply');
      apiAvailable = false;
      markTestSkipped('API unavailable: $text');
      return;
    }

    // Assert non-empty reply
    expect(text.trim(), isNotEmpty, reason: 'Assistant reply should be non-empty');
    debugPrint('[TEST] Assistant replied: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    // Let the reply render visually before teardown
    await tester.pump(const Duration(seconds: 1));
    } finally {
      // Capture on EVERY exit from the try (pass/fail/skip/timeout), while the
      // tree is still mounted (before _runTestBody's reset unmounts it on pass).
      await captureLiveShot(tester, captureKey, '3.1_basic');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));

  // =========================================================================
  // 3.2 Web_fetch tool call
  // =========================================================================
  testWidgets('web_fetch tool call: AI fetches URL and responds',
      (tester) async {
    // Skip if config missing or API unavailable from previous test
    if (!configExists) {
      markTestSkipped('Config not found');
      return;
    }
    if (!apiAvailable) {
      markTestSkipped('API unavailable (detected in previous test)');
      return;
    }
    if (!hasSearchConfig) {
      markTestSkipped('No search providers configured — web_fetch tool not registered');
      return;
    }

    // captureKey for RepaintBoundary.toImage() — wrap MyApp for full-window shot.
    final captureKey = GlobalKey();

    // Pump full AppShell
    await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const MyApp()));
    await tester.pump(const Duration(seconds: 2));

    // 5.1: ride the body in try/finally (NOT addTearDown — a teardown shot fires
    // after the tree reset and would break the pass path). Capture runs in finally.
    try {
    // Type message with explicit tool instruction
    final textField = find.byType(TextField);
    await tester.enterText(
      textField,
      '请使用 web_fetch 工具抓取 https://example.com 的内容，然后告诉我页面标题是什么',
    );

    final sendButton = find.byTooltip('Send');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for ToolCallCard to appear
    try {
      await pumpUntilFound(tester, find.byType(ToolCallCard), timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.2 wait ToolCallCard timeout');
      // AI might not have called web_fetch — check if there's an error reply
      final text = readFinalAssistantReply(tester);
      if (text != null && text.startsWith('Error:')) {
        markTestSkipped('API unavailable: $text');
        return;
      }
      fail('No ToolCallCard within 150s — AI may not have called web_fetch');
    }

    // Wait for ToolCallCard status to become Done
    final doneCard = find.byWidgetPredicate(
      (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.done,
    );
    try {
      await pumpUntilFound(tester, doneCard, timeoutSec: 60);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.2 wait done-card timeout');
      // Check for error status
      final errorCard = find.byWidgetPredicate(
        (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error,
      );
      if (errorCard.evaluate().isNotEmpty) {
        fail('ToolCallCard shows Error status — internal bug in web_fetch');
      }
      fail('ToolCallCard did not reach Done within 60s');
    }

    // Wait for the turn to resolve: completed bubble, silent completion, or hang
    try {
      await pumpUntilReplyOrTurnDone(tester, timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.2 reply timeout');
      fail('Conversation still streaming after 150s — possible pipe deadlock or FFI crash');
    }
    if (readFinalAssistantReply(tester) == null) {
      // 静默完成：模型空回复或内部异常 → fail 诚实归因。
      await dumpToolCards(tester, phase: '3.2 silent completion');
      fail('Conversation completed without an assistant reply after web_fetch — '
          'model empty reply or internal exception (see [OBS] dump and sidecar log)');
    }

    await dumpToolCards(tester, phase: '3.2 pre-assertion');
    final text = readFinalAssistantReply(tester);
    expect(text, isNotNull);
    expect(text!.trim(), isNotEmpty, reason: 'Reply after web_fetch should be non-empty');
    debugPrint('[TEST] Assistant replied after web_fetch: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    // Let the reply render visually before teardown
    await tester.pump(const Duration(seconds: 1));
    } finally {
      await captureLiveShot(tester, captureKey, '3.2_web_fetch');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));

  // =========================================================================
  // 3.3 write_file + edit_file live tool call
  // =========================================================================
  testWidgets('write_file + edit_file: AI creates then edits a file',
      (tester) async {
    if (!configExists) {
      markTestSkipped('Config not found');
      return;
    }
    if (!apiAvailable) {
      markTestSkipped('API unavailable (detected in previous test)');
      return;
    }

    final homeDir = ConfigService.homeDir;
    final testFilePath = '$homeDir${Platform.pathSeparator}_aliasagent_live_test.txt';
    final testFileRelPath = '_aliasagent_live_test.txt';

    // Create the test file outside of the widget tree using real SidecarBridge
    final bridge = SidecarBridge.instance;
    bridge.setWorkspace(homeDir);
    final writeResult = bridge.writeFile(jsonEncode({
      'path': testFileRelPath,
      'content': 'hello from AliasAgent live test\nline two\nline three\n',
    }));
    final writeParsed = jsonDecode(writeResult);
    if (writeParsed['ok'] != true) {
      fail('Failed to create test file: ${writeParsed['error']}');
    }
    debugPrint('[TEST] Created test file at $testFilePath');

    // captureKey for RepaintBoundary.toImage() — wrap MyApp for full-window shot.
    final captureKey = GlobalKey();

    // Pump full AppShell
    await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const MyApp()));
    await tester.pump(const Duration(seconds: 2));

    // 5.1: ride the body in try/finally (NOT addTearDown — a teardown shot fires
    // after the tree reset and would break the pass path). Capture runs in finally.
    try {
    // Tell AI to edit the file
    final textField = find.byType(TextField);
    await tester.enterText(
      textField,
      '请使用 edit_file 工具修改 $testFileRelPath，把 "line two" 改成 "LINE TWO MODIFIED"。'
      '修改完成后，必须用中文自然语言回复我：修改是否成功，以及修改后的文件内容。',
    );

    final sendButton = find.byTooltip('Send');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for ToolCallCard to appear
    try {
      await pumpUntilFound(tester, find.byType(ToolCallCard), timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.3 wait ToolCallCard timeout');
      final text = readFinalAssistantReply(tester);
      if (text != null && text.startsWith('Error:')) {
        markTestSkipped('API unavailable: $text');
        // Cleanup
        try { File(testFilePath).deleteSync(); } catch (_) {}
        return;
      }
      fail('No ToolCallCard within 150s — AI may not have called edit_file');
    }

    // Wait for ToolCallCard to reach Done status
    final doneCard = find.byWidgetPredicate(
      (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.done,
    );
    try {
      await pumpUntilFound(tester, doneCard, timeoutSec: 60);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.3 wait done-card timeout');
      final errorCard = find.byWidgetPredicate(
        (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error,
      );
      if (errorCard.evaluate().isNotEmpty) {
        fail('ToolCallCard shows Error status — internal bug in edit_file');
      }
      fail('ToolCallCard did not reach Done within 60s');
    }

    // Wait for the turn to resolve: completed bubble, silent completion, or hang
    try {
      await pumpUntilReplyOrTurnDone(tester, timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.3 reply timeout');
      // Cleanup (home-dir file is outside tearDown's tempDir scope)
      try { File(testFilePath).deleteSync(); } catch (_) {}
      fail('Conversation still streaming after 150s — possible pipe deadlock or FFI crash');
    }
    if (readFinalAssistantReply(tester) == null) {
      // 静默完成：模型空回复或内部异常 → fail 诚实归因（先清理测试文件）。
      await dumpToolCards(tester, phase: '3.3 silent completion');
      try { File(testFilePath).deleteSync(); } catch (_) {}
      fail('Conversation completed without an assistant reply after edit_file — '
          'model empty reply or internal exception (see [OBS] dump and sidecar log)');
    }

    // Pump extra to ensure all tool turns complete before verification
    await tester.pump(const Duration(seconds: 2));

    await dumpToolCards(tester, phase: '3.3 pre-assertion');
    dumpFile(testFilePath, label: '3.3 test file');
    final text = readFinalAssistantReply(tester);
    expect(text, isNotNull);
    expect(text!.trim(), isNotEmpty, reason: 'Reply after edit_file should be non-empty');
    debugPrint('[TEST] Assistant replied after edit_file: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    // Verify the file was actually edited
    try {
      final actualContent = File(testFilePath).readAsStringSync();
      expect(actualContent, contains('LINE TWO MODIFIED'),
          reason: 'File should contain the edited text');
      expect(actualContent, isNot(contains('line two')),
          reason: 'File should NOT contain the original text');
      debugPrint('[TEST] File edit verified: $testFilePath');
    } catch (e) {
      fail('Failed to verify file content: $e');
    }

    // Cleanup
    try { File(testFilePath).deleteSync(); } catch (_) {}

    await tester.pump(const Duration(seconds: 1));
    } finally {
      await captureLiveShot(tester, captureKey, '3.3_edit_file');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));

  // =========================================================================
  // 3.4 Extended thinking: AI shows thinking then responds
  // =========================================================================
  testWidgets('extended thinking: AI shows thinking then responds',
      (tester) async {
    if (!configExists) {
      markTestSkipped('Config not found');
      return;
    }
    if (!apiAvailable) {
      markTestSkipped('API unavailable (detected in previous test)');
      return;
    }

    // Check if any agent type has thinking_effort configured
    final agentTypes = configResult.config!.agentTypes;
    final thinkingAgentName = agentTypes.keys.firstWhere(
      (k) {
        final eff = agentTypes[k]!.thinkingEffort;
        return eff != null && eff.isNotEmpty;
      },
      orElse: () => '',
    );
    if (thinkingAgentName.isEmpty) {
      markTestSkipped(
        'No agent type has thinking_effort. '
        'Add "thinking_effort": "high" to an agent type in config.json.',
      );
      return;
    }

    // captureKey for RepaintBoundary.toImage() — wrap MyApp for full-window shot.
    final captureKey = GlobalKey();

    // Pump full AppShell
    await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const MyApp()));
    await tester.pump(const Duration(seconds: 2));

    // 5.1: ride the body in try/finally (NOT addTearDown — a teardown shot fires
    // after the tree reset and would break the pass path). Capture runs in finally.
    try {
    // Send message requiring reasoning
    final textField = find.byType(TextField);
    await tester.enterText(
      textField,
      '请仔细计算 (15 * 37 + 42) / 3 + 11 * 5 - 8，逐步推导每一步的中间结果。',
    );

    final sendButton = find.byTooltip('Send');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for ThinkingCard to appear
    try {
      await pumpUntilFound(tester, find.byType(ThinkingCard), timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.4 wait ThinkingCard timeout');
      final text = readFinalAssistantReply(tester);
      if (text != null && text.startsWith('Error:')) {
        markTestSkipped('API error: $text');
        return;
      }
      fail('No ThinkingCard within 150s — thinking may not have been triggered');
    }

    // --- Realtime delta verification (add-real-time-thinking-display 6.1) ---
    // Expand the card, then poll: the thinking body must show NON-EMPTY
    // content while the turn is still streaming (incremental thinking_delta
    // rendering) — this also serves as the DeepSeek endpoint live measurement
    // (8.12): if no delta arrives before completion, the endpoint behaves with
    // display:omitted semantics and we record the degraded path explicitly.
    await tester.tap(find.byType(ThinkingCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // crossfade

    var sawIncrementalContent = false;
    var sawStreamingDots = false;
    for (int i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('· ').evaluate().isNotEmpty) {
        sawStreamingDots = true; // header char count → turn completed
      }
      // Look for the thinking BODY text (long italic text inside the card).
      // Exclude header texts ('💭'/'Thinking'/'· N chars') — the completed
      // header '· N chars' is >8 chars and would otherwise make the
      // measurement a false PASS on the display:omitted degraded path (12.3).
      final bodyTexts = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(ThinkingCard),
            matching: find.byType(Text),
          ))
          .where((t) {
        final d = t.data;
        return d != null &&
            d.length > 8 &&
            !d.contains('· ') &&
            !d.contains('chars');
      });
      if (bodyTexts.isNotEmpty) {
        sawIncrementalContent = true;
      }
      if (sawStreamingDots && sawIncrementalContent) break;
      if (find.textContaining('chars').evaluate().isNotEmpty) break;
    }

    if (sawIncrementalContent) {
      debugPrint('[TEST] REALTIME-DELTA: thinking content rendered before '
          'turn completion — DeepSeek delivers thinking_delta increments (PASS)');
    } else {
      debugPrint('[TEST] REALTIME-DELTA: no incremental content observed before '
          'completion — DeepSeek endpoint behaves with display:omitted semantics '
          '(degraded path: final block + indicator, documented in 8.12)');
    }

    // Wait for the turn to resolve: completed bubble, silent completion, or hang
    try {
      await pumpUntilReplyOrTurnDone(tester, timeoutSec: 150);
    } on TimeoutException {
      await dumpToolCards(tester, phase: '3.4 reply timeout');
      fail('Conversation still streaming after 150s — possible pipe deadlock or FFI crash');
    }
    if (readFinalAssistantReply(tester) == null) {
      // 静默完成：模型空回复或内部异常 → fail 诚实归因。
      await dumpToolCards(tester, phase: '3.4 silent completion');
      fail('Conversation completed without an assistant reply after thinking — '
          'model empty reply or internal exception (see [OBS] dump and sidecar log)');
    }

    // NOTE: "card still present after turn" is intentionally NOT asserted on
    // the widget tree here — with a long session history the ListView lazily
    // recycles off-viewport cards, so tree lookup is unreliable in this
    // environment. Card-preservation-on-completion semantics are covered by
    // widget tests (thinking_streaming_test 5.x / 9.10a); this live test
    // verifies the end-to-end streaming behavior (card appears + incremental
    // content + reply) above.

    // Verify assistant reply
    await dumpNoTool(tester, '3.4 extended thinking');
    final text = readFinalAssistantReply(tester);
    expect(text, isNotNull);
    expect(text!.trim(), isNotEmpty,
        reason: 'Reply after thinking should be non-empty');
    debugPrint('[TEST] Reply after thinking: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    await tester.pump(const Duration(seconds: 1));
    } finally {
      await captureLiveShot(tester, captureKey, '3.4_thinking');
    }
  }, timeout: const Timeout(Duration(seconds: 300)));
}
