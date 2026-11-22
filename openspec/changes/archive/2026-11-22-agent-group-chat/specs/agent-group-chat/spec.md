## ADDED Requirements

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

一次群发送 SHALL 指定恰好一个发言者（成员 id），只运行该成员一轮。**组级单运行门**：同一个组在同一时刻 SHALL 至多有一个成员在运行 —— 无论被点名的是谁，只要组内已有成员在跑，本次发送 SHALL 返回可归因的 busy 结果（复用既有 `Agent.send` 的 busy 语义），SHALL NOT 排队、SHALL NOT 静默丢弃、SHALL NOT 改写到别的成员；SHALL NOT 只检查目标成员自己的忙闲。

发送 MAY 携带一条用户消息：携带时该消息作为用户公开消息写入**一次**（`author` 空、`public`），不携带时 SHALL NOT 写入空的用户消息行。两个前置门用来避免发出退化成单轮续写或空请求的上下文：

- 不带用户消息、且该成员视图为空（没有任何可见项）→ SHALL 返回可归因错误（MUST NOT 发 `messages: []`）；
- 不带用户消息、且该成员视图最后一条可见项是**本人的 assistant 轮** → SHALL 返回可归因错误（那会退化成 prefill 续写），要求带文本或最后可见项非本人 assistant。

未指定发言者的发送 SHALL 返回可归因错误。删除/移除成员时先取消其实例。

#### Scenario: 点名谁就只有谁发言

- **WHEN** 用户在组里发言并点名成员「甲」
- **THEN** 只有「甲」产生一轮回复与私有活动，「乙」不产生任何消息行

#### Scenario: 组级单运行门

- **WHEN** 成员「甲」正在运行，客户端点名「乙」发送
- **THEN** 返回可归因的 busy 结果（指明该组已有成员在运行），原文里不出现两人交错的写入

#### Scenario: 不带用户消息的点名

- **WHEN** 客户端只指定发言者「甲」、不带用户消息，且「甲」的视图最后一条可见项是用户的公开消息
- **THEN** 库中 SHALL NOT 新增一条空内容的用户消息行，「甲」直接基于现有原文发言

#### Scenario: 空视图不许发

- **WHEN** 成员「甲」加入后视图为空（没有任何可见项），客户端不带用户消息点名它
- **THEN** 返回可归因错误（指明视图为空），SHALL NOT 发出空 messages 的请求

#### Scenario: 本人 assistant 结尾不许 prefill

- **WHEN** 不带用户消息点名「甲」，而「甲」的视图最后一条可见项是「甲」自己的 assistant 轮
- **THEN** 返回可归因错误，要求带用户文本或让最后可见项不是本人 assistant

#### Scenario: 未点名被拒

- **WHEN** 客户端调用群发送但不带发言者
- **THEN** 返回可归因错误（指明缺少发言者），库中不新增任何消息

### Requirement: 公开回复自包含与组角色纪律

成员实例的系统提示词 SHALL 追加一段组角色说明，且该说明 SHALL 由代码常量提供（便于测试与文档断言）。说明 MUST 覆盖五件事：他人以「Y 说：」出现在 user 轮；自己的历史以 assistant 轮呈现；他人的工具过程不可见；**公开回复**必须自包含（结论 + 文件指针）；共享工作区是成员间真正的协调通道。

自包含纪律 SHALL 只约束**公开回复**（它会被其他成员读到），SHALL NOT 强加给摘要：摘要是该成员私有的、跨成员不读，只要求保留归属（见「逐视图摘要的私有性」）。

#### Scenario: 系统提示词含组角色说明

- **WHEN** 创建一个组成员实例
- **THEN** 它实际发送的系统提示词里包含组角色说明常量的全文（逐字断言，不是"包含关键字"）

#### Scenario: 他人工具证据不可见也能协作

- **WHEN** 成员「甲」用工具改了共享工作区里的一个文件，随后用户点名「乙」
- **THEN** 「乙」的视图里没有「甲」的工具证据，但「甲」的公开回复带了文件指针，「乙」能按指针读到该文件（观察通道输出结论与路径）

