// 用户文档 ↔ 执行分组代码的一致性守卫（change
// `parallelize-readonly-tool-calls` 任务 9.3）。
//
// 三件事：
//   ① `Docs/user-guide/tools-file.md` 的「只读工具的并行执行」一节里，9 个只读名
//      与 8 个逐个名必须逐个出现（名字清单直接从 `lib/services/tool_group_planner.dart`
//      的常量里读，不手抄 —— 代码加名字而文档不写、或文档多写一个代码里没有的，
//      这里都会红）；
//   ② 这一节里出现的反引号小写名字必须**恰好**是这 17 个工具名（多写一个别的名字
//      也算文档与代码不一致）；
//   ③ `Docs/user-guide/configuration.md` 里必须有 `tool.parallel_max` 那一行，
//      且默认值文字与代码里的缺省常量一致。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从源码里取出 `const Set<String> <名字> = <String>{ ... };` 的花括号块。
String _setLiteralBlock(String source, String constName) {
  final marker = 'const Set<String> $constName = <String>{';
  final start = source.indexOf(marker);
  if (start < 0) {
    throw StateError('tool_group_planner.dart 里找不到 `$constName` 常量');
  }
  final end = source.indexOf('};', start);
  if (end <= start) {
    throw StateError('`$constName` 的花括号没有闭合');
  }
  return source.substring(start, end);
}

/// 花括号块里 `'xxx'` 形式的短名字。
Set<String> _namesIn(String block) => {
      for (final m in RegExp(r"'([a-z][a-z0-9_]*)'").allMatches(block))
        m.group(1)!,
    };

/// 文档某一节（从标题行到下一个同级 `## ` 标题之前）。
String _section(String markdown, String heading) {
  final start = markdown.indexOf(heading);
  if (start < 0) throw StateError('文档里找不到小节 "$heading"');
  final rest = markdown.substring(start + heading.length);
  final next = rest.indexOf('\n## ');
  return next < 0 ? rest : rest.substring(0, next);
}

void main() {
  final plannerSource =
      File('lib/services/tool_group_planner.dart').readAsStringSync();
  final fileDoc = File('Docs/user-guide/tools-file.md').readAsStringSync();

  final codeReadOnly =
      _namesIn(_setLiteralBlock(plannerSource, 'kReadOnlyToolNames'));
  final codeSerial =
      _namesIn(_setLiteralBlock(plannerSource, 'kSerialToolNames'));

  final parallelSection = _section(fileDoc, '## 只读工具的并行执行');
  final docNames = {
    for (final m in RegExp(r'`([a-z][a-z0-9_]*)`').allMatches(parallelSection))
      m.group(1)!,
  };

  test('代码里的两个集合是 9 + 8', () {
    // ignore: avoid_print
    print('[文档守卫] 代码只读集合（${codeReadOnly.length}）='
        '${(codeReadOnly.toList()..sort())}');
    // ignore: avoid_print
    print('[文档守卫] 代码逐个集合（${codeSerial.length}）='
        '${(codeSerial.toList()..sort())}');
    expect(codeReadOnly.length, 9);
    expect(codeSerial.length, 8);
  });

  test('9 个只读名逐个出现在「只读工具的并行执行」一节', () {
    final missing = codeReadOnly.difference(docNames).toList()..sort();
    // ignore: avoid_print
    print('[文档守卫] 只读名缺失=$missing 文档里这一节的名字='
        '${(docNames.toList()..sort())}');
    expect(missing, isEmpty,
        reason: '这些只读工具名在 tools-file.md 的并行小节里没有出现：$missing');
  });

  test('8 个逐个名逐个出现在「只读工具的并行执行」一节', () {
    final missing = codeSerial.difference(docNames).toList()..sort();
    // ignore: avoid_print
    print('[文档守卫] 逐个名缺失=$missing');
    expect(missing, isEmpty,
        reason: '这些逐个执行的工具名在 tools-file.md 的并行小节里没有出现：$missing');
  });

  test('这一节里出现过的小写名字恰好是那 17 个工具名（不多不少）', () {
    final expected = <String>{...codeReadOnly, ...codeSerial};
    final extra = docNames.difference(expected).toList()..sort();
    // ignore: avoid_print
    print('[文档守卫] 文档多出来的名字=$extra 期望名字数=${expected.length} '
        '文档名字数=${docNames.length}');
    expect(extra, isEmpty,
        reason: '这些名字出现在并行小节里，但代码的两个集合里都没有：$extra');
    expect(docNames, expected,
        reason: '并行小节里的名字清单必须恰好等于"9 个只读 + 8 个逐个"');
  });

  test('configuration.md 有 tool.parallel_max 行，默认值与代码缺省一致', () {
    final configDoc =
        File('Docs/user-guide/configuration.md').readAsStringSync();
    final appConfig =
        File('lib/models/app_config.dart').readAsStringSync();
    final defaultMatch = RegExp(
            r'static const int kDefaultToolParallelMax\s*=\s*(\d+);')
        .firstMatch(appConfig);
    expect(defaultMatch, isNotNull,
        reason: 'app_config.dart 里找不到 kDefaultToolParallelMax 的缺省常量');
    final codeDefault = defaultMatch!.group(1)!;

    final row = configDoc
        .split('\n')
        .where((line) => line.contains('`tool.parallel_max`'))
        .toList();
    // ignore: avoid_print
    print('[文档守卫] 代码缺省=$codeDefault configuration.md 命中行数=${row.length}');
    for (final line in row) {
      // ignore: avoid_print
      print('[文档守卫]   $line');
    }
    expect(row, isNotEmpty,
        reason: 'configuration.md 里没有 `tool.parallel_max` 这一行');
    expect(row.length, 1);
    // 默认值文字必须与代码缺省一致：`0（不设上限）`。代码把缺省改成正整数时这里会红。
    expect(row.single, contains('$codeDefault（不设上限）'),
        reason: '配置键表里的默认值文字与代码缺省（$codeDefault）不一致');

    // 完整配置示例里也要看得到这个键（用户能照着抄）。
    expect(configDoc, contains('"parallel_max"'),
        reason: 'configuration.md 的完整配置 json 块里没有 parallel_max');
  });
}
