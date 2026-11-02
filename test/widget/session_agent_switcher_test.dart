import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/session_agent_switcher.dart';

/// 当前会话工具栏上的 Agent 模板选择控件（任务 3.6）。
///
/// 固定的是：显示当前 `Session.agentType`；列出模板注册表里的全部模板；禁用时
/// `onChanged` 为 null（点不动）；选中另一个模板时回调收到模板名；当前值不在列表里
/// 时不崩、也不偷偷换成别的名字。
void main() {
  Future<void> pumpSwitcher(
    WidgetTester tester, {
    required List<String> templateNames,
    String? current,
    bool enabled = true,
    ValueChanged<String>? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SessionAgentSwitcher(
            templateNames: templateNames,
            current: current,
            enabled: enabled,
            onChanged: onChanged,
          ),
        ),
      ),
    ));
  }

  testWidgets('显示当前模板并列出全部模板', (tester) async {
    await pumpSwitcher(tester, templateNames: ['general', 'reviewer'], current: 'general');
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    // ignore: avoid_print
    print('  [OBS] 当前值=${dropdown.value} '
        'items=${dropdown.items!.map((i) => i.value).toList()} '
        'onChanged 为空=${dropdown.onChanged == null}');
    expect(dropdown.value, 'general');
    expect(dropdown.items!.map((i) => i.value).toList(), ['general', 'reviewer']);
    expect(find.text('general'), findsOneWidget);
  });

  testWidgets('禁用时点不动：onChanged 为 null', (tester) async {
    var changes = 0;
    await pumpSwitcher(
      tester,
      templateNames: ['general', 'reviewer'],
      current: 'general',
      enabled: false,
      onChanged: (_) => changes++,
    );
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    // ignore: avoid_print
    print('  [OBS] 禁用时 onChanged=${dropdown.onChanged}');
    expect(dropdown.onChanged, isNull);
    await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
    await tester.pumpAndSettle();
    expect(changes, 0, reason: '禁用时点击不得触发切换');
    expect(find.text('reviewer'), findsNothing, reason: '禁用时菜单不该展开');
  });

  testWidgets('选中另一个模板时回调收到模板名', (tester) async {
    final picked = <String>[];
    await pumpSwitcher(
      tester,
      templateNames: ['general', 'reviewer'],
      current: 'general',
      onChanged: picked.add,
    );
    await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 菜单展开后可见项=${find.text('reviewer').evaluate().length}');
    await tester.tap(find.text('reviewer').last);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 回调收到=$picked');
    expect(picked, ['reviewer']);
  });

  testWidgets('选中的就是当前模板时不触发回调', (tester) async {
    final picked = <String>[];
    await pumpSwitcher(
      tester,
      templateNames: ['general', 'reviewer'],
      current: 'reviewer',
      onChanged: picked.add,
    );
    await tester.tap(find.byKey(const ValueKey('session-agent-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('reviewer').last);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });

  testWidgets('当前值不在模板列表里时不崩，且不偷偷换名字', (tester) async {
    await pumpSwitcher(
      tester,
      templateNames: ['general', 'reviewer'],
      current: 'ghost',
      onChanged: (_) {},
    );
    final dropdown = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('session-agent-switcher')));
    // ignore: avoid_print
    print('  [OBS] 缺失模板时 value=${dropdown.value} 提示文字 ghost='
        '${find.text('ghost').evaluate().isNotEmpty}');
    expect(tester.takeException(), isNull);
    expect(dropdown.value, isNull, reason: '不在列表里的名字不能塞进 DropdownButton');
    expect(find.text('ghost'), findsOneWidget, reason: '仍然显示数据库里的真实值');
    expect(find.text('general'), findsNothing, reason: '不得静默换成 general');
  });
}
