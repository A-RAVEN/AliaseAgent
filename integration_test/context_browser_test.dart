// 真桌面浏览器验收（change `add-context-handles` 任务 3.5）。
//
// 用真实的 `sidecar.dll` + 真实的 Python 浏览器子进程：两个上下文各导航到不同页面，
// 各自读回快照，证明它们**不是同一个页面**。
//
// 死亡代次与并发启停已分别在任务 1.9 的 C++/Python 协议测试里覆盖，这一层不重复注入。
//
// 本用例会在两个页面都打开后写就绪标记并停住，留出时间让外部用
// `desktop-screenshot` 做 OS 全屏截图（截图由执行者 read_image 验收）：
//   - 就绪标记：`%TEMP%\add-context-handles-browser-ready.txt`
//   - 放行标记：`%TEMP%\add-context-handles-browser-shot-done.txt`（外部读完截图后创建）
//
// 跑法：`flutter test integration_test/context_browser_test.dart -d windows`

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

Map<String, dynamic> _decode(String raw, String what) {
  final parsed = jsonDecode(raw);
  if (parsed is! Map<String, dynamic>) {
    fail('$what 返回的不是 JSON 对象：$raw');
  }
  return parsed;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridge = SidecarBridge.instance;
  const ctxA = 'browser-甲';
  const ctxB = 'browser-乙';

  final tempDir = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
  final readyFile =
      File('$tempDir${Platform.pathSeparator}add-context-handles-browser-ready.txt');
  final shotDoneFile =
      File('$tempDir${Platform.pathSeparator}add-context-handles-browser-shot-done.txt');

  const pageA = 'data:text/html,<html><head><title>ALPHA-PAGE-ONE</title></head>'
      '<body><h1>ALPHA-MARKER-ONE</h1></body></html>';
  const pageB = 'data:text/html,<html><head><title>BETA-PAGE-TWO</title></head>'
      '<body><h1>BETA-MARKER-TWO</h1></body></html>';

  setUpAll(() async {
    if (readyFile.existsSync()) readyFile.deleteSync();
    if (shotDoneFile.existsSync()) shotDoneFile.deleteSync();
    // 先清掉上一次可能残留的上下文（dispose 对未建过的句柄也是成功）。
    await bridge.disposeContext(ctxA);
    await bridge.disposeContext(ctxB);
  });

  tearDownAll(() async {
    for (final ctx in [ctxA, ctxB]) {
      try {
        await bridge.disposeContext(ctx);
      } catch (e) {
        // ignore: avoid_print
        print('[3.5] tearDown dispose($ctx) 忽略：$e');
      }
    }
    if (readyFile.existsSync()) readyFile.deleteSync();
  });

  testWidgets('两个上下文各导航不同页面并读快照，留出 OS 截图时间', (tester) async {
    final avail = _decode(await bridge.browserAvailable(), 'browser_available');
    // ignore: avoid_print
    print('[3.5] browser_available: ${jsonEncode(avail)}');
    expect(avail['available'], isTrue,
        reason: '这一层必须用真实桌面浏览器；浏览器栈不可用时不能算通过');

    final createdA = await bridge.ensureContext(ctxA);
    final createdB = await bridge.ensureContext(ctxB);
    // ignore: avoid_print
    print('[3.5] ensureContext($ctxA)=$createdA ensureContext($ctxB)=$createdB');

    final navA = _decode(
        await bridge.browserNavigate(ctxA, jsonEncode({'url': pageA})), '甲 navigate');
    // ignore: avoid_print
    print('[3.5] 甲 navigate: ok=${navA['ok']} url=${navA['url']} '
        'title=${navA['title']} snapshot_len=${navA['snapshot_len']}');
    expect(navA['ok'], isTrue, reason: '甲的导航必须成功：${jsonEncode(navA)}');
    expect(navA['snapshot'], contains('ALPHA-MARKER-ONE'));

    final navB = _decode(
        await bridge.browserNavigate(ctxB, jsonEncode({'url': pageB})), '乙 navigate');
    // ignore: avoid_print
    print('[3.5] 乙 navigate: ok=${navB['ok']} url=${navB['url']} '
        'title=${navB['title']} snapshot_len=${navB['snapshot_len']}');
    expect(navB['ok'], isTrue, reason: '乙的导航必须成功：${jsonEncode(navB)}');
    expect(navB['snapshot'], contains('BETA-MARKER-TWO'));

    // 两张页面必须不同：URL、标题、快照三样都不同。
    expect(navA['url'], isNot(equals(navB['url'])),
        reason: '两个上下文的 URL 必须不同（否则就是同一个页面）');
    expect(navA['title'], 'ALPHA-PAGE-ONE');
    expect(navB['title'], 'BETA-PAGE-TWO');
    expect(navA['title'], isNot(equals(navB['title'])));

    // 再各读一次快照：证明两边的页面各自留在自己的上下文里，乙的导航没有把甲带走。
    final snapA = _decode(await bridge.browserSnapshot(ctxA, '{}'), '甲 snapshot');
    final snapB = _decode(await bridge.browserSnapshot(ctxB, '{}'), '乙 snapshot');
    // ignore: avoid_print
    print('[3.5] 快照甲：ok=${snapA['ok']} url=${snapA['url']} '
        'title=${snapA['title']} snapshot_len=${snapA['snapshot_len']}');
    // ignore: avoid_print
    print('[3.5] 快照乙：ok=${snapB['ok']} url=${snapB['url']} '
        'title=${snapB['title']} snapshot_len=${snapB['snapshot_len']}');
    expect(snapA['ok'], isTrue);
    expect(snapB['ok'], isTrue);
    expect(snapA['snapshot'], contains('ALPHA-MARKER-ONE'));
    expect(snapA['snapshot'], isNot(contains('BETA-MARKER-TWO')));
    expect(snapB['snapshot'], contains('BETA-MARKER-TWO'));
    expect(snapB['snapshot'], isNot(contains('ALPHA-MARKER-ONE')));
    expect(snapA['url'], isNot(equals(snapB['url'])));

    // 两个页面都开好了，写就绪标记，然后停住等外部截图。
    readyFile.writeAsStringSync(
        'ready ${DateTime.now().toIso8601String()}\n'
        '甲 url=${navA['url']} title=${navA['title']}\n'
        '乙 url=${navB['url']} title=${navB['title']}\n');
    // ignore: avoid_print
    print('[3.5] READY_FOR_SCREENSHOT 标记已写：${readyFile.path}');
    // ignore: avoid_print
    print('[3.5] 等待外部截图放行文件：${shotDoneFile.path}（最多 180 秒）');

    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(deadline) && !shotDoneFile.existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    // ignore: avoid_print
    print('[3.5] 截图窗口结束：shotDone=${shotDoneFile.existsSync()}');

    // 截图之后页面仍在：证明截图拍到的是这两个活着的页面。
    final finalA = _decode(await bridge.browserSnapshot(ctxA, '{}'), '甲 snapshot 收尾');
    final finalB = _decode(await bridge.browserSnapshot(ctxB, '{}'), '乙 snapshot 收尾');
    // ignore: avoid_print
    print('[3.5] 收尾快照甲：ok=${finalA['ok']} title=${finalA['title']}');
    // ignore: avoid_print
    print('[3.5] 收尾快照乙：ok=${finalB['ok']} title=${finalB['title']}');
    expect(finalA['ok'], isTrue);
    expect(finalB['ok'], isTrue);
    expect(finalA['title'], 'ALPHA-PAGE-ONE');
    expect(finalB['title'], 'BETA-PAGE-TWO');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
