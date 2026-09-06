// Observability helpers for the window-based live suites
// (integration_test/live_file_tools_test.dart, integration_test/real_api_test.dart).
//
// CLAUDE.md「测试输出可观测性」: a live test's output must let the runner/reviewer
// know what the test ACTUALLY did — the real tool calls (toolName / complete
// input / status / result) and the affected files' final state — BEFORE the
// assertions, so a failure is attributable from the log alone.
//
// Every dump here is a pure `debugPrint` increment: it NEVER asserts and NEVER
// changes expect / fail / markTestSkipped behavior (change
// add-live-test-observability design D2 — zero acceptance risk).
//
// The chat message list is a ListView.builder inside ChatArea
// (lib/ui/chat_area.dart L93-116) that lazily recycles off-viewport cards, so a
// single in-tree scan can report a false empty. All card scans here scroll the
// chat list with a bounded drag count (mirroring live_file_tools_test.dart
// `_scanErrorCardsWithScroll`) and deduplicate by ToolCallActivity.id
// (lib/models/tool_call_activity.dart L55).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/context_snapshot.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import '../test/integration/helpers/screenshot_utils.dart';

/// Read the app's MOST RECENT final assistant reply from STATE (not the widget
/// tree). The live test pumps the full MyApp, so exactly one ChatScreen is
/// mounted; `tester.state<ChatScreenState>(find.byType(ChatScreen))` resolves to
/// the live `ChatScreenState`, whose `finalAssistantReply` getter reflects the
/// stored `isFinalReply`-marked message — independent of ListView.builder
/// build/recycle/timing (change fix-live-test-reply-detection D1/D2). This is
/// the replacement for the one-shot widget scan (completedAssistant /
/// latestAssistantText) that false-failed 3.3 when the reply bubble was
/// momentarily unbuilt.
///
/// Returns null when ChatScreen is not yet mounted (config-load phase) or when
/// no final reply has been stored this turn (empty-final / internal exception).
/// The caller distinguishes those per design D4 (getter null => silent-
/// completion / pre-stream; "Error:" prefix => skip; otherwise => pass).
String? readFinalAssistantReply(WidgetTester tester) {
  final screen = find.byType(ChatScreen);
  if (screen.evaluate().isEmpty) return null;
  return tester.state<ChatScreenState>(screen).finalAssistantReply;
}

/// Unique lock on the chat message list. AppShell renders
/// Row(SessionSidebar, ChatArea) and BOTH hold a ListView.builder, so
/// find.byType(ListView) is ambiguous (2 matches) and tester.drag throws on
/// getCenter — the add-file-tools-live-tests lesson recorded in
/// `_scanErrorCardsWithScroll`.
Finder _chatListFinder() => find.descendant(
      of: find.byType(ChatArea),
      matching: find.byType(ListView),
    );

/// Scroll-scan the chat list, returning every ToolCallCard's activity deduped
/// by id in first-seen order. Bounded by [maxDrags] drags; never throws (a
/// failed gesture just stops the scan early).
Future<List<ToolCallActivity>> _scanToolCards(
  WidgetTester tester, {
  int maxDrags = 12,
}) async {
  final chatList = _chatListFinder();
  final seen = <String, ToolCallActivity>{};
  final order = <String>[];
  var drags = 0;
  while (true) {
    for (final card
        in tester.widgetList<ToolCallCard>(find.byType(ToolCallCard))) {
      final a = card.activity;
      if (a.id.isEmpty) continue;
      if (!seen.containsKey(a.id)) order.add(a.id);
      seen[a.id] = a; // keep the LATEST activity for a recycled card id
    }
    if (chatList.evaluate().isEmpty || drags >= maxDrags) break;
    try {
      await tester.drag(chatList, const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 200));
    } catch (_) {
      break; // gesture simulation unavailable — stop scanning
    }
    drags++;
  }
  // Restore the viewport to the bottom so the LATEST assistant bubble stays in
  // view for later `latestAssistantText` reads (change handle-empty-assistant-
  // reply D3 — 08-22 measured regression where the dump scrolled the bubble off
  // viewport). Restore via ScrollController.jumpTo — NOT reverse drags: the
  // first drag-based restore passed Test 1 but broke the WHOLE suite (Test 2/3/4
  // all "did not complete [E]" — see tasks 3.4), because gesture-driven drags on
  // a clamped-at-extent ListView leave pending ballistic animations that survive
  // into the next testWidgets and abort its binding. jumpTo is synchronous and
  // gesture-free (no ballistic, no cross-test residue), clamps naturally at
  // maxScrollExtent, and is best-effort (skipped when the list/controller is
  // gone, e.g. mid-teardown).
  if (chatList.evaluate().isNotEmpty) {
    try {
      final ctrl = tester.widget<ListView>(chatList).controller;
      if (ctrl != null && ctrl.hasClients) {
        ctrl.jumpTo(ctrl.position.maxScrollExtent);
        await tester.pump();
      }
    } catch (_) {
      // controller detached (mid-teardown) — restore is best-effort only
    }
  }
  return [for (final id in order) seen[id]!];
}

