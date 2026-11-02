import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/ui/agent_template_menu.dart';

/// 模板菜单（change `add-agent-object-and-templates` 任务 3.1）。
///
/// 固定的是：列出每个模板的名字 / 模型 / 推理强度，提供添加与修改入口，
/// 且界面上不出现 provider 密钥。
void main() {
  const general = AgentTypeConfig(
    name: 'general',
    provider: 'anthropic',
    model: 'claude-sonnet-4-6',
    systemPrompt: '你是助手',
    tools: ['read_file'],
    maxContextTokens: 100000,
    thinkingEffort: 'high',
  );
  const reviewer = AgentTypeConfig(
    name: 'reviewer',
    provider: 'deepseek',
    model: 'deepseek-v4',
    systemPrompt: '你是评审',
    tools: ['read_file'],
    maxContextTokens: 64000,
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('列出每个模板的名字、模型与推理强度，并提供添加 / 修改入口', (tester) async {
    AgentTypeConfig? edited;
    var added = 0;
    await tester.pumpWidget(wrap(AgentTemplateMenu(
      templates: const [general, reviewer],
      onEdit: (t) => edited = t,
      onAdd: () => added++,
    )));
    await tester.pump();

    // ignore: avoid_print
    print('  [OBS] 菜单文本：${find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList()}');

    expect(find.text('general'), findsOneWidget);
    expect(find.text('reviewer'), findsOneWidget);
    expect(find.textContaining('claude-sonnet-4-6'), findsOneWidget);
    expect(find.textContaining('deepseek-v4'), findsOneWidget);
    expect(find.textContaining('推理：high'), findsOneWidget);
    expect(find.textContaining('推理：关闭'), findsOneWidget,
        reason: '没配推理强度的模板要显示"关闭"，不能空着');
    expect(find.byKey(const ValueKey('add-template')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-template-general')), findsOneWidget);
    expect(find.byKey(const ValueKey('edit-template-reviewer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-template-reviewer')));
    await tester.pump();
    expect(edited?.name, 'reviewer');

    await tester.tap(find.byKey(const ValueKey('add-template')));
    await tester.pump();
    expect(added, 1);
  });

  testWidgets('界面不出现 provider 密钥或 api_key 字样', (tester) async {
    await tester.pumpWidget(wrap(const AgentTemplateMenu(
      templates: [general, reviewer],
    )));
    await tester.pump();

    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .toList();
    final joined = texts.join('\n');
    // ignore: avoid_print
    print('  [OBS] 菜单里的全部文本：$texts');
    expect(joined.contains('api_key'), isFalse,
        reason: '菜单不许显示 provider 密钥（连字段名都不该出现）');
    expect(joined.contains('sk-'), isFalse);
    expect(joined.contains('anthropic'), isFalse,
        reason: 'provider 名字也可以不展示；展示的是名字也不是密钥，但这里收得更紧');
  });
}
