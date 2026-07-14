import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  group('AppShell', () {
    // ── 5.1 Loading spinner ────────────────────────────────────────

    testWidgets('shows loading spinner when config is not yet loaded', (tester) async {
      // notFound does not set _config or _error → loading spinner visible
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _notFound,
        ),
      ));

      // First frame: before postFrameCallback fires, _config and _error are null
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // ── 5.2 Malformed config error display ─────────────────────────

    testWidgets('shows error for malformed config', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _malformed,
        ),
      ));

      // Error is set in initState → error UI shown immediately
      expect(find.text('Configuration Error'), findsOneWidget);
      expect(find.text('Invalid config file'), findsOneWidget);
    });

    // ── 5.3 Missing config triggers SetupDialog ────────────────────

    testWidgets('notFound config shows loading then SetupDialog after postFrameCallback',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _notFound,
        ),
      ));

      // First frame: loading spinner (no config yet, no error)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Second frame: postFrameCallback fires → showDialog → SetupDialog
      await tester.pump();
      await tester.pump(); // dialog renders in overlay

      // SetupDialog should be visible now
      expect(find.byType(SetupDialog), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget);
    });
  });
}

// ── Test config loaders ─────────────────────────────────────────────

ConfigResult _notFound() => ConfigResult.notFound();

ConfigResult _malformed() => ConfigResult.malformed('Invalid config file');
