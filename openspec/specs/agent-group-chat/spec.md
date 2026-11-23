# Agent Group Chat — Spec

## Purpose

规定组会话（`kind = group`）与成员身份，以及组内对话的存储、投影与调度纪律。组内全部公开消息与各成员的私有活动存为**同一份原文**、共用同一条 per-session `seq` 序列，每条行带 `author`（稳定成员 id）与 `visibility`（`public` / `private-to-author`）；发给某个成员的上下文只能由「可见性过滤 + 主客体映射」这一份**逐成员视图投影**产出，他人私有内容永不进入该成员视图。发言由用户点名或自发反应链调度（每组一个串行执行器保证同一时刻至多一个成员在写；`group.send` 异步返回 `started`、永不 busy，链运行中再发也接受并进入执行器队列/被吸收）。公开回复必须自包含（他人看不到自己的工具过程），共享工作区的同一目录是成员间真正的协调通道；摘要则按成员作用域私有存储、不跨成员共享，参考上下文块同样受成员作用域限制。核心提供群 RPC 面，web 在真实应用里提供组视图（公开时间线 + 右侧成员名单 + [群聊 | 成员视图] 双标签；真实上下文与占用环在成员视图内）。隐私边界以**输入通道**（投影产出的 messages、摘要请求的 folded 文本与参考块）为可失败判据。成员视图按 `seq` 区间增量装配、按各自窗口派生的阈值 `T` 界定驻留，派生缓存随驻留视图淘汰；任何缓存容量、批大小或上下限都不得是写死的魔数。

## Requirements

### Requirement: 组会话与成员

系统 SHALL 支持 `kind = group` 的组会话。一个组会话 SHALL 在 `group_members` 中持有 N 个成员，每个成员有**稳定的成员 id**（主键）、组内唯一的显示名、模板名、覆盖层与加入时间。成员身份（author）SHALL 用成员 id 记录，显示名 SHALL 只在渲染归属时从 `group_members` 解析；改名 SHALL NOT 改变历史消息的归属。

成员名在组内 SHALL 唯一且非空（唯一性只在**未移除**的成员之间成立），重名或空名 SHALL 被拒绝并指明冲突的名字（MUST NOT 静默改名）。移除成员 SHALL 是**软删**：写入 `removed_at` 标记、行保留、其原文与摘要一律不删；移除后同名重建 SHALL 是一个**新的成员 id**，新成员 SHALL NOT 看到旧成员的私有行。`group.list` SHALL 返回已移除成员（带 `removedAt`），使历史行的归属有去处。删除组会话 SHALL 级联删除其成员、消息与摘要。

组会话 SHALL 在创建时建立自己的上下文（`ensureContext(groupId, defaultWorkspace: workspace)`）：`workspace` 由 RPC 可选传入，缺省用产品既有缺省工作区口径（`Agent.ensureContext` 的 `defaultWorkspace ?? ConfigService.homeDir`），SHALL NOT 发明第二个缺省值。

#### Scenario: 建组并加入两个成员

- **WHEN** 用户创建组会话并依次加入成员「甲」「乙」（各自指定模板）
- **THEN** `group.list` 返回该组（`kind = group`）并带两条成员记录（各带稳定成员 id、显示名、模板名、removedAt 为空）

#### Scenario: 重名成员被拒

- **WHEN** 用户向已有未移除成员「甲」的组再加入一个名为「甲」的成员
- **THEN** 请求被拒绝并返回可归因错误（含冲突名「甲」），成员表不发生任何改动

#### Scenario: 成员改名不改变历史归属

- **WHEN** 把成员「甲」改名为「甲二」后查看它此前发的公开回复
- **THEN** 该行仍归属同一个成员 id，只显示名变成「甲二」

#### Scenario: 组会话不创建单 Agent 实例

- **WHEN** 应用或核心重启后加载顶层会话列表
- **THEN** 组会话出现在列表中，但不为它创建单 Agent 实例、不套用任何模板、不把它的原文当单会话历史恢复

#### Scenario: 移除成员不删原文且历史有归属

- **WHEN** 用户移除成员「甲」，然后上翻包含「甲」发言的历史页
- **THEN** 「甲」的发言入口与实例消失，而它此前产生的消息行与摘要行仍在库中，且每条历史行仍能按成员 id 归属到 `group.list` 里带 `removedAt` 的「甲」

#### Scenario: 移除后同名重建是新身份

- **WHEN** 移除「甲」后在同一组再建一个同名「甲」
- **THEN** 新成员拿到新的成员 id，它看不到旧「甲」的私有行；旧「甲」的公开行仍归旧 id 并显示为已移除成员

#### Scenario: 删除组级联清理

- **WHEN** 用户删除一个含成员、消息与摘要的组会话
- **THEN** 数据库中该组的成员行、消息行、摘要行均不存在（验收读真实 SQLite 行数，不只看外键声明）

#### Scenario: 建组即建立组上下文

- **WHEN** 客户端调用 `group.create`（带或不带 `workspace`）
- **THEN** 组上下文被建立且其工作区等于传入值或缺省工作区，后续成员继承到同一目录

### Requirement: 单一共享原文

组内全部公开消息与各成员的私有活动 SHALL 存为**同一个会话下的一份原文**，SHALL 共用单一 per-session `seq` 序列。每条消息 SHALL 记录 `author`（**稳定成员 id**；用户消息为空）与 `visibility`（`public` / `private-to-author`）。

系统 SHALL NOT 按成员把原文拆成多份存储（不按成员分会话、不按成员拆原文表或 lane）：视图是投影，不是存储分区。原文 SHALL NOT 因任何视图差异而被复制或改写；同一段对话在库里只有一份。

组成员回合的**最终公开行只存正文**：`tool_calls` 与 `thinking_json` 均 SHALL 为 NULL，v1 公开回复 SHALL NOT 带附件。私有证据（thinking、工具调用、工具结果）SHALL 只存在于 `visibility = private-to-author` 的行；这条约束使隐私不依赖「映射时记得过滤」。单 agent 会话的最终行行为 SHALL 保持不变（该会话不存在跨成员投影）。

#### Scenario: 两个成员的发言落在同一 seq 序列

- **WHEN** 成员「甲」与「乙」先后在同一个组里发言
- **THEN** 两条回复行的 `session_id` 相同，`seq` 严格递增，中间没有为成员切出来的第二套序列

#### Scenario: 私有活动按作者与可见性落库

- **WHEN** 成员「甲」在回合里做了 thinking 与两次工具调用
- **THEN** 这些中间行带 `author = <甲的成员 id>`、`visibility = private-to-author`，且与公开行同处这一份原文

#### Scenario: 用户消息没有成员作者

- **WHEN** 用户在组里发一条消息
- **THEN** 该行 `visibility = public` 且 `author` 为空（用户标记）

#### Scenario: 最终公开行不含工具与思考

- **WHEN** 成员「甲」一轮里调用了两次工具并产生 thinking，最后给出公开回复
- **THEN** 该公开行的 `tool_calls` 与 `thinking_json` 均为 NULL、附件为空；同一轮的工具调用与 thinking 只出现在 private 行里

#### Scenario: 原文唯一

- **WHEN** 同一个组被两个不同成员的视图分别渲染
- **THEN** 库中消息行数与内容不因视图不同而变化（换投影实现不改存储）

### Requirement: 逐成员视图投影是唯一出口

发给成员 X 的上下文 SHALL 由对原文序列做「可见性过滤 + 主客体映射」得到，逐条规则如下：

- 用户消息 → user 轮，原样；
- X 自己的公开回复 → assistant 轮，第一人称，**不带**「X 说：」归属前缀；
- X 自己的私有活动（thinking / 工具调用 / 工具结果）→ 按现有 replay 机制回放（assistant 的 thinking 与 `tool_use`，随后合成的 user `tool_result`）；
- 其他成员 Y 的公开回复 → user 轮 + 文本归属前缀「Y 说：…」（Y 用显示名，含已移除成员的显示名）；
- 其他成员的私有活动 → 整体剔除，SHALL NOT 以任何形式出现在 X 的视图里。

**归属只能进文本**：Anthropic 的 `MessageParam` 只有 `role` 与 `content` 两个字段（`Docs/AnthropicAPIDoc.md` §1.3.2 官方原文「Each input message must be an object with a `role` and `content`」），没有 `name`；DeepSeek 兼容页未记载 `name` 可用于 Messages。因此「谁说的」SHALL 以文本前缀表达，SHALL NOT 依赖不存在的字段。

**连续同角色轮**：`Docs/AnthropicAPIDoc.md` §1.3.2 明示相邻同角色轮会被合并；DeepSeek 兼容端点**未记载**该行为。装配层 SHALL 直接发出相邻同角色轮（不插填充、不改 role、不造空 text 块），并在 live 验收里断言相邻 user 轮不导致接口报错。

**投影不变量**（结构约束，不是风格约定）：

- 成员自己的 `tool_use` 与其对应的 `tool_result` 之间 SHALL NOT 夹入其他成员的公开行 —— 该工具轮按现有 replay 机制作为一个原子单元回放；
- `tool_result` SHALL 放在其所在 user 轮 `content` 数组的**最前**（与该轮其它被合并的 user 内容块相比），与现行 replay 的形态一致；
- 每条可见项 SHALL 恰好出现一次（不重复、不遗漏）。

SHALL NOT 存在第二条把原文行（尤其是他人私有活动）交给成员模型的路径。

#### Scenario: 他人公开回复进 user 轮并带前缀

- **WHEN** 成员「乙」的视图里出现「甲」的公开回复「已改完 `lib/a.dart`」
- **THEN** 该条在请求里是 role user，正文以「甲 说：」开头

#### Scenario: 自己的回复是第一人称

- **WHEN** 成员「甲」的视图里出现自己刚才的公开回复
- **THEN** 该条是 role assistant，正文不带任何「甲 说：」前缀

#### Scenario: 自己的工具轮按 replay 回放且不夹他人行

- **WHEN** 成员「甲」回放自己上一轮「thinking + 两次 tool_use + 两条 tool_result」
- **THEN** 请求里该工具轮是连续的 assistant 工具轮 + 一条 user(tool_result)，中间没有他人公开行，`tool_result` 位于该 user 轮 content 数组最前

#### Scenario: 他人私有活动整体消失

- **WHEN** 成员「甲」有私有的 thinking、工具调用与工具结果，成员「乙」的视图被装配
- **THEN** 乙的请求里不存在这些内容块的任何形式（正文、tool_use、tool_result、摘要、参考块都没有）

#### Scenario: 连续同角色直接交给接口

- **WHEN** 两个其他成员先后公开回复，而 X 自己没有发言（视图里出现两条相邻 user 轮）
- **THEN** 装配层原样发出这两条 user 轮，不插入 assistant 填充、不改写 role

#### Scenario: 只有一个装配入口

- **WHEN** 代码审查或结构断言检查「成员请求的消息来自哪里」
- **THEN** 所有成员请求的 messages 都由同一个投影函数产出（不存在绕过投影直接读原文行的第二条装配路径）

### Requirement: 成员发言调度：用户点名

一次群发送 SHALL 指定**至多一个**发言者（成员 id）。带发言者时后台先运行该成员一轮；不带发言者时按「自发反应开关与默认值」「公开消息触发反应轮」执行（开关开启时以用户消息触发反应链；开关关闭时只有用户消息里的 `@mention` 能指定响应者）。**用户发送永远接受**：`group.send` SHALL NOT 因组内已有链/成员在跑而拒绝；内部用**每组一个串行执行器**保证同一时刻至多一条链在写原文，但这是调度细节，MUST NOT 外溢成对用户输入的拒绝。执行器在跑时新请求 SHALL 入队或被吸收（下一轮反应更新的 seq），不丢失、不并发写。

**异步发送契约**：`group.send` SHALL 在完成同步前置校验（组/成员/两个前置门）、写入用户消息（若有文本）与标题后**立即返回** `status = started`；模型生成、工具、定向轮与反应链 SHALL 在后台执行。**`group.send` 永不返回 busy**；前置门失败时在返回前同步返回可归因错误。发送结果 SHALL NOT 等待链结束，也 SHALL NOT 携带链的 `steps` / `rounds` / `finalText`；链进度只从 `group.chain` 与 `group.chain.completed` 读取。

