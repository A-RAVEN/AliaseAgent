import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// WCAG 相对亮度（用于算对比度）。
double _relativeLuminance(Color c) {
  double linear(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

/// WCAG 2.1 对比度（1.0 ～ 21.0）。`_contrastRatio(a, b)` 与参数顺序无关。
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
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

    testWidgets('数字在环的左边，且环仍被单独框成 20×20', (tester) async {
      await pumpLabeled(tester, _b(raw: 45021, window: 1000000));
      final labelRect = tester.getRect(find.text('4.50%'));
      final ringRect = tester.getRect(find.byType(ContextRing));
      // ignore: avoid_print
      print('  [OBS] 数字右边缘=${labelRect.right} 环的左边缘=${ringRect.left} '
          '环的尺寸=${ringRect.size}');

      expect(labelRect.right, lessThanOrEqualTo(ringRect.left),
          reason: '位置决策是"数字在环左边"，没有这条断言，放到右边或叠在环上也会绿');
      expect(ringRect.size,
          const Size(20, 20),
          reason: '数字是兄弟节点 ⇒ find.byType(ContextRing) 仍然只框住 20×20（那 4 处既有断言靠这个）');
      // 10.2：数字与环之间的间距由描边常量推导，不能再是一个来路不明的数。
      expect(ContextRingLabeled.labelGap, contextRingStroke * 2,
          reason: '间距 = 描边 × 2；写成字面量 6 的话这条会红');
      // ignore: avoid_print
      print('  [OBS] labelGap=${ContextRingLabeled.labelGap} '
          '(contextRingStroke * 2 = ${contextRingStroke * 2}) '
          '直径=$contextRingDiameter 半径=$contextRingRadius');
    });

    test('三段色相两两相差 ≥ 60°（用户 2026-10-18：要鲜艳、必须能分辨）', () {
      double hueOf(Color c) {
        final r = c.r, g = c.g, b = c.b;
        final maxV = [r, g, b].reduce((a, b) => a > b ? a : b);
        final minV = [r, g, b].reduce((a, b) => a < b ? a : b);
        final d = maxV - minV;
        if (d == 0) return 0;
        double h;
        if (maxV == r) {
          h = ((g - b) / d) % 6;
        } else if (maxV == g) {
          h = (b - r) / d + 2;
        } else {
          h = (r - g) / d + 4;
        }
        return (h * 60) % 360;
      }

      final colors = {
        '二级': contextRingLevel2Color,
        '一级': contextRingLevel1Color,
        '原文': contextRingRawColor,
      };
      final names = colors.keys.toList();
      for (var i = 0; i < names.length; i++) {
        for (var j = i + 1; j < names.length; j++) {
          final a = hueOf(colors[names[i]]!);
          final b = hueOf(colors[names[j]]!);
          var diff = (a - b).abs();
          if (diff > 180) diff = 360 - diff;
          // ignore: avoid_print
          print('  [OBS] ${names[i]}(${a.toStringAsFixed(0)}°) vs '
              '${names[j]}(${b.toStringAsFixed(0)}°) 相差 ${diff.toStringAsFixed(0)}°');
          expect(diff, greaterThanOrEqualTo(60),
              reason: '两瓣色相相差不足 60° 就分不清 —— 这正是用户投诉过的'
                  '「紫和深红看不出来」');
        }
      }
    });

    test('轨道色不是旧色，且与三段三色两两不同', () {
      // 用 `fromSeed` 造主题：裸 `ColorScheme.light()` 里 primary / tertiary / outline
      // 全是黑色 —— 那种夹具连"三段互不相同"都做不到，测不出轨道色的选择对不对。
      for (final scheme in [
        ColorScheme.fromSeed(seedColor: Colors.blue),
        ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
      ]) {
        final track = contextRingTrackColor(scheme);
        final segments = [
          contextRingLevel2Color,
          contextRingLevel1Color,
          contextRingRawColor,
        ];
        for (final seg in segments) {
          expect(track, isNot(seg),
              reason: 'spec：轨道 SHALL 另用一种颜色（与三段都不同）—— '
                  '只写"≠旧色"的话，选成 outline（正是"原文"那段的色）也会绿');
        }
        expect(track, isNot(scheme.surfaceContainerHighest),
            reason: '旧色在近黑背景上等于隐形（真机放大 12 倍才认得出）');
        // **加严**：光"不等于旧色"不够 —— 换成一个同样暗的颜色也能过。这里按
        // WCAG 2.1 SC 1.4.11（非文本内容的对比度至少 3:1）卡对比度。
        final ratio = _contrastRatio(track, scheme.surface);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: '轨道与背景的对比度 ${ratio.toStringAsFixed(2)}:1 低于 3:1，'
                '在近黑背景上仍然看不见');
        // ignore: avoid_print
        print('  [OBS] ${scheme.brightness}：轨道=$track 三段=$segments '
            '旧色=${scheme.surfaceContainerHighest} '
            '对比度=${ratio.toStringAsFixed(2)}:1');
      }
    });
    testWidgets('三段各画一种颜色（像素级，11.3）', (tester) async {
      // 为什么要有这条：真机里"投影含二级摘要"在当前压缩策略下不可达
      // （近端原文区始终约 1×T，而二级要 ≥2T 才顶替），所以三段三色的样子
      // 只能在这一层验 —— 数据是真的 ContextBreakdown，渲染是真的 ContextRing。
      const b = ContextBreakdown(
        level2Tokens: 1000,
        level1Tokens: 2000,
        rawTokens: 3000,
        fixedOverheadTokens: 0,
        windowTokens: 10000,
      );
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: const ContextRing(breakdown: b),
            ),
          ),
        ),
      ));

      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // `toImage()` / `toByteData()` 会真的等异步回片，必须放在 `runAsync` 里 ——
      // 直接 await 会把控件测试挂死（这次实测挂到超时）。
      ui.Image? image;
      ByteData? bytes;
      await tester.runAsync(() async {
        image = await boundary.toImage();
        bytes = await image!.toByteData();
      });
      final raw = bytes!;
      final scheme = Theme.of(tester.element(find.byType(ContextRing))).colorScheme;
      final wanted = <String, Color>{
        '二级': contextRingLevel2Color,
        '一级': contextRingLevel1Color,
        '原文': contextRingRawColor,
        '轨道': contextRingTrackColor(scheme),
      };
      final counts = <String, int>{for (final k in wanted.keys) k: 0};
      for (var i = 0; i < raw.lengthInBytes; i += 4) {
        final r = raw.getUint8(i), g = raw.getUint8(i + 1), bl = raw.getUint8(i + 2);
        wanted.forEach((name, c) {
          // 容差 12/255：抗锯齿边缘会掺一点背景色，不计入。
          if ((r - (c.r * 255)).abs() <= 12 &&
              (g - (c.g * 255)).abs() <= 12 &&
              (bl - (c.b * 255)).abs() <= 12) {
            counts[name] = counts[name]! + 1;
          }
        });
      }
      // ignore: avoid_print
      print('  [OBS] 像素计数（${image!.width}×${image!.height}）：$counts');

      for (final name in ['二级', '一级', '原文']) {
        expect(counts[name], greaterThan(0),
            reason: '「$name」那一块必须真的被画出来 —— 把它的 token 改成 0 这条就红');
      }
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

      expect(size, const Size(20, 20),
          reason: '有拆分时环按 20 逻辑像素渲染（用户 2026-10-18 指定，不再是参照物的 14）');
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

      expect(size, const Size(20, 20),
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

      expect(size, const Size(20, 20),
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
