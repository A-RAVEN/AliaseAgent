@Tags(['live'])
library;

// web_fetch 正文 spill 交付的真实链路验收（change `migrate-web-fetch-to-spill` 任务 4.3）。
//
// 验的是"调用点真的接了形状"这件事在真实模型 + 真 DLL + 真抓取下成立：
//   - 提示词指定一个约 10KB 的纯文本 URL（rfc-editor 的 RFC 3629，UTF-8 定义文档，
//     纯 ASCII 正文——read_spill 的字节偏移不会切半码点）；
//   - 断言模型可见正文（卡片 activity.result）是"头尾预览 + 省略说明 + 末行
//     `[spill refs: content=…]`"形态，而不是旧的"前 2000 字符加三个点"；
//   - 引用文件真实存在，信封 total 与文件实际字节数相等（外部真值，不看信封自洽）；
//   - 用同一上下文句柄（= 会话 id，见 `agent.dart` 的 `ensureContext(sessionId)`）
//     经 FFI `read_spill` 读回：头部区间应出现在预览里、中段区间不应出现（被省略）、
//     尾部区间应出现——"头尾不重叠、中段可恢复"三条同时成立。
// 断言前打印工具名 / 完整 input / 交付正文头尾与各区间读数（TESTING.md §3.1）。
//
// 跑法（监督者执行，需 magpie 网关与目标 URL 可达）：
//   flutter test --tags live --run-skipped integration_test/web_fetch_spill_live_test.dart -d windows
// 跑完看 `test/live_visual/web_fetch_spill_live.png`。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
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

/// 抓取目标：RFC 3629（UTF-8 规范），约 10KB 纯 ASCII 文本页。
/// 正文远超 `spill.preview_chars × 2`（默认 2000 字符），必然走头尾预览 + 落盘。
const String _kFetchUrl = 'https://www.rfc-editor.org/rfc/rfc3629';

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 300}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('会话轮没有在 ${timeoutSec}s 内结束');
}

/// 轮询到出现一张 done 状态的 web_fetch 卡，返回它的 activity。
Future<ToolCallActivity> _pollWebFetchDone(WidgetTester tester,
    {int timeoutSec = 240}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    for (final card in tester.widgetList<ToolCallCard>(find.byType(ToolCallCard))) {
      final a = card.activity;
      if (a.toolName == 'web_fetch' && a.status == ToolCallStatus.done) {
        return a;
      }
    }
  }
  throw TimeoutException('$timeoutSec 秒内没有出现 done 的 web_fetch 卡片');
}

