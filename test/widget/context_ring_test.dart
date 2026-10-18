import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/ui/context_ring.dart';

/// 环这个控件的渲染判据。
///
/// 五种情形：三段非零 / 只有原文 / 三段全零 / 窗口为 0 / 没有拆分。
/// 每条断言之前先把实际读数打出来（尺寸、环上段数、每段的 token 与弧度）。

ContextBreakdown _b({
  int level2 = 0,
  int level1 = 0,
  int raw = 0,
  int fixed = 0,
  int window = 100000,
}) =>
    ContextBreakdown(
      level2Tokens: level2,
      level1Tokens: level1,
      rawTokens: raw,
      fixedOverheadTokens: fixed,
      windowTokens: window,
    );

Future<void> _pump(WidgetTester tester, ContextBreakdown? b) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Center(child: ContextRing(breakdown: b))),
  ));
}

void main() {
  group('环旁的数字', () {
    Future<void> pumpLabeled(WidgetTester tester, ContextBreakdown? b) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: ContextRingLabeled(breakdown: b))),
      ));
    }

    testWidgets('4.5% 时环旁出现 4.50%，并量出它的宽度', (tester) async {
      final b = _b(raw: 45021, window: 1000000);
      await pumpLabeled(tester, b);
      final label = find.text('4.50%');
      final found = label.evaluate().length;
      // ignore: avoid_print
      print('  [OBS] 三段=${b.conversationTokens} 窗口=${b.windowTokens} '
          '期望=4.50% 找到=$found 文本宽度=${found == 0 ? "n/a" : tester.getSize(label).width}');

      expect(found, 1,
          reason: '分子是环上三段之和：45021 / 1000000 = 4.5021% ⇒ 两位小数 4.50%');
      expect(tester.getSize(label).width, greaterThan(0),
          reason: '这个宽度就是 design D10 里"未量过"的那个数，9.3 用这条把它量出来');
    });

    testWidgets('固定开销不改变环旁那个数（分子只有三项）', (tester) async {
      final noFixed = _b(raw: 45021, window: 1000000);
      final withFixed = _b(raw: 45021, fixed: 6000, window: 1000000);
      await pumpLabeled(tester, noFixed);
      final a = tester.widget<Text>(find.textContaining('%')).data;
      await pumpLabeled(tester, withFixed);
      final c = tester.widget<Text>(find.textContaining('%')).data;
      // ignore: avoid_print
      print('  [OBS] 固定开销=0 → $a   固定开销=6000 → $c');

      expect(a, '4.50%');
      expect(c, a,
          reason: '固定开销不在环上，所以它不许改变这个百分比（换成 usedTokens 就会变）');
    });

    testWidgets('窗口为 0 与没有拆分时都不出现数字', (tester) async {
      await pumpLabeled(tester, _b(raw: 500, window: 0));
      final zeroWindow = find.textContaining('%').evaluate().length;
      await pumpLabeled(tester, null);
      final noBreakdown = find.textContaining('%').evaluate().length;
      // ignore: avoid_print
      print('  [OBS] 窗口=0 时百分比个数=$zeroWindow；breakdown=null 时=$noBreakdown');

      expect(zeroWindow, 0, reason: '窗口未知 ⇒ 没有比例可算');
      expect(noBreakdown, 0, reason: '还没捕获过 ⇒ 没有数字');
    });

    testWidgets('数字在环的左边，且环仍被单独框成 14×14', (tester) async {
      await pumpLabeled(tester, _b(raw: 45021, window: 1000000));
      final labelRect = tester.getRect(find.text('4.50%'));
      final ringRect = tester.getRect(find.byType(ContextRing));
      // ignore: avoid_print
      print('  [OBS] 数字右边缘=${labelRect.right} 环的左边缘=${ringRect.left} '
          '环的尺寸=${ringRect.size}');

      expect(labelRect.right, lessThanOrEqualTo(ringRect.left),
          reason: '位置决策是"数字在环左边"，没有这条断言，放到右边或叠在环上也会绿');
      expect(ringRect.size,
          const Size(contextRingDiameter, contextRingDiameter),
          reason: '数字是兄弟节点 ⇒ find.byType(ContextRing) 仍然只框住 14×14（那 5 处既有断言靠这个）');
    });
  });

  group('上下文占用环控件', () {
    testWidgets('三段非零：环上三段，按 二级→一级→原文 排', (tester) async {
      final b = _b(level2: 1200, level1: 3400, raw: 200, fixed: 6000);
      await _pump(tester, b);

      final size = tester.getSize(find.byType(ContextRing));
      final segs = b.ringSegments;
      // ignore: avoid_print
      print('  [OBS] 三段非零：控件尺寸=$size 环上段数=${segs.length} '
          '各段 tokens=${segs.map((s) => s.tokens).toList()} '
          '各段弧度=${segs.map((s) => s.sweepRadians.toStringAsFixed(6)).toList()}');

      expect(size, const Size(contextRingDiameter, contextRingDiameter),
          reason: '有拆分时环按参照物的 14 逻辑像素渲染');
      expect(find.byType(CustomPaint), findsWidgets,
          reason: '轨道与三段弧都靠 CustomPainter 画');
      expect(segs.length, 3, reason: '三段都在 ⇒ 环上就是三段');
      expect(segs.map((s) => s.tokens).toList(), [1200, 3400, 200],
          reason: '顺序固定为 二级 → 一级 → 原文');
      expect(segs[0].sweepRadians, greaterThan(segs[2].sweepRadians),
          reason: '一级那段最大 ⇒ 它扫过的弧度也必须最大（1200 < 3400 > 200）');
    });

    testWidgets('两级为零：环上只有原文一段', (tester) async {
      final b = _b(raw: 500);
      await _pump(tester, b);

      final size = tester.getSize(find.byType(ContextRing));
      final nz = b.ringSegments.where((s) => s.tokens > 0).length;
      // ignore: avoid_print
      print('  [OBS] 两级为零：控件尺寸=$size 环上段数=${b.ringSegments.length} '
          '非零段数=$nz 各段 tokens=${b.ringSegments.map((s) => s.tokens).toList()}');

      expect(size, const Size(contextRingDiameter, contextRingDiameter),
          reason: '有内容就照常画环，不能因为只有一段就消失');
      expect(b.ringSegments.length, 3,
          reason: '环上始终是三段（为零的那两段扫 0 度），不是"只有一段"');
      expect(nz, 1, reason: '实际画出来的弧只有原文那一段');
    });

    testWidgets('三段全零：轨道仍然画出来', (tester) async {
      final b = _b();
      await _pump(tester, b);

      final size = tester.getSize(find.byType(ContextRing));
      final painters = tester.widgetList(find.byType(CustomPaint)).length;
      // ignore: avoid_print
      print('  [OBS] 三段全零：控件尺寸=$size CustomPaint 个数=$painters '
          '各段 tokens=${b.ringSegments.map((s) => s.tokens).toList()}');

      expect(size, const Size(contextRingDiameter, contextRingDiameter),
          reason: '没有内容也照常画轨道圆环，不许整块消失');
      expect(painters, greaterThan(0), reason: '画布还在（轨道由它画）');
    });

    testWidgets('窗口为 0：渲染成不占高度的空盒子', (tester) async {
      await _pump(tester, _b(raw: 500, window: 0));
      final size = tester.getSize(find.byType(ContextRing));
      // ignore: avoid_print
      print('  [OBS] 窗口为 0：控件尺寸=$size');

      expect(size, Size.zero, reason: '窗口未知 ⇒ 没有"占多少"，不占布局高度');
    });

    testWidgets('没有拆分：渲染成不占高度的空盒子', (tester) async {
      await _pump(tester, null);
      final size = tester.getSize(find.byType(ContextRing));
      // ignore: avoid_print
      print('  [OBS] 没有拆分：控件尺寸=$size');

      expect(size, Size.zero, reason: '还没捕获过 ⇒ 不占布局高度');
    });
  });
}
