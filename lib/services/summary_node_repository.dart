import '../models/summary_node.dart';
import 'database_service.dart';

/// Persists the compaction tree (summary_nodes) and the per-session tree_version.
///
/// All writes that logically form one materialization (insert summary node +
/// bump tree_version) are executed in a single transaction so the tree never
/// half-updates (spec: "Background folding lifecycle — persist in a transaction").
class SummaryNodeRepository {
  /// 成员作用域的 SQL 片段与参数。
  ///
  /// `null`（单 Agent 会话）**必须**写成 `member_id IS NULL`：`= NULL` 在 SQL 里
  /// 匹配不到任何行，delete-before-insert 会失效、覆盖范围查询也拿不到旧节点
  /// （spec「单 agent 会话按 IS NULL 匹配」就是这么钉的）。
  static ({String sql, List<Object?> args}) _memberScope(String? memberId) =>
      memberId == null
          ? (sql: 'member_id IS NULL', args: const [])
          : (sql: 'member_id = ?', args: [memberId]);

  /// Insert a summary node and return it with its DB id. Sets tree_version bump
  /// to the caller (or use [materialize] for the atomic paired write).
  Future<SummaryNode> insert(SummaryNode node) async {
    final db = await DatabaseService.database;
    final id = await db.insert('summary_nodes', node.toRow());
    return SummaryNode(
      id: id,
      sessionId: node.sessionId,
      memberId: node.memberId,
      level: node.level,
      startSeq: node.startSeq,
      endSeq: node.endSeq,
      nodeType: node.nodeType,
      parentId: node.parentId,
      summaryJson: node.summaryJson,
      tokenCost: node.tokenCost,
      summaryPromptVersion: node.summaryPromptVersion,
      model: node.model,
      coveredMinSeq: node.coveredMinSeq,
      coveredMaxSeq: node.coveredMaxSeq,
    );
  }

  /// Atomic materialization: insert the summary node AND bump tree_version in a
  /// single transaction.
  ///
  /// [memberId] 是成员作用域：单 Agent 会话为 null（按 `IS NULL` 匹配），组成员
  /// 传入成员 id。delete-before-insert 与写入都带同一作用域 —— 一个成员的
  /// materialize 永不删另一个成员的节点。
  Future<SummaryNode> materialize({
    required String sessionId,
    String? memberId,
    required int level,
    required int startSeq,
    required int endSeq,
    required String nodeType,
    int? parentId,
    String? summaryJson,
    int? tokenCost,
    int? summaryPromptVersion,
    String? model,
    required int coveredMinSeq,
    required int coveredMaxSeq,
  }) async {
    final db = await DatabaseService.database;
    final scope = _memberScope(memberId);
    SummaryNode? inserted;
    await db.transaction((txn) async {
      // UPSERT: a covered span must have EXACTLY ONE current row (D9 dense
      // non-overlap). Delete any prior row covering the same
      // (level, covered_min_seq, covered_max_seq) **in this member scope** before
      // inserting, so re-materialization (dirty-seq recompute) never accumulates
      // duplicate spans and findCovering returns the freshest, not the oldest.
      // (R0-H-BUG — load-bearing: this delete-before-insert IS the operative
      // guarantee of covered dense non-overlap, since the table has NO UNIQUE
      // constraint on covered_min/max_seq. It is a documented real-bug fix, not a
      // defensive nicety.) `level` is included so a level-2 node never deletes a
      // level-1 node that shares the same covered span (see task 4.1 level-key
      // note). `memberId` is included so two members' nodes for the same span and
      // level coexist (agent-group-chat D4).
      await txn.delete(
        'summary_nodes',
        where: 'session_id = ? AND ${scope.sql} AND level = ? '
            'AND covered_min_seq = ? AND covered_max_seq = ?',
        whereArgs: [
          sessionId,
          ...scope.args,
          level,
          coveredMinSeq,
          coveredMaxSeq,
        ],
      );
      final row = <String, dynamic>{
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
      final id = await txn.insert('summary_nodes', row);
      await txn.rawUpdate(
        'UPDATE sessions SET tree_version = tree_version + 1 WHERE id = ?',
        [sessionId],
      );
      inserted = SummaryNode(
        id: id,
        sessionId: sessionId,
        memberId: memberId,
        level: level,
        startSeq: startSeq,
        endSeq: endSeq,
        nodeType: nodeType,
        parentId: parentId,
        summaryJson: summaryJson,
        tokenCost: tokenCost,
        summaryPromptVersion: summaryPromptVersion,
        model: model,
        coveredMinSeq: coveredMinSeq,
        coveredMaxSeq: coveredMaxSeq,
      );
    });
    return inserted!;
  }

  /// 某会话**全部作用域**的摘要节点（诊断 / 审计用：例如证明组会话里没有
  /// `member_id` 为空的共享摘要行）。运行时的读路径一律走带作用域的
  /// [queryBySession]，不读全部。
  Future<List<SummaryNode>> queryAllBySession(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'summary_nodes',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'level ASC, start_seq ASC',
    );
    return rows.map(SummaryNode.fromRow).toList();
  }

