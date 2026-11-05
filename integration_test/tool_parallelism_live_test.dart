@Tags(['live'])
library;

// 只读工具并行执行的真实链路验收（change `parallelize-readonly-tool-calls` 任务 8.1）。
//
// 职责边界（对抗验证 0009 裁定）：**时间收益**判据由 `test/integration/sidecar_worker_test.dart`
// （真 DLL 计时）与 `test/integration/tool_parallelism_test.dart` ①（确定性延迟）
// 承担，本用例**不重复计时断言**。这里验的是真实模型 + 真 DLL + 真窗口的端到端形态：
//   - 提示词明确要求模型在**同一轮**里对 `lib/` 与 `sidecar/` 各发一次 `grep_file`；
//   - 断言**一个** assistant 轮里含 ≥2 个只读 `tool_use`（两个 grep 在同一条
//     toolCallsJson 里 = 同一轮）；
//   - 两个结果按发出顺序交付，内容与各自要求的目录相符（没有互相串）；
//   - 工具轮之后下一轮请求组装成功（存在最终回复）。
// 断言前打印每个调用的名称、完整 input、开始/结束时刻与重叠观测（TESTING.md §3.1）。
// 模型没按形态发出时**判失败并打印现场**，不静默跳过、不自造重试次数。
//
// 跑法（监督者执行；本文件只创建与静态检查）：
//   flutter test --tags live --run-skipped integration_test/tool_parallelism_live_test.dart -d windows
// 跑完看 `test/live_visual/parallel_tools_live.png`。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 240}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('Conversation did not complete within ${timeoutSec}s');
}

/// 卡片时间线：按 100ms 采样界面上的工具卡，记录每张卡第一次出现（执行中）、
/// 最后一次出现与转为终态的时刻。这是窗口版用例的观察通道（TESTING.md §3.1：
/// 窗口版经界面卡片 `ToolCallCard.activity` 读）。
class _CardTimeline {
  final Map<String, DateTime> firstSeen = {};
  final Map<String, DateTime> finishedAt = {};
  final Map<String, ToolCallActivity> latest = {};

  void sample(WidgetTester tester) {
    final now = DateTime.now();
    for (final card in tester.widgetList<ToolCallCard>(find.byType(ToolCallCard))) {
      final a = card.activity;
      firstSeen.putIfAbsent(a.id, () => now);
      latest[a.id] = a;
      if (a.status != ToolCallStatus.executing) {
        finishedAt.putIfAbsent(a.id, () => now);
      }
    }
  }

  /// 两个调用的观测时间窗是否相交（任一调用没被采到终态则返回 null = 未观测到）。
  bool? overlaps(String a, String b) {
    final aStart = firstSeen[a];
    final bStart = firstSeen[b];
    final aEnd = finishedAt[a];
    final bEnd = finishedAt[b];
    if (aStart == null || bStart == null || aEnd == null || bEnd == null) {
      return null;
    }
    final start = aStart.isAfter(bStart) ? aStart : bStart;
    final end = aEnd.isBefore(bEnd) ? aEnd : bEnd;
    return end.isAfter(start);
  }
}

