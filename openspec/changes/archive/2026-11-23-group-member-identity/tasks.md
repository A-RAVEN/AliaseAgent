# Tasks: 成员自我身份锚 + 名点识别

## 1. 身份锚注入

- [x] 1.1 在 `lib/services/group_prompts.dart` 新增参数化常量 `kGroupMemberIdentityPrompt(name)`（内容：成员自己的显示名 + 「别人叫这个名字是在跟你说话 / 叫别的名字是在跟别人说话」），并在 `AgentFactory.createMember` 的系统提示词拼装处与 `kGroupMemberRolePrompt` 一起注入；所有组成员轮（定向 / mention / 自愿反应）都带，普通轮与关闭态纯 speaker 不变。先写 `test/unit/group_prompts_test.dart` 的红断言：`kGroupMemberIdentityPrompt('甲')` 含「甲」「群聊组的成员」「跟你说话」「跟别人说话」，且不等于 `'乙'` 的身份句。
- [x] 1.2 身份锚改为**第一人称本人视角**：「你就是「名字」本人」「别人用「名字」称呼你」「你自己发言时直接以第一人称「我」」「不要称自己为「名字」」「系统会自动把你的发言标为「名字」」「模板里的自称/角色名不代表本群身份」；删掉旧的外部标签句「这是你在本群的唯一称呼」。核对 `sidecar.sendMessage` payload 与 `_callModel` 组装，确认 `agentTypeName` 只进 `ContextSnapshot.agentType`、不作为身份进模型可见处。测试：`test/unit/group_prompts_test.dart` 逐字断言上述新措辞且**不含**「唯一称呼」；`test/integration/agent_reaction_round_test.dart` 断言模型请求参数中没有 `agentType` 键。
- [x] 1.3 群成员名单**每轮现读**注入系统提示词：`Agent` 新增 `groupRosterProvider`，`GroupService.ensureMemberAgent` 传入「`listByGroup` 过滤 `isRemoved`、取名字」的闭包；`_callModel` 每轮装配时追加「本群成员：…。你是「…」。」，不缓存、不重建实例。测试：`test/integration/agent_reaction_round_test.dart` 断言首轮名单「甲、乙」、加入丙后下一轮「甲、乙、丙」，且身份仍是「甲」。

## 2. 反应提示词名点纪律

- [x] 2.1 `kGroupReactionPrompt` 补「最新消息点名**其他成员**（@别人或直接叫别人名字）时，除非有别人没说过的实质性补充，否则 `pass=true`；点名的是**你**时应当回应：`pass=false` 并给出实质内容」，不改变默认沉默框架与 `group_react` 纪律。先写 `test/unit/group_prompts_test.dart` 的红断言：包含「点名」「其他成员」「别人名字」「点名的是**你**」「应当回应」。
- [x] 2.2 `kGroupReactionPrompt` 与 `kGroupMemberRolePrompt` 同时补「不替其它成员发言」纪律，并精确界定：禁替其它成员发言/编造观点/抢答点名别人的问题/模拟多成员对话；**允许**引用、回应、反驳别人实际说过的话。测试 `test/unit/group_prompts_test.dart` 逐字断言两段都含「只代表你自己」「不要替其它成员发言」「编造他们的观点」「实际说过」「模拟多个成员的对话」。
- [x] 2.3 第一人称口吻**重写身份锚视角**（不是追加一句话）：`kGroupMemberIdentityPrompt(name)` 改为「你就是「name」本人；『name』只是别人叫你的方式，你自己发言直接以第一人称『我』；不要称自己为『name』、不要署名；系统会自动把你的发言标为『name』」；`kGroupMemberRolePrompt` 的 (1)(2) 归属句改为「别人被系统标名 / 你自己用『我』、不用加前缀」，`kGroupReactionPrompt` / `kGroupMustRespondPrompt` 在「只代表你自己」处补第一人称要求。删掉旧的外部标签句「这是你在本群的唯一称呼」。产品不做事后文本清洗（署名由 `author` 承担）。测试：`test/unit/group_prompts_test.dart` 逐字断言新身份措辞且不含「唯一称呼」、三段含「第一人称」「开头写自己的名字」「归属标签」「系统自动署名」；`test/integration/agent_reaction_round_test.dart` 断言第一人称 message 原样落库、不以成员名开头、不自动加「甲：」前缀。先红：把身份锚临时改回旧外部标签句后身份测试必红（已验证 `Expected: contains '你就是「甲」本人'`）。
- [x] 2.4 对象未出现先等待：`kGroupReactionPrompt`、`kGroupMemberRolePrompt`、`kGroupMustRespondPrompt` 补「被要求评价/回应的对象尚未出现时返回 pass=true 等待；不要凭空编造对象、不要假装读了不存在的文件、不要自己造一份再评」；该纪律优先于名点识别；强制轮对象不存在时如实说「还没看到 X，请 X 先给出」。测试：`test/unit/group_prompts_test.dart` 逐字断言「尚未出现」「等待它出现」「不要凭空编造」「不要假装读了不存在的文件」与必应轮的「还没看到」「不要编造对象」；`test/integration/agent_reaction_round_test.dart` 编排「丙讲笑话」首轮甲乙 `passed`、丙 `replied`，次轮甲乙 `replied` 且评价丙实际那段、无假文件名。

