// 完整聊天屏的用户文档守卫（change `web-chat-screen` 任务 7.3 / 审查 TC-3）。
//
// 参照 `parallel_tools_docs_test.dart` 的"解析常量、绑定文档"强先例，而不是只
// `contains` 一个数字：
//   - 可配参数的名字与取值**从 `web/src/tokens.ts` 源码解析**（不手抄）；
//   - 每条参数必须在 `Docs/user-guide/web-core-shim.md` 的「完整聊天屏参数」小节里
//     有**独立一行**，该行同时含键名与代码里的默认值，且不含别的键 —— 这样：
//       ① 代码改默认值、文档不改 → 红（行里的值对不上）；
//       ② 代码重命名键、文档不改 → 红（找不到该键的行）；
//       ③ 文档把一堆数字堆在一行想"混过" → 红（一行只能有一个键）；
//       ④ 间距 scale 里无关的 24 / 16 之类数字不会让参数行莫名其妙通过
//          （判定是"键所在行必须带自己的值"，不是"文档里出现过这个数字"）。
//   - message.query 的 additive 扩展参数（anchor/before/prevCursor）写进 RPC 表；
//   - feedback 台账 F-002~F-004 的状态字段必须写出拍板出处（TODO.md 2026-11-16 /
//     2026-11-21）且不再是"待用户拍板"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[聊天屏文档守卫] $label: $value');
}

/// 从源码里取 `const <name> = <整数>;` 的值。
int _intConstant(String source, String name) {
  final match =
      RegExp('const int $name = (\\d+);').firstMatch(source) ??
          RegExp('const $name = (\\d+);').firstMatch(source);
  if (match == null) {
    throw StateError('web/src/tokens.ts 里找不到整数常量 `$name`');
  }
  return int.parse(match.group(1)!);
}

/// 从源码里取 `const <name> = '<字符串>';` 的值。
String _stringConstant(String source, String name) {
  final match = RegExp("const $name = '([^']+)';").firstMatch(source);
  if (match == null) {
    throw StateError('web/src/tokens.ts 里找不到字符串常量 `$name`');
  }
  return match.group(1)!;
}

/// 文档某一节（从标题行到下一个同级或更高级 `## ` 标题之前）。
String _section(String markdown, String heading) {
  final start = markdown.indexOf(heading);
  if (start < 0) throw StateError('文档里找不到小节 "$heading"');
  final rest = markdown.substring(start + heading.length);
  final next = rest.indexOf('\n## ');
  return next < 0 ? rest : rest.substring(0, next);
}

void main() {
  final tokens = File('web/src/tokens.ts').readAsStringSync();
  final doc = File('Docs/user-guide/web-core-shim.md').readAsStringSync();
  final readme = File('README.md').readAsStringSync();
  final feedback = File('Docs/feedback.md').readAsStringSync();

  /// (常量名, 环境变量常量名, 单位说明)
  const params = <List<String>>[
    ['kDefaultBottomThresholdPx', 'kBottomThresholdEnvKey'],
    ['kDefaultReconnectBaseMs', 'kReconnectBaseEnvKey'],
    ['kDefaultReconnectCapMs', 'kReconnectCapEnvKey'],
    ['kDefaultHeartbeatPeriodMs', 'kHeartbeatPeriodEnvKey'],
    ['kDefaultHeartbeatTimeoutMs', 'kHeartbeatTimeoutEnvKey'],
  ];

  test('完整聊天屏小节的每条参数行与 tokens.ts 绑定（键 + 值，且一行一键）', () {
    final section = _section(doc, '## 完整聊天屏参数');
    final allKeys = [
      for (final param in params) _stringConstant(tokens, param[1]),
    ];
    _obs('代码里的参数键', allKeys);
    final failures = <String>[];
    for (final param in params) {
      final defaultValue = _intConstant(tokens, param[0]);
      final key = _stringConstant(tokens, param[1]);
      final rows = section
          .split('\n')
          .where((line) => line.trimLeft().startsWith('|') && line.contains(key))
          .toList();
      if (rows.isEmpty) {
        failures.add('文档「完整聊天屏参数」小节没有 $key 这一行');
        continue;
      }
      if (rows.length > 1) {
        failures.add('$key 在参数小节里出现了 ${rows.length} 行（必须恰好一行）');
      }
      final row = rows.single;
      _obs('$key 的文档行', row.trim());
      if (!row.contains('$defaultValue')) {
        failures.add('$key 的文档行没有代码默认值 $defaultValue：$row');
      }
      for (final other in allKeys) {
        if (other != key && row.contains(other)) {
          failures.add('$key 的文档行里混入了别的键 $other（一行只能有一个键）');
        }
      }
    }
    expect(failures, isEmpty,
        reason: '参数文档与 web/src/tokens.ts 不一致：\n${failures.join('\n')}');
  });

  test('message.query 的 additive 扩展参数写进 RPC 表（尾锚 / 反向游标 / prevCursor）', () {
    for (final anchor in const ['anchor', 'tail', 'before', 'prevCursor', 'head']) {
      _obs('RPC 表锚点', anchor);
      expect(doc, contains(anchor), reason: '文档没有写 message.query 的 "$anchor"');
    }
    // RPC 表那一行必须同时出现这三个参数（不是散落在别处）。
    final messageRow = doc
        .split('\n')
        .firstWhere((line) => line.startsWith('| `message.query`'));
    _obs('message.query 表行', messageRow);
    for (final anchor in const ['anchor', 'before', 'prevCursor']) {
      expect(messageRow, contains(anchor),
          reason: 'message.query 表行缺少 "$anchor"');
    }
  });

  test('README 索引指向完整聊天屏文档', () {
    expect(readme, contains('Docs/user-guide/web-core-shim.md'));
    _obs('README 里的索引行',
        readme.split('\n').firstWhere((line) => line.contains('web-core-shim')));
    expect(readme, contains('完整聊天屏'),
        reason: 'README 的功能索引仍是"最小验证页"口径，没同步成完整聊天屏');
  });

  test('feedback F-002~F-004 的状态字段写出拍板出处，不再是"待用户拍板"', () {
    for (final id in const ['F-002', 'F-003', 'F-004']) {
      final start = feedback.indexOf('## $id ');
      expect(start, greaterThanOrEqualTo(0), reason: 'feedback.md 里找不到 $id');
      final next = feedback.indexOf('\n## F-', start + 1);
      final block = feedback.substring(start, next < 0 ? null : next);
      final statusLines = block
          .split('\n')
          .where((line) => line.contains('**状态**'))
          .toList();
      _obs('$id 的状态行', statusLines);
      expect(statusLines.length, 1, reason: '$id 必须有且只有一行状态字段');
      final status = statusLines.single;
      expect(status, isNot(contains('待用户拍板')),
          reason: '$id 仍是"待用户拍板"，没有同步拍板出处');
      expect(status, contains('TODO.md'),
          reason: '$id 的状态字段没写拍板出处（TODO.md 条目）');
    }
    for (final date in const ['2026-11-16', '2026-11-21']) {
      expect(feedback, contains(date),
          reason: 'feedback.md 缺少拍板日期 $date');
    }
  });
}
