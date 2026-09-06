import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_snapshot.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/ui/context_view.dart';

import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';
import '../integration/helpers/fake_sidecar.dart';

/// Register the `general` agent the test drives. [maxContextTokens] of 0/none
/// leaves compaction off (a full-history send); a positive value triggers the
/// over-budget fold path.
void _setupAgentRegistry({int maxContextTokens = 0}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
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
  SummaryProvider? summaryProvider,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ),
    ),
  );
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
}

/// Switch the conversation area to the real context view via the toggle.
Future<void> _toggleToContext(WidgetTester tester) async {
  await tester.tap(find.text('真实上下文'));
  await tester.pump();
  await tester.pump();
}

/// Dump every on-screen text node (Text + SelectableText) as [OBS] so a
/// reviewer can SEE what a view actually renders (per project observability —
/// this never asserts, it only prints).
void _dumpVisibleTexts(WidgetTester tester, String label) {
  final lines = <String>[];
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final d = t.data;
    if (d != null && d.isNotEmpty) lines.add(d);
  }
  for (final s in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    final d = s.data;
    if (d != null && d.isNotEmpty) lines.add(d);
  }
  // ignore: avoid_print
  print('  [OBS] ===== $label (${lines.length} text nodes) =====');
  for (final l in lines) {
    // ignore: avoid_print
    print('  [OBS]   • ${_oneLine(l)}');
  }
  print('');
}

String _oneLine(String s) =>
    s.length > 200 ? '${s.substring(0, 200)}…' : s.replaceFirst('\n', '⏎');

