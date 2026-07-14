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

    testWidgets('renders API key TextField and Start button', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}),
      ));

      // TextField for API key
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget); // labelText

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

      // Enter a valid key
      await tester.enterText(find.byType(TextField), 'sk-ant-test-key');
      await tester.pump();

      // Tap "Start"
      await tester.tap(find.text('Start'));
      await tester.pump();

      // onComplete should have been called
      expect(completed, isTrue);

      // saveConfig should have been called with a valid config
      expect(savedConfig, isNotNull);
      expect(savedConfig!.providers['anthropic']!.apiKey, 'sk-ant-test-key');
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
