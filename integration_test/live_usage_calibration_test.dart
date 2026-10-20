@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/context_ring.dart';

/// 13.1：校准"环旁那个百分比到底准不准"。
///
/// 两把尺子放在一起：
/// * **服务端说这次请求用了多少** —— 流结束时 `input_tokens` 被写进助手消息的
///   `token_count` 字段（`lib/main.dart` 里 `tokenCount: lastInputTokens`）；
/// * **产品自己估了多少** —— 环上那份拆分里的 `usedTokens`（固定开销 + 二级 + 一级 + 原文）。
///
/// 用例只做两件事：把它们同时打印出来、算出比值。**不设"必须接近 1"的断言** ——
/// 比值是多少由实测决定，写死阈值就是凭空发明；13.2 负责把实测值记进规范。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  setUp(() async {
    // `integration_test` 跑的是测试自己的 main()，产品那两行初始化不会执行；
    // `sqfliteFfiInit()` 本身不设置全局 databaseFactory，不补第二行开库就抛 Bad state。
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('aliasagent_usage_cal_');
    await DatabaseService.openAt(tempDir!.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir != null && tempDir!.existsSync()) {
      try {
        tempDir!.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁，交给系统清理。
      }
    }
  });

  testWidgets('同一次请求：打印服务端 input_tokens 与产品估算值、比值', (tester) async {
    final result = ConfigService.load();
    if (result.status != ConfigStatus.ok || result.config == null) {
      markTestSkipped('没有可用的真实模型配置（${ConfigService.configPath}），跳过。');
      return;
    }
    final realCfg = result.config!;
    final providerName = realCfg.providers.keys.first;
    final agentName = realCfg.agentTypes.keys.first;
    final agent = realCfg.agentTypes[agentName]!;

    // 种子：几条普通消息。窗口给足，确保这一趟**不触发压缩** —— 这样"估算值"与
    // "服务端用量"描述的是同一份原样请求，比值才有意义。
    final sessionRepo = SessionRepository();
    final msgRepo = MessageRepository();
    final session = await sessionRepo.create(title: 'usage-calibration');
    for (var i = 0; i < 6; i++) {
      await msgRepo.insert(
        sessionId: session.id,
        role: i.isEven ? 'user' : 'assistant',
        content: '第 ${i + 1} 条：这是一段用于校准分词估算的普通对话内容，'
            '长度大致均匀，不含工具调用。',
      );
    }

    final cfg = AppConfig(
      version: 1,
      providers: {
        providerName: ProviderConfig(
          apiKey: realCfg.providers[providerName]!.apiKey,
          baseUrl: realCfg.providers[providerName]!.baseUrl,
        ),
      },
      agentTypes: {
        agentName: AgentTypeConfig(
          name: agentName,
          provider: providerName,
          model: agent.model,
          systemPrompt: agent.systemPrompt,
          maxContextTokens: 1000000,
          standingRequirements: agent.standingRequirements,
        ),
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: AppShell(configLoader: () => ConfigResult.ok(cfg)),
    ));
    await tester.pump(const Duration(seconds: 2));

    final sendButton = find.byTooltip('Send');
    for (var i = 0; i < 120 && sendButton.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sendButton, findsOneWidget, reason: '发送按钮必须就绪（最多等 120 秒）');

    await tester.enterText(find.byType(TextField), '请回复"收到"两个字，不要做别的事。');
    await tester.tap(sendButton);
    await tester.pump();
    // 等这一轮结束：先看到流式中，再转成非流式。
    var sawStreaming = false;
    final end = DateTime.now().add(const Duration(seconds: 300));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(seconds: 1));
      final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
      final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
      if (stillStreaming) sawStreaming = true;
      if (sawStreaming && !stillStreaming) {
        await tester.pump(const Duration(seconds: 1));
        break;
      }
    }
    expect(sawStreaming, isTrue, reason: '这一轮必须真的开始流式（否则没有服务端用量）');

    // ① 服务端用量：这一轮对话请求的 token_count。
    //
    // **取最大值，不取"最后一条助手消息"** —— 2026-10-18 实测踩到：同一会话里除了这轮
    // 对话，还可能有附属请求（例如生成标题），它们的用量也被写进助手消息，末条可能只有
    // 35 token，拿它当"这次请求的用量"就完全错了（第一次跑 2083，第二次跑 35）。
    final rows = await msgRepo.queryBySession(session.id);
    final assistants = rows.where((m) => m.role == 'assistant').toList();
    expect(assistants, isNotEmpty, reason: '这一轮必须落了助手消息');
    final tokenCounts = assistants.map((m) => m.tokenCount ?? 0).toList()..sort();
    final actualInputTokens = tokenCounts.last;

    // ② 产品估算：环上拆分的 usedTokens（固定开销 + 三段）。
    final rings = tester.widgetList<ContextRing>(find.byType(ContextRing));
    expect(rings, isNotEmpty, reason: '输入行里必须有环');
    final b = rings.last.breakdown;
    expect(b, isNotNull, reason: '发过一次请求 ⇒ 必须有占用拆分');
    final estimated = b!.usedTokens;

    // ignore: avoid_print
    print('  [CALIB] 服务端 input_tokens=$actualInputTokens');
    // ignore: avoid_print
    print('  [CALIB] 产品估算 usedTokens=$estimated '
        '（固定=${b.fixedOverheadTokens} 二级=${b.level2Tokens} '
        '一级=${b.level1Tokens} 原文=${b.rawTokens} 窗口=${b.windowTokens}）');
    // ignore: avoid_print
    print('  [CALIB] 比值 = 服务端 ÷ 估算 = '
        '${(actualInputTokens / estimated).toStringAsFixed(4)}');
    // ignore: avoid_print
    print('  [CALIB] 结论：${actualInputTokens > estimated ? "产品估算偏小" : "产品估算偏大"} '
        '（差 ${(actualInputTokens - estimated).abs()} token）');

    expect(actualInputTokens, greaterThan(0),
        reason: '服务端必须回报 input_tokens，否则这条校准没有意义');
    expect(estimated, greaterThan(0), reason: '产品估算必须大于 0');
  }, timeout: const Timeout(Duration(seconds: 600)));
}
