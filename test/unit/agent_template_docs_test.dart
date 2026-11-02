import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/agent_template_menu.dart';

/// Agent 模板文档与产品代码的一致性（change `add-agent-object-and-templates`
/// 任务 4.1）。
///
/// 只核对能核到的事实：入口名字、模板名不可改、错误文案、配置键、生效时机、
/// 首启基础工具清单、README 索引；文档里若又出现"只认 general / 没有菜单 /
/// 首启只有两项工具"这类过时说法，这条用例红。
void main() {
  final docs = File('Docs/user-guide/agent-templates.md');
  final configDoc = File('Docs/user-guide/configuration.md');
  final readme = File('README.md');

  test('文档存在并被 README 功能索引链接', () {
    expect(docs.existsSync(), isTrue, reason: '缺少 Docs/user-guide/agent-templates.md');
    expect(readme.readAsStringSync(),
        contains('](Docs/user-guide/agent-templates.md)'),
        reason: 'README 的功能索引里没有链接这份文档');
  });

  test('入口、模板名只读与生效时机与界面代码对得上', () {
    final text = docs.readAsStringSync();
    final libSources = _allLibSources();
    final joined = libSources.join('\n');

    // ignore: avoid_print
    print('  [OBS] 文档提到 Agents=${text.contains('Agents')}；'
        '提到模板名只读=${text.contains('模板名创建后不可修改')}；'
        '提到生效时机=${text.contains(kAgentTemplateEffectiveNote)}');
    expect(text, contains('Agents'), reason: '文档必须写出侧栏入口的名字');
    expect(joined, contains("'Agents'"), reason: '代码里必须有这个入口文案');
    expect(text, contains('模板名创建后不可修改'),
        reason: '文档必须说明模板名创建后不可改');
    expect(joined, contains('模板名创建后不可修改（只读）'),
        reason: '编辑器里要有同一句只读提示');
    expect(text, contains(kAgentTemplateEffectiveNote),
        reason: '文档与菜单必须用同一句生效时机说明');
    expect(joined, contains(kAgentTemplateEffectiveNote),
        reason: '菜单常量必须真的在界面代码里');
  });

  test('错误文案与产品代码一致（未知工具、非法窗口、模板缺失）', () {
    final text = docs.readAsStringSync();
    final joined = _allLibSources().join('\n');
    // ignore: avoid_print
    print('  [OBS] 文档含"未知工具：${text.contains('未知工具：')}"、'
        '含"上下文窗口必须是正整数"=${text.contains('上下文窗口必须是正整数')}、'
        '含"不会退回 general"=${text.contains('不会退回 general')}');
    expect(text, contains('未知工具：'), reason: '文档要写出未知工具错误');
    expect(joined, contains('未知工具：'), reason: '产品代码里要有这条错误');
    expect(text, contains('上下文窗口必须是正整数'),
        reason: '文档要写出非法窗口错误');
    expect(joined, contains('上下文窗口必须是正整数（当前输入不合法）'));
    expect(text, contains('拒绝创建实例，也不会退回 general'),
        reason: '文档要写清缺失模板不退回 general');
    expect(joined, contains('拒绝创建实例，也不会退回 general'));
  });

  test('配置键与首启基础工具清单与代码一致', () {
    final text = docs.readAsStringSync();
    final configText = configDoc.readAsStringSync();
    for (final key in const [
      'agent_types',
      'provider',
      'model',
      'system_prompt',
      'tools',
      'thinking_effort',
      'max_context_tokens',
      'input_modalities',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 配置键 $key：模板文档=${text.contains(key)} '
          '配置文档=${configText.contains(key)}');
      expect(configText, contains(key),
          reason: '配置文档缺少键 $key 的说明（user_docs_test 也会因此红）');
    }
    // 首启默认清单必须覆盖当前十项基础工具（配置文档的首启示例里逐个出现）。
    for (final tool in ToolCatalog.kBaseToolNames) {
      expect(configText, contains(tool),
          reason: '配置文档的首启示例没有覆盖基础工具 $tool');
    }
  });

  test('文档不再声称"没有图形化设置界面""只认 general""首启只有两项工具"', () {
    final configText = configDoc.readAsStringSync();
    final agentText = docs.readAsStringSync();
    final stale = <String>[
      '没有图形化设置界面',
      '应用只认名字叫',
      '首启对话框写死的那份配置里只有两个文件工具',
      '界面上不会用到',
    ];
    for (final phrase in stale) {
      // ignore: avoid_print
      print('  [OBS] 过时说法「$phrase」出现在配置文档=${configText.contains(phrase)} '
          '模板文档=${agentText.contains(phrase)}');
      expect(configText.contains(phrase), isFalse,
          reason: '配置文档仍然写着过时说法：「$phrase」');
      expect(agentText.contains(phrase), isFalse,
          reason: '模板文档里出现了过时说法：「$phrase」');
    }
  });

  test('文档说明了修改只影响之后创建或恢复的实例，且不包含删除/改名入口', () {
    final text = docs.readAsStringSync();
    expect(text, contains('不支持删除模板'));
    expect(text, contains('不支持修改模板名'));
    expect(text, contains('已经运行的会话不会热更新'));
  });

  test('Session 切换说明与界面一致，且不再声称"重开即用新配置"', () {
    final agentText = docs.readAsStringSync();
    final configText = configDoc.readAsStringSync();
    final joined = _allLibSources().join('\n');

    // 界面真实文案：产品代码与用户文档两边都要有（改文案不改文档就红）。
    for (final copy in const [
      '正在切换 Agent 模板…',
      '正在切换 Agent 模板：完成后才能发送',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 切换文案「$copy」：代码=${joined.contains(copy)} '
          '文档=${agentText.contains(copy)}');
      expect(joined, contains(copy), reason: '产品代码里没有这条切换文案：$copy');
      expect(agentText, contains(copy), reason: '用户文档没有写出这条切换文案：$copy');
    }
    expect(joined, contains('SessionAgentSwitcher'),
        reason: '切换控件必须真的接在界面上');
    expect(joined, contains('_callbacksFor(sessionId)'),
        reason: '新实例必须用该会话的界面回调');

    // 实质要求：入口位置、退役、溢出引用、数据库列、重启恢复、失败阶段与候选名、
    // 下一次请求用新模板。
    for (final phrase in const [
      '当前会话工具栏',
      '退役',
      '溢出',
      'read_spill',
      'sessions.agent_type',
      '重启',
      '失败阶段',
      '候选模板名',
      '下一次请求',
      '静默退回',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 模板文档含「$phrase」=${agentText.contains(phrase)}');
      expect(agentText, contains(phrase), reason: '模板文档没有写清「$phrase」');
    }

    // 配置文档必须写实际存在的 agent_types 键、数据库列，以及"把会话改到已有模板"
    // 的真实路径（切换控件）。
    for (final phrase in const [
      'agent_types',
      'sessions.agent_type',
      '把会话改到已有模板',
      '当前会话工具栏',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 配置文档含「$phrase」=${configText.contains(phrase)}');
      expect(configText, contains(phrase), reason: '配置文档没有写清「$phrase」');
    }

    // 反向：两句错误的"重开即应用"说明必须删掉。
    for (final wrong in const ['重新打开该会话', '重新打开它']) {
      // ignore: avoid_print
      print('  [OBS] 过时说明「$wrong」出现在模板文档=${agentText.contains(wrong)}');
      expect(agentText.contains(wrong), isFalse,
          reason: '模板文档仍然写着「$wrong」');
    }
    expect(agentText.contains('重新打开'), isFalse,
        reason: '模板文档不得再声称重新打开会话就会使用新配置');
  });
}

List<String> _allLibSources() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f.readAsStringSync(),
  ];
}
