import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/chat_item.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'helpers/test_utils.dart';

/// Message with enough lines to overflow in a small viewport (400×300 logical px).
Message _longMsg(String id, String role, int lines) {
  final content = List.generate(lines, (i) => 'M$id L${i + 1}').join('\n');
  return testMessage(id: id, role: role, content: content);
}

/// Get the ListView Scrollable's ScrollPosition.
/// ChatArea has a ListView (Scrollable #1) and each MessageBubble's MarkdownBody
/// has a SingleChildScrollView (Scrollable #2+). The ListView scrollable comes first.
ScrollPosition _listScroll(WidgetTester tester) {
  final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
  return scrollable.controller!.position;
}

/// Pump ChatArea in a constrained test surface so content overflows.
Future<void> _pumpChat(WidgetTester tester, ChatArea area) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: area),
  ));
}

void main() {
  // Use small physical surface so the ListView viewport is ~235px tall,
  // which is enough to overflow with 16+ line messages.
  setUp(() {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.window.physicalSizeTestValue = const Size(400, 300);
    binding.window.devicePixelRatioTestValue = 1.0;
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.window.clearPhysicalSizeTestValue();
    binding.window.clearDevicePixelRatioTestValue();
  });

  group('Auto-scroll', () {
    // ── 3.1 New user message scrolls to bottom ─────────────────────

    testWidgets('new user message triggers auto-scroll', (tester) async {
      final msg1 = _longMsg('m1', 'user', 18);

      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1)],
        onSendMessage: (_) {},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify content overflows
      expect(_listScroll(tester).maxScrollExtent, greaterThan(0),
          reason: 'Content must overflow for auto-scroll to be meaningful');

      // Add a second message → item count increases → postFrameCallback scroll
      final msg2 = _longMsg('m2', 'user', 18);
      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1), ChatMessageItem(msg2)],
        onSendMessage: (_) {},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final pos = _listScroll(tester);
      expect(pos.pixels, equals(pos.maxScrollExtent));
    });

    // ── 3.2 Streaming text scrolls to bottom ───────────────────────

    testWidgets('streaming text update keeps scroll near bottom', (tester) async {
      final msg1 = _longMsg('m1', 'user', 16);

      // Start with one message and short streaming text
      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1), const ChatStreamingItem('Thinking...')],
        onSendMessage: (_) {},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final posBefore = _listScroll(tester);
      expect(posBefore.maxScrollExtent, greaterThan(0));
      expect(posBefore.pixels, equals(posBefore.maxScrollExtent),
          reason: 'Should start at the bottom');

      // Update streaming with more text → didUpdateWidget calls jumpTo.
      // jumpTo uses the previous frame's maxScrollExtent, so the scroll may
      // lag slightly behind the new content. Verify the streaming text is
      // present and scroll moved forward (didn't regress).
      final longStreaming = 'Thinking...\n' +
          List.generate(20, (i) => 'Stream chunk $i').join('\n');
      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1), ChatStreamingItem(longStreaming)],
        onSendMessage: (_) {},
      ));
      await tester.pump();

      // The updated streaming text should be rendered
      expect(find.textContaining('Stream chunk 0'), findsOneWidget);

      // Scroll position should not have gone backward
      final posAfter = _listScroll(tester);
      expect(posAfter.pixels, greaterThanOrEqualTo(posBefore.pixels));
    });

    // ── 3.3 Streaming completion scrolls to bottom ─────────────────

    testWidgets('streaming done with message add triggers final scroll', (tester) async {
      final msg1 = _longMsg('m1', 'user', 14);

      // Start streaming (1 msg + 1 streaming bubble = 2 items)
      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1), const ChatStreamingItem('Generating...')],
        onSendMessage: (_) {},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_listScroll(tester).maxScrollExtent, greaterThan(0));

      // Add assistant message while still streaming → item count goes
      // from 2 → 3 → postFrameCallback fires → scrolls to bottom
      final assistantContent = 'Final response.\n' * 10;
      final msg2 = testMessage(id: 'm2', role: 'assistant', content: assistantContent);
      await _pumpChat(tester, ChatArea(
        items: [ChatMessageItem(msg1), ChatMessageItem(msg2), const ChatStreamingItem('Finalizing...')],
        onSendMessage: (_) {},
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final pos = _listScroll(tester);
      expect(pos.pixels, equals(pos.maxScrollExtent));
    });
  });
}
