import 'dart:convert';
import 'dart:math' as math;

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/context_estimator.dart';

/// 投影时间线上的一段：要么发摘要（[summary] 非空，标记由 [segment] 的层级决定），
/// 要么把 [segment] 里的原文原样发出去（[summary] 为空）。两种段在时间里交错排列：
/// 离现在还不够远的那一段即使已经被压成摘要，这一趟也仍然发原文。
class ProjectionPiece {
  final CompactionSegment segment;
  final SummaryResult? summary;
  const ProjectionPiece({required this.segment, this.summary});
}

/// 环上的一段的排布：这一段占多少 token、扫过多少弧度。
typedef RingSegment = ({int tokens, double sweepRadians});

/// 一趟请求的占用拆分：二级摘要 / 一级摘要 / 原文 + 系统提示词与工具定义。
///
/// 分类口径见 design D1：**按这一趟实际发出去的表示**分，不按段自己的层级分 ——
/// 已经压成摘要、但位置还不够远的段，这一趟仍按原文发，就算进原文。
class ContextBreakdown {
  /// 二级摘要：各段实测 `output_tokens` 之和。
  final int level2Tokens;

  /// 一级摘要：各段实测 `output_tokens` 之和。
  final int level1Tokens;

  /// 原文：按估算器算（含工具轮追加的那些消息）。
  final int rawTokens;

  /// 系统提示词 + 工具定义：按估算器算。**不在环上**（design D5）。
  final int fixedOverheadTokens;

  /// 模型上下文窗口；<= 0 视为未知。
  final int windowTokens;

  const ContextBreakdown({
    required this.level2Tokens,
    required this.level1Tokens,
    required this.rawTokens,
    required this.fixedOverheadTokens,
    required this.windowTokens,
  });

  /// 四项之和 —— 面板上那个「合计」。
  int get usedTokens =>
      level2Tokens + level1Tokens + rawTokens + fixedOverheadTokens;

  /// **环上**三段之和（对话消息那部分，不含固定开销）。
  ///
  /// 与 [usedTokens] 分开两个派生量：环只画三项，拿四项的合计去算角度会永远对不上。
  int get conversationTokens => level2Tokens + level1Tokens + rawTokens;

  /// 三段在环上的排布：顺时针、起点 12 点，顺序固定为 二级 → 一级 → 原文。
  ///
  /// 每段 `sweep = tokens / windowTokens * 2π`；[windowTokens] <= 0（窗口未知）时返回空列表。
  List<RingSegment> get ringSegments {
    if (windowTokens <= 0) return const [];
    RingSegment seg(int tokens) => (
          tokens: tokens,
          sweepRadians: tokens / windowTokens * 2 * math.pi,
        );
    return [seg(level2Tokens), seg(level1Tokens), seg(rawTokens)];
  }

  /// 按 design D1 把一条投影时间线分成三段。
  ///
  /// [trailingRawMessages]：投影定下来之后才追加进这一轮请求的消息（工具轮里那些），
  /// 它们是 **API 格式的 map**（`apiMessages` 里那些），没有对应的投影段，一律计入原文。
  /// 按序列化后的长度用同一个估算器算 —— 不走 `Message` 回环转换，那会丢掉工具块。
  /// 不带上它们，最后一轮的快照与这份拆分描述的不是同一份请求（见 tasks 3.1）。
  static ContextBreakdown fromTimeline({
    required List<ProjectionPiece> timeline,
    required int windowTokens,
    required int fixedOverheadTokens,
    List<Map<String, dynamic>> trailingRawMessages = const [],
  }) {
    var level2 = 0;
    var level1 = 0;
    var raw = 0;
    for (final piece in timeline) {
      final summary = piece.summary;
      if (summary == null) {
        // 这一趟按原文发这一段（哪怕它已经被压成摘要）。
        raw += CompactionEngine.rawTokens(piece.segment.messages);
      } else if (piece.segment.level >= 2) {
        level2 += summary.tokens;
      } else {
        level1 += summary.tokens;
      }
    }
    if (trailingRawMessages.isNotEmpty) {
      raw += ContextEstimator.estimateTokens(jsonEncode(trailingRawMessages));
    }
    return ContextBreakdown(
      level2Tokens: level2,
      level1Tokens: level1,
      rawTokens: raw,
      fixedOverheadTokens: fixedOverheadTokens,
      windowTokens: windowTokens,
    );
  }

  /// 没有走压缩那两条路径时的退化形式：整条时间线只有一个按原文发的段。
  ///
  /// 复用 [fromTimeline]，不另写一套分类。
  static ContextBreakdown verbatim({
    required List<Message> messages,
    required int windowTokens,
    required int fixedOverheadTokens,
    List<Map<String, dynamic>> trailingRawMessages = const [],
  }) {
    return fromTimeline(
      timeline: [
        ProjectionPiece(
            segment: CompactionSegment(messages: messages, summary: false)),
      ],
      windowTokens: windowTokens,
      fixedOverheadTokens: fixedOverheadTokens,
      trailingRawMessages: trailingRawMessages,
    );
  }
}
