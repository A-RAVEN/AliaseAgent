import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import 'helpers/test_utils.dart';

void main() {
  group('ToolCallCard', () {
    testWidgets('renders tool name and input', (tester) async {
      final activity = testToolActivity(
        toolName: 'list_dir',
        input: const {'path': '/home'},
        status: ToolCallStatus.done,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.textContaining('list_dir'), findsOneWidget);
      expect(find.textContaining('path=/home'), findsOneWidget);
    });

    testWidgets('shows executing state with spinner', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.executing,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Executing...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows done state with check icon', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.done,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Done'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('shows error state with error icon', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.error,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Error'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows result preview when done', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.done,
        resultPreview: 'file content here',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('file content here'), findsOneWidget);
      expect(find.text('Expand result'), findsOneWidget);
    });
  });
}
