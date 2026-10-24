@Tags(['live'])
library;

// 能力门的负例实测（add-image-input 任务 13.3）。
//
// 把 `input_modalities` 里的 image **临时**去掉，再贴同一张纯红图：
//   - 界面必须多出一行 `模型未声明图片输入，本次没有发送图片`（图没发出去，看得见）
//   - 历史里那条用户消息**仍然存着**图片路径（库不因为"没发"就丢记录）
//   - 模型的回答里不该出现"红"（它根本没看到图）
//
// **这条用例会临时改写 `~/.aliasagent/config.json`**，跑完（成功、失败、异常都算）
// 用 `finally` + `tearDownAll` 两道保险把原文**逐字节**写回去，并把原文打印进日志，
// 万一中途断电也能照着恢复。
//
// 跑法：
//   flutter test --tags live --run-skipped integration_test/live_image_capability_gate_test.dart -d windows
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
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/ui/chat_area.dart';

import 'live_observability.dart';

Future<Uint8List> _makeRedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 64, 64),
    Paint()..color = const Color(0xFFFF0000),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 把图片放进真实剪贴板（同 13.1 的手法）。
Future<String?> _putImageOnClipboard(String pngPath) async {
  if (!Platform.isWindows) return '仅在 Windows 上跑';
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($env:ALIASAGENT_CLIP_IMG)
try { [System.Windows.Forms.Clipboard]::SetImage($img) } finally { $img.Dispose() }
Write-Output "OK"
''';
  try {
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-Command', script],
      environment: {'ALIASAGENT_CLIP_IMG': pngPath},
    );
    if (r.exitCode != 0) return 'PowerShell 退出码 ${r.exitCode}: ${r.stderr}';
    if (!r.stdout.toString().contains('OK')) return '没有回 OK: ${r.stdout}';
    return null;
  } catch (e) {
    return '调用 PowerShell 失败: $e';
  }
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

/// 把聊天列表拖回顶部：`ListView.builder` 只 build 视口内的消息，滚到底部时
/// 最上面那条用户气泡根本没建出来 —— `find.text` 自然找不到它。
/// 这一步是让"提示那行"重新进入视口，不是放松断言。
Future<void> _scrollChatToTop(WidgetTester tester, {int drags = 6}) async {
  final list = find.descendant(
      of: find.byType(ChatArea), matching: find.byType(ListView));
  for (var i = 0; i < drags; i++) {
    if (list.evaluate().isEmpty) return;
    await tester.drag(list, const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String originalConfig;
  var configRestored = false;

  setUpAll(clearLiveVisualDir);

  // ---- 读原文（读一次，后面所有恢复都用它）----
  String? setupProblem;
  try {
    originalConfig = File(ConfigService.configPath).readAsStringSync();
  } catch (e) {
    originalConfig = '';
    setupProblem = '读不到配置文件 ${ConfigService.configPath}: $e';
  }

  if (setupProblem == null) {
    // ignore: avoid_print
    print('  [OBS] 配置文件原文（跑完会逐字节写回）=> $originalConfig');
    // ---- 临时去掉 input_modalities ----
    try {
      final decoded =
          jsonDecode(originalConfig) as Map<String, dynamic>;
      final general = (decoded['agent_types'] as Map)['general'] as Map;
      general.remove('input_modalities');
      File(ConfigService.configPath)
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(decoded));
      // ignore: avoid_print
      print('  [OBS] 已临时移除 input_modalities；现在的配置 => '
          '${File(ConfigService.configPath).readAsStringSync()}');
      // 用产品代码自己的解析路径复核（不手写字段名）
      final check = ConfigService.load();
      if (check.status != ConfigStatus.ok) {
        setupProblem = '改完的配置读不出来：${check.status}';
      } else if (check.config!.agentTypes['general']!.inputModalities
          .contains('image')) {
        setupProblem = '改完仍声明了 image 输入（改错了）';
      }
    } catch (e) {
      setupProblem = '改配置失败：$e';
    }
  }

  void restoreConfig() {
    if (configRestored || originalConfig.isEmpty) return;
    File(ConfigService.configPath).writeAsStringSync(originalConfig);
    configRestored = true;
    final back = File(ConfigService.configPath).readAsStringSync();
    // ignore: avoid_print
    print('  [OBS] 配置已写回，与原文逐字节一致 = ${back == originalConfig}');
  }

  tearDownAll(restoreConfig);

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_imgate_live_');
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
    '去掉 input_modalities 后贴图：界面出提示、请求里没有 image、回答里没有红色',
    (tester) async {
      try {
        if (setupProblem != null) {
          markTestSkipped('前置不满足：$setupProblem');
          return;
        }

        // 1. 纯红图（与 13.1 同一张）+ 放进剪贴板
        late String pngPath;
        await tester.runAsync(() async {
          pngPath = '${tempDir.path}${Platform.pathSeparator}red64.png';
          await File(pngPath).writeAsBytes(await _makeRedPng(), flush: true);
        });
        String? clipError;
        await tester.runAsync(() async {
          clipError = await _putImageOnClipboard(pngPath);
        });
        if (clipError != null) {
          markTestSkipped('放不进剪贴板：$clipError');
          return;
        }

        // 2. 起应用、贴图、发送
        final captureKey = GlobalKey();
        await tester.pumpWidget(
            RepaintBoundary(key: captureKey, child: const MyApp()));
        await tester.pump(const Duration(seconds: 2));
        expect(SidecarBridge.instance.setWorkspace(tempDir.path), isNull);

        // 贴图：Windows 的剪贴板是独占资源，可能被别的程序短暂占着（这时 C++ 回
        // `clipboard is busy …` 而不是"没有图"）。所以点几次、每次都把结果打出来 ——
        // 真的贴不上时仍然会失败，只是不再因为一次时序竞争就误报。
        var hasThumb = false;
        for (var attempt = 1; attempt <= 3 && !hasThumb; attempt++) {
          await tester.tap(find.byTooltip('粘贴图片'));
          for (var i = 0; i < 10 && !hasThumb; i++) {
            // 贴图回调里有真实文件 I/O：`pump()` 只推假时钟，要 runAsync 放行
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            });
            await tester.pump();
            hasThumb = find.byTooltip('移除这张图').evaluate().isNotEmpty;
          }
          // ignore: avoid_print
          print('  [OBS] 第 $attempt 次点「粘贴图片」→ 缩略图 = $hasThumb');
        }
        expect(hasThumb, isTrue,
            reason: '贴图本身与能力门无关，缩略图必须出现');

        await tester.enterText(
            find.byType(TextField), '这张图片主要是什么颜色？只回答一个中文颜色词。');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await _waitForTurnComplete(tester);

        // 3. 界面：气泡里必须多一行提示（先把列表拖回顶部，让那条气泡真的被建出来）
        await _scrollChatToTop(tester);
        final notice = find.text('模型未声明图片输入，本次没有发送图片');
        // ignore: avoid_print
        print('  [OBS] 界面提示"模型未声明图片输入…"出现次数 = '
            '${notice.evaluate().length}');
        await captureLiveShot(tester, captureKey, 'live_image_gate');
        expect(notice, findsWidgets,
            reason: '图没发出去这件事必须看得见（不能静默丢掉）');

        // 4. 库：那条用户消息仍然带着图片路径
        final db = await DatabaseService.database;
        final rows = await db.query('messages',
            orderBy: 'created_at DESC, seq DESC', limit: 4);
        final userRow = rows.firstWhere(
            (r) => r['role'] == 'user' && r['attachments'] != null,
            orElse: () => <String, Object?>{});
        // ignore: avoid_print
        print('  [OBS] 带附件的用户消息 => ${userRow['attachments']}');
        expect(userRow, isNotEmpty,
            reason: '图片没发出去，但历史里仍然要留着它的路径');

        // 5. **请求本身**：不能有 image 块。这条是判据的核心 —— 它看的是真的发出去的
        //    那份请求（应用捕获的 contextSnapshot），不是模型的回答。
        final screen = find.byType(ChatScreen);
        expect(screen.evaluate(), isNotEmpty);
        final snap = tester.state<ChatScreenState>(screen).contextSnapshot;
        expect(snap, isNotNull, reason: '这一轮必须抓到一份请求快照');
        final requestJson = jsonEncode(snap!.messages);
        // ignore: avoid_print
        print('  [OBS] 请求快照里消息条数=${snap.messages.length} '
            '出现 "type":"image" 的次数=${'"type":"image"'.allMatches(requestJson).length}');
        // ignore: avoid_print
        print('  [OBS] 请求里那段"未发送"标记 => '
            '${requestJson.contains("图片未发送")}');
        expect(requestJson, isNot(contains('"type":"image"')),
            reason: '模型没声明图片输入时，请求里不许出现 image 块');
        expect(requestJson, contains('图片未发送'),
            reason: '不发图必须留一句可见的标记（不能静默丢掉）');

        // 模型的回答只作现场记录，不当判据：它能在没看到图的情况下猜一个颜色
        // （本用例第一次跑就答了「红色」，而那次请求里根本没有图）。
        final reply = readFinalAssistantReply(tester) ?? '';
        // ignore: avoid_print
        print('  [OBS] 模型回答（仅记录，不断言）=> 「$reply」');
        expect(reply, isNotEmpty);
      } finally {
        restoreConfig();
      }
    },
    timeout: const Timeout(Duration(seconds: 360)),
  );
}
