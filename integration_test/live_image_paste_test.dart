@Tags(['live'])
library;

// 真实剪贴板贴图 → 真模型看图（add-image-input 任务 13.1）。
//
// 这条路是真端到端：把一张 64×64 纯红 PNG 放进**真实剪贴板** → 点「粘贴图片」→
// 缩略图出现 → 发一句"这张图是什么颜色" → 断言的回答里必须是"红"。
// 如果图没被真的发出去，模型只会说看不到图（或瞎猜），所以"含红"这条能判死。
//
// 隔离（与其余 live 套件一致）：
//   - `@Tags(['live'])` + `dart_test.yaml` 的 `tags.live.skip`：默认跑
//     `flutter test integration_test` 会跳过它（并显示原因）。
//   - 要显式跑：
//       flutter test --tags live --run-skipped integration_test/live_image_paste_test.dart -d windows
//   - 前提：`%USERPROFILE%\.aliasagent\config.json` 里 general 的 provider 有
//     api_key / base_url / model，且 `input_modalities` 含 image。缺哪一条就
//     `markTestSkipped`，并说明缺的是哪一条。
//
// **副作用须知**：这条用例会**覆盖你当前剪贴板里的内容**（放进去一张纯红图）。
// 这是"验证贴图"唯一真实的办法，别在剪贴板里有重要东西时跑它。
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
import 'package:alias_agent/services/image_probe.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/ui/chat_area.dart';

import 'live_observability.dart';

/// 造一张 64×64 纯红 PNG。用 Flutter 自己的 `toByteData(png)` 编码，
/// 不依赖任何外部命令，也不往仓库里塞二进制夹具。
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

/// 把一张图片文件放进**真实剪贴板**（Windows）。
///
/// Dart 的 `Clipboard` 只支持文本，图片必须走 Win32/OLE，所以借一次
/// PowerShell：`Clipboard.SetImage` 内部是带 copy 的 `SetDataObject`，进程退出后
/// 内容仍然留在剪贴板上。返回 null 表示成功，否则是失败原因。
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

