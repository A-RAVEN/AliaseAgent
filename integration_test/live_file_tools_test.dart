@Tags(['live'])
library;

// Window-based live suite for add-file-tools (design D1-D3, change
// add-file-tools-live-tests). The REAL model drives the REAL sidecar through
// the FULL app in a REAL desktop window (`-d windows`): the user sees the AI
// answer in the window, exactly like integration_test/real_api_test.dart.
//
// Isolation (design D5, empirically confirmed in task 12.1):
//   - marked `live` (@Tags) + gated by dart_test.yaml `tags.live.skip`:
//     default `flutter test integration_test` skips it (shows the reason).
//   - run explicitly with the canonical window command:
//       flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows
//   - requires api_key + base_url + model in %USERPROFILE%\.aliasagent\config.json.
//     Missing any → the per-test markTestSkipped gate skips gracefully.
//
// Fixture ordering (design D2, review findings 9/16): `pumpWidget(MyApp)` runs
// _ChatScreenState.initState which resets the sidecar workspace to
// ConfigService.homeDir — so the test MUST re-setWorkspace(wsPath) AFTER pump
// before sending the instruction. The model only reads/writes the fixture
// workspace; the user's real files are never touched.
//
// 4 scenarios (design D3):
//   Test 1  natural multi-tool (grep_file + edit_file)
//   Test 2  batch edits array on ONE file (input['edits'].length >= 2)
//   Test 3  unique-match rejection / self-heal (region + comment-token anchors)
//   Test 4  glob_file-specific
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/message_bubble.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import 'live_observability.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pump until [finder] matches, using manual pump loops (pumpAndSettle hangs
/// because _StreamingDots / CircularProgressIndicator animate forever).
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

/// Pump until ALL [finders] match (order-independent — e.g. a tool turn may
/// emit grep_file and edit_file cards in either order).
Future<void> pumpUntilAll(
  WidgetTester tester,
  List<Finder> finders, {
  int timeoutSec = 150,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finders.every((f) => f.evaluate().isNotEmpty)) return;
  }
  throw TimeoutException('Not all finders matched within ${timeoutSec}s');
}

/// Wait until the whole conversation finishes streaming (ChatArea.isStreaming
/// becomes false), so ALL tool turns (e.g. a second edit_file for another file
/// in a later turn) have applied before file-state assertions. _isStreaming
/// stays true across tool turns and only clears at true completion
/// (main.dart _endStreaming), so this is a reliable "conversation done" signal.
Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('Conversation did not complete within ${timeoutSec}s');
}

/// Finder for a ToolCallCard of a given tool, optionally filtered by status.
Finder toolCard(String toolName, {ToolCallStatus? status}) =>
    find.byWidgetPredicate(
      (w) =>
          w is ToolCallCard &&
          w.activity.toolName == toolName &&
          (status == null || w.activity.status == status),
    );

/// Finder for a DONE edit_file card whose input carries a batch edits array
/// (>= 2 pairs). Field is `toolName` (not `name`) per tool_call_activity.dart;
/// `input` holds the full tool args (main.dart:732-736, verified task 12.2).
Finder batchEditCard() => find.byWidgetPredicate(
      (w) =>
          w is ToolCallCard &&
          w.activity.toolName == 'edit_file' &&
          w.activity.status == ToolCallStatus.done &&
          (w.activity.input['edits'] is List) &&
          (w.activity.input['edits'] as List).length >= 2,
    );

/// Count ToolCallCards currently showing an error status (soft record only —
/// subject to ListView recycling of off-viewport cards, design D2).
int _countErrorCards(WidgetTester tester) => tester
    .widgetList<ToolCallCard>(find.byWidgetPredicate(
        (w) => w is ToolCallCard && w.activity.status == ToolCallStatus.error))
    .length;

