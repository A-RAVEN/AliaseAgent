import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';

import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Widget _buildApp({
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

void main() {
  group('Streaming state', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('streaming completes without error and allows subsequent sends', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueChunk('Response text')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Send first message
      await tester.enterText(find.byType(TextField), 'Message 1');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // First reply should appear (streaming completed)
      expect(find.text('Response text'), findsOneWidget);

      // Queue second reply and send again — proves streaming ended cleanly
      sidecar
        ..queueChunk('Second response')
        ..queueDone();

      await tester.enterText(find.byType(TextField), 'Message 2');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Both replies should be present (no streaming state corruption)
      expect(find.text('Response text'), findsOneWidget);
      expect(find.text('Second response'), findsOneWidget);
    });

    testWidgets('send button is reachable after streaming completes', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueChunk('Done')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Send button should still exist and be tappable (streaming has ended)
      expect(find.byTooltip('Send'), findsOneWidget);
    });
  });
}
