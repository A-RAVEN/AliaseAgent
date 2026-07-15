import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/chat_item.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'helpers/test_utils.dart';

void main() {
  group('ChatArea', () {
    testWidgets('shows empty state placeholder when no messages', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: const [],
            onSendMessage: (_) {},
          ),
        ),
      ));

      expect(find.textContaining('No messages yet'), findsOneWidget);
      expect(find.text('Type a message...'), findsOneWidget); // hint text is always visible
    });

    testWidgets('renders user message', (tester) async {
      final msg = testMessage(role: 'user', content: 'Hello world');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: [ChatMessageItem(msg)],
            onSendMessage: (_) {},
          ),
        ),
      ));

      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('renders assistant message', (tester) async {
      final msg = testMessage(role: 'assistant', content: 'Hi there');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: [ChatMessageItem(msg)],
            onSendMessage: (_) {},
          ),
        ),
      ));

      expect(find.text('Hi there'), findsOneWidget);
      expect(find.text('Assistant'), findsOneWidget);
    });

    testWidgets('shows streaming text with loading indicator', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: const [ChatStreamingItem('Thinking...')],
            onSendMessage: (_) {},
          ),
        ),
      ));

      expect(find.text('Thinking...'), findsOneWidget);
      expect(find.byType(AnimatedBuilder), findsWidgets); // streaming dots
    });

    testWidgets('empty message is not sent', (tester) async {
      String? sent;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: const [],
            onSendMessage: (text) => sent = text,
          ),
        ),
      ));

      // Tap send with empty input
      await tester.tap(find.byIcon(Icons.send));
      expect(sent, isNull);
    });

    testWidgets('sends message and clears input', (tester) async {
      String? sent;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: const [],
            onSendMessage: (text) => sent = text,
          ),
        ),
      ));

      await tester.enterText(find.byType(TextField), 'Test message');
      await tester.tap(find.byIcon(Icons.send));

      expect(sent, 'Test message');
      // Input should be cleared
      expect(find.text('Test message'), findsNothing);
    });

    testWidgets('renders both messages and tool activities interleaved', (tester) async {
      final msg = testMessage(role: 'user', content: 'Read file');
      final activity = testToolActivity(toolName: 'read_file');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: [
              ChatMessageItem(msg),
              ChatToolCallItem(activity),
            ],
            onSendMessage: (_) {},
          ),
        ),
      ));

      expect(find.text('Read file'), findsOneWidget);
      // Tool call card shows tool name
      expect(find.textContaining('read_file'), findsOneWidget);
    });
  });
}
