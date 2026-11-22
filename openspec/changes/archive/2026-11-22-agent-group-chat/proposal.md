## Why

现状里「会话 = 一个 Agent」是写死的：`sessions` 只有一个 `agent_type`，`messages` 没有作者/可见性，`summary_nodes` 按 `(session_id, level, start_seq, end_seq)` 全局键，无头核心的 RPC 与 Flutter 启动恢复都按 `sessionId` 找实例。唯一的多 Agent 形态是 `spawn_subagent` 的一次性子运行 —— 父看不到子过程、子看不到父历史、结束即销毁，适合分工，不适合**长期协作**。

用户要的是群聊：一个组里多个成员共享同一段对话，各成员保留自己的私有思考与工具过程，由用户逐轮点名发言。这不能靠加一个界面解决，必须先把「**单一共享原文 + 逐成员视图投影**」这条主线立起来 —— 原文只有一份（可审计、可回放、可换视图），每个成员看到的上下文是这份原文的一次投影，投影是成员模型唯一能拿到上下文的出口。

现在做的理由：路线 C（无头核心 + web 聊天屏 + 管理屏）已落地，群聊的界面载体与 RPC 通道就绪；spawn 的工作区继承、子角色提示词、私有上下文隔离已跑通，群聊是它的持久化泛化。

## What Changes

**A. 组与会话模型（单一原文，不物理分 lane）**
- `sessions` 加 `kind`（`group` / `single`）与 `overrides_json`（单会话覆盖层）；新增 `group_members` 表（成员 id、显示名、模板名、覆盖层、`removed_at`、加入时间）。
- `messages` 加 `author`（**稳定成员 id**；用户消息为空）与 `visibility`（`public` / `private-to-author`）两列。成员移除是**软删**（行保留、`removed_at` 标记），同名重建是新 id。
- 组内全部公开消息 + 各成员私有活动都存**这一份原文**，单一 per-session `seq` 序列。不按成员分表、不分会话：视图是投影，不是存储分区。
- **kind 分派守卫（新增，堵第二条出口）**：组会话出现在顶层会话列表，但**不创建/不恢复单 Agent 实例**；Flutter 启动恢复跳过它、`agent.send` 与 `session.switchTemplate` 对组会话可归因拒绝、Flutter 打开组会话显示占位；`session.list` 序列化 `kind` 供客户端分流。否则把组会话当单会话恢复，就会绕开投影、把整份原文（含他人私有行）直接喂给模型。

**B. 视图投影 = 唯一出口**
- 发给成员 X 的上下文 = 对原文序列做「可见性过滤 + 主客体映射」：用户消息 → user 轮原样；X 自己的公开回复 → assistant 轮第一人称；X 自己的私有活动 → 按现有 replay 机制回放；其他成员 Y 的公开回复 → user 轮 + 文本归属前缀「Y 说：…」；其他成员的私有活动 → 整体剔除。
- **归属只能进文本**：Anthropic 的 `MessageParam` 只有 `role` + `content`，DeepSeek 兼容页未记载 `name` 可用于 Messages，归属只能写进正文。
- 连续同角色轮合法：Anthropic 文档明示会合并相邻同角色轮（DeepSeek 兼容端点未记载，故 live 断言相邻 user 轮不报错）；装配层不补洞、不改 role。
- **投影不变量**：成员 `tool_use`↔`tool_result` 之间不夹他人公开行；`tool_result` 放在所在 user 轮 content 数组最前。
- 不存在第二条把原文行交给成员模型的路径。

**C. 逐视图压缩（取代共享摘要）**
- 压缩对象 = **各成员自己的投影视图**，不是共享原文、不是共享公开摘要。`summary_nodes` 的作用域键加成员维度（单 agent 会话该维度为空，按 `IS NULL` 匹配走原路径）。
- **摘要参考上下文也按成员作用域**：`_loadReferenceCandidates` 现在读「本会话全部摘要」，B 折叠时会把 A 的摘要当参考块喂给模型 —— 本 change 把它改成只取本人作用域的摘要（新增的泄漏通道）。
- 阈值仍只有一条规则：token 阈值 = 该成员自己的模型总上下文 × 配置百分比，逐视图实时派生；不引入任何条数门槛或写死的绝对 token 数。
- 摘要请求只带「保留归属」纪律（他人的话仍是「Y 说」），**不**带面向公开回复的"自包含 + 文件指针"要求。
- 代价如实写入 design：公开内容会被各视图各压一遍（N 倍摘要算力 + N 份存储），但按各视图自身压力触发，实际成本≈各视图需求之和；摘要发散是特性（客观原文是唯一真相，摘要是各成员的主观记忆）。