void _banner(String phase) =>
    debugPrint('════════ [OBS] $phase ════════');

String _truncate(String s, int len) =>
    s.length > len ? '${s.substring(0, len)}…' : s;

/// Print every tool call actually observed in the chat list this turn:
/// toolName / status / complete input (pretty JSON) / result preview. If the
/// tool carries structured results (resultSections, e.g. web_fetch), print a
/// per-section summary instead of a raw string dump.
Future<void> dumpToolCards(
  WidgetTester tester, {
  required String phase,
  int resultPreviewLen = 500,
}) async {
  final cards = await _scanToolCards(tester);
  _banner(phase);
  if (cards.isEmpty) {
    debugPrint('[OBS] $phase — no ToolCallCard found in chat list');
    return;
  }
  for (final a in cards) {
    final input = const JsonEncoder.withIndent('  ').convert(a.input);
    debugPrint('[OBS] $phase — tool=${a.toolName} status=${a.status.name} '
        'id=${a.id}');
    debugPrint('[OBS] $phase — input:\n$input');
    if (a.resultSections != null) {
      debugPrint('[OBS] $phase — result (structured):');
      for (final s in a.resultSections!) {
        final items = s.items;
        final summary = items.isEmpty
            ? '0 results'
            : '${items.length} results: '
                '${items.take(3).map((i) => i.title ?? i.url ?? '').join(' | ')}';
        debugPrint(
            '[OBS] $phase —   section=${s.label} '
            '${s.error != null ? 'error=${s.error}' : summary}');
      }
    } else {
      final result = a.result ?? a.resultPreview ?? '';
      debugPrint('[OBS] $phase — result: ${_truncate(result, resultPreviewLen)}');
    }
  }
}

/// Print a file's final content (edit_file / write_file cases — "what the
/// model actually changed" becomes attributable). A read failure is reported,
/// not thrown.
void dumpFile(String path, {required String label}) {
  _banner(label);
  debugPrint('[OBS] $label — file: $path');
  try {
    debugPrint('[OBS] $label — content:\n${File(path).readAsStringSync()}');
  } catch (e) {
    debugPrint('[OBS] $label — READ FAILED: $e');
  }
}

/// Print "无工具调用" ONLY after confirming the chat list really holds no
/// ToolCallCard (scroll-scanned). If the model actually emitted a tool call
/// (deviation), dump the real cards instead of falsely reporting "no tools".
Future<void> dumpNoTool(WidgetTester tester, String phase) async {
  final cards = await _scanToolCards(tester);
  if (cards.isEmpty) {
    _banner(phase);
    debugPrint('[OBS] $phase — 无工具调用（扫描确认聊天列表内无 ToolCallCard）');
  } else {
    await dumpToolCards(tester, phase: phase);
  }
}

/// Print the captured real-context snapshot (system + messages + tools) from
/// STATE — the same channel the context view reads — so a live test is
/// attributable to what was actually transmitted (change add-real-context-view
/// task 4.3). Purely observational: never asserts, never changes pass/fail.
/// Returns the number of captured message objects (0 when none yet).
int dumpContext(WidgetTester tester, String phase) {
  final screen = find.byType(ChatScreen);
  _banner(phase);
  if (screen.evaluate().isEmpty) {
    debugPrint('[OBS] $phase — ChatScreen not mounted');
    return 0;
  }
  final ContextSnapshot? snap =
      tester.state<ChatScreenState>(screen).contextSnapshot;
  if (snap == null) {
    debugPrint('[OBS] $phase — no context snapshot captured yet');
    return 0;
  }
  debugPrint('[OBS] $phase — session=${snap.sessionId} model=${snap.model} '
      'thinking=${snap.thinkingMode}/${snap.thinkingEffort} '
      'messages=${snap.messages.length}');
  debugPrint('[OBS] $phase — systemPrompt:\n${snap.systemPrompt}');
  debugPrint('[OBS] $phase — messages:\n'
      '${_truncate(const JsonEncoder.withIndent('  ').convert(snap.messages), 2000)}');
  debugPrint('[OBS] $phase — tools:\n${_truncate(snap.toolsJson, 1000)}');
  return snap.messages.length;
}

