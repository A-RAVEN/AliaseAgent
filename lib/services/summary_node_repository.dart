import '../models/summary_node.dart';
import 'database_service.dart';

/// Persists the compaction tree (summary_nodes) and the per-session tree_version.
///
/// All writes that logically form one materialization (insert summary node +
/// bump tree_version) are executed in a single transaction so the tree never
/// half-updates (spec: "Background folding lifecycle — persist in a transaction").
class SummaryNodeRepository {
  /// Insert a summary node and return it with its DB id. Sets tree_version bump
  /// to the caller (or use [materialize] for the atomic paired write).
  Future<SummaryNode> insert(SummaryNode node) async {
    final db = await DatabaseService.database;
    final id = await db.insert('summary_nodes', node.toRow());
    return SummaryNode(
      id: id,
      sessionId: node.sessionId,
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
  Future<SummaryNode> materialize({
    required String sessionId,
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
    SummaryNode? inserted;
    await db.transaction((txn) async {
      // UPSERT: a covered span must have EXACTLY ONE current row (D9 dense
      // non-overlap). Delete any prior row covering the same (covered_min_seq,
      // covered_max_seq) before inserting, so re-materialization (dirty-seq
      // recompute) never accumulates duplicate spans and findCovering returns the
      // freshest, not the oldest. (R0-H-BUG — minimal defensive contract.)
      await txn.delete(
        'summary_nodes',
        where: 'session_id = ? AND covered_min_seq = ? AND covered_max_seq = ?',
        whereArgs: [sessionId, coveredMinSeq, coveredMaxSeq],
      );
      final row = <String, dynamic>{
        'session_id': sessionId,
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

  Future<List<SummaryNode>> queryBySession(String sessionId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'summary_nodes',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'level ASC, start_seq ASC',
    );
    return rows.map(SummaryNode.fromRow).toList();
  }

  /// Find a summary node covering exactly the [startSeq, endSeq] span (leaf
  /// coverage), if one exists.
  Future<SummaryNode?> findCovering(String sessionId, int startSeq, int endSeq) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'summary_nodes',
      where: 'session_id = ? AND covered_min_seq = ? AND covered_max_seq = ?',
      whereArgs: [sessionId, startSeq, endSeq],
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
