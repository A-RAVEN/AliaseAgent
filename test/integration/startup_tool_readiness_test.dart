import 'dart:async';
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

/// 启动就绪门槛（change `fix-silent-truncation`，tasks.md 6.3 / 6.4）。
///
/// 覆盖哪几件事（共用用例时要说清，否则"它到底测了啥"无法核对）：
///   1. 动态工具还在探测时（假 sidecar 的 `browserAvailable()` 被一个 Completer 卡住），
///      点发送**不会**发出任何请求 —— 断言 `lastMessagesJson` 仍是 null；
///   2. 那一刻界面给的是可见原因：发送按钮被禁用、工具提示是"正在准备工具…"；
///   3. 症状要记准（6.4）：未就绪时清单里**有**那 8 个本地工具、**没有** `web_search`
///      —— 不是"清单为空"。这条断言写在测到的实际内容上（`web_search` 缺席 + 若干本地
///      工具在场），不是照着文档抄一遍；
///   4. 探测返回之后发送恢复可用，且那一轮请求里的工具名集合**完整**（含 `web_search`）。
///
/// 为什么用 Completer 而不是延迟时长：`pump()` 是手动的，等不到真实时钟；卡住一个
/// Future 才能把"未就绪那一瞬"稳定地摆出来。
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
        'test': ProviderConfig(
          apiKey: 'sk-test',
          baseUrl: 'https://api.deepseek.com/anthropic',
        ),
      },
    ));
  }

  Widget buildApp(FakeSidecar sidecar) => MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            config: const AppConfig(version: 1),
            sessionRepo: FakeSessionRepository(testSessions(1)),
            msgRepo: FakeMessageRepository(),
            sidecar: sidecar,
          ),
        ),
      );

  testWidgets('动态工具没探完之前不许发：请求不发、按钮禁用并给出原因', (tester) async {
    setupRegistry();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    final gate = Completer<void>();
    final sidecar = FakeSidecar()
      ..browserAvailableGate = gate
      // 一个后端可用 → 就绪之后 web_search 应当出现在工具清单里
      ..stubSearchProviders('[{"name":"deepseek","description":"DeepSeek Web Search"}]')
      ..stubBrowserAvailable('{"ok":true,"available":false,"error":"no Edge"}')
      ..queueDone();

    await tester.pumpWidget(buildApp(sidecar));
    await tester.pump();
    await tester.pump();

    // ---- 未就绪那一瞬（6.3 ①、②）----
    final sendButton = find.byTooltip('正在准备工具…');
    expect(sendButton, findsOneWidget,
        reason: '未就绪时发送按钮的提示要写明原因（不是静默禁用）');
    final iconButton = tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(IconButton)),
    );
    expect(iconButton.onPressed, isNull, reason: '未就绪时发送按钮必须是禁用的');

    await tester.enterText(find.byType(TextField), '帮我搜一下');
    // ignore: avoid_print
    print('[就绪门槛] 未就绪时点发送前的 lastMessagesJson=${sidecar.lastMessagesJson}');
    await tester.tap(find.byIcon(Icons.send), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    // ignore: avoid_print
    print('[就绪门槛] 未就绪时点发送后的 lastMessagesJson=${sidecar.lastMessagesJson}');
    expect(sidecar.lastMessagesJson, isNull,
        reason: '未就绪时不许发出任何请求（那会带着残缺的工具清单）');

    // ---- 6.4 的真断言：直接读界面此刻持有的工具清单 ----
    final state = tester.state<ChatScreenState>(find.byType(ChatScreen));
    final unreadyNames = state.currentToolNames();
    // ignore: avoid_print
    print('[就绪门槛] 未就绪那一刻的工具清单（${unreadyNames.length} 个）：$unreadyNames');
    expect(state.toolsReady, isFalse, reason: '这一刻就是"未就绪"');
    // 本地那 9 个：在 await 之前就同步装好了，所以**清单不是空的**
    // （第 9 个是 `read_spill`，change spill-large-tool-output 加进来的本地工具）
    for (final local in const [
      'read_file', 'write_file', 'edit_file', 'list_dir',
      'get_current_time', 'glob_file', 'grep_file', 'run_command',
      'read_spill',
    ]) {
      expect(unreadyNames, contains(local),
          reason: '本地工具 $local 在 await 之前就装好了，未就绪那一刻必须在场');
    }
    // 动态那批：await 之后才加，未就绪那一刻**必须还不在**
    expect(unreadyNames, isNot(contains('web_search')),
        reason: 'web_search 是 await 之后才加进清单的 —— 未就绪那一刻不该有');
    expect(unreadyNames, isNot(contains('web_fetch')),
        reason: 'web_fetch 同上');
    expect(unreadyNames.length, 10,
        reason: '未就绪那一刻恰好是"10 个本地工具"这种残缺状态（不是空清单、也不是完整清单）');

    // ---- 放行探测，就绪 ----
    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final readyNames = state.currentToolNames();
    // ignore: avoid_print
    print('[就绪门槛] 就绪后的工具清单（${readyNames.length} 个）：$readyNames');
    expect(state.toolsReady, isTrue, reason: '探测返回后应当就绪');
    expect(readyNames, contains('web_search'));
    expect(readyNames, contains('web_fetch'));

    expect(find.byTooltip('Send'), findsOneWidget, reason: '就绪后按钮恢复可用');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    final sent = sidecar.lastMessagesJson ?? '';
    final sentTools = jsonDecode(sidecar.lastToolsJson ?? '[]') as List<dynamic>;
    final names = sentTools.map((t) => (t as Map)['name'] as String).toList();
    // ignore: avoid_print
    print('[就绪门槛] 就绪后发出的工具清单（${names.length} 个）：$names');

    expect(sent, isNotEmpty, reason: '就绪后发送要真的发出去');
    expect(names, contains('web_search'),
        reason: '就绪后那一轮请求的工具清单必须完整（含 web_search）');
    // 6.4 的症状核对走**清单构成的对照**：就绪后是 12 个（10 个本地 + web_search +
    // web_fetch），而那两个动态工具是在 await 之后才加进 `base` 的（源码顺序：
    // `await browserAvailable()` → `hasProviders` → `base['web_search']` / `base['web_fetch']`）。
    // 也就是说挡住的那一瞬，"动态那批"确实还没进清单 —— 这是这条用例能给出的最强证据：
    // 未就绪时**一个请求都没发**（上一段那条断言），因此不存在"带着残缺清单发出去"的情况。
    expect(names.length, 12,
        reason: '完整清单 = 10 个本地工具 + web_search + web_fetch');
    expect(names, contains('read_file'));
    expect(names, contains('run_command'));
    expect(names, contains('read_image'),
        reason: 'read_image 是本地工具，未就绪那一刻就在场（add-image-input）');
  });
}
