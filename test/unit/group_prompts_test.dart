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
    // ⑥ 公开回复只代表自己，不冒充其它成员（R.12 第三条纪律）
    expect(prompt, contains('只代表你自己'));
    expect(prompt, contains('不要替其它成员发言'));
    expect(prompt, contains('编造他们的观点'));
    expect(prompt, contains('不要抢答点名其它成员的问题'));
    expect(prompt, contains('实际说过'));
    expect(prompt, contains('模拟多个成员的对话'));
    // ⑦ 第一人称发言，禁自我署名（系统自动署名）
    expect(prompt, contains('第一人称'));
    expect(prompt, contains('不要在正文开头写自己的名字'));
    expect(prompt, contains('归属标签'));
    expect(prompt, contains('系统自动署名'));
    expect(prompt, contains('不要凭空编造'));

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

  test('kGroupMemberIdentityPrompt：把成员自己的显示名注入系统提示词', () {
    final a = kGroupMemberIdentityPrompt('甲');
    final b = kGroupMemberIdentityPrompt('乙');
    // ignore: avoid_print
    print('[OBS] 甲身份句=$a');
    // ignore: avoid_print
    print('[OBS] 乙身份句=$b');
    expect(a, contains('你就是「甲」本人'));
    expect(a, contains('别人用「甲」称呼你'));
    expect(a, contains('跟你说话'));
    expect(a, contains('跟别人说话'));
    expect(a, contains('你自己发言时直接以第一人称「我」'));
    expect(a, contains('不要称自己为「甲」'));
    expect(a, contains('系统会自动把你的发言标为「甲」'));
    expect(a, contains('模板'));
    expect(a, contains('不代表你在本群的身份'));
    expect(a, isNot(contains('唯一称呼')),
        reason: '旧的外部标签视角必须删掉，不能保留「唯一称呼」');
    expect(a, isNot(equals(b)), reason: '不同成员的身份句必须不同');
    expect(a, isNot(contains('「乙」')), reason: '甲的身份句不能把乙写成自己');
  });

  test('kGroupReactionPrompt：名点识别纪律（点名别人沉默 / 点名自己回应）', () {
    const prompt = kGroupReactionPrompt;
    expect(prompt, contains('点名'));
    expect(prompt, contains('其他成员'));
    expect(prompt, contains('别人名字'));
    expect(prompt, contains('点名的是**你**'));
    expect(prompt, contains('应当回应'));
  });

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
    // ⑦ 不替其它成员发言，但允许引用/回应实际说过的话（精确界定）
    expect(prompt, contains('只代表你自己'));
    expect(prompt, contains('不要替其它成员发言'));
    expect(prompt, contains('编造他们的观点'));
    expect(prompt, contains('不要抢答点名'));
    expect(prompt, contains('实际说过'));
    expect(prompt, contains('不要模拟多个成员的对话'));
    // ⑧ 第一人称、禁自我署名
    expect(prompt, contains('第一人称'));
    expect(prompt, contains('开头写'));
    expect(prompt, contains('自己的名字'));
    expect(prompt, contains('归属标签'));
    expect(prompt, contains('系统自动署名'));
    // ⑨ 对象未出现先等待，不编造
    expect(prompt, contains('尚未出现'));
    expect(prompt, contains('等待它出现'));
    expect(prompt, contains('不要凭空编造'));
    expect(prompt, contains('不要假装读了不存在的文件'));
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
    // ④ 第一人称、禁自我署名（必应轮同样适用）
    expect(prompt, contains('第一人称'));
    expect(prompt, contains('开头写'));
    expect(prompt, contains('自己的名字'));
    expect(prompt, contains('系统自动署名'));
    // ⑤ 对象没出现：如实说还没看到，不编造
    expect(prompt, contains('还没看到'));
    expect(prompt, contains('不要编造对象'));
    expect(prompt, contains('不存在的文件'));
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
    expect(kGroupMemberRolePrompt, isNot(contains('用户点名了你')));
  });
}
