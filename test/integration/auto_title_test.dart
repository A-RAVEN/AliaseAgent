import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';

import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
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

Session _newChatSession() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return Session(
    id: 's1',
    title: 'New Chat',
    agentType: 'general',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('Auto-title', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('first message updates session title from New Chat', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessionRepo = FakeSessionRepository([_newChatSession()]);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueChunk('Sure, I can help with that!')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Verify initial state shows "New Chat"
      // Note: the sidebar shows the title from _sessions state;
      // each Session object is a separate reference after FakeSessionRepository.list()
      // returns a copy, so checking "New Chat" still shows is the pre-update view.
      // We verify the repo state instead.
      final sessionBefore = await sessionRepo.get('s1');
      expect(sessionBefore!.title, 'New Chat');

      // Send first message — title should update from "New Chat"
      await tester.enterText(find.byType(TextField), '帮我写代码');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Verify the session title in the repo was updated
      final sessionAfter = await sessionRepo.get('s1');
      expect(sessionAfter!.title, '帮我写代码');
    });
  });
}