#### Scenario: 摘要不被要求自包含

- **WHEN** 检查组摘要请求的系统文本与纪律常量
- **THEN** 其中不含「结论 + 文件指针」这类面向公开回复的自包含要求，只有归属保持要求

### Requirement: 共享工作区继承

成员上下文 SHALL 用**组上下文已保存的工作区**初始化（沿用 spawn 的继承路径：`sidecar.getWorkspace(groupId)` 只读读取，再作为成员上下文的默认工作区）。该工作区由 `group.create` 建立（见「组会话与成员」），系统 SHALL NOT 给成员单独的私有工作区；成员写入的文件对全组可见（同一目录）。

成员实例 SHALL 是持久实例：SHALL NOT 建立 `parent_session_id` 子运行记录，SHALL NOT 在回合结束时销毁上下文。

#### Scenario: 成员工作区等于组工作区

- **WHEN** 组成员实例被创建
- **THEN** 它的上下文工作区与组上下文保存的工作区相同（逐字相等，不是"默认主目录"）

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

核心 SHALL 提供 `group.create` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（带发言者指定）/ `group.view`（带成员 id）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员/原因），MUST NOT 静默失败或崩溃。

`group.list` SHALL 返回每个组的 id、标题与成员清单：每个成员带成员 id、显示名、模板名、**已移除标记 `removedAt`**、`overrides`（工具子集 / 提示词追加 / 思考强度）与 `effective`（生效工具清单、生效思考模式与强度），供界面渲染分栏、选发言人与展示覆盖层效果；不额外增加"列成员"的方法。

`group.member.update` SHALL 原地更新成员（显示名 / 模板 / 覆盖层）并保持成员 id 不变；更新后 SHALL 重建该成员实例（先退役/销毁旧实例，再按新配置创建），使新的工具子集与提示词追加生效。

`group.view` SHALL 返回该成员**本次运行内最近一次真实发出**的上下文快照（`system` / `messages` / `tools` + 窗口与 breakdown）；该成员本次运行内从未发言时 SHALL 返回空（界面显示占位），SHALL NOT 用历史拼一份"没发过的上下文"。重启后视图为空属既定语义（与真实上下文视图的"自本次启动以来"先例一致）。

#### Scenario: 八个群聊方法可调用

- **WHEN** 客户端依次调用建组、列组、加成员、改成员、发消息、取成员视图、移除成员、删组
- **THEN** 每个方法返回结构化结果或可归因错误，通道不崩溃

#### Scenario: 列组带成员与覆盖层可观察字段

- **WHEN** 成员设置了工具子集与追加提示词后客户端调用 `group.list`
- **THEN** 该成员项同时返回 `overrides` 与 `effective`（生效工具清单、生效思考强度），可直接用于界面展示

#### Scenario: 改成员重建实例

- **WHEN** 客户端用 `group.member.update` 修改某成员的工具子集
- **THEN** 成员 id 不变，其旧实例被销毁、按新配置重建，下一次发言的请求使用新工具清单

#### Scenario: 方法清单同步

- **WHEN** 核心启动注册群聊 RPC
- **THEN** `kCoreRpcMethodNames` 与实现一致（漏注册抛错），且网页文档的 RPC 表列出全部群聊方法

#### Scenario: 取成员视图返回本次运行内最后一次真实发出的上下文

- **WHEN** 成员「甲」本次运行内发过一轮，客户端调用 `group.view(甲)`
- **THEN** 返回的快照 `messages` 与该轮实际发出的投影逐字一致（含归属前缀），`windowTokens` 是「甲」自己实例的窗口

#### Scenario: 没发过的成员返回空

- **WHEN** 成员「乙」加入后还没发过言（或应用已重启），客户端调用 `group.view(乙)`
- **THEN** 返回空结果，界面显示占位，而不是一份用历史拼出来的上下文

#### Scenario: 失败可归因

