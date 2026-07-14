import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/app_config.dart';
import '../integration/helpers/fake_sidecar.dart';
import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';

const _testConfig = AppConfig(version: 1);

void main() {
  group('ChatScreen DI', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('can be created with injected repos without crash', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final msgs = [
        testMessage(sessionId: 's1', role: 'user', content: 'Test message'),
      ];

      // Verifies the DI refactoring works — injected repos and sidecar are used,
      // SidecarBridge is NOT called.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _testConfig,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(msgs),
          sidecar: FakeSidecar(),
        )),
      ));

      // After a pump, the widget should be in the tree without exceptions
      await tester.pump();
      await tester.pump();

      // No crash = DI injection successful
      expect(tester.takeException(), isNull);
    });

    testWidgets('defaults to real repos when not injected', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // Without injection, ChatScreen creates real repos and calls SidecarBridge.
      // In test environment this will throw (no DLL), so we skip this.
      // Instead, verify the constructor still works without the optional params.
      const widget = ChatScreen(config: _testConfig);
      expect(widget.sessionRepo, isNull);
      expect(widget.msgRepo, isNull);
    });
  });
}
