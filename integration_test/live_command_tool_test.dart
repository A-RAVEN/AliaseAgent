@Tags(['live'])
library;

// 命令工具的真实端到端验收（change add-command-tool，tasks.md 9.2）。
//
// 为什么是"一条 live 用例"而不是"手动点界面"：本机屏幕正被用户自己的会话占着，
// 手动抢焦点会打断他；而这条用例跑在本应用真实的 Flutter 窗口里、用**真实动态库**
// 执行**真实命令**，跑完按仓库规矩留一张 `test/live_visual/` 截图给主循环做目视
// 验收 —— 这与"人眼看一次工具卡"是同一个观察对象（本应用自己的渲染）。
//
// 跑法（与其它 live 用例一致）：
//   flutter test --tags live --run-skipped integration_test/live_command_tool_test.dart -d windows
// 跑完必须用读图工具看 `test/live_visual/livecmd_t1.png`。
//
// 覆盖哪几件事：①模型真的调用了 run_command；②工具卡走到 done（不是 error）；
// ③返回的中文输出逐字正确（没有乱码）；④界面上的工具卡把命令与输出显示出来。
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
  int timeoutSec = 150,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Widget not found within ${timeoutSec}s');
}

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 180}) async {
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
  debugPrint('[命令工具 live / $phase] 共 ${cards.length} 张工具卡：');
  for (final c in cards) {
    final a = c.activity;
    final result = (a.result ?? '').replaceAll('\n', '\\n');
    debugPrint('[命令工具 live]   工具=${a.toolName} 状态=${a.status.name} '
        '入参=${a.input} 结果=${result.length > 300 ? '${result.substring(0, 300)}…' : result}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  bool hasCompleteConfig = false;

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
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_livecmd_');
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
    '命令工具：真实模型调 run_command，中文输出不乱码且工具卡可见',
    (tester) async {
      if (!hasCompleteConfig) {
        markTestSkipped('Incomplete config at ${ConfigService.configPath}: '
            'requires api_key + base_url + model for the general agent');
        return;
      }

      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      await tester.pump(const Duration(seconds: 2));

      try {
        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: 'Chat 输入框');
        await tester.enterText(
          textField,
          '请用 run_command 执行这条命令：Write-Output "中文测试"，'
          '然后把它打印出来的内容原样告诉我。',
        );
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: '发送按钮');
        await tester.tap(sendButton);
        await tester.pump();

        await _pumpUntilFound(
          tester,
          _toolCard('run_command', status: ToolCallStatus.done),
          timeoutSec: 180,
        );
        await _dumpCards(tester, phase: 'run_command 卡已 done');
        await _waitForTurnComplete(tester);

        // 断言：工具卡 done，且结果里有逐字正确的中文输出，没有替换字符。
        final cards = tester
            .widgetList<ToolCallCard>(_toolCard('run_command', status: ToolCallStatus.done))
            .toList();
        expect(cards, isNotEmpty, reason: 'run_command 必须有一张 done 的卡');
        final result = cards.last.activity.result ?? '';
        debugPrint('[命令工具 live] 断言前现场：结果长度=${result.length}');
        expect(result, contains('中文测试'),
            reason: '命令的输出必须原样出现在工具卡里（乱码时这里会失败）');
        expect(result.contains('\uFFFD'), isFalse,
            reason: '不该出现替换字符（那是编码坏掉的标志）');
        debugPrint('[命令工具 live] OK — run_command 卡 done，输出含「中文测试」且无替换字符');
      } finally {
        await captureLiveShot(tester, captureKey, 'livecmd_t1');
      }
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );
}
