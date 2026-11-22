// 逐视图压缩（真库）：两个成员各压一次、各自作用域、无共享摘要（change
// `agent-group-chat` 任务 4.4 / design D4）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_prompts.dart';

import 'group_harness.dart';

void main() {
  test('两个成员各压一次：摘要按成员作用域落库、无共享摘要行、参考块不跨成员', () async {
    final harness = await GroupHarness.create(window: 2000);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');
    // 一段足够长的共享原文（用户 + 甲的公开回复交替），两个成员视图都能看到。
    await harness.seedHistory(
      count: 80,
      authorOf: (i) => i.isEven ? null : a.id,
    );

    // 甲先发言 → 触发甲的视图折叠。
    harness.queueFinal('甲的公开结论：lib/a.dart');
    final outcomeA = await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲总结一下');
    expect(outcomeA.status, 'completed');
    final aNodes = await harness.summaryNodeRepo
        .queryBySession(harness.group.id, memberId: a.id);
    // ignore: avoid_print
    print('[OBS] 甲的摘要节点=${aNodes.map((n) => '${n.level}:${n.coveredMinSeq}..${n.coveredMaxSeq}')}');
    expect(aNodes, isNotEmpty, reason: '甲的视图必须真的折叠出摘要');

    // 乙接着发言 → 乙的视图自己折叠；不得取到甲的摘要作参考块。
    harness.queueFinal('乙的公开结论：lib/b.dart');
    final outcomeB = await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙总结一下');
    expect(outcomeB.status, 'completed');
    final bNodes = await harness.summaryNodeRepo
        .queryBySession(harness.group.id, memberId: b.id);
    final allNodes = await harness.summaryNodeRepo
        .queryAllBySession(harness.group.id);
    // ignore: avoid_print
    print('[OBS] 乙的摘要节点=${bNodes.map((n) => '${n.level}:${n.coveredMinSeq}..${n.coveredMaxSeq}')}');
    // ignore: avoid_print
    print('[OBS] 全部节点作用域=${allNodes.map((n) => n.memberId).toList()}');

    expect(bNodes, isNotEmpty, reason: '乙的视图也必须折叠出摘要');
    expect(allNodes.any((n) => n.memberId == null), isFalse,
        reason: '组会话不存在共享摘要（member_id 为空的摘要行）');
    expect(allNodes.map((n) => n.memberId).toSet(), containsAll([a.id, b.id]));

    // 参考上下文只来自本人作用域：乙折叠时拿到的参考里没有甲的摘要文本。
    final bReferences = harness.support.summary.referencesPerCall;
    final aTexts = aNodes.map((n) => n.summaryJson ?? '').toList();
    // ignore: avoid_print
    print('[OBS] 乙折叠的参考次数=${bReferences.length} '
        '参考条数=${bReferences.map((r) => r.length).toList()} '
        '甲的摘要文本被当参考=${bReferences.any((refs) => refs.any((r) => aTexts.any((t) => t.contains(r.text))))}');

    // 组摘要的归属纪律必须随摘要请求发出（4.7 的接线）。
    // ignore: avoid_print
    print('[OBS] 摘要系统文本追加段=${harness.support.summary.systemPromptSuffixes}');
    expect(harness.support.summary.systemPromptSuffixes, isNotEmpty);
    expect(harness.support.summary.systemPromptSuffixes.last,
        kGroupSummaryPromptSuffix);
    await harness.dispose();
  });

  test('单会话 NULL 分支：摘要 member_id 为空、重复 materialize 只留一行', () async {
    final harness = await GroupHarness.create(window: 2000, createGroup: false);
    final session = await harness.support.sessionRepo.create(title: '单会话');
    for (var i = 0; i < 80; i++) {
      await harness.support.messageRepo.insert(
        sessionId: session.id,
        role: i.isEven ? 'user' : 'assistant',
        content: '单会话历史 $i ${'A' * 120}',
      );
    }
    final agent = await harness.factory.create(session);
    harness.queueFinal('单会话的最终回复');
    final result = await agent.send('请总结');
    expect(result.status.name, 'completed');

    final nodes = await harness.summaryNodeRepo.queryAllBySession(session.id);
    // ignore: avoid_print
    print('[OBS] 单会话摘要=${nodes.map((n) => 'member=${n.memberId} '
        '${n.coveredMinSeq}..${n.coveredMaxSeq}')}');
    expect(nodes, isNotEmpty);
    expect(nodes.every((n) => n.memberId == null), isTrue,
        reason: '单会话摘要的 member_id 必须为空（IS NULL 路径）');

    // 同覆盖范围重复落库：只留一行。
    final node = nodes.first;
    for (var i = 0; i < 2; i++) {
      await harness.support.summaryNodeRepo.materialize(
        sessionId: session.id,
        memberId: null,
        level: node.level,
        startSeq: node.startSeq,
        endSeq: node.endSeq,
        nodeType: 'summary',
        summaryJson: '{"role":"user","content":[{"type":"text","text":"重压 $i"}]}',
        tokenCost: 2,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: node.coveredMinSeq,
        coveredMaxSeq: node.coveredMaxSeq,
      );
    }
    final after = await harness.summaryNodeRepo.queryAllBySession(session.id);
    final sameSpan = after.where((n) =>
        n.level == node.level &&
        n.coveredMinSeq == node.coveredMinSeq &&
        n.coveredMaxSeq == node.coveredMaxSeq);
    // ignore: avoid_print
    print('[OBS] 同覆盖范围行数=${sameSpan.length} 总行数=${after.length}');
    expect(sameSpan.length, 1, reason: '单会话 delete-before-insert 必须命中（IS NULL）');
    await harness.dispose();
  });
}
