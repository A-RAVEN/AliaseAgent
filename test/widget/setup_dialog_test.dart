import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

Widget _wrapDialog(SetupDialog dialog) {
  return MaterialApp(home: Scaffold(body: dialog));
}

void main() {
  group('SetupDialog', () {
    // ── 4.1 Renders TextField + "Start" button ─────────────────────

    testWidgets('renders API key + max context tokens fields and Start button', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}),
      ));

      // Two TextFields: API key + max context tokens
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('API Key'), findsOneWidget); // labelText
      expect(find.text('Max Context Tokens'), findsOneWidget); // labelText

      // "Start" button (NOT "Save")
      expect(find.text('Start'), findsOneWidget);
    });

    // ── 4.2 Empty input → error, dialog stays ──────────────────────

    testWidgets('empty API key shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));

      // Tap "Start" with empty input
      await tester.tap(find.text('Start'));
      await tester.pump();

      // onComplete should NOT have been called
      expect(completed, isFalse);

      // Error message should appear
      expect(find.text('Please enter an API key'), findsOneWidget);

      // Dialog should still be present
      expect(find.byType(SetupDialog), findsOneWidget);
    });

    // ── 4.3 Valid key → onComplete called ──────────────────────────

    testWidgets('valid API key triggers onComplete', (tester) async {
      bool completed = false;
      AppConfig? savedConfig;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(
          onComplete: () => completed = true,
          saveConfig: (config) => savedConfig = config,
        ),
      ));

      // Enter a valid key + a valid max context token count
      await tester.enterText(find.byType(TextField).at(0), 'sk-ant-test-key');
      await tester.enterText(find.byType(TextField).at(1), '200000');
      await tester.pump();

      // Tap "Start"
      await tester.tap(find.text('Start'));
      await tester.pump();

      // onComplete should have been called
      expect(completed, isTrue);

      // saveConfig should have been called with a valid config
      expect(savedConfig, isNotNull);
      expect(savedConfig!.providers['anthropic']!.apiKey, 'sk-ant-test-key');
      expect(
        savedConfig!.agentTypes['general']!.maxContextTokens,
        200000,
        reason: 'max context tokens must be required and captured on setup',
      );
    });

    // ── 4.3b Max context tokens is required → validation error ─────

    testWidgets('missing max context tokens shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));

      // Enter only the API key — max context tokens left empty
      await tester.enterText(find.byType(TextField).at(0), 'sk-ant-test-key');
      await tester.pump();

      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(completed, isFalse);
      expect(
        find.text('Please enter a valid max context token count (a positive integer)'),
        findsOneWidget,
      );
    });

    // ── 4.4 barrierDismissible=false ───────────────────────────────

    testWidgets('tapping outside dialog does not close it', (tester) async {
      // SetupDialog must be shown via showDialog to have a barrier
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SetupDialog(onComplete: () {}),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      // Open the dialog
      await tester.tap(find.text('Open'));
      await tester.pump(); // showDialog schedules insertion
      await tester.pump(); // dialog renders

      expect(find.byType(SetupDialog), findsOneWidget);

      // Tap outside the dialog (top-left corner, far from dialog center)
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      // Dialog should still be present (barrierDismissible: false)
      expect(find.byType(SetupDialog), findsOneWidget);
    });
  });
}