- **WHEN** 客户端对不存在的组或成员调用群聊方法
- **THEN** 返回带原因与对象 id 的 JSON-RPC 错误

### Requirement: web 组视图

web 客户端 SHALL 在**真实应用**里提供可达的组视图（不是只在测试 harness 里存在的组件）：会话列表 SHALL 按 `kind` 把组会话路由到组视图，单会话仍进聊天屏。组视图 SHALL 包含：

1. 公开时间线（按 `seq` 排列，每条带作者归属）；
2. 每成员私有分栏（用户可切换或并排查看，栏头标明"仅该成员可见"），已移除成员也 SHALL 有一栏（标「已移除」），使历史私有行有去处；
3. 每成员真实上下文视图（显示 `group.view` 返回的 `system` / `messages` / `tools` 原始 JSON，复用既有真实上下文视图组件）；
4. 每成员占用环（按该成员视图的 breakdown 与**该成员自己的窗口**，复用既有环组件与三瓣口径）；
5. 操作面：建组、加成员、编辑成员覆盖层（工具子集 / 提示词追加 / 思考强度）、选发言人并发送（`group.send` 的 `speaker`）。

事件路由 SHALL 以 payload 为准：`group.send` 的参数带 `speaker`，`agent.event` 带 `groupId` / `memberId`，私有分栏 SHALL 按这两个字段归位；e2e 验收 SHALL 以 payload 为判据（DOM 选中值只作辅助，不能作为唯一证据）。

用户消息与全部成员的公开回复 SHALL 可见并带归属。Flutter 侧本期 SHALL NOT 被要求提供组界面：组会话在 Flutter 的会话列表里可见，但打开时 SHALL 显示「请在 web 组视图打开」的占位，不进入单 Agent 对话界面。

#### Scenario: 会话列表按 kind 分流

- **WHEN** 用户在 web 端打开一个组会话
- **THEN** 进入组视图（公开时间线 + 成员分栏），而不是单 Agent 聊天屏

#### Scenario: 打开组视图看到时间线与私有分栏

- **WHEN** 用户打开一个含两个成员的组
- **THEN** 页面显示公开时间线，以及「甲」「乙」两栏私有活动，栏头标明仅该成员可见

#### Scenario: 已移除成员仍有分栏

- **WHEN** 一个组里有已移除的成员「甲」
- **THEN** 组视图仍显示「甲（已移除）」分栏，它的私有历史行有去处

#### Scenario: 建组/加成员/编辑覆盖层/点名发送都可在界面上完成

- **WHEN** 用户从组视图建组、加两个成员、把其中一个的工具子集收紧、点名该成员发言
- **THEN** 四件事都经 `group.*` RPC 完成，界面显示该成员的生效工具清单与已发出的发言

#### Scenario: 切到成员的真实上下文

- **WHEN** 用户在「甲」的分栏里打开真实上下文视图
- **THEN** 页面显示 `group.view(甲)` 的 system/messages/tools 原始 JSON，可滚可复制

#### Scenario: 每成员占用环各用自己窗口

- **WHEN** 「甲」与「乙」的模型窗口不同
- **THEN** 两个环的分母分别是各自实例的窗口，各按自己的 breakdown 绘制，不共用一个分母

#### Scenario: 没发过言的成员显示占位

- **WHEN** 某个成员还没发过言（或应用重启后）
- **THEN** 它的真实上下文视图显示占位、环不渲染（与既有"没有快照不画环"一致）

#### Scenario: 事件按 payload 归位

- **WHEN** 两个成员先后发言
- **THEN** 每个成员的流式/工具/消息事件按 `memberId` 落到自己的分栏，公开回复按 `groupId` 落到时间线（e2e 断言 payload 字段，不只看 DOM 选中的分栏）

#### Scenario: 加载页内的行都有归属去处

- **WHEN** 客户端加载一页消息
- **THEN** 每条行都能按 author/visibility 落到公开时间线或某个成员分栏（含已移除成员），不丢行、不重复显示

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
