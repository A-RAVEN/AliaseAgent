// 成员视图的驻留界与缓存生命周期（change `agent-group-chat` 任务 4.9 / design D9）。
//
// 四条判据：
//   ① 同一历史在 1M / 200k 窗口下派生不同 `T`（阈值按成员自己的窗口算）；
//   ② 常驻原文段不超 `T`（压缩计划自己的保证）；
//   ③ 解析缓存条目只跟随当前驻留视图的 seq 并集，不随会话全长增长；
//   ④ 同一公开行在两个成员视图里只解析一次（公共缓存命中）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/compaction/compaction_plan.dart';
import 'package:alias_agent/services/group_view_loader.dart';

import '../widget/helpers/fakes.dart';

List<Message> _history(int count, {int chars = 250}) => [
      for (var i = 1; i <= count; i++)
        Message(
          id: 'm$i',
          seq: i,
          sessionId: 'group-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'A' * chars,
          author: i.isOdd ? null : 'member-a',
          createdAt: i,
        ),
    ];

void main() {
  test('① 同一历史在 1M / 200k 窗口下派生不同的 T', () {
    // 百分比来自模板配置（缺省 25），唯一计算点是 thresholdTokens。
    final t1m = CompactionEngine.thresholdTokens(1000000, 25);
    final t200k = CompactionEngine.thresholdTokens(200000, 25);
    // ignore: avoid_print
    print('[OBS] T(1M,25%)=$t1m T(200k,25%)=$t200k 比例=${t1m / t200k}');
    expect(t1m, 250000);
    expect(t200k, 50000);
    expect(t1m / t200k, 5.0, reason: '阈值随成员自己的窗口成比例，不是共享的写死数');
    // 换百分比跟着变（不是常数）。
    expect(CompactionEngine.thresholdTokens(1000000, 10), 100000);
  });

  test('② 常驻原文段不超 T（压缩计划把它折叠到阈值以内）', () {
    // 600 条 × 400 字符 ≈ 6 万 token 的 raw，超过 200k×25% 的 T。
    final history = _history(600, chars: 400);
    const percent = 25;
    const window = 200000;
    final t = CompactionEngine.thresholdTokens(window, percent);
    final plan = CompactionEngine.buildTree(
      history: history,
      maxContextTokens: window,
      closed: const [],
      coverageFloorSeq: -1,
      thresholdPercent: percent,
    );
    final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
    // ignore: avoid_print
    print('[OBS] T=$t 常驻原文 raw=$verbatimRaw 段数=${plan.segments.length}');
    expect(plan.shouldCompact, isTrue);
    expect(verbatimRaw, lessThanOrEqualTo(t),
        reason: '视图超过 T 的部分由该成员自己的压缩折叠，常驻原文不超过 T');
  });

  test('③ 解析缓存条目只跟随驻留视图的 seq 并集，不随会话全长增长', () async {
    final repo = FakeMessageRepository(_history(60, chars: 40));
    final loader = GroupViewLoader(groupId: 'group-1', messageRepo: repo);
    // 先装配：coveredThrough=50 ⇒ 只留 seq>50 的项。
    await loader.assemble(
      memberId: 'member-a',
      displayNames: const {'member-a': '甲'},
      coveredThrough: 50,
    );
    final resident = loader.residentSeqs('member-a');
    // ignore: avoid_print
    print('[OBS] 驻留 seq=$resident 缓存条目=${loader.cache.length} '
        '原文总行=60');
    expect(loader.cache.length, resident.length,
        reason: '缓存只保留当前驻留视图的 seq 并集（旧行离开视图即淘汰）');
    expect(loader.cache.length, lessThan(60));

    // 再追加 100 行：缓存上限仍由驻留视图决定，不随原文总行数线性增长。
    repo.messages.addAll(_history(160, chars: 40).sublist(60));
    await loader.assemble(
      memberId: 'member-a',
      displayNames: const {'member-a': '甲'},
      coveredThrough: 120,
    );
    final resident2 = loader.residentSeqs('member-a');
    // ignore: avoid_print
    print('[OBS] 第二轮驻留==${resident2.length} 缓存=${loader.cache.length} '
        '原文总行=${repo.messages.length}');
    expect(loader.cache.length, resident2.length);
    expect(loader.cache.length, lessThan(160));
  });

  test('④ 同一公开行在两个成员视图里只解析一次（公共缓存）', () async {
    final sharedCache = GroupRowParseCache();
    final repo = FakeMessageRepository([
      ..._history(6, chars: 30),
      // 一条私有行（只属于甲）：不进公共缓存，两个视图各一份。
      Message(
        id: 'priv',
        seq: 7,
        sessionId: 'group-1',
        role: 'assistant',
        content: '',
        author: 'member-a',
        visibility: Message.visibilityPrivateToAuthor,
        createdAt: 7,
      ),
    ]);
    final loaderA = GroupViewLoader(
        groupId: 'group-1', messageRepo: repo, cache: sharedCache);
    final loaderB = GroupViewLoader(
        groupId: 'group-1', messageRepo: repo, cache: sharedCache);
    await loaderA.assemble(
      memberId: 'member-a',
      displayNames: const {'member-a': '甲'},
      coveredThrough: 0,
    );
    final afterA = sharedCache.parseCount;
    await loaderB.assemble(
      memberId: 'member-b',
      displayNames: const {'member-a': '甲'},
      coveredThrough: 0,
    );
    final afterB = sharedCache.parseCount;
    // ignore: avoid_print
    print('[OBS] 甲装配后解析=$afterA 乙装配后解析=$afterB '
        '公开行数=6 私有行数=1');
    expect(afterA, 7,
        reason: '甲：6 条公开行各解析一次 + 自己的私有行各一份（不进公共缓存）');
    expect(afterB, afterA,
        reason: '乙视图里的公开行全部命中公共缓存（同一行只解析一次）');
    // 两个视图各自正确：乙看不到甲的私有行。
    expect(loaderB.residentSeqs('member-b'), isNot(contains(7)));
    expect(loaderA.residentSeqs('member-a'), contains(7));
  });
}
