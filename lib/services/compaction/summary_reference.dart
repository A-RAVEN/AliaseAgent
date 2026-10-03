/// 参考上下文：喂给摘要模型的一小段"前文"，让它能解析本段里的指代、不必重述
/// 用户目标。它是**纯数据 + 一个纯函数**，所以挑选规则可以脱离模型单独测。
///
/// 硬约束（见 design 的第一条决定）：最多两条、只取覆盖范围严格早于本批的、
/// 按覆盖范围去重（较细那条被较粗那条完全盖住时只留较粗的）、不随会话变长。
class SummaryReference {
  /// 1 = 一级摘要，2 = 二级摘要（"层级最高"的那条通常是 2，但不保证）。
  final int level;

  /// 这条摘要覆盖的消息序号范围（用来让模型判断"这段参考是不是在我这一段之前"，
  /// 也是按覆盖范围去重的依据）。
  final int coveredMinSeq;
  final int coveredMaxSeq;

  /// 摘要正文（已经从 `summary_nodes.summary_json` 里取出的纯文本）。
  final String text;

  const SummaryReference({
    required this.level,
    required this.coveredMinSeq,
    required this.coveredMaxSeq,
    required this.text,
  });

  /// 序号范围是否完全盖住 [other]（含相等）。
  bool covers(SummaryReference other) =>
      coveredMinSeq <= other.coveredMinSeq && coveredMaxSeq >= other.coveredMaxSeq;
}

/// 从已落盘的摘要节点里挑出这次折叠的参考上下文。
///
/// [persisted] 是本会话已落盘的全部摘要节点（顺序无所谓），[batchOldestSeq] 是
/// **最外层那一批**的最旧消息序号（折半重压时两半用同一份参考、用同一个界）。
///
/// 规则：①候选必须 `coveredMaxSeq < batchOldestSeq`（覆盖范围与本次批次有交叠的
/// 一律排除 —— 例如本趟后半段才合成、还没进投影的二级摘要）；②取候选里最近的
/// 一条一级摘要；③再取候选里层级最高的一条（同级取覆盖最远的那条）；④两条若
/// 同一条，或较细那条被较粗那条完全盖住，只留较粗的那条；⑤输出按覆盖范围从旧
/// 到新排列。
List<SummaryReference> selectSummaryReferences({
  required List<SummaryReference> persisted,
  required int batchOldestSeq,
}) {
  final eligible = persisted.where((r) => r.coveredMaxSeq < batchOldestSeq).toList();
  if (eligible.isEmpty) return const [];

  SummaryReference? mostRecentLevel1;
  for (final r in eligible) {
    if (r.level != 1) continue;
    if (mostRecentLevel1 == null || r.coveredMaxSeq > mostRecentLevel1.coveredMaxSeq) {
      mostRecentLevel1 = r;
    }
  }

  SummaryReference coarsest = eligible.first;
  for (final r in eligible) {
    if (r.level > coarsest.level ||
        (r.level == coarsest.level && r.coveredMaxSeq > coarsest.coveredMaxSeq)) {
      coarsest = r;
    }
  }

  final picked = <SummaryReference>[];
  if (mostRecentLevel1 != null) picked.add(mostRecentLevel1);
  // 按覆盖范围去重：两条里若有一条盖住另一条，只留**更粗**的那条 —— 同一段历史
  // 不以两种文本进同一次请求（这也是用户"一级与二级不许有内容重复"那条规则的
  // 精神在参考块上的落法）。
  if (picked.any(coarsest.covers)) {
    picked.removeWhere(coarsest.covers);
    picked.add(coarsest);
  } else if (!picked.any((p) => p.covers(coarsest))) {
    picked.add(coarsest);
  }

  picked.sort((a, b) => a.coveredMaxSeq.compareTo(b.coveredMaxSeq));
  return picked;
}
