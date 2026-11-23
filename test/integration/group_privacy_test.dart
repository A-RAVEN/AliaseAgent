// 隐私硬边界（change `agent-group-chat` 任务 6.1 / design D12）。
//
// **以输入通道为主判据**：摘要请求实际收到的 folded 文本与参考块、投影产出的
// messages、快照的 toRawJson。摘要模型输出只作附加证据（假 provider 固定文本会让
// "断言输出"假绿）。
//
// 四条用例：
//   ① B 的视图 messages 不含 A 的标记；
//   ② B 的快照（toRawJson）不含 A 的标记；
//   ③ B 的摘要请求输入（folded + 参考块）不含 A 的标记；
//   ④ 反证：A 自己的视图里标记仍然存在（防止"两边都丢"也过）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/event_serialization.dart';
import 'package:alias_agent/services/api_message_builder.dart';
import 'package:alias_agent/services/group_view_projection.dart';

import 'group_harness.dart';

const String kOldPrivMark = 'A-OLD-PRIV-MARK-31ac';
const String kNewPrivMark = 'A-NEW-PRIV-MARK-77bd';

void main() {
  test('A 的私有标记不进 B 的视图/快照/摘要输入；A 自己的视图里仍在', () async {
    final harness = await GroupHarness.create(window: 2000);
    final a = await harness.addMember('甲');
    final b = await harness.addMember('乙');

    // 一条**早期**的私有证据（会被折叠进摘要区间）+ 一段足够长的共享原文。
    await harness.seedPrivateRow(memberId: a.id, marker: kOldPrivMark);
    await harness.seedHistory(
      count: 80,
      authorOf: (i) => i.isEven ? null : a.id,
    );
    // 一条**近期**私有证据（不在折叠区，会在 A 的视图里按 replay 回放）。
    await harness.seedPrivateRow(memberId: a.id, marker: kNewPrivMark);

    final rawRows = await harness.support.messageRepo
        .queryBySession(harness.group.id);
    final bView = GroupViewProjection.project(
      raw: rawRows,
      memberId: b.id,
      displayNames: {a.id: '甲', b.id: '乙'},
    );

    // ① B 的视图（装配出的 messages）不含标记。
    final bApi = bView.apiMessages(acceptsImages: false, model: 'test-model');
    final bApiText = bApi.toString();
    // ignore: avoid_print
    print('[OBS] ① B 视图条数=${bApi.length} '
        '含旧标记=${bApiText.contains(kOldPrivMark)} '
        '含新标记=${bApiText.contains(kNewPrivMark)}');
    expect(bApiText, isNot(contains(kOldPrivMark)));
    expect(bApiText, isNot(contains(kNewPrivMark)));
    expect(bView.textContent, isNot(contains(kOldPrivMark)));

    // ③ B 触发一次折叠：摘要请求输入（folded + 参考块）不含标记。
    // 先给 B 一个真实请求（B 的回合会先折叠）。
    harness.queueFinal('乙的公开结论');
    await harness.groups
        .send(groupId: harness.group.id, memberId: b.id, text: '乙总结一下');
    // 异步发送：等链终态再断言折叠/快照（R.7）。
    expect((await harness.waitForChain()).status, 'completed');
    final foldedB = harness.support.summary.lastFolded ?? const [];
    final foldedText = foldedB
        .map((m) => '${m.content}|${m.thinkingJson ?? ''}|${m.toolCallsJson ?? ''}')
        .join('\n');
    final refs = harness.support.summary.referencesPerCall
        .expand((list) => list)
        .map((r) => r.text)
        .join('\n');
    // ignore: avoid_print
    print('[OBS] ③ B 折叠输入条数=${foldedB.length} '
        '含旧标记=${foldedText.contains(kOldPrivMark)} '
        '含新标记=${foldedText.contains(kNewPrivMark)} '
        '参考块含旧标记=${refs.contains(kOldPrivMark)}');
    expect(foldedB, isNotEmpty, reason: 'B 必须真的触发过一次折叠');
    expect(foldedText, isNot(contains(kOldPrivMark)),
        reason: 'B 的折叠输入不得含 A 的私有内容（输入通道判据）');
    expect(foldedText, isNot(contains(kNewPrivMark)));
    expect(refs, isNot(contains(kOldPrivMark)));

    // ② B 的快照（toRawJson）不含标记。
    final snapshot = harness.groups.snapshotOf(b.id);
    expect(snapshot, isNotNull);
    final snapshotJson = serializeContextSnapshot(snapshot!).toString();
    // ignore: avoid_print
    print('[OBS] ② B 快照含旧标记=${snapshotJson.contains(kOldPrivMark)} '
        '含新标记=${snapshotJson.contains(kNewPrivMark)}');
    expect(snapshotJson, isNot(contains(kOldPrivMark)));
    expect(snapshotJson, isNot(contains(kNewPrivMark)));
    expect(snapshot.toRawJson().toString(), isNot(contains(kOldPrivMark)));

    // ④ 反证：A 自己的请求里标记仍在（近期私有行按 replay 出现在 A 的视图）。
    harness.queueFinal('甲的公开结论');
    await harness.groups
        .send(groupId: harness.group.id, memberId: a.id, text: '甲也说一句');
    expect((await harness.waitForChain()).status, 'completed');
    final aRequest = harness.support.sidecar.lastMessagesJson ?? '';
    final aRaw = await harness.support.messageRepo.queryBySession(harness.group.id);
    final aView = GroupViewProjection.project(
      raw: aRaw,
      memberId: a.id,
      displayNames: {a.id: '甲', b.id: '乙'},
    );
    // ignore: avoid_print
    print('[OBS][诊断] A 视图 seq=${aView.messages.map((m) => m.seq).toList()}');
    // ignore: avoid_print
    final privateRows = aRaw
        .where((m) => m.isPrivate)
        .map((m) =>
            'seq=${m.seq} mine=${m.author == a.id} vis=${m.visibility} '
            'hasThink=${m.thinkingJson != null}')
        .join(' | ');
    // ignore: avoid_print
    print('[OBS][诊断] 私有行=$privateRows');
    // ignore: avoid_print
    print('[OBS] ④ A 的视图含新标记=${aView.textContent.contains(kNewPrivMark)} '
        'A 的真实请求含新标记=${aRequest.contains(kNewPrivMark)} '
        '（旧标记已进摘要，不在原文段）');
    expect(aView.messages.any((m) =>
            (m.thinkingJson ?? '').contains(kNewPrivMark) ||
            (m.toolCallsJson ?? '').contains(kNewPrivMark)),
        isTrue,
        reason: 'A 自己的视图里必须能看到自己的私有证据（反证：不是两边都丢）');
    // 反证的观察点也是**输入通道**：A 自己的视图（这一轮装配出的 messages）里标记
    // 必须在，且用与 Agent 相同的装配器（buildApiMessages）会把它按 replay 发出去。
    // （真实请求里它可能被折叠进摘要 —— 那是 A 自己的摘要，不是泄漏；假摘要 provider
    // 固定文本会把这个差异放大，所以这里不断言最终请求的文本。）
    final aAssembled = buildApiMessages(
      aView.messages,
      acceptsImages: false,
      model: 'test-model',
    ).toString();
    // ignore: avoid_print
    print('[OBS] ④ A 的视图含新标记='
        '${aView.messages.any((m) => (m.thinkingJson ?? '').contains(kNewPrivMark))} '
        'A 的装配结果含新标记=${aAssembled.contains(kNewPrivMark)} '
        '（最终请求含=${aRequest.contains(kNewPrivMark)}，可能被 A 自己的摘要代表）');
    expect(aAssembled, contains(kNewPrivMark),
        reason: '反证：同一装配器下 A 自己的私有证据出现在请求里（不是两边都丢）');
    await harness.dispose();
  });
}
