@Tags(['live'])
library;

// 展示用（用户 2026-09-26 要求）：跑一次真实模型的窗口测试，把
//   「原文 + 1 级摘要 + 2 级摘要」
// 三样同时摆进应用里的「真实上下文」那一屏，并把窗口一直开着，直到用户手动关掉。
//
// 关于"真实"的边界，写清楚：
//   - 历史（原文）是一批程序生成的填充文本（用户 2026-09-26 确认这样可以），
//     它只是为了把内容量顶过阈值；
//   - **摘要全部是本次运行里真实模型写的**：应用跑的是正式代码路径
//     （ModelSummaryProvider → 真实 /v1/messages），摘要在生成后写进
//     summary_nodes，本文件只是把它从库里读出来打印，没有任何预置或手写文本。
//   - 每轮真实对话：只有"请确认超时改成多少秒"这类提示是我发的，回复是模型回的。
//
// 它不是判定用的测试：摆好界面、拍完截图后进入等待循环，结论看日志里的
// [VERDICT] / [OBS] 行。窗口被手动关闭时这一轮会中断，属预期。
//
// 运行：flutter test --tags live --run-skipped integration_test/show_compaction_live_test.dart -d windows

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/context_view.dart';

import '../test/integration/helpers/real_context_fixture.dart';
import 'live_observability.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 让真实鼠标/触屏输入也能进到应用里。默认是 false —— 测试绑定期望输入全由
  // 测试自己合成，所以真人点窗口会毫无反应。框架会在每个测试结束后核对这个值
  // 没被测试体改过，所以只能在这里（测试体外）设。
  binding.shouldPropagateDevicePointerEvents = true;
  // 让应用自己请求的每一帧都真的画出来。默认的 fadePointers 只在测试调用
  // pump() 时才画帧，人工点窗口会"好几秒才有反应"（源码：framePolicy 默认值在
  // flutter_test/lib/src/binding.dart 的 LiveTestWidgetsFlutterBindingFramePolicy）。
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  sqfliteFfiInit();
  // integration_test 跑的是测试自己的 main()，lib/main.dart 里的 databaseFactory
  // 初始化不执行，所以这里要显式设一次。
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_show_');
    await DatabaseService.openAt(tempDir.path);
    // 不调用 clearLiveVisualDir()：那会删掉之前跑出来的截图。
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁，交给系统清理。
      }
    }
  });

  testWidgets('展示压缩结果：原文 + 1 级摘要 + 2 级摘要（窗口保持打开）', (tester) async {
    final cfg = _resolveLiveConfig();
    if (cfg == null) {
      markTestSkipped('没有可用的真实 provider key / model：跳过（需要联网跑）');
      return;
    }

    final sessionRepo = SessionRepository();
    final msgRepo = MessageRepository();
    final session = await sessionRepo.create(title: 'show-compaction');
    final sessionId = session.id;
    final prompt = '请确认你把 config.dart 的连接超时改成了多少秒。';

    // 先把一大批历史直接写进库（这部分不花模型调用），让阈值够得着。
    final fixture0 = buildConfigRefactorConversation(
        sessionId: sessionId, fillerTurns: 480);

    // ── 造假就会失败的检查 ──────────────────────────────────────────────
    // 往**最老**那条消息里塞一个随机口令。这串码只存在于"会被压掉的那段原文"里：
    //   · 摘要是真模型读这段原文写出来的 ⇒ 摘要正文里可能带出它；
    //   · 折叠内容真的经摘要发给了模型 ⇒ 直接问模型，它答得出来；
    //   · 如果整条链是假的 / 摘要与原文无关 ⇒ 两处都查不到，这里会明说。
    const nonce = 'ZQ7K3M9P';
    final oldest = fixture0.first;
    final fixture = <Message>[
      Message(
        id: oldest.id,
        seq: oldest.seq,
        sessionId: oldest.sessionId,
        role: oldest.role,
        content: '【本次会话唯一随机口令】$nonce —— 这是重要信息，摘要里必须原样保留。\n'
            '${oldest.content}',
        createdAt: oldest.createdAt,
      ),
      ...fixture0.skip(1),
    ];
    debugPrint('[FALSIFY] 已把随机口令 $nonce 写进最老那条消息（seq ${oldest.seq}）');
    final preHistory = [
      ...fixture,
      Message(
        id: 'm_current',
        seq: (fixture.last.seq ?? 0) + 1,
        sessionId: sessionId,
        role: 'user',
        content: prompt,
        createdAt: (fixture.last.seq ?? 0) + 1,
      ),
    ];

    // 阈值 = 模型能装下的总量 × 25%。这里把总量设成原始内容的 **2/5**（阈值 = 原始内容的
    // 10%）。为什么不是 2/3：新口径要求"一条 2 级要等它覆盖的整段都落到最远档（超过 2T）
    // 才进投影"，而第一批 1 级合出来的那条 2 级正好盖住最旧的那几批 —— 比例取 2/3 时它后面
    // 剩下的内容不够 2T（实测：总量 12991、阈值 2165 ⇒ 2T=4330，而那条 2 级后面只剩 2200
    // 左右），界面上就只能看到原文 + 1 级。取 2/5 ⇒ 阈值降到约 1300，同一条 2 级后面还剩
    // 5000 以上，稳稳超过 2T，界面上三级同屏。
    final totalRaw = CompactionEngine.rawTokens(preHistory);
    final kBudget = (totalRaw * 2) ~/ 5;
    debugPrint('[OBS] 模型上下文总量=$kBudget 阈值=${CompactionEngine.thresholdTokens(kBudget, null)}'
        '（= 总量的 25%）原始内容总量=$totalRaw');

    final smallConfig = AppConfig(
      version: 1,
      providers: {
        cfg.providerName:
            ProviderConfig(apiKey: cfg.apiKey, baseUrl: cfg.baseUrl),
      },
      agentTypes: {
        cfg.agentName: AgentTypeConfig(
          name: cfg.agentName,
          provider: cfg.providerName,
          model: cfg.model,
          systemPrompt: cfg.systemPrompt,
          maxContextTokens: kBudget,
          standingRequirements: cfg.standingRequirements,
        ),
      },
    );

    for (final m in fixture) {
      await msgRepo.insert(
        sessionId: sessionId,
        role: m.role,
        content: m.content,
        toolCallsJson: m.toolCallsJson,
      );
    }


    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: AppShell(configLoader: () => ConfigResult.ok(smallConfig)),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));

    // 固定三步，卡住"粗摘要已存在、且还有一条它没盖住的新 1 级摘要"的那一刻：
    //   第一步：触发第一轮压缩 —— 产出若干 1 级摘要，并把它们合成一条 2 级摘要。
    //   第二步：再发一条 —— 它后面那次压缩会产出一条 2 级摘要没盖到的新 1 级摘要
    //           （新 1 级的量远小于阈值，不会再被合成掉，所以这一步之后状态稳定）。
    //   第三步：再发一条 —— **这一次请求**里就同时带上 2 级摘要 + 新 1 级摘要 + 原文，
    //           而界面显示的就是这一次请求。
    List<SummaryNode> nodes = const [];
    await _sendOneTurn(tester, prompt, 1);
    await _waitForFoldToSettle(sessionId);
    _logStructure(await SummaryNodeRepository().queryBySession(sessionId), '第一步之后');

    await _sendOneTurn(tester, '继续：确认一下超时值。', 2);
    await _waitForFoldToSettle(sessionId);
    _logStructure(await SummaryNodeRepository().queryBySession(sessionId), '第二步之后');

    await _sendOneTurn(tester, '最后确认一次：超时值是多少？', 3);
    debugPrint('[OBS] 第三步已发出：界面这一屏就是它 —— 应当同时有 2 级摘要、'
        '一条它没盖住的 1 级摘要，以及原文');

    // ── 造假检查：口令有没有经摘要到达模型 ────────────────────────────────
    final nodesForNonce = await SummaryNodeRepository().queryBySession(sessionId);
    final summaryTexts =
        nodesForNonce.map(_summaryText).join('\n');
    final sentForNonce = _snapshotMessagesJson(tester);
    debugPrint('[FALSIFY] 口令 $nonce：'
        '出现在存下来的摘要正文里=${summaryTexts.contains(nonce)}；'
        '出现在这次真正发出去的上下文里=${sentForNonce.contains(nonce)}');

    await _sendOneTurn(tester, '本次会话的唯一随机口令是什么？请只回答那串码。', 4);
    final nonceReply = readFinalAssistantReply(tester);
    debugPrint('[FALSIFY] 问模型口令，它的回复是：$nonceReply');
    debugPrint('[FALSIFY] 模型答出了口令='
        '${nonceReply != null && nonceReply.contains(nonce)}'
        '（口令只存在于被压掉的最老那条消息里，模型只能从摘要里知道它）');

    // 每条摘要的级别、覆盖范围、花的 token、正文。正文是这次运行里真实模型
    // 写进库的，这里只是读出来打印。
    nodes = await SummaryNodeRepository().queryBySession(sessionId);
    final allMessages = await msgRepo.queryBySession(sessionId);
    debugPrint('[OBS] 这次会话共 ${allMessages.length} 条消息（填充 + 真实往来）');
    for (final n in nodes) {
      debugPrint('[OBS] 摘要 level=${n.level} 覆盖=[${n.coveredMinSeq},${n.coveredMaxSeq}] '
          'token=${n.tokenCost}');
      debugPrint('[OBS] 摘要正文（模型输出，从库里读出）：\n${_summaryText(n)}');
    }

    final sent = _snapshotMessagesJson(tester);
    debugPrint('[VERDICT] 库里原文 ${allMessages.length} 条；'
        '1 级摘要 ${nodes.where((n) => n.level <= 1).length} 条；'
        '2 级摘要 ${nodes.where((n) => n.level >= 2).length} 条');
    debugPrint('[VERDICT] 最近一次真正发出去的上下文里：'
        '带 1 级摘要标记=${sent.contains(kSummaryMarker)}；'
        '带 2 级摘要标记=${sent.contains(kLevel2SummaryMarker)}');
    debugPrint('[VERDICT] 发出去的上下文长度=${sent.length} 字符');

    // 每条 2 级这一趟"该不该进投影"：由产品代码按"整段是否都超过 2T"算，不靠人眼看。
    // 够远 ⇒ 它必须在发出去的内容里；不够远 ⇒ 它必须不在，那一段由它盖住的 1 级表示。
    final distances = CompactionEngine.distancesFromNewest(allMessages);
    final tForBands = CompactionEngine.thresholdTokens(kBudget, null);
    for (final n in nodes.where((n) => n.level >= 2)) {
      final span = CompactionEngine.spanIndices(
          allMessages, n.coveredMinSeq, n.coveredMaxSeq);
      final farEnough = span != null &&
          CompactionEngine.substitutesSpan(
            distanceAtOldest: distances[span.oldest],
            distanceAtNewest: distances[span.newest],
            level: 2,
            t: tForBands,
          );
      debugPrint('[VERDICT] 2 级覆盖 seq ${n.coveredMinSeq}..${n.coveredMaxSeq}：'
          '最旧端离末尾 ${span == null ? "不在历史里" : distances[span.oldest]} raw、'
          '最新端离末尾 ${span == null ? "不在历史里" : distances[span.newest]} raw，'
          '最远档下界 2T=${2 * tForBands} ⇒ '
          '${farEnough ? "够远，必须出现在这一趟的投影里" : "还不够远，这一趟由它的 1 级摘要表示"}');
    }

    // 稳态下三档各占多少：直接从**真正发出去的那份内容**里数块 —— 带 2 级标记的是最远档、
    // 带 1 级标记的是中距档、剩下的文本就是还在逐字发的最近原文（字符数 ÷ 4 是本地估算）。
    var l2Blocks = 0;
    var l1Blocks = 0;
    var verbatimChars = 0;
    for (final m in (jsonDecode(sent) as List)) {
      final content = (m as Map<String, dynamic>)['content'];
      if (content is! List) continue;
      for (final b in content) {
        if (b is! Map<String, dynamic> || b['type'] != 'text') continue;
        final text = (b['text'] as String?) ?? '';
        if (text.contains(kLevel2SummaryMarker)) {
          l2Blocks++;
        } else if (text.contains(kSummaryMarker)) {
          l1Blocks++;
        } else {
          verbatimChars += text.length;
        }
      }
    }
    final l2TokenSum = nodes
        .where((n) => n.level >= 2)
        .fold<int>(0, (m, n) => m + (n.tokenCost ?? 0));
    final l1TokenSum = nodes
        .where((n) => n.level <= 1)
        .fold<int>(0, (m, n) => m + (n.tokenCost ?? 0));
    debugPrint('[VERDICT] 这一次发出去的内容按档分：最远档（2 级摘要）$l2Blocks 块'
        '（库里 2 级实测 token 合计 $l2TokenSum）；中距档（1 级摘要）$l1Blocks 块'
        '（库里 1 级实测 token 合计 $l1TokenSum）；最近档（逐字原文）约 '
        '${verbatimChars ~/ 4} 估算 token（$verbatimChars 字符）');

    // 切到「真实上下文」那一屏。
    final tab = find.text('真实上下文');
    if (tab.evaluate().isNotEmpty) {
      await tester.tap(tab);
      await tester.pump(const Duration(seconds: 1));
      debugPrint('[OBS] 已切到「真实上下文」');
    } else {
      debugPrint('[OBS] 界面上找不到「真实上下文」标签');
    }
    dumpContext(tester, '展示用：真实上下文');
    // 把每条摘要块展开：默认是收起的（只显示标题行），点一下才显示模型写的摘要正文。
    for (var i = 0; i < 8; i++) {
      final items = find.byType(SummaryItem);
      if (i >= items.evaluate().length) break;
      await tester.tap(items.at(i), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
    }
    debugPrint('[OBS] 摘要块已展开：界面上共 ${find.byType(SummaryItem).evaluate().length} 个');
    await captureLiveShot(tester, captureKey, 'show_compaction_live');

    // 挂着不关：一直等到用户手动关闭窗口（上限 6 小时，防忘记）。
    debugPrint('[HOLD] 界面已停在「真实上下文」，窗口会一直开着，直到你手动关闭它。');
    final deadline = DateTime.now().add(const Duration(hours: 6));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    debugPrint('[HOLD] 已到 6 小时上限，退出等待。');
  }, timeout: const Timeout(Duration(hours: 7)));
}

