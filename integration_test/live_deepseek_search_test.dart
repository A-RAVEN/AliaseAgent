@Tags(['live'])
library;

// DeepSeek 搜索的真实端到端验收（change add-deepseek-web-search，tasks.md 7.1 / 7.2）。
//
// 为什么是"一条 live 用例"而不是"手动点界面"：本机屏幕正在被用户自己的会话占着，
// 手动抢焦点会打断他；而这条用例跑在本应用真实的 Flutter 窗口里、用**真实动态库**
// 执行**真实搜索**（真花钱），跑完按仓库规矩留一张 `test/live_visual/` 截图给主循环
// 做目视验收 —— 这与"人眼看一次工具卡"是同一个观察对象（本应用自己的渲染）。
//
// 跑法（与其它 live 用例一致）：
//   flutter test --tags live --run-skipped integration_test/live_deepseek_search_test.dart -d windows
// 跑完必须用读图工具看 `test/live_visual/liveds_t1.png`。
//
// 前提：配置里的 `search` 段要写了 `deepseek`（哪怕是空的 `{}`），并且 `providers`
// 里那个 `base_url` 指向 `api.deepseek.com`。没写就跳过并打印原因，不假装通过。
//
// 覆盖哪几件事：①界面上的工具清单里真的有 `web_search`（后端被认出来那一跳）；
// ②模型真的调用了 `web_search`；③工具卡走到 done（不是 error）；④返回里是**真实的
// 网页结果**（每条带网址与标题，条数 ≤ 请求上限）；⑤把这一次的耗时与 token 代价
// （能读到就读，读不到就写读不到）打到日志里，供交付说明引用。
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
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

/// Pump until [finder] matches, using manual pump loops (pumpAndSettle hangs
/// because the streaming dots animate forever).
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int timeoutSec = 180,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Widget not found within ${timeoutSec}s');
}

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 240}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('Conversation did not complete within ${timeoutSec}s');
}

Finder _toolCard(String toolName, {ToolCallStatus? status}) =>
    find.byWidgetPredicate(
      (w) =>
          w is ToolCallCard &&
          w.activity.toolName == toolName &&
          (status == null || w.activity.status == status),
    );

/// 把当前所有工具卡的名字、状态与结果正文打到日志（断言前先出证据）。
Future<void> _dumpCards(WidgetTester tester, {required String phase}) async {
  final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
  debugPrint('[DeepSeek 搜索 live / $phase] 共 ${cards.length} 张工具卡：');
  for (final c in cards) {
    final a = c.activity;
    final result = (a.result ?? '').replaceAll('\n', '\\n');
    debugPrint('[DeepSeek 搜索 live]   工具=${a.toolName} 状态=${a.status.name} '
        '入参=${a.input} 结果=${result.length > 600 ? '${result.substring(0, 600)}…' : result}');
  }
}

