@Tags(['live'])
library;

import 'dart:io';
import 'dart:convert';
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

import 'live_observability.dart';

/// 18.1：复现「粘贴图片」**第一次点没反应**（2026-10-25 用户要求）。
///
/// 背景：跑 13.1 的 live 用例时日志出现
/// `第 1 次点「粘贴图片」→ 待发缩略图 = false`、`第 2 次 → true`。
/// 用例点了 3 次所以照样绿，但**用户只会点一次**。
///
/// 这条用例**不调模型**，只做一件事：点一次，然后在 2 秒内每 100ms 看一眼缩略图
/// 有没有出现。判据是"点一次必须成功"—— 现象还在就红，并把轮询到第几次、
/// 以及 C++ `read_clipboard_image` 的原文一起打进日志，作为修之前的基线。
///
/// **副作用**：会覆盖你当前剪贴板内容（放一张纯红图）。与 13.1 同一须知。
Future<Uint8List> _makeRedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 64, 64),
    Paint()..color = const Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<String?> _putImageOnClipboard(String pngPath) async {
  if (!Platform.isWindows) return '仅在 Windows 上跑这条用例';
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($env:ALIASAGENT_CLIP_IMG)
try { [System.Windows.Forms.Clipboard]::SetImage($img) } finally { $img.Dispose() }
Write-Output "OK"
''';
  try {
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-Command', script],
      environment: {'ALIASAGENT_CLIP_IMG': pngPath},
    );
    if (result.exitCode != 0) {
      return 'PowerShell 退出码 ${result.exitCode}: ${result.stderr}';
    }
    if (!result.stdout.toString().contains('OK')) {
      return 'PowerShell 没有回 OK: ${result.stdout}';
    }
    return null;
  } catch (e) {
    return '调用 PowerShell 失败: $e';
  }
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
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_paste_click_');
    await DatabaseService.openAt(tempDir.path);
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

  testWidgets('只点一次「粘贴图片」，缩略图必须在 2 秒内出现', (tester) async {
    if (configProblem != null) {
      markTestSkipped('配置不满足：$configProblem');
      return;
    }

    // 1. 造图 + 放上真实剪贴板
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

    // 2. 起真窗口（只给 2 秒 —— 与 13.1 一模一样，不等工具就绪）
    await tester.pumpWidget(MaterialApp(
      home: AppShell(configLoader: () => ConfigResult.ok(configResult.config!)),
    ));
    await tester.pump(const Duration(seconds: 2));

    // 2.5 记下此刻"工具就绪"这个状态 —— 13.1 就是在这个时刻点的按钮。
    //     发送按钮的 tooltip 只有在工具就绪时才是 `Send`。
    final readyNow = find.byTooltip('Send').evaluate().isNotEmpty;
    // ignore: avoid_print
    print('  [OBS] 起窗口 2 秒时：工具已就绪 = $readyNow；'
        '「粘贴图片」按钮存在 = ${find.byTooltip('粘贴图片').evaluate().isNotEmpty}');
    expect(find.byTooltip('粘贴图片'), findsOneWidget, reason: '输入行必须有「粘贴图片」按钮');

    // 3. **只点一次**（就在工具可能还没就绪的时刻点 —— 这才是 13.1 的时序）
    await tester.tap(find.byTooltip('粘贴图片'));
    await tester.pump();

    var appearedAt = -1;
    for (var i = 1; i <= 20; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      if (find.byTooltip('移除这张图').evaluate().isNotEmpty) {
        appearedAt = i;
        break;
      }
    }
    // ignore: avoid_print
    print('  [OBS] 点一次之后：第 $appearedAt 次轮询（每次 100ms）出现缩略图'
        '（-1 表示 2 秒内始终没出现）');
    // 贴图失败时界面上会有一句提示，把它也打出来 —— 静默无反应是最难查的状态
    final notice = find.textContaining('剪贴板');
    // ignore: avoid_print
    print('  [OBS] 界面上的剪贴板提示条数 = ${notice.evaluate().length}');

    expect(appearedAt, greaterThan(0),
        reason: '点一次「粘贴图片」就必须把缩略图贴出来；'
            '第一次点没反应正是 18.1 要复现并修掉的现象');
  }, timeout: const Timeout(Duration(seconds: 300)));
}
