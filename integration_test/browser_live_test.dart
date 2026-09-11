@Tags(['live'])
library;

// Window-based live suite for add-browser-tool (design/memory: change
// add-browser-tool). The REAL model drives the REAL sidecar's persistent headed
// Edge worker through the FULL app in a REAL desktop window (`-d windows`),
// exactly like integration_test/live_file_tools_test.dart.
//
// Run explicitly (skipped by default via dart_test.yaml tags.live.skip):
//   flutter test --tags live --run-skipped integration_test/browser_live_test.dart -d windows
// Requires a complete `general` agent config in ~/.aliasagent/config.json AND a
// usable browser runtime (Playwright + Edge) — otherwise per-test markTestSkipped
// gates skip gracefully (TESTING.md §3.2).
//
// 12.3: the test is no longer a shallow "open a data: empty page" exercise. It
// drives a REAL multi-step Bing search — navigate → type the keyword → trigger
// search → snapshot results → click the first result → snapshot the landing page
// → report a title/content. Acceptance comes from the worker's machine-readable
// `browser-record:` lines in sidecar.log (the channel spec'd in the change);
// each browser op writes one, and counters (raise_count / popup_closed /
// download_denied / permission_denied / tabs) are deliberately NOT in the
// model-visible snapshot text.
//
// Honest boundary (design Open Q4): a text snapshot carries N> CSS selectors, so
// whether the model can actually supply a working selector to *click* a result is
// an OPEN question — the acceptance here must NOT pre-assume it. If the model's
// own reply reports it could not find/select an element, or the records show the
// multi-step flow did not complete, that fail is a REAL recorded conclusion
// ("text snapshot is insufficient to locate elements"), NOT a test bug — it is
// surfaced (not silently degraded, not re-labelled as a confirmed capability).
// Bing anti-bot (navigator.webdriver → possible AutomationControlled flag),
// the China endpoint (cn.bing.com), and network flake are likewise reported
// honestly rather than smoothed over.
import 'dart:async';
import 'dart:convert';
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
import 'package:alias_agent/ui/tool_call_card.dart';
import 'live_observability.dart';

// The keyword the model is told to type on Bing (case-exact, so the type-record
// input can be matched verbatim). Chosen to be result-bearing enough that Bing
// yields organic results to click, while distinctive enough that we can confirm
// the model used the type tool with exactly this input.
const String _kKeyword = 'Flutter';

Future<void> _pumpUntilFound(
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

/// The sidecar.log file (or null if unavailable).
File? _sidecarLogFile() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  final log = File('$home/.aliasagent/logs/sidecar.log');
  return log.existsSync() ? log : null;
}

/// Byte length of sidecar.log at a point in time — capture it BEFORE driving the
/// model so the records read later are scoped to THIS run (sidecar.log is
/// append-only and shared, so an unscoped read could satisfy a stale record from
/// a prior run on this run's failure path).
int _sidecarLogPos() => _sidecarLogFile()?.lengthSync() ?? 0;

/// Read the `browser-record:` lines appended to sidecar.log after byte offset
/// [from]. Returns parsed maps in file order (oldest-first within this run).
List<Map<String, dynamic>> _readBrowserRecords({required int from}) {
  final log = _sidecarLogFile();
  if (log == null) return const [];
  final len = log.lengthSync();
  if (from > len) return const [];
  final raf = log.openSync(mode: FileMode.read);
  // readSync(count) reads from the CURRENT position; openSync defaults to 0, so
  // we must seek to `from` before reading. Use the SYNC variant setPositionSync —
  // setPosition() is async (returns a Future); mixing it with readSync() throws
  // "An async operation is currently pending".
  raf.setPositionSync(from);
  final bytes = raf.readSync(len - from);
  raf.closeSync();
  final content = utf8.decode(bytes, allowMalformed: true);
  final out = <Map<String, dynamic>>[];
  for (final l in content.split('\n')) {
    final idx = l.indexOf('browser-record: ');
    if (idx < 0) continue;
    try {
      out.add(jsonDecode(l.substring(idx + 'browser-record: '.length))
          as Map<String, dynamic>);
    } catch (_) {}
  }
  return out;
}