/// 打印一次摘要结构的快照：各级几条、覆盖到哪、以及"2 级摘要没盖到的 1 级"有几条。
void _logStructure(List<SummaryNode> nodes, String phase) {
  final l1 = nodes.where((n) => n.level <= 1).toList();
  final l2 = nodes.where((n) => n.level >= 2).toList();
  final l2Max = l2.isEmpty
      ? -1
      : l2.map((n) => n.coveredMaxSeq).reduce((a, b) => a > b ? a : b);
  final newerL1 = l1.where((n) => n.coveredMaxSeq > l2Max).toList();
  debugPrint('[OBS] $phase：1 级 ${l1.length} 条、2 级 ${l2.length} 条、'
      '2 级没盖到的 1 级 ${newerL1.length} 条（2 级最高覆盖 seq $l2Max）');
}

/// 发一轮真实消息，等模型回复。返回 false 表示发不出去或模型报错。
Future<bool> _sendOneTurn(WidgetTester tester, String prompt, int round) async {
  final textField = find.byType(TextField);
  if (textField.evaluate().isEmpty) {
    debugPrint('[OBS] 第 $round 轮：找不到输入框，停止发送');
    return false;
  }
  debugPrint('[OBS] 第 $round 轮发出：$prompt');
  await tester.enterText(textField, prompt);
  final sendButton = find.byTooltip('Send');
  if (sendButton.evaluate().isEmpty) {
    debugPrint('[OBS] 第 $round 轮：找不到发送按钮，停止发送');
    return false;
  }
  await tester.tap(sendButton);
  await tester.pump();

  try {
    await pumpUntilReplyOrTurnDone(tester, timeoutSec: 300);
  } on TimeoutException {
    debugPrint('[OBS] 第 $round 轮：300 秒仍未结束');
  }

  final reply = readFinalAssistantReply(tester);
  debugPrint('[OBS] 第 $round 轮模型回复（前 200 字）：'
      '${reply == null ? "(没有回复)" : reply.substring(0, reply.length > 200 ? 200 : reply.length)}');
  if (reply != null && reply.startsWith('Error:')) {
    debugPrint('[OBS] 模型返回错误，停止发送：$reply');
    return false;
  }
  return true;
}

