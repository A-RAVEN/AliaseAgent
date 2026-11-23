## Context

群聊的存储、投影、压缩、私有分栏、web 组视图与 RPC 面已经在前一个 change（已归档的 `agent-group-chat`）落地：一份共享原文、逐成员投影、逐视图压缩、公开行只存正文、组级单运行门、`group.send` 点名一个成员。当前调度是**纯点名制**：`group.send` 必须带一个 `speaker`，一次只运行一个成员；成员之间不会互相接话。

用户实测反馈这种群聊「各聊各的」：A 讲完笑话，B、C 不会自己评价，除非用户再逐个点名。本 change 给群聊加**自发反应**，让成员对用户和其他成员的公开发言产生反应。

用户最新拍板两处（覆盖此前「先不设上限」）：

1. **所有公开消息都触发**（用户消息 + agent 公开回复），自由度最高；
2. **发送改异步 + 反应轮数上限可配置**：`group.send` 写完用户消息（若有文本）、起链后立刻返回，链在后台跑；每组新增 `max_reaction_rounds` 设置（`sessions` 列，界面可改，`null` = 产品默认 8），达上限优雅停止（不是报错），定向 / 点名轮不受上限影响。上限是防失控保险，正常聊天仍靠「全 PASS 自然停」；
3. **没有 directed/reactive 二元模式**：群聊只有一种行为，配一个 per-group 布尔开关 `reactions_enabled`，**新建组默认 `true`**（点名不该是默认体验）；开关关闭时只有被点名（`speaker` / `@mention`）的成员跑，等价旧点名体验。迁移把**既有组行回填 `false`**（保留旧行为）。`group.send` 的 `speaker` 始终可空。

本设计只做**串行第一刀**：一轮反应内成员按序跑，后跑者能看到先跑者的公开回复。并行反应、token 预算治理、主持人 agent、自由抢话、轮转、跨组反应都不在本期。

## Goals / Non-Goals

**Goals:**

- 新建组默认自发反应：每条公开消息都成为反应刺激（轮内串行可见，下一轮触发取轮末最后一条公开 seq），可反应的成员按固定顺序各跑一轮完整 Agent 轮（可调工具，工具过程私有）。
- 生成时沉默：反应轮用 `group_react {pass:true}` 表示「没话说」，不产生公开消息；`pass=false` 的 `message` 才落公开行。不再靠 `[PASS]` 文本全等。
- 收敛有可解释、可测试的机制：全 PASS 自然停 + last-reacted-seq；**另加每组可配置的轮数上限**（默认 8，范围 1..50，界面可改）做防失控保险，达上限以 `round_cap` 优雅停。
- 发送异步：`group.send` 在写完用户消息（若有文本）、起链后立刻返回 `status: started`；链在后台跑，进度经 `group.chain` 与 `group.chain.completed` 可观察，用户随时可取消。
- 点名仍然可用：`speaker` 与 `@显示名` 都定向一个成员；**开启态 speaker 强制轮 + 两态下 `@mention` 强制轮**必应（`pass=true`/空 `message` 记 `forced_pass`/`forced_empty`），关闭态纯 speaker 保持旧普通轮（`[PASS]` 是普通正文）。
- 用户发送永远接受：链执行器在跑时再发也照写用户消息、返回 `started`；内部只有一个执行器串行写原文，`busy` 只作状态指示，不作发送拒绝。
- 组级单运行门内部化：一个执行器/一条链在写原文，链中 `agent.cancel` 能停整条链并清空排队。
- web 组视图能开关自发反应、在开启时不选发言人就发送、逐条看到反应展开、看到流式/反应指示并能取消；链达上限时显示可归因提示。
- 文档与守卫同步：`group-chat.md` / `web-core-shim.md` / `configuration.md` / `README.md`；RPC 表与组设置说明取自代码常量。

**Non-Goals:**

- 并行反应（B、C 同时跑）——串行第一刀；
- 提供「无限链」模式：上限是强制保险；每组值范围 1..50，越界拒绝（`-32602`），`null` = 默认 8，不允许 0 或负数；
- token 预算治理（留第二刀，须满足失败方案台账 #22 的三条条件：量的单位是被保护的资源、阈值由容量派生、触发后降级而不是停摆）；
- 主持人 agent、自由抢话、轮转、跨组反应；
- 改动投影、逐视图压缩、私有分栏、公开行只存正文、共享工作区（全部复用）；
- 把 `reactions_enabled` 或 `max_reaction_rounds` 做成 `config.json` 键（两者都是 `sessions` 列）；
- Flutter 组界面（继续只有 web 组视图）。

## Decisions

### D1 一种行为 + per-group 布尔开关，取代二元模式

`sessions` 表加 `reactions_enabled INTEGER NOT NULL DEFAULT 1`（JSON `reactionsEnabled`）。它是**组的持久属性**，不是每次请求的参数：刷新页面、重启核心后仍在。

- **新建组默认 `true`**（用户明确「点名不应是默认」）：`Session` 构造默认 `true`，`SessionRepository.create` 写入该值。
- **v9→v11 迁移把既有组行回填 `false`**（v9→v10 段加开关列并回填；v10→v11 段补上限列）：升级用户的群聊保持原有点名体验，非破坏；他们可以在界面上打开开关。上一轮同步实现升到 v10 的库也走 v10→v11 段补上限列。
- **单会话行也带该列**，但无行为意义（单 Agent 入口不读它）；写 `true` 即可。
- 关 = 安静态（旧点名体验的 opt-in）；开 = 自发反应。

**否定的备选**：① 两种模式字符串 `mode = directed|reactive`——用户拍板改成单一行为 + 开关；② 存进 `config.json`——它是按组的属性，且配置是全局的；③ 只在内存里存——刷新即丢。

### D2 触发点：公开消息落库之后，由组服务调度

「公开消息」= `visibility = public` 的行：用户消息（`author` 空）或成员的最终公开回复（`author` = 成员 id）。开关开启时，**每条公开消息都会成为反应刺激**：用户消息启动一轮；成员在同一轮内的公开回复会被**该轮里后跑的成员**看到并反应（串行可见，见 D3）；链的下一轮触发取**该轮最后一条公开消息**的 `seq`。这不是对「所有公开消息触发」的收窄，而是串行实现口径——不存在「逐条独立排队、每条再单独起一轮」的第二层队列（见 D3 否定的备选）。

触发点在 `GroupService`，不在 `Agent` 内部：Agent 是「跑一轮」的执行者，不应反向依赖组调度；组服务持有成员清单、链状态、单运行门与取消令牌。

