import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/ui/compaction_status_banner.dart';
import 'package:alias_agent/ui/context_ring.dart';

/// 点开的面板：数字对不对、来源标注落在哪几行、底部那句是不是仓库里那一句。
///
/// 用一组固定读数（design D6 那张表）：二级 1200 / 一级 3400 / 原文 2760 /
/// 固定开销 6000 ⇒ 合计 13360。

ContextBreakdown _fixture() => const ContextBreakdown(
      level2Tokens: 1200,
      level1Tokens: 3400,
      rawTokens: 2760,
      fixedOverheadTokens: 6000,
      windowTokens: 100000,
    );

Future<void> _openPanel(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Center(child: ContextRing(breakdown: _fixture()))),
  ));
  await tester.tap(find.byType(ContextRing));
  await tester.pumpAndSettle();
}

/// 面板里所有可见文字（按渲染顺序）。
List<String> _panelTexts(WidgetTester tester) {
  final texts = <String>[];
  for (final w in tester.widgetList<Text>(find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(Text),
  ))) {
    if (w.data != null) texts.add(w.data!);
  }
  return texts;
}

void main() {
  group('面板与环旁同口径', () {
    testWidgets('面板那个百分比与环旁逐字相同；面板里没有分数那一截', (tester) async {
      final b = _fixture();
      final expected = ContextRingLabeled.labelOf(b);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: ContextRingLabeled(breakdown: b))),
      ));
      final ringSide = tester.widget<Text>(find.textContaining('%')).data;
      await tester.tap(find.byType(ContextRing));
      await tester.pumpAndSettle();
      final texts = _panelTexts(tester);
      final percents = texts.where((t) => t.contains('%')).toList();
      // ignore: avoid_print
      print('  [OBS] 汇总：三段=${b.conversationTokens} 四项=${b.usedTokens} 窗口=${b.windowTokens} '
          'labelOf=$expected 环旁=$ringSide 面板里的百分比=$percents '
          '面板里有分数形式=${texts.any((t) => t.contains(' / '))}');

      expect(ringSide, expected, reason: '环旁那个数就是 labelOf 算出来的');
      expect(percents, [expected],
          reason: '面板里只许有一个百分比，且与环旁逐字相同（用四项算会变成 10.80%）');
      expect(texts.any((t) => t.contains(' / ')), isFalse,
          reason: '分数那一截必须真的删掉，不是只换分子');
    });

    testWidgets('固定开销变了，环旁与面板那个数都不跟着变', (tester) async {
      final noFixed = const ContextBreakdown(
        level2Tokens: 1200,
        level1Tokens: 3400,
        rawTokens: 2760,
        fixedOverheadTokens: 0,
        windowTokens: 100000,
      );
      final withFixed = _fixture(); // 同样的三段，固定开销 6000
      // ignore: avoid_print
      print('  [OBS] 固定=0 → ${ContextRingLabeled.labelOf(noFixed)}   '
          '固定=6000 → ${ContextRingLabeled.labelOf(withFixed)}');

      expect(ContextRingLabeled.labelOf(withFixed),
          ContextRingLabeled.labelOf(noFixed),
          reason: '分子是环上三段之和，固定开销改变不了它');
    });
  });

  group('占用面板', () {
    testWidgets('6.2 五行数字、来源标注落在该落的行、合计等于四项相加', (tester) async {
      await _openPanel(tester);
      final texts = _panelTexts(tester);
      // ignore: avoid_print
      print('  [OBS] 面板文本=$texts');

      expect(find.byType(AlertDialog), findsOneWidget, reason: '点一下就该弹出面板');

      // 五行数字：二级 / 一级 / 原文 / 固定开销 / 合计
      for (final v in ['1200', '3400', '2760', '6000']) {
        expect(texts, contains(v), reason: '面板里必须逐项列出 $v');
      }
      expect(texts, contains('13360'),
          reason: '合计必须等于四项相加：1200 + 3400 + 2760 + 6000 = 13360');

      final measured =
          texts.where((t) => t.contains('实测')).toList();
      final estimated =
          texts.where((t) => t.contains('估算')).toList();
      // ignore: avoid_print
      print('  [OBS] 标「实测」的行=$measured 标「估算」的行=$estimated');

      expect(measured.length, 2, reason: '「实测」只许出现在二级与一级两行上');
      expect(estimated.length, 2,
          reason: '「估算」只许出现在原文与系统提示词+工具定义两行上');

      expect(texts.any((t) => t.contains('环上不含')), isTrue,
          reason: '面板必须写明环上不含固定开销那一行');
      expect(texts, contains(CompactionStatusBanner.contextViewNote),
          reason: '底部必须复用「真实上下文」那一屏的原句');
      expect(find.text('关闭'), findsOneWidget, reason: '面板要有一个关闭按钮');
    });

    testWidgets('6.2b 点关闭后回到原来那一屏', (tester) async {
      await _openPanel(tester);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('  [OBS] 关闭后还有没有面板=${find.byType(AlertDialog).evaluate().isNotEmpty} '
          '环还在不在=${find.byType(ContextRing).evaluate().isNotEmpty}');

      expect(find.byType(AlertDialog), findsNothing, reason: '关闭按钮要真的关掉面板');
      expect(find.byType(ContextRing), findsOneWidget, reason: '关掉面板后环照旧在');
    });
  });
}
