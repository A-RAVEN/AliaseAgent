@Tags(['live'])
library;

// `read_image` 工具的真模型实测（add-image-input 任务 13.2）。
//
// 真窗口 + 真模型 + 真 DLL：工作区里放一张 64×64 纯蓝 PNG，让模型用 `read_image`
// 读它并回答颜色。断言三件事：卡片走到 Done、回答里是"蓝"、卡片上真的画出了缩略图。
// 颜色选蓝是为了和 13.1 那张红图区分开 —— 两张截图不会看串。
//
// 跑法：
//   flutter test --tags live --run-skipped integration_test/live_image_read_tool_test.dart -d windows
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

/// 造一张 64×64 纯蓝 PNG。
Future<Uint8List> _makeBluePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 64, 64),
    Paint()..color = const Color(0xFF0000FF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 180}) async {
  final deadline = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('这一轮 ${timeoutSec}s 内没结束');
}

/// 等某张工具卡片出现（写法照 `live_file_tools_test.dart` 的 `pumpUntilAll`；
/// 那两个 helper 是那个文件里的私有函数，而它有 `main()`、不能 import，所以这里各留一份）。
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int timeoutSec = 150,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('${timeoutSec}s 内没等到目标卡片');
}

Finder _toolCard(String toolName, {ToolCallStatus? status}) =>
    find.byWidgetPredicate((w) =>
        w is ToolCallCard &&
        w.activity.toolName == toolName &&
        (status == null || w.activity.status == status));

