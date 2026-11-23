// 群聊用户文档守卫（change `agent-group-chat` 任务 9.5 / design D15；
// change `group-reactive-mode` 任务 6.3 增自发反应锚点与 web 文案扫描源）。
//
// 与既有 web 文档守卫（整份文档子串包含，从宽）不同，这条**解析 RPC 表行**：
// `group-chat.md` 里必须有一张表，每行第一列是群聊方法名；文档任意处出现不算过。
//
// 另外几条：
//   ② 覆盖层三字段名取自产品解析路径的常量（`instance_overrides.dart`）；
//   ③ `界面文案：` 句子必须在 `lib/` 里逐字存在（只扫 lib/，与既有守卫同口径）；
//   ④ 已知限制锚点存在（重启后视图为空 / 已移除只读 / 空视图与 prefill 错误）；
//   ⑤ **新增**：自发反应的锚点（开关 / `[PASS]` / 取消 / 无深度上限 / `reactions_enabled`），
//      哨兵与开关名取自代码常量；
//   ⑥ **新增**：`界面文案（web）：` 标记的文案必须在 `web/src/group/GroupView.tsx`
//      里逐字存在（新扫描源；不放宽 ③ 的 lib-only 口径）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/models/instance_overrides.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/group_reaction.dart';

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

  test('① 解析 RPC 表行：十个群聊方法逐个出现在第一列', () {
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
    expect(kCoreRpcMethodNames.where((m) => m.startsWith('group.')).length, 10,
        reason: 'group.chain 是第十个群聊方法（异步链状态查询）');
    expect(missing, isEmpty,
        reason: '群聊 RPC 表必须逐行列出这些方法（第一列），文档任意处出现不算过：$missing');
    expect(firstColumn, contains('group.update'),
        reason: 'group.update 必须是表里的**独立一行**（不是正文提一句）');
    expect(firstColumn, contains('group.chain'),
        reason: 'group.chain 必须是表里的**独立一行**（异步链状态）');
    // agent.cancel 的组路由行为也要写进表里（9.4 的行为说明在 web 文档，
    // 这里要求群聊文档也提到它）。
    expect(markdown, contains('agent.cancel'));
  });

  test('⑤ 自发反应锚点齐备（哨兵与开关名取自代码常量）', () {
    final markdown = doc.readAsStringSync();
    // 哨兵名取自代码常量本身，不是文档里手抄的字符串。
    _obs('哨兵常量', kGroupPassSentinel);
    expect(markdown, contains(kGroupPassSentinel),
        reason: '文档必须写出静默哨兵 `$kGroupPassSentinel`（取自 kGroupPassSentinel）');
    // 开关名取自**序列化契约**：`session.list` / `group.list` 的 JSON 键。
    final serialized = serializeSession(Session(
      id: 'probe',
      title: 't',
      createdAt: 1,
      updatedAt: 1,
      kind: Session.kindGroup,
    ));
    final flagKey = serialized.keys.firstWhere(
      (key) => key.toLowerCase().contains('reaction'),
      orElse: () => '',
    );
    _obs('序列化契约里的开关键', flagKey);
    expect(flagKey, isNotEmpty, reason: 'serializeSession 必须带自发反应开关');
    expect(markdown, contains(flagKey),
        reason: '文档必须写出开关的 JSON 字段名 `$flagKey`（取自序列化契约）');
    // 数据库列名（文档要说清它是 sessions 列、不是 config.json 键）。
    expect(markdown, contains('reactions_enabled'));

    // 每组的反应轮数上限（change `group-reactive-mode` R.5 / D13）：字段名、列名与
    // 默认值都取自代码常量 / 序列化契约，不手抄。
    final maxRoundsKey = serialized.keys.firstWhere(
      (key) => key.toLowerCase().contains('maxround'),
      orElse: () => '',
    );
    _obs('序列化契约里的上限字段', maxRoundsKey);
    expect(maxRoundsKey, isNotEmpty, reason: 'serializeSession 必须带 maxRounds');
    expect(markdown, contains(maxRoundsKey));
    expect(markdown, contains('max_reaction_rounds'));
    _obs('上限默认值常量', '$kDefaultMaxReactionRounds..$kMaxMaxReactionRounds');
    expect(markdown, contains('默认 8'),
        reason: '文档必须写出产品默认上限（取自 design D13 / 代码常量）');
    expect(markdown, contains('1..50'),
        reason: '文档必须写出允许范围（取自代码常量）');

    for (final anchor in <String>[
      '自发反应',
      '取消',
      '每组上限',
      '异步',
      'maxRounds',
      '已达轮数上限',
      '关闭自发反应后仍只支持点名',
      '默认开',
    ]) {
      _obs('自发反应锚点', anchor);
      expect(markdown, contains(anchor), reason: '文档缺少自发反应锚点「$anchor」');
    }
    // 旧的「只支持点名」断言**改写不删除**：关闭开关后的口径仍然要可失败。
    expect(markdown, contains('关闭自发反应后仍只支持点名'));
    // 旧的「无深度上限」表述必须被每组上限替换（不许两者并存）。
    expect(markdown, isNot(contains('无深度上限')),
        reason: '文档已改为「每组上限（默认 8，范围 1..50）」；旧表述留下就是自相矛盾');
    expect(markdown, contains('不是 `config.json` 键'));
    // R.9 / R.10：结构化 PASS 与默认沉默框架必须写进用户文档（且指向真实代码名）。
    for (final anchor in <String>[
      '默认沉默',
      kGroupReactToolName,
      'pass=true',
      'pass=false',
      '群聊礼仪',
      '纠正重试',
      'missing_group_react',
      'invalid_group_react',
    ]) {
      _obs('结构化 PASS 锚点', anchor);
      expect(markdown, contains(anchor),
          reason: '文档缺少结构化 PASS / 默认沉默锚点「$anchor」');
    }
  });

  test('⑥ 界面文案（web）：标记的文案在 GroupView.tsx 里逐字存在', () {
    final markdown = doc.readAsStringSync();
    final lines = markdown
        .split('\n')
        .where((line) => line.contains('界面文案（web）：'))
        .toList();
    expect(lines, isNotEmpty,
        reason: '群聊文档至少要标出一条 web 界面文案（新标记 `界面文案（web）：`）');
    final viewSource = File('web/src/group/GroupView.tsx');
    expect(viewSource.existsSync(), isTrue,
        reason: 'web 组视图源文件必须存在（新扫描源）');
    final haystack = viewSource.readAsStringSync();
    for (final line in lines) {
      final match = RegExp(r'界面文案（web）：「([^」]+)」').firstMatch(line);
      expect(match, isNotNull, reason: 'web 界面文案必须写在「」里：$line');
      final text = match!.group(1)!;
      _obs('web 界面文案', text);
      expect(haystack, contains(text),
          reason: '文档里的 web 界面文案「$text」在 GroupView.tsx 里找不到（界面改了、文档没跟上？）');
    }
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
      '关闭自发反应后仍只支持点名',
      '请在 web 组视图打开',
      '无并行',
      '无 token 预算治理',
      '旧组升级后默认关闭',
    ];
    for (final anchor in anchors) {
      _obs('已知限制锚点', anchor);
      expect(markdown, contains(anchor), reason: '文档缺少已知限制锚点「$anchor」');
    }
  });
}
