## Why

现在的群聊是**点名制**：`group.send` 必须带一个 `speaker`，一次只运行一个成员。用户实测反馈这样会「各聊各的」——A 讲完笑话，B、C 不会自己接话，除非用户再逐个点名。群聊的价值恰恰在于成员能对**用户和其他成员的公开发言**产生自发反应（用户说「A 讲笑话，B/C 评价」⇒ A 讲完，B、C 自己评价）。

本轮口径由用户拍板：**自发反应默认开**（点名不该是默认体验）、**`group.send` 改异步**（不再等整条链跑完）、**每组可配置反应轮数上限**（界面可改，防 token 失控）与**所有公开消息都触发反应**。群聊的存储、投影、压缩、私有分栏、web 组视图与 RPC 面已在前一个 change 落地，本 change 只在其上加调度行为，不改投影与压缩。

## What Changes

**A. 一种群聊行为 + 每组的「自发反应」开关**
- 群聊只有一种行为，配一个 per-group 布尔开关 `reactions_enabled`（JSON `reactionsEnabled`）：开启时所有公开消息触发反应链；关闭时只有被点名（`speaker` / `@mention`）的成员跑，等价旧点名体验（安静态）。
- **新建组默认 `true`**；v9→v11 迁移把**既有组行回填 `false`**（v9→v10 段加开关列；v10→v11 段补上限列，兼容上一轮同步实现升上来的 v10 缺列库）。单会话行也带这两列，但无行为意义。
- `group.create` 可带 `reactionsEnabled`；新增 `group.update` 改开关；web 组视图有「自发反应」开关（新建组默认开）。

**B. 反应链（串行第一刀，后台执行）**
- 开关开启时，**每条公开消息都会成为反应刺激**：用户消息启动一轮；成员在同一轮内的公开回复会被后跑的成员看到并反应（串行可见）。链的下一轮触发取**该轮最后一条公开消息**的 `seq`——这不是对「所有公开消息触发」的收窄，而是串行实现口径。可反应成员按固定顺序各跑一轮完整 Agent 轮（可调工具，工具过程私有）。
- 串行：B 的公开回复先落库，C 的视图里能看到 B 的评价。并行反应留第二刀。
- 成员没有实质贡献时**用结构化的 `group_react {pass:true}`** 表达沉默；反应轮请求注入这个终态控制工具，代码读 `pass` 布尔，不靠文本匹配。`pass=true` 时无论 `message` 写什么（包括「我这回合不发言」这类元话术）都不写公开行；`pass=false` 时公开行只写 `message` 字段。没有调用/参数非法记 `failed`，**不回退到 `[PASS]` 文本匹配**。反应轮的纯空白 `message` 也不写公开行（记 `empty`）。
- 收敛有两条正常防线 + 一道保险：**全 PASS（结构化 `pass=true`）自然停** + **last-reacted-seq**（成员只对更新的公开消息反应，不对同一条反复接话）；**每组可配置的反应轮数上限**（`max_reaction_rounds`，界面可改，默认 8，范围 1..50）是**每条用户触发一份预算**：用户新发消息重置预算，agent 自主接话不重置；纯 agent 链到顶以 `round_cap` 优雅停，定向 / 点名轮不受影响。
- 反应提示词写成代码常量：`kGroupReactionPrompt`（**默认沉默 + 3–4 个 `pass=true` 样板 + 相关性门槛 + 用 `group_react` 返回**）与 `kGroupMustRespondPrompt`（开启态 speaker / 两态 @mention 必应，指示 `pass=false`，不含沉默授权）。

**C. 点名与 @mention（三态钉死）**
- `group.send` 的 `speaker` **始终可空**：带 speaker = 定向；空 = 纯触发（开关开启时触发反应轮；关闭且消息里没有 `@mention` 时无发言者，返回可归因错误）。
- **开启态 speaker** = 强制轮（必应；`pass=true` / 空 `message` 记 `forced_pass`/`forced_empty`）。
- **关闭态纯 speaker（无 @）** = 旧普通轮逐字不变（不追加反应/必应提示词、不注入 `group_react`、不做结构化判定；`[PASS]` 按旧行为是普通正文）。
- **关闭态 speaker + @mention** = speaker 普通轮 + mention 强制轮（两者都跑）。
- 用户消息里的 `@显示名` 解析成成员 id；`@mention` 在开关关闭时也生效，且在开启态的首个反应轮强制——触发可以是该用户消息，也可以是 speaker 对该用户消息的公开回复。

