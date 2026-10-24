import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/chat_item.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/input_bar.dart';
import 'helpers/test_utils.dart';

void main() {
  group('ChatArea', () {
    testWidgets('shows empty state placeholder when no messages', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: const [],
          ),
        ),
      ));

      expect(find.textContaining('No messages yet'), findsOneWidget);
      // 输入框的提示文字**不在这里**了 —— 2026-10-18 输入行搬到 `lib/ui/input_bar.dart`，
      // 相关断言移到本文件下面「输入行」那一组（直接 pump `InputBar`）。
    });

    testWidgets('renders user message', (tester) async {
      final msg = testMessage(role: 'user', content: 'Hello world');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatArea(
            items: [ChatMessageItem(msg)],
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
          ),
        ),
      ));

      expect(find.text('Thinking...'), findsOneWidget);
      expect(find.byType(AnimatedBuilder), findsWidgets); // streaming dots
    });

    testWidgets('empty message is not sent', (tester) async {
      String? sent;
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InputBar(controller: ctrl, onSubmit: () => sent = ctrl.text),
        ),
      ));

      // 空输入时点发送：空内容守卫在 InputBar 里，不许提交
      await tester.tap(find.byIcon(Icons.send));
      expect(sent, isNull);
    });

    testWidgets('a pasted image makes an empty-text message sendable', (tester) async {
      // add-image-input：贴了图但一个字没写，这也是一条合法消息。
      // 守卫必须从"只看文字"放宽成"没有文字**且**没有待发图片"。
      String? sent;
      var submitted = 0;
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InputBar(
            controller: ctrl,
            pendingImagePaths: const ['C:\\tmp\\pasted.png'],
            onSubmit: () {
              submitted++;
              sent = ctrl.text;
            },
          ),
        ),
      ));

      await tester.tap(find.byIcon(Icons.send));
      expect(submitted, 1, reason: '有图、无文字也必须能提交');
      expect(sent, '', reason: '这条路提交的是空文字 + 一张图');
    });

    testWidgets('sends message and clears input', (tester) async {
      String? sent;
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: InputBar(
            controller: ctrl,
            onSubmit: () {
              sent = ctrl.text;
              ctrl.clear();
            },
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
          ),
        ),
      ));

      expect(find.text('Read file'), findsOneWidget);
      // Tool call card shows tool name
      expect(find.textContaining('read_file'), findsOneWidget);
    });
  });
}
