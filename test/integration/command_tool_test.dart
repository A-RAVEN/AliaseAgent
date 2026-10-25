import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

/// 命令工具的集成测试（tasks.md 4.4 / 6.2）：经**仓库根的真实 `sidecar.dll`**
/// 跑**真实命令**。
///
/// 用例覆盖哪几件事（共用一条用例时要说清，否则"它到底测了啥"无法核对）：
///   1. 非零退出码仍算成功执行，且退出码原样带回；
///   2. 标准输出与标准错误分开，不合并；
///   3. 中文输出经真实链路往返不乱码；
///   4. 超时被终止，且返回已经收集到的输出；
///   5. 工作区之外的 `workdir` 被拒绝，且命令没有被执行（留痕文件不存在）；
///   6. `workdir` 真的生效，(Get-Location) 报告的是给的那个子目录；
///   7. `cd` 不跨调用（下一次调用仍在工作区）；
///   8. 把每条流的上限按明显更小的值组装进请求后，同一条长输出命令的返回长度
///      真的变短、截断字段为真（这条穿过发起调用那一侧的组装路径）。
///
/// 跑法：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 把新构建的
/// 动态库刷到仓库根，再 `flutter test test/integration/command_tool_test.dart`。
void main() {
  late SidecarBridge bridge;
  late Directory tmp;

  setUpAll(() {
    bridge = SidecarBridge.instance;
    final ws = bridge.setWorkspace('.');
    expect(ws == null || ws.isEmpty, isTrue,
        reason: 'set_workspace 应当成功（返回空或 null）');
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cmd_tool_it_');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不影响判据
    }
  });

  test('非零退出码 + 两条流分开（覆盖 1、2）', () async {
    final command = "[Console]::Out.Write('OUT-TOKEN'); "
        "[Console]::Error.Write('ERR-TOKEN'); exit 3";
    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: $command');
    final r = await bridge.runCommand(jsonEncode({'command': command})).then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: ok=${r['ok']} exit=${r['exit_code']} '
        'stdout长度=${(r['stdout'] as String).length} '
        'stderr长度=${(r['stderr'] as String).length} '
        'timed_out=${r['timed_out']} duration_ms=${r['duration_ms']}');

    expect(r['ok'], isTrue, reason: '非零退出码不算工具失败');
    expect(r['exit_code'], 3);
    expect(r['timed_out'], isFalse);
    expect(r['stdout'], contains('OUT-TOKEN'));
    expect(r['stdout'], isNot(contains('ERR-TOKEN')));
    expect(r['stderr'], contains('ERR-TOKEN'));
    expect(r['stderr'], isNot(contains('OUT-TOKEN')));
  });

  test('中文输出经真实链路往返（覆盖 3）', () async {
    const text = '中文测试输出';
    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: Write-Output \'$text\'');
    final r = await bridge
        .runCommand(jsonEncode({'command': "Write-Output '$text'"}))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: stdout=${jsonEncode(r['stdout'])}');
    expect(r['ok'], isTrue);
    expect((r['stdout'] as String).trim(), text);
  });

  test('超时被终止且带回已收集的输出（覆盖 4）', () async {
    // 判据是"超时之前已经写出来的输出要带回来"，所以要让"写出"与"超时"之间的
    // 间隔足够确定：写成脚本文件（首行是空行，命令从第 2 行开始），先输出、
    // 停 500 毫秒让输出确实进了管道，再长睡到超时。
    // 早先这条用例在整机负载高时会假红（实测：单跑通过，全量跑时 800 毫秒不够
    // 覆盖 PowerShell 的启动开销，输出还没写出来就被杀了）。
    final script = File('${tmp.path}\\timeout-probe.ps1')
      ..writeAsStringSync('\nWrite-Output "BEFORE-TIMEOUT"\n'
          '[System.Threading.Thread]::Sleep(500)\n'
          '[System.Threading.Thread]::Sleep(10000)\n');
    final command = '& \'${script.path}\'';
    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: $command（超时 2500 毫秒）');
    final r = await bridge
        .runCommand(jsonEncode({'command': command, 'timeout_ms': 2500}))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: timed_out=${r['timed_out']} '
        'duration_ms=${r['duration_ms']} stdout=${jsonEncode(r['stdout'])}');
    expect(r['ok'], isTrue);
    expect(r['timed_out'], isTrue, reason: '整条命令跑满 10 秒，超时 2500 毫秒必然到点');
    expect(r['stdout'], contains('BEFORE-TIMEOUT'),
        reason: '超时之前写出来的输出必须带回来');
    expect(r['duration_ms'] as int, lessThan(9000), reason: '不该等满 10 秒');
  });

  test('越界 workdir 被拒绝且命令未执行（覆盖 5）', () async {
    final marker = '${tmp.path}\\REJECT-MARKER.txt';
    final command = "Set-Content -Path '$marker' -Value x";
    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: $command（workdir 指到工作区之外）');
    final r = await bridge
        .runCommand(jsonEncode({'command': command, 'workdir': tmp.path}))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: ok=${r['ok']} error=${r['error']} '
        '留痕文件存在=${File(marker).existsSync()}');
    expect(r['ok'], isFalse, reason: '工作区之外的 workdir 必须被拒绝');
    expect(File(marker).existsSync(), isFalse, reason: '命令不许被执行');
  });

  test('workdir 生效与 cd 不跨调用（覆盖 6、7）', () async {
    final sub = Directory('${tmp.path}\\sub工作目录')..createSync();
    final ws = bridge.setWorkspace(tmp.path);
    expect(ws == null || ws.isEmpty, isTrue);

    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: (Get-Location).Path（workdir=sub工作目录）');
    final r1 = await bridge
        .runCommand(jsonEncode({
          'command': '(Get-Location).Path',
          'workdir': 'sub工作目录',
        }))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: ok=${r1['ok']} stdout=${jsonEncode(r1['stdout'])} '
        'error=${r1['error']}');
    expect(r1['ok'], isTrue);
    expect(r1['stdout'], contains('sub工作目录'));

    // cd 不跨调用：先 cd 到别处，下一次调用仍应落在 tmp
    await bridge.runCommand(jsonEncode({'command': 'cd C:\\'})).then(jsonDecode);
    final r2 = await bridge
        .runCommand(jsonEncode({'command': '(Get-Location).Path'}))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数（第二次）: stdout=${jsonEncode(r2['stdout'])}');
    expect(r2['ok'], isTrue);
    expect(r2['stdout'], contains(tmp.path.split('\\').last),
        reason: '第二次调用应当回到工作区，而不是 C:\\');

    expect(sub.existsSync(), isTrue);
    bridge.setWorkspace('.');
  });

  test('预览长度改小后同一条命令的预览真的变短（覆盖 8）', () async {
    // 改前用的是已废弃的 `max_output_chars`（"保留尾部 N 个字符"）。那条交付方式
    // 已被 change spill-large-tool-output 取代：现在唯一的旋钮是 `preview_chars`
    // （头尾各留多少），判"要不要省略"的阈值是它的 2 倍。
    final command =
        "1..400 | ForEach-Object { Write-Output ('x' * 40) }";
    // ignore: avoid_print
    print('[命令工具] 实际执行的命令: $command（先按 preview_chars=500，再按缺省 1000）');
    final small = await bridge
        .runCommand(jsonEncode({'command': command, 'preview_chars': 500}))
        .then(jsonDecode);
    final plain = await bridge
        .runCommand(jsonEncode({'command': command}))
        .then(jsonDecode);
    // ignore: avoid_print
    print('[命令工具] 实测读数: 小预览长度=${(small['stdout'] as String).length} '
        '截断=${small['truncated']?['stdout']} | '
        '缺省长度=${(plain['stdout'] as String).length} '
        '截断=${plain['truncated']?['stdout']}');
    expect(small['ok'], isTrue);
    expect(plain['ok'], isTrue);
    expect(small['truncated']['stdout'], isTrue);
    expect(plain['truncated']['stdout'], isTrue);

    // 头尾各 500 ⇒ 正文 ≈ 1000 + 一行省略说明；留一截余量（省略说明的长度可变）
    final smallLen = (small['stdout'] as String).length;
    expect(smallLen, lessThan(1500), reason: 'preview_chars=500 时正文不该超过 1000 + 说明');
    expect(smallLen, greaterThanOrEqualTo(1000),
        reason: '头 500 + 尾 500 一个字都不许少');
    // 缺省 1000 的正文一定比 500 那次长 —— 差别证明这个值真的走到了执行侧
    expect((plain['stdout'] as String).length,
        greaterThan(smallLen));
    // 两边的 head 长度也必须真的是 500 / 1000（不是"看起来短了"）
    expect(((small['spill'] as Map)['stdout'] as Map)['head'], hasLength(500));
    expect(((plain['spill'] as Map)['stdout'] as Map)['head'], hasLength(1000));
  });
}
