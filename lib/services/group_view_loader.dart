// 成员视图的增量装配与派生缓存（change `agent-group-chat` 任务 4.2 / 4.9 /
// design D9）。
//
// 三条硬约束（都有可失败用例）：
//   ① **不许全量查询**：装配只按 `seq > 高水位` 读新区间，绝不调用 `queryBySession`
//      （用例注入"全量查询即抛错"的仓库来证明）；
//   ② **被摘要覆盖的区间非常驻**：装配后的驻留视图只保留 `seq > coveredThrough` 的
//      项；压缩时需要那段内容就按 `seq` 区间**按需读回**（[fullViewForCompaction]）；
//   ③ **派生缓存跟随驻留视图**：解析缓存只在当前驻留视图的 seq 并集上保留条目，
//      行被摘要覆盖或离开视图即淘汰 —— 否则长会话的缓存会绕过"驻留由 T 界定"。
//
// 公开原文行的解析结果**跨成员复用**（行不可变，按 seq 缓存）：同一行在两个视图里
// 只解析一次；私有回放各成员一份（私有行不进公共缓存）。
import '../models/message.dart';
import 'group_view_projection.dart';
import 'message_repository.dart';

/// 按 `seq` 缓存**公开行**的解析结果（跨成员复用）。
class GroupRowParseCache {
  final Map<int, Message> _parsed = <int, Message>{};

  /// 解析次数（用例用它证明同一公开行只解析一次）。
  int parseCount = 0;

  Message parse(Map<String, dynamic> row) {
    parseCount++;
    return Message.fromRow(row);
  }

  /// 取缓存；没有就解析并放入。
  Message parseOrGet(Map<String, dynamic> row) {
    final seq = row['seq'] as int?;
    if (seq == null) return parse(row);
    final cached = _parsed[seq];
    if (cached != null) return cached;
    final message = parse(row);
    _parsed[seq] = message;
    return message;
  }

  Message? lookup(int seq) => _parsed[seq];

  /// 只保留这些 seq 的条目（派生缓存的生命周期跟随驻留视图）。
  void retain(Set<int> seqs) {
    _parsed.removeWhere((seq, _) => !seqs.contains(seq));
  }

  int get length => _parsed.length;
}

/// 一个组的成员视图装配器（每组成员共享一份 [GroupRowParseCache]）。
class GroupViewLoader {
  GroupViewLoader({
    required this.groupId,
    required this.messageRepo,
    GroupRowParseCache? cache,
  }) : cache = cache ?? GroupRowParseCache();

  final String groupId;
  final MessageRepository messageRepo;
  final GroupRowParseCache cache;

  /// 每个成员已装配到的高水位 `seq`（第二轮只读它之后的行）。
  final Map<String, int> _highWater = <String, int>{};

  /// 每个成员的驻留视图（未被摘要覆盖的可见项，按 seq 升序）。
  final Map<String, List<Message>> _resident = <String, List<Message>>{};

  /// 每次装配读到的 seq 区间（用例断言"第二轮只读高水位之后的行"）。
  final List<({String memberId, int afterSeq, int? maxSeq, int rows})> readRanges =
      [];

  int highWaterOf(String memberId) => _highWater[memberId] ?? 0;

  List<Message> residentView(String memberId) =>
      List<Message>.unmodifiable(_resident[memberId] ?? const <Message>[]);

  /// 驻留视图的 seq 并集（缓存淘汰与规模断言的判据）。
  Set<int> residentSeqs(String memberId) => {
        for (final message in _resident[memberId] ?? const <Message>[])
          if (message.seq != null) message.seq!,
      };

  /// 增量装配：读 `seq > 高水位` 的新行、投影、并入驻留视图。
  ///
  /// [coveredThrough] 是该成员摘要已覆盖到的最大 seq：装配后**丢弃** `seq <=
  /// coveredThrough` 的驻留项（它们已被摘要替代，不再常驻），并按新的驻留 seq 并集
  /// 淘汰缓存条目。
  Future<void> assemble({
    required String memberId,
    required Map<String, String> displayNames,
    required int coveredThrough,
  }) async {
    final after = highWaterOf(memberId);
    final rows = await messageRepo.queryRawAfterSeq(groupId, after);
    var maxSeq = after;
    final appended = <Message>[];
    for (final row in rows) {
      final seq = row['seq'] as int?;
      if (seq == null || seq <= after) continue;
      if (seq > maxSeq) maxSeq = seq;
      final mapped = _mapRow(
        row,
        memberId: memberId,
        displayNames: displayNames,
      );
      if (mapped != null) appended.add(mapped);
    }
    readRanges.add((
      memberId: memberId,
      afterSeq: after,
      maxSeq: maxSeq == after ? null : maxSeq,
      rows: rows.length,
    ));
    _highWater[memberId] = maxSeq;
    final merged = <Message>[
      ...?_resident[memberId],
      ...appended,
    ]..sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    _resident[memberId] = [
      for (final message in merged)
        if ((message.seq ?? 0) > coveredThrough) message,
    ];
    cache.retain(residentSeqs(memberId));
  }

  /// 压缩输入 = 驻留视图 + **按需读回**被成员摘要覆盖的区间（同一套投影规则）。
  ///
  /// 返回的列表是这次请求的临时快照，不改变驻留集。
  Future<List<Message>> fullViewForCompaction({
    required String memberId,
    required Map<String, String> displayNames,
    required List<({int min, int max})> coveredSpans,
  }) async {
    final pieces = <Message>[];
    for (final span in coveredSpans) {
      final rows =
          await messageRepo.queryRawInRange(groupId, span.min, span.max);
      for (final row in rows) {
        final mapped = _mapRow(
          row,
          memberId: memberId,
          displayNames: displayNames,
        );
        if (mapped != null) pieces.add(mapped);
      }
    }
    pieces.addAll(_resident[memberId] ?? const <Message>[]);
    pieces.sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
    // 同一 seq 只留一份（覆盖区间与驻留视图不应重叠，这里防御性去重）。
    final seen = <int>{};
    final out = <Message>[];
    for (final message in pieces) {
      final seq = message.seq ?? 0;
      if (!seen.add(seq)) continue;
      out.add(message);
    }
    return out;
  }

  /// 单行映射：他人私有行剔除、他人公开行合成 user 行、其余原样。
  ///
  /// 与 [GroupViewProjection.project] 是**同一条规则**（后者对整段调用本函数）；
  /// 公开行解析走共享缓存（同一行在两个成员视图里只解析一次）。
  Message? _mapRow(
    Map<String, dynamic> row, {
    required String memberId,
    required Map<String, String> displayNames,
  }) {
    final isGroupPublicRow = (row['visibility'] as String? ?? 'public') ==
        Message.visibilityPublic;
    if (isGroupPublicRow) {
      return GroupViewProjection.mapRowCached(
        row,
        memberId: memberId,
        displayNames: displayNames,
        parseOrGet: cache.parseOrGet,
      );
    }
    // 私有行只对作者可见；私有回放各成员各一份（不进公共缓存）。
    if ((row['author'] as String?) != memberId) return null;
    return cache.parse(row);
  }
}
