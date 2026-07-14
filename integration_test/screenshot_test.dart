import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../test/integration/helpers/fake_sidecar.dart';
import '../test/integration/helpers/screenshot_utils.dart';
import '../test/widget/helpers/fakes.dart';
import '../test/widget/helpers/test_utils.dart';

const _outputDir = 'test/smoke/output';
const _refDir = 'test/smoke/references';

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
  required GlobalKey screenshotKey,
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: screenshotKey,
        child: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: msgRepo,
          sidecar: sidecar,
        ),
      ),
    ),
  );
}

/// Capture screenshot + compare against reference.
/// Creates baseline on first run (when reference doesn't exist).
Future<void> _screenshotAndCompare(GlobalKey key, String name) async {
  await captureAndCompare(
    key,
    '$_outputDir/$name.png',
    '$_refDir/$name.png',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final screenshotKey = GlobalKey();

  setUp(() {
    Directory(_outputDir).createSync(recursive: true);
    Directory(_refDir).createSync(recursive: true);
  });

  testWidgets('capture empty state', (tester) async {
    _setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sessions = testSessions(1);
    final sidecar = FakeSidecar();

    await tester.pumpWidget(_buildApp(
      screenshotKey: screenshotKey,
      sessionRepo: FakeSessionRepository(sessions),
      msgRepo: FakeMessageRepository(),
      sidecar: sidecar,
    ));
    await tester.pump();
    await tester.pump();

    await _screenshotAndCompare(screenshotKey, 'empty_state');
  });

  testWidgets('capture error state', (tester) async {
    _setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sessions = testSessions(1);
    final sidecar = FakeSidecar()
      ..queueDone(code: 1, error: 'Authentication failed');

    await tester.pumpWidget(_buildApp(
      screenshotKey: screenshotKey,
      sessionRepo: FakeSessionRepository(sessions),
      msgRepo: FakeMessageRepository(),
      sidecar: sidecar,
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    await _screenshotAndCompare(screenshotKey, 'error');
  });

  testWidgets('capture message flow', (tester) async {
    _setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sessions = testSessions(1);
    final sidecar = FakeSidecar()
      ..queueChunk('Hi there! Here is the code you asked for.')
      ..queueDone();

    await tester.pumpWidget(_buildApp(
      screenshotKey: screenshotKey,
      sessionRepo: FakeSessionRepository(sessions),
      msgRepo: FakeMessageRepository(),
      sidecar: sidecar,
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Help me write code');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    await _screenshotAndCompare(screenshotKey, 'auto_title');
  });

  testWidgets('capture tool call', (tester) async {
    _setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sessions = testSessions(1);
    final sidecar = FakeSidecar()
      ..stubReadFile('{"ok":true,"content":"hello world"}')
      ..queueToolCall('{"name":"read_file","input":{"path":"/f.txt"}}')
      ..queueDone();

    await tester.pumpWidget(_buildApp(
      screenshotKey: screenshotKey,
      sessionRepo: FakeSessionRepository(sessions),
      msgRepo: FakeMessageRepository(),
      sidecar: sidecar,
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Read /f.txt');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    await _screenshotAndCompare(screenshotKey, 'tool_card');
  });
}
