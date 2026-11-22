// 群聊用户文档守卫（change `agent-group-chat` 任务 9.5 / design D15）。
//
// 与既有 web 文档守卫（整份文档子串包含，从宽）不同，这条**解析 RPC 表行**：
// `group-chat.md` 里必须有一张表，每行第一列是群聊方法名；文档任意处出现不算过。
//
// 另外三条：
//   ② 覆盖层三字段名取自产品解析路径的常量（`instance_overrides.dart`）；
//   ③ `界面文案：` 句子必须在 `lib/` 里逐字存在（只扫 lib/，与既有守卫同口径）；
//   ④ 已知限制锚点存在（重启后视图为空 / 已移除只读 / 空视图与 prefill 错误）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/instance_overrides.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[群聊文档守卫] $label: $value');
}

/// 解析一份 markdown 里的**表格行**：返回每行去掉首尾 `|` 后按 `|` 切出的单元格。
///
/// 只认以 `|` 开头、以 `|` 结尾的行；表头分隔行（`---`）跳过。这不是"整份文档
/// 子串包含"——方法名必须出现在第一列。
List<List<String>> tableRows(String markdown) {
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

void main() {
  final doc = File('Docs/user-guide/group-chat.md');

  test('文档存在且 README 功能索引指向它', () {
    _obs('文档路径', doc.path);
    expect(doc.existsSync(), isTrue, reason: '缺少 Docs/user-guide/group-chat.md');
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('Docs/user-guide/group-chat.md'),
        reason: 'README 的功能文档索引必须加入群聊文档');
  });

  test('① 解析 RPC 表行：八个群聊方法逐个出现在第一列', () {
    final markdown = doc.readAsStringSync();
    final rows = tableRows(markdown);
    // ignore: avoid_print
    print('[群聊文档守卫] 表格行数: ${rows.length}');
    final firstColumn = {
      for (final row in rows)
        if (row.isNotEmpty) row.first.replaceAll('`', ''),
    };
    final missing = [
      for (final method in kCoreRpcMethodNames)
        if (method.startsWith('group.') && !firstColumn.contains(method)) method,
    ];
    _obs('代码里的群聊方法', kCoreRpcMethodNames.where((m) => m.startsWith('group.')).toList());
    _obs('表格第一列', firstColumn);
    _obs('表里缺的方法', missing);
    expect(kCoreRpcMethodNames.where((m) => m.startsWith('group.')).length, 8);
    expect(missing, isEmpty,
        reason: '群聊 RPC 表必须逐行列出这些方法（第一列），文档任意处出现不算过：$missing');
    // agent.cancel 的组路由行为也要写进表里（9.4 的行为说明在 web 文档，
    // 这里要求群聊文档也提到它）。
    expect(markdown, contains('agent.cancel'));
  });

  test('② 覆盖层三字段名与代码常量一致', () {
    final markdown = doc.readAsStringSync();
    for (final field in [
      kOverrideToolsSubsetKey,
      kOverrideSystemPromptAppendKey,
      kOverrideThinkingEffortKey,
    ]) {
      _obs('覆盖层字段', field);
      expect(markdown, contains(field),
          reason: '文档必须写出覆盖层字段 `$field`（名字取自代码常量）');
    }
    expect(markdown, contains('空值三态'));
    expect(markdown, contains('不是 `config.json` 键'));
  });

  test('③ 界面文案句子在 lib/ 下逐字存在', () {
    final markdown = doc.readAsStringSync();
    final lines = markdown
        .split('\n')
        .where((line) => line.contains('界面文案：'))
        .toList();
    expect(lines, isNotEmpty, reason: '群聊文档至少要标出一条界面文案');
    final libSources = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        libSources.add(entity.readAsStringSync());
      }
    }
    final haystack = libSources.join('\n');
    for (final line in lines) {
      final match = RegExp(r'界面文案：「([^」]+)」').firstMatch(line);
      expect(match, isNotNull, reason: '界面文案必须写在「」里：$line');
      final text = match!.group(1)!;
      _obs('界面文案', text);
      expect(haystack, contains(text),
          reason: '文档里的界面文案「$text」在 lib/ 下找不到（界面改了、文档没跟着改？）');
    }
  });

  test('④ 已知限制锚点齐备', () {
    final markdown = doc.readAsStringSync();
    final anchors = <String>[
      '重启后',
      '已移除',
      '空视图',
      'prefill',
      '看不到他人私有过程',
      '只支持点名',
      '请在 web 组视图打开',
    ];
    for (final anchor in anchors) {
      _obs('已知限制锚点', anchor);
      expect(markdown, contains(anchor), reason: '文档缺少已知限制锚点「$anchor」');
    }
  });
}
