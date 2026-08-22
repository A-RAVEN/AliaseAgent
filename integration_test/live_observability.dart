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

import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

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
