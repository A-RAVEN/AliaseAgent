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
import 'package:alias_agent/ui/message_bubble.dart';
import 'package:alias_agent/ui/thinking_card.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import 'package:alias_agent/models/tool_call_activity.dart';

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

/// Finder for a COMPLETED (non-streaming) assistant MessageBubble.
Finder get completedAssistant => find.byWidgetPredicate(
      (w) => w is MessageBubble && w.role == 'assistant' && !w.isStreaming,
    );

/// Extract text from the latest completed assistant MessageBubble.
String? latestAssistantText(WidgetTester tester) {
  final widgets = tester.widgetList<MessageBubble>(completedAssistant);
  if (widgets.isEmpty) return null;
  return widgets.last.content;
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

    // Pump full AppShell (lets _initSearchAndTools run naturally)
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(seconds: 2)); // let AppShell init

    // Type message
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget, reason: 'Chat input TextField should exist');
    await tester.enterText(textField, '你好，请用一句话介绍你自己');

    // Tap send
    final sendButton = find.byTooltip('Send');
    expect(sendButton, findsOneWidget, reason: 'Send button should exist');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for completed assistant reply (isStreaming == false)
    try {
      await pumpUntilFound(tester, completedAssistant, timeoutSec: 150);
    } on TimeoutException {
      fail('No completed assistant reply within 150s — possible pipe deadlock or FFI crash');
    }

    // Check for API error
    final text = latestAssistantText(tester);
    expect(text, isNotNull, reason: 'Assistant reply should exist');
    if (text!.startsWith('Error:')) {
      apiAvailable = false;
      markTestSkipped('API unavailable: $text');
      return;
    }

    // Assert non-empty reply
    expect(text.trim(), isNotEmpty, reason: 'Assistant reply should be non-empty');
    debugPrint('[TEST] Assistant replied: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    // Let the reply render visually before teardown
    await tester.pump(const Duration(seconds: 1));
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

    // Pump full AppShell
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(seconds: 2));

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
      // AI might not have called web_fetch — check if there's an error reply
      final text = latestAssistantText(tester);
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
      // Check for error status
      final errorCard = find.byWidgetPredicate(
        (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error,
      );
      if (errorCard.evaluate().isNotEmpty) {
        fail('ToolCallCard shows Error status — internal bug in web_fetch');
      }
      fail('ToolCallCard did not reach Done within 60s');
    }

    // Wait for completed assistant reply
    try {
      await pumpUntilFound(tester, completedAssistant, timeoutSec: 150);
    } on TimeoutException {
      fail('No completed assistant reply after web_fetch — possible pipe deadlock');
    }

    final text = latestAssistantText(tester);
    expect(text, isNotNull);
    expect(text!.trim(), isNotEmpty, reason: 'Reply after web_fetch should be non-empty');
    debugPrint('[TEST] Assistant replied after web_fetch: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    // Let the reply render visually before teardown
    await tester.pump(const Duration(seconds: 1));
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
    final testFilePath = '${homeDir}${Platform.pathSeparator}_aliasagent_live_test.txt';
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

    // Pump full AppShell
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(seconds: 2));

    // Tell AI to edit the file
    final textField = find.byType(TextField);
    await tester.enterText(
      textField,
      '请使用 edit_file 工具修改 $testFileRelPath，把 "line two" 改成 "LINE TWO MODIFIED"。改完告诉我结果。',
    );

    final sendButton = find.byTooltip('Send');
    await tester.tap(sendButton);
    await tester.pump();

    // Wait for ToolCallCard to appear
    try {
      await pumpUntilFound(tester, find.byType(ToolCallCard), timeoutSec: 150);
    } on TimeoutException {
      final text = latestAssistantText(tester);
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
      final errorCard = find.byWidgetPredicate(
        (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error,
      );
      if (errorCard.evaluate().isNotEmpty) {
        fail('ToolCallCard shows Error status — internal bug in edit_file');
      }
      fail('ToolCallCard did not reach Done within 60s');
    }

    // Wait for completed assistant reply
    try {
      await pumpUntilFound(tester, completedAssistant, timeoutSec: 150);
    } on TimeoutException {
      fail('No completed assistant reply after edit_file');
    }

    // Pump extra to ensure all tool turns complete before verification
    await tester.pump(const Duration(seconds: 2));

    final text = latestAssistantText(tester);
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

    // Pump full AppShell
    await tester.pumpWidget(const MyApp());
    await tester.pump(const Duration(seconds: 2));

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
      final text = latestAssistantText(tester);
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

    // Wait for turn to complete
    try {
      await pumpUntilFound(tester, completedAssistant, timeoutSec: 150);
    } on TimeoutException {
      fail('No completed assistant reply after thinking');
    }

    // NOTE: "card still present after turn" is intentionally NOT asserted on
    // the widget tree here — with a long session history the ListView lazily
    // recycles off-viewport cards, so tree lookup is unreliable in this
    // environment. Card-preservation-on-completion semantics are covered by
    // widget tests (thinking_streaming_test 5.x / 9.10a); this live test
    // verifies the end-to-end streaming behavior (card appears + incremental
    // content + reply) above.

    // Verify assistant reply
    final text = latestAssistantText(tester);
    expect(text, isNotNull);
    expect(text!.trim(), isNotEmpty,
        reason: 'Reply after thinking should be non-empty');
    debugPrint('[TEST] Reply after thinking: ${text.length > 200 ? '${text.substring(0, 200)}...' : text}');

    await tester.pump(const Duration(seconds: 1));
  }, timeout: const Timeout(Duration(seconds: 300)));
}
