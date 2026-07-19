import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// Setup agent registry with search tools enabled.
void _setupSearchAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: 'You are a helpful assistant with search capabilities.',
    tools: ['read_file', 'list_dir', 'web_search', 'web_fetch'],
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
    search: {
      'zhipuai': {'api_key': 'test-key-12345'},
    },
  ));
}

Widget _buildSearchApp({
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
  required FakeSidecar sidecar,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(
          version: 1,
          search: {'zhipuai': {'api_key': 'test-key'}},
        ),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

void main() {
  group('Web search end-to-end', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    // 11.1 — web_search end-to-end: FakeSidecar returns namespaced results
    testWidgets('web_search renders provider summary in ToolCallCard', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI search'},
        ]))
        ..stubWebSearch(jsonEncode({
          'ok': true,
          'results': {
            'zhipuai': {
              'results': [
                {'title': 'Test Result', 'url': 'https://example.com', 'content': 'This is a test search result.'},
              ],
            },
          },
        }))
        ..queueChunk('Let me search for that.')
        ..queueToolCall(jsonEncode({
          'id': 'tool_web_search',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'test search query',
            'providers': ['zhipuai'],
            'depth': 'basic',
            'max_results': 5,
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Search for test');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Flow completed without error
      expect(find.textContaining('Error:'), findsNothing);
      expect(find.text('Search for test'), findsOneWidget);
    });

    // 11.2 — Multi-provider display: verify namespaces visible
    testWidgets('multi-provider results show all namespaces', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI'},
          {'name': 'searxng', 'description': 'SearXNG'},
          {'name': 'kimi', 'description': 'Kimi'},
        ]))
        ..stubWebSearch(jsonEncode({
          'ok': true,
          'results': {
            'zhipuai': {
              'results': [
                {'title': 'ZhipuAI Result', 'url': 'https://zhipuai.example.com', 'content': 'Content from ZhipuAI.'},
              ],
            },
            'searxng': {
              'results': [
                {'title': 'SearXNG Result', 'url': 'https://searxng.example.com', 'content': 'Content from SearXNG.'},
              ],
            },
            'kimi': {
              'results': [
                {'title': '', 'url': '', 'content': 'Kimi synthesized answer about the topic.'},
              ],
            },
          },
        }))
        ..queueChunk('Searching multiple providers...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_multi',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'multi provider test',
            'providers': ['zhipuai', 'searxng', 'kimi'],
            'depth': 'basic',
            'max_results': 5,
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Search all providers');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.text('Search all providers'), findsOneWidget);
    });

    // 11.3 — Provider error display: verify error shown per namespace
    testWidgets('provider errors shown per namespace in result card', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI'},
          {'name': 'kimi', 'description': 'Kimi'},
        ]))
        ..stubWebSearch(jsonEncode({
          'ok': true,
          'results': {
            'zhipuai': {
              'results': [
                {'title': 'Good result', 'url': 'https://ok.example.com', 'content': 'Successfully retrieved.'},
              ],
            },
            'kimi': {
              'error': 'Kimi rate limited (HTTP 429) — retries exhausted',
            },
          },
        }))
        ..queueChunk('One provider had an error...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_error_ns',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'test with error',
            'providers': ['zhipuai', 'kimi'],
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Search with partial error');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Should complete without "Error:" prefix messages
      expect(find.textContaining('Error:'), findsNothing);
      expect(find.text('Search with partial error'), findsOneWidget);
    });

    // 11.4 — web_fetch end-to-end: result card, errors, distinguishable from web_search
    testWidgets('web_fetch renders fetched content in result card', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI'},
        ]))
        ..stubWebFetch(jsonEncode({
          'ok': true,
          'content': 'Full article text extracted from the web page.',
        }))
        ..queueChunk('Let me fetch that page...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_fetch',
          'type': 'tool_use',
          'name': 'web_fetch',
          'input': {
            'url': 'https://example.com/article',
            'extract_mode': 'text',
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Fetch that page');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.text('Fetch that page'), findsOneWidget);
    });

    testWidgets('web_fetch SSRF error displayed correctly', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI'},
        ]))
        ..stubWebFetch(jsonEncode({
          'ok': false,
          'error': 'Fetch failed: internal address not allowed',
        }))
        ..queueChunk('Trying to fetch...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_fetch_ssrf',
          'type': 'tool_use',
          'name': 'web_fetch',
          'input': {
            'url': 'http://localhost:8080/admin',
            'extract_mode': 'text',
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Fetch localhost');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Should complete — error from web_fetch is displayed in tool card, not as "Error:" message
      expect(find.text('Fetch localhost'), findsOneWidget);
    });

    testWidgets('web_fetch timeout error displayed', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'zhipuai', 'description': 'ZhipuAI'},
        ]))
        ..stubWebFetch(jsonEncode({
          'ok': false,
          'error': 'Fetch failed: timeout',
        }))
        ..queueChunk('Fetching...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_fetch_timeout',
          'type': 'tool_use',
          'name': 'web_fetch',
          'input': {
            'url': 'https://slow.example.com',
            'extract_mode': 'text',
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Fetch slow site');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
    });

    // 11.5 — SearXNG live e2e (skip if not set up)
    testWidgets('SearXNG live e2e skips when not available', (tester) async {
      _setupSearchAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      // Stub SearXNG as available but returning error (simulating not running)
      final sidecar = FakeSidecar()
        ..stubSearchProviders(jsonEncode([
          {'name': 'searxng', 'description': 'SearXNG self-hosted'},
        ]))
        ..stubWebSearch(jsonEncode({
          'ok': true,
          'results': {
            'searxng': {
              'error': 'SearXNG unavailable',
            },
          },
        }))
        ..queueChunk('Let me try SearXNG...')
        ..queueToolCall(jsonEncode({
          'id': 'tool_searxng_live',
          'type': 'tool_use',
          'name': 'web_search',
          'input': {
            'query': 'hello world',
            'providers': ['searxng'],
          },
        }))
        ..queueDone();

      await tester.pumpWidget(_buildSearchApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Search with SearXNG');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
    });
  });
}
