// 桌面壳的文档与常量守卫（change `windows-desktop-shell` 任务 0.5）。
//
// 覆盖哪几件事（每条都能在有人改一处忘另一处时变红）：
//   (a) `Docs/user-guide/desktop-shell.md` 存在，且 `README.md` 的功能文档索引含该路径；
//   (b) **默认端口三处一致 + 无第三份字面量** ——
//       Dart 侧 `kDefaultCorePort`、壳侧 `DefaultCorePort`、配置键表 `core.port` 行的
//       默认值三处相等；扫描 `lib/**/*.dart` 与 `shell/**/*.cs` 后，`16705` 只允许
//       出现在那两处常量声明里（在解析层再写一份就算红）；
//   (c) **实际解析值**也要对 —— `resolveCorePort(cliPort: null, configPath: 不存在的路径)`
//       必须等于该常量（否则「声明一致但实现另写一份」照样漏）；
//   (d) 配置键表那一行还含范围（1–65535）与「非法回落」的说明；
//   (e) 壳文档含托盘文案「打开窗口」「重启核心」「退出」、重启失败提示
//       「重启核心失败」、自检开关 `--selftest`、构建脚本名 `build_desktop_shell.ps1`；
//   (f) `web-core-shim.md` 写明优先级三锚点（`--port`、`core.port`、默认值）与
//       `core.shutdown`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:alias_agent/core/core_cli.dart';
import 'package:alias_agent/models/app_config.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[壳守卫] $label: $value');
}

/// 解析 markdown 的**表格行**（只认 `|…|`；表头分隔行跳过）。
///
/// 与 `web_core_docs_test.dart` 同一种解析：`core.port` 必须在**第一列**出现，
/// 整篇子串出现不算过。
List<List<String>> _tableRows(String markdown) {
  final rows = <List<String>>[];
  for (final line in markdown.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) continue;
    final cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((cell) => cell.trim())
        .toList();
    if (cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell))) continue;
    rows.add(cells);
  }
  return rows;
}

String _stripCode(String cell) => cell.replaceAll('`', '').trim();

