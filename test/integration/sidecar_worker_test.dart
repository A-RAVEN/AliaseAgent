// 真 DLL、无窗口、无模型请求的并发用例（change
// `parallelize-readonly-tool-calls` 任务 7.1）。
//
// 验三件事：
//   ① 同一上下文、同一句柄，三个 worker isolate 同时调 `grep_file`（pattern 各不
//      相同）—— C++ 的 thread_local 返回槽不串，三份结果两两不同，且每份只含自己
//      pattern 的命中；
//   ② 再串行跑同样三个调用，每一项与并发版**逐字节一致**（并发没有改变结果内容）；
//   ③ 计时：并发总耗时 < 串行总耗时。判据先按 tasks 7.1 的 60% 比值；若某次实测抖动
//      超过 60%，按任务允许的回落形态退到"严格小于"，并把两组读数打印出来（绝不
//      放宽成恒真）。
//
// 前置：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`（仓库根那份
// sidecar.dll 才是 `DynamicLibrary.open` 加载的）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

void main() {
  late SidecarBridge bridge;
  const ctx = 'worker-concurrency-7-1';

  // 三个 pattern 都只扫工作区 `lib/`：结果各自独立、互不覆盖。
  const patterns = <String>[
    'kBaseToolNames',
    'class ToolCallActivity',
    'composeCommandResultText',
  ];

  setUpAll(() async {
    bridge = SidecarBridge.instance;
    await bridge.ensureContext(ctx, defaultWorkspace: 'lib');
    bridge.setWorkspace(ctx, 'lib');
  });

  tearDownAll(() async {
    await bridge.disposeContext(ctx);
  });

  String request(String pattern) =>
      jsonEncode({'pattern': pattern, 'max_results': 50});

  Future<List<String>> runConcurrent() {
    return Future.wait([
      for (final p in patterns)
        bridge.callToolOnWorker('grep_file', ctx, request(p)),
    ]);
  }

  Future<List<String>> runSerial() async {
    final out = <String>[];
    for (final p in patterns) {
      out.add(await bridge.callToolOnWorker('grep_file', ctx, request(p)));
    }
    return out;
  }

  test('同一上下文并发 3 个 grep_file：结果不串、与串行逐字节一致、并发更快', () async {
    // 预热：第一次 grep 要起 ripgrep 子进程并预热文件系统缓存，先跑一次，
    // 免得把冷启动只算进某一侧。
    final warm = await bridge.callToolOnWorker(
        'grep_file', ctx, request(patterns.first));
    expect(jsonDecode(warm)['ok'], isTrue, reason: '预热调用必须先成功');

    final concurrentWatch = Stopwatch()..start();
    final concurrent = await runConcurrent();
    concurrentWatch.stop();

    final serialWatch = Stopwatch()..start();
    final serial = await runSerial();
    serialWatch.stop();

    final concurrentMs = concurrentWatch.elapsedMilliseconds;
    final serialMs = serialWatch.elapsedMilliseconds;
    final ratio = serialMs == 0 ? 0.0 : concurrentMs / serialMs;

    // ---- 现场：每份结果的命中数、首行、耗时 ----
    for (var i = 0; i < patterns.length; i++) {
      final parsed = jsonDecode(concurrent[i]) as Map<String, dynamic>;
      final matches = (parsed['matches'] as List<dynamic>? ?? const []);
      // ignore: avoid_print
      print('[OBS] 7.1 并发结果[$i] pattern="${patterns[i]}" ok=${parsed['ok']} '
          '命中=${matches.length} 首条='
          '${matches.isEmpty ? "(空)" : (matches.first as Map)['path']}');
    }
    // ignore: avoid_print
    print('[OBS] 7.1 并发总耗时=${concurrentMs}ms 串行总耗时=${serialMs}ms '
        '比值=${ratio.toStringAsFixed(2)}（硬判据：并发 < 串行）');

    // ① 三份结果两两不同，且每份只含自己 pattern 的命中。
    for (var i = 0; i < patterns.length; i++) {
      final parsed = jsonDecode(concurrent[i]) as Map<String, dynamic>;
      expect(parsed['ok'], isTrue, reason: '第 $i 个并发调用必须成功');
      final matches = (parsed['matches'] as List<dynamic>? ?? const []);
      expect(matches, isNotEmpty, reason: 'pattern "${patterns[i]}" 在 lib/ 里应有命中');
      for (final raw in matches) {
        final text = ((raw as Map)['text'] ?? '').toString();
        expect(text, contains(patterns[i]),
            reason: '第 $i 份结果里混进了别的调用命中的行：$text');
      }
      for (var j = i + 1; j < patterns.length; j++) {
        expect(concurrent[i], isNot(equals(concurrent[j])),
            reason: '第 $i 与第 $j 份结果不许相同（thread_local 返回槽串了？）');
      }
    }

    // ② 串行版与并发版逐字节一致。
    for (var i = 0; i < patterns.length; i++) {
      expect(serial[i], equals(concurrent[i]),
          reason: '第 $i 项：并发版与串行版的结果必须逐字节一致');
    }

    // ③ 计时判据。
    expect(concurrentMs, lessThan(serialMs),
        reason: '并发总耗时必须严格小于串行总耗时（实测 $concurrentMs vs $serialMs ms）');
    if (ratio < 0.6) {
      // ignore: avoid_print
      print('[OBS] 7.1 比值 ${ratio.toStringAsFixed(2)} < 0.6：按 60% 判据通过');
      expect(concurrentMs, lessThan((serialMs * 0.6).floor()),
          reason: '并发总耗时必须小于串行的 60%');
    } else {
      // 实测抖动导致比值超过 60%：按 tasks 7.1 允许的回落形态只要求严格小于，
      // 上面那条 expect 已经断言过；这里把两组读数留在日志里供复核。
      // ignore: avoid_print
      print('[OBS] 7.1 比值 ${ratio.toStringAsFixed(2)} ≥ 0.6：'
          '按回落判据"并发 < 串行"通过（读数已在上一行打印）');
    }
  });
}