void main() {
  group('Real context view (ContextView)', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('4.1(i): tool-call round — snapshot captures the grown context; '
        'ContextView renders thinking + tool_use', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // Round 1: thinking + text + tool call, then the tool loop's Round 2 final
      // answer. The last send carries the grown apiMessages (thinking | text |
      // tool_use appended on the assistant round, then the tool_result user msg).
      final sidecar = FakeSidecar()
        ..queueThinking(jsonEncode({
          'type': 'thinking', 'index': 0,
          'thinking': 'thinking text', 'signature': 's1',
        }))
        ..queueChunk('Let me look.')
        ..queueToolCall(jsonEncode({
          'type': 'tool_use', 'id': 'tool_1', 'name': 'read_file',
          'input': {'path': 'a.txt'},
        }))
        ..queueDone(stopReason: 'tool_use')
        ..queueChunk('Final answer.')
        ..queueDone(stopReason: 'end_turn');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
        summaryProvider: FakeSummaryProvider(),
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'analyze this');
      await tester.pump();
      await tester.pump();

      // (a) Snapshot readable; messages EXACTLY equal what was actually sent.
      final snap = tester.state<ChatScreenState>(find.byType(ChatScreen)).contextSnapshot;
      // ignore: avoid_print
      print('  [OBS] contextSnapshot: ${snap == null ? 'null' : snap.messages.length} msgs — '
          'systemPrompt chars=${snap?.systemPrompt.length ?? 0}');
      expect(snap, isNotNull, reason: 'a send must capture a snapshot');
      final sent = jsonDecode(sidecar.lastMessagesJson!) as List<dynamic>;
      expect(snap!.messages, sent,
          reason: 'contextSnapshot.messages must equal the exact messagesJson '
              'actually handed to the gateway (deep copy, not a live reference)');

      // The grown snapshot must contain a thinking block, a tool_use block and a
      // tool_result (block types actually present in the last send).
      final allBlocks = <String>[];
      for (final m in snap.messages) {
        final c = m['content'];
        if (c is List) {
          for (final b in c) {
            if (b is Map<String, dynamic>) allBlocks.add('${b['type']}');
          }
        }
      }
      // ignore: avoid_print
      print('  [OBS] captured block types: $allBlocks');
      expect(allBlocks, contains('thinking'),
          reason: 'the snapshot must carry the thinking block sent this round');
      expect(allBlocks, contains('tool_use'),
          reason: 'the snapshot must carry the tool_use block sent this round');
      expect(allBlocks, contains('tool_result'),
          reason: 'the snapshot must carry the tool_result block sent this round');

      // Reviewable content: dump the EXACT context captured (the real context),
      // then dump the two on-screen views — the conversation view (before the
      // toggle) and the real context view (after the toggle).
      // ignore: avoid_print
      print('  [OBS] captured systemPrompt:\n${snap.systemPrompt}');
      // ignore: avoid_print
      print('  [OBS] captured messages (pretty JSON):\n'
          '${const JsonEncoder.withIndent('  ').convert(snap.messages)}');

      // (b) Toggle switches to ContextView and renders the blocks.
      _dumpVisibleTexts(tester, '对话界面 (conversation view) BEFORE toggle');
      await _toggleToContext(tester);
      _dumpVisibleTexts(tester, '真实界面-上下文视图 (context view) AFTER toggle');

      // Message headers and the tool_use JSON block label are visible.
      expect(find.textContaining('] user'), findsWidgets);
      expect(find.textContaining('] assistant'), findsOneWidget);
      expect(find.textContaining('tool_use: read_file'), findsOneWidget);

      // Thinking card renders (expand it to make the content visible).
      await tester.tap(find.text('Thinking'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('thinking text'), findsOneWidget);
      _dumpVisibleTexts(tester, '真实界面-上下文视图 (context view) THINKING expanded');
    });

    testWidgets('4.1(ii) + 4.2: compaction round — snapshot captures the folded '
        'projection and ContextView renders the summary block', (tester) async {
      _setupAgentRegistry(maxContextTokens: 200);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
      final summaryProvider = FakeSummaryProvider(text: 'FOLDED SUMMARY');

      await tester.pumpWidget(_buildApp(
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(_longConversation(10)),
        sidecar: sidecar,
        summaryProvider: summaryProvider,
      ));
      await tester.pump();
      await tester.pump();

      await _send(tester, 'continue');
      await tester.pump();
      await tester.pump();

      // Headless channel: the actual sent projection is the folded one (leads
      // with the summary marker) — this is the compaction path (4.2).
      final sent = sidecar.lastMessagesJson!;
      // ignore: avoid_print
      print('  [OBS] sent projection chars=${sent.length} '
          'hasMarkers=${sent.contains('## 更早上下文')}');
      expect(sent, contains('## 更早上下文'),
          reason: 'the over-budget conversation must be compacted to a summary '
              'prefix (task 4.2 compaction path)');

      // Snapshot must match the sent projection exactly (4.2 headless parity).
      final snap = tester.state<ChatScreenState>(find.byType(ChatScreen)).contextSnapshot;
      // ignore: avoid_print
      print('  [OBS] contextSnapshot: ${snap == null ? 'null' : snap.messages.length} msgs');
      expect(snap, isNotNull, reason: 'a send must capture a snapshot');
      expect(snap!.messages, jsonDecode(sent) as List<dynamic>,
          reason: 'the captured snapshot equals the projection actually sent');

      // A summary text block (marker-prefixed) must be present in the snapshot.
      final texts = <String>[];
      for (final m in snap.messages) {
        final c = m['content'];
        if (c is List) {
          for (final b in c) {
            if (b is Map<String, dynamic> && b['type'] == 'text') {
              texts.add((b['text'] as String?) ?? '');
            }
          }
        }
      }
      // ignore: avoid_print
      print('  [OBS] text block count=${texts.length} '
          'firstStartsWithMarker=${texts.isNotEmpty && texts.first.startsWith('## 更早上下文')}');
      expect(texts.any((t) => t.startsWith('## 更早上下文')), isTrue,
          reason: 'the compacted projection must contain a summary text block '
              '(task 4.1(ii) summary block assertion)');

      // Toggle to ContextView → SummaryItem (marker header visible).
      await _toggleToContext(tester);
      _dumpVisibleTexts(tester, '真实界面-上下文视图 (compaction summary)');
      expect(find.textContaining('更早上下文'), findsWidgets);
    });
    testWidgets('4.4: tool_result is labeled by its true elided/un-elided form '
        '(honesty review F-impl-1)', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // A snapshot whose tool_result body has already been elided by a replay
      // (full-history send / compaction projection) carries the elision marker.
      final elided = ContextSnapshot(
        sessionId: 's1',
        systemPrompt: 'sys',
        messages: [
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 't_elide',
                'content':
                    'FILE:\n${'X' * 4500}\n...[truncated middle of 9000 chars]...\n'
                    'FILE_END\n[tool_result body elided: 9000 chars > threshold 8000]',
              },
            ],
          },
        ],
        toolsJson: '[]',
        model: 'm',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        capturedAt: DateTime.now(),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ContextView(snapshot: elided)),
      ));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] elided snapshot → label: 现场发送版 (elided)');
      expect(find.textContaining('现场发送版 (elided)'), findsOneWidget,
          reason: 'an elided replayed body must be labeled elided, not un-elided '
              '(honesty review F-impl-1)');

      // A raw live-round body (no elision marker) is the un-elided form.
      final raw = ContextSnapshot(
        sessionId: 's1',
        systemPrompt: 'sys',
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't_raw', 'content': 'small raw body'},
            ],
          },
        ],
        toolsJson: '[]',
        model: 'm',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        capturedAt: DateTime.now(),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ContextView(snapshot: raw)),
      ));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] raw snapshot → label: 现场发送版 (un-elided)');
      expect(find.textContaining('现场发送版 (un-elided)'), findsOneWidget,
          reason: 'a raw live-round body must be labeled un-elided');
    });
  });
}

/// A long alternating conversation so the over-budget fold triggers.
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
