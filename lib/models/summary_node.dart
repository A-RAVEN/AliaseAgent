/// A node in the compaction tree, persisted in the `summary_nodes` table. It is
/// a *derived index* over the messages table — the original conversation is
/// never deleted or overwritten by compaction.
///
/// Keyed by (session_id, member_id, level, start_seq, end_seq) for span queries;
/// coverage is tracked via covered_min_seq/covered_max_seq (dense,
/// non-overlapping **per (session, member) scope**).
///
/// [memberId] 是成员作用域（change `agent-group-chat`）：单 Agent 会话为 NULL，
/// 组会话按成员的投影视图各存一条 —— 同一 span 两个成员各一行、互不覆盖。
class SummaryNode {
  final int id; // DB autoincrement id
  final String sessionId;

  /// 成员作用域：null = 单 Agent 会话（既有的 `IS NULL` 路径）。
  final String? memberId;
  final int level;
  final int startSeq;
  final int endSeq;
  final String nodeType; // 'summary' | 'leaf' | 'root'
  final int? parentId;
  final String? summaryJson; // role blocks (for summaries)
  final int? tokenCost;
  final int? summaryPromptVersion;
  final String? model;
  final int coveredMinSeq;
  final int coveredMaxSeq;

  const SummaryNode({
    required this.id,
    required this.sessionId,
    this.memberId,
    required this.level,
    required this.startSeq,
    required this.endSeq,
    required this.nodeType,
    this.parentId,
    this.summaryJson,
    this.tokenCost,
    this.summaryPromptVersion,
    this.model,
    required this.coveredMinSeq,
    required this.coveredMaxSeq,
  });

  factory SummaryNode.fromRow(Map<String, dynamic> row) {
    return SummaryNode(
      id: row['id'] as int,
      sessionId: row['session_id'] as String,
      memberId: row['member_id'] as String?,
      level: row['level'] as int,
      startSeq: row['start_seq'] as int,
      endSeq: row['end_seq'] as int,
      nodeType: row['node_type'] as String,
      parentId: row['parent_id'] as int?,
      summaryJson: row['summary_json'] as String?,
      tokenCost: row['token_cost'] as int?,
      summaryPromptVersion: row['summary_prompt_version'] as int?,
      model: row['model'] as String?,
      coveredMinSeq: row['covered_min_seq'] as int,
      coveredMaxSeq: row['covered_max_seq'] as int,
    );
  }

  Map<String, dynamic> toRow() => {
        'session_id': sessionId,
        'member_id': memberId,
        'level': level,
        'start_seq': startSeq,
        'end_seq': endSeq,
        'node_type': nodeType,
        'parent_id': parentId,
        'summary_json': summaryJson,
        'token_cost': tokenCost,
        'summary_prompt_version': summaryPromptVersion,
        'model': model,
        'covered_min_seq': coveredMinSeq,
        'covered_max_seq': coveredMaxSeq,
      };
}