**D. 异步发送、内部串行执行器与取消**
- **BREAKING**：`group.send` 不再等链结束，也**永不因链在跑拒绝用户**。写完用户消息（若有文本）、把请求交给执行器后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`；模型生成与链在后台跑，进度经 `group.chain` 与 `group.chain.completed` 观察。定向 speaker 轮也异步。
- **内部串行**：每组一个吸收式执行器，同一时刻至多一条链在写原文；链运行中新用户消息照写，执行器在轮边界吸收（更新 `triggerSeq`、重置该用户触发的预算），定向/mention 请求按序执行；`busy` 只作状态指示（活动指示/取消按钮），**不作发送拒绝**。
- `agent.cancel` 组路由 SHALL 能停整条反应链（不只取消当前成员）并**清空排队**，回包带 `reactionChainStopped`；带 `memberId` 取消链中**排队**成员时 `cancelled:false` + `reactionChainStopped:true`，不谎报取消。
- `group.list` 的组项带 `busy` / `runningMemberId`，`group.chain` 给出当前/最近一条链的 `status` / `rounds`（当前用户触发已消耗轮数）/ `triggerSeq` / `stopReason` / `steps`；链结束发 `group.chain.completed`（`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`）。

**E. RPC / web**
- `group.create` / `group.update` 带 `reactionsEnabled` 与 `maxRounds`（可空 = 默认；`group.update` 显式 null = 恢复默认）；`session.list` / `group.list` 序列化两者。
- `group.send` 只返回 `started`（**永不 busy**）；`group.chain` 返回链的 `steps`（0..N 条，`source ∈ {speaker, mention, reaction}`、`status ∈ {replied, passed, forced_pass, forced_empty, empty, failed, cancelled}`；`passed`/`forced_pass` 来自 `group_react.pass`，`replied` 来自 `pass=false` + 非空 `message`）；不再在 `group.send` 结果里给 `steps/rounds/finalText`。
- 复用既有 `agent.event`（只新增 `group.chain.completed`）：**组成员运行**的事件带 `groupId` + `memberId`；**组服务自己写入**的用户消息只带 `groupId`（无成员可归，不伪造 memberId）。`forced_pass`/`forced_empty` 不走 `turn.failed`，只在 `group.chain` 的 `steps` 里可观察。
- web 组视图：自发反应开关、**反应轮数上限输入框**（`group-round-cap`，留空恢复默认）、开关开启时发言人可选、时间线逐条冒出公开回复、成员分栏显示私有过程、流式/链活动指示、取消按钮（重连后仍可用）、`round_cap` 提示；事件仍按 payload 归位。

**F. 不改的东西**
- 单一共享原文、逐成员视图投影、逐视图压缩、私有分栏、最终公开行只存正文、共享工作区全部复用；**用户发送永远接受**（内部执行器串行，不把并发约束外溢成拒绝）；`context-compaction` 与 `agent-config` 需求不改；**不新增任何 `config.json` 配置键**（`reactions_enabled` 与 `max_reaction_rounds` 都是 `sessions` 列）。

### 本期非目标

- 并行反应（B/C 同时跑）；提供无限链模式（上限是强制保险）；token 预算治理（留第二刀，治理须满足失败方案台账 #22 的三条条件）；主持人 agent；自由抢话；轮转；跨组反应；Flutter 组界面。

## Capabilities

### New Capabilities

（无新增能力：自发反应属于既有 `agent-group-chat` 的调度行为。）

### Modified Capabilities

- `agent-group-chat`：`成员发言调度：用户点名` MODIFIED（点名不再是唯一调度来源，改为「反应开关 + 点名可空 + 所有公开消息触发 + 结构化 PASS + 异步发送 + 每条用户触发预算 + 每组上限保险」）；ADDED 自发反应开关与默认值、反应轮数上限可配置（每组）、公开消息触发反应轮、反应轮与结构化 PASS 标记、反应提示词常量、反应链收敛与生命周期、`@` 点名定向响应；`群聊 RPC 面` 与 `web 组视图` MODIFIED（`group.update`、`group.chain`、异步 `group.send`、可空 speaker、上限输入框、反应链展示与取消）。
- `session-persistence`：`组会话、成员表与覆盖层列` MODIFIED（`sessions.reactions_enabled` 与 `sessions.max_reaction_rounds` 两列、模型读写）；ADDED `Schema migration v9 to v11`（v9→v10 加开关列并回填、v10→v11 补上限列，兼容 v10 缺列库；两列、非破坏迁移）。
- `web-core-shim`：`群聊 RPC 面与成员身份事件` MODIFIED（`group.update`、`group.chain`、异步 `group.send`、`reactionsEnabled` / `maxRounds` 序列化、链结束事件）；`组会话的取消与实例路由` MODIFIED（`agent.cancel` 停整条反应链）。

## Impact

- **核心（Dart）**：`lib/models/session.dart`（`reactionsEnabled` 与 `maxRounds` 字段/默认语义）、`lib/services/session_repository.dart`（创建时可带组设置、`updateMaxRounds`、标题缺省判据泛化到组的 `新组`）、`lib/services/database_service.dart`（schema v11 + v9→v11 两段迁移：`oldV <= 9` 开关列、`oldV <= 10` 上限列）、新增 `lib/services/group_reaction.dart`（哨兵判定、`@mention` 解析、反应轮规划、steps/stopReason 常量集合）、`lib/services/group_prompts.dart`（`kGroupReactionPrompt` 默认沉默/few-shot、`kGroupMustRespondPrompt`）、`lib/services/group_service.dart`（**异步链调度器 + 内部吸收式执行器**、组设置、链状态/stopReason、取消/清排队、用户消息写入、`group.list` 的 busy/runningMemberId）、`lib/services/agent.dart`（`reaction` / `mustRespond` 轮、PASS/空白跳过公开写入、结果里带回公开消息与 PASS 标记）、`lib/core/headless_core.dart`（`group.update` / `group.chain`、异步 `group.send` 永不 busy、`session.list`/`group.list` 序列化、用户消息与链结束事件）、`lib/core/event_serialization.dart`（如消息序列化复用）。
- **web**：`web/src/protocol.ts`（`reactionsEnabled`、`maxRounds`、`busy`/`runningMemberId`、`group.update`、`group.chain`、异步 `group.send` 结果）、`web/src/group/model.ts`（发送前校验按开关分流）、`web/src/group/GroupView.tsx`（开关、**上限输入框**、可空发言人、异步发送态与链活动指示、重连后仍可用的取消按钮、`round_cap` 与 `forced_pass`/`forced_empty` 提示）、`web/src/App.tsx`（按成员归位的流式指示、`group.chain` 重连恢复、链结束事件）、`web/e2e/group.mjs` 与新增真实模型页驱动脚本。
- **数据**：SQLite schema 9→11，分两段加两列（v9→v10 `reactions_enabled`；v10→v11 可空 `max_reaction_rounds`）+ 回填旧组 `reactions_enabled = 0`，不删任何行；既有组升级后为安静态、上限为空（用默认 8），新建组默认自发反应；上一轮同步实现升到 v10 的库也由 v10→v11 段补列。
- **文档**：`Docs/user-guide/group-chat.md`（自发反应一节、异步发送与 `group.chain`、上限输入框与默认/范围、关闭态 `[PASS]` 是普通正文、RPC 表、已知限制、取消、`forced_pass` 提示不持久）、`Docs/user-guide/web-core-shim.md`（RPC 表与事件）、`Docs/user-guide/web-management.md`（管理 RPC 表里的群聊方法清单必须含新增的 `group.update` 与 `group.chain`，否则 `web_management_docs_test` 红）、`README.md` 功能索引行；`configuration.md` **不新增键**，并写明 `reactions_enabled` / `max_reaction_rounds` 是组设置（`sessions` 列）。
- **测试**：`test/unit`（哨兵精确判定、`@mention` 解析、反应轮规划、提示词常量、Session 组设置、steps/stopReason 常量集合、文档守卫）、`test/integration`（v9→v11 两段迁移与 v10 缺列库补列、Agent 反应轮 PASS/空白、异步发送在链结束前返回、`group.chain` 进度/终态、达上限优雅停、全 PASS 自然停、并发 send、失败有/无错误行、RPC 面与事件 memberId 分类）、`test/widget`（无新增：组界面在 web）、web vitest + puppeteer、`integration_test`（真实模型笑话场景：等 `started` 后轮询 `group.chain`，验证 `stopReason` 合法且在上限内停止 + 视觉截图）。
- **成本与风险**：N 成员 × 多轮生成烧 token；每组上限（默认 8，范围 1..50）是防失控保险，达上限以 `round_cap` 优雅停，正常聊天靠全 PASS 自然停；`group.send` 已异步，不会因链长挂住发送态。live 验收按 `triggerSeq` 取最后一轮：末轮全 `passed`/`empty`（`all_passed`）或达到 `round_cap`，整体 `status != failed`。
- **依赖**：无新增第三方依赖。
