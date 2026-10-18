@Tags(['live'])
library;

// 8.6（环）视觉验收：**真实**发一条消息，看环有没有出现在顶部工具栏右侧、
// 「对话视图 / 真实上下文」是否仍在原位、点开后面板里的数字与来源标注是否可读。
//
// 跑法：`flutter test --tags live --run-skipped integration_test/live_context_ring_test.dart -d windows`
// 跑完**必须**用读图工具看 `test/live_visual/livecontextring_t1.png` —— 只看 "All tests passed"
// 不算过（CLAUDE.md 的验证清单第 3 条）。
//
// 断言之前先把环上三段与合计的实际读数打出来（测试输出必须可观察）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/context_ring.dart';

import '../test/integration/helpers/screenshot_utils.dart';
import 'live_observability.dart';

/// 等这一轮对话真的结束（`ChatArea.isStreaming` 转 false）。
///
/// 与 `live_command_tool_test.dart` 里同名函数一致：live 绑定要求收尾时没有挂起的帧，
/// 所以只能用这种"推进一秒、看一眼"的循环，不能自己攒状态。
Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 180}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('对话在 $timeoutSec 秒内没有结束');
}

/// 等某个控件出现（与 `live_command_tool_test.dart` 里同名函数一致）。
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('控件在 $timeoutSec 秒内没有出现');
}

const String _shotPath = 'test/live_visual/livecontextring_t1.png';

/// 这条用例真调模型：发一条短消息，等环出现。
const String _prompt = '你好，请只回复两个字：收到。';

void main() {
  setUpAll(() {
    // `integration_test` 跑的是**测试自己的** `main()`，`lib/main.dart` 里那两行
    // 初始化从没执行过；而 `sqfliteFfiInit()` 本身**不会**设置全局 `databaseFactory`，
    // 不补第二行，一开数据库就抛 `Bad state: databaseFactory not initialized`
    // （本用例第二版就是这么挂的，连截图都没走到）。仓库里碰数据库的 live 用例都这么写。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    clearLiveVisualDir();
  });

  testWidgets('live 占用环：出现、位置、点开面板可读', (tester) async {
    final loaded = ConfigService.load();
    final config = loaded.config;
    if (config == null) {
      markTestSkipped('配置读不出来（${ConfigService.configPath}）：${loaded.error}');
      return;
    }
    final agent = config.agentTypes['general'];
    final provider = agent == null ? null : config.providers[agent.provider];
    if (agent == null ||
        provider == null ||
        provider.apiKey.isEmpty ||
        provider.baseUrl.isEmpty) {
      markTestSkipped('配置不完整（${ConfigService.configPath}）：'
          'general 这个 agent 需要 api_key + base_url + model 三样都填');
      return;
    }

    final captureKey = GlobalKey();
    await tester
        .pumpWidget(RepaintBoundary(key: captureKey, child: const MyApp()));
    await tester.pump(const Duration(seconds: 2));

    // 发送之前：还没捕获过快照 ⇒ 环渲染成不占高度的空盒子（design D7）。
    final before = tester.widget<ContextRing>(find.byType(ContextRing));
    // ignore: avoid_print
    print('  [OBS] 发送前 breakdown=${before.breakdown}');

    expect(find.byType(TextField), findsOneWidget, reason: 'Chat 输入框');
    await tester.enterText(find.byType(TextField), _prompt);
    // 真实应用启动时要先把动态工具装好；没装好之前发送按钮的提示是「正在准备工具…」，
    // 不是 'Send'（`lib/ui/chat_area.dart` 第 228 行：`tooltip: widget.toolsReady ? 'Send' : ...`）。
    // 所以先等它变出来，再点 —— 本用例第三版就是在这里找不到控件挂掉的。
    await _pumpUntilFound(tester, find.byTooltip('Send'), timeoutSec: 60);
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    // 等真实模型回完（最多 180 秒）。**不要自己搓 pump 循环** —— live 绑定在收尾时
    // 要求没有挂起的帧，手搓的循环会让 postTest 断言 `_pendingFrame == null` 失败
    // （本用例第一版就是这么挂的，截图都没走到）。照抄仓库既有的写法。
    await _waitForTurnComplete(tester);

    final ring = tester.widget<ContextRing>(find.byType(ContextRing));
    final b = ring.breakdown;
    // ignore: avoid_print
    print('  [OBS] 发送后 '
        'level2=${b?.level2Tokens} level1=${b?.level1Tokens} '
        'raw=${b?.rawTokens} 固定=${b?.fixedOverheadTokens} '
        '窗口=${b?.windowTokens} 合计=${b?.usedTokens} 环上三段=${b?.ringSegments.length}');

    expect(b, isNotNull, reason: '真实发送一次之后必须有占用拆分');

    // 「对话视图 / 真实上下文」这一行还在，环在它右边（5.3 的接线）。
    expect(find.text('对话视图'), findsOneWidget, reason: '视图切换按钮仍在原位');
    expect(find.text('真实上下文'), findsOneWidget);
    final ringX = tester.getTopLeft(find.byType(ContextRing)).dx;
    final buttonX = tester.getTopLeft(find.text('对话视图')).dx;
    // ignore: avoid_print
    print('  [OBS] 环的左边距=$ringX 对话视图按钮的左边距=$buttonX');
    expect(ringX, greaterThan(buttonX), reason: '环必须在按钮右侧');

    // 截图（工具栏那一屏），供主循环目视。
    await captureWidgetAsPng(captureKey, _shotPath);
    // ignore: avoid_print
    print('  [OBS] 截图已写到 $_shotPath');

    // 点开面板，把里面的文字打出来（数字与来源标注可读）。
    await tester.tap(find.byType(ContextRing));
    await tester.pumpAndSettle();

    // 9.9：面板开好之后**再截一张图** —— 8.6 那次只截了开面板之前的那张，所以
    //"面板可读"只能用组件转储核；这一张专门用图来核。
    const String panelShotPath = 'test/live_visual/livecontextring_t2.png';
    await captureWidgetAsPng(captureKey, panelShotPath);
    // ignore: avoid_print
    print('  [OBS] 面板截图已写到 $panelShotPath');
    final texts = <String>[];
    for (final w in tester.widgetList<Text>(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Text),
    ))) {
      if (w.data != null) texts.add(w.data!);
    }
    // ignore: avoid_print
    print('  [OBS] 面板文本=$texts');

    expect(texts, contains('二级摘要'));
    expect(texts, contains('一级摘要'));
    expect(texts, contains('原文'));
    expect(texts, contains('合计'));
    expect(texts.any((t) => t.contains('实测')), isTrue, reason: '两行摘要要标实测');
    expect(texts.any((t) => t.contains('估算')), isTrue, reason: '原文与固定开销要标估算');
  });
}
