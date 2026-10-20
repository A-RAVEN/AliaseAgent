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
  ///
  /// **2026-10-18 加的限制：整圈不许被画过**。三段之和可以大于窗口（历史总量本来就可能
  /// 比窗口大 —— 压缩就是为了让它塞进窗口），那时按比例算出来的弧度会超过 2π、绕回去，
  /// 画出来的环会自我覆盖。所以按顺序累加、到整圈为止，超出的部分**不画**；
  /// 真实的 token 数仍原样留在 `tokens` 里（数字与面板都读它，不读弧度）。
  List<RingSegment> get ringSegments {
    if (windowTokens <= 0) return const [];
    const full = 2 * math.pi;
    var used = 0.0;
    final out = <RingSegment>[];
    for (final tokens in [level2Tokens, level1Tokens, rawTokens]) {
      var sweep = tokens / windowTokens * full;
      if (used + sweep > full) sweep = full - used;
      if (sweep < 0) sweep = 0;
      out.add((tokens: tokens, sweepRadians: sweep));
      used += sweep;
    }
    return out;
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

  /// 按**层级**直接构造（2026-10-18 新口径，tasks 12.2）。
  ///
  /// 与 [fromTimeline] 的区别是"量的是什么"：
  /// * [fromTimeline] 量的是**上一次实际发出去那份请求**的构成 —— 只有当二级摘要真进了这次
  ///   投影时，二级那一段才非零。而按 `CompactionEngine.substitutesSpan` 的判据（2 级要求
  ///   最旧端与最新端都超过 `2T`），二级在实际对话里几乎永远不进投影。
  /// * 这个工厂量的是**这段对话按层级划分的构成**：调用方按"每条消息取盖住它的最高层级"
  ///   把三层 token 累加好再传进来（见 `lib/main.dart` 里那处调用），三段之和＝这段对话的
  ///   token 总量，同一条消息不会被算两次。
  ///
  /// 用户原话（2026-10-18）：「我的要求是有原文，一级，二级摘要 3 瓣条的占用量」。
  static ContextBreakdown fromTiers({
    required int level2Tokens,
    required int level1Tokens,
    required int rawTokens,
    required int windowTokens,
    required int fixedOverheadTokens,
  }) {
    return ContextBreakdown(
      level2Tokens: level2Tokens,
      level1Tokens: level1Tokens,
      rawTokens: rawTokens,
      fixedOverheadTokens: fixedOverheadTokens,
      windowTokens: windowTokens,
    );
  }

  /// 按**层级**从整段历史算（2026-10-18 新口径，tasks 12.3）。
  ///
  /// 规则：对每条消息取**盖住它的最高层级**（[covers] 里 `minSeq..maxSeq` 命中的、`level`
  /// 最大的那条）；被二级盖的算二级、只被一级盖的算一级、都没盖的算原文。三段之和
  /// 就是这段对话的 token 总量 —— 同一条消息只进一个桶，不会重复计入。
  ///
  /// [extraRawTokens]：投影定下来之后才追加进这一轮请求的那些消息（工具轮），一律算原文。
  ///
  /// 提成纯函数是为了能单测：调用点在 `_sendMessage` 里、拿不到它的私有状态。
  static ContextBreakdown fromHistory({
    required List<Message> messages,
    required List<({int level, int minSeq, int maxSeq})> covers,
    required int windowTokens,
    required int fixedOverheadTokens,
    int extraRawTokens = 0,
  }) {
    var level2 = 0;
    var level1 = 0;
    var raw = 0;
    for (final m in messages) {
      final seq = m.seq ?? 0;
      var coveredBy = 0;
      for (final c in covers) {
        if (seq >= c.minSeq && seq <= c.maxSeq && c.level > coveredBy) {
          coveredBy = c.level;
        }
      }
      final t = ContextEstimator.estimateMessage(m);
      if (coveredBy >= 2) {
        level2 += t;
      } else if (coveredBy == 1) {
        level1 += t;
      } else {
        raw += t;
      }
    }
    return fromTiers(
      level2Tokens: level2,
      level1Tokens: level1,
      rawTokens: raw + extraRawTokens,
      windowTokens: windowTokens,
      fixedOverheadTokens: fixedOverheadTokens,
    );
  }

  /// 按**层级**从"各层表示自己的大小"算（2026-10-18 用户要求三瓣，tasks 12.3 的第二版）。
  ///
  /// **为什么不用"取最高层级"那版**：那一版在真机上跑出来 `level2=10859 level1=0`
  /// （一条大二级把所有折叠内容都盖住了 ⇒ 一级桶恒 0），而且总量可以大于窗口、环画过整圈。
  ///
  /// 这一版的口径是"每一层的表示各占多少"：
  /// * 二级 = 库里所有 `level == 2` 摘要的 `tokenCost` 之和；
  /// * 一级 = 库里所有 `level == 1` 摘要的 `tokenCost` 之和；
  /// * 原文 = **没有被任何摘要覆盖**的那些消息的估算之和（含 [extraRawTokens]）。
  ///
  /// 注意三段之和**不等于**上下文大小（二级盖住的一级仍各自计一次）—— 环显示的是
  /// "各层表示的成本"，这一点写在 spec 里。
  static ContextBreakdown fromSummaries({
    required List<Message> messages,
    required List<({int level, int minSeq, int maxSeq, int tokenCost})> summaries,
    required int windowTokens,
    required int fixedOverheadTokens,
    int extraRawTokens = 0,
  }) {
    var level2 = 0;
    var level1 = 0;
    for (final s in summaries) {
      if (s.level >= 2) {
        level2 += s.tokenCost;
      } else if (s.level == 1) {
        level1 += s.tokenCost;
      }
    }
    var raw = extraRawTokens;
    for (final m in messages) {
      final seq = m.seq ?? 0;
      final covered = summaries.any((s) => seq >= s.minSeq && seq <= s.maxSeq);
      if (!covered) raw += ContextEstimator.estimateMessage(m);
    }
    return fromTiers(
      level2Tokens: level2,
      level1Tokens: level1,
      rawTokens: raw,
      windowTokens: windowTokens,
      fixedOverheadTokens: fixedOverheadTokens,
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