/// Design D2 rejection soft-record: a single in-tree scan can report a false
/// zero when the error card is recycled off-viewport (ListView.builder), so
/// poll while scrolling the CHAT message list up (toward the early cards) so
/// any rejection card gets (re)built. Returns the best (max) error-card count.
Future<int> _scanErrorCardsWithScroll(WidgetTester tester,
    {int windowSec = 30, int maxDrags = 12}) async {
  // Target the chat list uniquely. AppShell builds Row(SessionSidebar,
  // ChatArea) and BOTH render a ListView.builder, so find.byType(ListView) is
  // ambiguous (2 matches) and tester.drag would throw "ambiguously found
  // multiple matching widgets" on getCenter (local SDK controller.dart) — the
  // old catch(_) swallowed that, silently degrading to a single non-scrolling
  // scan (round-2 finding). ChatArea is the unique ancestor of the message list.
  final chatList = find.descendant(
    of: find.byType(ChatArea),
    matching: find.byType(ListView),
  );
  final end = DateTime.now().add(Duration(seconds: windowSec));
  var best = 0;
  var drags = 0;
  while (DateTime.now().isBefore(end) && drags < maxDrags) {
    best = _countErrorCards(tester);
    if (best > 0) break;
    if (chatList.evaluate().isEmpty) break;
    try {
      await tester.drag(chatList, const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
    } catch (_) {
      break; // gesture simulation unavailable in this environment — stop early
    }
    drags++;
  }
  return best;
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

/// Leading keyword after the last comment marker, normalized to upper-case:
///   'return 1; // DONE: fix' -> 'DONE'
///   '// TODO: implement'     -> 'TODO'
///   '// DONE (was TODO)'     -> 'DONE'
/// Returns null when the line has no comment (design D4 — robust to inline
/// comments and self-documenting replacement text).
String? _commentToken(String line) {
  final idx = line.lastIndexOf('//');
  if (idx < 0) return null;
  final comment = line.substring(idx + 2).trim();
  if (comment.isEmpty) return null;
  return comment.split(RegExp(r'[\s:,;.()]+')).first.toUpperCase();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // main() is NOT run in tests — the app's sqlite factory + DB must be set up
  // here or ChatScreen opens the user's real database (design D2, finding 10).
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  bool apiAvailable = true;

  final configResult = ConfigService.load();
  // Strict gate matching spec Req-1(c) and the (deleted) headless suite's task
  // 2.1 gate: require api_key + base_url + model ALL non-empty for the
  // 'general' agent's provider. ConfigService.load() returns ok for any
  // PARSEABLE config, but a missing/empty base_url defaults to '' without
  // throwing (provider_config.dart:13) and the app then falls back to
  // https://api.anthropic.com (main.dart:660-662) — firing a real call at the
  // WRONG default endpoint before any Error: reply. That violates "no fallback
  // default" + spec Req-1(c) ("rather than ... firing calls against a wrong
  // default endpoint"), so the gate checks field completeness, not parse status
  // (round-3 findings). Missing api_key/model already throw on parse → malformed.
  bool hasCompleteConfig = false;
  if (configResult.status == ConfigStatus.ok) {
    final c = configResult.config!;
    final general = c.agentTypes['general'];
    final provider = general != null ? c.providers[general.provider] : null;
    hasCompleteConfig = general != null &&
        provider != null &&
        provider.apiKey.isNotEmpty &&
        provider.baseUrl.isNotEmpty &&
        general.model.isNotEmpty;
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_live_');
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
  // Test 1 — natural multi-tool (grep_file finds TODOs, edit_file fixes them)
  // =========================================================================
  testWidgets(
    'Test 1: natural multi-tool — grep_file finds TODOs, edit_file fixes them',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent '
            '(no fallback to a default endpoint)');
        return;
      }

      // 1. Fixture workspace (pure filesystem, BEFORE pump).
      final ws = Directory('${tempDir.path}/ws')..createSync();
      final src = Directory('${ws.path}/src')..createSync();
      File('${src.path}/a.dart').writeAsStringSync(
          '// TODO: fix the timeout\nvoid main() {}\n');
      File('${src.path}/b.dart').writeAsStringSync(
          '// TODO: also fix the retry\nvoid other() {}\n');

      // 2. Pump the full app; initState resets workspace to homeDir.
      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));

      // 3. Redirect the workspace to the fixture AFTER pump (design D2).
      //    Null return = success; non-null would mean the model could touch the
      //    user's homeDir — a serious safety hazard (design Risks).
      expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
          reason: 'setWorkspace(fixture) must succeed — never fall back to homeDir');

      // 4. Drive the real model via the chat input.
      final textField = find.byType(TextField);
      expect(textField, findsOneWidget, reason: 'Chat input TextField');
      await tester.enterText(
        textField,
        'In the workspace, find every TODO comment using grep_file and '
        'replace it with DONE using edit_file. When done, report which '
        'files you edited.',
      );
      final sendButton = find.byTooltip('Send');
      expect(sendButton, findsOneWidget, reason: 'Send button');
      await tester.tap(sendButton);
      await tester.pump();

      // 5. Wait for grep_file AND edit_file tool cards to reach done
      //    (order-independent — the turn may emit them in either order).
      try {
        await pumpUntilAll(tester, [
          toolCard('grep_file', status: ToolCallStatus.done),
          toolCard('edit_file', status: ToolCallStatus.done),
        ], timeoutSec: 150);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 1 wait grep+edit done timeout');
        final text = latestAssistantText(tester);
        if (text != null && text.startsWith('Error:')) {
          apiAvailable = false;
          markTestSkipped('API unavailable: $text');
          return;
        }
        fail('Expected grep_file + edit_file done cards within 150s');
      }
      // Wait for the full conversation to complete so all tool turns have
      // applied before asserting file state.
      try {
        await _waitForTurnComplete(tester);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 1 turn-complete timeout');
        dumpFile('${src.path}/a.dart', label: 'Test 1 a.dart');
        dumpFile('${src.path}/b.dart', label: 'Test 1 b.dart');
        rethrow;
      }

      // 6. Assert file final state.
      await dumpToolCards(tester, phase: 'Test 1 pre-assertion');
      dumpFile('${src.path}/a.dart', label: 'Test 1 a.dart');
      dumpFile('${src.path}/b.dart', label: 'Test 1 b.dart');
      final aContent = File('${src.path}/a.dart').readAsStringSync();
      final bContent = File('${src.path}/b.dart').readAsStringSync();
      expect(aContent, contains('DONE'), reason: 'a.dart should end with DONE');
      expect(bContent, contains('DONE'), reason: 'b.dart should end with DONE');
      debugPrint('[TEST 1] OK — grep_file + edit_file reached done; '
          'a.dart/b.dart now contain DONE');
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );

  // =========================================================================
  // Test 2 — batch edits array (one edit_file call, edits.length >= 2)
  // =========================================================================
  testWidgets(
    'Test 2: batch edits array — one edit_file call with edits.length >= 2',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent '
            '(no fallback to a default endpoint)');
        return;
      }
      if (!apiAvailable) {
        markTestSkipped('API unavailable (detected in previous test)');
        return;
      }

      final ws = Directory('${tempDir.path}/ws')..createSync();
      final src = Directory('${ws.path}/src')..createSync();
      // Three DISTINCT TODOs in ONE file + one more in a second file.
      // edit_file is per-file (single path + edits array), so the batch must
      // target a single file to be reachable (design D3).
      File('${src.path}/tasks.dart').writeAsStringSync(
          '// TODO: fix the timeout\nvoid taskA() {}\n'
          '\n'
          '// TODO: fix the retry\nvoid taskB() {}\n'
          '\n'
          '// TODO: fix the cache\nvoid taskC() {}\n');
      File('${src.path}/notes.dart').writeAsStringSync(
          '// TODO: review the doc\nvoid note() {}\n');

      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));
      expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
          reason: 'setWorkspace(fixture) must succeed — never fall back to homeDir');

      final textField = find.byType(TextField);
      await tester.enterText(
        textField,
        'Use grep_file to find all TODO comments. Replace each TODO comment '
        'with "DONE": change "// TODO: ..." to "// DONE". For src/tasks.dart, '
        'use a SINGLE edit_file call with all three replacements in one edits '
        'array (do not use replace_all). Handle src/notes.dart separately. '
        'When done, report which files you edited.',
      );
      final sendButton = find.byTooltip('Send');
      await tester.tap(sendButton);
      await tester.pump();

      // The batch really issued: a DONE edit_file card whose input['edits']
      // has >= 2 pairs (design D3 / task 12.2 empirical confirmation).
      try {
        await pumpUntilFound(tester, batchEditCard(), timeoutSec: 150);
      } on TimeoutException {
        await dumpToolCards(
            tester, phase: 'Test 2 wait batch-edit-card timeout');
        final text = latestAssistantText(tester);
        if (text != null && text.startsWith('Error:')) {
          apiAvailable = false;
          markTestSkipped('API unavailable: $text');
          return;
        }
        fail('No DONE edit_file card with edits.length >= 2 within 150s');
      }
      // Wait for the whole conversation: the model edits notes.dart in a
      // SEPARATE later turn ("Handle src/notes.dart separately"), so the file
      // assertions must run only after the turn truly completes (else they
      // race ahead of the notes.dart edit — the run-1 Test 2 failure).
      try {
        await _waitForTurnComplete(tester);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 2 turn-complete timeout');
        dumpFile('${src.path}/tasks.dart', label: 'Test 2 tasks.dart');
        dumpFile('${src.path}/notes.dart', label: 'Test 2 notes.dart');
        rethrow;
      }

      // Line-anchored assertions (design D4 — no global substring counts).
      await dumpToolCards(tester, phase: 'Test 2 pre-assertion');
      dumpFile('${src.path}/tasks.dart', label: 'Test 2 tasks.dart');
      dumpFile('${src.path}/notes.dart', label: 'Test 2 notes.dart');
      final tasksLines = File('${src.path}/tasks.dart')
          .readAsStringSync()
          .split('\n');
      final notesLines = File('${src.path}/notes.dart')
          .readAsStringSync()
          .split('\n');
      expect(tasksLines.any((l) => l.trimLeft().startsWith('// DONE')), isTrue,
          reason: 'tasks.dart TODOs should be replaced with DONE');
      expect(tasksLines.any((l) => l.trimLeft().startsWith('// TODO')), isFalse,
          reason: 'tasks.dart must contain no TODO comment line');
      expect(notesLines.any((l) => l.trimLeft().startsWith('// DONE')), isTrue,
          reason: 'notes.dart TODO should be replaced with DONE');
      expect(notesLines.any((l) => l.trimLeft().startsWith('// TODO')), isFalse,
          reason: 'notes.dart must contain no TODO comment line');
      debugPrint('[TEST 2] OK — batch edits array observed (edits.length >= 2) '
          'and both files line-anchored DONE');
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );

  // =========================================================================
  // Test 3 — unique-match rejection / self-heal (exactly one target changed)
  // =========================================================================
  testWidgets(
    'Test 3: unique-match rejection/self-heal — only countA changed',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent '
            '(no fallback to a default endpoint)');
        return;
      }
      if (!apiAvailable) {
        markTestSkipped('API unavailable (detected in previous test)');
        return;
      }

      final ws = Directory('${tempDir.path}/ws')..createSync();
      final src = Directory('${ws.path}/src')..createSync();
      // Two function bodies that are FULLY identical text, differing only in
      // the function name. A single-line old_text (comment or return line)
      // matches twice and is rejected without replace_all; the model must
      // include the function signature to target countA uniquely.
      File('${src.path}/app.dart').writeAsStringSync(
          'int countA() {\n'
          '  return 1; // TODO: implement\n'
          '}\n'
          '\n'
          'int countB() {\n'
          '  return 1; // TODO: implement\n'
          '}\n');

      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));
      expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
          reason: 'setWorkspace(fixture) must succeed — never fall back to homeDir');

      final textField = find.byType(TextField);
      await tester.enterText(
        textField,
        'There are two identical "// TODO: implement" comments in '
        'src/app.dart, inside two identically-bodied functions countA and '
        'countB. Change ONLY the one inside countA to DONE. The TODO inside '
        'countB MUST stay unchanged. Note: the two function bodies are '
        'identical text, so an old_text of just the comment or return line '
        'matches both and will be rejected unless you include the function '
        'signature. Do NOT rewrite the whole file — use edit_file to change '
        'just the comment in countA. Report when done.',
      );
      final sendButton = find.byTooltip('Send');
      await tester.tap(sendButton);
      await tester.pump();

      // edit_file must have been used (a write_file-only rewrite must not
      // satisfy the unique-match/rejection coverage).
      try {
        await pumpUntilFound(
            tester, toolCard('edit_file'), timeoutSec: 150);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 3 wait edit_file-card timeout');
        final text = latestAssistantText(tester);
        if (text != null && text.startsWith('Error:')) {
          apiAvailable = false;
          markTestSkipped('API unavailable: $text');
          return;
        }
        fail('No edit_file ToolCallCard within 150s');
      }
      // Wait for a DONE edit_file card (the self-healed successful attempt).
      try {
        await pumpUntilFound(tester,
            toolCard('edit_file', status: ToolCallStatus.done),
            timeoutSec: 150);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 3 wait edit_file-done timeout');
        // API may have died mid-turn after the first card appeared (the DONE
        // never arrives) — degrade to a graceful skip like every other wait
        // (wrap-up finding): an API-availability flake must not become a hard
        // suite failure.
        final text = latestAssistantText(tester);
        if (text != null && text.startsWith('Error:')) {
          apiAvailable = false;
          markTestSkipped('API unavailable: $text');
          return;
        }
        fail('No DONE edit_file card within 150s');
      }
      // Wait for the full conversation to complete so the region file-state
      // assertions below reflect the settled result (self-heal may span turns).
      try {
        await _waitForTurnComplete(tester);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 3 turn-complete timeout');
        dumpFile('${src.path}/app.dart', label: 'Test 3 app.dart');
        rethrow;
      }

      // Soft record (design D4): did the model hit a rejection (error card)?
      // Not a hard assertion — the model may take the unique old_text path.
      // Scroll+poll (design D2) so a recycled off-viewport error card is not
      // miscounted as zero.
      final errorCards = await _scanErrorCardsWithScroll(tester);
      debugPrint('[TEST 3] error-status tool cards observed: $errorCards');

      await dumpToolCards(tester, phase: 'Test 3 pre-assertion');
      dumpFile('${src.path}/app.dart', label: 'Test 3 app.dart');

      // Region + comment-token anchored assertions. Region split is DEFENSIVE
      // (length check — if the model rewrote the file and dropped the function
      // signatures, fail cleanly instead of throwing RangeError).
      final content = File('${src.path}/app.dart').readAsStringSync();
      final aParts = content.split('int countA()');
      final aRegion = aParts.length > 1
          ? aParts[1].split('int countB()')[0]
          : ''; // signature absent — model rewrote the file; fail below
      final bParts = content.split('int countB()');
      final bRegion = bParts.length > 1 ? bParts[1] : '';
      final aLines = aRegion.split('\n');
      final bLines = bRegion.split('\n');
      bool hasToken(String token, Iterable<String> lines) =>
          lines.any((l) => _commentToken(l) == token);
      expect(hasToken('DONE', aLines), isTrue,
          reason: 'countA TODO should have been changed to DONE');
      expect(hasToken('TODO', aLines), isFalse,
          reason: 'countA TODO must be gone — only the countA occurrence was targeted');
      expect(hasToken('TODO', bLines), isTrue,
          reason: 'countB TODO must be preserved');
      expect(hasToken('DONE', bLines), isFalse,
          reason: 'countB must not be changed (no replace_all blast)');
      debugPrint('[TEST 3] OK — countA DONE, countB preserved (region + '
          'comment-token anchored)');
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );

  // =========================================================================
  // Test 4 — glob_file-specific (locate by pattern, workspace-relative paths)
  // =========================================================================
  testWidgets(
    'Test 4: glob_file-specific — locate files by pattern',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent '
            '(no fallback to a default endpoint)');
        return;
      }
      if (!apiAvailable) {
        markTestSkipped('API unavailable (detected in previous test)');
        return;
      }

      final ws = Directory('${tempDir.path}/ws')..createSync();
      final src = Directory('${ws.path}/src')..createSync();
      File('${src.path}/a.dart').writeAsStringSync('void a() {}\n');
      File('${src.path}/b.dart').writeAsStringSync('void b() {}\n');
      File('${src.path}/data.json').writeAsStringSync('{"x": 1}\n');
      File('${ws.path}/README.md').writeAsStringSync('# Project\n');

      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));
      expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
          reason: 'setWorkspace(fixture) must succeed — never fall back to homeDir');

      final textField = find.byType(TextField);
      await tester.enterText(
        textField,
        'Use glob_file (not grep_file) to find all files matching '
        '"src/*.dart". Then use read_file on src/a.dart and report its '
        'first line.',
      );
      final sendButton = find.byTooltip('Send');
      await tester.tap(sendButton);
      await tester.pump();

      // A DONE glob_file card whose result carries both target paths
      // (workspace-relative). The card result/preview holds the formatted
      // paths (main.dart:1227-1242).
      try {
        await pumpUntilFound(
            tester,
            find.byWidgetPredicate(
              (w) =>
                  w is ToolCallCard &&
                  w.activity.toolName == 'glob_file' &&
                  w.activity.status == ToolCallStatus.done &&
                  ((w.activity.result ?? '').contains('src/a.dart') &&
                      (w.activity.result ?? '').contains('src/b.dart')),
            ),
            timeoutSec: 150);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 4 wait glob_file-done timeout');
        final text = latestAssistantText(tester);
        if (text != null && text.startsWith('Error:')) {
          apiAvailable = false;
          markTestSkipped('API unavailable: $text');
          return;
        }
        fail('No DONE glob_file card returning src/a.dart and src/b.dart '
            'within 150s');
      }
      // Wait for the conversation to complete too: the instruction asks for
      // read_file after the glob, so the model's later turns must finish before
      // teardown (else the DB-closed mid-flight race from run-1 Test 2 recurs).
      try {
        await _waitForTurnComplete(tester);
      } on TimeoutException {
        await dumpToolCards(tester, phase: 'Test 4 turn-complete timeout');
        rethrow;
      }
      await dumpToolCards(tester, phase: 'Test 4 pre-assertion');
      debugPrint('[TEST 4] OK — glob_file returned src/a.dart + src/b.dart '
          '(workspace-relative)');
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );
}