- 用户消息：**所有异步发送**（开关开 / 关、带 speaker 与否）都由 `GroupService` 在返回前写入**一次**（`author` 空、`public`），随后写标题；成员轮一律 `writeUserMessage:false`。这样 `triggerSeq` 在 `group.send` 返回前就已确定，且组服务写的 `user.message` 不带 `memberId`（没有成员可归）。安静态的**成员生成行为**仍逐字不变（普通轮、无反应提示词、无 PASS 判定），变的只是“谁把用户消息写进库”与事件归属——这是异步契约的必要统一。
- 标题：组的第一条用户消息可自动命名，但判据必须同时认组的缺省标题 **`新组`** 与既有 **`New Chat`**；标题不是这两个缺省值（用户已命名）时**不改**。`updateTitleIfDefault` 目前只认 `New Chat`，不泛化就会让组标题永远停在 `新组`，因此这条要与用户消息写入同批落地。
- 成员公开回复：`Agent.send` 把本轮写入的公开消息带回结果（`AgentRunResult.publicMessage`），组服务据此推进触发 `seq`，不需要额外查询「最新公开行」。
- `group_react {pass:true}` / 空 `message` 不产生公开消息，因此不会推进触发。

**否定的备选**：在 `Agent` 里写库后直接回调调度器——Agent 会依赖组服务，单 Agent 会话也被迫携带组逻辑；用 `message.query` 轮询最新行——多一次查询且区分不了 PASS。

### D3 反应链：一轮怎么跑、怎么停

术语：**触发** = 一条公开消息的 `seq`；**反应轮** = 针对一个触发、把当前可反应的成员按序各跑一轮。链 = 连续的反应轮。

**可反应成员（`planReactionRound`）**：

- 仍在组里（`removed_at` 为空）；
- 不是触发消息的作者（不自己反应自己）；
- `lastReactedSeq[member] < triggerSeq`（成员只对更新的公开消息反应）；
- 本次发送**用户文本里被 `@` 点名**的成员排在最前（按点名出现顺序）；`@mention` 在**首个反应轮**强制——触发可以是该用户消息，也可以是 speaker 对该用户消息的公开回复（见 D4）；其余按**加入顺序**（`created_at`、`rowid` 兜底）。

**一轮的执行**：按上述顺序**串行**跑；每个成员开跑前先 `assembleMemberView()` 增量装配（这样后跑者能看到先跑者刚落库的公开回复）；每个成员开始前把 `lastReactedSeq[member] = triggerSeq`（即使它 PASS/失败，也算「已经对这条反应过」）；成员各自的 `Agent.send(writeUserMessage: false, reaction: true, mustRespond: 是否被点名)` 跑完整 Agent 轮（工具过程落在 private 行）；公开回复由 Agent 写库并带回 `publicSeq`。

**执行器模型（吸收式长驻，不用 busy 拒绝用户）**：每个组一个链执行器，**同一时刻至多一条链在写原文**，但这是内部调度细节。`group.send` **永不因链条在跑拒绝用户**：写用户消息（若有文本）后把请求放入执行器的有序队列、唤醒执行器、立即返回 `started`。执行器串行处理：

- 队列里的定向 / mention 请求按顺序执行（用户点名必应）；
- 每次反应轮开始前**吸收最新用户触发**：若队列里有更新的用户消息，更新 `trigger`、把「当前用户触发的预算」`rounds` 重置为 0，再继续反应；
- 同一时刻只有一个成员在跑，公开行串行写入，不会交错；
- 队列空且没有可反应成员时结束，写 `stopReason` 并发 `group.chain.completed`；
- 取消时停当前链并**清空排队**（已写入的用户消息保留，用户可重发）。

**链的推进与停止**：

```
trigger = 最新公开消息 seq（speaker-only 且没有公开回复时为 null）
rounds = 0                       // 当前用户触发已消耗的反应轮；新用户触发重置
lastRoundHadReplies = false
loop:
  if 队列里有新的用户请求:
     取出并串行执行它的定向 / mention 轮（若有）
     trigger = 最新公开 seq（或该用户消息 seq）
     rounds = 0                  // 新用户触发 = 新预算
     continue
  responders = planReactionRound(trigger)
  if responders.isEmpty:
     if 队列非空: continue       // 还有用户请求要处理
     stopReason = (rounds == 0) ? no_members
                : (lastRoundHadReplies ? no_members : all_passed)
     break
  if rounds >= maxRounds:
     if 队列非空: continue       // 新用户触发会重置预算
     stopReason = round_cap; break
  rounds += 1
  lastRoundHadReplies = false
  roundLastPublicSeq = null
  for m in responders:           // 同一个 trigger 的整轮，串行
     if cancelled: stopReason = cancelled; break
     lastReacted[m] = trigger
     result = run(m, trigger, mustRespond: forced)
     若 result 硬失败: stopReason = failed; break
     若 result 产生公开消息: lastRoundHadReplies = true; roundLastPublicSeq = result.publicSeq
  if stopReason in {cancelled, failed}: break
  if roundLastPublicSeq != null: trigger = roundLastPublicSeq
```

**`stopReason` 封闭枚举**：`all_passed`（队列空、至少跑过一轮、最后一轮没有产生任何公开消息且已无可反应成员）/ `round_cap`（队列空、还有可反应成员但当前用户触发的反应轮数已达上限）/ `cancelled` / `failed` / `no_members`（队列空但规划不到可反应成员：首轮就无人，或上一轮有回复但已无人可接；安静态定向轮集合跑完后也归这里）。链状态 `status ∈ {idle, running, completed, cancelled, failed}`。

**上限的 per-用户触发语义**：`maxRounds` 是**每条用户触发一份反应预算**——用户新发一条消息（含 speaker-only 的用户动作）重置 `rounds = 0`；agent 自己的公开回复**不重置**预算；没有新用户消息的纯 agent 自主链受同一预算约束，到顶 `round_cap` 停。被 `@` 点名的强制成员属于首个反应轮，只计一轮；显式 `speaker` 定向轮与安静态 `@mention` 定向轮是用户点名，不计数、不被上限拦截。检查顺序是「先看有无新用户请求、再规划、后查上限」：若这一轮本该自然停，报 `all_passed` / `no_members`，不误报 `round_cap`。

**两条收敛防线 + 一道保险**：① 全 PASS 自然停（停止条件是「没有可反应成员」，不是另写「本轮无回复就 break」）；② last-reacted-seq（成员只对更新的公开消息反应，避免同一条反复接话）；③ 每条用户触发的轮数上限（正常聊天不该用到，只有模型持续不沉默时才由它兜底；用户随时发新消息就能重新获得预算）。

**异步执行模型**：`group.send` 只做同步前置（组/成员/两个前置门）、写一次用户消息（若有文本）与标题、把请求放入执行器队列；执行器空闲则启动后台 Future；然后立刻返回 `status: started`。**没有 busy 拒绝**。链状态的 `steps` 随执行累积；执行器空闲时写终态 `stopReason`、发 `group.chain.completed`。`group.chain` 的 `rounds` 是**当前用户触发已消耗的反应轮数**（吸收新用户消息时重置），`steps` 是本次执行器运行内累积的步骤。核心重启后 `group.chain` 为 `idle`。

