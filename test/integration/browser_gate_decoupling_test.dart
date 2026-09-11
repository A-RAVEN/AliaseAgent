import 'dart:convert';

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

/// Gate-decoupling test (add-browser-tool task 4.2).
///
/// The browser tools SHALL be declared OUTSIDE the `if (hasProviders)` gate: when
/// no search provider is configured (hasProviders==false) the browser tools are
/// STILL present as long as the browser runtime is available, while web_search /
/// web_fetch (provider-gated) are absent. When the browser runtime is unavailable
/// the browser tools are absent — never a silent placeholder.
void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  void setupAgentRegistry() {
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

  Widget buildApp(FakeSidecar sidecar) {
    return MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: FakeSessionRepository(testSessions(1)),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        ),
      ),
    );
  }

  /// Type and send a message so the ChatScreen calls sendMessage; the FakeSidecar
  /// captures toolsJson. [OBS] dumps what was sent (observability).
  Future<List<String>> sentToolNames(WidgetTester tester, FakeSidecar sidecar) async {
    await tester.enterText(find.byType(TextField), 'request a task');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final toolsJson = sidecar.lastToolsJson ?? '[]';
    final tools = (jsonDecode(toolsJson) as List).map((t) => (t as Map)['name'] as String).toList();
    debugPrint('[OBS] sent toolsJson -> $toolsJson');
    debugPrint('[OBS] deconstructed tool names -> ${tools.join(', ')}');
    return tools;
  }

  testWidgets('hasProviders==false + browser available -> browser tools present, web tools absent', (tester) async {
    setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]') // hasProviders == false
      ..stubBrowserAvailable('{"ok":true,"available":true,"channel":"msedge"}')
      ..queueDone();

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();

    final tools = await sentToolNames(tester, sidecar);
    expect(tools, contains('browser_navigate'));
    expect(tools, contains('browser_click'));
    expect(tools, contains('browser_type'));
    expect(tools, contains('browser_snapshot'));
    // web tools are provider-gated -> absent when hasProviders==false.
    expect(tools, isNot(contains('web_search')));
    expect(tools, isNot(contains('web_fetch')));
  });

  testWidgets('hasProviders==false + browser unavailable -> browser tools absent', (tester) async {
    setupAgentRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sidecar = FakeSidecar()
      ..stubSearchProviders('[]') // hasProviders == false
      ..stubBrowserAvailable('{"ok":true,"available":false,"error":"no Edge"}')
      ..queueDone();

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();

    final tools = await sentToolNames(tester, sidecar);
    expect(tools, isNot(contains('browser_navigate')));
    expect(tools, isNot(contains('web_search')));
    expect(tools, isNot(contains('web_fetch')));
  });
}