**发言者的三种语义**（与开关、`@mention` 组合）：① 开关开启 + 有 speaker ⇒ 强制轮（必应）；② 开关关闭 + 有 speaker、无 `@mention` ⇒ **旧普通轮逐字不变**（不追加反应/必应提示词、不做 PASS 判定，`[PASS]` 是普通正文）；③ 开关关闭 + 有 speaker + `@mention` ⇒ speaker 普通轮 + 按点名顺序的 mention 强制轮（两者都跑）。

发送 MAY 携带一条用户消息：携带时该消息作为用户公开消息写入**一次**（`author` 空、`public`），不携带时 SHALL NOT 写入空的用户消息行。两个前置门用于避免发出退化成单轮续写或空请求的上下文，适用于**带发言者且不带用户消息**的定向轮：

- 不带用户消息、且该成员视图为空（没有任何可见项）→ SHALL 返回可归因错误（MUST NOT 发 `messages: []`）；
- 不带用户消息、且该成员视图最后一条可见项是**本人的 assistant 轮** → SHALL 返回可归因错误（那会退化成 prefill 续写），要求带文本或最后可见项非本人 assistant。

未指定发言者的发送：开关关闭且没有 `@mention` → SHALL 返回可归因错误（`no_speaker`）；开关开启且既没有用户文本也没有发言者 → SHALL 返回可归因错误（`no_trigger`，没有可触发的公开消息）。删除/移除成员时 SHALL 先停反应链、再取消其实例。

#### Scenario: 点名谁就只有谁先发言

- **WHEN** 组的自发反应开关关闭，用户在组里发言并点名成员「甲」
- **THEN** 只有「甲」产生一轮回复与私有活动，「乙」不产生任何消息行

#### Scenario: 链运行中再发被接受

- **WHEN** 成员「甲」正在运行或一条链正在跑，客户端点名「乙」发送
- **THEN** `group.send` 返回 `started`（不返回 busy）并写入用户消息（若有文本）；「乙」的请求进入执行器队列，同一时刻只有一个成员在写，原文里不出现交错写入

#### Scenario: 链运行中再发的新消息被反应

- **WHEN** 一条反应链正在跑，客户端再发一条带文本的消息（不点名）
- **THEN** 该消息立即落库并返回 `started`；执行器在轮边界吸收它，`group.chain` 的 `triggerSeq` 更新、`rounds` 重置，后续反应能看到这条消息

#### Scenario: 用户连发多条都接受

- **WHEN** 客户端在短时间连续发出三条带文本的 `group.send`
- **THEN** 三条都返回 `started`、三条用户消息都写入；执行器串行处理，公开行不交错，没有一条被拒绝

#### Scenario: 两条并发发送不并发写

- **WHEN** 客户端几乎同时发出两条带文本的 `group.send`（都不带 speaker，组内成员可反应）
- **THEN** 两条都返回 `started` 且都写入用户消息；内部执行器串行，任何时刻至多一个成员在写公开行

#### Scenario: 关闭态纯点名是普通轮

- **WHEN** 自发反应关闭，客户端带文本点名「甲」，文本里没有 `@mention`
- **THEN** 「甲」只跑普通轮：不追加 `kGroupReactionPrompt` / `kGroupMustRespondPrompt`，不做 PASS 判定；若它输出 `[PASS]`，该文本按普通正文落公开行

#### Scenario: 不带用户消息的点名

- **WHEN** 客户端只指定发言者「甲」、不带用户消息，且「甲」的视图最后一条可见项是用户的公开消息
- **THEN** 库中 SHALL NOT 新增一条空内容的用户消息行，「甲」直接基于现有原文发言

#### Scenario: 空视图不许发

- **WHEN** 成员「甲」加入后视图为空（没有任何可见项），客户端不带用户消息点名它
- **THEN** 返回可归因错误（指明视图为空），SHALL NOT 发出空 messages 的请求

#### Scenario: 本人 assistant 结尾不许 prefill

- **WHEN** 不带用户消息点名「甲」，而「甲」的视图最后一条可见项是「甲」自己的 assistant 轮
- **THEN** 返回可归因错误，要求带用户文本或让最后可见项不是本人 assistant

#### Scenario: 安静态未点名被拒

- **WHEN** 组的自发反应开关关闭，客户端带文本发送但不带发言者、文本里也没有 `@mention`
- **THEN** 返回可归因错误（`no_speaker`），库中不新增任何消息

#### Scenario: 自发反应下无触发被拒

- **WHEN** 自发反应开启，客户端既不带文本也不带发言者发送
- **THEN** 返回可归因错误（`no_trigger`），库中不新增任何消息

#### Scenario: 带文本的点名后接反应链

- **WHEN** 自发反应开启，客户端带文本并点名「甲」
- **THEN** 用户消息写入一次，「甲」先跑一轮强制轮；它产生公开回复后，其余可反应成员对这条公开回复继续反应

### Requirement: 成员自我身份锚

成员实例的系统提示词 SHALL 包含**自我身份锚**，由代码常量 `kGroupMemberIdentityPrompt(member.name)` 用成员自己的显示名参数化生成；MUST NOT 只写泛称「你是一个群聊组的成员」而不给名字。

身份锚 MUST 采用**第一人称本人视角**：明确「你就是「名字」本人」；别人用这个名字称呼该成员（`@名字` 或直接叫「名字」）时是在跟该成员说话，叫别的名字时是在跟别人说话；但该成员**自己发言时直接以第一人称「我」说话**——「名字」只是别人叫他的方式，不是他对自己 的称呼。身份锚 MUST 要求**不要称自己为「名字」**、不要在正文给自己署名（「名字：」「名字（作者本人）：」「作为名字」），并说明**系统会自动把发言标为「名字」**；模板提示词里的任何自称或角色名都不代表本群身份。身份锚 SHALL 由成员实例创建路径（`AgentFactory.createMember`，与 `kGroupMemberRolePrompt` 同一处）注入，对所有组成员轮（定向轮、mention 强制轮、自愿反应轮）生效；普通轮与关闭态纯 speaker 的行为不变。

**模板名不得作为身份进入模型可见处**：`agentTypeName` SHALL 只出现在 UI 的 `ContextSnapshot.agentType`，MUST NOT 进入 `sidecar.sendMessage` 的 `systemPrompt` / `messagesJson` / `toolsJson`。模板自身的 `systemPrompt` 业务内容 SHALL 保留（模板作者写的），但群内身份以身份锚为准。

成员实例的系统提示词 SHALL 在**每轮装配时现读**并注入当前群成员名单（未移除成员、加入顺序），内容形如「本群成员：甲、乙、丙。你是「丙」。」；MUST NOT 缓存成实例创建时的名单。已移除成员 MUST NOT 出现在当前名单（历史公开行的归属仍保留）。

身份锚与角色说明 SHALL 同时要求**第一人称发言**：成员 MUST 用「我」直接说内容，MUST NOT 在正文开头写自己的名字或归属标签（「丙：」「丙（作者本人）：」「作为丙，我…」）；公开行署名由系统按 `author` 自动完成，成员不需要也不应该自己写。引用别人时 MAY 用「甲说…/乙提到…」。

#### Scenario: 第一人称发言且系统自动署名

- **WHEN** 捕获任一成员的角色说明 / 反应提示词 / 必应提示词
- **THEN** 其中包含「用第一人称『我』直接发言」「不要在正文开头写自己的名字或归属标签」「系统自动署名」等逐字纪律

#### Scenario: 公开行不自动加成员名前缀

- **WHEN** 某成员以 `group_react {pass:false, message:"我认为……"}` 发言
- **THEN** 公开行内容就是该 `message` 原文，不自动添加「甲：」之类前缀；归属由 `author` 字段承担

#### Scenario: 每个成员的系统提示词含自己的名字

- **WHEN** 创建「甲」「乙」「丙」三个组成员实例并捕获它们的系统提示词
- **THEN** 每个实例都包含 `kGroupMemberIdentityPrompt(自己的名字)` 全文；甲的系统提示词不包含 `kGroupMemberIdentityPrompt('乙')`，乙的也不包含甲的身份句

#### Scenario: 第一人称本人视角且模板自称不代表本群身份

- **WHEN** 捕获任一成员的系统提示词
- **THEN** 身份锚包含「你就是「名字」本人」「你自己发言时直接以第一人称「我」」「不要称自己为「名字」」「系统会自动把你的发言标为「名字」」与「模板提示词里的任何自称或角色名都不代表你在本群的身份」；不包含旧的外部标签句「这是你在本群的唯一称呼」；模型请求参数中不出现以模板名充当身份的内容

#### Scenario: 系统提示词含当前群成员名单

- **WHEN** 组内有甲、乙、丙三个未移除成员，捕获任一成员这一轮的系统提示词
- **THEN** 其中包含「本群成员：甲、乙、丙。你是「<该成员的名字>」。」；已移除成员不在名单中

#### Scenario: 名单每轮现读

- **WHEN** 某成员已发出过一轮（系统提示词名单为「甲、乙」），随后组里加入「丙」，该成员再发一轮
- **THEN** 第二轮系统提示词的名单变为「甲、乙、丙」，不需要重建实例或重启核心

#### Scenario: 裸名点名由被点名者回应

- **WHEN** 自发反应开启，用户发送「丙讲个笑话，甲和乙评价一下」（没有 `@`）
- **THEN** 「丙」凭身份锚识别出点名的是自己并回应（`pass=false`）；「甲」「乙」识别出点名的是别人，除非有别人没说过的实质性补充，否则 `pass=true`；讲笑话的公开行 `author` 必须是「丙」

#### Scenario: 身份锚在反应轮仍在

- **WHEN** 捕获任一成员的自愿反应轮系统提示词
- **THEN** 其中同时包含该成员的身份锚全文、`kGroupMemberRolePrompt` 全文与 `kGroupReactionPrompt` 全文（身份锚不会被反应提示词替换）

### Requirement: 公开回复自包含与组角色纪律

成员实例的系统提示词 SHALL 追加一段组角色说明，且该说明 SHALL 由代码常量提供（便于测试与文档断言）。说明 MUST 覆盖五件事：他人以「Y 说：」出现在 user 轮；自己的历史以 assistant 轮呈现；他人的工具过程不可见；**公开回复**必须自包含（结论 + 文件指针）；共享工作区是成员间真正的协调通道。

系统提示词 SHALL 同时包含成员自我身份锚（见「成员自我身份锚」需求），使成员知道自己叫什么、别人叫这个名字时是在跟自己说话。身份锚与组角色说明是**追加**，不得替换模板提示词或彼此替换。系统提示词还 SHALL 包含**每轮现读**的当前群成员名单（未移除成员），让成员知道群里还有谁、能识别名点别人。

组角色说明 SHALL 包含「公开回复只代表你自己」的纪律：MUST NOT 替其它成员发言、编造他们的观点或立场；MUST NOT 抢答**点名其它成员**的问题；MUST NOT 在一条回复里模拟多个成员的对话。它 SHALL NOT 禁止引用、回应、反驳别人**实际说过**的话——那是实质贡献，不是替发言。组角色说明还 SHALL 要求**第一人称发言**：用「我」直接说内容，MUST NOT 在正文开头写自己的名字或「某某：」归属标签；公开行署名由系统自动完成。组角色说明 SHALL 要求：被要求评价/回应的对象还没出现时，MUST NOT 凭空编造，应如实说还没看到、等它出现。

自包含纪律 SHALL 只约束**公开回复**（它会被其他成员读到），SHALL NOT 强加给摘要：摘要是该成员私有的、跨成员不读，只要求保留归属（见「逐视图摘要的私有性」）。

#### Scenario: 系统提示词含组角色说明

- **WHEN** 创建一个组成员实例
- **THEN** 它实际发送的系统提示词里包含组角色说明常量的全文（逐字断言，不是"包含关键字"）

#### Scenario: 身份锚与角色说明并存

- **WHEN** 创建任一组成员实例并捕获其系统提示词
- **THEN** 其中同时包含 `kGroupMemberIdentityPrompt(自己的名字)` 与 `kGroupMemberRolePrompt` 的全文

#### Scenario: 只代表自己，不冒充其它成员

- **WHEN** 捕获任一成员的系统提示词
- **THEN** 组角色说明包含「只代表你自己」「不要替其它成员发言」「不要编造他们的观点」「不要抢答点名其它成员的问题」「可以引用、回应、反驳别人实际说过的话」「不要模拟多个成员的对话」等逐字纪律

#### Scenario: 他人工具证据不可见也能协作