**顺序为何是加入顺序**：用户示例「A 讲笑话，B/C 评价」按 A、B、C 加入时，第一轮 A 先讲，B、C 在同轮后跑时已经能在视图里看到 A 的公开回复（B 的回复又会进 C 的视图）——这就是「串行」的可见性来源。设计不承诺「谁先加入谁一定先讲」，只承诺顺序确定、可复现。

**参与范围在链开始时快照**：一条链开始时固定参与成员的范围（成员 id、加入顺序、显示名）；链运行中新加入的成员**不加入当前链**（下一次触发才参与）。移除/编辑成员会先停链，所以快照里的成员不会被改掉或销毁。

**「每条公开消息触发」的串行口径**：同一轮里 A 先回复、B 后跑——B 的视图包含 A 的公开回复，B 就是对「A 的公开消息」作出的反应；这一轮结束后，下一轮触发取该轮**最后一条**公开消息的 `seq`（不是 A、B 各再起一轮）。因此「每条公开消息都被反应」与「链只按轮末最后一条推进」不矛盾：前者由轮内串行可见兑现，后者是触发推进的唯一实现口径。

**为什么选吸收式长驻执行器，而不是排队串行链**：用户连发消息时，排队串行链会让新消息排在旧链后面，用户看到“发了但没人理”；吸收式执行器在轮边界用最新用户触发替换当前触发并重置预算，用户消息**先落库**、下一次反应轮就能看到，既保证不丢内容，也不会让一条长链永久占住组。代价是 `group.chain` 的 `rounds` 会在吸收时重置（它本来就是“当前用户触发的预算”，不是整条执行器的总轮数）；`steps` 仍累积。

**取消与排队**：`agent.cancel` 带 `memberId` 时——该成员正在跑 ⇒ 取消它、`cancelled:true`、`reactionChainStopped:true`；该成员在链的参与快照里但尚未轮到 ⇒ 停整条链并清空排队，返回 `cancelled:false` + `reactionChainStopped:true` + 该 `memberId`；该成员不在链里且不在跑 ⇒ 既有「该成员当前没有在运行」语义，不冒领停链。不带 `memberId` 时停链、取消当前成员并清空排队。已写入的用户消息保留，用户可重发；链状态 `cancelled` 并发 `group.chain.completed`。

**否定的备选**：并行反应（写入顺序与归属不可复现）；按「谁空闲谁先」——不可复现；对每条公开消息起一个独立队列——同一 `seq` 会被反复排队，需要额外的去重表，且与「轮末最后一条推进」重复；`group.send` 等整条链跑完再返回——真实模型下发送态会长时间挂起；用 `busy` 拒绝链运行中的用户发送——把内部并发约束外溢成对用户输入的拒绝，用户已明确否决（台账 #28）。

### D4 定向与触发的关系：speaker 先跑，链从它的公开回复（或用户消息）起步

**所有分支都异步返回**：`group.send` 在前置校验、写用户消息（若有文本）与标题之后立刻返回 `status: started`；下面的 speaker / mention / 反应轮都在后台执行。下面的「先跑」指后台执行顺序，不是 RPC 返回顺序。用户消息写入与 `triggerSeq` 在返回前就已确定；speaker 的公开回复 seq 只能在后台确定，所以 speaker-only 的 `triggerSeq` 初始为 `null`，由 `group.chain` 更新。

开关开启时：

- **带 `speaker` + 带文本**：组服务先写用户消息（一次），再让 speaker 跑一轮**强制轮**（`mustRespond: true`），并把 `lastReactedSeq[speaker] = 用户消息 seq`（它已经对这条用户消息做过响应）。speaker 产生公开回复 ⇒ 链的首个触发 = 该回复的 `seq`；speaker 没有产生公开回复（PASS/空输出）⇒ 链的首个触发 = **用户消息 seq**，让 `@mention` 和其他成员仍有反应机会。
- **带 `speaker` + 不带文本**：不写用户消息；speaker 强制轮照旧受两个前置门（空视图 / 本人 assistant 结尾）约束；有公开回复则从该回复起链，否则链没有触发、直接结束。
- **不带 `speaker` + 带文本**：写用户消息，以它的 `seq` 起链。
- **不带 `speaker` + 不带文本**：没有可触发的公开消息 ⇒ 可归因错误 `no_trigger`（不写任何行）。
- 用户消息里的 `@mention` 只在**首个反应轮**（触发为该用户消息或 speaker 的公开回复，二者都算对该用户消息的响应）强制；之后的 agent 公开回复里的 `@` 只是正文，不再解析（只有用户消息的 `@` 触发点名）。

开关关闭时（安静态）**三态钉死**：

- **有 `speaker`、无 `@mention`（纯点名）**：组服务已先写用户消息（若有文本）；speaker 在后台跑普通轮，**生成行为逐字不变**——不追加反应提示词、不追加必应提示词、不做 PASS 判定；`[PASS]` 按旧行为是普通正文（照常落公开行）。
- **有 `speaker`、有 `@mention`**：speaker 先跑普通轮（同上；用户消息已由组服务写），随后按点名顺序各跑一轮 **`@mention` 强制轮**（`kGroupMustRespondPrompt` + 结构化检测；`pass=true`/空 `message` 记 `forced_pass`/`forced_empty`，不写公开行）。两者都跑，`steps` 里 source 分别为 `speaker` / `mention`。
- **无 `speaker`、有 `@mention`**：组服务写用户消息一次，然后按点名顺序各跑一轮强制轮；**不起反应链**。
- **无 `speaker`、无 `@mention`**：可归因错误 `no_speaker`（不写任何行）。

**为什么开启态 speaker 的 `pass=true` 也要让链从用户消息起**：否则「@B 被点名必应」会被一个拒绝回应的 speaker 吞掉；从用户消息起链能让被点名者仍拿到响应机会。开启态 speaker 的 `pass=true` 不会写进时间线，只在结果里记 `forced_pass`；关闭态纯 speaker 的 `[PASS]` 只是普通正文（旧行为），不参与这套语义。

### D5 结构化 PASS：`group_react` 终态工具

`Agent.send` 增加 `reaction` 与 `mustRespond` 两个标志（只在组成员实例上使用；`mustRespond` 蕴含 `reaction`）：

