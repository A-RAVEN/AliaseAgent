// web_fetch 正文走 spill 交付通道的 Dart 侧端到端用例（change
// `migrate-web-fetch-to-spill` 任务 3.1 / 3.2）。
//
// 覆盖：
//   ① 请求带上配置值 `spill.preview_chars`（3.1：证明"传配置"而不是"传常量"）；
//   ② FakeSidecar 返回带 `spill.content` 信封的结果 ⇒ 交付正文最后一行是 spill
//      引用行、正文没有被旧的 2000 字符硬切动过（3.2 ①）；
//   ③ FakeSidecar 返回 19,806 字符、**没有信封**的结果 ⇒ 交付正文含全部 19,806
//      字符（3.2 ②：有人恢复 2000 硬切本用例必红）；
//   ④ 历史重放一轮带 spill 引用行的 web_fetch、正文超过通用省略阈值 8,000 ⇒
//      `tool_result` 经省略后仍保有取回入口（3.2 ③）；
//   ⑤ 空正文 ⇒ 仍给 `(fetched empty page)` 且无引用行（3.2 ④）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

/// 测试用的非缺省 `spill.preview_chars`（37）—— 用来证明请求里带的是"从配置读到的
/// 值"，而不是 C++ 侧缺省常量 1000。数值本身是测试构造值，不是产品限制。
const int kTestPreviewChars = 37;

const List<Map<String, String>> _searchProviders = [
  {'name': 'zhipuai', 'description': 'ZhipuAI search'},
];

/// 注册一个带 `web_fetch` 的 agent 模板；`web_fetch` 是动态工具，搜索 provider 在
/// 配置里有一份才能在工具目录里出现（与 search_e2e_test.dart 的 setup 同形）。
void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: 100000,
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

Widget _buildApp({
  required FakeSidecar sidecar,
  required FakeMessageRepository msgRepo,
  int previewChars = kTestPreviewChars,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: AppConfig(
          version: 1,
          search: const {
            'zhipuai': {'api_key': 'test-key'},
          },
          spillPreviewChars: previewChars,
        ),
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: msgRepo,
        sidecar: sidecar,
      ),
    ),
  );
}

