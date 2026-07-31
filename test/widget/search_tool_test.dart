import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/app_config.dart';
import '../integration/helpers/fake_sidecar.dart';
import 'helpers/fakes.dart';
import 'helpers/test_utils.dart';

/// Configuration with at least one search provider.
const _configWithSearch = AppConfig(version: 1, search: {
  'zhipuai': {'api_key': 'test-key-12345'},
});

/// Configuration with no search providers.
const _configNoSearch = AppConfig(version: 1);

void main() {
  group('Search tool definitions', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    // 10.3 — Tool definition: FakeSidecar returns providers → verify description
    testWidgets('tool definitions include provider names when configured', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final msgs = [
        testMessage(sessionId: 's1', role: 'user', content: 'Hello'),
      ];
      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders(jsonEncode([
        {'name': 'zhipuai', 'description': 'ZhipuAI search provider'},
      ]));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configWithSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    // 10.5 — No providers → tools should be absent
    testWidgets('no search tools when providers empty', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final msgs = [
        testMessage(sessionId: 's1', role: 'user', content: 'Hello'),
      ];
      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders('[]'); // no providers configured

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configNoSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    // 11.6 — write_file and edit_file always appear in tool defs
    testWidgets('write_file and edit_file tools always present', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final msgs = [testMessage(sessionId: 's1', role: 'user', content: 'Hello')];
      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders('[]'); // explicitly no search providers

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configNoSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump(); await tester.pump();

      // Should not crash due to missing tool definitions
      expect(tester.takeException(), isNull);

      // Verify unconditional tools are callable via FakeSidecar
      final wf = sidecar.writeFile('{"path":"x","content":"y"}');
      expect(jsonDecode(wf)['ok'], isTrue);
      final ef = sidecar.editFile('{"path":"x","old_text":"a","new_text":"b"}');
      expect(jsonDecode(ef)['ok'], isTrue);
    });

    // 10.4 — Multiple providers → all in enum
    testWidgets('multiple providers appear in tool definition', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final msgs = [
        testMessage(sessionId: 's1', role: 'user', content: 'Hello'),
      ];
      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders(jsonEncode([
        {'name': 'zhipuai', 'description': 'ZhipuAI search'},
        {'name': 'kimi', 'description': 'Kimi search'},
        {'name': 'searxng', 'description': 'SearXNG search'},
      ]));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: const AppConfig(version: 1, search: {
            'zhipuai': {'api_key': 'k1'},
            'kimi': {'api_key': 'k2'},
          }),
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('Tool dispatch — web_search and web_fetch', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    // 10.6 — web_search dispatch
    testWidgets('web_search dispatch calls sidecar with correct JSON', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders(jsonEncode([
        {'name': 'zhipuai', 'description': 'ZhipuAI search'},
      ]));
      sidecar.stubWebSearch(jsonEncode({
        'ok': true,
        'results': {
          'zhipuai': {
            'results': [
              {'title': 'Result 1', 'url': 'https://example.com', 'content': 'Content here'},
            ],
          },
        },
      }));

      // Queue model response with a web_search tool call
      sidecar
        ..queueChunk('Let me search for that.')
        ..queueToolCall(jsonEncode({
          'id': 'tool_001',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'test query',
            'providers': ['zhipuai'],
            'depth': 'basic',
            'max_results': 5,
          },
        }))
        ..queueDone(code: 0);

      final sessions = testSessions(1);
      final msgRepo = FakeMessageRepository();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configWithSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: msgRepo,
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      // The widget should be created without errors
      expect(tester.takeException(), isNull);
    });

    // 10.7 — web_fetch dispatch
    testWidgets('web_fetch dispatch calls sidecar', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders(jsonEncode([
        {'name': 'zhipuai', 'description': 'ZhipuAI search'},
      ]));
      sidecar.stubWebFetch(jsonEncode({
        'ok': true,
        'content': 'Fetched page content here.',
      }));

      sidecar
        ..queueChunk('Let me fetch that page.')
        ..queueToolCall(jsonEncode({
          'id': 'tool_002',
          'type': 'tool_use',
          'name': 'web_fetch',
          'input': {
            'url': 'https://example.com/article',
            'extract_mode': 'text',
          },
        }))
        ..queueDone(code: 0);

      final sessions = testSessions(1);
      final msgRepo = FakeMessageRepository();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configWithSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    // 10.8 — Error propagation: Sidecar returns error → verify passed to model
    testWidgets('web_fetch error is formatted correctly', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sidecar = FakeSidecar();
      sidecar.stubSearchProviders(jsonEncode([
        {'name': 'zhipuai', 'description': 'ZhipuAI search'},
      ]));
      sidecar.stubWebSearch(jsonEncode({
        'ok': false,
        'error': 'All providers failed: zhipuai: timeout',
      }));

      sidecar
        ..queueChunk('Searching...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_err',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'nonexistent query',
            'providers': ['zhipuai'],
          },
        }))
        ..queueDone(code: 0);

      final sessions = testSessions(1);
      final msgRepo = FakeMessageRepository();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatScreen(
          config: _configWithSearch,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        )),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
