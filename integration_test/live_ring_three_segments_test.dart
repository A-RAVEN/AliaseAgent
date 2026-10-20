@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/context_ring.dart';
import 'package:alias_agent/ui/context_view.dart';

import '../test/integration/helpers/real_context_fixture.dart';
import '../test/integration/helpers/screenshot_utils.dart';
import 'live_observability.dart';

/// 专门验证"**二级摘要真的被用上**、环上出现三瓣"的 live 用例（2026-10-18）。
///
/// 为什么单独造一条：既有的 `compact_quality_live_test` 把窗口设成历史总量的
/// `2/3`，而那个比例**正好落在临界点**上 —— 按 `CompactionEngine.l2GroupCount`
/// 的规则，一条二级大约覆盖 `4T` 的原文，于是"它之后的内容"≈ `总 - 4T`
/// = `总 - 4×(总/6)` = `总/3`，而门槛 `2T` 也等于 `总/3`。实测就是卡在那条线上
/// （最新端 4307 vs 门槛 4330，差 23）。
///
/// 这条用例把窗口设成历史总量的 **1/2**：`T = 总/8`、`2T = 总/4`，而二级之后的内容
/// ≈ `总/2` > `总/4` —— 稳定越过门槛，二级会被真正顶替进上下文。
const String _shotPath = 'test/live_visual/ring_three_live.png';
const String _prompt = '请确认你把 config.dart 的连接超时改成了多少秒。';

