import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';

/// 三段分类与环的排布的判据都在这个文件里。
///
/// 分类口径（design D1）：**按这一趟实际发出去的表示**分，不按段自己的层级分 ——
/// `summary == null` 的段一律算原文，哪怕它的 `segment.level` 是 1（"已经压成摘要、
/// 但位置还不够远"就是这种形状）。每条断言之前都先把读数打出来。

/// 每条消息的估算 token 数 = [rawPerMsg]，正文带 `m<seq>:` 标签便于读现场。
List<Message> _conv(int n, int rawPerMsg) {
  final len = (rawPerMsg - 4) * 4 - 3;
  return [
    for (var i = 0; i < n; i++)
      Message(
        id: 'p$i',
        seq: i + 1,
        sessionId: 's1',
        role: i.isEven ? 'user' : 'assistant',
        content: 'm${i + 1}:${'A' * (len - 'm${i + 1}:'.length)}',
        createdAt: i,
      ),
  ];
}

SummaryResult _sum(int tokens) => SummaryResult(text: '摘要 $tokens', tokens: tokens);

void main() {
  group('上下文占用拆分', () {
    test('场景 A：已压成摘要但还不够远的段计入原文', () {
      final msgs = _conv(4, 100);
      // 形状取自 lib/main.dart 的 _resolveSummaries：段自己被标成 level 1 的摘要段，
      // 但这一趟 `sentAsSummary` 判否 ⇒ 走的是原文，所以 summary 为 null。
      final piece = ProjectionPiece(
        segment: CompactionSegment(messages: msgs, summary: true, level: 1),
        summary: null,
      );
      final b = ContextBreakdown.fromTimeline(
        timeline: [piece],
        windowTokens: 10000,
        fixedOverheadTokens: 500,
      );
      final expectedRaw = CompactionEngine.rawTokens(msgs);
      // ignore: avoid_print
      print('  [OBS] 场景A level2=${b.level2Tokens} level1=${b.level1Tokens} '
          'raw=${b.rawTokens}（该段估算=$expectedRaw）'
          '固定=${b.fixedOverheadTokens} 窗口=${b.windowTokens}');

      expect(b.level2Tokens, 0, reason: '这一趟没发摘要 ⇒ 二级必须是 0');
      expect(b.level1Tokens, 0,
          reason: '段被标成 level 1 的摘要，但这一趟按原文发 ⇒ 不许算进一级');
      expect(b.rawTokens, expectedRaw,
          reason: '它的量必须落在原文里（用仓库既有估算器算出来的那个数）');
    });

    test('场景 B：两级分别计入，环上三段', () {
      final l2msgs = _conv(2, 100);
      final l1msgs = _conv(2, 100);
      final rawMsgs = _conv(2, 100);
      final b = ContextBreakdown.fromTimeline(
        timeline: [
          ProjectionPiece(
            segment: CompactionSegment(messages: l2msgs, summary: true, level: 2),
            summary: _sum(1200),
          ),
          ProjectionPiece(
            segment: CompactionSegment(messages: l1msgs, summary: true, level: 1),
            summary: _sum(3400),
          ),
          ProjectionPiece(
            segment: CompactionSegment(messages: rawMsgs, summary: false),
          ),
        ],
        windowTokens: 100000,
        fixedOverheadTokens: 6000,
      );
      // ignore: avoid_print
      print('  [OBS] 场景B level2=${b.level2Tokens} level1=${b.level1Tokens} '
          'raw=${b.rawTokens}（该段估算=${CompactionEngine.rawTokens(rawMsgs)}）'
          '固定=${b.fixedOverheadTokens} 环上段数=${b.ringSegments.length}');

      expect(b.level2Tokens, 1200, reason: '二级那段报的是模型实测的 1200');
      expect(b.level1Tokens, 3400, reason: '一级那段报的是模型实测的 3400');
      expect(b.rawTokens, CompactionEngine.rawTokens(rawMsgs),
          reason: '按原文发的那段走估算器');
      expect(b.ringSegments.length, 3, reason: '三段都在 ⇒ 环上就是三段');
    });

    test('场景 C：没有摘要时只有原文一段', () {
      final msgs = _conv(6, 100);
      final b = ContextBreakdown.fromTimeline(
        timeline: [
          ProjectionPiece(
              segment: CompactionSegment(messages: msgs, summary: false)),
        ],
        windowTokens: 100000,
        fixedOverheadTokens: 0,
      );
      final direct = CompactionEngine.rawTokens(msgs);
      // ignore: avoid_print
      print('  [OBS] 场景C level2=${b.level2Tokens} level1=${b.level1Tokens} '
          'raw=${b.rawTokens} 直接调 rawTokens=$direct');

      expect(b.level2Tokens, 0);
      expect(b.level1Tokens, 0);
      expect(b.rawTokens, direct,
          reason: '两个数必须相等（同一个估算器算出来的），不是各自手算');
    });

    test('场景 D：环的排布与角度和', () {
      final rawMsgs = _conv(2, 100);
      final b = ContextBreakdown.fromTimeline(
        timeline: [
          ProjectionPiece(
            segment: CompactionSegment(messages: _conv(2, 100), summary: true, level: 2),
            summary: _sum(1200),
          ),
          ProjectionPiece(
            segment: CompactionSegment(messages: _conv(2, 100), summary: true, level: 1),
            summary: _sum(3400),
          ),
          ProjectionPiece(
              segment: CompactionSegment(messages: rawMsgs, summary: false)),
        ],
        windowTokens: 100000,
        fixedOverheadTokens: 6000,
      );
      final segs = b.ringSegments;
      final sum = segs.fold<double>(0, (m, s) => m + s.sweepRadians);
      final expected = b.conversationTokens / b.windowTokens * 2 * 3.141592653589793;
      // ignore: avoid_print
      print('  [OBS] 场景D 三段 tokens=${segs.map((s) => s.tokens).toList()} '
          '角度和=$sum 期望=$expected '
          'used=${b.usedTokens} 环上=${b.conversationTokens} 固定=${b.fixedOverheadTokens}');

      expect(segs.map((s) => s.tokens).toList(),
          [b.level2Tokens, b.level1Tokens, b.rawTokens],
          reason: '顺序固定为 二级 → 一级 → 原文');
      expect(sum, closeTo(expected, 1e-9),
          reason: '三段扫过的角度之和 = 环上三项 ÷ 窗口 × 2π（不是四项那个数）');
      expect(b.usedTokens - b.conversationTokens, b.fixedOverheadTokens,
          reason: '合计与环上三段的差额恰好是固定开销 —— 它不在环上');

      final zero = ContextBreakdown.fromTimeline(
        timeline: const [],
        windowTokens: 0,
        fixedOverheadTokens: 0,
      );
      // ignore: avoid_print
      print('  [OBS] 场景D 窗口为 0 时 ringSegments=${zero.ringSegments}');
      expect(zero.ringSegments, isEmpty, reason: '窗口未知 ⇒ 没有角度可算，返回空列表');
    });

    test('场景 E：工具轮追加的消息计入原文', () {
      final rawMsgs = _conv(2, 100);
      // 形状就是 apiMessages 里那些：API 格式的 map（含工具块，不是 Message）。
      final trailing = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'call_1', 'name': 'read_file', 'input': {'path': 'a.txt'}},
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'call_1', 'content': 'A' * 200},
          ],
        },
      ];
      ContextBreakdown build(
              {List<Map<String, dynamic>> trailingRawMessages = const []}) =>
          ContextBreakdown.fromTimeline(
            timeline: [
              ProjectionPiece(
                  segment: CompactionSegment(messages: rawMsgs, summary: false)),
            ],
            windowTokens: 100000,
            fixedOverheadTokens: 0,
            trailingRawMessages: trailingRawMessages,
          );
      final withTrailing = build(trailingRawMessages: trailing);
      final without = build();
      final expected =
          ContextEstimator.estimateTokens(jsonEncode(trailing));
      // ignore: avoid_print
      print('  [OBS] 场景E 带追加=${withTrailing.rawTokens} 不带=${without.rawTokens} '
          '追加部分估算=$expected');

      expect(withTrailing.rawTokens - without.rawTokens, expected,
          reason: '投影之后才追加进请求的消息没有投影段，必须按原文补进 rawTokens'
              '（用同一个估算器、按序列化后的长度算）');
    });
  });
}