  /// 某会话在**某个成员作用域**里的全部摘要节点。
  ///
  /// [memberId] 为 null = 单 Agent 会话（`member_id IS NULL`）。
  Future<List<SummaryNode>> queryBySession(String sessionId,
      {String? memberId}) async {
    final db = await DatabaseService.database;
    final scope = _memberScope(memberId);
    final rows = await db.query(
      'summary_nodes',
      where: 'session_id = ? AND ${scope.sql}',
      whereArgs: [sessionId, ...scope.args],
      orderBy: 'level ASC, start_seq ASC',
    );
    return rows.map(SummaryNode.fromRow).toList();
  }

  /// Find a summary node covering exactly the [startSeq, endSeq] span (leaf
  /// coverage), if one exists **in this member scope**. Pass [level] to
  /// disambiguate when a level-2 node shares a (covered_min, covered_max) span
  /// with a subsumed level-1 node (task 4.1 level-key note).
  Future<SummaryNode?> findCovering(
      String sessionId, int startSeq, int endSeq,
      {int? level, String? memberId}) async {
    final db = await DatabaseService.database;
    final scope = _memberScope(memberId);
    final rows = await db.query(
      'summary_nodes',
      where: 'session_id = ? AND ${scope.sql} '
          'AND covered_min_seq = ? AND covered_max_seq = ?'
          '${level != null ? ' AND level = ?' : ''}',
      whereArgs: [
        sessionId,
        ...scope.args,
        startSeq,
        endSeq,
        ?level,
      ],
      orderBy: 'level DESC', // coarsest (highest level) wins if level not specified
      limit: 1,
    );
    return rows.isEmpty ? null : SummaryNode.fromRow(rows.first);
  }

  /// Read the per-session tree_version materialization counter (bumped on each
  /// materialize; used as a monotonic version, not a staleness signal).
  Future<int> treeVersion(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'sessions',
      columns: ['tree_version'],
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['tree_version'] as int?) ?? 0;
  }

  /// Increment the per-session tree_version counter.
  ///
  /// In the current design tree_version is a MATERIALIZATION counter (also
  /// bumped inside [materialize]'s transaction) — it does NOT drive staleness.
  /// Leaf-mutation staleness is tracked by [markDirty]/dirty_since_seq and
  /// consumed by the reuse-gate in _resolveSummaries. This standalone method
  /// remains for callers/tests that want to force a counter bump.
  Future<void> bumpTreeVersion(String sessionId) async {
    final db = await DatabaseService.database;
    await db.rawUpdate(
      'UPDATE sessions SET tree_version = tree_version + 1 WHERE id = ?',
      [sessionId],
    );
  }

  /// Low watermark (min changed seq) of a session's compaction tree. 0 = clean
  /// (no leaf mutation since the last materialization pass). Summaries whose
  /// covered span reaches the dirty region (coveredMaxSeq >= dirtySinceSeq) are
  /// stale and must be re-summarized; spans strictly below it are reusable.
  Future<int> dirtySinceSeq(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'sessions',
      columns: ['dirty_since_seq'],
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['dirty_since_seq'] as int?) ?? 0;
  }

  /// Record a leaf-level mutation at [seq] as dirty: lower the per-session
  /// watermark to min(prev, seq). Called from updateToolCalls (the sole
  /// leaf-level content mutation) so the next materialization recomputes any
  /// cached summary that covers the touched span instead of reusing stale text.
  Future<void> markDirty(String sessionId, int seq) async {
    final db = await DatabaseService.database;
    // 0 is the "clean / unset" sentinel (real seqs are rowids >= 1), so the
    // watermark is the MIN only once set; a clean session takes the first seq.
    // Otherwise MIN(0, seq) would wrongly stay "clean" forever.
    await db.rawUpdate(
      'UPDATE sessions SET dirty_since_seq = '
      'CASE WHEN dirty_since_seq = 0 OR dirty_since_seq > ? THEN ? ELSE dirty_since_seq END '
      'WHERE id = ?',
      [seq, seq, sessionId],
    );
  }

  /// Reset the session watermark to clean (0) after a full materialization pass
  /// has re-summarized every stale span in the fold plan.
  Future<void> clearDirty(String sessionId) async {
    final db = await DatabaseService.database;
    await db.rawUpdate(
      'UPDATE sessions SET dirty_since_seq = 0 WHERE id = ?',
      [sessionId],
    );
  }
}
