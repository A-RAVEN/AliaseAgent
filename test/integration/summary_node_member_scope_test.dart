// `summary_nodes.member_id` 与成员作用域（change `agent-group-chat` 任务 1.5 /
// design D4、D14、D20）。
//
// 三条必须在真库上证明的行为：
//   ① 同一 span 两个成员各一行、互不删除（逐视图存储）；
//   ② 单会话 NULL 分支：materialize 后同覆盖范围只有一行 —— 把空作用域写成
//      `= NULL` 匹配不到，重复行随之出现，这条用例必须变红；
//   ③ findCovering 带成员参数、跨成员不命中。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/summary_node_repository.dart';

import 'group_test_support.dart';

void main() {
  late GroupTestSupport support;
  late SummaryNodeRepository nodes;
  late String sessionId;

  setUp(() async {
    support = await GroupTestSupport.create(prefix: 'summary_scope_test_');
    nodes = support.summaryNodeRepo;
    final session = await support.sessionRepo.create(title: '组', kind: 'group');
    sessionId = session.id;
  });

  tearDown(() async {
    await support.dispose();
  });

  Future<void> materialize({
    required String? memberId,
    required String text,
    int lo = 1,
    int hi = 10,
    int level = 1,
  }) =>
      nodes.materialize(
        sessionId: sessionId,
        memberId: memberId,
        level: level,
        startSeq: lo,
        endSeq: hi,
        nodeType: 'summary',
        summaryJson: '{"role":"user","content":[{"type":"text","text":"$text"}]}',
        tokenCost: 5,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: lo,
        coveredMaxSeq: hi,
      );

  group('summary_nodes 的成员作用域', () {
    test('同一 span 两成员各一行、互不删除', () async {
      await materialize(memberId: 'member-a', text: '甲的摘要');
      await materialize(memberId: 'member-b', text: '乙的摘要');

      final all = await nodes.queryAllBySession(sessionId);
      final a = await nodes.queryBySession(sessionId, memberId: 'member-a');
      final b = await nodes.queryBySession(sessionId, memberId: 'member-b');
      // ignore: avoid_print
      print('[OBS] 全部=${all.length} 甲=${a.length} 乙=${b.length} '
          '甲文本=${a.map((n) => n.memberId)} 乙文本=${b.map((n) => n.memberId)}');

      expect(all.length, 2, reason: '两个成员的同一 span 必须两行共存');
      expect(a.length, 1);
      expect(b.length, 1);
      expect(a.single.memberId, 'member-a');
      expect(b.single.memberId, 'member-b');
      expect(a.single.summaryJson, contains('甲的摘要'));
      expect(b.single.summaryJson, contains('乙的摘要'),
          reason: '后写入的一行不得删除另一成员的行');
    });

    test('单会话 NULL 分支：materialize 后同覆盖范围只有一行（写 = NULL 必红）', () async {
      // 同覆盖范围、同层级重复 materialize（dirty-seq 重算会走这条路）。
      await materialize(memberId: null, text: '第一次');
      await materialize(memberId: null, text: '第二次');

      final all = await nodes.queryAllBySession(sessionId);
      final nullScope = await nodes.queryBySession(sessionId, memberId: null);
      // ignore: avoid_print
      print('[OBS] 单会话 NULL 作用域行数=${all.length} '
          '文本=${all.map((n) => n.summaryJson)}');

      expect(all.length, 1,
          reason: '单会话（member_id IS NULL）的 delete-before-insert 必须命中：'
              '若 WHERE 写成 member_id = NULL 就匹配不到，会留下重复行');
      expect(nullScope.length, 1);
      expect(all.single.summaryJson, contains('第二次'),
          reason: '留下的必须是新写入的那一行（findCovering 要拿到 freshest）');

      // 组会话的成员行不会被单会话的 materialize 删掉。
      await materialize(memberId: 'member-a', text: '甲的摘要');
      await materialize(memberId: null, text: '第三次');
      final afterMixed = await nodes.queryAllBySession(sessionId);
      // ignore: avoid_print
      print('[OBS] 混合作用域后行数=${afterMixed.length} '
          '作用域=${afterMixed.map((n) => n.memberId)}');
      expect(afterMixed.length, 2,
          reason: '单会话的 delete-before-insert 不得删掉成员作用域的摘要');
    });

    test('findCovering 带成员参数，跨成员不命中', () async {
      await materialize(memberId: 'member-a', text: '甲的摘要');
      final byA = await nodes.findCovering(sessionId, 1, 10, memberId: 'member-a');
      final byB = await nodes.findCovering(sessionId, 1, 10, memberId: 'member-b');
      final byNull =
          await nodes.findCovering(sessionId, 1, 10, memberId: null);
      // ignore: avoid_print
      print('[OBS] findCovering 甲=${byA?.memberId} 乙=${byB?.memberId} '
          '单会话=${byNull?.memberId}');

      expect(byA?.memberId, 'member-a');
      expect(byB, isNull, reason: '查乙不能命中甲的摘要');
      expect(byNull, isNull, reason: '单会话作用域不能命中成员的摘要');
    });
  });
}