- **适用面**：`reaction:true` 只用于 ① 开启态 speaker 的强制轮；② 两态下 `@mention` 的强制轮；③ 开启态的自愿反应轮。**关闭态纯 speaker（无 @）不置 `reaction`**，走普通轮。
- **提示词**：`reaction && mustRespond` 追加 `kGroupMustRespondPrompt`；`reaction && !mustRespond` 追加 `kGroupReactionPrompt`。成员角色说明 `kGroupMemberRolePrompt` 仍在实例创建时追加，两者分工不同。
- **终态控制工具**：`reaction` 轮的请求 SHALL 注入 `group_react`，`input_schema` 为 `{pass: boolean, message: string}`（两者必填；`pass=true` 时 `message` 可空且被忽略）。它是**控制工具**，不是 `ToolCatalog` 里的普通工具：只在该轮出现在 tools JSON 中；Agent 的模型循环**拦截**它的调用（不交给工具执行器、不写 tool 行），并立即结束本轮。模型 MUST 在结束本轮时调用它恰好一次。
- **判定**：读 `pass` 布尔，不读正文：
  - `pass=true` ⇒ 不写公开行、不发 `assistant.message`、不调用 `onAssistantMessage`；**无论 `message` 写了什么**（包括「我这回合不发言，等其它模型」这类元话术）都吞掉。
  - `pass=false` ⇒ 公开行只写 `message` 字段内容；`message.trim().isEmpty` ⇒ 不写公开行，自愿轮记 `empty`、强制轮记 `forced_empty`。
  - 没有调用 `group_react` / 参数非法 / 同一轮多次调用 ⇒ **先纠正重试**：向模型回一条 user 轮纠正消息（内容形如「你没有正确调用 group_react……本轮必须调用恰好一次，参数为 {pass, message}，请重新调用」），类比工具执行失败后的错误反馈，然后继续模型循环；纠正重试上限是产品常量 `kMaxGroupReactRetries = 2`（用户 2026-11-23 拍板「像工具失败那样要求它重来」并建议 2 次：一次覆盖漏调用，第二次覆盖先口头答应再补调用；再多只重复烧 token，不是配置键）。超过上限仍不合规才该步 `failed`（`error: missing_group_react` 或 `invalid_group_react`），不写公开行；**任何情况下都不回退到 `[PASS]` 文本匹配**。重试计数按成员轮累计，自愿轮与强制轮都适用。
  - 反应轮模型正文里的叙述（包括「我选择 PASS」「[PASS]」）不进入公开时间线；只有 `message` 能成为公开内容。
- **返回值**：`AgentRunResult` 增加 `publicMessage`（本轮写入的公开消息，沉默/空输出/失败时为 `null`）与 `reactionPassed`（来自结构化 `pass`）。`finalText` 保留 `message` 便于测试与调用方观察；**时间线里看不到被 `pass=true` 吞掉的文本**。
- **强制轮**：同样注入 `group_react` 并读 `pass`；`pass=true` ⇒ 该步 `forced_pass`（可归因失败），`pass=false` + 空 `message` ⇒ `forced_empty`；都不写公开行、不发 `turn.failed`。
- 普通轮（单会话、**关闭态纯 speaker**、非反应轮）不注入 `group_react`、不看 `pass`，行为逐字不变；`[PASS]` 在这些轮里仍是普通正文。

**为什么用工具调用，而不是文本哨兵 / 纯 JSON**：工具调用是模型 API 的**天然结构化输出**（`input_json` 由 API 保证是 JSON），比让模型在正文里输出纯 JSON 可靠，也不需要「整条 trim 全等」这种脆弱匹配；文本哨兵正是本轮被用户否决的点——模型说「我这回合不发言，等其它模型」不等于 `[PASS]`，就会漏进时间线。终态工具还能在协议层表达「本轮结束」：调用即结束，不需要从正文猜。

**否定的备选**：① 文本哨兵 `[PASS]` 整条全等（用户实测模型不遵守，元话术漏公开；已否决）；② 让模型输出纯 JSON 正文（多一层解析失败面，且正文混入解释时无法可靠抽取）；③ 事后从公开行里删 `[PASS]`（已写库、已广播，时间线脏了再擦）；④ 用「包含 `[PASS]`」判定（会吞掉真实发言，且语义被放宽）。

### D6 提示词常量：授权沉默与必应分工

`lib/services/group_prompts.dart` 增两个常量：

- `kGroupReactionPrompt`：**开启态自愿反应轮**用（不是被点名轮）。必须指示模型用 `group_react` 工具返回 `{pass, message}`，并采用「**默认沉默**」框架：沉默是常态、发言是例外，大多数轮应返回 `pass=true`；只有非说不可、别人没说过的实质新信息才 `pass=false`；`pass=true` 不是失败，是群聊礼仪。必须覆盖：**3–4 个该 `pass=true` 的 few-shot 情形**（别人已表达过类似观点 / 纯表态无新依据 / 对话已充分收尾 / 与你的角色无关）、**相关性门槛**（只反应真正新且与你相关的信息）、有依据的同意 / 反对 / 补充 / 提问才算贡献、**不要在正文写「我 PASS / 我不发言」之类元话术**、`message` 是唯一公开内容、发言自包含（结论 + 文件指针）。它必须**强烈授权沉默**，否则模型会倾向永远接话。
- `kGroupMustRespondPrompt`：**开启态 speaker 强制轮 + 两态下 `@mention` 强制轮**用。必须说明「用户点名了你，这一轮必须给出实质回应」，并指示调用 `group_react {pass: false, message: "..."}`；它**不包含** `pass=true` 的沉默授权，避免与必应冲突。**本轮不修改它的必应口径**。

两者都是**代码常量**，理由与 `kGroupMemberRolePrompt` 相同：单测与文档守卫能逐字断言「提示词里真的写了这几句」，否则「纪律只写在 spec 里」无法验证。结构化判定对**置了 `reaction` 的轮次**生效（防御模型不服从）：强制轮 `pass=true`/空 `message` 记 `forced_pass`/`forced_empty`，不会静默；关闭态纯 speaker 普通轮两段都不追加、也不注入 `group_react`（旧行为）。

**否定的备选**：把两段拼成一个常量再按标志裁剪——拼接处容易漏句，测试也只能断言片段；把沉默授权写进成员角色说明——那会让普通点名轮也获得沉默许可。

### D7 失败、取消与结构操作

