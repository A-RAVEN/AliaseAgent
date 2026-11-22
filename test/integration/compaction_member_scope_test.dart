// 压缩作用域是成员（change `agent-group-chat` 任务 4.4 / design D4）。
//
// 分层：这条用**真 sqlite**（临时库 `openAt`），所以按 `Docs/TESTING.md` §2.1 放在
// integration 层；unit 层只留纯函数（`memberScopedReferences`，见
// `test/unit/summary_reference_scope_test.dart`）。
//
// 这条用例打真实仓储（不碰用户目录）：同一 sessionId（"同一个句柄"）下两个成员的
// 摘要各成一行、互不顶替；单会话 NULL 分支同覆盖范围只留一行。它同时是「B 取不到
// A 的摘要」那条泄漏通道在存储层的判据（查询按作用域过滤）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/summary_node_repository.dart';

import 'group_test_support.dart';

void main() {
  late GroupTestSupport support;
  late SummaryNodeRepository repo;
  late String sessionId;

  setUp(() async {
    support = await GroupTestSupport.create(prefix: 'compaction_scope_test_');
    repo = support.summaryNodeRepo;
    final session = await support.sessionRepo.create(title: '组', kind: 'group');
    sessionId = session.id;
  });

  tearDown(() async {
    await support.dispose();
  });

  Future<void> put({
    required String? memberId,
    required String text,
    int lo = 1,
    int hi = 8,
  }) =>
      repo.materialize(
        sessionId: sessionId,
        memberId: memberId,
        level: 1,
        startSeq: lo,
        endSeq: hi,
        nodeType: 'summary',
        summaryJson: '{"role":"user","content":[{"type":"text","text":"$text"}]}',
        tokenCost: 4,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: lo,
        coveredMaxSeq: hi,
      );

  test('同一句柄两个成员各自的摘要不互相顶替', () async {
    await put(memberId: 'member-a', text: '甲的视图摘要 A-MARK');
    await put(memberId: 'member-b', text: '乙的视图摘要 B-MARK');

    final all = await repo.queryAllBySession(sessionId);
    final forA = await repo.queryBySession(sessionId, memberId: 'member-a');
    final forB = await repo.queryBySession(sessionId, memberId: 'member-b');
    // ignore: avoid_print
    print('[OBS] 全部=${all.map((n) => '${n.memberId}:${n.summaryJson}')}');
    // ignore: avoid_print
    print('[OBS] 甲=${forA.length} 乙=${forB.length}');

    expect(all.length, 2);
    expect(forA.single.summaryJson, contains('A-MARK'));
    expect(forA.single.summaryJson, isNot(contains('B-MARK')));
    expect(forB.single.summaryJson, contains('B-MARK'));
    expect(forB.single.summaryJson, isNot(contains('A-MARK')),
        reason: 'B 的查询永远看不到 A 的摘要（成员作用域）');

    // 组会话里不存在 member_id 为空的共享摘要行。
    expect(all.where((n) => n.memberId == null), isEmpty);
  });

  test('单会话 NULL 分支：同一覆盖范围重复 materialize 只留一行', () async {
    await put(memberId: null, text: '第一次');
    await put(memberId: null, text: '第二次');
    final rows = await repo.queryBySession(sessionId, memberId: null);
    // ignore: avoid_print
    print('[OBS] 单会话行=${rows.map((n) => n.summaryJson)}');
    expect(rows.length, 1);
    expect(rows.single.summaryJson, contains('第二次'));
    expect(await repo.findCovering(sessionId, 1, 8, memberId: null), isNotNull);
    expect(await repo.findCovering(sessionId, 1, 8, memberId: 'member-a'), isNull);
  });
}
