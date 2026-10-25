import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

/// `run_command` 的结果信封（change `spill-large-tool-output`，tasks 1.1 / 3.2）。
///
/// 这个文件测的是**信封本身**：超限时信封必须带 `ref` / `total_bytes` /
/// `omitted_bytes` / `head` / `tail`，且这几个数要与**命令实际输出的字节数**对得上
/// —— 不许只让信封内部三数自洽（那样任何实现都能过）。
///
/// 外部真值怎么来的：命令用 `[Console]::Out.Write` 写死一个可数出来的字符串
/// （`'HEAD-MARKER' + 'A' × 199978 + 'TAIL-MARKER'`，共 200000 字节；ASCII 无换行，
/// 所以字节数 = 字符数 = 200000 —— 这个数是用 cmd 重定向实测出来的，不是手算）。
///
/// 跑法：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 把新构建的
/// 动态库刷到仓库根，再 `flutter test test/unit/spill_envelope_test.dart`。
void main() {
  final bridge = SidecarBridge.instance;

  /// 本文件的会话名。**必须传**：不传就会落到真实的 `no-session` 目录，
  /// 于是每跑一次测试就往用户主目录里留一堆 spill 文件（tasks 10.2）。
  const testSession = '_it_envelope';
  final spillRoot = Directory('${Platform.environment['USERPROFILE']}'
      '${Platform.pathSeparator}.aliasagent${Platform.pathSeparator}spill');
  int noSessionFilesBefore = 0;

  setUpAll(() {
    final ws = bridge.setWorkspace('.');
    expect(ws == null || ws.isEmpty, isTrue, reason: 'set_workspace 应当成功');
    // 记下"跑之前 no-session 里有几个文件"，跑完对照 —— 本文件不许往里加东西
    final orphan = Directory('${spillRoot.path}${Platform.pathSeparator}no-session');
    noSessionFilesBefore =
        orphan.existsSync() ? orphan.listSync().whereType<File>().length : 0;
  });

  tearDownAll(() {
    final own = Directory(
        '${spillRoot.path}${Platform.pathSeparator}$testSession');
    if (own.existsSync()) own.deleteSync(recursive: true);
  });

  /// 长输出命令：头部有标记、中间全是 A、尾部有标记，总共 200000 字节。
  const longCommand =
      "[Console]::Out.Write('HEAD-MARKER' + ('A' * 199978) + 'TAIL-MARKER')";
  const longBytes = 200000;

  Map<String, dynamic> envelopeOf(Object? spill, String stream) {
    expect(spill, isA<Map>(), reason: '超限时结果必须带 spill 信封');
    final perStream = (spill as Map)[stream];
    expect(perStream, isA<Map>(), reason: 'spill 信封里必须有 $stream 这一份');
    return Map<String, dynamic>.from(perStream as Map);
  }

  test('超限时信封带 ref/total_bytes/omitted_bytes/head/tail，且量与命令实际输出对得上',
      () async {
    // ignore: avoid_print
    print('[spill 信封] 实际执行的命令: $longCommand（外部真值 = $longBytes 字节）');
    final r = await bridge
        .runCommand(jsonEncode({'command': longCommand, 'spill_session': testSession}))
        .then((s) => jsonDecode(s) as Map<String, dynamic>);
    // ignore: avoid_print
    print('[spill 信封] 实测读数: ok=${r['ok']} '
        'stdout长度=${(r['stdout'] as String?)?.length} '
        'spill=${jsonEncode(r['spill'])}');

    expect(r['ok'], isTrue);
    final env = envelopeOf(r['spill'], 'stdout');
    // ignore: avoid_print
    print('[spill 信封] stdout 这份: ${jsonEncode(env)}');

    final ref = env['ref'];
    final totalBytes = env['total_bytes'];
    final omittedBytes = env['omitted_bytes'];
    final head = env['head'];
    final tail = env['tail'];

    expect(ref, isA<String>(), reason: '必须给出可取回的引用');
    expect(totalBytes, isA<int>());
    expect(omittedBytes, isA<int>());
    expect(head, isA<String>());
    expect(tail, isA<String>());

    // ① 外部真值：总量必须等于命令实际输出的字节数（不是信封自己说多少就是多少）
    expect(totalBytes, longBytes,
        reason: 'total_bytes 必须等于命令实际输出的字节数');
    // ② 引用指向的文件真的存在，且大小也等于那个数 —— 这是第三条独立证据
    final spillFile = File(ref as String);
    expect(spillFile.existsSync(), isTrue, reason: '引用指向的文件必须存在：$ref');
    expect(spillFile.lengthSync(), longBytes,
        reason: 'spill 文件的字节数必须等于命令实际输出');
    // ③ 内部关系：省略的 + 内联的 = 总量
    final inlineBytes = utf8.encode(head as String).length +
        utf8.encode(tail as String).length;
    // ignore: avoid_print
    print('[spill 信封] 核对: total=$totalBytes inline=$inlineBytes '
        'omitted=$omittedBytes inline+omitted=${inlineBytes + (omittedBytes as int)}');
    expect(inlineBytes + omittedBytes, totalBytes,
        reason: 'omitted_bytes + 内联字节数 必须等于 total_bytes');
    expect(omittedBytes, greaterThan(0), reason: '200000 字节明显超过预览阈值');

    // ④ 头尾各留一份，且落在正确的边界上
    expect(head, startsWith('HEAD-MARKER'), reason: '头部那 1000 字符里必须有第 1 行的标记');
    expect(tail, endsWith('TAIL-MARKER'), reason: '尾部那 1000 字符里必须有末尾标记');

    // ⑤ 给模型看的那份里两个标记都在（不能只给尾部）
    final inline = r['stdout'] as String;
    expect(inline, contains('HEAD-MARKER'));
    expect(inline, contains('TAIL-MARKER'));
  });

  test('未超限时也落盘：total_bytes 等于短输出字节数，omitted_bytes 为 0', () async {
    const command = "[Console]::Out.Write('SHORT')";
    // ignore: avoid_print
    print('[spill 信封] 实际执行的命令: $command（外部真值 = 5 字节）');
    final r = await bridge
        .runCommand(jsonEncode({'command': command, 'spill_session': testSession}))
        .then((s) => jsonDecode(s) as Map<String, dynamic>);
    // ignore: avoid_print
    print('[spill 信封] 实测读数: ok=${r['ok']} stdout=${jsonEncode(r['stdout'])} '
        'spill=${jsonEncode(r['spill'])}');

    expect(r['ok'], isTrue);
    final env = envelopeOf(r['spill'], 'stdout');
    expect(env['total_bytes'], 5);
    expect(env['omitted_bytes'], 0);
    expect(env['head'], 'SHORT');
    expect(env['tail'], '');
    final spillFile = File(env['ref'] as String);
    expect(spillFile.existsSync(), isTrue, reason: '小输出也必须落盘');
    expect(spillFile.lengthSync(), 5);
  });

  test('preview_chars 配到 4000 时，引用段仍在（tasks 3.2）', () async {
    // 头尾各 4000 字符 ⇒ 正文 8000+，正好顶到通用截断阈值
    // （kToolResultElisionThreshold = 8000）。走**真实的**两段代码：真实拼装 →
    // 真实截断，然后看引用还在不在。
    // ignore: avoid_print
    print('[spill 信封] 实际执行的命令: $longCommand（preview_chars=4000）');
    final parsed = await bridge
        .runCommand(jsonEncode({'command': longCommand, 'preview_chars': 4000, 'spill_session': testSession}))
        .then((s) => jsonDecode(s) as Map<String, dynamic>);
    final env =
        Map<String, dynamic>.from((parsed['spill'] as Map)['stdout'] as Map);
    final ref = env['ref'] as String;

    final content = ChatScreenState.composeCommandResultText(parsed);
    final elided = ChatScreenState.elideOversizedToolResult(
        name: 'run_command', path: '', body: content);
    // ignore: avoid_print
    print('[spill 信封] total=${env['total_bytes']} '
        'omitted=${env['omitted_bytes']}\n'
        '[spill 信封] 拼装后长度=${content.length} 截断后长度=${elided.length}\n'
        '[spill 信封] 引用 = $ref');

    expect(content.length, greaterThan(ChatScreenState.kToolResultElisionThreshold),
        reason: '这一条必须落在"要过通用截断"的那一侧，否则它什么都没验');
    expect(elided, contains(ref),
        reason: '引用必须留在结果里 —— 通用截断只保头尾，所以引用要放在最后');
    // 省略量也要看得见（模型据此判断值不值得去读回）
    expect(elided, contains('${env['omitted_bytes']} omitted'));
  });

  test('通用截断的尾注不再说「无法自动再取」（tasks 9.1）', () async {
    // 结果超过 8000 字符时会被通用截断，尾注原本固定写「本篇无法自动再取…」，
    // 而它上面一行就是 spill 引用 —— 自相矛盾。正文里带 spill 引用时必须改口径。
    final parsed = await bridge
        .runCommand(jsonEncode({'command': longCommand, 'preview_chars': 4000, 'spill_session': testSession}))
        .then((s) => jsonDecode(s) as Map<String, dynamic>);
    final content = ChatScreenState.composeCommandResultText(parsed);
    final elided = ChatScreenState.elideOversizedToolResult(
        name: 'run_command', path: '', body: content);
    // ignore: avoid_print
    print('[spill 信封] 9.1 尾注检查：拼装=${content.length} 截断后=${elided.length}；'
        '含 read_spill=${elided.contains('read_spill')} '
        '含「无法自动再取」=${elided.contains('无法自动再取')}');
    expect(content.length, greaterThan(ChatScreenState.kToolResultElisionThreshold),
        reason: '要落在"必须过通用截断"的那一侧，否则验不到尾注');
    expect(elided, contains('read_spill'));
    expect(elided, isNot(contains('无法自动再取')));
  });

  test('两条流同时超限时，两个 ref 都还在（tasks 9.2）', () async {
    // stdout 与 stderr 各写 200000 字节：两边都被截成头尾预览，
    // 两个引用都不许被通用截断掐掉。
    const cmd = "[Console]::Out.Write('X' * 200000); "
        "[Console]::Error.Write('Y' * 200000)";
    // `preview_chars=4000`：两条流各留 4000 字符头 + 4000 字符尾，拼起来必然超过
    // 通用截断阈值（8000）—— 否则"截断后没超阈值"这条断言是空的（缺省 1000 时
    // 拼装只有 4652 字符，根本不会触发截断）。
    final parsed = await bridge
        .runCommand(jsonEncode({
          'command': cmd,
          'preview_chars': 4000,
          'spill_session': testSession,
        }))
        .then((s) => jsonDecode(s) as Map<String, dynamic>);
    final spill = parsed['spill'] as Map;
    final outRef = (spill['stdout'] as Map)['ref'] as String;
    final errRef = (spill['stderr'] as Map)['ref'] as String;
    final content = ChatScreenState.composeCommandResultText(parsed);
    final elided = ChatScreenState.elideOversizedToolResult(
        name: 'run_command', path: '', body: content);
    // ignore: avoid_print
    print('[spill 信封] 9.2 双流：'
        'stdout省略=${(spill['stdout'] as Map)['omitted_bytes']} '
        'stderr省略=${(spill['stderr'] as Map)['omitted_bytes']}\n'
        '[spill 信封] 拼装=${content.length} 截断后=${elided.length}\n'
        '[spill 信封] outRef=$outRef\n[spill 信封] errRef=$errRef');

    expect((parsed['truncated'] as Map)['stdout'], isTrue);
    expect((parsed['truncated'] as Map)['stderr'], isTrue);
    expect(outRef, isNot(errRef));
    expect(File(outRef).lengthSync(), 200000);
    expect(File(errRef).lengthSync(), 200000);

    expect(elided, contains(outRef), reason: 'stdout 的引用不许被截断掐掉');
    expect(elided, contains(errRef), reason: 'stderr 的引用不许被截断掐掉');

    // tasks 11.2：任务文字声称"断言拼装结果没超过阈值"，此前只在 print 里打长度。
    // 这一条把它变成真断言：截断后的正文不该超过阈值 + 尾注本身的那点余量
    // （尾注是 `\n[tool_result body elided: … ]` 这一行，按 200 字符留）。
    // ignore: avoid_print
    print('[spill 信封] 11.2 截断后长度=${elided.length} 阈值='
        '${ChatScreenState.kToolResultElisionThreshold}');
    expect(elided.length,
        lessThanOrEqualTo(ChatScreenState.kToolResultElisionThreshold + 200),
        reason: '截断后的正文必须在阈值 + 尾注余量之内');
    expect(content.length, greaterThan(elided.length),
        reason: '这一条必须真的触发了通用截断，否则上限断言什么都没验');
  });

  test('本文件不往真实 spill 根的 no-session 里留文件（tasks 10.2）', () {
    // 跑完所有用例后：自己的会话目录在 tearDownAll 里删，no-session 的文件数
    // 必须和跑之前一样 —— 少了这条，每跑一次测试就往用户主目录里堆 10 个文件。
    final orphan =
        Directory('${spillRoot.path}${Platform.pathSeparator}no-session');
    final after =
        orphan.existsSync() ? orphan.listSync().whereType<File>().length : 0;
    // ignore: avoid_print
    print('[spill 信封] 10.2 no-session 文件数：跑前=$noSessionFilesBefore 跑后=$after');
    expect(after, noSessionFilesBefore,
        reason: '用例必须传 spill_session，不许把文件落进无主的 no-session');
  });

  test('「正文里有没有 spill 引用」的判断收在一处（tasks 10.4）', () {
    // 9.1 靠字符串嗅探判断要不要改尾注口径；标记写散在几处就会静默失效。
    // 这里用真拼装出来的正文验"有"，用一段普通文字验"没有"。
    final withRefs = ChatScreenState.composeCommandResultText(<String, dynamic>{
      'ok': true,
      'stdout': 'head...tail',
      'stderr': '',
      'truncated': {'stdout': true, 'stderr': false},
      'spill': {
        'stdout': {
          'ref': 'C:\\tmp\\000001-stdout.txt',
          'total_bytes': 200000,
          'omitted_bytes': 198000,
          'head': 'head',
          'tail': 'tail',
        }
      },
    });
    // ignore: avoid_print
    print('[spill 信封] 10.4 带引用的正文里判定='
        '${ChatScreenState.bodyHasSpillRefs(withRefs)}；'
        '普通文字判定=${ChatScreenState.bodyHasSpillRefs('hello world')}');
    expect(ChatScreenState.bodyHasSpillRefs(withRefs), isTrue);
    expect(ChatScreenState.bodyHasSpillRefs('hello world'), isFalse);
  });
}