/// 递归收集某目录下指定扩展名的文件（目录不存在时返回空）。
List<File> _filesWithExtension(String dirPath, String extension) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const <File>[];
  return dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith(extension))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  final appConfigFile = File('lib/models/app_config.dart');
  final desktopOptionsFile = File('shell/AliasAgent.Desktop/DesktopOptions.cs');
  final configDocFile = File('Docs/user-guide/configuration.md');
  final shellDocFile = File('Docs/user-guide/desktop-shell.md');
  final webCoreDocFile = File('Docs/user-guide/web-core-shim.md');
  final readme = File('README.md');
  final repoRoot = Directory.current.path;

  test('壳文档存在，且 README 功能文档索引含它', () {
    _obs('壳文档路径', shellDocFile.path);
    expect(shellDocFile.existsSync(), isTrue,
        reason: '缺少 Docs/user-guide/desktop-shell.md（change 必须同 change 落地用户文档）');
    expect(readme.readAsStringSync(),
        contains('Docs/user-guide/desktop-shell.md'),
        reason: 'README 的功能文档索引必须加入桌面壳文档');
  });

  test('默认端口三处一致（Dart 常量 / 壳常量 / 配置键表）', () {
    expect(appConfigFile.existsSync(), isTrue,
        reason: 'lib/models/app_config.dart 必须声明 kDefaultCorePort');
    final dartSource = appConfigFile.readAsStringSync();
    final dartMatch =
        RegExp(r'kDefaultCorePort\s*=\s*(\d+)\s*;').firstMatch(dartSource);
    _obs('Dart 侧常量声明命中', dartMatch?.group(0));
    expect(dartMatch, isNotNull,
        reason: 'AppConfig 上必须有具名常量 kDefaultCorePort = <数字>;');

    expect(desktopOptionsFile.existsSync(), isTrue,
        reason: 'shell/AliasAgent.Desktop/DesktopOptions.cs 必须声明 DefaultCorePort');
    final csSource = desktopOptionsFile.readAsStringSync();
    final csMatch =
        RegExp(r'DefaultCorePort\s*=\s*(\d+)\s*;').firstMatch(csSource);
    _obs('壳侧常量声明命中', csMatch?.group(0));
    expect(csMatch, isNotNull,
        reason: 'DesktopOptions 上必须有 public const int DefaultCorePort = <数字>;');

    expect(configDocFile.existsSync(), isTrue);
    final rows = _tableRows(configDocFile.readAsStringSync());
    final portRows = rows
        .where((row) => row.isNotEmpty && _stripCode(row.first) == 'core.port')
        .toList();
    _obs('配置键表里的 core.port 行', portRows);
    expect(portRows, isNotEmpty,
        reason: '配置键表必须有 core.port 独立一行（第一列）');

    final dartPort = int.parse(dartMatch!.group(1)!);
    final csPort = int.parse(csMatch!.group(1)!);
    _obs('Dart / 壳 / 面板值', '$dartPort / $csPort');
    expect(csPort, dartPort,
        reason: '壳与 Dart 的默认端口必须同值（壳按同一张优先级表算）');
    expect(dartPort, AppConfig.kDefaultCorePort,
        reason: 'Dart 解析出的常量值要与 AppConfig.kDefaultCorePort 一致');

    final docMentions = [
      for (final row in portRows)
        if (row.any((cell) => cell.contains('$dartPort'))) true,
    ];
    _obs('配置键表 core.port 行写出的默认值', docMentions);
    expect(docMentions, isNotEmpty,
        reason: '配置键表 core.port 行必须写出默认值 $dartPort');
  });

  test('16705 只允许出现在两处常量声明里（第三份字面量即红）', () {
    final portLiteral = '${AppConfig.kDefaultCorePort}';
    _obs('被守卫的字面量', portLiteral);

    final dartHits = <String, int>{};
    for (final file in _filesWithExtension('lib', '.dart')) {
      final count = portLiteral.allMatches(file.readAsStringSync()).length;
      // 统一分隔符：Windows 上 listSync 给的是反斜杠，断言里用正斜杠更可读。
      if (count > 0) dartHits[file.path.replaceAll('\\', '/')] = count;
    }
    final csHits = <String, int>{};
    for (final file in _filesWithExtension('shell', '.cs')) {
      final count = portLiteral.allMatches(file.readAsStringSync()).length;
      if (count > 0) csHits[file.path.replaceAll('\\', '/')] = count;
    }
    _obs('lib 下出现该字面量的文件', dartHits);
    _obs('shell 下出现该字面量的文件', csHits);

    expect(dartHits.keys.toList(), ['lib/models/app_config.dart'],
        reason: 'lib 下只允许 app_config.dart 的 kDefaultCorePort 声明里有这个数字'
            '（在解析层再写一份就是第三份字面量）');
    expect(dartHits['lib/models/app_config.dart'], 1,
        reason: '常量声明只该出现一次（注释里再写一份也算漂移源）');
    expect(csHits.keys.toList(), ['shell/AliasAgent.Desktop/DesktopOptions.cs'],
        reason: 'shell 下只允许 DesktopOptions.cs 的 DefaultCorePort 声明里有这个数字');
    expect(csHits['shell/AliasAgent.Desktop/DesktopOptions.cs'], 1);
  });

  test('实际解析值等于常量（声明一致但实现另写一份 ⇒ 红）', () {
    final missingConfig =
        p.join(repoRoot, 'no-such-dir-for-desktop-shell-guard', 'config.json');
    final resolved = resolveCorePort(cliPort: null, configPath: missingConfig);
    _obs('resolveCorePort(configPath 不存在) ⇒', resolved);
    expect(resolved, AppConfig.kDefaultCorePort,
        reason: '实现里必须用同一个具名常量，不许另写一个数字');
  });

  test('配置键表 core.port 行含范围 1–65535 与「非法回落」说明', () {
    final rows = _tableRows(configDocFile.readAsStringSync());
    final row = rows.firstWhere(
      (candidate) =>
          candidate.isNotEmpty && _stripCode(candidate.first) == 'core.port',
      orElse: () => <String>[],
    );
    _obs('core.port 表行', row);
    expect(row, isNotEmpty);
    final joined = row.join(' | ');
    expect(joined, contains('65535'), reason: '表行要写出合法范围上限');
    expect(joined, contains('1'), reason: '表行要写出合法范围下限');
    expect(joined, contains('回落'),
        reason: '表行要说明非法值回落默认（不是拒绝启动、也不是静默）');
    // 低端口口径：Windows 没有 Unix 式特权端口，文档只许说「不推荐」。
    final fullDoc = configDocFile.readAsStringSync();
    _obs('文档是否出现「需要管理员权限」',
        fullDoc.contains('需要管理员权限'));
    expect(fullDoc, isNot(contains('需要管理员权限')),
        reason: 'Windows 没有 Unix 式特权端口，低端口只是不推荐');

    _obs('完整 JSON 示例是否含 core 块',
        fullDoc.contains('"core"'));
    expect(fullDoc, contains('"core"'),
        reason: '完整 JSON 示例里要补上 core 块（用户照抄才拿得到固定端口）');
  });

  test('壳文档含托盘文案 / 自检开关 / 构建脚本名', () {
    final text = shellDocFile.readAsStringSync();
    for (final anchor in const [
      '打开窗口',
      '重启核心',
      '重启核心失败',
      '退出',
      '--selftest',
      'build_desktop_shell.ps1',
    ]) {
      _obs('壳文档锚点', anchor);
      expect(text, contains(anchor), reason: '壳文档缺少锚点「$anchor」');
    }
    // 两把锁的区别与已知限制必须写明（spec 要求披露）。
    for (final anchor in const ['无鉴权', 'core.lock', '单实例']) {
      _obs('已知限制锚点', anchor);
      expect(text, contains(anchor),
          reason: '壳文档缺少已知限制 / 两把锁的锚点「$anchor」');
    }
  });

  test('web-core-shim 文档写明优先级三锚点与 core.shutdown', () {
    final text = webCoreDocFile.readAsStringSync();
    _obs('默认端口常量值', AppConfig.kDefaultCorePort);
    for (final anchor in const ['--port', 'core.port']) {
      _obs('优先级锚点', anchor);
      expect(text, contains(anchor), reason: '无头核心文档缺少优先级锚点「$anchor」');
    }
    expect(text, contains('${AppConfig.kDefaultCorePort}'),
        reason: '无头核心文档要写出默认值本身（与代码常量同源）');
    expect(text, contains('core.shutdown'),
        reason: '无头核心文档的 RPC 表必须补 core.shutdown 行');
    // 与新行为冲突的旧口径必须删掉。
    expect(text, isNot(contains('不使用任何默认端口（端口是 OS 分配的，写死默认值就是魔数）')),
        reason: '固定端口是回归：旧口径「不使用任何默认端口」必须改写');
  });
}
