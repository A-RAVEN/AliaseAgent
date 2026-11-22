// 压缩输入换成视图序列（change `agent-group-chat` 任务 4.5 / design D4）。
//
// 四条用例：
//   ① 折叠输入是**该成员的视图**（不含其他成员的私有行）；
//   ② 摘要锚定**原始 seq**（视图剔除中间行时区间不漂移）；
//   ③ 两个成员各一条摘要（逐视图）；
//   ④ 不存在共享摘要行（组会话没有 member_id 为空的摘要）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_view_projection.dart';

import 'group_harness.dart';

void main() {
  test('折叠输入是视图、摘要锚定原始 seq、两成员各一条、无共享摘要', () async {
    final harness = await GroupHarness.create(window: 2000);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');

    // 80 条共享原文（用户 / 甲的公开回复交替）+ 两个成员的私有证据行。
    await harness.seedHistory(
      count: 80,
      authorOf: (i) => i.isEven ? null : a.id,
    );
    await harness.seedPrivateRow(memberId: a.id, marker: 'A-PRIV');
    await harness.seedPrivateRow(memberId: b.id, marker: 'B-PRIV');
    final rawRows = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final aView = GroupViewProjection.project(
      raw: rawRows,
      memberId: a.id,
      displayNames: {a.id: '甲', b.id: '乙'},
    );
    final aViewSeqs = aView.residentSeqs;

    // 甲发言 ⇒ 甲的视图折叠。
    harness.queueFinal('甲的公开结论');
    final outcomeA = await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲先说');
    expect(outcomeA.status, 'completed');

    // ① 折叠输入是视图：不含乙的私有标记，也不含乙的原文私有行对象。
    final foldedA = harness.support.summary.lastFolded ?? const [];
    final foldedText = foldedA.map((m) => '${m.content}${m.thinkingJson ?? ''}').join('|');
    // ignore: avoid_print
    print('[OBS] 甲折叠输入条数=${foldedA.length} '
        '含 B-PRIV=${foldedText.contains('B-PRIV')} '
        '含 A-PRIV=${foldedText.contains('A-PRIV')}');
    expect(foldedA, isNotEmpty);
    expect(foldedText, isNot(contains('B-PRIV')),
        reason: '甲的折叠输入不得含乙的私有行');

    // ② 摘要锚定原始 seq。
    final aNodes = await harness.summaryNodeRepo
        .queryBySession(harness.group.id, memberId: a.id);
    // ignore: avoid_print
    print('[OBS] 甲的摘要=${aNodes.map((n) => '${n.startSeq}..${n.endSeq} '
        '(covered ${n.coveredMinSeq}..${n.coveredMaxSeq})')}');
    expect(aNodes, isNotEmpty);
    for (final node in aNodes) {
      expect(node.coveredMinSeq, node.startSeq);
      expect(node.coveredMaxSeq, node.endSeq);
      expect(aViewSeqs, contains(node.coveredMinSeq),
          reason: '区间起点必须是甲视图里的原始 seq（不漂移到别人的行）');
      expect(aViewSeqs, contains(node.coveredMaxSeq));
    }

    // ③ 乙发言 ⇒ 乙也折叠出自己的一条摘要。
    harness.queueFinal('乙的公开结论');
    final outcomeB = await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙再说');
    expect(outcomeB.status, 'completed');
    final bNodes = await harness.summaryNodeRepo
        .queryBySession(harness.group.id, memberId: b.id);
    final allNodes = await harness.summaryNodeRepo
        .queryAllBySession(harness.group.id);
    // ignore: avoid_print
    print('[OBS] 乙的摘要条数=${bNodes.length} '
        '全部作用域=${allNodes.map((n) => n.memberId).toSet()}');

    expect(bNodes, isNotEmpty);
    // ④ 无共享摘要行。
    expect(allNodes.any((n) => n.memberId == null), isFalse);
    expect(allNodes.map((n) => n.memberId).toSet(), containsAll([a.id, b.id]));
    // 同一段原文在两个视图里各有一条摘要（可能区间相同），两条互不覆盖。
    expect(allNodes.length, greaterThanOrEqualTo(2));
    await harness.dispose();
  });
}
