import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/spill_paths.dart';

/// spill 目录名映射与启动清理（change `spill-large-tool-output`，
/// change `add-context-handles` 改写）。
///
/// 目录的创建/删除现在都在 C++ 侧按上下文句柄完成（`run_command` 建、
/// `dispose_context` 删），Dart 只剩「启动时清无主目录」这一件事。
/// 目录名映射仍是两侧各一份实现，必须逐字一致。
void main() {
  final root = Directory(spillRoot());

  String dirFor(String id) =>
      '${spillRoot()}${Platform.pathSeparator}${spillSessionDirName(id)}';

  setUpAll(() {
    if (!root.existsSync()) root.createSync(recursive: true);
  });

  tearDown(() {
    for (final id in ['_it_keep_1', '_it_drop_1', '_it_orphan_probe']) {
      final d = Directory(dirFor(id));
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  test('目录名映射与 C++ 侧一致：只留 [a-z0-9_-]，其余 %XX（大写十六进制）', () {
    expect(spillSessionDirName('abc-123_def-4'), 'abc-123_def-4');
    expect(spillSessionDirName('abc-123_DEF.4'), 'abc-123_%44%45%46%2E4');
    expect(spillSessionDirName('a/b\\c:d*e'), 'a%2Fb%5Cc%3Ad%2Ae');
    expect(spillSessionDirName(''), 'no-session');
    // `..` 必须编码掉，否则目录会跑到 spill 根目录之外。
    expect(spillSessionDirName('..'), '%2E%2E');
    // 「会话甲」是 3 个字符 / 9 个 UTF-8 字节 ⇒ 9 组 %XX（与 C++ 侧同口径）。
    expect(spillSessionDirName('会话甲'), '%E4%BC%9A%E8%AF%9D%E7%94%B2');
    // 只差大小写的两个名字必须不同目录（Windows 不区分大小写）。
    expect(spillSessionDirName('Agent-7'),
        isNot(spillSessionDirName('agent-7')));
    // ignore: avoid_print
    print('[spill 清理] 映射样例: a/b:c ⇒ ${spillSessionDirName('a/b:c')}，'
        '会话甲 ⇒ ${spillSessionDirName('会话甲')}');
  });

  test('启动清理只删无主目录：no-session 与 _it_* 删，有主目录留着', () {
    final orphan = Directory(dirFor(''))..createSync(recursive: true);
    expect(orphan.path.endsWith('no-session'), isTrue);
    File('${orphan.path}${Platform.pathSeparator}000001-stdout.txt')
        .writeAsStringSync('orphan');
    final testDir = Directory(dirFor('_it_orphan_probe'))
      ..createSync(recursive: true);
    // 一个真实会话（UUID 形状）的目录：清理不许动它
    const realSession = '3f2b1c4d-0000-4000-8000-000000000001';
    final realDir = Directory(dirFor(realSession))..createSync(recursive: true);
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
    expect(realDir.existsSync(), isTrue, reason: '有主目录不许被启动清理误删');
    expect(
        File('${realDir.path}${Platform.pathSeparator}000001-stdout.txt')
            .readAsStringSync(),
        'keep me');

    // 收尾：把真实会话目录也删掉，别留垃圾
    realDir.deleteSync(recursive: true);
  });
}
