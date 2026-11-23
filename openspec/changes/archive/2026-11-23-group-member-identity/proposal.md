## Why

用户实测揪出一个根本缺陷：在群里说「丙讲个笑话」，结果**乙讲了**。根因不是调度器，而是
**成员没有自我身份**：`kGroupMemberRolePrompt` 只说「你是一个群聊组的成员」（泛称），
`member.name` 只被 `displayNamesResolver` 用来渲染**别人**的「X 说」投影，从来没有告诉
成员**自己**叫什么。于是乙、丙都不知道「丙」指谁：乙可能抢着讲，丙可能不响应；显式
`@丙` 走强制轮还能工作，但裸名点名（没有 `@`）完全靠成员自己认名字，当前提示词给不出
这个信息。

这是群聊「点名」体验的根缺陷：调度器再正确，成员不知道自己的名字也无法按名点分工。

## What Changes

- **成员自我身份锚**：新增参数化提示词 `kGroupMemberIdentityPrompt(name)`，内容为
  「你是这个群聊组的成员「{name}」。别人叫这个名字（@名字 或直接叫「名字」）时是在跟你
  说话；叫别的名字时是在跟别人说话」。成员实例创建时（`agent_factory.createMember`，
  与 `kGroupMemberRolePrompt` 一起）用 `member.name` 注入；所有组成员轮（定向/反应）都带，
  普通轮/关闭态行为不变。
- **反应提示词补名点识别纪律**：`kGroupReactionPrompt` 增加「最新消息点名**其他成员**时，
  除非有别人没说过的实质性补充，否则 `pass=true`；点名**你**时应当回应：`pass=false`
  并给出实质内容」。
- **`@mention` 定向不变**：显式 `@丙` 仍由 `parseMentionedMemberIds` 解析并走强制轮；
  裸名点名（「丙讲笑话」无 `@`）靠身份锚 + 自愿反应识别，不改 `@` 解析器。
- **不把模板名当身份**：身份锚改用**第一人称本人视角**——「你就是「名字」本人；
  「名字」只是别人叫你的方式，你自己发言用「我」；不要称自己为「名字」；系统自动把你的
  发言标为「名字」」，并声明模板提示词里的自称/角色名不代表本群身份；`agentTypeName`
  只进 UI 的 `ContextSnapshot.agentType`，不进入模型可见的 `sendMessage` payload。
- **群成员名单每轮现读**：`Agent._callModel` 每轮装配系统提示词时通过
  `groupRosterProvider` 现读未移除成员，注入「本群成员：甲、乙、丙。你是「丙」。」；
  成员增减下一轮即生效，不缓存、不重建实例；已移除成员不进当前名单。
- **不替其它成员发言**：`kGroupMemberRolePrompt` 与 `kGroupReactionPrompt` 同时写入
  「公开回复只代表你自己」纪律——禁冒充/编造别人观点、禁抢答点名别人的问题、禁模拟
  多成员对话；但**允许**引用、回应、反驳别人实际说过的话（这是实质贡献，不是替发言）。

## Impact

- 代码：`lib/services/group_prompts.dart`（身份锚函数 + 反应提示词）、
  `lib/services/agent_factory.dart`（成员实例系统提示词注入点）。
- 测试：`test/unit/group_prompts_test.dart`（身份句、名点纪律逐字断言）、
  `test/integration/agent_reaction_round_test.dart`（三个成员各自系统提示词含自身名；
  裸名点名「丙讲笑话」时甲/乙 `passed`、丙 `replied`、首个公开行 `author=丙`）。
- live：`integration_test/group_reaction_live_support.dart`（场景改为「丙讲一个笑话，
  甲和乙分别评价一下」，断言讲笑话的公开行 `author=丙`）。
- 文档：`test/unit/group_docs_test.dart` 守卫 + `Docs/user-guide/group-chat.md`
  说明「成员知道自己的名字」「裸名点名怎么工作」「点名别人时默认沉默」。
- 行为兼容：显式 `speaker` / `@mention` 调度不变；关闭态纯 speaker 普通轮不追加任何
  反应提示词，也不改变 `[PASS]` 的普通正文语义。
