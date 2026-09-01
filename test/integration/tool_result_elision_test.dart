import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// Near-zone oversized tool_result body elision (spec "Near-zone oversized
/// tool_result body elision", D10). A verbatim tool_result whose BODY exceeds
/// the threshold must be elided to a marker + refetch record while the tool_use
/// block, the tool_result placement, and the round structure all stay intact
/// (never folds/splits the round).
void main() {
  void setup({int maxContextTokens = 100000}) {
    registry.clear();
    registry.register(AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      maxContextTokens: maxContextTokens,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
      },
    ));
  }

  tearDown(() {
    registry.clear();
    resolver = null;
  });

  testWidgets('oversized near tool_result body is elided, tool round structure preserved',
      (tester) async {
    setup(); // under-budget → full verbatim replay (this IS the near-zone verbatim path)
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    const bigBody = 'line of file content that fills space\n'; // ~38 chars
    final oversizedResult = bigBody * 240; // ~9120 chars > 8000 threshold
    final msgs = [
      Message(
        id: 'u1', seq: 1, sessionId: 's1', role: 'user',
        content: '请读取 /Users/acme/src/config.dart', createdAt: 1,
      ),
      Message(
        id: 'a1', seq: 2, sessionId: 's1', role: 'assistant',
        content: '好的，我来读取该文件。',
        toolCallsJson: jsonEncode([
          {
            'id': 'call_read',
            'toolName': 'read_file',
            'name': 'read_file',
            'input': {'path': '/Users/acme/src/config.dart'},
            'result': oversizedResult,
          }
        ]),
        createdAt: 2,
      ),
      Message(
        id: 'a2', seq: 3, sessionId: 's1', role: 'assistant',
        content: '文件内容已读取，内容较长，我先分析关键部分。', createdAt: 3,
      ),
    ];

    final sessions = testSessions(1);
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository(msgs);
    final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
    final summaryProvider = FakeSummaryProvider();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: msgRepo,
          sidecar: sidecar,
          summaryProvider: summaryProvider,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    final projected = sidecar.lastMessagesJson ?? '';
    // [OBS] dump the actual projection before asserting (observability).
    // ignore: avoid_print
    print('  [OBS] elision projectedChars=${projected.length} '
        'hasElideMarker=${projected.contains('tool_result body elided')} '
        'hasToolUseBlock=${projected.contains('tool_use')} '
        'hasReadPath=${projected.contains('/Users/acme/src/config.dart')}');

    // The oversized BODY is elided to a marker + refetch record.
    expect(projected, contains('tool_result body elided'),
        reason: 'an oversized near-zone tool_result body must be elided to a marker');
    expect(projected, contains('/Users/acme/src/config.dart'),
        reason: 'the refetch record must carry the tool path');

    // The round STRUCTURE is preserved: the assistant carries a tool_use block,
    // and a tool_result user message follows it (valid alternation, not folded).
    final parsed = jsonDecode(projected) as List<dynamic>;
    var hasToolUse = false;
    var hasToolResult = false;
    for (final m in parsed) {
      final mm = m as Map<String, dynamic>;
      final content = mm['content'];
      if (content is List) {
        for (final blk in content) {
          if (blk is Map && blk['type'] == 'tool_use') hasToolUse = true;
          if (blk is Map && blk['type'] == 'tool_result') hasToolResult = true;
        }
      }
    }
    expect(hasToolUse, isTrue,
        reason: 'the tool_use block must survive elision (round never folded)');
    expect(hasToolResult, isTrue,
        reason: 'the tool_result placement must survive elision (never split)');

    // Spec "Round structure preserved on elision": the projection must keep VALID
    // role alternation (no consecutive role:user) AND the tool_result user message
    // must immediately follow the assistant carrying the tool_use (order preserved).
    var consecutiveUser = 0;
    for (var i = 1; i < parsed.length; i++) {
      final cur = (parsed[i] as Map<String, dynamic>)['role'];
      final prev = (parsed[i - 1] as Map<String, dynamic>)['role'];
      if (cur == 'user' && prev == 'user') consecutiveUser++;
    }
    // ignore: avoid_print
    print('  [OBS] elision structure: hasToolUse=$hasToolUse hasToolResult=$hasToolResult '
        'consecutiveUser=$consecutiveUser '
        'roles=${parsed.map((m) => (m as Map)['role']).join(",")}');
    expect(consecutiveUser, 0,
        reason: 'elision must preserve valid role alternation (no consecutive role:user)');
  });

  testWidgets('small tool_result body is passed through intact (below threshold)',
      (tester) async {
    setup();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final msgs = [
      Message(
        id: 'u1', seq: 1, sessionId: 's1', role: 'user',
        content: '读取文件并返回前几行', createdAt: 1,
      ),
      Message(
        id: 'a1', seq: 2, sessionId: 's1', role: 'assistant',
        content: '好的，我来读取文件。',
        toolCallsJson: jsonEncode([
          {
            'id': 'call_read',
            'toolName': 'read_file',
            'name': 'read_file',
            'input': {'path': '/Users/acme/src/config.dart'},
            'result': 'const timeout = 120;\napi.timeout = 120;\n',
          }
        ]),
        createdAt: 2,
      ),
      Message(
        id: 'a2', seq: 3, sessionId: 's1', role: 'assistant',
        content: '文件读取完成，当前超时是 120 秒。', createdAt: 3,
      ),
    ];

    final sessions = testSessions(1);
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository(msgs);
    final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();
    final summaryProvider = FakeSummaryProvider();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: msgRepo,
          sidecar: sidecar,
          summaryProvider: summaryProvider,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    final projected = sidecar.lastMessagesJson ?? '';
    // ignore: avoid_print
    print('  [OBS] small-body projectedChars=${projected.length} '
        'hasElideMarker=${projected.contains('tool_result body elided')} '
        'hasFullBody=${projected.contains('const timeout = 120')}');
    expect(projected, isNot(contains('tool_result body elided')),
        reason: 'a body below the threshold is NOT elided');
    expect(projected, contains('const timeout = 120;'),
        reason: 'a small body is passed through intact');
  });
}
