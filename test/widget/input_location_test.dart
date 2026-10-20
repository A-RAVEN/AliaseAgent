import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/ui/context_ring.dart';
import 'package:alias_agent/ui/input_bar.dart';

import 'helpers/fakes.dart';
import '../integration/helpers/fake_sidecar.dart';

/// 覆盖 10.1：输入行被提到 `lib/main.dart` 的 `Column` 里（`Expanded` 之外），
/// 「对话视图」与「真实上下文」两屏**共用同一份** —— 所以切到第二屏时输入框与发送按钮
/// 仍在，而且整屏**各只有 1 个**（后者用来挡"在 ContextView 里再复制一份"这种糊法：
/// 那样两屏各 1 个也满足"都在"，但全屏会有 2 个）。
///
/// 这条在搬家之前会红：`ContextView` 里没有输入区，`find.byType(TextField)` 是 0 个。
void _setupAgentRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: 0,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

void main() {
  testWidgets('两屏都在、且整屏各只有一份输入行', (tester) async {
    _setupAgentRegistry();
    final sidecar = FakeSidecar();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: FakeSessionRepository(const []),
          msgRepo: FakeMessageRepository(),
          sidecar: sidecar,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // ① 对话视图
    final convField = find.byType(TextField).evaluate().length;
    final convSend = find.byIcon(Icons.send).evaluate().length;
    // ignore: avoid_print
    print('  [OBS] 对话视图：输入框=$convField 发送按钮=$convSend');
    expect(convField, 1);
    expect(convSend, 1);

    // ② 切到「真实上下文」
    await tester.tap(find.text('真实上下文'));
    await tester.pumpAndSettle();

    final ctxField = find.byType(TextField).evaluate().length;
    final ctxSend = find.byIcon(Icons.send).evaluate().length;
    // ignore: avoid_print
    print('  [OBS] 真实上下文：输入框=$ctxField 发送按钮=$ctxSend');
    expect(ctxField, 1, reason: '输入行在两屏之外，切屏不该让它消失');
    expect(ctxSend, 1, reason: '发送按钮同理');
    expect(ctxField, convField,
        reason: '整屏只许有一份输入行 —— 两个才算"复制了一份"而不是"共用"');

    // ④ 环不在工具栏那一行：整屏只有一个环，且它落在切换按钮下方。
    final ringRect = tester.getRect(find.byType(ContextRing));
    final toolbarRect = tester.getRect(find.text('对话视图'));
    // ignore: avoid_print
    print('  [OBS] 环=$ringRect 工具栏切换按钮=$toolbarRect');
    expect(find.byType(ContextRing), findsOneWidget, reason: '整屏只有一个环');
    expect(ringRect.top, greaterThan(toolbarRect.bottom),
        reason: '环已经从工具栏搬到输入行 —— 它应该在切换按钮下面');
  });

  /// 10.4：环贴在**输入行的发送按钮左侧**，且与发送按钮同一行。
  /// 在 `InputBar` 这一层量几何最直接（环作为 `accessory` 传进去，与真实布局同构）。
  testWidgets('环在发送按钮左侧，且与它同一行', (tester) async {
    const breakdown = ContextBreakdown(
      level2Tokens: 1200,
      level1Tokens: 3400,
      rawTokens: 45021,
      fixedOverheadTokens: 2002,
      windowTokens: 1000000,
    );
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InputBar(
          controller: ctrl,
          onSubmit: () {},
          accessory: const ContextRingLabeled(breakdown: breakdown),
        ),
      ),
    ));

    final ring = tester.getRect(find.byType(ContextRing));
    final label = tester.getRect(find.text('4.96%'));
    final send = tester.getRect(find.byType(IconButton));
    // ignore: avoid_print
    print('  [OBS] 环=$ring 数字=$label 发送按钮=$send');

    expect(label.right, lessThanOrEqualTo(ring.left), reason: '数字在环左边');
    expect(ring.right, lessThanOrEqualTo(send.left), reason: '环在发送按钮左侧');
    expect((ring.center.dy - send.center.dy).abs(), lessThanOrEqualTo(1.0),
        reason: '环与发送按钮同一行（只比 x 的话，把环放到消息区上方也能过）');
  });
}