/// 等后台压缩落定：每 2 秒数一次摘要条数，连续 6 次不变（或 300 秒到点）就返回。
/// 窗口取 12 秒而不是几秒，是因为一次真实的摘要调用本身可能要十几秒 —— 窗口太短会在
/// "这一条还在压"时就返回。就算它提前返回也不要紧：下一轮发送时，内联那一趟用的是同一
/// 条压缩路径，会先把该压的压掉再发。
Future<void> _waitForFoldToSettle(String sessionId) async {
  var last = -1;
  var stable = 0;
  final end = DateTime.now().add(const Duration(seconds: 300));
  while (DateTime.now().isBefore(end)) {
    final n = (await SummaryNodeRepository().queryBySession(sessionId)).length;
    if (n == last) {
      stable++;
    } else {
      stable = 0;
      last = n;
    }
    if (stable >= 6) {
      debugPrint('[OBS] 后台压缩已落定：摘要共 $n 条');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  debugPrint('[OBS] 等后台压缩落定超时，当前摘要 $last 条');
}

/// 等到这一轮有最终回复、或者流式已经结束（读界面状态，不靠固定睡眠）。
Future<void> pumpUntilReplyOrTurnDone(WidgetTester tester,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  var sawStreaming = false;
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
    if (stillStreaming) sawStreaming = true;
    if (readFinalAssistantReply(tester) != null) return;
    if (sawStreaming && !stillStreaming) {
      await tester.pump(const Duration(milliseconds: 500));
      return;
    }
  }
  throw TimeoutException('这一轮 ${timeoutSec}s 还没结束');
}

/// 从真实 config（或环境变量覆盖）里取 provider / model / key；取不到返回 null。
({String agentName, String providerName, String apiKey, String baseUrl,
    String model, String systemPrompt, List<String> standingRequirements})?
    _resolveLiveConfig() {
  final overrideKey = Platform.environment['ALIASAGENT_API_KEY']?.trim();
  final overrideBase = Platform.environment['ALIASAGENT_BASE_URL']?.trim();
  final overrideModel = Platform.environment['ALIASAGENT_MODEL']?.trim();
  if (overrideKey != null && overrideKey.isNotEmpty) {
    if (overrideBase == null ||
        overrideBase.isEmpty ||
        overrideModel == null ||
        overrideModel.isEmpty) {
      return null;
    }
    return (
      agentName: 'general',
      providerName: 'live',
      apiKey: overrideKey,
      baseUrl: overrideBase,
      model: overrideModel,
      systemPrompt: '',
      standingRequirements: const [],
    );
  }
  final result = ConfigService.load();
  if (result.status != ConfigStatus.ok || result.config == null) return null;
  final appConfig = result.config!;
  final base = appConfig.agentTypes['general'] ??
      (appConfig.agentTypes.isNotEmpty
          ? appConfig.agentTypes.values.first
          : null);
  if (base == null) return null;
  final providerCfg = appConfig.providers[base.provider];
  if (providerCfg == null || providerCfg.apiKey.trim().isEmpty) return null;
  if (providerCfg.baseUrl.trim().isEmpty || base.model.trim().isEmpty) {
    return null;
  }
  return (
    agentName: base.name,
    providerName: base.provider,
    apiKey: providerCfg.apiKey,
    baseUrl: providerCfg.baseUrl,
    model: base.model,
    systemPrompt: base.systemPrompt,
    standingRequirements: base.standingRequirements,
  );
}

/// 库里存的 summary_json 是 role/content 块结构，这里把正文取出来。
String _summaryText(SummaryNode node) {
  final raw = node.summaryJson;
  if (raw == null || raw.isEmpty) return '';
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final content = decoded['content'] as List<dynamic>;
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map<String, dynamic> && block['type'] == 'text') {
        buf.write(block['text']);
      }
    }
    return buf.toString();
  } catch (e) {
    debugPrint('[OBS] 摘要正文解析失败：$e');
    return raw;
  }
}

/// 最近一次真正发给模型的 messages（从界面状态里读，不是从库里读）。
String _snapshotMessagesJson(WidgetTester tester) {
  final screen = find.byType(ChatScreen);
  if (screen.evaluate().isEmpty) return '';
  final snap = tester.state<ChatScreenState>(screen).contextSnapshot;
  if (snap == null) return '';
  return const JsonEncoder().convert(snap.messages);
}
