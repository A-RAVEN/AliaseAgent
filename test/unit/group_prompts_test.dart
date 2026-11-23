// 两段提示词纪律（change `agent-group-chat` 任务 4.6 / design D6）。
//
// 逐字断言两段常量的全文，并钉住分工：
//   - 成员角色说明五件事齐备（含「Y 说：」、assistant 轮、工具过程不可见、自包含、
//     共享工作区）；
//   - 摘要纪律**只有归属**，不含"自包含 + 文件指针"。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/group_prompts.dart';

void main() {
  test('kGroupMemberRolePrompt 五件事齐备（逐字）', () {
    const prompt = kGroupMemberRolePrompt;
    // ignore: avoid_print
    print('[OBS] 角色说明全文（${prompt.length} 字）：$prompt');

    // ① 他人以「Y 说：」出现在 user 轮
    expect(prompt, contains('「某某 说：」'));
    expect(prompt, contains('user 轮'));
    // ② 自己的历史以 assistant 轮呈现
    expect(prompt, contains('assistant 轮'));
    expect(prompt, contains('第一人称'));
    // ③ 他人的工具过程不可见
    expect(prompt, contains('看不到其他成员的思考与工具过程'));
    // ④ 公开回复必须自包含（结论 + 文件指针）
    expect(prompt, contains('自包含'));
    expect(prompt, contains('结论'));
    expect(prompt, contains('文件路径'));
    expect(prompt, contains('公开回复'));
    // ⑤ 共享工作区是协调通道
    expect(prompt, contains('共享工作区'));
    expect(prompt, contains('协调通道'));

    // 与先例同源：子 Agent 角色说明里的"自包含最终结论 + 结论与文件路径写清楚"
    // 被泛化到成员的每一次公开回复。
    expect(prompt, contains('必要的背景'));
    expect(prompt, contains('写清楚'));
  });

  test('kGroupSummaryPromptSuffix 只有归属纪律，不含自包含要求', () {
    const suffix = kGroupSummaryPromptSuffix;
    // ignore: avoid_print
    print('[OBS] 摘要纪律全文（${suffix.length} 字）：$suffix');

    expect(suffix, contains('说：'), reason: '必须点名「Y 说」这种归属形态');
    expect(suffix, contains('归属'));
    expect(suffix, contains('第一人称'));
    expect(suffix, isNot(contains('自包含')),
        reason: '摘要私有、跨成员不读：不许带公开回复的自包含纪律');
    expect(suffix, isNot(contains('文件指针')));
    expect(suffix, isNot(contains('文件路径')));
    expect(suffix, isNot(contains('结论')),
        reason: '"结论 + 文件指针"是公开回复纪律，不进摘要');
  });

  // ---------------------------------------------------------------------------
  // 自发反应的两段提示词（change `group-reactive-mode` R.9 / design D6）
  // ---------------------------------------------------------------------------

  test('kGroupReactionPrompt：默认沉默框架 + few-shot + 相关性门槛 + group_react', () {
    const prompt = kGroupReactionPrompt;
    // ignore: avoid_print
    print('[OBS] 反应提示词全文（${prompt.length} 字）：$prompt');

    // ① 默认沉默：沉默是常态、发言是例外；大多数轮 pass=true；pass=true 不是失败。
    expect(prompt, contains('默认沉默'));
    expect(prompt, contains('沉默是常态、发言是例外'));
    expect(prompt, contains('大多数轮'));
    expect(prompt, contains('pass: true'));
    expect(prompt, contains('pass=true 不是失败'));
    expect(prompt, contains('群聊礼仪'));
    // ② 只有非说不可、别人没说过的实质新信息才发言。
    expect(prompt, contains('非说不可'));
    expect(prompt, contains('别人没说过的实质新信息'));
    expect(prompt, contains('pass: false'));
    // ③ few-shot：四个 pass=true 情形逐字（不是只写"可以 PASS"）。
    for (final sample in <String>[
      '别人已经表达过类似观点',
      '你只是纯表态、没有新依据',
      '对话已经充分收尾',
      '与你的角色/职责无关',
    ]) {
      // ignore: avoid_print
      print('[OBS] pass=true 样板「$sample」');
      expect(prompt, contains(sample), reason: '缺少 pass=true 情形「$sample」');
    }
    // ④ 相关性门槛。
    expect(prompt, contains('相关性门槛'));
    expect(prompt, contains('只反应真正新的、与你相关的信息'));
    // ⑤ 结构化纪律：指示 group_react，message 是唯一公开内容，禁止元话术。
    expect(prompt, contains('group_react'));
    expect(prompt, contains('恰好一次'));
    expect(prompt, contains('message 是唯一会公开的内容'));
    expect(prompt, contains('不要在正文里写'));
    expect(prompt, contains('我 PASS'));
    expect(prompt, contains('我不发言'));
    // ⑥ 发言仍要自包含、要有依据（不是空泛表态）。
    expect(prompt, contains('自包含'));
    expect(prompt, contains('文件指针'));
    expect(prompt, contains('有依据的同意'));
    expect(prompt, contains('有依据的反对'));
  });

  test('kGroupMustRespondPrompt：必应 + 指示 group_react pass=false，且无沉默授权', () {
    const prompt = kGroupMustRespondPrompt;
    // ignore: avoid_print
    print('[OBS] 必应提示词全文（${prompt.length} 字）：$prompt');

    // ① 用户点名了你，这一轮必须实质回应。
    expect(prompt, contains('点名'));
    expect(prompt, contains('必须'));
    expect(prompt, contains('实质'));
    expect(prompt, contains('回应'));
    // ② 指示 group_react {pass: false, message}。
    expect(prompt, contains('group_react'));
    expect(prompt, contains('pass 必须为 false'));
    expect(prompt, contains('message'));
    // ③ **没有** pass=true 的沉默授权（本 change 不改必应口径）。
    expect(prompt, isNot(contains('pass=true')),
        reason: '必应轮不许出现 pass=true 的沉默授权');
    expect(prompt, isNot(contains('pass: true')));
    expect(prompt, isNot(contains('没有话说')));
    expect(prompt, isNot(contains('没有贡献')));
  });

  test('两段提示词分工：不互相替换，也都不与成员角色说明互换', () {
    // ignore: avoid_print
    print('[OBS] 三段是否互不相同 => '
        '${kGroupReactionPrompt != kGroupMustRespondPrompt} / '
        '${kGroupReactionPrompt != kGroupMemberRolePrompt} / '
        '${kGroupMustRespondPrompt != kGroupMemberRolePrompt}');
    expect(kGroupReactionPrompt, isNot(equals(kGroupMustRespondPrompt)));
    expect(kGroupReactionPrompt, isNot(equals(kGroupMemberRolePrompt)));
    expect(kGroupMustRespondPrompt, isNot(equals(kGroupMemberRolePrompt)));
    // 沉默授权（pass=true）只出现在自愿轮那一段；必应轮没有。
    expect(kGroupReactionPrompt, contains('pass=true'));
    expect(kGroupMustRespondPrompt, isNot(contains('pass=true')));
    // 成员角色说明仍只有角色与自包含，不含反应/必应纪律。
    expect(kGroupMemberRolePrompt, isNot(contains('group_react')));
    expect(kGroupMemberRolePrompt, isNot(contains('点名')));
  });
}
