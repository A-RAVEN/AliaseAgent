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
  group('Usage telemetry -> token_count write', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('measured usage from on_done is persisted to the assistant message',
        (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueChunk('Hi there!')
        ..queueDone(inputTokens: 421, outputTokens: 9);

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Observe (dump) the persisted token_count BEFORE asserting — the test
      // must make the usage actually visible (CLAUDE.md observability).
      for (final m in msgRepo.messages) {
        // ignore: avoid_print
        print('  [OBS] persisted msg role=${m.role} tokenCount=${m.tokenCount} '
            'content="${m.content.length > 30 ? m.content.substring(0, 30) : m.content}"');
      }

      final assistant =
          msgRepo.messages.where((m) => m.role == 'assistant').toList();
      final user = msgRepo.messages.where((m) => m.role == 'user').toList();

      expect(user.single.tokenCount, isNull,
          reason: 'user messages carry no measured usage');
      expect(assistant.map((m) => m.tokenCount), contains(421),
          reason: 'the assistant message must be persisted with the measured input usage');
    });
  });
}