**D. 调度 v1：用户点名 + 组级单运行门**
- 一次发送指定**一个**发言者（成员 id），只跑该成员一轮；**组内同一时刻至多一个成员在运行**（不是只查目标成员忙闲）。
- 两个前置门：不带用户消息且该成员视图为空 → 可归因错误（不发 `messages: []`）；不带用户消息且最后可见项是本人 assistant 轮 → 可归因错误（避免退化成 prefill 续写）。
- **本期明确不做**：轮转、主持人、自由抢话、并行成员发言。

**E. 公开回复自包含纪律 + 共享工作区**
- 成员系统提示词附加组角色说明：他人以「Y 说：」出现在 user 轮、自己的历史以 assistant 轮呈现、他人的工具过程不可见、公开回复必须自包含（结论 + 文件指针）、共享工作区是成员间真正的协调通道。该说明写成代码常量。
- `group.create` 建立组上下文（可选 `workspace`，缺省用产品既有缺省工作区口径）；成员经 `sidecar.getWorkspace(groupId)` 继承同一工作区（沿用 spawn 的继承路径），文件是成员间唯一的协调通道。

**F. 成员定制基座：模板 + 覆盖层（新能力 `agent-instance-overrides`）**
- 覆盖层 v1 字段三个：工具子集（只能在模板 `tools` 上收紧；显式 `[]` = 零工具）、系统提示词追加（append，不替换）、`thinkingEffort`（白名单；显式空串 = 关闭；非白名单保存时拒绝）。
- 字段缺席/JSON null = 无覆盖。覆盖层按成员/会话持久（`overrides_json`），模板降为预设。
- **生效时机**：工具子集与提示词追加与模板的非推理字段同口径 —— **实例创建/恢复时生效**，不做逐轮热替换；`thinkingEffort` 沿用热更新（下一消息生效）；`model`/窗口仍模板级冻结。编辑覆盖层通过重建成员实例生效（`group.member.update`）。
- 单 agent 会话同样可用覆盖层（与成员同一条解析路径）。

**G. 规模前置（内存边界）**
- 成员视图按需装配（不把整条原文或全部成员视图常驻内存）；公开原文的行解析结果可跨成员复用，私有回放各成员各一份；**派生缓存的生命周期跟随驻留视图**（行被摘要覆盖或离开视图即淘汰），不随会话全长增长；不引入无出处的上限/缓存尺寸魔数。
- 这是本 change 的**前置任务**：`Agent.restore()` 目前会把整条会话历史全量载入并常驻，直接搬给 N 个成员就是 N 份全量历史。

**H. web 组视图（真实应用可达，route C 延续）**
- 组视图挂进真实应用：会话列表按 `kind` 分流；组视图 = 公开时间线 + 成员私有分栏（含「已移除」栏）+ 每成员真实上下文视图（复用 `RealContextView`）+ 每成员占用环（按该成员窗口与 breakdown，复用 `ContextRing`）+ 操作面（建组 / 加成员 / 编辑覆盖层 / 选发言人并发送）。
- 事件与发送以 payload 为证据（`group.send` 的 `speaker`、事件里的 `groupId`/`memberId` 落到哪个分栏），DOM 选中值只作辅助。
- **本期不要求 Flutter 组界面**：组会话在 Flutter 列表里可见，打开时显示「请在 web 组视图打开」占位。

**I. RPC 面（无头核心扩展）**
- 新增 `group.create` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（带 speaker）/ `group.view`（取某成员本次运行内最近一次真实发出的快照）；`kCoreRpcMethodNames` 同步。
- `group.list` 带成员清单（id / 显示名 / 模板名 / `removedAt` / `overrides` / `effective`）；`session.list` 带 `kind` 与 `overrides`；`message.query` 扩展 `author` / `visibility` 序列化；`agent.event` 带 `groupId` + `memberId`；`agent.cancel` 在组会话上按组路由（返回被取消成员的 `memberId`，不给假原因）。

**J. 隐私硬约束（规范条文 + 可失败验收）**
- 成员的真实上下文快照（`toRawJson`，含摘要层）与摘要请求的**输入通道**（被折叠文本 + 参考块）都不含他人私有内容；投影是唯一出口。
- 结构性加固：组成员回合的最终**公开行只存正文**（`tool_calls` 与 `thinking_json` 均为 NULL，v1 公开回复不带附件），私有证据只落 private 行。
- 验收可失败：独特标记注入 A 的私有工具轮，断言 B 的视图、快照与摘要输入通道都不含该标记（红靶打输入通道，摘要模型输出只作附加证据）。