/// 等到"这一轮对话真的结束"：先看到流式中，之后转成非流式，再补半秒让落库完成。
///
/// 与 `compact_quality_live_test.dart` 里同名函数同一套思路，但不依赖它私有的
/// `readFinalAssistantReply` —— 这里只要"结束"这个信号。
Future<void> _waitForTurnDone(WidgetTester tester,
    {int timeoutSec = 420}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  var sawStreaming = false;
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
    if (stillStreaming) sawStreaming = true;
    if (sawStreaming && !stillStreaming) {
      await tester.pump(const Duration(milliseconds: 500));
      return;
    }
  }
  throw TimeoutException('这一轮对话在 ${timeoutSec}s 内没有结束');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  setUp(() async {
    // `integration_test` 跑的是测试自己的 main()，`lib/main.dart` 里那两行初始化从没
    // 执行过；而 `sqfliteFfiInit()` 本身**不会**设置全局 `databaseFactory`，不补第二行，
    // 一开数据库就抛 `Bad state: databaseFactory not initialized`（这次实测就挂了）。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('aliasagent_ring_l2_');
    await DatabaseService.openAt(tempDir!.path);
    clearLiveVisualDir();
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir != null && tempDir!.existsSync()) {
      try {
        tempDir!.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁 —— 交给系统清理。
      }
    }
  });

  testWidgets('窗口设成历史的一半 ⇒ 二级摘要进上下文，环上三瓣', (tester) async {
    // ── 配置闸门（离线就 skip）
    final result = ConfigService.load();
    if (result.status != ConfigStatus.ok || result.config == null) {
      markTestSkipped('没有可用的真实模型配置（${ConfigService.configPath}）：'
          '这条用例要真调模型，跳过。');
      return;
    }
    final realCfg = result.config!;
    final providerName = realCfg.providers.keys.first;
    final agentName = realCfg.agentTypes.keys.first;
    final agent = realCfg.agentTypes[agentName]!;

    // ── 种子：一条长历史（约 1.3 万原始 token）
    final sessionRepo = SessionRepository();
    final msgRepo = MessageRepository();
    final session = await sessionRepo.create(title: 'ring-three-segments');
    final fixture =
        buildConfigRefactorConversation(sessionId: session.id, fillerTurns: 480);
    final preHistory = [
      ...fixture,
      Message(
        id: 'm_current',
        seq: (fixture.last.seq ?? 0) + 1,
        sessionId: session.id,
        role: 'user',
        content: _prompt,
        createdAt: (fixture.last.seq ?? 0) + 1,
      ),
    ];
    final totalRaw = CompactionEngine.rawTokens(preHistory);
    // **关键参数**：窗口 = 历史总量的一半（而不是那个用例的 2/3）。
    final kBudget = totalRaw ~/ 2;
    // ignore: avoid_print
    print('  [OBS] 种子 totalRaw=$totalRaw 窗口=$kBudget '
        'T=${CompactionEngine.thresholdTokens(kBudget, null)} '
        '2T=${2 * CompactionEngine.thresholdTokens(kBudget, null)}');

    for (final m in fixture) {
      await msgRepo.insert(
        sessionId: session.id,
        role: m.role,
        content: m.content,
        toolCallsJson: m.toolCallsJson,
      );
    }

    final smallConfig = AppConfig(
      version: 1,
      providers: {
        providerName: ProviderConfig(
            apiKey: realCfg.providers[providerName]!.apiKey,
            baseUrl: realCfg.providers[providerName]!.baseUrl),
      },
      agentTypes: {
        agentName: AgentTypeConfig(
          name: agentName,
          provider: providerName,
          model: agent.model,
          systemPrompt: agent.systemPrompt,
          maxContextTokens: kBudget,
          standingRequirements: agent.standingRequirements,
        ),
      },
    );

    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: AppShell(configLoader: () => ConfigResult.ok(smallConfig)),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));

    // ── 等工具就绪（未就绪时发送按钮的提示是「正在准备工具…」）
    final sendButton = find.byTooltip('Send');
    for (var i = 0; i < 120 && sendButton.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sendButton, findsOneWidget, reason: '发送按钮必须就绪（最多等 120 秒）');

    // ── 发一条，触发真实压缩
    await tester.enterText(find.byType(TextField), _prompt);
    await tester.tap(sendButton);
    await tester.pump();
    await _waitForTurnDone(tester);

    // ── 读环上的拆分：这里必须出现二级
    final rings = tester.widgetList<ContextRing>(find.byType(ContextRing));
    expect(rings, isNotEmpty, reason: '输入行里必须有环');
    final b = rings.last.breakdown;
    expect(b, isNotNull, reason: '发过一次请求 ⇒ 必须有占用拆分');
    final sweeps =
        b!.ringSegments.map((s) => s.sweepRadians.toStringAsFixed(4)).toList();
    // ignore: avoid_print
    print('  [OBS] 环上三段：level2=${b.level2Tokens} level1=${b.level1Tokens} '
        'raw=${b.rawTokens} 固定=${b.fixedOverheadTokens} 窗口=${b.windowTokens} '
        '弧度=$sweeps');

    await captureWidgetAsPng(captureKey, _shotPath);
    // ignore: avoid_print
    print('  [OBS] 截图已写到 $_shotPath');

    // ── 独立核对（2026-10-18 修正版）。
    //
    // 上一版有两处错，都被读代码发现（不靠跑）：
    //  ① **粒度错**：产品把连续多条摘要块攒进同一条消息（`_buildCompactionProjection` 的
    //     `pendingBlocks`，不区分层级），一条消息里可以同时有二级块和一级块；我却按**消息**
    //     `if/else if` 分类 ⇒ 混装消息里的一级块被吞。改成按 **content 块** 分类。
    //  ② **量纲错**：环上的 summary 用的是 `summary.tokens`（模型报的、不含标记），我却拿
    //     字符 ÷4 去比 ⇒ 永远对不上。所以这里**不再比 token 差值**，只比两件量纲一致的事：
    //        · 结构：各类块的数量；
    //        · 一致性：环上某层 > 0  ⇔  发出去的那份文本里存在该层至少一个块。
    await tester.tap(find.text('真实上下文'));
    await tester.pump();
    final snap = tester.widget<ContextView>(find.byType(ContextView)).snapshot;
    expect(snap, isNotNull, reason: '切到「真实上下文」必须能拿到快照');
    var l2Blocks = 0, l1Blocks = 0, rawBlocks = 0;
    var l2Chars = 0, l1Chars = 0, rawChars = 0;
    for (final m in snap!.messages) {
      final content = m['content'];
      final blocks = content is List
          ? content
          : [
              {'type': 'text', 'text': content}
            ];
      for (final blk in blocks) {
        final text = blk is Map ? (blk['text'] ?? '').toString() : '';
        if (text.contains(kLevel2SummaryMarker)) {
          l2Blocks++;
          l2Chars += text.length;
        } else if (text.contains(kSummaryMarker)) {
          l1Blocks++;
          l1Chars += text.length;
        } else {
          rawBlocks++;
          rawChars += text.length;
        }
      }
    }
    final ringTotal = b.level2Tokens + b.level1Tokens + b.rawTokens;
    final ringPct = ringTotal / b.windowTokens * 100;
    final arcSum =
        b.ringSegments.fold<double>(0, (a, s) => a + s.sweepRadians);
    // ignore: avoid_print
    print('  [VERIFY] 实际发出的块（按 content 块数，不按消息）：'
        '二级 $l2Blocks 块 / $l2Chars 字符；一级 $l1Blocks 块 / $l1Chars 字符；'
        '其它 $rawBlocks 块 / $rawChars 字符');
    // ignore: avoid_print
    print('  [VERIFY] 环上：level2=${b.level2Tokens} level1=${b.level1Tokens} '
        'raw=${b.rawTokens} 窗口=${b.windowTokens} 合计=$ringTotal '
        '占比=${ringPct.toStringAsFixed(2)}% 弧度合=${arcSum.toStringAsFixed(4)}');
    // ignore: avoid_print
    print('  [VERIFY] 几何：占比 × 2π = ${(ringPct / 100 * 2 * math.pi).toStringAsFixed(4)} '
        '（应等于上面的弧度合）');

    // 一致性：环上某层有量 ⇔ 发出去的文本里有该层的块。
    expect(b.level2Tokens > 0, l2Blocks > 0,
        reason: '环上有二级 ⇔ 发出去的文本里必须有二级块');
    expect(b.level1Tokens > 0, l1Blocks > 0,
        reason: '环上有一级 ⇔ 发出去的文本里必须有一级块');
    expect(l2Blocks + l1Blocks + rawBlocks, greaterThan(0));

    expect(b.level2Tokens, greaterThan(0),
        reason: '窗口设成历史的一半之后，二级摘要必须真的被用上 —— '
            '否则"三瓣"这一条在真机上永远看不到');
    expect(b.level1Tokens, greaterThan(0), reason: '一级也要有一瓣');
    expect(b.rawTokens, greaterThan(0), reason: '原文也要有一瓣');
  }, timeout: const Timeout(Duration(seconds: 900)));
}