/// 等这一轮跑完：`ChatArea.isStreaming` 变回 false（与 live_file_tools_test 同口径）。
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
    } else if (provider == null) {
      configProblem = 'general 引用的 provider 不存在';
    } else if (provider.apiKey.isEmpty || provider.baseUrl.isEmpty) {
      configProblem = 'provider 的 api_key / base_url 不完整';
    } else if (general.model.isEmpty) {
      configProblem = 'general 没有 model';
    } else if (!general.inputModalities.contains('image')) {
      configProblem = 'general 的 input_modalities 不含 image'
          '（现在是 ${general.inputModalities.join(",")}）—— 图不会发出去';
    }
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('aliasagent_img_live_');
    await DatabaseService.openAt(tempDir.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁 —— 交给系统清理
      }
    }
  });

  testWidgets(
    '贴一张纯红图 → 模型答出红色',
    (tester) async {
      if (configProblem != null) {
        markTestSkipped('配置不满足：$configProblem');
        return;
      }

      // 1. 造图 + 写文件（真实 I/O，用 runAsync）
      late String pngPath;
      await tester.runAsync(() async {
        pngPath = '${tempDir.path}${Platform.pathSeparator}red64.png';
        await File(pngPath).writeAsBytes(await _makeRedPng(), flush: true);
      });
      // ignore: avoid_print
      print('  [OBS] 夹具图片 => $pngPath（${File(pngPath).lengthSync()} 字节）');

      // 2. 放进真实剪贴板
      String? clipError;
      await tester.runAsync(() async {
        clipError = await _putImageOnClipboard(pngPath);
      });
      if (clipError != null) {
        markTestSkipped('放不进剪贴板：$clipError');
        return;
      }

      // 3. 起应用
      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      await tester.pump(const Duration(seconds: 2));

      try {
        // 4. 先直接问一次 C++：剪贴板里到底有没有我们放进去的那张图。
        //    这一步把"剪贴板读不出来"和"界面没反应"分开 —— 否则失败时说不清卡在哪。
        //    同时它也是 13.4 的判据：**落盘文件的宽高必须等于放进去那张图的宽高**。
        String direct = '';
        for (var attempt = 1; attempt <= 3; attempt++) {
          direct = SidecarBridge.instance.readClipboardImage(
              jsonEncode({'dest_dir': tempDir.path}));
          // ignore: avoid_print
          print('  [OBS] 第 $attempt 次直接调 read_clipboard_image => $direct');
          if (direct.contains('"ok":true')) break;
          // Windows 剪贴板是独占资源，可能被别的程序短暂占着（这时回 busy）。
          // 重放一次图再试；真的读不出来时下面的断言仍然会红。
          await tester.runAsync(() async {
            await _putImageOnClipboard(pngPath);
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
        }
        expect(direct, contains('"ok":true'),
            reason: 'C++ 这边必须能从真实剪贴板读出图片：$direct');

        // 13.4：宽高对得上（源文件用 Dart 侧自己的解析器量一遍，两边独立）
        final pasted = jsonDecode(direct) as Map<String, dynamic>;
        final srcInfo = probeImageBytes(File(pngPath).readAsBytesSync());
        // ignore: avoid_print
        print('  [OBS] 源图 ${srcInfo.width}x${srcInfo.height} '
            '落盘 ${pasted['width']}x${pasted['height']} '
            '（落盘 ${pasted['bytes']} 字节，源 ${srcInfo.bytes} 字节）');
        expect(pasted['width'], srcInfo.width,
            reason: '落盘 PNG 的宽必须等于放进去那张图的宽');
        expect(pasted['height'], srcInfo.height,
            reason: '落盘 PNG 的高必须等于放进去那张图的高');
        expect(File(pasted['path'] as String).existsSync(), isTrue,
            reason: '回报的路径必须真的有文件');

        // 5. 点「粘贴图片」→ 等缩略图出现。
        //    **必须给真实异步留窗口**：贴图回调里要做真实文件 I/O（读剪贴板、落盘），
        //    而 `pump()` 只推进假时钟、不推进真实 I/O —— 用 `runAsync` 放行。
        expect(find.byTooltip('粘贴图片'), findsOneWidget,
            reason: '输入行必须有「粘贴图片」按钮');
        var hasThumb = false;
        for (var attempt = 1; attempt <= 3 && !hasThumb; attempt++) {
          await tester.tap(find.byTooltip('粘贴图片'));
          for (var i = 0; i < 10 && !hasThumb; i++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            });
            await tester.pump();
            hasThumb = find.byTooltip('移除这张图').evaluate().isNotEmpty;
          }
          // ignore: avoid_print
          print('  [OBS] 第 $attempt 次点「粘贴图片」→ 待发缩略图 = $hasThumb');
        }
        expect(hasThumb, isTrue, reason: '贴成功后输入框上方必须出现待发缩略图');

        // 5. 发一句问颜色
        await tester.enterText(
            find.byType(TextField), '这张图片主要是什么颜色？只回答一个中文颜色词。');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        await _waitForTurnComplete(tester);

        // 6. 现场：工具调用 + 实测用量
        await dumpNoTool(tester, 'live-image-paste 结束后');
        final db = await DatabaseService.database;
        final rows = await db.query('messages',
            orderBy: 'created_at DESC, seq DESC', limit: 5);
        for (final r in rows) {
          // ignore: avoid_print
          print('  [OBS] 消息 role=${r['role']} '
              'attachments=${r['attachments']} '
              'token_count=${r['token_count']} '
              'output_token_count=${r['output_token_count']}');
        }
        final userRow = rows.firstWhere(
            (r) => r['role'] == 'user' && r['attachments'] != null,
            orElse: () => <String, Object?>{});
        // ignore: avoid_print
        print('  [OBS] 带附件的用户消息 => ${userRow['attachments']}');
        expect(userRow, isNotEmpty,
            reason: '这条用户消息必须真的带上了那个图片路径（历史只存路径）');
        expect(jsonDecode(userRow['attachments'] as String) as List, hasLength(1));

        final assistantRow =
            rows.firstWhere((r) => r['role'] == 'assistant', orElse: () => {});
        // ignore: avoid_print
        print('  [OBS] 本轮 usage.in=${assistantRow['token_count']} '
            'usage.out=${assistantRow['output_token_count']}');
        expect((assistantRow['token_count'] as int?) ?? 0, greaterThan(0),
            reason: '必须拿到服务端实测的输入 token 数');

        // 7. 断言回答
        final reply = readFinalAssistantReply(tester) ?? '';
        // ignore: avoid_print
        print('  [OBS] 模型回答 => 「$reply」');
        expect(reply, isNotEmpty, reason: '必须有最终回答');
        expect(reply, isNot(startsWith('Error:')),
            reason: '这一轮不该是错误回复：$reply');
        expect(reply, contains('红'),
            reason: '图片是纯红的；答不出红色说明图没真的发出去。回答原文：$reply');
      } finally {
        await captureLiveShot(tester, captureKey, 'live_image_paste');
      }
    },
    timeout: const Timeout(Duration(seconds: 360)),
  );
}
