// 子 Agent 用户文档与产品代码的一致性（add-spawn-subagent-tool 任务 7.1）。
//
// 核对的是"名字与说法能不能对上"，不审文风：
//   - 新文档覆盖规格要求的每一条行为（同步等待 / 独立历史 / 工作区继承 / 只回传
//     结论 / 取消 / 不能嵌套 / 不在侧栏 / 无详情界面 / spill 引用不可当交付）；
//   - 文档里的工具名、菜单名与配置文件示例，与产品代码逐项对得上；
//   - configuration.md 的首启 `tools` 数组与 `ToolCatalog.kBaseToolNames` 完全一致；
//   - configuration.md 与 agent-templates.md 不再写"十项基础工具"；
//   - README 功能索引链到新文档。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/tool_catalog.dart';

void main() {
  final docPath = 'Docs/user-guide/agent-subagents.md';
  final templatesPath = 'Docs/user-guide/agent-templates.md';
  final configPath = 'Docs/user-guide/configuration.md';

  String read(String path) => File(path).readAsStringSync();

  group('agent-subagents.md 覆盖规格要求', () {
    test('每一条用户可见行为都写到了（缺一条就红）', () {
      final doc = read(docPath);
      // ignore: avoid_print
      print('  [OBS] 文档长度=${doc.length} 行数=${doc.split('\n').length}');
      for (final required in const [
        'spawn_subagent', // 工具名
        'Agents', // 菜单名（在哪里配置）
        '同步', // 同步等待
        '独立历史', // 独立上下文与消息历史
        '工作区继承', // 父工作区继承
        '最终结论', // 只回传结论
        '取消', // 取消行为
        '不能嵌套', // 第一版范围
        '不在侧栏', // 子记录不出现在列表
        '没有详情界面', // 第一版无详情
        'spill', // 子 spill 引用不可当交付
        'task', // 必填任务参数
        'agent_type', // 可选模板参数
      ]) {
        // ignore: avoid_print
        print('  [OBS] 必需说法 "$required" 出现='
            '${doc.contains(required)}');
        expect(doc.contains(required), isTrue,
            reason: '文档必须说明"$required"，否则用户不知道这条行为');
      }
      // 反向：不许声称支持嵌套或并行。
      expect(doc.contains('支持嵌套'), isFalse, reason: '第一版不支持嵌套');
      expect(doc.contains('并行执行'), isFalse, reason: '第一版没有并行调度');
      expect(doc, contains('不能嵌套'));
      expect(doc, contains('没有并行'));
    });

    test('文档里的工具名与菜单名都能在产品代码里找到', () {
      final doc = read(docPath);
      final sidebar = read('lib/ui/session_sidebar.dart');
      final templateMenu = read('lib/ui/agent_template_menu.dart');
      final mainDart = read('lib/main.dart');

      // 工具定义（真实注册名）。
      final definitionAt = mainDart.indexOf("'spawn_subagent': const {");
      // ignore: avoid_print
      print('  [OBS] main.dart 里的工具定义位置=$definitionAt '
          '侧栏 Agents=${sidebar.contains("Text('Agents')")} '
          '模板菜单 Agents=${templateMenu.contains("Text('Agents')")} '
          '修改模板=${templateMenu.contains("tooltip: '修改模板'")}');
      expect(definitionAt >= 0, isTrue,
          reason: 'main.dart 里必须有 spawn_subagent 的工具定义');
      expect(sidebar, contains("Text('Agents')"),
          reason: '文档说的 Agents 入口必须真的在侧栏里');
      expect(templateMenu, contains("Text('Agents')"));
      expect(templateMenu, contains("tooltip: '修改模板'"),
          reason: '文档说的"铅笔按钮（修改模板）"必须真的存在');
      expect(doc, contains('spawn_subagent'));

      // 工具说明里的关键约束必须和文档说法一致（模型看到的与用户读到的同一套）。
      final descriptionStart =
          mainDart.indexOf("'spawn_subagent': const {");
      final descriptionEnd =
          mainDart.indexOf('input_schema', descriptionStart);
      final description =
          mainDart.substring(descriptionStart, descriptionEnd);
      // ignore: avoid_print
      print('  [OBS] 工具说明片段长度=${description.length}');
      for (final phrase in const [
        'cannot create another sub-agent',
        'runs synchronously',
        'self-contained',
      ]) {
        expect(description.toLowerCase(), contains(phrase.toLowerCase()),
            reason: '工具说明必须向模型讲清 "$phrase"（与用户文档同一套边界）');
      }
    });
  });

  group('首启示例与工具目录一致', () {
    test('configuration.md 的首启 tools 数组 == ToolCatalog.kBaseToolNames', () {
      final config = read(configPath);
      // 取第一个含 agent_types 的 ```json 代码块（第一次启动写出的那份）。
      final block = _firstJsonBlockContaining(config, 'agent_types');
      // ignore: avoid_print
      print('  [OBS] 首启示例 JSON 片段长度=${block.length}');
      final decoded = jsonDecode(block) as Map<String, dynamic>;
      final general =
          (decoded['agent_types'] as Map<String, dynamic>)['general']
              as Map<String, dynamic>;
      final tools = (general['tools'] as List<dynamic>).cast<String>();
      // ignore: avoid_print
      print('  [OBS] 文档首启 tools=${tools.length} 项：$tools');
      // ignore: avoid_print
      print('  [OBS] 代码基础工具=${ToolCatalog.kBaseToolNames.length} 项：'
          '${ToolCatalog.kBaseToolNames}');
      expect(tools, ToolCatalog.kBaseToolNames,
          reason: '文档里的首启工具数组必须与代码的当前基础清单逐项一致');
      expect(tools, contains('spawn_subagent'));
      expect(tools.length, 11);

      // 数量说明：不再写"十项基础工具"。
      expect(config.contains('十项基础工具'), isFalse,
          reason: 'configuration.md 的基础工具数量说明必须更新');
      expect(config.contains('十一项基础工具'), isTrue);
      final templates = read(templatesPath);
      expect(templates.contains('十项基础工具'), isFalse,
          reason: 'agent-templates.md 的基础工具数量说明必须更新');
      expect(templates.contains('十一项基础工具'), isTrue);
      // 既有十项清单不自动升级这件事必须写出来（不能声称自动迁移）。
      expect(config, contains('**不会**自动升级'),
          reason: '文档必须说清上一版十项完整清单不会自动加 spawn_subagent');
      expect(templates, contains('**不会**自动加上'),
          reason: '模板文档必须说清既有十项不会自动加 spawn_subagent');
    });

    test('README 功能索引链到子 Agent 文档', () {
      final readme = read('README.md');
      // ignore: avoid_print
      print('  [OBS] README 链到子 Agent 文档='
          '${readme.contains('Docs/user-guide/agent-subagents.md')}');
      expect(readme, contains('](Docs/user-guide/agent-subagents.md)'),
          reason: '新用户文档必须出现在 README 的功能索引里');
    });
  });
}

/// 取第一个包含 [marker] 的 ```json 代码块内容。
String _firstJsonBlockContaining(String markdown, String marker) {
  final lines = markdown.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (!trimmed.startsWith('```') ||
        !trimmed.toLowerCase().contains('json')) {
      continue;
    }
    final buffer = StringBuffer();
    for (var j = i + 1; j < lines.length; j++) {
      if (lines[j].trimLeft().startsWith('```')) break;
      buffer.writeln(lines[j]);
    }
    final block = buffer.toString();
    if (block.contains(marker)) return block;
  }
  fail('configuration.md 里找不到包含 "$marker" 的 json 代码块');
}