/// 等到出现至少 [count] 张指定工具的卡都到终态，同时持续采样时间线。
Future<void> _pollUntilCardsDone(
  WidgetTester tester,
  _CardTimeline timeline,
  String toolName, {
  required int count,
  int timeoutSec = 240,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    timeline.sample(tester);
    final done = tester
        .widgetList<ToolCallCard>(find.byType(ToolCallCard))
        .where((c) =>
            c.activity.toolName == toolName &&
            c.activity.status == ToolCallStatus.done)
        .length;
    if (done >= count) return;
  }
  throw TimeoutException('$toolName 的终态卡片不足 $count 张（$timeoutSec 秒）');
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
    tempDir = Directory.systemTemp.createTempSync('aliasagent_liveparallel_');
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
    '只读工具并行：真实模型同一轮发两个 grep_file（lib/ 与 sidecar/），结果按序且目录相符',
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
        // 工作区 = 仓库根（initState 会先把它重置成主目录，所以必须在 pump 之后重设）。
        final repoRoot = Directory.current.path;
        final chatState = tester.state<ChatScreenState>(find.byType(ChatScreen));
        // 空库启动时没有当前会话（`setCurrentWorkspace` 自 778b933 起要求先有会话，
        // 真实产品靠发消息时懒建兜底）：先走界面上真实的「New Chat」按钮建会话。
        // _newChat 要 await 建会话 + ensureContext（真 FFI），一帧 pump 不一定跑完，
        // 按秒轮询（与 _waitForTurnComplete 同一既有模式，15s 上限是测试等待构造值）。
        await tester.tap(find.widgetWithText(FilledButton, 'New Chat'));
        final chatReadyDeadline =
            DateTime.now().add(const Duration(seconds: 15));
        while (chatState.currentSessionId == null &&
            DateTime.now().isBefore(chatReadyDeadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(chatState.currentSessionId, isNotNull,
            reason: 'New Chat 按钮必须先建出当前会话，否则后面的 setWorkspace 必然报 no current session');
        expect(await chatState.setCurrentWorkspace(repoRoot), isNull,
            reason: 'setWorkspace(仓库根) 必须成功 —— 否则扫描的不是 lib/ 与 sidecar/');

        final textField = find.byType(TextField);
        expect(textField, findsOneWidget, reason: 'Chat 输入框');
        await tester.enterText(
          textField,
          '请在同一轮里**连续发出两个** grep_file 调用（不要分成两轮）：'
          '第 1 个用 pattern="kBaseToolNames"、glob="lib/**"；'
          '第 2 个用 pattern="detect_python"、glob="sidecar/**"。'
          '两个结果都拿到以后，再用一句话告诉我各自命中了什么。',
        );
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: '发送按钮');
        await tester.tap(sendButton);
        await tester.pump();

        final timeline = _CardTimeline();
        try {
          await _pollUntilCardsDone(tester, timeline, 'grep_file', count: 2);
        } on TimeoutException {
          // 没按形态发出：打印现场再判失败（不静默跳过）。
          await dumpToolCards(tester, phase: '8.1 等两张 grep_file done 超时');
          fail('模型没有在限定时间内发出两个 grep_file 调用（现场见上）');
        }
        await _waitForTurnComplete(tester);
        timeline.sample(tester);

        // ---- 断言前先打印现场：名称 / 完整 input / 起止时刻 / 重叠观测 ----
        for (final entry in timeline.latest.entries) {
          final a = entry.value;
          // ignore: avoid_print
          print('[OBS] 8.1 调用 id=${a.id} 工具=${a.toolName} 状态=${a.status.name}\n'
              '[OBS] 8.1 完整 input: ${const JsonEncoder.withIndent('  ').convert(a.input)}\n'
              '[OBS] 8.1 开始观测=${timeline.firstSeen[entry.key]} '
              '结束观测=${timeline.finishedAt[entry.key]}');
        }
        final grepIds = [
          for (final e in timeline.latest.entries)
            if (e.value.toolName == 'grep_file') e.key,
        ];
        if (grepIds.length >= 2) {
          // ignore: avoid_print
          print('[OBS] 8.1 两个 grep 的时间窗重叠观测='
              '${timeline.overlaps(grepIds[0], grepIds[1])}'
              '（时间收益判据不在这里，见 7.1 与 5.1①）');
        }

        // ---- 从落库的 toolCallsJson 读"同一个 assistant 轮" ----
        final sessionId = chatState.currentSessionId;
        expect(sessionId, isNotNull, reason: '当前会话 id');
        final messages = await MessageRepository().queryBySession(sessionId!);
        final toolRounds = <List<Map<String, dynamic>>>[];
        for (final m in messages) {
          if (m.role != 'assistant' ||
              m.toolCallsJson == null ||
              m.toolCallsJson!.isEmpty) {
            continue;
          }
          final list = (jsonDecode(m.toolCallsJson!) as List<dynamic>)
              .cast<Map<String, dynamic>>();
          final greps =
              list.where((t) => (t['toolName'] ?? t['name']) == 'grep_file').toList();
          if (greps.isNotEmpty) toolRounds.add(greps);
        }
        // ignore: avoid_print
        print('[OBS] 8.1 落库的 grep 轮数=${toolRounds.length} '
            '各轮 grep 数=${toolRounds.map((r) => r.length).toList()}');
        for (final round in toolRounds) {
          for (final t in round) {
            // ignore: avoid_print
            print('[OBS] 8.1 落库调用 id=${t['id']} name=${t['toolName'] ?? t['name']} '
                'input=${t['input']} status=${t['status']} '
                'result=${(t['result'] ?? '').toString().split('\n').take(3).join(' | ')}');
          }
        }

        // ① 至少一个 assistant 轮里含两个 grep_file（= 同一轮里连续发出）。
        // 轮数允许 >1：最终回复消息也会带整轮 allTurnToolCalls（落库设计如此，
        // 供刷新后重现工具卡），同一对调用因此出现在两条消息里——spec 的判据是
        // "存在一个 assistant 轮含 ≥2 个只读 tool_use"（存在量词），不是"恰好一条"。
        // 真·同一轮的证明在组内：两个调用 id 互不相同且与界面观测到的同一对一致。
        final multi = toolRounds.where((r) => r.length >= 2).toList();
        expect(multi.isNotEmpty, isTrue,
            reason: '必须有一个 assistant 轮里含 ≥2 个只读 tool_use；'
                '实际各轮 grep 数=${toolRounds.map((r) => r.length).toList()}');
        final round = multi.first;
        expect(round.map((t) => t['id']).toSet().length, 2,
            reason: '该轮内的两个 grep_file 必须是两个不同 id 的调用（同一 assistant 块），不是把两条各 1 个的轮并进来的假象');
        final firstInput = (round[0]['input'] as Map).cast<String, dynamic>();
        final secondInput = (round[1]['input'] as Map).cast<String, dynamic>();
        final firstGlob = (firstInput['glob'] ?? '').toString();
        final secondGlob = (secondInput['glob'] ?? '').toString();
        final firstResult = (round[0]['result'] ?? '').toString();
        final secondResult = (round[1]['result'] ?? '').toString();
        // ignore: avoid_print
        print('[OBS] 8.1 顺序检查：第 1 个 glob=$firstGlob 第 2 个 glob=$secondGlob');

        expect(firstGlob, contains('lib'),
            reason: '第 1 个 grep_file 应扫描 lib/（实际 glob=$firstGlob）');
        expect(secondGlob, contains('sidecar'),
            reason: '第 2 个 grep_file 应扫描 sidecar/（实际 glob=$secondGlob）');

        // ③ 内容与目录相符（没有互相串）：lib 的结果带 lib/ 路径与 pattern 命中，
        //    sidecar 的结果带 sidecar/ 路径与 pattern 命中。
        expect(firstResult, contains('kBaseToolNames'),
            reason: 'lib 那次必须真的命中 kBaseToolNames（实际前几行：'
                '${firstResult.split('\n').take(3).join(' | ')}）');
        expect(firstResult, contains('lib/'),
            reason: 'lib 那次的结果路径必须在 lib/ 下');
        expect(firstResult, isNot(contains('sidecar/')),
            reason: 'lib 那次的结果里不该出现 sidecar/ 的路径（结果串了）');
        expect(secondResult, contains('detect_python'),
            reason: 'sidecar 那次必须真的命中 detect_python');
        expect(secondResult, contains('sidecar/'),
            reason: 'sidecar 那次的结果路径必须在 sidecar/ 下');
        expect(secondResult, isNot(contains('lib/')),
            reason: 'sidecar 那次的结果里不该出现 lib/ 的路径（结果串了）');

        // ④ 下一轮请求组装成功：工具轮之后存在最终回复（不是错误消息）。
        final reply = chatState.finalAssistantReply;
        // ignore: avoid_print
        print('[OBS] 8.1 最终回复=${reply == null ? "(空)" : reply.substring(0, reply.length > 80 ? 80 : reply.length)}');
        expect(reply, isNotNull,
            reason: '工具轮之后必须还有一轮请求并拿到最终回复');
        expect(reply!.startsWith('Error:'), isFalse,
            reason: '最终回复不许是错误消息：$reply');
      } finally {
        await captureLiveShot(tester, captureKey, 'parallel_tools_live');
      }
    },
    timeout: const Timeout(Duration(seconds: 400)),
  );
}
