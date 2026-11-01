import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';

/// `run_command` 结果的拼装与通用截断守卫（change `add-context-handles`，任务 3.7）。
///
/// 三条判据：
///   ① `preview_chars=4000` 时允许整段超过 8000，但**引用与省略量必须留在截断后的
///      尾部区域**（通用截断只保头尾）；
///   ② 超时 / 非零退出码追加在引用行之后，引用仍然可见、不被连同尾部一起砍掉；
///   ③ 小输出写盘失败的兜底由 C++ 侧的 `spill_write_test.cpp`（"输出不超过预览阈值
///      时写盘失败 ⇒ 内联全文且不报错"）覆盖，这里不重复伪造。
void main() {
  const ref = r'C:\Users\tester\.aliasagent\spill\it-envelope\000001-stdout.txt';
  const previewChars = 4000;

  /// 造一份"头尾各 4000 字符、中间省略"的 run_command 结果（形状与 C++ 侧一致）。
  Map<String, dynamic> oversizedResult({
    bool timedOut = false,
    int exitCode = 0,
  }) {
    final head = 'HEAD-MARKER${'a' * previewChars}';
    final tail = '${'z' * previewChars}TAIL-MARKER';
    return <String, dynamic>{
      'ok': true,
      'exit_code': exitCode,
      'timed_out': timedOut,
      'duration_ms': 1234,
      'stdout': '$head\n[... 192000 bytes omitted of 200000; full output: $ref — '
          'read it back with read_spill (ref, offset=4000, limit=192000)]\n$tail',
      'stderr': '',
      'truncated': {'stdout': true, 'stderr': false},
      'spill': {
        'stdout': {
          'ref': ref,
          'total_bytes': 200000,
          'omitted_bytes': 192000,
          'head': head,
          'tail': tail,
        },
      },
    };
  }

  test('preview_chars=4000：整段超过 8000，引用与省略量仍在截断后的尾部', () {
    final body =
        ChatScreenState.composeCommandResultText(oversizedResult());
    // ignore: avoid_print
    print('[3.7] 拼装后长度=${body.length} 阈值='
        '${ChatScreenState.kToolResultElisionThreshold}');
    expect(body.length,
        greaterThan(ChatScreenState.kToolResultElisionThreshold),
        reason: '这一条必须落在"要过通用截断"的那一侧');

    final elided = ChatScreenState.elideOversizedToolResult(
        name: 'run_command', path: '', body: body);
    // ignore: avoid_print
    print('[3.7] 截断后长度=${elided.length}；含引用=${elided.contains(ref)}');
    expect(elided.length, lessThan(body.length), reason: '必须真的触发了通用截断');
    expect(elided, contains(ref), reason: '引用不许落在被砍掉的中段');
    expect(elided, contains('192000 omitted'), reason: '省略量必须可见');
    // 引用必须在**尾部区域**：截断保留的后半段里能直接找到它。
    final tailRegion =
        elided.substring(elided.length - ChatScreenState.kToolResultElisionThreshold ~/ 2);
    expect(tailRegion, contains(ref),
        reason: '引用必须位于截断后保留的尾部区域内');
  });

  test('超时与非零退出码追加在引用之后，引用仍在尾部可见', () {
    final body = ChatScreenState.composeCommandResultText(
        oversizedResult(timedOut: true, exitCode: 7));
    expect(body, contains(ref));
    expect(body, contains('[timed out after 1234ms]'));
    expect(body, contains('[exit code: 7]'));
    // 标记确实在引用之后（与实现顺序一致），这样通用截断砍不到引用。
    expect(body.indexOf('[timed out'),
        greaterThan(body.indexOf(ChatScreenState.kSpillRefsMarker)));

    final elided = ChatScreenState.elideOversizedToolResult(
        name: 'run_command', path: '', body: body);
    // ignore: avoid_print
    print('[3.7] 超时/非零退出码：截断后含引用=${elided.contains(ref)} '
        '含超时=${elided.contains('[timed out')} 含退出码=${elided.contains('[exit code: 7]')}');
    expect(elided, contains(ref), reason: '超时/退出码追加后引用不许被砍掉');
    expect(elided, contains('[timed out'));
    expect(elided, contains('[exit code: 7]'));
    final tailRegion =
        elided.substring(elided.length - ChatScreenState.kToolResultElisionThreshold ~/ 2);
    expect(tailRegion, contains(ref), reason: '引用必须仍在尾部区域');
  });
}
