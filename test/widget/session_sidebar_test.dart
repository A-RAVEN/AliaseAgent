import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/ui/session_sidebar.dart';
import 'helpers/test_utils.dart';

void main() {
  group('SessionSidebar', () {
    testWidgets('shows empty state when no sessions', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: const [],
            currentId: null,
            onNewChat: () {},
            onSelect: (_) {},
            onDelete: (_) {},
          ),
        ),
      ));

      expect(find.text('New Chat'), findsOneWidget);
      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('renders multiple sessions with titles', (tester) async {
      final sessions = testSessions(3);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: sessions,
            currentId: null,
            onNewChat: () {},
            onSelect: (_) {},
            onDelete: (_) {},
          ),
        ),
      ));

      expect(find.text('Session 1'), findsOneWidget);
      expect(find.text('Session 2'), findsOneWidget);
      expect(find.text('Session 3'), findsOneWidget);
    });

    testWidgets('highlights selected session', (tester) async {
      final sessions = testSessions(2);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: sessions,
            currentId: 's2',
            onNewChat: () {},
            onSelect: (_) {},
            onDelete: (_) {},
          ),
        ),
      ));

      // Find the session tiles and verify the selected one exists
      expect(find.text('Session 2'), findsOneWidget);

      // s2 should have a non-transparent background (selected state)
      final selectedTile = tester.widget<Container>(
        find.ancestor(
          of: find.text('Session 2'),
          matching: find.byType(Container),
        ).first,
      );
      expect(selectedTile.color, isNotNull);
    });

    testWidgets('New Chat button triggers callback', (tester) async {
      var called = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: const [],
            currentId: null,
            onNewChat: () => called = true,
            onSelect: (_) {},
            onDelete: (_) {},
          ),
        ),
      ));

      await tester.tap(find.text('New Chat'));
      expect(called, isTrue);
    });

    testWidgets('tapping a session triggers onSelect', (tester) async {
      final sessions = testSessions(1);
      Session? selected;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: sessions,
            currentId: null,
            onNewChat: () {},
            onSelect: (s) => selected = s,
            onDelete: (_) {},
          ),
        ),
      ));

      await tester.tap(find.text('Session 1'));
      expect(selected?.id, 's1');
    });
  });
}