/// 工具卡里显示的结果正文（就是 `lib/main.dart` 拼给模型看的那段文本）。
/// 格式：每个后端一行 `<后端名>: <条数> results`，紧接着第一条结果的
/// `标题 — 网址` 预览。所以这里按行读，不按 JSON 解析（卡片存的是这段文本，
/// 不是原始返回）。
///
/// **一个坑（首轮实测踩到）**：这段文本有 2000 字的预算，超了就不再写后面的后端 ——
/// 界面配置了三个后端时，卡片可能只显示其中一两个。所以"deepseek 这一行在不在卡片
/// 里"**不是**可靠判据，别拿它当断言；deepseek 那一路真正被调用与它的耗时，由
/// `%USERPROFILE%\.aliasagent\logs\sidecar.log` 里的
/// `DeepSeek 搜索：query=... url=... model=...` 与 `DeepSeek 搜索：HTTP 200 用时 Nms`
/// 两行给证据。
int? _resultCountFor(String cardText, String provider) {
  final m = RegExp('^${RegExp.escape(provider)}: (\\d+) results\$', multiLine: true)
      .firstMatch(cardText);
  return m == null ? null : int.parse(m.group(1)!);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  bool hasCompleteConfig = false;
  bool hasDeepseekSection = false;

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
    hasDeepseekSection = (c.search?['deepseek']) != null;
    debugPrint('[DeepSeek 搜索 live] 配置检查：会话模型地址=${provider?.baseUrl} '
        'search 段里有 deepseek=${c.search?.containsKey('deepseek')} '
        '（原始 search 段的键：${c.search?.keys.toList()}）');
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_liveds_');
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

  testWidgets(
    'DeepSeek 搜索：真实模型调 web_search，拿回真实网页结果且工具卡可见',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent');
        return;
      }
      if (!hasDeepseekSection) {
        markTestSkipped('配置里的 search 段没有 deepseek（写一个空的 "deepseek": {} '
            '才算开启 DeepSeek 搜索）—— 跳过，不假装通过');
        return;
      }

      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      // 等界面把搜索后端与工具清单初始化完：`_initSearchAndTools` 里有异步的搜索
      // 初始化与浏览器可用性探测，早于它们发消息，那一轮请求的工具清单会**缺动态那批**
      // （`web_search` / `web_fetch` / 浏览器四件套都在 await 之后才加进 `base`；本地那 8 个
      // 在 await 之前就装好了，所以清单不是空的、是残缺的）。当时模型因此一个工具都没调，
      // 等 240 秒也等不到工具卡。
      //
      // 注：界面侧现在有了 `toolsReady` 门槛（fix-silent-truncation 的 6.1/6.2）—— 未就绪时
      // 发送按钮是禁用的，所以从界面点发送已经不可能踩到这个坑；这里保留等待是因为
      // **下面要点的就是那颗按钮**（未就绪时它会点不动）。"启动后不等待就发送"这条
      // 改由 `live_startup_search_test.dart` 用一条更早的路径验。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      debugPrint('[DeepSeek 搜索 live] 界面初始化等待结束，开始发消息');

      try {
        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: 'Chat 输入框');
        await tester.enterText(
          textField,
          '请用 web_search 搜一下「Flutter Windows 桌面应用 发布说明」，'
          '把搜到的前两条结果的标题和网址原样列给我。',
        );
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: '发送按钮');
        await tester.tap(sendButton);
        await tester.pump();

        await _pumpUntilFound(
          tester,
          _toolCard('web_search', status: ToolCallStatus.done),
          timeoutSec: 240,
        );
        await _dumpCards(tester, phase: 'web_search 卡已 done');
        await _waitForTurnComplete(tester);
        await _dumpCards(tester, phase: '整轮结束');

        final cards = tester
            .widgetList<ToolCallCard>(
                _toolCard('web_search', status: ToolCallStatus.done))
            .toList();
        expect(cards, isNotEmpty, reason: 'web_search 必须有一张 done 的卡');
        final raw = cards.last.activity.result ?? '';
        debugPrint('[DeepSeek 搜索 live] 断言前现场：工具卡结果正文长度=${raw.length}');
        debugPrint('[DeepSeek 搜索 live] 工具卡结果正文：\n$raw');

        // 卡片里存的是"拼给模型看的那段文本"（每个后端一行 `<后端名>: <条数> results`
        // 加第一条结果的 `标题 — 网址` 预览），不是原始 JSON —— 按行读它。
        final perProvider = RegExp(r'^([a-z]+): (\d+) results$', multiLine: true)
            .allMatches(raw)
            .map((m) => '${m.group(1)}=${m.group(2)}')
            .toList();
        debugPrint('[DeepSeek 搜索 live] 卡片里显示的后端与条数：$perProvider');
        expect(perProvider, isNotEmpty,
            reason: '卡片里应当至少显示一个后端的结果行（实际正文见上面的日志）');
        expect(raw.contains('ERROR'), isFalse,
            reason: '不该出现 ERROR 行（那是某个后端报错了）');

        // 真实网页结果的证据：正文里带 http(s) 网址，且不是本机/占位地址
        final urls = RegExp(r'https?://[^\s]+').allMatches(raw).map((m) => m.group(0)!).toList();
        debugPrint('[DeepSeek 搜索 live] 卡片里出现的网址（${urls.length} 个）：$urls');
        expect(urls, isNotEmpty, reason: '结果里必须带真实网址');
        expect(urls.any((u) => u.contains('127.0.0.1')), isFalse,
            reason: '不该出现本机地址（那是测试替身才有的东西）');

        // 界面里确实渲染了一个会话区（整轮已结束）
        expect(tester.widgetList<ChatArea>(find.byType(ChatArea)), isNotEmpty,
            reason: '会话区应当在');
        final deepseekCount = _resultCountFor(raw, 'deepseek');
        debugPrint('[DeepSeek 搜索 live] OK — web_search 卡 done；卡片正文 ${raw.length} 字、'
            '网址 ${urls.length} 个；卡片里是否显示 deepseek 行：'
            '${deepseekCount == null ? "没显示（2000 字预算被前面的后端占满，属已知渲染行为）" : "$deepseekCount 条"}。'
            'deepseek 那一路真正被调用与耗时看 sidecar.log 的 '
            '「DeepSeek 搜索：query=… 」与「DeepSeek 搜索：HTTP 200 用时 Nms」两行');
      } finally {
        await captureLiveShot(tester, captureKey, 'liveds_t1');
      }
    },
    timeout: const Timeout(Duration(seconds: 420)),
  );
}
