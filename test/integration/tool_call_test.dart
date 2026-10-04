import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/ui/message_bubble.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

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
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

void main() {
  group('Tool call flow', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('tool call flow completes without error', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..queueToolCall('{"name":"list_dir","input":{"path":"/test"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
      ));
      await tester.pump();
      await tester.pump();

      // Send a message that triggers a tool call
      await tester.enterText(find.byType(TextField), 'List files');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Flow completed without error — no error text in the message list
      expect(find.textContaining('Error:'), findsNothing);
      // User message was inserted
      expect(find.text('List files'), findsOneWidget);
    });

    testWidgets('tool call with read_file stub completes without error', (tester) async {
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

      // Flow completed without error — no error text in the message list
      expect(find.textContaining('Error:'), findsNothing);
      // User message was inserted
      expect(find.text('Read file'), findsOneWidget);
    });

    // 18.T1 — Tool card appears during streaming
    testWidgets('tool card appears during streaming', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubReadFile('{"ok":true,"content":"hello world"}')
        ..queueChunk('Let me check that file...')
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
      await tester.pump();
      await tester.pump();

      // Tool call card appears during streaming
      expect(find.byType(ToolCallCard), findsOneWidget);
      // Tool name visible
      expect(find.textContaining('read_file'), findsOneWidget);
    });

    // 7.3 — D5 + D8: no empty bubble for tool_use-only response
    testWidgets('tool_use-only response produces no empty bubble', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubReadFile('{"ok":true,"content":"file content"}')
        ..queueToolCall('{"name":"read_file","input":{"path":"/test.txt"}}')
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

      // Tool card visible and done
      expect(find.byType(ToolCallCard), findsOneWidget);
      // No empty assistant bubble (D5: no ChatStreamingItem, D8: no ChatMessageItem)
      final emptyAssistantBubbles = find.byWidgetPredicate(
        (w) => w is MessageBubble && w.role == 'assistant' && w.content.isEmpty,
      );
      expect(emptyAssistantBubbles, findsNothing);
    });

    // 11.5 — write_file through ChatScreen+FakeSidecar
    testWidgets('write_file tool call completes without error', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubWriteFile('{"ok":true,"bytes_written":5,"created":true}')
        ..queueToolCall('{"name":"write_file","input":{"path":"/new.txt","content":"hello"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Write file');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('write_file'), findsOneWidget);
    });

    // 11.5 — edit_file through ChatScreen+FakeSidecar
    testWidgets('edit_file tool call completes without error', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubEditFile('{"ok":true,"replacements":1}')
        ..queueToolCall('{"name":"edit_file","input":{"path":"/test.txt","edits":[{"old_text":"a","new_text":"b"}]}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Edit file');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('edit_file'), findsOneWidget);
    });

    // glob_file dispatch through ChatScreen+FakeSidecar
    testWidgets('glob_file tool call completes without error', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubGlobFile('{"ok":true,"paths":["lib/main.dart","lib/models/app_config.dart"],"count":2}')
        ..queueToolCall('{"name":"glob_file","input":{"pattern":"lib/**/*.dart"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Find files');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('lib/main.dart'), findsWidgets);
    });

    // grep_file dispatch through ChatScreen+FakeSidecar
    testWidgets('grep_file tool call completes without error', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubGrepFile('{"ok":true,"matches":[{"path":"lib/main.dart","line":42,"text":"TODO: fix"}],"count":1}')
        ..queueToolCall('{"name":"grep_file","input":{"pattern":"TODO"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Search TODO');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      expect(find.textContaining('Error:'), findsNothing);
      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('TODO: fix'), findsWidgets);
    });

    // run_command dispatch through ChatScreen+FakeSidecar（change add-command-tool，
    // tasks.md 6.3）。覆盖哪几件事：①组装出的请求里真的带上四个配置值（5.4 的接线
    // 在这里被穿到，**这一条是"配置值有没有传下去"的唯一判据** —— 集成测试里那条
    // "配置改小后输出变短"用的是工具入参，管不到配置）；②命令输出渲染到界面上。
    // 这条不依赖真实动态库，是日常回归里跑得最快的一条。
    testWidgets('run_command 的成功结果与四个配置值都到位', (tester) async {
      // 把上限配成一个**非缺省、可区分**的值：真传下去了才会看到 1234，
      // 没传下去就会是代码里写死的缺省值 8000。注册表与 provider 解析器都要摆好
      // （`_setupAgentRegistry` 会先 clear，所以这里单独写一份带命令配置的）。
      registry.clear();
      registry.register(const AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'test-model',
        systemPrompt: '',
        tools: ['read_file', 'list_dir'],
        commandMaxOutputChars: 1234,
      ));
      resolver = ProviderResolver(const AppConfig(
        version: 1,
        providers: {
          'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
        },
      ));
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubRunCommand('{"ok":true,"exit_code":0,"stdout":"COMMAND-OK\\n",'
            '"stderr":"","timed_out":false,"duration_ms":12,'
            '"truncated":{"stdout":false,"stderr":false}}')
        ..queueToolCall('{"name":"run_command","input":{"command":"echo hi"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Run it');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      final sent = sidecar.lastRunCommandRequest;
      // ignore: avoid_print
      print('[命令工具/假sidecar] 组装出的请求: $sent');
      expect(sent, isNotNull);
      expect(sent, contains('"timeout_ms":120000'));
      expect(sent, contains('"max_timeout_ms":600000'));
      expect(sent, contains('"max_output_chars":1234'),
          reason: '配置里的 1234 必须出现在请求里；出现 8000 就说明配置没传下去');
      expect(sent, contains('"full_output_chars":2000000'));

      expect(find.byType(ToolCallCard), findsOneWidget);
      expect(find.textContaining('COMMAND-OK'), findsWidgets);
    });

    // 6.3 的另一半：非零退出码与 stderr 都要渲染出来（覆盖"工具执行 → 渲染"里
    // 那两条带标记的分支）。
    testWidgets('run_command 的非零退出码与 stderr 都渲染出来', (tester) async {
      _setupAgentRegistry();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;

      final sessions = testSessions(1);
      final sessionRepo = FakeSessionRepository(sessions);
      final msgRepo = FakeMessageRepository();
      final sidecar = FakeSidecar()
        ..stubRunCommand('{"ok":true,"exit_code":7,"stdout":"BUILD-FAILED\\n",'
            '"stderr":"boom: detail\\n","timed_out":false,"duration_ms":34,'
            '"truncated":{"stdout":false,"stderr":false}}')
        ..queueToolCall('{"name":"run_command","input":{"command":"build"}}')
        ..queueDone();

      await tester.pumpWidget(_buildApp(
        sessionRepo: sessionRepo, msgRepo: msgRepo, sidecar: sidecar,
      ));
      await tester.pump(); await tester.pump();

      await tester.enterText(find.byType(TextField), 'Build it');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(); await tester.pump();

      expect(find.textContaining('BUILD-FAILED'), findsWidgets);
      expect(find.textContaining('boom: detail'), findsWidgets);
      expect(find.textContaining('[exit code: 7]'), findsWidgets);
    });
  });
}
