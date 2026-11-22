// 参考上下文的成员作用域（change `agent-group-chat` 任务 4.4 / design D19）。
//
// 这是本 change 新增的泄漏通道：B 折叠时若把 A 的摘要当参考块，A 的私有内容就进了
// B 的模型输入。作用域有两层 —— 查询层按 `member_id` 过滤，纯函数层再按同一规则
// 过一遍。这里打**纯函数层**：A 的摘要对 B 不可见，单会话只留作用域为空的条目。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/compaction/summary_reference.dart';

void main() {
  const aRef = SummaryReference(
      level: 1, coveredMinSeq: 1, coveredMaxSeq: 10, text: '甲的私有摘要 A-MARK');
  const bRef = SummaryReference(
      level: 1, coveredMinSeq: 1, coveredMaxSeq: 10, text: '乙的摘要 B-MARK');
  const singleRef = SummaryReference(
      level: 1, coveredMinSeq: 1, coveredMaxSeq: 10, text: '单会话摘要 S-MARK');

  test('候选集只含本人作用域：B 永远取不到 A 的摘要', () {
    final persisted = <({String? memberId, SummaryReference reference})>[
      (memberId: 'member-a', reference: aRef),
      (memberId: 'member-b', reference: bRef),
      (memberId: null, reference: singleRef),
    ];
    final forB = memberScopedReferences(persisted, memberId: 'member-b');
    final forA = memberScopedReferences(persisted, memberId: 'member-a');
    final forSingle = memberScopedReferences(persisted, memberId: null);
    // ignore: avoid_print
    print('[OBS] B 的候选=${forB.map((r) => r.text)} '
        'A 的候选=${forA.map((r) => r.text)} '
        '单会话候选=${forSingle.map((r) => r.text)}');

    expect(forB.map((r) => r.text), ['乙的摘要 B-MARK']);
    expect(forB.any((r) => r.text.contains('A-MARK')), isFalse,
        reason: '甲的作用域摘要不得成为乙的参考块');
    expect(forA.map((r) => r.text), ['甲的私有摘要 A-MARK']);
    expect(forSingle.map((r) => r.text), ['单会话摘要 S-MARK'],
        reason: '单会话只留作用域为空的条目（IS NULL 路径）');
  });

  test('空候选 ⇒ 空结果（首次折叠的请求不带参考块，行为不变）', () {
    expect(memberScopedReferences(const [], memberId: 'member-b'), isEmpty);
    expect(
        memberScopedReferences(
            [(memberId: 'member-a', reference: aRef)],
            memberId: 'member-b'),
        isEmpty);
  });

  test('过滤后再走既有的挑选规则：仍然最多两条、只取更早的', () {
    final scopedB = memberScopedReferences([
      (memberId: 'member-b', reference: bRef),
      (memberId: 'member-a', reference: aRef),
    ], memberId: 'member-b');
    final selected = selectSummaryReferences(
        persisted: scopedB, batchOldestSeq: 100);
    // ignore: avoid_print
    print('[OBS] 挑选结果=${selected.map((r) => r.text)}');
    expect(selected.length, 1);
    expect(selected.single.text, contains('B-MARK'));
  });
}