/// 一轮完整的"发送 → 模型发一个 web_fetch 工具调用 → 工具结果交付 → 第二次请求"。
/// 等到 `sidecar.sendHandles` 出现第二条（第二次请求真的发出去了）再返回，避免用
/// 固定次数 pump 猜时序。
Future<void> _runOneWebFetchRound(
  WidgetTester tester,
  FakeSidecar sidecar, {
  int previewChars = kTestPreviewChars,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;

  await tester.pumpWidget(_buildApp(
    sidecar: sidecar,
    msgRepo: FakeMessageRepository(),
    previewChars: previewChars,
  ));
  await tester.pump();
  await tester.pump();

  await tester.enterText(find.byType(TextField), '抓取这个页面');
  await tester.tap(find.byTooltip('Send'));
  for (var i = 0; i < 20 && sidecar.sendHandles.length < 2; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(sidecar.sendHandles.length, greaterThanOrEqualTo(2),
      reason: '工具结果必须触发第二次请求（否则读不到交付给模型的正文）');
}

/// 重放一轮历史 `web_fetch`：`toolCallsJson` 里的结果会先经通用省略，再进请求体。
/// 返回最后一次请求体（`lastMessagesJson`）原文。
Future<String> _replayHistoricalWebFetch(
  WidgetTester tester, {
  required Map<String, dynamic> callInput,
  required String storedResult,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  final msgs = [
    Message(
      id: 'u1',
      seq: 1,
      sessionId: 's1',
      role: 'user',
      content: '抓一下那个长页面',
      createdAt: 1,
    ),
    Message(
      id: 'a1',
      seq: 2,
      sessionId: 's1',
      role: 'assistant',
      content: '好的。',
      toolCallsJson: jsonEncode([
        {
          'id': 'call_replay',
          'toolName': 'web_fetch',
          'name': 'web_fetch',
          'input': callInput,
          'result': storedResult,
        }
      ]),
      createdAt: 2,
    ),
    Message(
      id: 'a2',
      seq: 3,
      sessionId: 's1',
      role: 'assistant',
      content: '页面较长，我先总结要点。',
      createdAt: 3,
    ),
  ];
  final sidecar = FakeSidecar()
    ..stubSearchProviders(jsonEncode(_searchProviders))
    ..queueChunk('Reply')
    ..queueDone();
  await tester.pumpWidget(_buildApp(
    sidecar: sidecar,
    msgRepo: FakeMessageRepository(msgs),
  ));
  await tester.pump();
  await tester.pump();

  await tester.enterText(find.byType(TextField), '继续');
  await tester.tap(find.byTooltip('Send'));
  for (var i = 0; i < 20 && sidecar.sendHandles.isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(sidecar.sendHandles, isNotEmpty, reason: '重放必须走到一次真实的模型请求');
  return sidecar.lastMessagesJson ?? '';
}

/// 从最后一次请求体里取某个工具的那条 `tool_result` 正文（本轮交付，不经重放省略）。
String _toolResultTextOf(FakeSidecar sidecar, String toolName) {
  final raw = sidecar.lastMessagesJson ?? '[]';
  final list = jsonDecode(raw) as List<dynamic>;
  for (final m in list) {
    final content = (m as Map<String, dynamic>)['content'];
    if (content is! List) continue;
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      if (block['type'] != 'tool_result') continue;
      final c = block['content'];
      if (c is String) return c;
      if (c is List) {
        final parts = <String>[];
        for (final b in c) {
          if (b is Map && b['type'] == 'text') parts.add((b['text'] ?? '').toString());
        }
        return parts.join('\n');
      }
    }
  }
  throw StateError('最后一次请求里没有 $toolName 的 tool_result 正文');
}

/// 一次标准 web_fetch 工具调用事件（id 可区分不同用例）。
String _webFetchCallJson({required String id, required String url}) => jsonEncode({
      'id': id,
      'type': 'tool_use',
      'name': 'web_fetch',
      'input': {'url': url},
    });

void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  testWidgets('3.1 web_fetch 请求带上配置值 spill.preview_chars，url 不丢', (tester) async {
    _setupAgentRegistry();
    final sidecar = FakeSidecar()
      ..stubSearchProviders(jsonEncode(_searchProviders))
      ..stubWebFetch(jsonEncode({
        'ok': true,
        'url': 'https://example.com/a',
        'title': 'A',
        'content': 'short content',
      }))
      ..queueChunk('我来抓取。')
      ..queueToolCall(_webFetchCallJson(id: 'call_req', url: 'https://example.com/a'))
      ..queueDone();

    await _runOneWebFetchRound(tester, sidecar);

    final calls = sidecar.callsOf('web_fetch');
    expect(calls, hasLength(1));
    final request = jsonDecode(calls.single.requestJson) as Map<String, dynamic>;
    // ignore: avoid_print
    print('  [OBS] web_fetch requestJson=${calls.single.requestJson}');
    expect(request['preview_chars'], kTestPreviewChars,
        reason: '请求必须带配置里的 spill.preview_chars（37），不是缺省 1000');
    expect(request['url'], 'https://example.com/a', reason: '原有 url 字段不许丢');
  });

  testWidgets('3.2① 带 spill 信封的长正文：最后一行是引用行、正文未被 2000 硬切',
      (tester) async {
    _setupAgentRegistry();
    // 引用路径与正文都是测试构造值（模拟 C++ 侧已形状化的交付）。
    const ref = r'C:\Users\me\.aliasagent\spill\s1\000001-content.txt';
    final headPart = 'H' * 1000;
    final tailPart = 'T' * 1000;
    final shaped = '$headPart\n[... 17806 bytes omitted of 19806; full output: $ref — '
        'read it back with read_spill (ref, offset=1000, limit=17806)]\n$tailPart';
    final sidecar = FakeSidecar()
      ..stubSearchProviders(jsonEncode(_searchProviders))
      ..stubWebFetch(jsonEncode({
        'ok': true,
        'url': 'https://example.com/long',
        'title': '长页面',
        'content': shaped,
        'truncated': true,
        'spill': {
          'content': {
            'ref': ref,
            'total_bytes': 19806,
            'omitted_bytes': 17806,
            'head': headPart,
            'tail': tailPart,
          },
        },
      }))
      ..queueChunk('抓取长页面。')
      ..queueToolCall(_webFetchCallJson(id: 'call_long', url: 'https://example.com/long'))
      ..queueDone();

    await _runOneWebFetchRound(tester, sidecar);
    final delivered = _toolResultTextOf(sidecar, 'web_fetch');
    final lines = delivered.split('\n');
    // ignore: avoid_print
    print('  [OBS] deliveredChars=${delivered.length} lastLine=${lines.last}');

    // 第一行标题、第二行网址（delta spec「web_fetch 结果交付给模型的形态」第 1 项）。
    expect(lines[0], '长页面');
    expect(lines[1], 'https://example.com/long');
    // 第 3 项：落了盘时**最后一行**是 spill 引用行。
    expect(lines.last, startsWith('[spill refs:'));
    expect(lines.last, contains('read_spill(ref, offset, limit)'));
    expect(lines.last, contains('19806 bytes, 17806 omitted'));
    // 正文就是 C++ 交回的形状文本（约 2,150 字符）：旧的 2000 硬切会让这条红。
    expect(delivered, contains(shaped),
        reason: '正文必须是完整形状文本，而不是它的前 2000 个字符');
  });

  testWidgets('3.2② 无信封的 19,806 字符正文完整交付（恢复 2000 硬切必红）', (tester) async {
    _setupAgentRegistry();
    // 中段标记落在第 9,805 个字符之后 —— 2000 硬切一定把它切掉。
    final body = 'HEAD-${'a' * 9800}MIDDLE-MARKER${'b' * 9983}-TAIL';
    expect(body.length, 19806);  // 5 + 9800 + 13 + 9983 + 5
    final sidecar = FakeSidecar()
      ..stubSearchProviders(jsonEncode(_searchProviders))
      ..stubWebFetch(jsonEncode({
        'ok': true,
        'url': 'https://example.com/legacy',
        'title': '旧形态页面',
        'content': body,
      }))
      ..queueChunk('抓取。')
      ..queueToolCall(
          _webFetchCallJson(id: 'call_noenv', url: 'https://example.com/legacy'))
      ..queueDone();

    await _runOneWebFetchRound(tester, sidecar);
    final delivered = _toolResultTextOf(sidecar, 'web_fetch');
    // ignore: avoid_print
    print('  [OBS] deliveredChars=${delivered.length} hasMiddle='
        '${delivered.contains('MIDDLE-MARKER')} hasRefs=${delivered.contains('[spill refs:')}');
    expect(delivered, contains(body),
        reason: '没有信封的结果必须整段交付（2000 硬切会掐掉 MIDDLE-MARKER 之后的内容）');
    expect(delivered.length, greaterThan(body.length));
    expect(delivered, isNot(contains('[spill refs:')),
        reason: '没有 spill 信封时不产生引用行');
  });

  testWidgets('3.2③-a 重放带引用行的历史 web_fetch，通用省略后引用行仍在', (tester) async {
    _setupAgentRegistry();
    const ref = r'C:\Users\me\.aliasagent\spill\s1\000001-content.txt';
    final shapedBody = '${'H' * 5000}\n'
        '[... 2000 bytes omitted of 12000; full output: $ref — read it back with '
        'read_spill (ref, offset=5000, limit=2000)]\n${'T' * 5000}';
    final stored = '示例页面\nhttps://example.com/long\n$shapedBody\n'
        '[spill refs: content=$ref (12000 bytes, 2000 omitted) — read any byte '
        'range back with read_spill(ref, offset, limit)]';
    // ignore: avoid_print
    print('  [OBS] replay(a) storedChars=${stored.length}');
    // 前置条件：这一段真的超过通用省略阈值（8,000），否则测不到省略分支。
    expect(stored.length, greaterThan(8000));

    final projected = await _replayHistoricalWebFetch(
      tester,
      callInput: {'url': 'https://example.com/long'},
      storedResult: stored,
    );
    // ignore: avoid_print
    print('  [OBS] replay(a) elided=${projected.contains('tool_result body elided')} '
        'hasRefs=${projected.contains('[spill refs:')}');
    expect(projected, contains('tool_result body elided'));
    expect(projected, contains('[spill refs:'),
        reason: '引用行在最后一行，通用省略保尾时必须活下来');
  });

  testWidgets('3.2③-b 重放的历史 web_fetch 没有网址：尾注必须指向 read_spill',
      (tester) async {
    _setupAgentRegistry();
    const ref = r'C:\Users\me\.aliasagent\spill\s1\000001-content.txt';
    final shapedBody = '${'H' * 5000}\n'
        '[... 2000 bytes omitted of 12000; full output: $ref — read it back with '
        'read_spill (ref, offset=5000, limit=2000)]\n${'T' * 5000}';
    final stored = '示例页面\nhttps://example.com/long\n$shapedBody\n'
        '[spill refs: content=$ref (12000 bytes, 2000 omitted) — read any byte '
        'range back with read_spill(ref, offset, limit)]';

    // 历史 tool_call 没有可用网址（构造场景：专门核对 `bodyHasSpillRefs` 这条尾注）。
    // 把尾注拼成"请重新给出地址"的错实现会让这条红。
    final projected = await _replayHistoricalWebFetch(
      tester,
      callInput: <String, dynamic>{},
      storedResult: stored,
    );
    // ignore: avoid_print
    print('  [OBS] replay(b) elided=${projected.contains('tool_result body elided')} '
        'hasReadSpillNote=${projected.contains('中间的原文可用 read_spill')}');
    expect(projected, contains('tool_result body elided'));
    // 尾注原文是 `; 中间的原文可用 read_spill(ref, offset, limit) 读回（ref 见上面那行
    // spill refs）` —— 断言"指向 read_spill 读回"这个可执行指引，而不是要求模型重新给地址。
    expect(projected, contains('中间的原文可用 read_spill(ref, offset, limit) 读回'),
        reason: '正文里已有 spill 引用时，尾注必须指向 read_spill，而不是让模型重新给地址');
    expect(projected, isNot(contains('请重新给出地址')));
  });

  testWidgets('3.2④ 空正文 ⇒ (fetched empty page)、无引用行', (tester) async {
    _setupAgentRegistry();
    final sidecar = FakeSidecar()
      ..stubSearchProviders(jsonEncode(_searchProviders))
      ..stubWebFetch(jsonEncode({
        'ok': true,
        'url': 'https://example.com/empty',
        'title': '',
        'content': '',
        // 即使 C++ 侧给了空内容的信封，空正文也不许产生引用行（规范第 4 项）。
        'spill': {
          'content': {
            'ref': r'C:\Users\me\.aliasagent\spill\s1\000002-content.txt',
            'total_bytes': 0,
            'omitted_bytes': 0,
          },
        },
      }))
      ..queueChunk('抓取。')
      ..queueToolCall(
          _webFetchCallJson(id: 'call_empty', url: 'https://example.com/empty'))
      ..queueDone();

    await _runOneWebFetchRound(tester, sidecar);
    final delivered = _toolResultTextOf(sidecar, 'web_fetch');
    // ignore: avoid_print
    print('  [OBS] empty delivered=${jsonEncode(delivered)}');
    expect(delivered, contains('(fetched empty page)'));
    expect(delivered, isNot(contains('[spill refs:')));
  });
}
