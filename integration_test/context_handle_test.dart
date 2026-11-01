// 真 DLL 端到端验收（change `add-context-handles` 任务 3.4）。
//
// 这里不经过界面、不经过假 sidecar：直接拿真实的 `sidecar.dll`，用
// `SidecarBridge` 的公开方法建上下文、跑 `run_command`、读 `read_spill`、销毁上下文。
// 覆盖 tasks.md 点名的五件事：
//   ① 两个上下文与同一句柄并发 `run_command`；
//   ② 跨上下文 `read_spill` 拒绝（绝对路径 + `乙/../甲` 两种）；
//   ③ 长命令执行中销毁上下文（销毁要等它真结束，之后新调用报 unknown_context）；
//   ④ 恢复会话后的工具调用（同名再 ensure 得到 created:false，序号接着往后走，工具不报 unknown_context）；
//   ⑤ 每次调用都打印句柄、序号、结果摘要与文件路径，失败时有现场可看。
//
// 跑法：`flutter test integration_test/context_handle_test.dart -d windows`
//
// 进程重启续号由任务 2.4 的 C++ 测试钩子覆盖（`reset_registry_for_tests()`），
// 这一层不伪造进程重启。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/spill_paths.dart';

Map<String, dynamic> _decode(String raw, String what) {
  final parsed = jsonDecode(raw);
  if (parsed is! Map<String, dynamic>) {
    fail('$what 返回的不是 JSON 对象：$raw');
  }
  return parsed;
}

