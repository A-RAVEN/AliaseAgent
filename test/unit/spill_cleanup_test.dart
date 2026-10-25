import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/spill_paths.dart';

/// 删会话时连带删掉该会话的 spill 目录（change `spill-large-tool-output`，tasks 5.1）。
///
/// 夹具用 `_it_` 前缀的会话名，落在真实的 spill 根下（产品就是这么建的），
/// 用例结束删掉，不往用户主目录留垃圾。
void main() {
  final root = Directory(spillRoot());

  setUpAll(() {
    if (!root.existsSync()) root.createSync(recursive: true);
  });

  tearDown(() {
    for (final id in ['_it_keep_1', '_it_drop_1']) {
      final d = Directory(spillSessionDir(id));
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('删掉一个会话的目录，别的会话目录仍在', () {
    final keepDir = Directory(spillSessionDir('_it_keep_1'))
      ..createSync(recursive: true);
    final dropDir = Directory(spillSessionDir('_it_drop_1'))
      ..createSync(recursive: true);
    // 每个目录里放一个文件，模拟真的写过 spill
    File('${keepDir.path}${Platform.pathSeparator}000001-stdout.txt')
        .writeAsStringSync('keep');
    File('${dropDir.path}${Platform.pathSeparator}000001-stdout.txt')
        .writeAsStringSync('drop');

    // ignore: avoid_print
    print('[spill 清理] 删之前: keep=${keepDir.existsSync()} '
        'drop=${dropDir.existsSync()}');

    final removed = deleteSessionSpill('_it_drop_1');
    // ignore: avoid_print
    print('[spill 清理] 删除返回=$removed；删之后 keep=${keepDir.existsSync()} '
        'drop=${dropDir.existsSync()}');

    expect(removed, isTrue, reason: '目录存在时必须真的删掉');
    expect(dropDir.existsSync(), isFalse, reason: '被删会话的 spill 目录必须消失');
    expect(keepDir.existsSync(), isTrue, reason: '别的会话目录不许受影响');
    expect(
        File('${keepDir.path}${Platform.pathSeparator}000001-stdout.txt')
            .readAsStringSync(),
        'keep');
  });

  test('目录本来就不存在时什么都不做，也不去建它', () {
    final dir = Directory(spillSessionDir('_it_never_created'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);

    final removed = deleteSessionSpill('_it_never_created');
    // ignore: avoid_print
    print('[spill 清理] 不存在的会话: 返回=$removed 目录存在=${dir.existsSync()}');

    expect(removed, isFalse);
    expect(dir.existsSync(), isFalse, reason: '不存在的目录不许被"顺手建出来"');
  });

  test('目录名映射与 C++ 侧一致：只留字母数字与 . _ -，其余换下划线', () {
    expect(spillSessionDirName('abc-123_DEF.4'), 'abc-123_DEF.4');
    expect(spillSessionDirName('a/b\\c:d*e'), 'a_b_c_d_e');
    expect(spillSessionDirName(''), 'no-session');
    expect(spillSessionDirName('..'), 'no-session');
    // "中文会话" 是 4 个字符 / 12 个 UTF-8 字节 ⇒ 12 个下划线（与 C++ 侧同口径）
    expect(spillSessionDirName('中文会话'), '____________');
    // ignore: avoid_print
    print('[spill 清理] 映射样例: a/b:c ⇒ ${spillSessionDirName('a/b:c')}，'
        '中文会话 ⇒ ${spillSessionDirName('中文会话')}');
    // 这四条与 `sidecar/test/spill_write_test.cpp` 的
    // "目录名映射与 Dart 侧一致" 用例逐字对应 —— 两边漂移必有一边红。
  });

  test('启动清理只删无主目录：no-session 与 _it_* 删，真实会话目录留着', () {
    // 这一条钉的是 tasks 10.1：删会话只删 <会话 id>/，而 no-session 对应不到任何
    // 会话 —— 没有这条清理，它就只增不减。
    final orphan = Directory(spillSessionDir(''))..createSync(recursive: true);
    expect(orphan.path.endsWith('no-session'), isTrue);
    File('${orphan.path}${Platform.pathSeparator}000001-stdout.txt')
        .writeAsStringSync('orphan');
    final testDir = Directory(spillSessionDir('_it_orphan_probe'))
      ..createSync(recursive: true);
    // 一个真实会话（UUID 形状）的目录：清理不许动它
    const realSession = '3f2b1c4d-0000-4000-8000-000000000001';
    final realDir = Directory(spillSessionDir(realSession))
      ..createSync(recursive: true);
    File('${realDir.path}${Platform.pathSeparator}000001-stdout.txt')
        .writeAsStringSync('keep me');

    final removed = cleanOrphanSpillDirs();
    // ignore: avoid_print
    print('[spill 清理] 启动清理删掉：$removed；'
        'no-session 还在=${orphan.existsSync()} '
        '_it_ 还在=${testDir.existsSync()} '
        '真实会话还在=${realDir.existsSync()}');

    expect(removed, contains('no-session'));
    expect(orphan.existsSync(), isFalse, reason: '无主目录必须被删掉');
    expect(testDir.existsSync(), isFalse, reason: '测试目录也属于无主');
    expect(realDir.existsSync(), isTrue, reason: '真实会话的 spill 不许被启动清理误删');
    expect(
        File('${realDir.path}${Platform.pathSeparator}000001-stdout.txt')
            .readAsStringSync(),
        'keep me');

    // 收尾：把真实会话目录也删掉，别留垃圾
    realDir.deleteSync(recursive: true);
  });
}
