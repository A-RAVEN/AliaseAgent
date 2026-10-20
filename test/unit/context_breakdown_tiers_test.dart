import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/context_estimator.dart';

/// 12.2：`ContextBreakdown.fromTiers` 的口径与几何。
///
/// 这个工厂是"按层级划分整段对话"那条新口径的入口（2026-10-18 用户要求三瓣）：
/// 三段 token 由调用方按"每条消息取盖住它的最高层级"算好后传进来，这里只负责
/// 把它变成环上的三段与两个派生量。
void main() {
  group('ContextBreakdown.fromTiers', () {
    test('三段弧度按 token 成比例，且三段之和等于 conversationTokens', () {
      final b = ContextBreakdown.fromTiers(
        level2Tokens: 1000,
        level1Tokens: 2000,
        rawTokens: 3000,
        windowTokens: 10000,
        fixedOverheadTokens: 500,
      );
      final segs = b.ringSegments;
      // ignore: avoid_print
      print('  [OBS] tokens=${segs.map((s) => s.tokens).toList()} '
          '弧度=${segs.map((s) => s.sweepRadians.toStringAsFixed(6)).toList()} '
          'conversation=${b.conversationTokens} used=${b.usedTokens}');

      expect(segs.map((s) => s.tokens).toList(), [1000, 2000, 3000],
          reason: '顺序必须是 二级 → 一级 → 原文，与绘制起点一致');
      expect(b.conversationTokens, 6000, reason: '三段之和 = 对话总量');
      expect(b.usedTokens, 6500, reason: 'usedTokens 是四项相加（含固定开销）');
      for (final s in segs) {
        expect(s.sweepRadians,
            closeTo(s.tokens / b.windowTokens * 2 * math.pi, 1e-9),
            reason: '每段扫过的角度 = 该段 token ÷ 窗口 × 360°');
      }
    });

    test('某一层为 0 时那一段弧度就是 0（不是被漏掉）', () {
      final b = ContextBreakdown.fromTiers(
        level2Tokens: 0,
        level1Tokens: 2918,
        rawTokens: 2132,
        windowTokens: 8660,
        fixedOverheadTokens: 1676,
      );
      final segs = b.ringSegments;
      // ignore: avoid_print
      print('  [OBS] 两段：tokens=${segs.map((s) => s.tokens).toList()} '
          '弧度=${segs.map((s) => s.sweepRadians.toStringAsFixed(6)).toList()}');

      expect(segs.first.tokens, 0);
      expect(segs.first.sweepRadians, 0,
          reason: 'token 为 0 的那一段不画（弧度为 0），但仍占着段位');
      expect(segs[1].sweepRadians, greaterThan(0));
      expect(segs[2].sweepRadians, greaterThan(0));
    });

    test('窗口为 0 时没有可画的段（环渲染成空盒子）', () {
      final b = ContextBreakdown.fromTiers(
        level2Tokens: 10,
        level1Tokens: 20,
        rawTokens: 30,
        windowTokens: 0,
        fixedOverheadTokens: 5,
      );
      // ignore: avoid_print
      print('  [OBS] 窗口 0：段数=${b.ringSegments.length}');
      expect(b.ringSegments, isEmpty);
    });
    test('fromSummaries：二级/一级各按自己摘要的 tokenCost 计，原文只算没被覆盖的', () {
      final messages = [
        for (var i = 1; i <= 8; i++)
          Message(
            id: 'm$i',
            seq: i,
            sessionId: 's1',
            role: i.isEven ? 'user' : 'assistant',
            content: 'msg $i ' * 10,
            createdAt: i,
          ),
      ];
      // 一条二级（1..5，自身 300 token）+ 一条一级（2..3，自身 120 token）。
      final b = ContextBreakdown.fromSummaries(
        messages: messages,
        summaries: const [
          (level: 2, minSeq: 1, maxSeq: 5, tokenCost: 300),
          (level: 1, minSeq: 2, maxSeq: 3, tokenCost: 120),
        ],
        windowTokens: 100000,
        fixedOverheadTokens: 0,
      );

      int sumOf(Iterable<Message> ms) =>
          ms.fold(0, (acc, m) => acc + ContextEstimator.estimateMessage(m));
      final uncovered = sumOf(messages.where((m) => (m.seq ?? 0) > 5));
      // ignore: avoid_print
      print('  [OBS] level2=${b.level2Tokens} level1=${b.level1Tokens} '
          'raw=${b.rawTokens}（原文期望 $uncovered，只算没被任何摘要覆盖的 6..8）');

      expect(b.level2Tokens, 300, reason: '二级 = 二级摘要自己的 tokenCost');
      expect(b.level1Tokens, 120,
          reason: '一级 = 一级摘要自己的 tokenCost（新口径允许与二级重叠计）');
      expect(b.rawTokens, uncovered, reason: '1..5 已被摘要覆盖 ⇒ 不算原文');
    });

    test('fromSummaries：完全没有摘要时全部算原文（退化路径）', () {
      final messages = [
        for (var i = 1; i <= 3; i++)
          Message(
            id: 'm$i',
            seq: i,
            sessionId: 's1',
            role: 'user',
            content: 'x' * 40,
            createdAt: i,
          ),
      ];
      final b = ContextBreakdown.fromSummaries(
        messages: messages,
        summaries: const [],
        windowTokens: 1000,
        fixedOverheadTokens: 10,
        extraRawTokens: 7,
      );
      final sum = messages.fold(
          0, (acc, m) => acc + ContextEstimator.estimateMessage(m));
      // ignore: avoid_print
      print('  [OBS] 无摘要：level2=${b.level2Tokens} level1=${b.level1Tokens} '
          'raw=${b.rawTokens}（= $sum + 7 工具轮）');

      expect(b.level2Tokens, 0);
      expect(b.level1Tokens, 0);
      expect(b.rawTokens, sum + 7, reason: '工具轮那些消息也算原文');
    });
  });
}