**不做**（本期范围外，同时写进 design 的非目标）：成员轮转与主持人、自由抢话、并行发言、Flutter 组界面、`model` / 窗口级覆盖、组间共享工作区、组成员并发写同一文件的冲突裁决。

## Capabilities

### New Capabilities

- `agent-group-chat`: 组会话与成员（软删）、单一共享原文（author=稳定成员 id、最终公开行只存正文）、逐成员视图投影（唯一出口 + 不变量）、用户点名调度与组级单运行门、组角色纪律与共享工作区、群聊 RPC 面、真实应用内的 web 组视图、隐私硬边界（含摘要输入通道）、成员视图按需装配与缓存生命周期。
- `agent-instance-overrides`: 模板 + 会话/成员级覆盖层（工具子集、系统提示词追加、thinkingEffort）；空值三态（缺席/显式空集/显式空串）互不等价；创建/恢复时生效、思考强度热更新、编辑走实例重建；持久化、模板降为预设、单 agent 会话同样可用。

### Modified Capabilities

- `context-compaction`: 「Stable message ordering (seq)」MODIFIED —— 摘要 span 键加成员作用域；「Summarizer reference context is bounded…」MODIFIED —— 参考摘要限本人作用域（堵新增泄漏通道）；新增「压缩输入是各成员自己的投影视图」要求。
- `session-persistence`: 「Session storage」MODIFIED —— `kind = group` 时 agent_type 不作模板选择器、不创建/恢复单 Agent；「Summary nodes table」与「Stable seq column」MODIFIED —— 键加 `member_id`、`leaf_owner` 索引含成员、空作用域按 `IS NULL` 匹配；新增 author/visibility 列、组/成员表（含软删与覆盖层列）、v8→v9 非破坏迁移。
- `web-core-shim`: 新增「群聊 RPC 面与成员身份事件」（8 个方法、`session.list` 带 kind、成员字段与覆盖层可观察字段）与「组会话的取消与实例路由」（`agent.cancel` 按组路由，不给假原因）。

## Impact

- **核心（Dart）**：`lib/services/agent.dart`（实例句柄、视图装配、写入 seam、压缩作用域与参考上下文、最终公开行只存正文）、`lib/services/message_repository.dart`、`lib/services/summary_node_repository.dart`、`lib/services/database_service.dart`（schema v9）、`lib/core/headless_core.dart` + `lib/core/event_serialization.dart`（群聊 RPC、kind 序列化、取消路由、事件身份）、`lib/main.dart`（`_loadSessions`/`_ensureAgentFor` 的 kind 守卫与 Flutter 占位）；新增群会话/成员/视图装配服务。
- **web**：组视图组件真实挂载（`App.tsx` 路由、会话列表 kind 分流）、建组/加成员/覆盖层编辑/选人发送、`protocol.ts` 方法；复用既有 `RealContextView` / `ContextRing` / tokens；`web/e2e/group.mjs` 接进 `npm run test:all`。
- **不动**：C++ sidecar（请求形态不变）、`subagent-tool`（spawn 保持一次性子运行）、`agent-template-management`（模板需求不变，覆盖层是新能力）。
- **数据**：SQLite schema 8→9，非破坏迁移（只加列/加表/加索引，旧行按「公开、无作者、无覆盖、single」解释）。
- **文档**：新增 `Docs/user-guide/group-chat.md` 与 README 索引；`configuration.md` 补成员/会话覆盖层一节；`web-core-shim.md` 与 `web-management.md` 的 RPC 表补群聊方法（两个文档守卫逐名核对 `kCoreRpcMethodNames`）。
- **测试**：unit（投影与剔除、覆盖层解析与空值三态、模型读写、常量化提示词）、integration（真库 openAt + 假 sidecar/假 probe + 临时 configPath/attachmentsDir/lockPath：组装配、隐私输入通道、kind 守卫、软删、取消路由、事件身份、迁移结构对比）、web vitest + puppeteer（payload 通道判据）、live（真实模型组轮 + 相邻 user 轮 + 摘要输入抓取 + 截图视觉验收）。
- **依赖**：无新增三方依赖。
- **已知代价**：公开内容按成员各压一遍（N 份摘要算力与存储）；成员视图的内存边界必须在本期做（前置任务）。组会话在 Flutter 里只有占位（组界面走 web）。