- **链状态与结束事件**：每个执行器运行建一条链状态，字段见 D9。执行器空闲时：写 `status` / `stopReason`、释放内部执行器占用、通过 `agent.event` 发一条 `group.chain.completed`（`type` 为该值，携带 `groupId` / `sessionId` / `status` / `stopReason` / `rounds` / `triggerSeq`）。**这是本 change 唯一新增的事件类型**；其余仍复用既有事件类型。
- **成员轮硬失败**（`AgentRunResult.isFailed`）：失败**不一定**写公开 `Error: …` 行——provider 报错路径会写，`_callModel` 抛异常 / 超过 50 轮工具上限等路径只返回 failed、不写行。执行器**中止当前链并清空排队**，链状态记 `status = failed` / `stopReason = failed`，步骤里带失败成员的 `memberId` 与错误；如果失败产生了公开 `Error: …` 行，该行**不触发下一轮**（链已中止），但仍留在时间线（诚实）。理由：错误行若继续被反应，其他成员会对着「Error: …」接话。
- **被点名者不回应**：`forced_pass` / `forced_empty` **不是整轮失败**，不用 `turn.failed`（否则界面会显示「整轮失败」而链其实继续）。它们只体现在 `group.chain` 的 `steps` 里；web 在 `group.chain.completed` 后读链状态提示，或从步骤里读。该提示**不持久**：刷新后历史里没有这条提示（没有公开行、没有额外私有行），group-chat.md 必须写明这个已知限制；不能读成「已持久化告警」。
- **取消**：`GroupService.cancel` 先看该组是否有执行器在跑；有则按 D3 的「取消与排队」处理：不带 memberId ⇒ 停链 + 取消当前成员 + **清空排队** + `cancelled:true` + `reactionChainStopped:true`；带 memberId 且该成员在跑 ⇒ 取消 + 清空排队 + `cancelled:true`；带 memberId 且该成员在链里但尚未轮到 ⇒ **停整条链并清空排队** + `cancelled:false` + `reactionChainStopped:true` + 该 memberId。链状态记 `status = cancelled` / `stopReason = cancelled` 并结束事件。没有链时保持既有语义（组内没有成员在运行 = 真话，不是「查不到实例」）。**已写入的用户消息保留**，用户可重发。
- **安静态定向轮**：也异步执行，但**不计反应轮**；执行器在定向 / mention 轮全部结束后进入 `completed`，`stopReason = no_members`（没有反应轮可跑），`rounds = 0`。它不消耗该组的轮数上限，也不被上限拦截。
- **结构操作**（移除成员 / 编辑成员 / 删组）：先停链并清空排队（标 cancelled + 取消当前成员），再执行既有动作；这样链不会在成员被销毁后继续调用它。
- **`group.update`（改开关 / 上限）**：链运行中仍返回 busy（它不是用户消息；只影响设置）。**用户消息发送永远不因链在跑被拒绝**；`group.send` 只受参数/上下文错误影响。
- **内部串行执行器**：每个组一个执行器，同一时刻至多一条链在写原文；`group.send` 写用户消息后把请求入队并唤醒执行器，**不返回 busy**。执行器在反应轮边界吸收最新用户触发（更新 trigger、重置该用户触发的预算），队列里的定向/mention 请求按序执行；不会出现两条链并发写公开行。
- **可观察的忙碌状态**：`group.list` 的组项带 `busy` 与 `runningMemberId`（只表示执行器在跑、供活动指示/取消按钮，**不是发送拒绝条件**）；`group.chain` 给出完整链状态。

### D8 存储与迁移（schema v9 → v11）

1. `_schemaVersion` 9 → 11。
2. `_onCreate`（v11）的 `sessions` 建表语句加 `reactions_enabled INTEGER NOT NULL DEFAULT 1` 与 `max_reaction_rounds INTEGER`（可空）。
3. `_onUpgrade` 分两段，**不能合并**：① `if (oldV <= 9)` 只加 `reactions_enabled` 并回填组行 0（**不要在这个分支加 `max_reaction_rounds`**）；② `if (oldV <= 10)` 只加 `max_reaction_rounds INTEGER`。第二段覆盖两类库：从 v9 及更早升上来的（第一段刚加完开关列），以及**上一轮同步实现已经升到 v10、但缺上限列**的真实用户库（版本号在同步→异步返工之间撞车）。两段都只加列、不删行；既有无上限值的行保持 `NULL`（= 用产品默认 8）。
4. `openAt` 与生产 `_init` 共用同一份 `_onCreate` / `_onUpgrade`（既有规范）。
5. `Session`：`reactionsEnabled` 字段（构造默认 `true`）与 `maxRounds` 字段（可空，`NULL` = 默认）；`toRow` 写两列；`fromRow` 对 `reactions_enabled` 的缺列/为 null 仍按 `false` 解释，对 `max_reaction_rounds` 的缺列/为 null 读成 `null`；`copyWith` 支持改两者。
6. `SessionRepository.create` 增可选 `reactionsEnabled` 与 `maxRounds`（缺省 `true` / `null`）；新增 `updateReactionsEnabled(id, bool)` 与 `updateMaxRounds(id, int?)`（`null` = 恢复默认），供 `group.update` 用。
7. 迁移只加列 + 回填，**不删任何行**；升级产物与全新建库的结构用 `PRAGMA table_info` 逐项比对。回退只能靠迁移前备份数据库（版本只向前）。

**「新默认 true / 旧行回填 false」的差别是刻意的**：新建组享受新体验；升级用户的既有组保持旧点名行为，直到用户自己打开开关。文档必须把这个差别写清楚，否则升级用户会以为「怎么没反应」。

### D9 RPC 面