/// Whether a record's counter fields claim stay-hidden. Design 甲 (follow new
/// tab) intentionally allows multi-tab (tabs may be > 1): clicking a target=_blank
/// result follows the new page rather than closing it, so tabs==1 is NOT asserted
/// here. What stays enforced is: the tool never bring_to_front (raise_count==0).
void _expectStayHidden(Map<String, dynamic> r, {required String label}) {
  expect(r['raise_count'], 0, reason: '$label: tool must never bring_to_front');
  // tabs is reported honestly (may be > 1 under design 甲) — not asserted to ==1.
  debugPrint('[OBS] $label tabs=${r['tabs']} (multi-tab allowed under design 甲)');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUpAll(clearLiveVisualDir);

  final configResult = ConfigService.load();
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
    tempDir = Directory.systemTemp.createTempSync('aliasagent_browser_live_');
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

  testWidgets(
    'browser: real model drives a real Bing search (type/click/content-recognition) with stay-hidden semantics',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent');
        return;
      }

      // Browser-runtime availability gate.
      final avail = jsonDecode(await SidecarBridge.instance.browserAvailable());
      if (avail['available'] != true) {
        markTestSkipped('browser stack unavailable: $avail');
        return;
      }

      final ws = Directory('${tempDir.path}/ws')..createSync();
      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      await tester.pump(const Duration(seconds: 2));

      try {
        // Redirect the workspace to the fixture AFTER pump (initState resets to
        // homeDir), so a model that touches files never hits the user's home.
        expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
            reason: 'setWorkspace(fixture) must succeed');

        // Scope the browser-record channel to THIS run (append-only shared log).
        final logStart = _sidecarLogPos();

        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: 'Chat input TextField');
        await tester.enterText(
          textField,
          'Do a real multi-step web search with the browser tools '
          '(browser_navigate / browser_type / browser_click / browser_snapshot). '
          '1) browser_navigate to bing.com. '
          '2) In the search box, browser_type the exact text "$_kKeyword" '
          'and trigger the search. '
          '3) browser_snapshot the search results. '
          '4) browser_click the FIRST organic result (its title link). '
          '5) browser_snapshot the page you land on. '
          '6) Then report: the URL you landed on, the page title, and the first '
          'line of its main content. If you cannot find or click a result, say '
          'exactly WHY (what you see in the snapshot) rather than guessing.',
        );
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        // Wait for a DONE browser card (any of the 4 tools proves the tool ran).
        final doneFinder = find.byWidgetPredicate(
          (w) =>
              w is ToolCallCard &&
              w.activity.toolName.toLowerCase().startsWith('browser_') &&
              w.activity.status == ToolCallStatus.done,
        );
        try {
          await _pumpUntilFound(tester, doneFinder, timeoutSec: 180);
        } on TimeoutException {
          await dumpToolCards(tester, phase: 'wait browser done timeout');
          final text = readFinalAssistantReply(tester);
          if (text != null && text.startsWith('Error:')) {
            markTestSkipped('API unavailable: $text');
            return;
          }
          fail('Expected a done browser_* card within 180s');
        }

        // Wait for the conversation to complete so all tool turns applied.
        final end = DateTime.now().add(const Duration(seconds: 240));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(seconds: 1));
          final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
          if (areas.isNotEmpty && !areas.last.isStreaming) break;
        }

        // OBSERVABILITY: dump every real tool card + the browser-record channel
        // BEFORE asserting, so a failure is attributable from the log alone.
        await dumpToolCards(tester, phase: 'browser live final');
        final records = _readBrowserRecords(from: logStart);
        debugPrint('[OBS] browser-record count=${records.length}');
        for (final r in records) {
          debugPrint('[OBS] browser-record=${jsonEncode(r)}');
        }

        // ---- Acceptance (from the browser-record channel) --------------------

        // (1) A navigate happened and succeeded (the model went to bing).
        final navRecords = records.where(
            (r) => r['tool'] == 'navigate' && r['ok'] == true).toList();
        expect(navRecords, isNotEmpty,
            reason: 'expected at least one successful navigate record');

        // (2) The unique keyword was used: EITHER typed (type input.text) OR the
        // model constructed a search URL directly (navigate url ?q=Keyword).
        // Whether bing auto-redirects to a different host/locale, both strategies
        // are valid — only one needs to hold.
        final typedKeyword = records.any((r) =>
            r['tool'] == 'type' &&
            r['input'] is Map &&
            ((r['input'] as Map)['text'] as String?)?.contains(_kKeyword) == true);
        final navigatedKeyword = records.any((r) =>
            r['tool'] == 'navigate' &&
            ((r['url'] as String?)?.contains(_kKeyword) == true));
        expect(typedKeyword || navigatedKeyword, isTrue,
            reason: 'the model must have used the keyword "$_kKeyword" '
                '(either typed via browser_type, or navigated to a ?q= URL). '
                'Records: ${records.map((r) => r['tool']).toList()}');

        // (3) A real content change happened in a step after a click (multi-step):
        // find a click record whose snapshot_len DIFFERS from the immediately
        // preceding record's snapshot_len — proving the click changed the page
        // rather than no-oping. The browser-record channel carries snapshot_len
        // (spec.md:24), NOT snapshot text (the text stays model-side / in the tool
        // card), so this uses the carried length signal.
        bool contentChangedAfterClick = false;
        for (var i = 0; i < records.length; ++i) {
          final r = records[i];
          if (r['tool'] != 'click' || r['ok'] != true) continue;
          if (i > 0) {
            final beforeLen = (records[i - 1]['snapshot_len'] as int?) ?? 0;
            final afterLen = (r['snapshot_len'] as int?) ?? 0;
            if (afterLen > 0 && afterLen != beforeLen) {
              contentChangedAfterClick = true;
              break;
            }
          }
        }
        expect(contentChangedAfterClick, isTrue,
            reason: 'expected a click whose snapshot_len differs from the prior '
                'record (a real navigation/DOM change), proving multi-step '
                'interaction. If the model could not click a result (text-only '
                'snapshot gives no selector — design Open Q4), this fails and '
                'records that conclusion.');

        // (4) Content-recognition cross-verify — DISCRIMINATING (12.8): the model's
        // reply must contain a NON-keyword token that really appears in a LANDING
        // page record (a real result/landing page — url is NOT the bing search
        // page, title NOT the "搜索" results page). The instructed keyword (_kKeyword)
        // is excluded because it appears on the bing search page's title/url too,
        // so the OLD any-token check could be satisfied by the keyword alone and
        // proved nothing about non-hallucination (12.8 / round-5 #3). A hallucinated
        // landing title/url (e.g. "acme.example") has no record, so it cannot match.
        // If there is NO landing record at all, the model never read a real landing
        // page -> fail honestly (not a silent degradation).
        final reply = readFinalAssistantReply(tester);
        debugPrint('[OBS] final assistant reply -> ${reply ?? '(null)'}');
        expect(reply, isNotNull, reason: 'a final assistant reply must exist');
        if (reply != null) {
          expect(reply.startsWith('Error:'), isFalse,
              reason: 'model returned an API error instead of a result');
          // Landing-page records: a real result/landing page the bing search page
          // (or about:blank) is NOT — those carry the keyword and the search
          // results, not the followed target. Exclude by url (no 'bing', non-blank).
          final landing = records.where((r) {
            if (r['ok'] != true) return false;
            final u = (r['url'] as String? ?? '').toLowerCase();
            return u.isNotEmpty &&
                u != 'about:blank' &&
                !u.contains('bing') &&
                !u.contains('about:blank');
          }).toList();
          debugPrint('[OBS] content-recognition: landing records=${landing.length}');
          for (final r in landing) {
            debugPrint('[OBS] content-recognition landing url=${r['url']} '
                'title=${r['title']}');
          }
          final replyTokens = RegExp(r'[A-Za-z0-9._-]{6,}')
              .allMatches(reply)
              .map((m) => m.group(0)!)
              .toSet()
            ..remove(_kKeyword); // exclude the instructed keyword (search-page noise)
          final seen = StringBuffer();
          for (final r in landing) {
            seen.write((r['title'] as String?) ?? '');
            seen.write(' ');
            seen.write((r['url'] as String?) ?? '');
            seen.write('\n');
          }
          final anyTokenSeen = replyTokens.any((t) => seen.toString().contains(t));
          debugPrint('[OBS] content-recognition: nonKeywordReplyTokens='
              '${replyTokens.length} landingRecords=${landing.length} '
              'anyTokenInLandingRecord=$anyTokenSeen');
          expect(landing, isNotEmpty,
              reason: 'expected at least one real landing-page record (the model '
                  'must have clicked/followed a result and read the target page, '
                  'not just the bing search page)');
          expect(anyTokenSeen, isTrue,
              reason: 'the model claimed to see a page whose title/url is NOT in '
                  'any landing record. Hallucination check: a non-keyword token it '
                  'reported must appear in a real visited landing page title/url.');
        }

        // (5) Stay-hidden + single-tab on EVERY record.
        for (final r in records) {
          if (r['ok'] == true) {
            _expectStayHidden(r, label: 'tool=${r['tool']}');
          }
        }
      } finally {
        await captureLiveShot(tester, captureKey, 'browser_live_${DateTime.now().millisecondsSinceEpoch}');
      }
    },
    timeout: const Timeout(Duration(seconds: 420)),
  );
}