/// 从 spill 引用路径里取出文件名序号（`000001-stdout.txt` -> 1）。
int _seqOf(String ref) {
  final name = ref.split(Platform.pathSeparator).last;
  final dash = name.indexOf('-');
  final head = dash < 0 ? name : name.substring(0, dash);
  final seq = int.tryParse(head);
  if (seq == null) {
    fail('spill 文件名里没有 6 位序号：$ref');
  }
  return seq;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridge = SidecarBridge.instance;

  // 中文句柄：同时验证 spill 目录名的 %XX 编码与两侧一致性。
  const ctxA = 'e2e-甲';
  const ctxB = 'e2e-乙';
  const ctxC = 'e2e-丙';

  /// 跑一条命令并解析返回；断言成功，返回 (json, stdout 引用, 序号, 该流字节数)。
  ///
  /// 注意 `read_spill` 的区间是**严格**的：`offset + limit` 超过文件总字节数会报
  /// 「读取区间越界」而不是静默截断。所以读回时 `limit` 必须正好用 `total_bytes`。
  Future<({Map<String, dynamic> json, String ref, int seq, int total})> runOk(
      String handle, String command, String label) async {
    final raw = await bridge.runCommand(handle, jsonEncode({
      'command': command,
      'timeout_ms': 30000,
    }));
    final r = _decode(raw, label);
    final spill = r['spill'];
    expect(r['ok'], isTrue, reason: '$label 必须成功：$raw');
    expect(spill, isA<Map>(), reason: '$label 必须先落盘并给出 spill 信封：$raw');
    final stdout = (spill as Map)['stdout'] as Map;
    final ref = stdout['ref'] as String;
    final total = stdout['total_bytes'] as int;
    final seq = _seqOf(ref);
    // ignore: avoid_print
    print('[3.4] $label 句柄=$handle 序号=$seq 字节=$total '
        'exit=${r['exit_code']} ok=${r['ok']} 文件=$ref');
    return (json: r, ref: ref, seq: seq, total: total);
  }

  setUpAll(() async {
    // 先幂等销毁一次，让 spill 目录与序号从 1 开始（dispose 对未建过的句柄也是成功）。
    await bridge.disposeContext(ctxA);
    await bridge.disposeContext(ctxB);
    await bridge.disposeContext(ctxC);
    // 上一次跑到一半留下的目录也直接清掉：本用例断言"序号从 1 开始"，
    // 不能依赖 C++ 对未登记句柄的 dispose 会顺手删目录。
    final root = Directory(spillRoot());
    for (final ctx in [ctxA, ctxB, ctxC]) {
      final dir = Directory(
          '${root.path}${Platform.pathSeparator}${spillSessionDirName(ctx)}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  tearDownAll(() async {
    for (final ctx in [ctxA, ctxB, ctxC]) {
      try {
        await bridge.disposeContext(ctx);
      } catch (e) {
        // 清理失败不影响判据（上下文可能已经在用例里被销毁）。
        // ignore: avoid_print
        print('[3.4] tearDown dispose($ctx) 忽略：$e');
      }
    }
  });

  testWidgets('两个上下文各跑一次 run_command：各自目录、序号都从 1 开始', (tester) async {
    final createdA = await bridge.ensureContext(ctxA);
    final createdB = await bridge.ensureContext(ctxB);
    // ignore: avoid_print
    print('[3.4] ensureContext($ctxA) created=$createdA；'
        'ensureContext($ctxB) created=$createdB');

    final a = await runOk(ctxA, 'Write-Output "alpha-marker-甲"', '甲第一次');
    final b = await runOk(ctxB, 'Write-Output "beta-marker-乙"', '乙第一次');

    expect(File(a.ref).existsSync(), isTrue, reason: '甲的 spill 文件必须存在：${a.ref}');
    expect(File(b.ref).existsSync(), isTrue, reason: '乙的 spill 文件必须存在：${b.ref}');
    expect(a.ref, contains(spillSessionDirName(ctxA)),
        reason: '甲的引用必须落在甲编码后的目录：${a.ref}');
    expect(b.ref, contains(spillSessionDirName(ctxB)),
        reason: '乙的引用必须落在乙编码后的目录：${b.ref}');
    expect(a.seq, 1, reason: '甲的第一条输出应该是 000001');
    expect(b.seq, 1, reason: '乙的第一条输出应该是 000001（各上下文各自从 1 开始）');
    expect(a.ref, isNot(equals(b.ref)));

    // 用各自的句柄把内容读回来，证明目录归属与编号一致。
    final readA = _decode(
        bridge.readSpill(
            ctxA, jsonEncode({'ref': a.ref, 'offset': 0, 'limit': a.total})),
        '甲 read_spill');
    final readB = _decode(
        bridge.readSpill(
            ctxB, jsonEncode({'ref': b.ref, 'offset': 0, 'limit': b.total})),
        '乙 read_spill');
    // ignore: avoid_print
    print('[3.4] 甲读回 ok=${readA['ok']} bytes=${readA['bytes_read']} '
        'error=${readA['error']}；乙读回 ok=${readB['ok']} '
        'bytes=${readB['bytes_read']} error=${readB['error']}');
    expect(readA['ok'], isTrue, reason: '甲读自己的引用必须成功');
    expect(readA['text'], contains('alpha-marker-甲'));
    expect(readB['ok'], isTrue, reason: '乙读自己的引用必须成功');
    expect(readB['text'], contains('beta-marker-乙'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('同一句柄并发两条 run_command：序号不同、内容各归各的', (tester) async {
    // 两条命令并发从同一个句柄取号：慢的一条先发、快的一条后发，
    // 必须拿到不同序号，且每份文件的内容都对应自己的命令（不能被对方覆盖）。
    final results = await Future.wait([
      runOk(ctxA, 'Start-Sleep -Milliseconds 400; Write-Output "concurrent-slow-甲"',
          '并发-慢'),
      runOk(ctxA, 'Write-Output "concurrent-fast-甲"', '并发-快'),
    ]);
    final slow = results[0];
    final fast = results[1];

    expect(slow.ref, isNot(equals(fast.ref)), reason: '并发两条命令不许落到同一个 spill 文件');
    expect(slow.seq, isNot(equals(fast.seq)), reason: '同一句柄并发取号必须不同');

    final slowRead = _decode(
        bridge.readSpill(
            ctxA, jsonEncode({'ref': slow.ref, 'offset': 0, 'limit': slow.total})),
        '并发-慢 read_spill');
    final fastRead = _decode(
        bridge.readSpill(
            ctxA, jsonEncode({'ref': fast.ref, 'offset': 0, 'limit': fast.total})),
        '并发-快 read_spill');
    // ignore: avoid_print
    print('[3.4] 并发读数：慢 seq=${slow.seq} ok=${slowRead['ok']} '
        'error=${slowRead['error']}；快 seq=${fast.seq} ok=${fastRead['ok']} '
        'error=${fastRead['error']}');
    expect(slowRead['ok'], isTrue);
    expect(fastRead['ok'], isTrue);
    expect(slowRead['text'], contains('concurrent-slow-甲'),
        reason: '慢命令的文件里必须是慢命令自己的输出');
    expect(fastRead['text'], contains('concurrent-fast-甲'),
        reason: '快命令的文件里必须是快命令自己的输出');
    expect(slowRead['text'], isNot(contains('concurrent-fast-甲')));
    expect(fastRead['text'], isNot(contains('concurrent-slow-甲')));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('用乙的句柄读甲的引用：直接路径与 乙/../甲 都被拒绝', (tester) async {
    final a = await runOk(ctxA, 'Write-Output "owned-by-甲"', '甲给跨上下文用例');
    final b = await runOk(ctxB, 'Write-Output "owned-by-乙"', '乙给跨上下文用例');

    // ① 直接拿甲的绝对路径引用，用乙的句柄读。
    final directRaw = bridge.readSpill(
        ctxB, jsonEncode({'ref': a.ref, 'offset': 0, 'limit': a.total}));
    final direct = _decode(directRaw, '跨上下文 read_spill');
    // ignore: avoid_print
    print('[3.4] 直接跨上下文：ok=${direct['ok']} error=${direct['error']}');
    expect(direct['ok'], isFalse, reason: '乙读甲的引用必须失败：$directRaw');
    expect(direct['error'], contains('不属于'),
        reason: '错误必须说明引用不属于该上下文：${direct['error']}');

    // ② 中间加 `..` 绕过：乙目录/../甲目录/甲的spill文件名。
    final bDir = File(b.ref).parent.path;
    final aFile = File(a.ref);
    final aDirName = aFile.parent.path.split(Platform.pathSeparator).last;
    final aName = aFile.path.split(Platform.pathSeparator).last;
    final dotdotRef = '$bDir${Platform.pathSeparator}..${Platform.pathSeparator}'
        '$aDirName${Platform.pathSeparator}$aName';
    final dotdotRaw = bridge.readSpill(
        ctxB, jsonEncode({'ref': dotdotRef, 'offset': 0, 'limit': a.total}));
    final dotdot = _decode(dotdotRaw, '乙/../甲 read_spill');
    // ignore: avoid_print
    print('[3.4] 乙/../甲：ref=$dotdotRef ok=${dotdot['ok']} error=${dotdot['error']}');
    expect(File(dotdotRef).existsSync(), isTrue,
        reason: '这条路径经文件系统解析确实指向甲的文件，所以拒绝必须来自归属检查');
    expect(dotdot['ok'], isFalse, reason: '乙/../甲 必须拒绝：$dotdotRaw');
    expect('${dotdot['text'] ?? ''}', isNot(contains('owned-by-甲')),
        reason: '绝不能把甲的内容返回给乙');

    // 同一份引用换回甲的句柄：必须读成功 —— 证明拒绝的原因是"不属于乙"，
    // 而不是这条引用本身坏了。
    final ownRead = _decode(
        bridge.readSpill(
            ctxA, jsonEncode({'ref': a.ref, 'offset': 0, 'limit': a.total})),
        '甲读自己的引用');
    // ignore: avoid_print
    print('[3.4] 甲读自己的同一份引用：ok=${ownRead['ok']} '
        'bytes=${ownRead['bytes_read']} error=${ownRead['error']}');
    expect(ownRead['ok'], isTrue,
        reason: '甲读自己的引用必须成功（证明上面的拒绝是归属检查）');
    expect(ownRead['text'], contains('owned-by-甲'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('长命令执行中销毁上下文：等命令真结束、之后新调用 unknown_context',
      (tester) async {
    final created = await bridge.ensureContext(ctxC);
    // ignore: avoid_print
    print('[3.4] 长命令用例：ensureContext($ctxC) created=$created');

    final pending = bridge.runCommand(ctxC, jsonEncode({
      'command': 'Start-Sleep -Seconds 3; Write-Output "long-command-done-丙"',
      'timeout_ms': 20000,
    }));
    // 等命令真的开始（否则"销毁时正在跑"这句话不成立）。
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final sw = Stopwatch()..start();
    await bridge.disposeContext(ctxC);
    sw.stop();
    final disposeElapsed = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('[3.4] disposeContext($ctxC) 用时 ${disposeElapsed}ms（长命令还在跑）');
    expect(disposeElapsed, greaterThanOrEqualTo(1500),
        reason: '销毁必须等长命令结束（3 秒睡眠），不能立即返回后把它掐掉');

    final raw = await pending;
    final r = _decode(raw, '长命令结果');
    // ignore: avoid_print
    print('[3.4] 长命令结果：ok=${r['ok']} exit=${r['exit_code']} '
        'stdout=${r['stdout']} 用时=${r['duration_ms']}ms');
    expect(r['ok'], isTrue, reason: '销毁不能把在途长命令变成失败：$raw');
    expect(r['stdout'], contains('long-command-done-丙'),
        reason: '命令必须真的跑完并产出自己的输出');

    // 销毁之后同一个句柄不许再干活。
    final afterRaw = await bridge.runCommand(
        ctxC, jsonEncode({'command': 'Write-Output "should-not-run"'}));
    final after = _decode(afterRaw, '销毁后 run_command');
    // ignore: avoid_print
    print('[3.4] 销毁后再调用：ok=${after['ok']} code=${after['code']} error=${after['error']}');
    expect(after['ok'], isFalse, reason: '销毁后不许再执行：$afterRaw');
    expect(after['code'], 'unknown_context');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('恢复会话（同名再 ensure created:false）后工具照常可用、序号接着走',
      (tester) async {
    final before = await runOk(ctxA, 'Write-Output "before-recover"', '恢复前');
    final createdAgain = await bridge.ensureContext(ctxA);
    // ignore: avoid_print
    print('[3.4] 再次 ensureContext($ctxA) created=$createdAgain（应为 false）');
    expect(createdAgain, isFalse, reason: '同名上下文还在，第二次 ensure 必须是 created:false');

    // 工作区仍然可设、文件工具可用：恢复后不许报 unknown_context。
    // 用一个自建临时工作区，避免依赖测试进程的当前目录。
    final wsDir = Directory.systemTemp.createTempSync('aliasagent_ctx_recover_');
    addTearDown(() {
      try {
        if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    File('${wsDir.path}${Platform.pathSeparator}recovered.txt')
        .writeAsStringSync('recovered-file-content');
    final ws = bridge.setWorkspace(ctxA, wsDir.path);
    expect(ws == null || ws.isEmpty, isTrue, reason: 'set_workspace 必须成功：$ws');
    final readRaw = bridge.readFile(ctxA, 'recovered.txt');
    final read = _decode(readRaw, '恢复后 read_file');
    // ignore: avoid_print
    print('[3.4] 恢复后 read_file(recovered.txt)：ok=${read['ok']} '
        '长度=${(read['content'] as String? ?? '').length}');
    expect(read['ok'], isTrue, reason: '恢复后的工具调用必须成功：$readRaw');
    expect(read['content'], contains('recovered-file-content'));

    final after = await runOk(ctxA, 'Write-Output "after-recover"', '恢复后');
    // ignore: avoid_print
    print('[3.4] 恢复前序号=${before.seq} 恢复后序号=${after.seq}');
    expect(after.seq, greaterThan(before.seq),
        reason: '恢复后序号必须接着走（同一进程内状态仍在，不重置）');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
