@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

/// 真机验收（change `spill-large-tool-output`，tasks 7.6）：
/// **一条真实的、真的会失败的构建命令**，看两件事 ——
///   ① 头部那一条编译器报错还在（旧行为只留尾部，它必被砍掉）；
///   ② 中间被省略的那段能用 `read_spill` 按字节读回来，且与文件对应区间逐字节相同。
///
/// 为什么不用"打印一堆假日志"的假命令：那测不到"编译器的报错长什么样、落在头部还是尾部"。
/// 这里真的写一个编译不过的 C++ 文件、真的让 `cmake --build` 失败。
///
/// 跑法：`flutter test --tags live --run-skipped integration_test/live_spill_output_test.dart -d windows`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridge = SidecarBridge.instance;
  Directory? projectDir;

  setUpAll(() {
    final ws = bridge.setWorkspace('.');
    expect(ws == null || ws.isEmpty, isTrue, reason: 'set_workspace 应当成功');
  });

  setUp(() {
    projectDir = Directory.systemTemp.createTempSync('aliasagent_live_spill_');
  });

  tearDown(() {
    try {
      if (projectDir != null && projectDir!.existsSync()) {
        projectDir!.deleteSync(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响判据
    }
  });

  testWidgets('失败构建：头部报错可见 + 中间段能读回', (tester) async {
    final dir = projectDir!;
    final native = dir.path.replaceAll('/', '\\');

    // 一个真的编译不过的 C++ 文件：第 1 行就是未声明的标识符（头部报错），
    // 后面还有 120 行同类错误，把输出撑到远超预览阈值（2000 字节）。
    final badLines = <String>['int EDGE_MARKER_LINE_1 = undeclared_symbol_at_line_1;'];
    for (var i = 2; i <= 120; i++) {
      badLines.add('int EDGE_MARKER_LINE_$i = undeclared_symbol_at_line_$i;');
    }
    File('$native\\bad.cpp').writeAsStringSync(
        '#include <cstdio>\n${badLines.join('\n')}\nint main(){return 0;}\n');
    File('$native\\CMakeLists.txt').writeAsStringSync(
        'cmake_minimum_required(VERSION 3.15)\n'
        'project(live_spill_probe CXX)\n'
        'add_executable(bad bad.cpp)\n');

    // 一条命令里：configure（静默）→ 真的构建到失败 → 尾部打一个确定的标记。
    // 尾标记必须有，因为 msbuild 的总结行随语言与版本变，不能写死。
    // `-- /nologo /v:q` 是给 MSBuild 的：不加的话光是"生成引擎版本…"那几行横幅
    // 就把结果开头的 1000 字符占掉了，第一条 error 会落到被省略的中段
    // （实测：total=25199、omitted=23093，头部 1000 字符里一条 error 都没有）。
    final command = '\$ErrorActionPreference = "Continue"; '
        'cmake -S "$native" -B "$native\\build" *> \$null; '
        'cmake --build "$native\\build" --config Debug -- /nologo /v:q; '
        'Write-Output "BUILD-TAIL-MARKER"';
    // ignore: avoid_print
    print('[live spill] 实际执行的命令: $command');

    final raw = await bridge.runCommand(jsonEncode({
      'command': command,
      'timeout_ms': 180000,
      'spill_session': 'live-spill',
    }));
    final r = jsonDecode(raw) as Map<String, dynamic>;
    final inline = (r['stdout'] as String? ?? '') + (r['stderr'] as String? ?? '');
    // ignore: avoid_print
    print('[live spill] ok=${r['ok']} exit=${r['exit_code']} '
        'inline长度=${inline.length} truncated=${jsonEncode(r['truncated'])}');

    expect(r['ok'], isTrue, reason: '构建失败不是工具失败：$raw');
    expect(r.containsKey('spill'), isTrue, reason: '这条命令的输出必须超过预览阈值');

    final env = Map<String, dynamic>.from((r['spill'] as Map)['stdout'] as Map);
    final ref = env['ref'] as String;
    final head = env['head'] as String;
    final omitted = env['omitted_bytes'] as int;
    final total = env['total_bytes'] as int;
    // ignore: avoid_print
    print('[live spill] 信封: ref=$ref total=$total omitted=$omitted');
    expect(omitted, greaterThan(0));

    // ① 头部那一条报错在（旧行为会把它砍掉）
    // ignore: avoid_print
    print('[live spill] 头部前 200 字符：'
        '${head.length > 200 ? head.substring(0, 200) : head}');
    final headError = head.split('\n').firstWhere(
        (l) => l.contains('undeclared_symbol_at_line_1'),
        orElse: () => '');
    // ignore: avoid_print
    print('[live spill] 头部命中的那一条报错：$headError');
    expect(headError, isNotEmpty,
        reason: '第 1 行的报错必须落在头部预览里（头部前 1000 个字符）');
    expect(inline, contains('undeclared_symbol_at_line_1'));

    // ② 尾部那句总结也在（证明头尾都留）
    expect(inline, contains('BUILD-TAIL-MARKER'));

    // ③ 中间段用 read_spill 读回来，并与文件对应区间逐字节相同
    //
    // 偏移必须是**字节数**：`head` 是 C++ 按字节切出来的原始片段，Dart 的
    // `String.length` 数的是 UTF-16 码元 —— 头部含中文时（这次就有「未声明的标识符」）
    // 字节数比 length 大，用 `head.length` 会把起点落进头部之内，
    // 于是"读回了被省略的中间段"这句话就是假的（tasks 11.3）。
    final offset = utf8.encode(head).length;
    final limit = omitted < 2000 ? omitted : 2000;
    final rawRead = await Future.value(bridge.readSpill(jsonEncode({
      'ref': ref,
      'offset': offset,
      'limit': limit,
    })));
    final read = jsonDecode(rawRead) as Map<String, dynamic>;
    final text = read['text'] as String? ?? '';
    // ignore: avoid_print
    print('[live spill] read_spill(offset=$offset, limit=$limit): '
        'ok=${read['ok']} bytes_read=${read['bytes_read']} '
        'total_bytes=${read['total_bytes']} error=${read['error']}');
    // ignore: avoid_print
    print('[live spill] 读回的中间段前 400 字符：'
        '${text.length > 400 ? text.substring(0, 400) : text}');

    expect(read['ok'], isTrue, reason: '合法区间必须读成功：$rawRead');
    expect(read['bytes_read'], limit);
    final fileBytes = File(ref).readAsBytesSync();
    expect(utf8.encode(text),
        equals(fileBytes.sublist(offset, offset + limit)),
        reason: '读回的字节必须与文件区间逐字节相同');

    // 起点必须等于**省略段的起点**。用信封里另外三个数核对，而不是拿 head 自己比：
    // 按 C++ 侧的定义 `omitted = total_bytes - head 字节数 - tail 字节数`，
    // 所以省略段起点 = `total_bytes - tail 字节数 - omitted_bytes`。
    // 把 offset 改回 `head.length`（UTF-16 长度）时这里必然对不上 —— tasks 11.3 的判据。
    final tailBytes = utf8.encode(env['tail'] as String).length;
    final expectedOffset = total - tailBytes - omitted;
    // ignore: avoid_print
    print('[live spill] 11.3 起点检查：offset=$offset 期望=$expectedOffset'
        '（total=$total - tail字节=$tailBytes - omitted=$omitted）；'
        '头部字符数=${head.length} 头部字节数=${utf8.encode(head).length}');
    expect(offset, expectedOffset,
        reason: '偏移必须按字节算，且正好落在省略段起点（用 total/tail/omitted 三个数核）');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