/// FFI 直连 `read_spill`：与 app 同一份 sidecar.dll（Dart 对同库名复用实例），
/// 句柄用当前会话 id（产品就是按它建上下文的），读回必须按本上下文目录放行。
({bool ok, String text, String error}) _readSpill(
    String handle, String ref, int offset, int limit) {
  final dylib = DynamicLibrary.open('sidecar.dll');
  final fn = dylib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('read_spill');
  final h = handle.toNativeUtf8();
  final req = jsonEncode({'ref': ref, 'offset': offset, 'limit': limit}).toNativeUtf8();
  try {
    final text = fn(h, req).toDartString();
    final parsed = jsonDecode(text) as Map<String, dynamic>;
    return (
      ok: parsed['ok'] == true,
      text: (parsed['text'] as String?) ?? '',
      error: (parsed['error'] as String?) ?? '',
    );
  } finally {
    calloc.free(h);
    calloc.free(req);
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
    tempDir = Directory.systemTemp.createTempSync('aliasagent_live_wfspill_');
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
    'web_fetch 正文走 spill：真抓取长文本页，头尾预览+引用行，read_spill 能读回中段',
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
        final repoRoot = Directory.current.path;
        final chatState = tester.state<ChatScreenState>(find.byType(ChatScreen));
        // 会话 bootstrap（与 tool_parallelism_live_test 同一先例）：空库先点真实
        // New Chat 按钮，轮询 currentSessionId 出现后再设工作区。
        await tester.tap(find.widgetWithText(FilledButton, 'New Chat'));
        final chatReadyDeadline =
            DateTime.now().add(const Duration(seconds: 15));
        while (chatState.currentSessionId == null &&
            DateTime.now().isBefore(chatReadyDeadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(chatState.currentSessionId, isNotNull,
            reason: 'New Chat 必须先建出当前会话');
        expect(await chatState.setCurrentWorkspace(repoRoot), isNull,
            reason: 'setWorkspace(仓库根) 必须成功');

        // 观察通道：与 app 同一进程、同一 sidecar 实例，直接读后端清单——
        // 分清"清单为空（闸门/配置问题）"与"清单非空但工具没进模型目录（装配问题）"。
        final probeLib = DynamicLibrary.open('sidecar.dll');
        final getProviders = probeLib.lookupFunction<
            Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('get_search_providers');
        final providersObs = getProviders().toDartString();
        // ignore: avoid_print
        print('[OBS] 4.3 get_search_providers=$providersObs');

        await tester.enterText(
          find.byType(TextField),
          '必须调用 **web_fetch** 工具来抓取这个网址（input 里 url 就填它）：'
              '$_kFetchUrl 。\n'
              '不许用 run_command、PowerShell 或其它任何工具代替抓取——'
              '这一步只接受 web_fetch。拿到结果后，用一句话告诉我这份 RFC 定义的是什么。',
        );
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: '发送按钮');
        await tester.tap(sendButton);
        await tester.pump();

        final ToolCallActivity activity;
        try {
          activity = await _pollWebFetchDone(tester);
        } on TimeoutException {
          await dumpToolCards(tester, phase: '4.3 等 web_fetch done 卡超时');
          fail('模型没有发出/完成 web_fetch（现场见上）');
        }
        await _waitForTurnComplete(tester);

        final body = activity.result ?? '';
        final inputJson =
            const JsonEncoder.withIndent('  ').convert(activity.input);
        // ignore: avoid_print
        print('[OBS] 4.3 工具=${activity.toolName} 状态=${activity.status.name}\n'
            '[OBS] 4.3 完整 input: $inputJson\n'
            '[OBS] 4.3 交付正文前 120 字符: ${body.substring(0, body.length > 120 ? 120 : body.length)}\n'
            '[OBS] 4.3 交付正文末 260 字符: ${body.length > 260 ? body.substring(body.length - 260) : body}\n'
            '[OBS] 4.3 交付正文长度: ${body.length}');

        // ---- ① 交付形态：头尾预览 + 省略说明 + 末行 spill 引用 ----
        expect(body, contains('[spill refs:'),
            reason: '正文末行必须是 spill 引用行（旧形态"前 2000 字符加三个点"不许回来）');
        expect(body, contains('read_spill'),
            reason: '引用行必须给出 read_spill 读回办法');
        expect(body, contains('bytes omitted'),
            reason: '省略说明必须写明略去了多少');
        expect(body, isNot(matches(RegExp(r'\.\.\.\s*$'))),
            reason: '不允许裸三个点结尾的静默截断形态');

        // ---- ② 外部真值：引用文件存在、信封 total == 文件实际字节数 ----
        final refsMatch = RegExp(
                r'\[spill refs: content=(.+?) \((\d+) bytes, (\d+) omitted\)')
            .firstMatch(body);
        expect(refsMatch, isNotNull, reason: '引用行必须可解析：${body.substring(body.length > 400 ? body.length - 400 : 0)}');
        final ref = refsMatch!.group(1)!;
        final total = int.parse(refsMatch.group(2)!);
        final omitted = int.parse(refsMatch.group(3)!);
        final spillFile = File(ref.replaceAll('\\', Platform.pathSeparator));
        // ignore: avoid_print
        print('[OBS] 4.3 ref=$ref total=$total omitted=$omitted');
        expect(spillFile.existsSync(), isTrue, reason: '引用必须指向真实存在的 spill 文件：$ref');
        final fileBytes = spillFile.readAsBytesSync();
        expect(fileBytes.length, total,
            reason: '信封 total 必须等于 spill 文件实际大小（外部真值，不是信封自洽）');
        expect(omitted, greaterThan(0),
            reason: '10KB 级页面必然超过头尾预览，省略量必须大于 0');

        // ---- ③ read_spill 真读回：头区间在预览里、中段不在、尾区间在预览里 ----
        final handle = chatState.currentSessionId!;
        final headRead = _readSpill(handle, ref, 0, 200);
        final midOffset = fileBytes.length ~/ 2;
        final midRead = _readSpill(handle, ref, midOffset, 200);
        final tailRead =
            _readSpill(handle, ref, fileBytes.length - 200, 200);
        // ignore: avoid_print
        print('[OBS] 4.3 read_spill 头 ok=${headRead.ok} len=${headRead.text.length}；'
            '中 ok=${midRead.ok} len=${midRead.text.length}；'
            '尾 ok=${tailRead.ok} len=${tailRead.text.length}');
        expect(headRead.ok && tailRead.ok && midRead.ok, isTrue,
            reason: '本上下文句柄读自己的引用必须放行（错误：头=${headRead.error} 中=${midRead.error} 尾=${tailRead.error}）');
        final midText = midRead.text;
        expect(midText.length, greaterThan(50),
            reason: '中段读回应接近 200 字节（实际 ${midText.length}）');
        expect(body, contains(headRead.text),
            reason: '头 200 字节属于头预览，正文里应当出现');
        expect(body, contains(tailRead.text),
            reason: '尾 200 字节属于尾预览，正文里应当出现');
        expect(body, isNot(contains(midText)),
            reason: '中段被省略，不应出现在交付正文里（若出现说明 omitted 计数是假的）');
      } finally {
        await captureLiveShot(tester, captureKey, 'web_fetch_spill_live');
      }
    },
    timeout: const Timeout(Duration(seconds: 540)),
  );
}