- **WHEN** 成员「甲」用工具改了共享工作区里的一个文件，随后用户点名「乙」
- **THEN** 「乙」的视图里没有「甲」的工具证据，但「甲」的公开回复带了文件指针，「乙」能按指针读到该文件（观察通道输出结论与路径）

#### Scenario: 摘要不被要求自包含

- **WHEN** 检查组摘要请求的系统文本与纪律常量
- **THEN** 其中不含「结论 + 文件指针」这类面向公开回复的自包含要求，只有归属保持要求

### Requirement: 共享工作区继承

成员上下文 SHALL 用**组上下文当前工作区**初始化：取工作区前先经统一入口 `ensureGroupContext(groupId)` 按需重注册（核心重启后存量群上下文丢失时重注册，避免 `unknown_context`），再 `sidecar.getWorkspace(groupId)` 只读读取作为成员上下文默认工作区。该工作区由 `group.create` 建立（见「组会话与成员」）；**自定义工作区不持久化，核心重启后组工作区回落缺省 `ConfigService.homeDir`，成员随之继承缺省（已知限制；持久化另立）**。系统 SHALL NOT 给成员单独的私有工作区；成员写入的文件对全组可见（同一目录）。

成员实例 SHALL 是持久实例：SHALL NOT 建立 `parent_session_id` 子运行记录，SHALL NOT 在回合结束时销毁上下文。

#### Scenario: 成员工作区等于组工作区

- **WHEN** 组成员实例被创建，且组上下文工作区为自定义目录（同进程未重启）
- **THEN** 它的上下文工作区与组上下文当前工作区逐字相等（自定义时不是默认主目录）

#### Scenario: 甲写的文件乙能读

- **WHEN** 成员「甲」在共享工作区写入一个文件
- **THEN** 随后发言的成员「乙」在读该路径时读到同一份内容

#### Scenario: 成员不是子运行

- **WHEN** 成员完成一轮
- **THEN** 数据库里没有指向该成员的 `parent_session_id` 子运行记录，且该成员实例与上下文仍可用（下一轮可直接发言）

### Requirement: 逐视图摘要的私有性

压缩 SHALL 以各成员自己的投影视图为对象（机制见 `context-compaction`）。每个成员的摘要 SHALL 按成员作用域存储，系统 SHALL NOT 存在服务全组的共享摘要。成员 B 的摘要生成输入（被折叠的文本**与参考上下文块**）SHALL 只含 B 的视图内内容；B SHALL NOT 能取到 A 的摘要、参考块或私有行。

摘要文本 SHALL 保留归属：由视图生成的摘要里，他人的发言仍是「Y 说」，SHALL NOT 被改写成第一人称。该纪律由摘要请求的系统文本常量携带，并 SHALL 有可失败断言（打**输入通道**：被折叠的文本里保留「Y 说」）。

#### Scenario: 两成员各存各的摘要

- **WHEN** 同一段原文分别触发「甲」「乙」视图的折叠
- **THEN** `summary_nodes` 里同一 span 出现两行，`member_id` 不同，两行文本互不影响

#### Scenario: B 的摘要输入没有 A 的私有内容

- **WHEN** 「甲」的私有工具轮被注入独特标记，随后「乙」的视图触发折叠
- **THEN** 「乙」这次摘要请求的输入（被折叠文本 + 参考上下文块）里不含该标记

#### Scenario: 参考上下文只来自本人作用域

- **WHEN** 「乙」的折叠需要参考更早的摘要
- **THEN** 候选只来自 `member_id = 乙` 的已持久化摘要；「甲」的摘要 SHALL NOT 出现在参考块里

#### Scenario: 摘要保留他人归属

- **WHEN** 「乙」的视图里出现「甲 说：…」并被折进摘要
- **THEN** 送回模型折叠的输入里仍是「甲 说：…」（归属不被改写），摘要文本也保留归属

#### Scenario: 不存在共享摘要

- **WHEN** 检查组会话的摘要行
- **THEN** 不存在 `member_id` 为空的摘要行（组会话的摘要必定按成员存储）

### Requirement: 群聊 RPC 面

核心 SHALL 提供 `group.create` / `group.update` / `group.chain` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（发言者可选）/ `group.view`（带成员 id）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员/原因），MUST NOT 静默失败或崩溃。

`group.create` SHALL 接受可选的 `reactionsEnabled`（布尔；省略 = 新建组默认开启）与 `maxRounds`（整数 1..50；省略 / null = 用产品默认）。

`group.update` SHALL 接受 `{groupId, reactionsEnabled?, maxRounds?}`，至少给一个字段；`reactionsEnabled` 必须布尔；`maxRounds` 必须是 1..50 的整数或显式 `null`（显式 null = 恢复默认，**与字段缺席不同**：缺席 = 不改）。类型不对 / 越界 / 一个字段都没给 SHALL 返回可归因错误（`-32602`）；反应链运行中 SHALL 返回可归因 busy（不排队）。它仍只做组设置，不扩成通用 update。

`group.list` SHALL 返回每个组的 id、标题、`reactionsEnabled`、`maxRounds`（整数或 null）、**`busy`（布尔）与 `runningMemberId`（字符串或 null）** 与成员清单：每个成员带成员 id、显示名、模板名、**已移除标记 `removedAt`**、`overrides`（工具子集 / 提示词追加 / 思考强度）与 `effective`（生效工具清单、生效思考模式与强度），供界面渲染**成员视图与成员名单**、选发言人与展示覆盖层效果；不额外增加“列成员”的方法。`busy` / `runningMemberId` 是只读状态，使 web 在断线重连后仍知道链在跑、该显示/取消谁。

`group.member.update` SHALL 原地更新成员（显示名 / 模板 / 覆盖层）并保持成员 id 不变；更新后 SHALL 重建该成员实例（先退役/销毁旧实例，再按新配置创建），使新的工具子集与提示词追加生效。