/// 某工具卡片里画出来的 `Image` 个数（不去重、滚动扫描一遍就够）。
int _imagesInsideCard(WidgetTester tester, String toolName) {
  final card = find.byWidgetPredicate(
      (w) => w is ToolCallCard && w.activity.toolName == toolName);
  return find.descendant(of: card, matching: find.byType(Image)).evaluate().length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUpAll(clearLiveVisualDir);

  final configResult = ConfigService.load();
  String? configProblem;
  if (configResult.status != ConfigStatus.ok) {
    configProblem = '配置读不出来（${configResult.status}）：${ConfigService.configPath}';
  } else {
    final c = configResult.config!;
    final general = c.agentTypes['general'];
    final provider = general != null ? c.providers[general.provider] : null;
    if (general == null) {
      configProblem = '没有 general 这个 agent 类型';
    } else if (provider == null || provider.apiKey.isEmpty || provider.baseUrl.isEmpty) {
      configProblem = 'general 的 provider 不完整';
    } else if (general.model.isEmpty) {
      configProblem = 'general 没有 model';
    } else if (!general.inputModalities.contains('image')) {
      configProblem = 'general 的 input_modalities 不含 image —— read_image 会直接失败';
    }
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_imgread_live_');
    await DatabaseService.openAt(tempDir.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁
      }
    }
  });

  testWidgets(
    'read_image 读工作区里的纯蓝图 → 模型答出蓝色，卡片画出缩略图',
    (tester) async {
      if (configProblem != null) {
        markTestSkipped('配置不满足：$configProblem');
        return;
      }

      // 1. 工作区 + 夹具图（纯文件系统，pump 之前）
      final ws = Directory('${tempDir.path}/ws')..createSync();
      final pngPath = '${ws.path}${Platform.pathSeparator}blue64.png';
      await tester.runAsync(() async {
        await File(pngPath).writeAsBytes(await _makeBluePng(), flush: true);
      });
      // ignore: avoid_print
      print('  [OBS] 夹具图片 => $pngPath（${File(pngPath).lengthSync()} 字节）');

      // 2. 起应用；initState 会把工作区重置成主目录，所以要在 pump 之后重设
      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      await tester.pump(const Duration(seconds: 2));
      expect(SidecarBridge.instance.setWorkspace(ws.path), isNull,
          reason: 'setWorkspace(夹具工作区) 必须成功 —— 绝不能让模型去碰主目录');

      try {
        // 3. 让模型自己调 read_image
        await tester.enterText(
            find.byType(TextField),
            '用 read_image 读工作区根目录下的 blue64.png，'
            '然后只回答它主要是什么颜色（一个中文颜色词）。');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        try {
          await _pumpUntil(
              tester, _toolCard('read_image', status: ToolCallStatus.done),
              timeoutSec: 150);
        } on TimeoutException {
          await dumpToolCards(tester, phase: '13.2 read_image 卡片没到 Done');
          rethrow;
        }
        await _waitForTurnComplete(tester);

        // 4. 现场
        await dumpToolCards(tester, phase: '13.2 结束后');
        final cards = tester
            .widgetList<ToolCallCard>(find.byType(ToolCallCard))
            .map((c) => c.activity)
            .where((a) => a.toolName == 'read_image')
            .toList();
        // ignore: avoid_print
        print('  [OBS] read_image 卡片数=${cards.length}');
        for (final a in cards) {
          // ignore: avoid_print
          print('  [OBS]   status=${a.status.name} imagePath=${a.imagePath} '
              'result 前 80 字=${(a.result ?? '').split("\n").take(3).join(" | ")}');
        }
        expect(cards, isNotEmpty, reason: '模型必须真的调了 read_image');
        // 卡片上存的必须是**解析后的绝对路径**（C++ 用工作区解析过的那串），
        // 不是模型给的 `blue64.png` —— 界面进程要拿它去读文件画缩略图。
        final cardPath = cards.last.imagePath ?? '';
        expect(cardPath, isNot('blue64.png'),
            reason: '相对路径在界面进程里打不开（CWD 不是工作区）');
        expect(cardPath, endsWith('blue64.png'));
        expect(File(cardPath).existsSync(), isTrue,
            reason: '卡片上的路径必须能真的读到文件：$cardPath');

        final thumbCount = _imagesInsideCard(tester, 'read_image');
        // ignore: avoid_print
        print('  [OBS] read_image 卡片里画出的 Image 个数=$thumbCount');
        expect(thumbCount, greaterThan(0),
            reason: '卡片上必须画出图（用户要看到"模型看到的是什么"）');

        final db = await DatabaseService.database;
        final rows = await db.query('messages',
            orderBy: 'created_at DESC, seq DESC', limit: 4);
        for (final r in rows) {
          // ignore: avoid_print
          print('  [OBS] 消息 role=${r['role']} '
              'token_count=${r['token_count']} '
              'output_token_count=${r['output_token_count']} '
              'tool_calls 前 60 字=${(r['tool_calls'] as String? ?? '').split("\n").first}');
        }

        // 5. 回答
        final reply = readFinalAssistantReply(tester) ?? '';
        // ignore: avoid_print
        print('  [OBS] 模型回答 => 「$reply」');
        expect(reply, isNotEmpty);
        expect(reply, isNot(startsWith('Error:')), reason: '不该是错误回复：$reply');
        expect(reply, contains('蓝'),
            reason: '图是纯蓝的；答不出蓝色说明图没真的到模型眼里。回答原文：$reply');

        // 6. 落库的 tool_calls 里 image 只有 path（与 10.4 的口径对齐）
        final assistantWithTool = rows.firstWhere(
            (r) => (r['tool_calls'] as String?)?.contains('"image"') == true,
            orElse: () => <String, Object?>{});
        expect(assistantWithTool, isNotEmpty,
            reason: '库里那条工具消息必须带 image 字段');
        final calls =
            jsonDecode(assistantWithTool['tool_calls'] as String) as List;
        final image = (calls.first as Map)['image'] as Map<String, dynamic>;
        // ignore: avoid_print
        print('  [OBS] 落库的 image => $image');
        expect(image.keys.toList(), ['path']);
      } finally {
        await captureLiveShot(tester, captureKey, 'live_image_read_tool');
      }
    },
    timeout: const Timeout(Duration(seconds: 360)),
  );
}