- `group.create`：参数增 `reactionsEnabled?`（布尔，省略 = 新建组默认 `true`）与 `maxRounds?`（整数 1..50，省略/`null` = 用产品默认）。
- **`group.update`**：`{groupId, reactionsEnabled?, maxRounds?}`；至少给一个字段；`reactionsEnabled` 必须布尔；`maxRounds` 必须是 1..50 的整数或显式 `null`（`null` = 恢复默认，**与字段缺席不同**：缺席 = 不改）。字段缺失 / 类型不对 / 越界 ⇒ `-32602`；组不存在 ⇒ 可归因错误（带 groupId）；链运行中 ⇒ busy 结果。它仍只做组设置，不扩成通用 update。
- **新增 `group.chain`**：`{groupId}`；返回当前 / 最近一条链的状态 `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps}`。`status ∈ {idle, running, completed, cancelled, failed}`（`idle` = 本进程内还没有链）；`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`（运行中为 null）；`rounds` 是**当前用户触发已消耗的反应轮数**（执行器吸收新的用户消息时重置；agent 自主回复不重置）；`steps` 是本次执行器运行内累积的步骤，沿用 D9 的封闭 `source` / `status` 取值。核心重启后回到 `idle`（与 `group.view` 的「本次运行内」先例一致）。
- `group.send`：**异步契约**——`speaker` 可选字符串（出现时必须非空，类型不对仍 `-32602`）；同步前置校验（组/成员/两个前置门）与用户消息写入完成后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`，模型生成与链在后台跑。**`group.send` 永不返回 busy 拒绝用户**：执行器在跑时新请求入队/被吸收，用户消息照写、响应照回。`triggerSeq` 在带文本时为用户消息 seq，speaker-only 时为 null（由 `group.chain` 后续更新）。结果**不携带** `steps` / `rounds` / `finalText` / `memberId`。
  - 开关开：无 speaker + 无文本 ⇒ `no_trigger`；有文本 ⇒ 写用户消息 + 入队。
  - 开关关：无 speaker 且无 `@mention` ⇒ `no_speaker`；有 `@mention` ⇒ 只跑被点名者（含 speaker 时 speaker 普通轮 + mention 强制轮），同样后台执行。
- `session.list` / `group.list` 的会话序列化增 `reactionsEnabled`（布尔）与 `maxRounds`（整数或 null；null 表示用默认，客户端以默认占位显示）。`group.list` 的每个组项增 `busy`（布尔）与 `runningMemberId`（字符串或 null），**只表示执行器在跑、供活动指示/取消按钮，不是发送拒绝条件**。
- **链的 `steps`**：0..N 条，`source ∈ { speaker, mention, reaction }`；`status ∈ { replied, passed, forced_pass, forced_empty, empty, failed, cancelled }`；另有 `memberId` / `triggerSeq` / `publicSeq` / `finalText` / `error`。这些取值是 RPC 契约，代码里用常量集合定义、spec 引用它；`steps` 只用于观察与测试，**不是第二套消息存储**。
- **`group.chain.completed` 事件**：唯一新增的事件类型（其余仍复用既有 `agent.event` 类型）。payload 为 `{groupId, sessionId, status, stopReason, rounds, triggerSeq}`；`steps` 不塞进事件，需要时查 `group.chain`。组成员运行的事件仍带 `groupId` + `memberId`；组服务写的用户消息只带 `groupId`（不伪造 memberId）；`forced_pass` / `forced_empty` 不走 `turn.failed`。
- `kCoreRpcMethodNames` 加 `group.update` 与 `group.chain`；`web/src/protocol.ts` 的 `GROUP_RPC_METHODS` 同步；三个文档守卫一起更新：`test/unit/group_docs_test.dart` 的精确计数（8→10）、`test/unit/web_core_docs_test.dart` 与 `test/unit/web_management_docs_test.dart` 的整份文档子串清单（后者会遍历 `kCoreRpcMethodNames` 全表，**漏改 `web-management.md` 会红**）。

### D10 web：开关、可选发言人、展开与取消

- **开关**：组视图头部 `<input type="checkbox" data-testid="reactions-toggle">`，初值 `group.reactionsEnabled`；切换调 `group.update`，成功后重拉 `group.list`；链运行中禁用。
- **轮数上限输入**：开关旁边 `<input type="number" min="1" max="50" data-testid="group-round-cap">`；当前值取 `group.maxRounds`，为 `null` 时**留空并用默认值占位**（显示“默认 8”）。失焦或回车保存：留空 ⇒ `group.update {maxRounds: null}`（恢复默认）；填整数 ⇒ `group.update {maxRounds: N}`；越界由核心返回可归因错误，界面不静默改正。链运行中禁用。
- **发言人**：开关开时发言人下拉第一项是「（不点名，仅触发反应）」，默认空；空 + 有文本可发送，空 + 空文本在本地拒绝（`no_trigger` 文案）。开关关时保持旧下拉与旧本地校验；文本里含 `@` 时允许空发言人（`@` 是否有效由核心裁决，**前端不复制 mention 解析规则**）。
- **展开**：时间线仍是 `message.query` 的一页数据派生的；每个成员的公开回复落库后触发 `assistant.message` 事件，App 收到组事件即重拉 `group.list` / `message.query` / `group.view`，所以时间线会逐条冒出公开回复，私有分栏也会长出该成员的工具行。**反应轮也更新 `_lastSnapshots`**：成员跑过反应轮后 `group.view` 返回的是它实际发出的那份上下文（systemPrompt 含对应反应提示词），不是「本次运行内只记点名的轮」。
- **异步发送态**：`group.send` 返回 `started` 即清除 `sending`（**不等链结束**）；**发送按钮永远可用**——链运行中再次发送也接受（新用户消息照写、执行器吸收/排队），不存在「发送未开始」的 busy 提示分支。链进行中另用 `chainRunning` 表示；其来源：`started` 响应先把组标成进行中；之后 `agent.streaming` / `assistant.message` 事件持续刷新；`group.chain.completed` 清除；重连时用 `group.chain`（`status = running`）与 `group.list.busy` 恢复。
- **上限提示**：`group.chain.completed` 的 `stopReason = round_cap` 时显示「已达轮数上限（反应已停止；可继续点名，或调大该组的反应轮数上限）」；`all_passed` 不提示（正常收敛）。
- **取消**：`group-cancel` 按钮在 `chainRunning || streamingMembers 有成员 || group.busy` 时可用，调 `agent.cancel {sessionId: group.id}`（停当前链 + 清空排队），随后重拉 `group.chain` / `group.list`。断线重连后按钮不会因为本地状态丢失而禁用。
- **被点名者拒绝**：`group.chain.completed` 后查 `group.chain` 的 `steps`，若有 `forced_pass` / `forced_empty`，`onError` 提示「被点名的成员没有回应（返回 pass=true / 空 message）」——不伪造发言，也不让结构化沉默进时间线。提示只来自本次链状态，**刷新后不再显示**（历史里没有这条提示）；group-chat.md 写明这个已知限制。
- 组件仍是纯展示 + 动作：数据由 App 注入，动作走 RPC 后重拉；事件归位以 payload（`groupId` / `memberId`）为判据，DOM 选中值只作辅助。

**否定的备选**：前端复制 `@mention` 解析（两份规则必然漂移）；乐观插入用户消息（与事件重拉重复，且取消/失败时要回滚）；用本地 `sending` 表示整条链（异步后 `sending` 只覆盖 RPC，会错误地显示“空闲”或“发送中”）；新造除 `group.chain.completed` 之外的事件类型（与既有「不新造事件类型」规范冲突）。

### D11 明确不修改的既有能力（核过主 spec 原文）

- **`单一共享原文`**：反应轮的公开行仍只存正文（`tool_calls` / `thinking_json` 为 NULL），私有证据只落 private 行——这条不因 PASS 或反应轮改变。
- **`逐成员视图投影是唯一出口`**：反应轮仍走同一条投影；PASS 只是「不写公开行」，不新增读原文的路径。
- **`逐视图摘要的私有性`**：压缩对象仍是各成员自己的视图；反应轮的公开回复会成为后续视图/摘要的输入，机制不变。
- **`隐私硬边界`**：不新增让成员看到他人私有内容的通道。
- **`成员视图按需装配与规模前置`**：反应轮不改变按需装配；链没有引入缓存容量或批大小。
- **`context-compaction` / `agent-config`**：需求不改。`agent-config` 管的是 `providers` / `agent_types` 与模态，不拥有组级运行设置；`max_reaction_rounds` 的规范落在 `agent-group-chat` 的 ADDED 需求（D13）。本 change **不新增任何 `config.json` 键**：`reactions_enabled` 与 `max_reaction_rounds` 都是 `sessions` 列；`configuration.md` 只写明“它们是组设置，不是配置键”。
- **`web-chat-screen`**：单会话聊天屏不受影响；组视图只是新增控件与指示。
- **`group.view` 的「最近一次真实发出」语义**：需求不改，但实现要覆盖反应轮——`_lastSnapshots` 在**每一次**成员轮结束后更新（含反应轮），否则链跑过的成员在 `group.view` 里会错误地显示「本次运行内没发过言」。
- **主 spec 的 Purpose 需要归档同步**：主 spec `agent-group-chat` 的 Purpose 现在写「发言由用户逐次点名调度」。本 change 归档时由归档子 agent 一并改成「自发反应开关与点名共同调度：关闭态等价旧点名，开启态每条公开消息触发反应轮（轮内串行可见，下一轮触发取轮末最后一条公开 seq）」。本 change 不直接改主 spec（归档流程负责）。

### D12 测试策略与红靶

- **unit**：`parseGroupReactDecision` 的 `{pass,message}` 解析 / 缺字段 / 非法 / 多调用、`parseMentionedMemberIds` 的最长名/边界/去重、`planReactionRound` 的作者排除 / last-reacted-seq / forced 顺序、两个提示词常量逐字（含「有理由的同意」、`group_react`、默认沉默）、Session 的 `maxRounds` 默认/范围/往返、steps 的 `source`/`status` 常量集合。
- **integration**（真 SQLite + 假 sidecar + 临时 configPath / attachmentsDir / lockPath / 工作区，绝不写用户 `~/.aliasagent`）：
  - `test/integration/schema_migration_test.dart`：v9→v11 无损、v10 缺上限列的库→v11 补列、旧组开关回填 false、**旧单会话行 1**、新建组 true、结构指纹一致；
  - `test/integration/agent_reaction_round_test.dart`：`group_react` 注入与终态拦截、`pass=true` 吞元话术、`pass=false` 只公开 `message`、缺 `group_react`/非法参数记 failed、私有工具行仍在、提示词按轮次与适用面、强制轮 `pass=true`/空 `message`、普通轮不注入；
  - `test/integration/group_reaction_scheduling_test.dart`：异步发送在链结束前返回、`group.chain` 进度、触发与轮末推进、串行可见、作者排除、全 PASS 停（`all_passed`）、达上限优雅停（`round_cap`）、last-reacted-seq、开关关闭安静（纯 speaker 的 `[PASS]` 是正文）、`@mention`（含 speaker 回复/`pass=true` 两种 trigger）、**链运行中再发→接受 `started` 且新消息被反应**、**连发多条都接受**、**新用户消息重置 cap 预算**、**内部串行无交错写**、取消（含清空排队）、失败中止（有/无 Error 行）、定向轮不受上限影响、steps 状态词表、`group.view` 反应轮快照、标题缺省判据；
  - `test/integration/group_reaction_rpc_test.dart`：`group.update`（缺字段/非布尔/组不存在）、可空 speaker、`group.send` 异步结果形状（**永不 busy**）、`group.chain` 的 idle/running/终态与 `stopReason`/每用户触发 `rounds`、`group.chain.completed` 事件、`group.list.busy/runningMemberId`（仅状态）、事件 memberId 按事件类型、隔离同前。
- **web**：`web/src/protocol.test.ts` / `web/src/group/model.test.ts`（vitest 纯逻辑）+ `web/e2e/group.mjs`（puppeteer 假核心，payload 判据；假核心要支持异步 `group.send`、`group.chain`、`group.chain.completed`、分步广播、busy 状态）+ 新增 `web/e2e/group_reactions.mjs` 只用于真实核心的视觉/live 驱动（无组时自建组与成员）。
- **live**：`integration_test/group_reaction_live_test.dart`（真实 sidecar + 真实模型 + 无头 Edge 截图；临时 config 副本 / 临时 DB / 临时 lock / 临时工作区）；`test/live/` 镜像入口供无窗口运行。先等 `group.send` 的 `started`，再轮询 `group.chain` 直到终态；断言 `stopReason` 合法、当前用户触发的反应轮不超上限、末轮全 `passed`/`empty` 或 `round_cap`；另在链运行中再发一条，断言被接受且被反应；**打印每轮 passed/replied 比例（沉默率观察）**，理想多数轮 passed 并出现 `all_passed`，至少优于「全 round_cap、零 all_passed」。
- **七个变异红靶**（详见 `tasks.md` 主循环批次）：`group_react` 结构化判定失效退回文本匹配、last-reacted-seq 失效、作者排除失效、关闭开关仍起链、**上限失效（链超上限不停）**、**发送退回同步等待（`group.send` 阻塞到链结束）**、**用户发送退回 busy 拒绝**。每条都必须能让点名的用例变红，否则该用例不算覆盖。

### D13 轮数上限：每组设置（`sessions.max_reaction_rounds`），不是配置键

- **存储**：`sessions` 表加 `max_reaction_rounds INTEGER`（可空；`NULL` = 用产品默认值）。它和 `reactions_enabled` 一样是**组设置**，不是 `config.json` 键；`configuration.md` 与 `group-chat.md` 都要写明这一点。
- **模型与 RPC 字段名**：`Session.maxRounds`（可空）；`toRow` / `fromRow` 读写；`group.list` / `session.list` 序列化 `maxRounds`；`group.create` / `group.update` 接受 `maxRounds`（整数或 `null`）。
- **建议默认 8（产品常量，用户可改）**：典型 3 人群聊的 2–3 个来回约 4–6 个反应轮，再加 2 轮评价/回应余量；不取 3（用户示例 3 层会把正常讨论截断），不取几十（默认就失去保险意义）。`NULL` 时用这个默认，界面上以占位显示。
- **范围 1..50**：界面的数字输入与 `group.update` 都按这个范围校验；越界 / 非整数 / 0 / 负数 ⇒ `-32602`（不静默截断）。留空（显式 `null`）⇒ 恢复默认（列写 `NULL`）。
- **计算**：`GroupService` 在执行器每次吸收用户触发时读 `group.maxRounds ?? kDefaultMaxReactionRounds`；同一用户触发内不再改；改设置只影响后续用户触发（当前预算不追改）。
- **计数口径**：`maxRounds` 是**每条用户触发一份反应预算**。用户新发一条消息（带文本或 speaker-only 的用户动作）重置当前预算 `rounds = 0`；agent 自己的公开回复**不重置**预算；没有新用户消息的纯 agent 自主链受同一预算约束，到顶 `round_cap` 停。被 `@` 点名的强制成员属于首个反应轮，只计一轮；显式 `speaker` 定向轮与安静态 `@mention` 定向轮不计数、不被拦截（D3）。
- **达上限**：**队列为空**且当前用户触发的反应轮数达上限时，链状态 `completed` + `stopReason = round_cap`，并发 `group.chain.completed`；不是错误。若此时队列里已有新的用户请求，执行器先吸收它、重置预算，不误报 `round_cap`。后续点名/定向发送照常可用。
- **规范落点**：`agent-config` 管的是 `providers` / `agent_types` / 模态，不拥有组运行设置；该设置的规范落在 `agent-group-chat` 的 ADDED「反应轮数上限可配置（每组）」；文档守卫从 `Session` 字段名与默认常量取值，`configuration.md` 只声明“它不是配置键”。

## Risks / Trade-offs

- **[沉默偏差：模型倾向永远接话]** → 这是本 change 最大的产品风险。`kGroupReactionPrompt` 已强化为「默认沉默 + few-shot PASS + 相关性门槛」，但提示词是经验活：模型可能仍继续输出「说得好！」这类废话，群会刷屏。单测只能证明「哨兵解析正确」，**证明不了模型会沉默**。因此 **live 真模型验收必做**：笑话例子里 B/C 给实质评价、A 在讲完后对评价轮合理 PASS、链最终收敛或在上限内停下；**并打印每轮 passed/replied 比例作为沉默率观察**。理想是多数轮 passed、出现 `all_passed` 自然收敛；至少应比「全 round_cap、零 all_passed」改善。**诚实标注**：提示词改善是经验性的，`round_cap` 仍是可靠兜底，不保证模型一定沉默。
- **[上限兜底：模型永不 PASS 也不会无限]** → 正常聊天靠「全 PASS 自然停」；每组的上限是防失控保险，达上限以 `stopReason = round_cap` 优雅停，不是报错，定向 / 点名轮不受影响。用户仍可随时 `agent.cancel` 停链；`group.send` 已经先返回，不会因为链长而挂住发送态。
- **[成本]** → N 成员 × 多轮 × 每次生成调用烧 token；串行链越长越贵。上限把单条链的最坏轮数封在组设置值（默认 8，范围 1..50），**token 预算治理仍留第二刀**（台账 #22 的三条条件：量的单位是被保护的资源、阈值由容量派生、触发后降级而不是停摆）。上限只管轮数，不管每轮 token；这是已知代价，不是遗漏。
- **[旧组升级后默认关闭]** → 升级用户打开群聊会发现「没有自发反应」。文档必须写明「新建组默认开、旧组升级默认关，可在组视图打开」；不这样做就是静默行为变化。
- **[被点名者仍可能 pass=true 或空 message]** → 提示词要求必应，但模型可能不服从。我们不伪造发言、不把结构化沉默当公开内容：该步记 `forced_pass` / `forced_empty`，只在 `group.chain` 的 `steps` 里可观察；web 在链结束后提示。这是可归因的失败，不是静默成功；**该提示不持久**（没有公开行，刷新后不再显示），文档要写明。
- **[失败轮不一定有错误行]** → provider 报错会写公开 `Error: …` 行；未预期异常 / 超过工具轮上限只返回 failed、不写行。两种都中止链，链状态 `failed` 并带失败成员；有错误行时它留在时间线但不触发下一轮。
- **[安静态的 `[PASS]` 是普通正文]** → 关闭态纯 speaker 轮不做 PASS 判定，模型若恰好输出 `[PASS]` 会照旧落公开行。这是「安静态 = 旧行为逐字不变」的直接结果；文档要写明，避免用户把它当成漏判。
- **[live 的「实质评价」无法被结构断言证明]** → 结构断言只保留可失败部分（公开行存在、`status=replied`、非空、非 PASS），「实质」靠打印现场 + `read_image` 人读；另加一条测试侧纯恭维（「说得好」「不错」等整条匹配）失败判据，但它只是启发式，不冒充语义检查。
- **[串行顺序依赖加入顺序]** → 「A 先讲、B/C 后评」在 A 先加入时可复现；若用户把 B 先加入，第一轮 B 可能先跑、看到的是用户消息而不是笑话。`@mention` 是让用户显式指定顺序的手段。文档要写清「串行 = 加入顺序」，不承诺智能排序。
- **[链状态只在内存]** → `group.chain` 是“本次运行内”的当前/最近一条链，核心重启后为 `idle`（与 `group.view` 先例一致）；重连不受影响，但重启后看不到旧链的 `steps`。文档要写明。
- **[用户发送不接受 busy 拒绝]** → 这是本轮根性修订：用户在任何时候发消息都必须被接受；`group.send` 只可能因参数/上下文错误（`no_speaker`、`no_trigger`、空视图、本人 assistant 结尾）失败，不因链在跑失败。内部用「吸收式长驻执行器」保证同一时刻至多一条链写原文；新用户消息立即落库，执行器在轮边界吸收并重置预算。取消会停当前链并清空排队，已写入的用户消息保留、可重发。
- **[吸收式执行器的调度复杂度]** → 比“busy 拒绝”复杂：需要执行器队列、轮边界吸收、每用户触发预算重置、取消清队列。代价换来的是「聊天系统永远能发消息」这一 UX 不变量；测试要覆盖连发、吸收、不并发写、取消清队列、cap 重置。
- **[测试夹具与产品默认相反]** → 产品新建组默认开，但既有群聊 integration 测试依赖「点名后只有一个人跑」；夹具 `GroupHarness.create` 缺省 `reactionsEnabled: false`，新反应测试显式传 `true`。这是**夹具口径**，不是产品默认，必须在夹具注释里写清，否则后人会误读产品默认。

## Migration Plan

1. 先落 schema v11（`_schemaVersion` / `_onCreate` / `_onUpgrade` 的 `oldV <= 9` 与 `oldV <= 10` 两段），再改模型与仓储；迁移测试先红后绿。
2. 迁移只做 `ALTER TABLE … ADD COLUMN`：`oldV <= 9` 加开关列并回填旧组 0；`oldV <= 10` 补上限列（覆盖同步实现升上来的 v10 缺列库）；不删行、不改既有列。**旧组开关 = 0、旧单会话开关 = 1、上限 = NULL** 是有意的差异，验收要分别断言（DB 行 + `fromRow`）。
3. 升级产物与全新建库分别取 `PRAGMA table_info(sessions)` 逐项比对（列名/类型/非空/默认值）。
4. 回退：数据库版本只向前；回退代码前必须用迁移前备份的库文件恢复（sqflite 对降级不做静默处理）。真实用户数据不删任何行。
5. 文档同批更新：`Docs/user-guide/configuration.md` 写明 `reactions_enabled` / `max_reaction_rounds` 是**组设置（`sessions` 列），不是 `config.json` 键**；`group-chat.md` 写清界面输入框、默认值与范围。
6. **归档同步**：归档子 agent 要把主 spec `agent-group-chat` 的 Purpose 从「发言由用户逐次点名调度」改为「自发反应开关与点名共同调度：关闭态等价旧点名，开启态每条公开消息触发反应轮（轮内串行可见，下一轮触发取轮末最后一条公开 seq）」，并把 `reactions_enabled` / `max_reaction_rounds` 的组设置口径写进 Purpose 或相关需求；本 change 不直接改主 spec。

## Open Questions

- `kGroupReactionPrompt` 是否需要 few-shot 示例，取决于 live 真模型验收的观察（当前先写一段式常量；若沉默偏差明显，下一刀在同一常量里补一两个「该 PASS / 该发言」的短例）。
- 默认上限 8 是否合适，取决于 live 真模型观察；界面已可改，若多数用户把它改大/改小，再评估默认值。
- `group.chain` 的 `steps` 是否需要在 web 上做“链进度”可视化（当前只用于重连恢复与测试；实时进度靠事件）。
- 关闭态下 `@mention` 多个成员是否要限制数量——当前不限制（按点名顺序串行跑），若真实使用中出现「一条消息点十几个成员」的成本问题，再评估；不预造上限。
