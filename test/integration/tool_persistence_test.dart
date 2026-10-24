import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/ui/message_bubble.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

const _testConfig = AppConfig(version: 1);

void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    tools: ['read_file', 'list_dir'],
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
        config: _testConfig,
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

void main() {
  group('Tool call persistence', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    // 18.T2 — Tool card persists after streaming ends
    testWidgets('tool card persists after streaming ends', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubReadFile('{"ok":true,"content":"file content here"}')
        ..queueToolCall('{"name":"read_file","input":{"path":"/test.txt"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Read test.txt');
      await tester.tap(find.byTooltip('Send'));
      // Multiple pumps to allow streaming to complete
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // After streaming ends, tool card must still be visible
      expect(find.byType(ToolCallCard), findsOneWidget);
      // No ChatStreamingItem — streaming has ended
      // (AnimatedBuilder is too broad; Material 3 uses it internally)
    });

    // 18.T3 — Tool calls stored in MessageRepository with correct JSON structure
    testWidgets('tool calls stored in MessageRepository', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubReadFile('{"ok":true,"content":"hello world"}')
        ..queueToolCall('{"name":"read_file","input":{"path":"/f.txt"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Read file');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Verify messages were stored
      final storedMsgs = await msgRepo.queryBySession('s1');
      expect(storedMsgs.length, greaterThanOrEqualTo(2)); // user + assistant(s)

      // Find the assistant message with toolCallsJson
      final assistantWithTools = storedMsgs.where(
          (m) => m.role == 'assistant' && m.toolCallsJson != null);
      expect(assistantWithTools.isNotEmpty, isTrue);

      final toolCalls = jsonDecode(assistantWithTools.first.toolCallsJson!)
          as List<dynamic>;
      expect(toolCalls.length, 1);

      final tc = toolCalls[0] as Map<String, dynamic>;
      // Task 18.T3 requires verifying specific fields: id, name, input, status, result
      expect(tc['id'], isA<String>());
      expect(tc['id'], isNotEmpty);
      expect(tc['name'], 'read_file');
      expect(tc['input'], isA<Map>());
      expect(tc['status'], isA<String>());
      expect(tc['status'], anyOf('done', 'executing'));
      expect(tc.containsKey('result'), isTrue);
    });

    // 18.T4 — Tool cards restored when session is loaded from MessageRepository
    testWidgets('tool cards restored on session load', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // Pre-populate messages with toolCallsJson
      final msgWithTools = testMessageWithToolCalls(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: 'Let me read that for you.',
        toolCallsJson:
            '[{"id":"tc1","toolName":"read_file","input":{"path":"/test.txt"},"status":"done","result":"hello world","resultPreview":"hello world"}]',
      );
      final userMsg = testMessage(
        id: 'm0',
        sessionId: 's1',
        role: 'user',
        content: 'Read test.txt',
      );
      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository([userMsg, msgWithTools]);
      final sidecar = FakeSidecar();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Tool card is restored from persisted data
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('read_file'), findsOneWidget);
      // Assistant message content is visible
      expect(find.text('Let me read that for you.'), findsOneWidget);
    });

    // 4.4 — edit 的 hunks 存进消息再读回来，卡片仍能画出差异
    testWidgets('edit hunks survive persistence and re-render', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // 先构造活动对象、走 toJson 落库——这样"序列化分支丢了"会直接让本用例红。
      const original = ToolCallActivity(
        id: 'tc1',
        toolName: 'edit_file',
        input: {'path': '/a.txt'},
        status: ToolCallStatus.done,
        result: 'Edited /a.txt (2 replacements) — 第 12、40 行',
        resultPreview: 'Edited /a.txt (2 replacements) — 第 12、40 行',
        hunks: [
          EditHunk(startLine: 12, oldText: 'old twelve', newText: 'new twelve'),
          EditHunk(startLine: 40, oldText: 'old forty', newText: 'new forty'),
        ],
      );
      final msgWithTools = testMessageWithToolCalls(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '改好了。',
        toolCallsJson: jsonEncode([original.toJson()]),
      );
      final userMsg = testMessage(
        id: 'm0',
        sessionId: 's1',
        role: 'user',
        content: '编辑一下',
      );
      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository([userMsg, msgWithTools]);
      final sidecar = FakeSidecar();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // 存进去的 JSON 先过一遍 fromJson：字段一个不丢
      final stored = await msgRepo.queryBySession('s1');
      final withTools = stored.where(
          (m) => m.role == 'assistant' && m.toolCallsJson != null);
      final calls =
          jsonDecode(withTools.first.toolCallsJson!) as List<dynamic>;
      final activity =
          ToolCallActivity.fromJson(calls.first as Map<String, dynamic>);
      expect(activity.hunks, isNotNull);
      expect(activity.hunks!.length, 2);
      expect(activity.hunks![0].startLine, 12);
      expect(activity.hunks![1].oldText, 'old forty');

      // 卡片重开后仍能画出差异
      expect(find.byType(ToolCallCard), findsOneWidget);
      await tester.tap(find.text('Expand result'));
      await tester.pump();
      expect(find.text('第 12 行'), findsOneWidget);
      expect(find.text('第 40 行'), findsOneWidget);
      expect(find.text('- old twelve'), findsOneWidget);
      expect(find.text('+ new forty'), findsOneWidget);
    });

    // 18.T5 — Tool cards survive session switch and return
    testWidgets('tool cards survive session switch', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgWithTools = testMessageWithToolCalls(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: 'Here you go.',
      );
      final userMsg = testMessage(
        id: 'm0',
        sessionId: 's1',
        role: 'user',
        content: 'Read file',
      );
      final sessions = [
        testSession(id: 's1', title: 'Session 1'),
        testSession(id: 's2', title: 'Session 2'),
      ];
      final sessionRepo = FakeSessionRepository(sessions);
      final otherMsgs = [
        testMessage(id: 'o0', sessionId: 's2', role: 'user', content: 'Hello from s2'),
      ];
      final msgRepo = FakeMessageRepository([
        userMsg,
        msgWithTools,
        ...otherMsgs,
      ]);
      final sidecar = FakeSidecar();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Session 1 is loaded (first in list), tool card visible
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.text('Read file'), findsOneWidget);

      // Switch to session 2
      await tester.tap(find.text('Session 2'));
      await tester.pump();
      await tester.pump();

      // Session 2 has no tool cards
      expect(find.byType(ToolCallCard), findsNothing);
      expect(find.text('Hello from s2'), findsOneWidget);

      // Switch back to session 1
      await tester.tap(find.text('Session 1'));
      await tester.pump();
      await tester.pump();

      // Tool cards restored
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.text('Read file'), findsOneWidget);
      expect(find.textContaining('read_file'), findsOneWidget);
    });

    // 18.T6 — Complete multi-turn conversation restored
    testWidgets('multi-turn conversation with tool calls restored', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final msgs = [
        // Turn 1: user asks, assistant uses tool, gets result
        testMessage(
          id: 'm0', sessionId: 's1', role: 'user', content: 'Read config',
        ),
        testMessageWithToolCalls(
          id: 'm1', sessionId: 's1', role: 'assistant',
          content: 'Let me check.',
          toolCallsJson:
              '[{"id":"tc1","toolName":"read_file","input":{"path":"/config.json"},"status":"done","result":"{\\"version\\":1}","resultPreview":"{\\"version\\":1}"}]',
        ),
        testMessage(
          id: 'm2', sessionId: 's1', role: 'assistant',
          content: 'The config version is 1.',
        ),
        // Turn 2: follow-up question, another tool call
        testMessage(
          id: 'm3', sessionId: 's1', role: 'user', content: 'Also list dir',
        ),
        testMessageWithToolCalls(
          id: 'm4', sessionId: 's1', role: 'assistant',
          content: 'Let me list the directory.',
          toolCallsJson:
              '[{"id":"tc2","toolName":"list_dir","input":{"path":"."},"status":"done","result":"[\\"file1.txt\\"]","resultPreview":"[\\"file1.txt\\"]"}]',
        ),
        testMessage(
          id: 'm5', sessionId: 's1', role: 'assistant',
          content: 'The directory contains file1.txt.',
        ),
      ];
      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository(msgs);
      final sidecar = FakeSidecar();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Both tool cards restored at correct positions
      expect(find.byType(ToolCallCard), findsNWidgets(2));

      // All user messages visible
      expect(find.text('Read config'), findsOneWidget);
      expect(find.text('Also list dir'), findsOneWidget);

      // All assistant messages visible
      expect(find.text('Let me check.'), findsOneWidget);
      expect(find.text('The config version is 1.'), findsOneWidget);
      expect(find.text('Let me list the directory.'), findsOneWidget);
      expect(find.text('The directory contains file1.txt.'), findsOneWidget);

      // Both tool names visible
      expect(find.textContaining('read_file'), findsOneWidget);
      expect(find.textContaining('list_dir'), findsOneWidget);
    });

    // 7.4 — D7: no empty bubble for tool-only message on reload
    testWidgets('reload tool_use-only message produces no empty bubble', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      // Pre-populate with tool_use-only message (empty content + tool calls)
      final msgWithTools = testMessageWithToolCalls(
        id: 'm1',
        sessionId: 's1',
        role: 'assistant',
        content: '', // empty — tool_use-only response
        toolCallsJson:
            '[{"id":"tc1","toolName":"read_file","input":{"path":"/f.txt"},"status":"done","result":"ok"}]',
      );
      final userMsg = testMessage(
        id: 'm0', sessionId: 's1', role: 'user', content: 'Read file',
      );
      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository([userMsg, msgWithTools]);
      final sidecar = FakeSidecar();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Tool card restored from persisted data
      expect(find.byType(ToolCallCard), findsOneWidget);
      // D7: no empty ChatMessageItem rendered for the empty-content message
      final emptyAssistantBubbles = find.byWidgetPredicate(
        (w) => w is MessageBubble && w.role == 'assistant' && w.content.isEmpty,
      );
      expect(emptyAssistantBubbles, findsNothing);
    });
  });
}
