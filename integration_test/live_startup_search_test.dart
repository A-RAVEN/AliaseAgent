@Tags(['live'])
library;

// 启动就绪的真机验收（change `fix-silent-truncation`，tasks.md 6.5）。
//
// 要验的一件事：**界面刚起来、动态工具还没装好的那段窗口里，发送入口不许放行**。
// 6.3 的窗口用例已经在假 sidecar 上验过这条逻辑；这里用真机验"真的界面在真启动时
// 也是这个行为"，并且验"就绪之后搜索确实能用"。
//
// 为什么不在这里真发一条消息：启动那一瞬按钮是禁用的，`tester.tap` 点不动它 ——
// 这本身就是被验的现象。所以这一条断言的是：
//   ① 启动后立刻（只 pump 很短时间）看发送按钮：它处于禁用状态、提示为"正在准备工具…"；
//   ② 等就绪（按钮提示回到 Send）之后，模型确实拿到了 `web_search`：发一条要求搜索的
//      消息，断言工具卡走到 done。
//
// 跑法：
//   flutter test --tags live --run-skipped integration_test/live_startup_search_test.dart -d windows
// 跑完用读图工具看 `test/live_visual/livestart_t1.png`。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int timeoutSec = 240,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Widget not found within ${timeoutSec}s');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  bool hasCompleteConfig = false;
  bool hasSearchProvider = false;

  setUpAll(clearLiveVisualDir);

  final configResult = ConfigService.load();
  if (configResult.status == ConfigStatus.ok) {
    final c = configResult.config!;
    final general = c.agentTypes['general'];
    final provider = general != null ? c.providers[general.provider] : null;
    hasCompleteConfig = general != null &&
        provider != null &&
        provider.apiKey.isNotEmpty &&
        provider.baseUrl.isNotEmpty &&
        general.model.isNotEmpty;
    hasSearchProvider = (c.search?.containsKey('deepseek') ?? false) ||
        (c.search?.containsKey('zhipuai') ?? false) ||
        (c.search?.containsKey('kimi') ?? false);
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_livestart_');
    await DatabaseService.openAt(tempDir.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁：交给系统清理
      }
    }
  });

  testWidgets('启动窗口期发送被挡住；就绪后搜索可用', (tester) async {
    if (!hasCompleteConfig) {
      markTestSkipped('Incomplete config at ${ConfigService.configPath}');
      return;
    }
    if (!hasSearchProvider) {
      markTestSkipped('配置里没有任何搜索后端，就绪后也不会有 web_search —— 跳过');
      return;
    }

    final captureKey = GlobalKey();
    await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const MyApp()));

    // ---- ① 启动那一瞬：只 pump 两小步，尽量停在动态工具还没装好的窗口里 ----
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final preparing = find.byTooltip('正在准备工具…');
    final ready = find.byTooltip('Send');
    final sawUnready = preparing.evaluate().isNotEmpty;
    debugPrint('[启动就绪 live] 启动后立刻看：未就绪提示在场=$sawUnready、'
        '就绪提示在场=${ready.evaluate().isNotEmpty}');
    if (sawUnready) {
      final button = tester.widget<IconButton>(
        find.ancestor(of: find.byIcon(Icons.send), matching: find.byType(IconButton)),
      );
      expect(button.onPressed, isNull, reason: '未就绪时发送按钮必须是禁用的');
      debugPrint('[启动就绪 live] 未就绪窗口里发送按钮 onPressed=null（已断言）');
    } else {
      // 本机启动太快、两小步内就绪了 —— 那是"没问题"的一种表现，但这条断言就验不到。
      // 如实打印，不假装验过。
      debugPrint('[启动就绪 live] 本机启动过快，50ms×2 内已经就绪 ——'
          '未就绪窗口没抓到，这一半按"未能证明"记录');
    }

    try {
      // ---- ② 等就绪，然后发一条要求搜索的消息 ----
      await _pumpUntilFound(tester, find.byTooltip('Send'), timeoutSec: 60);
      debugPrint('[启动就绪 live] 已就绪（发送按钮提示回到 Send）');

      await tester.enterText(find.byType(TextField), '请用 web_search 搜一下「Flutter」');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      await _pumpUntilFound(
        tester,
        find.byWidgetPredicate((w) =>
            w is ToolCallCard &&
            w.activity.toolName == 'web_search' &&
            w.activity.status == ToolCallStatus.done),
        timeoutSec: 240,
      );
      final cards = tester
          .widgetList<ToolCallCard>(find.byType(ToolCallCard))
          .where((c) => c.activity.toolName == 'web_search')
          .toList();
      final body = cards.last.activity.result ?? '';
      debugPrint('[启动就绪 live] web_search 卡 done，结果正文长度=${body.length}');
      expect(body, isNotEmpty, reason: '就绪后 web_search 必须真的被调用并返回内容');
    } finally {
      await captureLiveShot(tester, captureKey, 'livestart_t1');
    }
  }, timeout: const Timeout(Duration(seconds: 420)));
}
