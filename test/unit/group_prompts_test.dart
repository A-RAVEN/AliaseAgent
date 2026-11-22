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
}
