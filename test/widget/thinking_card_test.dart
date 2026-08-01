import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/models/chat_item.dart';
import 'package:alias_agent/ui/thinking_card.dart';

void main() {
  group('ThinkingCard widget', () {
    testWidgets('renders collapsed by default', (tester) async {
      final item = ChatThinkingItem(
        thinking: 'Let me analyze this problem step by step.',
        isStreaming: false,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: item)),
      ));

      // Header is visible
      expect(find.text('Thinking'), findsOneWidget);
      // Char count shown (not animated dots)
      expect(find.textContaining('chars'), findsOneWidget);
      // Chevron down = collapsed state
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets('toggles between collapsed and expanded on click', (tester) async {
      final item = ChatThinkingItem(
        thinking: 'Step 1: Understand the problem.',
        isStreaming: false,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: item)),
      ));

      // Initially collapsed — chevron points down
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);

      // Click header to expand
      await tester.tap(find.text('Thinking'));
      await tester.pump(const Duration(milliseconds: 300));

      // Now expanded — chevron points up
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);

      // Click again to collapse
      await tester.tap(find.text('Thinking'));
      await tester.pump(const Duration(milliseconds: 300));

      // Collapsed again
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets('shows animated dots when streaming, char count when done', (tester) async {
      // Streaming state
      final streamingItem = ChatThinkingItem(
        thinking: 'Analyzing...',
        isStreaming: true,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: streamingItem)),
      ));

      // Animated dots should be present (streaming); char count not shown
      expect(find.textContaining('chars'), findsNothing);

      // Done state
      final doneItem = ChatThinkingItem(
        thinking: 'Analyzing...',
        isStreaming: false,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: doneItem)),
      ));

      // Char count shown
      expect(find.textContaining('chars'), findsOneWidget);
    });

    testWidgets('body is scrollable with long content', (tester) async {
      final longThinking = List.filled(200, 'This is a line of thinking text. ').join('\n');
      final item = ChatThinkingItem(
        thinking: longThinking,
        isStreaming: false,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: item)),
      ));

      // Expand to see the body
      await tester.tap(find.text('Thinking'));
      await tester.pump(const Duration(milliseconds: 300));

      // Verify SingleChildScrollView exists in expanded state
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('renders thinking icon in header', (tester) async {
      final item = ChatThinkingItem(
        thinking: 'Test thinking',
        isStreaming: false,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ThinkingCard(item: item)),
      ));

      expect(find.text('💭'), findsOneWidget);
    });
  });
}