`group.send` 的 `speaker` SHALL 可选：带发言者 = 定向该成员（开启态强制必应；关闭态纯 speaker 仍是旧普通轮）；不带 = 开关开启时纯触发（写用户消息并起链），开关关闭时按用户消息里的 `@mention` 定向、没有 `@mention` 则拒绝。**发送 SHALL 异步且永不 busy**：完成同步前置校验与用户消息写入后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`（带文本时 `triggerSeq` 为用户消息 seq；speaker-only 时为 null，由链状态更新）；链执行器在跑时新请求入队/被吸收，不返回 busy 拒绝。发送结果 SHALL NOT 携带 `steps` / `rounds` / `finalText` / `memberId`，SHALL NOT 等待链结束。

**`group.chain`**：`{groupId}` SHALL 返回当前 / 最近一条链的状态 `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps, error}`。`status ∈ {idle, running, completed, cancelled, failed}`；`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`（运行中为 null）；`error` 为字符串或 null——链 `failed` 时 SHALL 非空且含可归因文本（如 `unknown_context` / 成员轮异常原因），使界面与测试能知道失败真因，MUST NOT 只返回 `failed` 而吞掉原因；`rounds` 只计反应轮；`steps` 是 0..N 条，封闭取值是：
- `source ∈ { speaker, mention, reaction }`；
- `status ∈ { replied, passed, forced_pass, forced_empty, empty, failed, cancelled }`；
- 另有 `memberId` / `triggerSeq` / `publicSeq` / `finalText` / `error`。

`group.chain` 在核心重启后为 `idle`（本进程内语义）。链进入终态时 SHALL 通过 `agent.event` 发一条 `group.chain.completed`（`type` 为该值，携带 `groupId` / `sessionId` / `status` / `stopReason` / `rounds` / `triggerSeq`）；这是群聊反应链引入的唯一新增事件类型，本 change 不新增事件类型；其余仍复用既有事件类型。链的 `steps` 只用于观察与测试，SHALL NOT 成为消息的第二份存储。

`group.view` SHALL 返回该成员**本次运行内最近一次真实发出**的上下文快照（`system` / `messages` / `tools` + 窗口与 breakdown）；该成员本次运行内从未发言时 SHALL 返回空（界面显示占位），SHALL NOT 用历史拼一份“没发过的上下文”。重启后视图为空属既定语义（与真实上下文视图的“自本次启动以来”先例一致）。请求失败 SHALL 返回可归因错误，使界面能区分“读取失败”与“从未发言”。

#### Scenario: 十个群聊方法可调用

- **WHEN** 客户端依次调用建组、改组、查链、列组、加成员、改成员、发消息、取成员视图、移除成员、删组
- **THEN** 每个方法返回结构化结果或可归因错误，通道不崩溃

#### Scenario: 列组带成员、组设置与覆盖层可观察字段

- **WHEN** 成员设置了工具子集与追加提示词后客户端调用 `group.list`
- **THEN** 该组项返回 `reactionsEnabled`、`maxRounds`、`busy`、`runningMemberId`，该成员项同时返回 `overrides` 与 `effective`（生效工具清单、生效思考强度）

#### Scenario: 改组开关

- **WHEN** 客户端调用 `group.update` 把 `reactionsEnabled` 改为 `false`
- **THEN** 返回更新后的会话（`reactionsEnabled = false`），再次 `group.list` 读到同一个值

#### Scenario: 改组上限与恢复默认

- **WHEN** 客户端调用 `group.update` 传 `maxRounds = 6`，再传 `maxRounds = null`
- **THEN** 第一次读回 6；第二次读回 null（= 用产品默认），`group.list` 与 `session.list` 都一致

#### Scenario: 改组参数非法或组不存在

- **WHEN** 客户端调用 `group.update` 时一个字段都没给、`reactionsEnabled` 非布尔、`maxRounds` 非整数/越界（0、51、负数）、或 `groupId` 不存在
- **THEN** 前三类返回 `-32602`（指明字段），组不存在返回带 `groupId` 的可归因错误；组设置不被改动

#### Scenario: 组项带忙碌状态

- **WHEN** 一条反应链正在跑时客户端调用 `group.list`
- **THEN** 该组项 `busy = true`，`runningMemberId` 是当前正在运行的成员 id（链在成员间隙时可为 null）；链结束后 `busy = false`

#### Scenario: 改成员重建实例

- **WHEN** 客户端用 `group.member.update` 修改某成员的工具子集
- **THEN** 成员 id 不变，其旧实例被销毁、按新配置重建，下一次发言的请求使用新工具清单

#### Scenario: 方法清单同步

- **WHEN** 核心启动注册群聊 RPC
- **THEN** `kCoreRpcMethodNames` 与实现一致（漏注册抛错），且网页文档的 RPC 表列出全部群聊方法（含 `group.chain`）

#### Scenario: 查链：空闲、运行中与终态

- **WHEN** 依次在没有链、链运行中、链结束后调用 `group.chain`
- **THEN** 分别返回 `status = idle`（steps 空、rounds 0）；`status = running`（stopReason null，steps 累积）；终态 `status` 与 `stopReason` 合法，steps 完整

#### Scenario: 发送在链结束前返回

- **WHEN** 客户端发一条会触发多轮反应的消息
- **THEN** `group.send` 在第一次模型调用完成前就返回 `status = started` 与 `triggerSeq`；此时 `group.chain` 为 `running`；链结束后才有 `stopReason`

#### Scenario: 省略发言者触发反应链

- **WHEN** 组的自发反应开启，客户端调用 `group.send` 时省略 `speaker`、只带文本
- **THEN** 调用立即返回 `started`；随后 `group.chain` 显示链在跑，公开时间线按反应展开，终态 `stopReason` 合法

#### Scenario: 没有可反应成员时链直接结束

- **WHEN** 组的自发反应开启、组里没有任何可反应成员，客户端带文本发送
- **THEN** 用户消息照常写入一条，`group.send` 返回 `started`；`group.chain` 很快进入 `completed`，`steps = []`、`rounds = 0`、`stopReason = no_members`，不返回错误、不写占位消息

#### Scenario: 取成员视图返回本次运行内最后一次真实发出的上下文

- **WHEN** 成员「甲」本次运行内发过一轮，客户端调用 `group.view(甲)`
- **THEN** 返回的快照 `messages` 与该轮实际发出的投影逐字一致（含归属前缀），`windowTokens` 是「甲」自己实例的窗口

#### Scenario: 没发过的成员返回空

- **WHEN** 成员「乙」加入后还没发过言（或应用已重启），客户端调用 `group.view(乙)`
- **THEN** 返回空结果，界面显示占位，而不是一份用历史拼出来的上下文

#### Scenario: 取成员视图失败可归因

- **WHEN** 客户端对某成员调用 `group.view` 且读取失败
- **THEN** 返回带成员 id 与原因的错误；界面据此显示“读取失败 + 重试”，不得把失败当成空快照

#### Scenario: 失败可归因

- **WHEN** 客户端对不存在的组或成员调用群聊方法
- **THEN** 返回带原因与对象 id 的 JSON-RPC 错误

### Requirement: web 组视图

web 客户端 SHALL 在**真实应用**里提供可达的组视图（不是只在测试挂架里存在的组件）。群聊 SHALL 作为**普通会话**打开：会话列表由应用壳常驻左侧，主区按选中会话的 `kind` 路由（列表常驻、主区切换与过期群响应丢弃的行为见 `web-chat-screen` 的「会话列表常驻左侧与主区切换」）；打开或切换群聊 MUST NOT 整屏替换单聊聊天屏、MUST NOT 卸载或隐藏会话列表。群聊数据未就绪时主区 SHALL 显示加载占位，MUST NOT 把上一个群的成员或消息挂到新会话标题下。

群聊主区 SHALL 提供 `[群聊 | 成员视图]` 双标签；切换标签 MUST NOT 改变会话列表，也 MUST NOT 重拉或修改数据。群聊 SHALL 包含：

1. **「群聊」标签**：
   - 公开时间线（按 `seq` 排列，每条带作者归属），位于**中间主列**；
   - 发送区（发言人选择、文本输入、发送按钮、链的一次性提示）位于主列时间线下方；
   - 成员名单位于时间线**右侧**（`id="group-members"`，供 `aria-controls` 引用），包含成员卡片、加入成员、覆盖层编辑与移除入口；成员名单 SHALL 显示正在流式的成员（「正在反应…」）；
   - 头部链活动指示 SHALL 追加正在流式的成员名（`streamingMembers`，链在成员间隙时用 `runningMemberId` 回退），使窄屏成员名单抽屉关闭时仍能看见“哪个成员在流式”；
   - 底部的「成员私有分栏」MUST NOT 存在；公开时间线 MUST NOT 被成员私有内容挤占垂直空间。
2. **「成员视图」标签**：
   - 成员选择器，列出全部成员（含已移除成员，标「（已移除）」）。已选成员只要仍在成员表里（包括 `removedAt` 非空的软删成员）SHALL 保持选中，使历史私有行可查；只有成员 id 从成员表消失时才回退到第一个未移除成员，没有未移除成员时选第一个成员，没有成员时显示空态；
   - 选中成员的私有过程行（栏头口径「仅该成员可见」；已移除成员的历史私有行仍有去处）；私有行为空时 SHALL 显示「本次已加载页里没有私有行」并给出「加载更早的消息」入口（有更早页时），MUST NOT 让用户误以为该成员从未有过私有过程；
   - 不在成员表里的作者（脏数据）SHALL 以只读「未知作者（数据异常）」横幅列出其私有行与行数，MUST NOT 静默丢行；
   - 选中成员的真实上下文状态 SHALL 区分 `loading` / `ok` / `empty` / `error`：`error` 显示可重试提示（重试只重拉该成员），MUST NOT 复用「本次运行内没发过言」的文案；`empty` 才显示没发过言的占位；`ok` 显示 `group.view` 返回的 `system` / `messages` / `tools` 原始 JSON（复用既有真实上下文视图组件）；
   - 选中成员的占用环（按该成员视图的 breakdown 与**该成员自己的窗口**，复用既有环组件与三瓣口径）；没有 breakdown 时 SHALL 显式说明、不画空环。
3. **自发反应开关与轮数上限**：显示并切换该组的 `reactionsEnabled`（新建组默认开启）；旁边显示「反应轮数上限」输入框（当前 `maxRounds`，为 null 时以默认值占位，范围 1..50，留空 = 恢复默认）；两项切换/保存 SHALL 走 `group.update`，链运行中 SHALL 禁用。
4. **操作面**：建组、加成员、编辑成员覆盖层（工具子集 / 提示词追加 / 思考强度）、选发言人并发送（`group.send` 的 `speaker`；开关开启时发言人 SHALL 可选，空 = 纯触发；**发送按钮 SHALL 永远可用，链运行中也能发**）、取消正在运行的反应链（**断线重连后仍可用**：用 `group.chain` 的 `running` / `group.list` 的 `busy` / `runningMemberId` 恢复判断，不只依赖本地发送状态）。
5. **响应式**：宽度低于产品既有的 `xl` 断点时，成员名单 SHALL 收起为可由头部「成员」按钮开合的抽屉；双标签与发送区 MUST 保持可用；群聊主区 MUST NOT 出现横向溢出。抽屉 MUST NOT 覆盖会话列表；`xl` 及以上 SHALL 以静态右列显示成员名单。跨断点时（窄屏打开抽屉后拉宽到 `xl`）抽屉 SHALL 被关闭或转为静态列，MUST NOT 留下无法关闭的浮层；「成员」按钮 SHALL 只在「群聊」标签渲染/可用，切到「成员视图」时 SHALL 关闭抽屉，`aria-expanded` MUST NOT 与实际可见状态不符。抽屉背景 MUST NOT 盖住头部标签（否则点头部标签会命中背景）；抽屉 SHALL 支持 Escape 关闭，并带 `role="dialog"` / `aria-modal` 与打开/关闭焦点处理。双标签 SHALL 用 `role="tablist"` / `role="tab"` / `role="tabpanel"` 并以 `aria-controls` 关联。
6. **滚动位置**：公开时间线、成员视图、成员名单三个滚动容器 SHALL 各自保存位置，并在切标签、开合抽屉后恢复（恢复必须发生在容器可见后）；只保存时间线不算完成。切换成员不会隐藏成员视图容器，不能拿它当滚动存档判据。
7. **提示游标**：换群 MUST NOT 依靠重建组件把链提示游标归零；旧群的链提示在切走再切回时 MUST NOT 重放；当前群视图挂载后新的链结束 SHALL 出提示（不承诺离开期间结束的链在回来时补提示）。

**异步发送**：`group.send` 返回 `started` 后界面 SHALL 立即解除“发送中”，但链可能仍在跑；**不存在“发送未开始/链忙不能发”的分支**，链运行中再发也照常接受（新用户消息写入、执行器吸收/排队）。链活动指示与取消按钮 SHALL 由 `started` 响应、`agent.streaming` / `assistant.message` 事件、`group.chain` 与 `group.chain.completed` 共同驱动。链终态为 `round_cap` 时 SHALL 显示「已达轮数上限（反应已停止；可继续点名，或调大该组的反应轮数上限）」；`all_passed` 不提示。链进行中页面 SHALL 显示活动指示（哪个成员正在流式）。

**提示可见性**：`forced_pass` / `forced_empty` / `round_cap` 的一次性提示仍在群聊标签发送区上方；当提示产生时用户正在「成员视图」标签，群聊标签 SHALL 显示未读标记（`data-unread="true"` 与可见小点），切回群聊后显示提示并清除标记，MUST NOT 让提示只在隐藏面板里静默存在。

反应链 SHALL 在界面上**逐步展开**：每位成员的公开回复落库后时间线新增一条，其私有工具过程落进该成员的成员视图数据；事件路由 SHALL 以 payload 为准：`group.send` 的参数带 `speaker`（可空）；**成员运行**产生的 `agent.event` 带 `groupId` / `memberId`，私有内容 SHALL 按这两个字段归位；**组服务自己写入的** `user.message` 只带 `groupId`（没有成员可归），落到公开时间线。e2e 验收 SHALL 以 payload 为判据（DOM 选中值只作辅助，不能作为唯一证据）。

**关闭态的发送例外**：开关关闭时，文本里含 `@` 允许空发言人（`@` 是否有效由核心裁决，前端 SHALL NOT 复制 mention 解析规则）；文本不含 `@` 且没有 speaker 时前端 SHALL 拒绝并给出可归因提示（旧本地校验），最终以核心错误为准。`forced_pass` / `forced_empty` 的提示 SHALL 在链结束后从 `group.chain` 的 `steps` 读取，**刷新后不再显示**（没有对应公开行）；文档写明这个已知限制。

用户消息与全部成员的公开回复 SHALL 可见并带归属。Flutter 侧本期 SHALL NOT 被要求提供组界面：组会话在 Flutter 的会话列表里可见，但打开时 SHALL 显示「请在 web 组视图打开」的占位，不进入单 Agent 对话界面。

#### Scenario: 会话列表按 kind 分流且不消失

- **WHEN** 用户在 web 端打开一个组会话
- **THEN** 主区进入组视图（公开时间线 + 右侧成员名单），而左侧会话列表仍然可见、仍可点击其它会话，不会因为打开群聊而消失

#### Scenario: 打开群聊看到时间线与右侧成员名单

- **WHEN** 用户打开一个含两个成员的组
- **THEN** 「群聊」标签显示公开时间线，成员「甲」「乙」的名单位于时间线右侧；页面底部不再有「成员私有分栏」，时间线垂直空间不被它挤占

#### Scenario: 已移除成员仍可在成员视图查看且保持选中

- **WHEN** 一个组里有已移除的成员「甲」，用户在成员视图选中它后又触发一次成员表刷新
- **THEN** 成员选择器仍列出「甲（已移除）」，且「甲」仍是当前选中项；选中它能看到它的历史私有行，不丢行也不因为 `removedAt` 非空自动跳走

#### Scenario: 成员视图标签展示选中成员的上下文与占用环

- **WHEN** 用户在「成员视图」标签选择成员「甲」
- **THEN** 页面显示「甲」的私有过程行、`group.view(甲)` 的 `system` / `messages` / `tools` 原始 JSON（可滚可复制）与占用环；环的分母是「甲」自己实例的窗口，不是共享分母或别的成员的窗口

#### Scenario: 快照读取失败不伪装成没发过言

- **WHEN** 成员「甲」有真实发言，但 `group.view(甲)` 本次请求抛错
- **THEN** 成员视图显示 `member-snapshot-error` 与可点击的「重试」；MUST NOT 显示「本次运行内没发过言」，也 MUST NOT 画空环

#### Scenario: 快照空态与加载态可区分

- **WHEN** 成员「乙」本次运行内确实没发过言，或该成员快照仍在加载
- **THEN** 没发过言时显示 `member-no-snapshot` 占位；加载中显示 `member-snapshot-loading`；两者都不显示成对方的文案

#### Scenario: 没发过言的成员显示占位

- **WHEN** 某个成员还没发过言（或应用重启后），用户在该成员视图里选中它
- **THEN** 真实上下文区域显示显式占位、环不渲染（与既有“没有快照不画环”一致），不把空数据画成 0

#### Scenario: 底部分栏不再挤占主聊天

- **WHEN** 用户打开一个有多个成员的群聊
- **THEN** 页面不存在底部「成员私有分栏」容器；公开时间线一直延伸到发送区上方，成员私有内容只在「成员视图」标签内出现

#### Scenario: 双标签切换不改会话列表与状态

- **WHEN** 用户在「群聊」与「成员视图」之间来回切换
- **THEN** 主区显示对应标签的内容，左侧会话列表与当前选中的群会话保持不变，不重新拉取会话列表、不丢失标签页外的链状态、草稿与时间线滚动位置

#### Scenario: 私有行空态与加载更早

- **WHEN** 选中成员的私有行只存在于更早的消息页，当前页没有
- **THEN** 成员视图显示「本次已加载页里没有私有行」与「加载更早的消息」；点击后取回更早页，该成员的私有行出现在成员视图里

#### Scenario: 未知作者私有行有去处

- **WHEN** 当前页出现一条 `visibility = private-to-author`、但 `author` 不在 `group.list` 成员表里的行
- **THEN** 成员视图的「未知作者（数据异常）」只读横幅列出该行（或至少它的行数），该行不被静默丢弃，也不被伪造成一个正常成员

#### Scenario: breakdown 缺失不画空环

- **WHEN** 某个成员有快照但 `breakdown` 为 `null`
- **THEN** 成员视图显示 `member-no-breakdown` 的显式说明，且不渲染 `context-ring`，不把缺失数据画成 0

#### Scenario: 窄屏成员名单收起为抽屉且流式成员名可见

- **WHEN** 浏览器宽度低于既有 `xl` 断点，用户打开一个群聊，且链正在让「甲」流式
- **THEN** 成员名单默认收起，头部出现「成员」按钮；`reaction-active` 文案包含正在流式的成员名「甲」；点开「成员」后成员名单以右侧抽屉出现，关闭后消失；双标签与发送区仍可用，页面没有横向溢出，会话列表仍可见

#### Scenario: 抽屉背景不盖住头部标签

- **WHEN** 720px 打开成员抽屉，然后点头部「成员视图」标签
- **THEN** 点击按真实命中生效（不是落到背景），标签切到「成员视图」、抽屉关闭；再点「群聊」时抽屉仍关闭

#### Scenario: 抽屉跨断点可收

- **WHEN** 用户在 720px 打开成员抽屉，然后把视口拉宽到 1280px，再缩回 720px
- **THEN** 拉宽后成员名单变为静态右列，背景/关闭按钮/「成员」切换按钮不可见，不残留 absolute 浮层；缩回窄屏时抽屉保持关闭

#### Scenario: 抽屉可访问

- **WHEN** 用户打开成员抽屉后按 Escape，或检查抽屉语义
- **THEN** Escape 关闭抽屉，焦点回到「成员」按钮；抽屉有 `role="dialog"` 与 `aria-modal`，监听器在卸载/换群后不累积

#### Scenario: 成员视图标签下成员按钮不空转

- **WHEN** 用户切到「成员视图」标签
- **THEN** 群聊头部的「成员」切换按钮不存在或不可用，`aria-expanded` 不谎报抽屉已开；再切回「群聊」时抽屉是关闭的

#### Scenario: 成员视图与名单滚动位置恢复

- **WHEN** 用户把成员视图或成员名单滚到中段（容器确实可滚，`scrollHeight > clientHeight` 且 `scrollTop > 0`），然后切标签或开关抽屉再回来
- **THEN** 对应容器的 `scrollTop` 恢复到离开时的位置，不被重置到顶部；切换成员不作为该判据

#### Scenario: 换群不重放旧链提示

- **WHEN** A 组链结束并显示过提示，用户切到 B 组再切回 A 组；等 A 的 `group.chain` 响应与两帧渲染后再断言
- **THEN** A 的旧提示不再重放；A 组视图挂载后新的链结束仍显示提示；不承诺离开期间结束的链在回来时补提示，换群也不依赖 `key` 重建

#### Scenario: 群聊数据未就绪显示占位

- **WHEN** 用户从一个群聊切到另一个群聊，新群的 `group.list` / 消息尚未返回
- **THEN** 主区显示群聊加载占位，不显示上一个群的标题、成员或消息；数据到达后再显示新群内容

#### Scenario: 群聊重载失败保留已加载内容

- **WHEN** 群聊已成功显示时间线与成员，随后一次 `onReload`（例如切开关后的重拉）的 `group.list` / `message.query` 失败
- **THEN** 时间线、成员、游标与快照仍保留，页面显示错误条，不退回 `group-loading`；链状态与流式成员清空，取消按钮不被旧链误启用；只有首屏首次失败才占位

#### Scenario: 成员视图里链结束的提示有未读标记

- **WHEN** 用户停留在「成员视图」标签，链以 `round_cap` 或 `forced_pass` / `forced_empty` 结束
- **THEN** 「群聊」标签显示未读点（`data-unread="true"`）；切回群聊后看到对应提示，提示不再隐藏在隐藏面板里

#### Scenario: 建组/加成员/编辑覆盖层/点名发送都可在界面上完成

- **WHEN** 用户从组视图建组、加两个成员、把其中一个的工具子集收紧、点名该成员发言
- **THEN** 四件事都经 `group.*` RPC 完成，界面显示该成员的生效工具清单与已发出的发言

#### Scenario: 新建组默认开启自发反应

- **WHEN** 用户新建一个组并进入组视图
- **THEN** 「自发反应」开关显示为开启，且 `group.list` 返回的 `reactionsEnabled` 为 `true`

#### Scenario: 切换自发反应开关

- **WHEN** 用户在组视图里关闭「自发反应」开关
- **THEN** 界面发出 `group.update`（参数 `reactionsEnabled` 为 `false`），重拉后开关显示关闭

#### Scenario: 修改轮数上限

- **WHEN** 用户在「反应轮数上限」输入框里填 6 并保存，随后清空再保存
- **THEN** 第一次 `group.update` 的 payload 带 `maxRounds = 6`；第二次带 `maxRounds = null`（恢复默认）；重拉后输入框分别显示 6 与默认值占位

#### Scenario: 开关开启时不选发言人即可发送

- **WHEN** 自发反应开启，用户不选发言人、只输入一条消息并发送
- **THEN** `group.send` 的 payload 里没有 `speaker`（或为空）；界面在收到 `started` 后立即解除“发送中”，时间线随后逐个出现成员的公开回复

#### Scenario: 发送态在 started 后解除

- **WHEN** 客户端发一条会触发多轮反应的消息，链尚未结束
- **THEN** 收到 `status = started` 后界面不再显示“发送中”；链活动指示与取消按钮仍可用（由 `group.chain` / 事件 / `busy` 驱动）

#### Scenario: 链运行中发送按钮仍可用

- **WHEN** 链正在跑，用户输入一条新消息并点发送
- **THEN** 发送按钮不因链在跑被禁用/拦截；`group.send` 返回 `started`，新用户消息写入并出现在时间线，执行器吸收它

#### Scenario: 不再有发送未开始的 busy 提示

- **WHEN** 客户端在链运行中发送
- **THEN** 界面不显示「发送未开始 / 组忙」之类的拒绝提示；只有参数/上下文错误（如关闭态无 speaker 且无 @）才显示可归因错误

#### Scenario: 反应链逐步展开

- **WHEN** 一条用户消息触发反应链，成员依次公开回复并分别调用工具
- **THEN** 时间线逐条新增公开回复，每个成员的私有工具行在其成员视图数据里可见；链进行中页面显示活动指示与正在流式的成员名（成员名单上有「正在反应…」，头部也有名字）

#### Scenario: 达到轮数上限的提示

- **WHEN** 链以 `stopReason = round_cap` 结束
- **THEN** 页面显示「已达轮数上限」提示；链状态与 `group.chain` 一致，后续点名仍可发送

#### Scenario: 取消停链

- **WHEN** 反应链进行中用户点「取消」
- **THEN** 界面发出 `agent.cancel`（组会话 id），链停止，不再出现新的公开回复

#### Scenario: 断线重连后仍能取消

- **WHEN** 反应链进行中 WS 断线重连，本地发送状态已丢失
- **THEN** 重拉 `group.chain` 得到 `status = running`（或 `group.list` 的 `busy = true`），「取消」按钮仍可用；点击发出 `agent.cancel` 并停链

#### Scenario: 关闭态含 @ 时空发言人可发送

- **WHEN** 自发反应关闭，用户不选发言人、输入一条含 `@乙` 的文本并发送
- **THEN** 前端放行该发送（不因缺 speaker 本地拦截），核心按 `@mention` 只跑「乙」；若核心判定 `@` 无效则返回可归因错误

#### Scenario: 被点名者不回应只提示本次结果

- **WHEN** 链结束后 `group.chain` 的 `steps` 里有 `forced_pass` / `forced_empty`
- **THEN** 页面显示可归因提示，且不新增任何公开行；刷新页面后该提示不再出现（历史里没有它）

#### Scenario: 每成员占用环各用自己窗口

- **WHEN** 「甲」与「乙」的模型窗口分别是 1000000 与 200000
- **THEN** 在成员视图分别选中两人时，两个环的分母分别是各自实例的窗口（`member-window` 分别显示 1000000 / 200000），各按自己的 breakdown 绘制，不共用一个分母

#### Scenario: 事件按 payload 归位

- **WHEN** 两个成员先后发言
- **THEN** 每个成员的流式/工具/消息事件按 `memberId` 落到该成员的成员视图数据，公开回复按 `groupId` 落到时间线（e2e 断言 payload 字段，不只看 DOM 选中的成员）

#### Scenario: 加载页内的行都有归属去处

- **WHEN** 客户端加载一页消息
- **THEN** 每条行都能按 `author` / `visibility` 落到公开时间线或某个成员的成员视图数据（含已移除成员）；不在成员表的私有行落到只读「未知作者」横幅，不丢行、不重复显示

### Requirement: 隐私硬边界

成员的真实上下文快照（`toRawJson`，**含摘要层**）SHALL NOT 包含其他成员的私有内容。投影是唯一出口：任何其他路径（**摘要请求的被折叠文本与参考上下文块**、事件 payload 里的上下文、RPC 返回给成员模型的内容）SHALL NOT 让成员模型看到他人的私有行。

该边界 SHALL 有可失败的验收，且红靶 SHALL 打**输入通道**（摘要请求实际收到的 folded 文本与参考块、投影函数产出的 messages），而不是只断言摘要的模型输出文本 —— 摘要文本是模型产出，用假 provider 固定文本或真模型改写它都会让断言假绿或假红。摘要文本断言只作附加证据。

#### Scenario: B 的视图不含 A 的标记

- **WHEN** A 的私有工具轮里带独特标记，B 的视图被装配
- **THEN** B 的请求 messages 里搜不到该标记

#### Scenario: B 的快照不含 A 的标记

- **WHEN** B 发言后读取它的真实上下文快照 `toRawJson`
- **THEN** 该 JSON 里搜不到 A 的标记

#### Scenario: B 的摘要输入通道不含 A 的标记

- **WHEN** B 的视图已触发一次摘要，A 的私有工具轮带独特标记
- **THEN** B 这次摘要请求实际收到的输入（被折叠文本 + 参考上下文块）里搜不到该标记（参考块漏掉成员作用域时此用例必须变红）

#### Scenario: A 自己的视图里标记仍然存在

- **WHEN** 装配 A 自己的视图
- **THEN** 该标记出现在 A 的请求里（证明标记确实被写入，而不是"两边都丢"也能过）

### Requirement: 成员视图按需装配与规模前置

成员视图 SHALL 按 `seq` 区间从原文增量装配，SHALL NOT 复用"把整条会话历史全量载入并常驻"的路径。被该成员摘要覆盖的区间 SHALL 按需读取，SHALL NOT 常驻。驻留内存的视图内容 SHALL 由该成员的阈值 `T`（该成员模型窗口 × 配置百分比）界定：视图超过 `T` 的内容由该成员自己的压缩折叠进摘要。

公开原文的行解析结果 SHALL 可跨成员复用（同一行在多个视图里只解析一次）；私有回放 SHALL 按成员各一份。**派生缓存的生命周期 SHALL 跟随驻留视图**：缓存只保留当前驻留视图的 seq 并集对应的条目，行被摘要覆盖或离开视图即淘汰，SHALL NOT 随会话全长无限增长（否则"驻留由 `T` 界定"被缓存绕过）。

任何缓存容量、批大小或上下限 SHALL NOT 是写死的魔数：它 SHALL 属于四类出处之一（用户明确要求、产品既有常量、平台/接口硬限、`Docs/user-guide/configuration.md` 配置表登记过的配置键）；写不出出处 SHALL 做成配置项并登记，MUST NOT 直接写进实现。

#### Scenario: 装配不触发全量查询

- **WHEN** 用一个"被要求全量读取整条会话就抛错"的消息仓库注入成员视图装配
- **THEN** 装配成功完成（证明它按 seq 区间读，没有走全量查询）

#### Scenario: 阈值随成员窗口派生

- **WHEN** 同一段历史分别由 1M 窗口与 200k 窗口的成员视图压缩
- **THEN** 两者派生出不同的 `T`，折叠批次数随窗口变化（不是写死的批数）

#### Scenario: 公开解析结果跨成员复用

- **WHEN** 两个成员的视图都包含同一条公开消息
- **THEN** 该行的解析只发生一次（用计数观察，公共缓存命中；两个视图各自的结果仍正确）

#### Scenario: 缓存不随会话全长增长

- **WHEN** 一个长会话里大部分行已被该成员摘要覆盖、早已离开驻留视图
- **THEN** 解析缓存的条目数只与当前驻留视图的 seq 并集相当，不随原文总行数增长

#### Scenario: 不引入无出处魔数

- **WHEN** 审阅实现里的缓存容量与批大小
- **THEN** 每个数字都能指到四类出处之一，或对应一个在配置文档里登记的配置键；否则该实现不合格

### Requirement: 自发反应开关与默认值

每个组会话 SHALL 有一个持久布尔开关 `reactions_enabled`（`sessions` 表的列，JSON `reactionsEnabled`）：开启 = 每条公开消息都成为反应刺激（轮内串行可见，下一轮触发取轮末最后一条公开 seq）；关闭 = 只有被点名（`speaker` 或用户消息里的 `@mention`）的成员运行，不触发反应链。**新建组 SHALL 默认开启（true）**；v9→v11 迁移（v9→v10 段加开关列并回填）SHALL 把**既有组行回填为关闭（false）**，使升级不改变旧组体验。单会话行也带该列，但其值 SHALL NOT 影响任何行为。该开关 SHALL NOT 是 `config.json` 配置键（它是数据库列）。`group.create` MAY 带 `reactionsEnabled`；`group.update` SHALL 能改它；反应链运行中改开关 SHALL 返回可归因 busy（不排队、不改到链中途）。

#### Scenario: 新建组默认开启

- **WHEN** 客户端调用 `group.create` 且不带 `reactionsEnabled`
- **THEN** 新组行的 `reactions_enabled` 为 1，`group.list` 返回 `reactionsEnabled = true`

#### Scenario: 关闭后是安静态

- **WHEN** 客户端调用 `group.update` 把某组改为 `reactionsEnabled = false`，随后带文本发送但不点名
- **THEN** 该发送被拒绝（`no_speaker`），不触发任何反应轮；重读 `group.list` 仍是 `false`

#### Scenario: 旧组升级后是安静态

- **WHEN** 一个 v9 数据库里的既有组升级到 v10 后被 `group.list` 读出
- **THEN** 该组 `reactionsEnabled = false`，旧点名行为不变

#### Scenario: 开关不是 config.json 键

- **WHEN** 审阅配置文档与配置解析路径
- **THEN** 不存在 `reactions_enabled` / `reactionsEnabled` 配置键；它只出现在 `sessions` 列、RPC 参数/结果与组视图里

#### Scenario: 链运行中改开关被拒

- **WHEN** 反应链正在运行，客户端调用 `group.update` 改 `reactionsEnabled`
- **THEN** 返回可归因 busy，开关值不变，链继续

### Requirement: 反应轮数上限可配置（每组）

每个组会话 SHALL 有一个可空的反应轮数上限 `max_reaction_rounds`（`sessions` 表的列，JSON `maxRounds`；`NULL` = 用产品默认值）。产品默认值 SHALL 是代码常量（建议起点 8，依据见 design D13），允许范围 SHALL 是 **1..50**；`null` / 空值时链使用默认值。它是**组设置，不是 `config.json` 键**（与 `reactions_enabled` 同层）。

- `group.create` / `group.update` SHALL 接受 `maxRounds`（整数 1..50 或 `null`；`group.update` 中显式 `null` = 恢复默认，字段缺席 = 不改；越界 / 非整数 ⇒ `-32602`）。
- `group.list` / `session.list` SHALL 序列化 `maxRounds`（整数或 null）。
- web 组视图 SHALL 在自发反应开关旁提供「反应轮数上限」输入框（`data-testid = group-round-cap`），显示当前值；`null` 时以默认值占位；留空 = 恢复默认；保存走 `group.update`；链运行中禁用。
- `GroupService` SHALL 在执行器每次吸收用户触发时读该组的 `maxRounds ?? 产品默认`；`maxRounds` 是**每条用户触发一份反应预算**——用户新发一条消息（带文本或 speaker-only 的用户动作）重置 `rounds = 0`；agent 自己的公开回复不重置；没有新用户消息的纯 agent 链受同一预算约束。被 `@` 点名的强制成员属于首个反应轮，只计一轮；显式 `speaker` 定向轮与安静态 `@mention` 定向轮不计数、不被拦截。
- **队列为空**且当前用户触发的反应轮数达上限时，链 SHALL 以 `stopReason = round_cap` 优雅停止（不是报错）；若队列里已有新的用户请求，执行器先吸收它、重置预算，不误报 `round_cap`。后续点名 / 定向发送照常可用。

#### Scenario: 新建组上限为空时使用默认

- **WHEN** 新建组的 `max_reaction_rounds` 为 NULL，链开始运行
- **THEN** 该链使用产品默认上限（8）；`group.list` 的 `maxRounds` 为 null，界面输入框显示默认占位

#### Scenario: 设置上限后链在达到上限时停

- **WHEN** 把某组 `maxRounds` 设为 3，链连续每轮都有人回复
- **THEN** 第 3 个反应轮后链以 `stopReason = round_cap` 结束；第 4 轮不开始，不返回错误

#### Scenario: 留空恢复默认

- **WHEN** 客户端把 `maxRounds` 更新为 `null`
- **THEN** 库里 `max_reaction_rounds` 为 NULL，下一次链使用产品默认 8，`group.list` 读回 null

#### Scenario: 非法上限被拒

- **WHEN** 客户端把 `maxRounds` 设为 0、51、负数或非整数
- **THEN** 返回 `-32602`，组设置不变，链仍按原值运行

#### Scenario: 上限不是 config.json 键

- **WHEN** 审阅 `configuration.md`、`group-chat.md` 与配置解析路径
- **THEN** 文档写明 `max_reaction_rounds` / `maxRounds` 是组设置（`sessions` 列），不是 `config.json` 键；配置表里没有它

#### Scenario: 界面上改上限

- **WHEN** 用户在组视图的「反应轮数上限」输入框填 6 并保存
- **THEN** 界面发出 `group.update`，payload 的 `maxRounds` 为 6；重拉后输入框显示 6

### Requirement: 公开消息触发反应轮

开关开启时，组内**每一条公开消息**（用户消息，或成员正常完成的最终公开回复）SHALL 成为反应刺激：用户消息 SHALL 启动一轮反应；同一轮内，后跑成员 SHALL 在视图里看到先跑成员的公开回复（因此每条成员公开回复都被反应，不是只对用户消息反应）；链的下一轮触发 SHALL 取**该轮最后一条公开消息**的 `seq`，MUST NOT 把轮内每条回复再各自排成独立的一轮。反应轮 SHALL 选择：仍在组里（`removed_at` 为空）、不是该公开消息作者、`lastReactedSeq` 小于该消息 `seq` 的成员；**本次发送用户文本里被 `@显示名` 点名的成员** SHALL 在首个反应轮排在最前（按点名出现顺序；首个反应轮的触发可以是该用户消息，也可以是 speaker 对该用户消息的公开回复），其余 SHALL 按加入顺序（`created_at`，`rowid` 兜底）。参与成员的范围 SHALL 在链开始时快照：链运行中新加入的成员 SHALL NOT 加入当前链（下一次触发才参与）。成员 SHALL 串行运行：后跑成员的视图 SHALL 已包含先跑成员的公开回复。没有可反应成员时链 SHALL 直接结束（不是错误、不写占位消息；`group.send` 只返回 `started`，`group.chain` 终态 `steps = []`、`rounds = 0`、`stopReason = no_members`）。成员轮硬失败 SHALL 中止链并回报失败：若失败产生了公开 `Error: …` 行，该行 SHALL NOT 触发下一轮；即使失败没有写任何公开行（未预期异常 / 工具轮上限等路径），也 SHALL 以 `group.chain` 的 failed 状态与 `turn.failed` 可归因。

#### Scenario: 用户消息触发反应轮

- **WHEN** 自发反应开启，用户发一条消息（不点名）
- **THEN** 组内可反应成员按顺序各跑一轮，各自产生一条公开回复或 PASS

#### Scenario: 成员公开回复触发下一轮

- **WHEN** 成员「甲」产生一条公开回复，且后面还有可反应成员
- **THEN** 后跑成员在**同一轮**的视图里已经能看到「甲 说：…」并据此反应；这一轮结束后触发取轮末最后一条公开消息的 seq，继续下一轮

#### Scenario: 轮末最后一条决定下一触发

- **WHEN** 同一轮里「甲」先公开回复、「乙」后公开回复
- **THEN** 「乙」的视图包含「甲 说：…」；下一轮触发是「乙」那条回复的 seq（不是甲、乙各再起一轮）

#### Scenario: 作者不反应自己

- **WHEN** 触发公开消息的作者是「甲」
- **THEN** 「甲」不在这一轮的可反应成员里，不产生对自己消息的反应轮

#### Scenario: 已移除成员不反应

- **WHEN** 组里有已移除成员「甲」，一条公开消息触发反应轮
- **THEN** 「甲」不被选中、不产生消息行

#### Scenario: 串行可见性

- **WHEN** 同一轮里「乙」先于「丙」反应，且「乙」公开回复了一条评价
- **THEN** 「丙」这一轮的视图（实际请求的 messages）里包含「乙 说：…」那条评价

#### Scenario: 没有可反应成员时直接结束

- **WHEN** 组里只剩消息作者自己（或其他成员都已移除），一条公开消息触发反应轮
- **THEN** 链立即结束：`group.chain` 为 `completed`、`steps = []`、`rounds = 0`、`stopReason = no_members`；`group.send` 只返回 `started`，不返回错误、不写占位消息

#### Scenario: 链中新加入的成员不加入当前链

- **WHEN** 一条反应链运行中，用户新加了一个成员
- **THEN** 当前链的步骤里不出现该新成员；它从下一次公开消息触发起才参与

#### Scenario: 错误行不触发下一轮

- **WHEN** 某个成员的反应轮硬失败，Agent 写入一条公开的 `Error: …` 行
- **THEN** 链中止，不再有成员针对这条错误行反应；`group.send` 结果为 failed 并带错误

#### Scenario: 没有错误行的失败也中止链

- **WHEN** 某个成员的反应轮硬失败但没有写任何公开错误行（例如未预期异常 / 工具轮上限）
- **THEN** 链同样中止，`group.send` 为 failed 并带该成员的 `memberId` 与错误；后续成员不再运行

#### Scenario: speaker 回复或 PASS 都让 mention 在首轮强制

- **WHEN** 自发反应开启，点名「甲」且用户文本里 `@乙`；甲产生公开回复，或甲 `group_react {pass:true}`/空 `message`
- **THEN** 两种情况下「乙」都在首个反应轮被强制（source=`mention`），且必须给出公开回复（status=`replied`、有 publicSeq）

### Requirement: 反应轮与结构化 PASS 标记（group_react 工具）

反应轮 SHALL 是完整 Agent 轮：成员 MAY 调用工具；思考与工具过程 SHALL 落 `private-to-author` 行；最终公开行仍只存正文（`tool_calls` / `thinking_json` 为 NULL）。**沉默判定 SHALL 读结构化标记，MUST NOT 靠文本匹配**：

- 每个反应轮（开启态自愿轮、开启态 speaker 强制轮、两态 `@mention` 强制轮）的请求 SHALL 注入一个**终态控制工具** `group_react`，`input_schema` 为 `{pass: boolean, message: string}`（两者必填；`pass=true` 时 `message` 可空且被忽略）。
- 模型 MUST 在结束本轮时调用 `group_react` **恰好一次**，作为终态调用；Agent 模型循环 SHALL 拦截该调用并结束本轮，MUST NOT 把它当普通工具执行、MUST NOT 为它写 tool 行。
- `pass=true` ⇒ 本轮沉默：SHALL NOT 写公开行、SHALL NOT 发 `assistant.message`；无论 `message` 写了什么（包括「我这回合不发言，等其它模型」这类元话术）都 SHALL 被吞掉。
- `pass=false` ⇒ 本轮发言：公开行 SHALL 写 `message` 字段内容（不是模型正文里的解释），空 `message` 走空输出分支。
- 反应轮模型正文里的叙述（包括「我选择 PASS」「[PASS]」）SHALL NOT 直接进入公开时间线；只有 `message` 字段能成为公开内容。
- **没有调用 `group_react`、调用参数非法、或同一轮多次调用** ⇒ SHALL 先**纠正重试**：向模型回一条 user 轮纠正消息（类比工具执行失败的错误反馈，说明必须调用 `group_react {pass, message}`、请重新调用），然后继续模型循环；纠正重试上限是产品常量 `kMaxGroupReactRetries`（2 次，按成员轮累计，自愿轮与强制轮都适用）。**超过上限仍不合规**才该步记 `failed`（带可归因 `error`，如 `missing_group_react` / `invalid_group_react`），SHALL NOT 写公开行；**任何情况下都 SHALL NOT 回退到 `[PASS]` 文本匹配**。
- 旧的 `isReactionPass` 文本全等逻辑与 `[PASS]` 哨兵主路径 SHALL 废弃（`kGroupPassSentinel` 不再参与判定）；普通轮（关闭态纯 speaker、单会话）不注入 `group_react`，`[PASS]` 按旧行为是普通正文。

**适用面**：开启态 speaker 强制轮、两态 `@mention` 强制轮、开启态自愿反应轮 SHALL 注入并解析 `group_react`；**关闭态纯 speaker（无 @）普通轮 SHALL NOT 注入、不做结构化判定**。强制轮 `pass=true` ⇒ `forced_pass`；强制轮 `pass=false` + `message` 空 ⇒ `forced_empty`；自愿轮 `pass=false` + `message` 空 ⇒ `empty`；三者都 SHALL NOT 写公开行。`forced_pass` / `forced_empty` SHALL NOT 用 `turn.failed` 表达，只在 `group.chain` 的 `steps` 里可观察。私有工具轮在沉默/空输出时 SHALL 照常落库。

#### Scenario: pass=true 吞掉元话术

- **WHEN** 某成员的反应轮调用 `group_react {pass: true, message: "我这回合不发言，等其它模型"}`
- **THEN** 不写公开消息行、不发 `assistant.message`，步状态为 `passed`；该元话术不出现在时间线

#### Scenario: pass=false 公开 message 内容

- **WHEN** 某成员调用 `group_react {pass: false, message: "我同意，但路径应改成 lib/b.dart"}`
- **THEN** 公开行内容为该 `message` 字段，步状态为 `replied`；模型正文里的其它解释不进入公开行

#### Scenario: 正文说“我 PASS”但 pass=true

- **WHEN** 模型正文写「我选择 PASS，等大家」，但 `group_react.pass = true`
- **THEN** 以结构化标记为准：沉默，不写公开行；文本叙述被忽略

#### Scenario: pass=false 但 message 为空

- **WHEN** 成员调用 `group_react {pass: false, message: ""}`
- **THEN** 不写公开行；自愿轮记 `empty`，强制轮记 `forced_empty`

#### Scenario: 强制轮 pass=true 记 forced_pass

- **WHEN** 开启态 speaker 强制轮或 `@mention` 强制轮调用 `group_react {pass: true, ...}`
- **THEN** 不写公开行，步状态为 `forced_pass`（可归因失败）；`group.chain` 可观察，SHALL NOT 发 `turn.failed`

#### Scenario: 缺少 group_react 先纠正重试

- **WHEN** 某反应轮结束前没有调用 `group_react`（或参数非法）
- **THEN** SHALL 向模型回一条纠正消息并继续模型循环（类似工具失败反馈），计数一次；若重试后调用合规 ⇒ 按 `pass`/`message` 正常收尾（`replied`/`passed`/`empty`），不记 `failed`

#### Scenario: 重试超限仍不合规

- **WHEN** 一条反应轮在 `kMaxGroupReactRetries` 次纠正后仍未正确调用 `group_react`
- **THEN** 该步记 `failed`、带可归因 `error`，不写公开行；**不回退到文本匹配**，期间所有模型正文（含元话术）都不进入时间线

#### Scenario: 纠正重试不泄漏元话术

- **WHEN** 模型首次只写「我这回合不发言」而没有调用 `group_react`，重试后调用 `pass=true`
- **THEN** 不写公开行；首次的元话术与 `pass=true` 的 `message` 都不出现在时间线

#### Scenario: 结构化 PASS 的私有工具轮仍落库

- **WHEN** 某成员先调用一次普通工具（产生私有行）后调用 `group_react {pass: true}`
- **THEN** 私有工具行仍在库中（`private-to-author`、作者为该成员），只是没有公开行；`group_react` 本身不写 tool 行

#### Scenario: 反应轮正文里的 [PASS] 不是哨兵

- **WHEN** 某成员正文写 `[PASS]` 但调用的是 `group_react {pass: false, message: "..."}`
- **THEN** 按 `pass=false` 公开 `message`；正文里的 `[PASS]` 不触发沉默，也不进入公开行

#### Scenario: 关闭态纯 speaker 的 [PASS] 是普通正文

- **WHEN** 自发反应关闭，用户点名「甲」且文本里没有 `@mention`；「甲」的输出恰为 `[PASS]`
- **THEN** 不注入 `group_react`、不做结构化判定，该文本按旧行为作为普通公开回复落行并可见

#### Scenario: 普通轮的空白正文保持旧行为

- **WHEN** 单会话轮或关闭态纯 speaker 轮的最终内容是纯空白
- **THEN** 走既有 `isNotEmpty` 路径，行为与本 change 前逐字一致（反应轮的结构化口径不扩散到普通轮）

### Requirement: 反应提示词常量

**开启态自愿反应轮** SHALL 在成员系统提示词末尾追加代码常量 `kGroupReactionPrompt`；**开启态 speaker 强制轮**与**两态下 `@mention` 强制轮** SHALL 追加代码常量 `kGroupMustRespondPrompt`。两段提示词都 SHALL 指示模型**用 `group_react` 工具**返回 `{pass, message}` 作为本轮终态决定，MUST NOT 让模型用正文叙述决定。`kGroupReactionPrompt` MUST 采用「**默认沉默**」框架并覆盖：

1. **沉默是常态、发言是例外**：大多数轮应返回 `group_react {pass: true, message: ""}`；只有当你有一条**非说不可、别人没说过的实质新信息**时才返回 `pass: false` 并写 `message`；`pass=true` 不是失败，是群聊礼仪。
2. **few-shot 的 pass=true 情形（3–4 个）**：别人已表达过类似观点；你只是纯表态、没有新依据；对话已经充分收尾；这条消息与你的角色/职责无关。
3. **相关性门槛**：只反应真正新的、与你相关的信息；其余 `pass=true`。
4. **名点识别**：如果最新消息是在点名**其他成员**（`@别人` 或直接叫别人名字），除非你有别人没说过的实质性补充，否则 `pass=true`；如果点名的是**你**（叫你的名字或 `@你`），你应当回应：`pass=false` 并给出实质内容。成员凭系统提示词里的自我身份锚判断名点属于谁。
5. **结构化纪律**：本轮必须调用 `group_react` 恰好一次；`message` 是唯一会公开的内容（`pass=true` 时忽略）；不要在正文里写「我 PASS / 我不发言」之类元话术；发言时 `message` 自包含（结论 + 文件指针）；有依据的同意 / 反对 / 补充 / 提问才算贡献。
6. **第一人称发言**：用「我」直接说内容；MUST NOT 在 `message` 开头写自己的名字或「某某：」「某某（作者本人）：」「作为某某，我…」这类归属标签；公开行由系统自动署名；引用别人可用「甲说…」，说自己一律用「我」。
7. **不替其它成员发言**：公开回复只代表你自己，不要替其它成员发言或编造他们的观点；不要抢答点名其它成员的问题；**可以**引用、回应、反驳别人实际说过的话（这是实质贡献，不是替发言）；不要模拟多个成员的对话。
8. **对象未出现先等待**：如果被要求评价/回应/处理的对象尚未出现（别人还没讲笑话、还没给方案、还没贴正文），返回 `pass=true` 等待它出现；MUST NOT 凭空编造对象、假装读了不存在的文件、自己造一份再评。该纪律优先于名点识别：即使点名的是你，对象未出现也先 `pass=true`。

`kGroupMustRespondPrompt` MUST 说明用户点名了该成员、本轮必须给出实质回应，并指示调用 `group_react {pass: false, message: "..."}`；它 SHALL NOT 包含「没有话说就 pass=true」这类沉默授权；**本 change 不修改它的必应口径**。它 SHALL 要求：对象还没出现时如实说「还没看到 X，请 X 先给出」，MUST NOT 编造对象或假装读过不存在的文件。

**关闭态纯 speaker（无 @）的普通轮 SHALL NOT 追加这两段、也不注入 `group_react`**；单会话与其它非反应普通轮同样不追加。安静态的 `@mention` 强制轮 SHALL 追加 `kGroupMustRespondPrompt`（并做结构化判定防漏），它是「被点名轮」而不是普通轮。两段常量 SHALL 有逐字断言（测试断言常量全文实际出现在请求的系统提示词里），且断言默认沉默、few-shot 情形、`group_react`、「正文不要写元话术」与名点识别纪律都在常量里。

#### Scenario: 自愿轮提示词逐字含默认沉默与 group_react

- **WHEN** 一个开启态自愿反应轮的请求被捕获
- **THEN** 它的系统提示词包含 `kGroupReactionPrompt` 全文（沉默是常态、发言是例外、多数轮 `pass=true`、`pass=true` 不是失败、非说不可的新信息、3–4 个 pass=true 情形、相关性门槛、必须调用 `group_react`、`message` 是唯一公开内容、正文不要写元话术）

#### Scenario: 提示词含名点识别纪律

- **WHEN** 检查 `kGroupReactionPrompt` 常量全文
- **THEN** 其中逐字包含「点名**其他成员**时除非有实质补充否则 `pass=true`」「点名的是**你**时应当回应」「`pass=false` 给出实质内容」等表述

#### Scenario: 反应提示词含不替别人发言纪律

- **WHEN** 检查 `kGroupReactionPrompt` 常量全文
- **THEN** 其中逐字包含「只代表你自己」「不要替其它成员发言」「编造他们的观点」「不要抢答点名其它成员的问题」「可以引用、回应、反驳别人实际说过的话」「不要模拟多个成员的对话」

#### Scenario: 反应提示词含第一人称纪律

- **WHEN** 检查 `kGroupReactionPrompt` 与 `kGroupMustRespondPrompt` 常量全文
- **THEN** 两者都逐字包含「第一人称」「开头写自己的名字」「归属标签」「系统自动署名」，且 `message` 由系统自动署名、不需要模型自己写名字

#### Scenario: 评价对象未出现时等待而不编造

- **WHEN** 自发反应开启，用户发送「丙讲个笑话，甲和乙评价一下」，丙还没有公开讲笑话
- **THEN** 甲、乙应当 `pass=true` 等待；它们 MUST NOT 凭空编造一个笑话来评价、MUST NOT 引用不存在的文件；等丙的公开笑话出现后，后续轮再评价丙实际讲的那段

#### Scenario: 强制轮遇到对象不存在

- **WHEN** 用户 `@乙` 要求评价，但被评价的对象还没出现
- **THEN** 乙必须回应，但回应内容是如实说「还没看到 X，请 X 先给出」，不得编造对象或假装读过不存在的文件

#### Scenario: 必应轮提示词要求 group_react pass=false

- **WHEN** 一个开启态 speaker 强制轮或 `@mention` 强制轮被捕获
- **THEN** 它的系统提示词包含 `kGroupMustRespondPrompt` 全文，指示 `group_react {pass: false, message}`，且不含「没有话说就 pass=true」这类许可

#### Scenario: 普通轮不追加反应提示词

- **WHEN** 捕获单会话轮、关闭态纯 speaker 轮（无 `@mention`）或其它非反应轮的系统提示词
- **THEN** 其中不含 `kGroupReactionPrompt` 或 `kGroupMustRespondPrompt`，也不含 `group_react` 工具定义

#### Scenario: 成员角色说明仍在

- **WHEN** 捕获任一成员轮（含反应轮）的系统提示词
- **THEN** 其中仍包含 `kGroupMemberRolePrompt` 全文（反应提示词是追加，不是替换）

### Requirement: 反应链的收敛与生命周期

收敛 SHALL 有两条正常防线 + 一道保险：① 一轮内没有产生任何公开消息时，下一次成员规划 SHALL 为空（每个可反应成员都已被记为对该 `seq` 反应过），链因此结束（`stopReason = all_passed`）；② **last-reacted-seq**：成员 SHALL 只对 `seq` 更新的公开消息反应，SHALL NOT 对同一条公开消息重复反应；③ **每条用户触发的轮数上限** `max_reaction_rounds`（`sessions` 列，整数 1..50 或 `NULL` = 产品默认 8）：用户新发一条消息 SHALL 重置当前预算（`rounds = 0`），agent 自主回复不重置；没有新用户消息的纯 agent 链在预算耗尽且**队列为空**时以 `stopReason = round_cap` **优雅停止**（不是错误），定向 / 点名轮不计数、不被拦截。系统 SHALL NOT 有其它深度上限或等价配置键。

**内部串行执行器**：每个组 SHALL 有一个执行器，同一时刻至多一条链在写原文；**`group.send` SHALL NOT 因执行器在跑被拒绝**（用户消息照写、返回 `started`）。执行器 SHALL 在反应轮边界吸收最新用户触发（更新 `triggerSeq`、重置该用户触发的预算）；队列里的定向 / mention 请求按序串行执行；取消 SHALL 停当前链并清空排队。`group.list` 的 `busy` / `runningMemberId` 只是执行器状态，SHALL NOT 作为发送拒绝条件。

**异步链与可观察状态**：`group.send` SHALL 在起链/入队后立即返回 `started`；链在后台执行并持续更新 `group.chain` 的 `steps` / `rounds`（当前用户触发已消耗轮数）/ `triggerSeq`。链进入终态时 SHALL 写 `status` / `stopReason` 并发 `group.chain.completed`（带 `stopReason`）；`status ∈ {idle, running, completed, cancelled, failed}`，`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`。`group.list` SHALL 暴露 `busy` / `runningMemberId`，使断线重连后的客户端仍能判断执行器在跑。

`agent.cancel` 的组路由 SHALL 能停整条链（不只是当前成员），回包 SHALL 带 `reactionChainStopped`；带 `memberId` 取消**链中排队成员**时 SHALL 停整条链并返回 `cancelled: false` + `reactionChainStopped: true` + 该 `memberId`（它确实没在运行，不谎报 cancelled）；取消**正在运行**的成员时 `cancelled: true`。链中移除 / 编辑成员或删组 SHALL 先停链再执行既有动作。成员轮硬失败 SHALL 中止链并把链状态记为 `failed`（有公开 `Error: …` 行时该行不触发下一轮；没有错误行的失败同样可归因）。链 SHALL NOT 并行运行成员（同一时刻至多一个成员在跑）。

#### Scenario: 全 PASS 自然停

- **WHEN** 一条触发让所有可反应成员都调用 `group_react {pass: true}`（没有新公开消息）
- **THEN** 链在下一轮规划时因没有可反应成员而结束，不再发出新的模型请求；`group.chain` 的 `status = completed`、`stopReason = all_passed`，`rounds` 不再增长

#### Scenario: 同一条不重复反应

- **WHEN** 成员「甲」已经对公开消息 `seq = N` 反应过（无论回复还是 PASS），该消息仍是当前触发
- **THEN** 「甲」不会被再次选中去反应同一条消息

#### Scenario: 达到每组轮数上限优雅停

- **WHEN** 某组的 `maxRounds = 2`，链连续两轮都有成员公开回复且仍有人可反应、队列里没有新的用户消息
- **THEN** 第三轮开始前链以 `stopReason = round_cap` 结束（`status = completed`），不是报错；`group.chain.completed` 带该 `stopReason`，后续点名仍可发送

#### Scenario: 新用户消息重置上限预算

- **WHEN** 某组 `maxRounds = 2`，链已消耗 2 轮预算，用户又发一条新消息
- **THEN** 该消息被接受并写入；执行器吸收它，`group.chain.rounds` 重置为 0，这条新触发重新获得 2 轮自主反应预算（不是直接 `round_cap`）

#### Scenario: 定向轮不受轮数上限影响

- **WHEN** 某组 `maxRounds = 1`，客户端点名一个成员发言
- **THEN** 定向轮照常执行（source=`speaker`），不被上限拦截；上限只约束之后的反应轮

#### Scenario: 上限是组设置不是配置键

- **WHEN** 审阅 `Session`/`sessions` 表、`group.update` 与 `configuration.md`
- **THEN** `maxRounds` / `max_reaction_rounds` 是组设置（`sessions` 列），不是 `config.json` 键；链读取的是该组的值，`NULL` 时用产品默认 8

#### Scenario: 链结束事件

- **WHEN** 一条异步链进入任意终态
- **THEN** 客户端收到一条 `group.chain.completed` 的 `agent.event`，payload 带 `groupId` / `status` / `stopReason` / `rounds` / `triggerSeq`

#### Scenario: 链运行中发送被接受

- **WHEN** 反应链正在运行，客户端再次调用 `group.send`（带文本）
- **THEN** 返回 `started`、写入这条用户消息（不返回 busy）；执行器吸收它，`group.chain` 的 `triggerSeq` 更新、`rounds` 重置，后续反应能看到这条消息

#### Scenario: 取消停整条链

- **WHEN** 反应链运行中客户端对组会话调用 `agent.cancel`
- **THEN** 当前成员被取消、链停止（不再有后续成员运行），回包带 `reactionChainStopped: true` 与（若有）当前成员的 `memberId`；链状态 `cancelled`

#### Scenario: 取消链中排队成员

- **WHEN** 反应链运行中，客户端带 `memberId` 取消一个**尚未轮到**的成员
- **THEN** 整条链停止（后续成员不再开始），回包带 `cancelled: false`、`reactionChainStopped: true` 与该 `memberId`；不谎报该成员被取消

#### Scenario: 取消链外未运行成员

- **WHEN** 反应链运行中，客户端带 `memberId` 取消一个既不在链里、也没有在运行的成员
- **THEN** 返回可归因「该成员当前没有在运行」结果；链继续运行（不冒领停链）

#### Scenario: 链中移除成员先停链

- **WHEN** 反应链正在运行，客户端移除一个成员
- **THEN** 链先停止，再做软删；不会在成员被销毁后继续调用它的实例

#### Scenario: 成员失败中止链

- **WHEN** 反应链里某个成员轮硬失败（例如 provider 报错）
- **THEN** 链中止，后续成员不再运行；`group.chain` 的 `status = failed`、`stopReason = failed`，失败步骤带该成员的 `memberId` 与错误

#### Scenario: 无错误行的失败也中止链

- **WHEN** 某个成员轮硬失败但没有写公开错误行（未预期异常 / 工具轮上限等路径）
- **THEN** 链同样中止，`group.chain` 与 `turn.failed` 可归因（带 memberId 与 error），后续成员不再运行

#### Scenario: 不并行运行成员

- **WHEN** 一条反应链连续跑多个成员
- **THEN** 同一时刻至多一个成员处于流式运行（用 `agent.streaming` 事件或实例状态观察）

### Requirement: @ 点名定向响应

用户消息里的 `@显示名` SHALL 被解析为成员 id：以 `@` 开头，匹配**未移除**成员的显示名；同一位置 SHALL 取最长匹配；名字后面必须是字符串结尾、空白或标点，否则不算命中；多个命中 SHALL 按出现顺序去重。命中的成员 SHALL 必应：**开关开启时**在首个反应轮作为强制成员排在最前——首个反应轮的触发可以是该用户消息，也可以是 speaker 对该用户消息的公开回复（speaker 回复或 PASS 两种情况下 `@mention` 都强制）；**开关关闭时**按点名顺序各跑一轮强制响应（不触发反应链；若有 speaker，speaker 普通轮先跑，随后 mention 强制轮）。「必应」的验收口径是 `source = mention` 且 `status = replied` 且有 `publicSeq`；`forced_pass` / `forced_empty` 是失败，不是「已回应」。未被解析的 `@…` SHALL 原样留在用户消息正文里，SHALL NOT 报错、SHALL NOT 被删除。点名解析 SHALL 只作用于**用户消息**；agent 公开回复里的 `@` 只是正文。`speaker` 与 `@mention` 同时存在时，两者都跑（开启态 speaker 强制轮 / 关闭态 speaker 普通轮先跑，`@mention` 随后）。

#### Scenario: @B 强制 B 回应

- **WHEN** 自发反应开启，用户发「@乙 你怎么看？」且其它成员都 PASS
- **THEN** 「乙」的 step 满足 `source = mention`、`status = replied`、`publicSeq` 非空，且 `steps` 里没有 `forced_pass` / `forced_empty`；其公开回复进入时间线

#### Scenario: @B @C 按出现顺序

- **WHEN** 用户消息里先 `@乙` 后 `@丙`
- **THEN** 首个反应轮里「乙」排在「丙」前面（步骤顺序可观察），两者都被强制

#### Scenario: 最长名字优先

- **WHEN** 组里同时有「甲」与「甲二」，用户写 `@甲二`
- **THEN** 解析成「甲二」的成员 id，而不是「甲」

#### Scenario: 未匹配的 @ 留在原文

- **WHEN** 用户写 `@不存在的人 你好`
- **THEN** 消息照常写入，正文保留 `@不存在的人 你好`，不返回错误、不产生强制成员

#### Scenario: 关闭态 @mention 仍生效

- **WHEN** 自发反应关闭，用户带文本发送、不点为发言者但 `@乙`
- **THEN** 「乙」跑一轮强制响应（source=`mention`），不触发反应链；其它未被点名的成员不产生消息

#### Scenario: speaker 与 @mention 都跑

- **WHEN** 自发反应开启，客户端点名「甲」且用户文本里 `@乙`；甲产生公开回复，或甲 `group_react {pass:true}`/空 `message`
- **THEN** 「甲」先跑（source=`speaker`），随后「乙」在首个反应轮被强制（source=`mention`）；两种情况下「乙」都必须 `status = replied` 且有 `publicSeq`

#### Scenario: 关闭态 speaker 与 @mention 都跑

- **WHEN** 自发反应关闭，客户端点名「甲」且用户文本里 `@乙`
- **THEN** 「甲」先跑普通轮（source=`speaker`），随后「乙」跑强制轮（source=`mention`）；`steps` 两步都可观察

### Requirement: 群上下文跨核心重启存活

群的工作区上下文 SHALL 在核心重启后对**存量群**仍然可用：成员反应轮取工作区前 SHALL 先按需重注册群上下文（`ensureContext`，统一入口 `ensureGroupContext`），不得因 sidecar 内存上下文随重启丢失而对存量群报 `unknown_context`。`ensureContext` 异常 SHALL 包成 `GroupException`；`getWorkspace` 返回 ok 但工作区为空串 SHALL 按可归因错误处理，MUST NOT 静默以空工作区建成员。**自定义工作区不持久化**：`sessions` 无 workspace 列，重启后上下文新建（`created:true`）SHALL 回落缺省 `ConfigService.homeDir`（已知限制；持久化另立）；幂等仅指**同进程上下文仍在**（`created:false`）时不覆盖已有工作区，不是重启保留。新建群与单会话的既有行为不变。

#### Scenario: 重启后存量群成员轮可反应

- **WHEN** 建群（reactionsEnabled 开启）并加成员、发一条消息确认能反应；随后**同一数据库**重建 sidecar / 核心实例（模拟重启，内存上下文丢失），对同一存量群再发一条消息
- **THEN** 成员轮成功反应：链 `status=='completed'` 且步 `replied`/`publicSeq` 非空（不以「非 steps=0」判——失败步也让 steps>0），不报 `unknown_context`

#### Scenario: 同进程幂等重注册不覆盖已有工作区（回归守卫）

- **WHEN** 群上下文仍在（同进程，未重启），再次触发 `ensureGroupContext`
- **THEN** `created:false`，该群已有工作区不被覆盖（读 `getWorkspace` 验证）

#### Scenario: 重启后自定义工作区回落缺省（已知限制）

- **WHEN** 某群经 RPC 设了自定义工作区，核心重启后触发该群成员轮
- **THEN** 工作区回落缺省 `ConfigService.homeDir`（workspace 未持久化）；成员轮仍可反应，不报 `unknown_context`

#### Scenario: 新建群与单会话不受影响（回归守卫）

- **WHEN** 重启后新建群发消息，或打开存量单会话
- **THEN** 新建群正常反应（创建时已注册）；单会话沿用其懒注册，行为不变

### Requirement: 群链失败可归因

链 `failed` 时 SHALL 有可归因真因并经 `group.chain` 的 `error` 字段返回（字段形状见 MODIFIED「群聊 RPC 面」）；界面 SHALL 以独立提示（`group-chain-error`，不复用加载/视图错误提示）显示该真因，一过性（下次发送清除）。**现状纠正**：组链 failed 时界面此前什么都不显示（`turn.failed` 群分支被吞属 residuals），本需求新增真因显示。`completed`/`cancelled` 时 `error` SHALL 为 null，不显示旧错。

#### Scenario: 失败链返回真因并显示

- **WHEN** 一条链因成员轮异常（如 `unknown_context` 或 provider 错误）进入 `failed`
- **THEN** `group.chain` 回包含非空 `error` 且含该原因文本；界面 `group-chain-error` 显示该真因

#### Scenario: 非失败链不带旧错（回归守卫）

- **WHEN** 链 `completed` 或 `cancelled`
- **THEN** `group.chain` 的 `error` 为 null；界面不显示 `group-chain-error`
