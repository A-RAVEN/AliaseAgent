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

/// `glob_file` / `grep_file` 被截断时，模型看到的那段正文要**可恢复**
/// （change `fix-silent-truncation`，tasks.md 8.3）。
///
/// 覆盖哪几件事（共用用例时要说清，否则"它到底测了啥"无法核对）：
///   1. 被截断时正文里有"只给了前 N 条"这句；
///   2. 正文里给了一个能直接照抄的取回写法（`max_results=<更大的值>`）；
///   3. **不声称总条数** —— C++ 侧收满 `max_results` 就掐断了搜索进程，`count` 就是
///      本次条数、不是总数；写成 "showing 3 of 3" 等于编一个总数，所以不许出现
///      `of <同一个数>` 这种写法。
///
/// 为什么用假 sidecar：这里验的是**界面组装那段正文**的行为（真实结果由 C++ 给），
/// 所以让假 sidecar 直接回一个"已截断"的结果即可，不必真跑 ripgrep。
void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  void setupRegistry() {
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
        'test': ProviderConfig(apiKey: 'sk-test', baseUrl: 'http://127.0.0.1:1'),
      },
    ));
  }

  /// 让模型先调一次工具，再取回它那一轮的 tool_result 正文。
  Future<String> toolResultBody(
    WidgetTester tester, {
    required String toolName,
    required Map<String, dynamic> input,
    required String stubResult,
  }) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final sidecar = FakeSidecar();
    if (toolName == 'glob_file') {
      sidecar.stubGlobFile(stubResult);
    } else {
      sidecar.stubGrepFile(stubResult);
    }
    // 第一轮：模型要调这个工具；第二轮：回一句结束。
    sidecar.queueToolCall(jsonEncode({
      'id': 'call_$toolName',
      'name': toolName,
      'input': input,
    }));
    sidecar.queueChunk('done');
    sidecar.queueDone();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: FakeSessionRepository(testSessions(1)),
          msgRepo: FakeMessageRepository(<Message>[]),
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '找一下');
    await tester.tap(find.byTooltip('Send'));
    // 工具轮要跑完：第一轮 → 执行工具 → 第二轮带着 tool_result 再发一次；第二轮那次
    // sendMessage 才是观察对象，所以多 pump 几拍。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final messages = jsonDecode(sidecar.lastMessagesJson ?? '[]') as List<dynamic>;
    final buf = StringBuffer();
    for (final m in messages) {
      final content = (m as Map)['content'];
      if (content is List) {
        for (final block in content) {
          if (block is Map && block['type'] == 'tool_result') {
            buf.writeln((block['content'] ?? '').toString());
          }
        }
      }
    }
    return buf.toString();
  }

  testWidgets('glob_file 被截断：说清只给了前 N 条 + 可照抄的取回写法，不编总数',
      (tester) async {
    final body = await toolResultBody(
      tester,
      toolName: 'glob_file',
      input: {'pattern': '*.dart', 'max_results': 3},
      // C++ 侧收满 max_results 就掐断 —— 所以 count 也等于 3（不是总数）
      stubResult: jsonEncode({
        'ok': true,
        'paths': ['a.dart', 'b.dart', 'c.dart'],
        'count': 3,
        'truncated': true,
      }),
    );

    // ignore: avoid_print
    print('[截断/glob] 模型看到的正文：\n$body');
    expect(body.isNotEmpty, isTrue,
        reason: '正文不许为空 —— 空了说明第二轮请求没发生，下面几条断言落在空串上，不算验过');
    expect(body, contains('truncated'), reason: '要标出被截断');
    expect(body, contains('only the first 3 entries are shown'),
        reason: '要说清本次给了几条');
    expect(body, contains('max_results=6'),
        reason: '要给一个能直接照抄的取回写法');
    expect(body.contains('of 3'), isFalse,
        reason: '不许写 "showing 3 of 3" —— count 就是本次条数，不是总数');
  });

  testWidgets('grep_file 被截断：同样给可照抄的取回写法，不编总数', (tester) async {
    final body = await toolResultBody(
      tester,
      toolName: 'grep_file',
      input: {'pattern': 'TODO', 'max_results': 2},
      stubResult: jsonEncode({
        'ok': true,
        'matches': [
          {'path': 'a.dart', 'line': 1, 'text': 'TODO one'},
          {'path': 'b.dart', 'line': 2, 'text': 'TODO two'},
        ],
        'count': 2,
        'truncated': true,
      }),
    );

    // ignore: avoid_print
    print('[截断/grep] 模型看到的正文：\n$body');
    expect(body.isNotEmpty, isTrue, reason: '正文不许为空（同 glob 那条的理由）');
    expect(body, contains('truncated'));
    expect(body, contains('only the first 2 matches are shown'));
    expect(body, contains('max_results=4'));
    expect(body, contains('narrow the pattern/glob'));
    expect(body.contains('of 2'), isFalse, reason: '同样不许编总数');
  });
}
