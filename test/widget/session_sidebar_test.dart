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

    // change add-agent-object-and-templates 任务 3.1：侧栏的 Agents 入口。
    testWidgets('Agents 入口调用回调；没有回调时不显示入口', (tester) async {
      var opened = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: testSessions(1),
            currentId: null,
            onNewChat: () {},
            onSelect: (_) {},
            onDelete: (_) {},
            onAgents: () => opened++,
          ),
        ),
      ));
      // ignore: avoid_print
      print('  [OBS] Agents 入口数量=${find.text('Agents').evaluate().length}；'
          '点一下回调次数（点前）=$opened');
      expect(find.text('Agents'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agents-entry')));
      expect(opened, 1);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            sessions: testSessions(1),
            currentId: null,
            onNewChat: () {},
            onSelect: (_) {},
            onDelete: (_) {},
          ),
        ),
      ));
      expect(find.text('Agents'), findsNothing,
          reason: '没提供回调时不显示一个点了没反应的入口');
    });
  });
}