## 3. 身份与名点行为测试

- [x] 3.1 `test/integration/agent_reaction_round_test.dart` 创建甲/乙/丙三个成员实例，断言各自系统提示词含 `kGroupMemberIdentityPrompt(自己的名字)`、不含别人的身份句。先红：当前身份锚未注入时断言必红。
- [x] 3.2 同一文件用假 sidecar 编排「丙讲个笑话，甲和乙评价一下」：第一轮甲/乙 `passed`、丙 `replied`，讲笑话的首个公开成员行 `author=丙`（不是乙抢讲）；断言丙的 `publicSeq` 非空。先红再实现。
- [x] 3.3 同一文件补名单现读用例：甲先跑一轮（名单甲、乙），加丙后再跑一轮（名单甲、乙、丙），且请求参数没有 `agentType`；断言身份句是「你就是「甲」本人」「不要称自己为「甲」」的第一人称视角。先红：名单未注入/缓存时断言必红。
- [x] 3.4 提示词测试断言两段都含「只代表你自己」「不要替其它成员发言」「编造他们的观点」「不要抢答点名其它成员的问题」「可以引用、回应、反驳别人实际说过的话」「不要模拟多个成员的对话」；既有名点别人→`pass=true` 的行为用例保持。先红：纪律未写入时常量断言必红。
- [x] 3.5 第一人称行为测试：`test/integration/agent_reaction_round_test.dart` 用假 sidecar 让成员以「我认为……」发言，断言公开行内容原样等于 message、`startsWith('我')`、不以「甲」开头、不含「甲：」；三段常量断言见 2.3。
- [x] 3.6 对象未出现等待行为测试：同一文件编排「丙讲笑话，甲和乙评价」：首轮甲/乙 `passed`、丙 `replied`；次轮甲/乙 `replied` 且评论文本引用丙实际讲的关键短语（「从前有座山」），公开时间线不含 `joke_scores` 等假文件名；另断言甲乙第一轮没有编造内容进公开行。

## 4. 真实模型 live 复跑

- [x] 4.1 `integration_test/group_reaction_live_support.dart` 第一段场景改为「丙讲一个笑话，甲和乙分别评价一下这个笑话。」，断言**丙有 `replied` 步骤且其公开行 `author=丙`**（讲笑话的公开行不是别人代讲；甲/乙此前的「请丙贴正文」属允许的实质补充，不要求全场第一条是丙），打印 author / 沉默率 / `stopReason` 并截图；`group.view` 快照断言成员系统提示词含「本群成员：甲、乙、丙。你是「自己」。」；第二段 `@乙` 定向必应保持。运行 `flutter test --tags live --run-skipped integration_test/group_reaction_live_test.dart -d windows`，贴输出与 `read_image` 结论。

## 5. 文档与守卫

- [x] 5.1 `Docs/user-guide/group-chat.md` 增加「成员知道自己的名字」「裸名点名（没有 `@`）靠身份锚 + 自愿反应识别」「点名其他成员时默认沉默」「每轮看到的群成员名单」「不替其它成员发言（但可引用回应）」的说明；`test/unit/group_docs_test.dart` 增加对应文档锚点（身份 / 自我名字 / 点名别人 / 本群成员 / 替其它成员发言），并保持既有结构化 PASS、默认沉默、轮数上限守卫全绿。先红：文档未更新时锚点断言必红。
