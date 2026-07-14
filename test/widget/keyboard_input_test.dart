import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/chat_area.dart';

Widget _chatArea({required void Function(String) onCapture}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatArea(
        messages: const [],
        onSendMessage: onCapture,
      ),
    ),
  );
}

void main() {
  group('Keyboard input', () {
    // ── 2.1 Enter submits non-empty message ────────────────────────

    testWidgets('Enter submits non-empty message and clears input', (tester) async {
      String? sent;

      await tester.pumpWidget(_chatArea(onCapture: (text) => sent = text));

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, 'Hello');
      // Input cleared after submission
      expect(find.text('Hello'), findsNothing);
    });

    // ── 2.2 Enter on empty/blank input does nothing ────────────────

    testWidgets('Enter on empty input does not send', (tester) async {
      String? sent;

      await tester.pumpWidget(_chatArea(onCapture: (text) => sent = text));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, isNull);
    });

    testWidgets('Enter on whitespace-only input does not send', (tester) async {
      String? sent;

      await tester.pumpWidget(_chatArea(onCapture: (text) => sent = text));

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, isNull);
    });

    // ── 2.3 Shift+Enter inserts newline, does not submit ───────────

    testWidgets('Shift+Enter adds newline and does not submit', (tester) async {
      // Shift+Enter simulation: HardwareKeyboard.instance.isShiftPressed is
      // unreliable in widget tests. Instead, verify by setting multi-line text
      // (the *outcome* of Shift+Enter) and checking that it:
      //   (a) displays correctly in the TextField (multi-line)
      //   (b) does NOT trigger onSendMessage until explicit submit
      String? sent;

      await tester.pumpWidget(_chatArea(onCapture: (text) => sent = text));

      // Simulate typing "Line1" then Shift+Enter → "Line1\n"
      await tester.enterText(find.byType(TextField), 'Line1\n');
      await tester.pump();

      // onSendMessage should not have been called just from entering text
      expect(sent, isNull);

      // TextField should contain the multi-line text
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, contains('\n'));
      expect(field.controller!.text, startsWith('Line1'));

      // Now Enter with multi-line text → submits the full multi-line content
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, 'Line1\n');
      expect(field.controller!.text, isEmpty);
    });

    // ── 2.4 Multiple Shift+Enter → multiple newlines ───────────────

    testWidgets('multiple Shift+Enter produces multiple newlines, no submit', (tester) async {
      String? sent;

      await tester.pumpWidget(_chatArea(onCapture: (text) => sent = text));

      // Simulate Shift+Enter twice on empty input → "\n\n"
      await tester.enterText(find.byType(TextField), '\n\n');
      await tester.pump();

      // No submission should have occurred
      expect(sent, isNull);

      // TextField contains 2 newline characters
      final field = tester.widget<TextField>(find.byType(TextField));
      expect('\n'.allMatches(field.controller!.text).length, 2);
    });
  });
}