/// Minimum on-disk PNG size for a shot to count as sane — rejects gross
/// corruption / zero-length writes. This is the change's own spec-mandated
/// "字节数/尺寸阈值" sanity check (design D3 #2). It is deliberately a small byte
/// floor, NOT a fine-grained blank detector: a `captureWidgetAsPng` capture
/// either renders the real app (multi-color, far above this) or throws on a
/// failed/painted boundary → caught → delete-on-fail, so a solid blank isn't
/// producible here. Adding a pixel-variance decoder to hunt the (non-producible)
/// solid-blank was judged over-engineering (round-3) and, worse, a ≤5-shade
/// quantizer would delete a genuinely low-entropy but structured fail-state
/// frame that 5.1 must preserve. Any truly unreadable frame is still reported
/// honestly by the native-vision acceptance loop as "截图无效" (design D4), not
/// counted as pass — so this is a best-effort pre-filter, not the acceptance
/// gate. Kept comfortably below any real scene (27-53 KB measured) and any
/// sparse-but-real fail frame, so it never rejects a legitimate capture.
const int _kMinShotBytes = 2048;

/// 5.2 stale cleanup: remove every PNG in test/live_visual/ so a stale capture
/// from a prior run — or from a case skipped BEFORE registering capture, where
/// delete-on-fail never ran — is never misread as this run's result. Called
/// from the suite's `setUpAll` (runs once before any test body). Best-effort.
void clearLiveVisualDir() {
  final dir = Directory('test/live_visual');
  if (!dir.existsSync()) return;
  for (final e in dir.listSync()) {
    if (e is File && e.path.toLowerCase().endsWith('.png')) {
      try {
        e.deleteSync();
      } catch (_) {
        // best-effort — a locked file is fine; the capture path re-validates
      }
    }
  }
}

/// Capture the live window render to test/live_visual/[name].png for
/// native-vision acceptance (change add-live-test-visual-acceptance). The
/// caller must wrap MyApp in a RepaintBoundary(key: key) and call this from the
/// test body's `finally` (bug-fix 5.1) — a case-tail call is skipped by every
/// earlier fail()/expect/markTestSkipped/Timeout throw, so fail states would
/// never be screenshotted; and calling it from a teardown (addTearDown) is WRONG
/// because the tree is reset (runApp(_postTestMessage) in _runTestBody) before
/// teardowns fire, so the boundary is gone and capture fails on the pass path.
/// try/finally runs inside the body, before the reset, and covers all of
/// pass/fail/skip/timeout.
///
/// [tester] is used to flush one frame first: fail paths have no
/// render-stabilizing pump, and `RepaintBoundary.toImage` asserts on a
/// not-yet-painted (debugNeedsPaint) boundary.
///
/// Non-fatal: a capture failure deletes the target file (bug-fix 5.2) and
/// returns WITHOUT throwing, so a screenshot problem never fails the test it
/// observes.
Future<void> captureLiveShot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final path = 'test/live_visual/$name.png';
  final file = File(path);
  try {
    // 5.1: flush one frame so toImage doesn't hit the debugNeedsPaint assert on
    // fail paths (which have no render-stabilizing pump). A single pump() is
    // deterministic — pumpAndSettle would hang on the infinite _StreamingDots.
    await tester.pump();
    await captureWidgetAsPng(key, path);

    // 5.2 sanity: reject gross corruption / zero-length writes (byte floor).
    // This is the spec's "字节数/尺寸阈值" check; a genuinely unreadable frame is
    // still reported honestly as "截图无效" by the acceptance loop, not here.
    final bytes = await file.readAsBytes();
    if (bytes.length < _kMinShotBytes) {
      throw StateError('screenshot degenerate: ${bytes.length} bytes '
          '< $_kMinShotBytes (corrupt/zero-length write)');
    }
    debugPrint('[SHOT] captured $path (${bytes.length} bytes)');
  } catch (e) {
    // 5.2 delete-on-fail: a failed capture must NOT leave a prior run's PNG at
    // the same fixed path (which the loop reader would misread as this run).
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    debugPrint('[SHOT] screenshot failed (non-fatal): $e');
  }
}
