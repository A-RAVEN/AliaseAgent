## MODIFIED Requirements

### Requirement: 群聊 RPC 面与成员身份事件

核心 SHALL 暴露群聊 RPC：`group.create` / `group.update` / `group.chain` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（发言者可选）/ `group.view`（带成员 id）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`，与 `_registerMethods` 的实现一致（漏注册抛 `StateError`）。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员与原因），MUST NOT 静默失败或崩溃。

`group.create` SHALL 接受可选的 `reactionsEnabled`（布尔；省略 = 新建组默认 `true`）与 `maxRounds`（整数 1..50；省略 / null = 产品默认）。`group.update` SHALL 接受 `{groupId, reactionsEnabled?, maxRounds?}`（至少一个字段；`reactionsEnabled` 布尔；`maxRounds` 为 1..50 的整数或显式 null，显式 null = 恢复默认，字段缺席 = 不改；类型不对 / 越界 / 空对象返回 `-32602`；组不存在返回带 `groupId` 的可归因错误）；反应链运行中 SHALL 返回可归因 busy。`group.list` SHALL 返回 `reactionsEnabled` 与 `maxRounds`，组项 SHALL 另带 `busy`（布尔）与 `runningMemberId`（字符串或 null，链在成员间隙时可为 null），供断线重连后的客户端恢复「链在跑/谁在跑」的判断。

`session.list` 返回的每个会话 SHALL 序列化 `kind`（`single` / `group`）、`overrides`（会话级覆盖层，可空）、`reactionsEnabled`（布尔）与 `maxRounds`（整数或 null；单会话也写，客户端只对组使用）；组会话 SHALL 以 `kind = group` 让客户端路由到组视图。`group.list` 的每个成员项 SHALL 带成员 id、显示名、模板名、`removedAt`（已移除成员仍返回）、`overrides` 与 `effective`（生效工具清单、生效思考模式与强度）。

`group.send` 的 `speaker` SHALL 可选（出现时必须是字符串；类型不对返回 `-32602`）；省略 `speaker` 时由组服务按 `reactionsEnabled` 与 `@mention` 决定响应者。**结果 SHALL 异步且永不 busy**：完成同步前置校验与用户消息写入后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`（带文本时 `triggerSeq` 为用户消息 seq；speaker-only 时为 null）；链执行器在跑时新请求入队/被吸收，不返回 busy 拒绝。结果 SHALL NOT 携带 `steps` / `rounds` / `finalText` / `memberId`，SHALL NOT 等待链结束。

**`group.chain`** SHALL 返回当前 / 最近一条链的状态 `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps}`：`status ∈ {idle, running, completed, cancelled, failed}`；`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`（运行中 null）；`rounds` 是**当前用户触发已消耗的反应轮数**（执行器吸收新用户消息时重置）；`steps` 是 0..N 条，字段与封闭取值是 RPC 契约：
- `source ∈ { speaker, mention, reaction }`；
- `status ∈ { replied, passed, forced_pass, forced_empty, empty, failed, cancelled }`；
- 另有 `memberId` / `triggerSeq` / `publicSeq` / `finalText` / `error`。

`steps.status` SHALL 由 `group_react` 的**结构化 `pass` 标记**派生：`pass=true` ⇒ `passed`（强制轮 `forced_pass`）；`pass=false` + `message` 非空 ⇒ `replied`；`pass=false` + `message` 空 ⇒ `empty`（强制轮 `forced_empty`）；没有调用/参数非法 ⇒ `failed`。MUST NOT 用正文文本 `[PASS]` 全等匹配来派生状态。

`steps` 只用于观察/测试，SHALL NOT 成为消息的第二份存储；核心重启后 `group.chain` 为 `idle`。

**组成员运行**产生的 `agent.event` notification SHALL 在既有 `sessionId` 之外携带 `groupId` 与 `memberId`；**组服务自己写入的**用户消息 SHALL 也发 `user.message`，但只带 `sessionId` + `groupId`，**SHALL NOT 伪造 `memberId`**；标题变化 SHALL 发 `session.title`。事件类型与语义 SHALL 复用现有模型，**唯一新增的事件类型是 `group.chain.completed`**（链进入终态时发，携带 `groupId` / `sessionId` / `status` / `stopReason` / `rounds` / `triggerSeq`）；其余反应链事件仍是既有类型。`forced_pass` / `forced_empty` SHALL NOT 用 `turn.failed` 表达（它们不是整轮失败），只在 `group.chain` 的 `steps` 里可观察。`message.query` 返回的每条消息 SHALL 序列化 `author` 与 `visibility`（可空字段如实写出，MUST NOT 静默丢弃）。

`group.view` SHALL 返回该成员**本次运行内**最近一次真实发出的上下文快照（`system` / `messages` / `tools` 加窗口与 breakdown）；**反应轮也算真实发出**（PASS/空输出没有发出，不算）；该成员本次运行内从未发言时 SHALL 返回空结果（重启后视图为空属既定语义）。SHALL NOT 用历史拼装一份未真正发出的上下文。

既有分页语义 SHALL 保持不变：尾锚默认、`beforeSeq` 反向游标、`anchor=head` 前向游标与 `pageSize` 必填的行为都不因群聊或反应链而改变。

#### Scenario: 群聊方法注册且清单一致

- **WHEN** 核心启动并注册群聊 RPC
- **THEN** 每个群聊方法（含 `group.update` 与 `group.chain`）都能被调用，且 `kCoreRpcMethodNames` 与实现一致（漏注册抛错）

#### Scenario: 会话列表带 kind、开关与上限

- **WHEN** 客户端调用 `session.list` 且库里同时有单会话与组会话
- **THEN** 两项都返回且各带自己的 `kind`、布尔 `reactionsEnabled` 与 `maxRounds`（整数或 null）；组会话新建时 `reactionsEnabled = true`、`maxRounds = null`

#### Scenario: 改组开关可回读

- **WHEN** 客户端调用 `group.update` 传 `reactionsEnabled: false`
- **THEN** 返回更新后的会话（该字段为 false），随后 `group.list` / `session.list` 都读到 false

#### Scenario: 改组上限与恢复默认

- **WHEN** 客户端调用 `group.update` 传 `maxRounds: 6`，随后再传 `maxRounds: null`
- **THEN** 第一次 `group.list` / `session.list` 读回 6；第二次读回 null（= 产品默认），链下一次使用默认上限

#### Scenario: 改组参数非法或组不存在

- **WHEN** 客户端调用 `group.update` 时一个字段都没给、`reactionsEnabled` 非布尔、`maxRounds` 非整数/越界（0、51、负数）、或 `groupId` 不存在
- **THEN** 前三类返回 `-32602`（指明字段），组不存在返回带 `groupId` 的可归因错误；组设置不被改动

#### Scenario: 组项带忙碌状态

- **WHEN** 一条反应链正在跑（或刚跑完一个成员、下一个尚未开始）时客户端调用 `group.list`
- **THEN** 该组项 `busy = true`，`runningMemberId` 是当前运行成员（成员间隙为 null）；链结束后 `busy = false`；`busy` 只作状态指示，**不构成发送拒绝**

#### Scenario: 成员事件带身份

- **WHEN** 用户先后点名两个成员各发一轮
- **THEN** 两轮的事件 payload 都带同一个 `groupId`（等于组会话 id）与各自的 `memberId`，`sessionId` 字段保留

#### Scenario: 消息查询带作者与可见性

- **WHEN** 客户端对组会话调用 `message.query`
- **THEN** 返回的每条消息都含 `author` 与 `visibility` 字段，私有行的 visibility 为 private-to-author

#### Scenario: 查链的状态

- **WHEN** 客户端在没有链、链运行中、链结束后分别调用 `group.chain`
- **THEN** 分别得到 `status = idle`（steps 空、rounds 0、stopReason null）、`status = running`（stopReason null、steps 累积）、终态（status 与 stopReason 在封闭枚举内、steps 完整）

#### Scenario: 发送在链结束前返回

- **WHEN** 客户端调用 `group.send` 触发一条多轮反应链
- **THEN** 响应立即为 `{status: 'started', triggerSeq}`（不含 steps/rounds）；随后 `group.chain` 为 `running`，链结束后才有 `stopReason`

#### Scenario: 链运行中再发也接受

- **WHEN** 一条链正在跑，客户端再次调用 `group.send` 带文本
- **THEN** 响应仍为 `started`（**不返回 busy**）、新用户消息写入；执行器吸收新触发，`group.chain.triggerSeq` 更新、`rounds` 重置；同一时刻仍只有一个成员在写

#### Scenario: 没有可反应成员时链以 no_members 结束

- **WHEN** 组的自发反应开启、组内没有任何可反应成员，客户端调用 `group.send` 只带 `text`
- **THEN** 响应仍为 `started`；`group.chain` 进入 `completed`，`steps = []`、`rounds = 0`、`stopReason = no_members`；用户消息照常写入一条

#### Scenario: 安静态省略 speaker 返回可归因错误

- **WHEN** 组的自发反应关闭，客户端调用 `group.send` 只带 `text` 且文本里没有 `@mention`
- **THEN** 返回 `-32602`，原因指明缺少发言者（`no_speaker`），不写任何消息

#### Scenario: 用户消息事件带 groupId 但不伪造 memberId

- **WHEN** 组服务为一次自发反应发送写入用户消息
- **THEN** 客户端收到一条 `user.message` 的 `agent.event`，payload 带该组 id 与消息字段；`memberId` 缺失或为 null（不伪造成员身份）

#### Scenario: 强制轮失败不用 turn.failed

- **WHEN** `group.chain` 的 `steps` 里出现 `forced_pass` / `forced_empty`
- **THEN** 客户端**不会**收到该步的 `turn.failed` 事件；该步只在链状态的 `steps` 里可观察

#### Scenario: steps 状态由结构化 pass 派生

- **WHEN** `group.chain` 的 `steps` 分别来自 `group_react {pass:true}`、`{pass:false, message:"..."}`、`{pass:false, message:""}`
- **THEN** 对应 step 的 `status` 为 `passed`、`replied`、`empty`（强制轮对应 `forced_pass`/`forced_empty`）；不依赖正文 `[PASS]` 文本匹配

#### Scenario: 链结束事件带 stopReason

- **WHEN** 一条异步链进入任意终态（自然停 / 达上限 / 取消 / 失败 / 无人可反应）
- **THEN** 客户端收到 `group.chain.completed` 的 `agent.event`，payload 带 `groupId` / `status` / `stopReason` / `rounds` / `triggerSeq`；`steps` 通过 `group.chain` 查询

#### Scenario: 取成员视图只给本次运行内真实发出的内容

- **WHEN** 成员「甲」发言后用 `group.view(甲)` 取快照，成员「乙」从未发言也用同样方法取
- **THEN** 「甲」得到该轮实际发出的上下文；「乙」得到空结果（界面显示占位）

#### Scenario: 反应轮也更新成员视图快照

- **WHEN** 一条反应链让成员「乙」跑过一轮（实际发出请求，无论回复还是 PASS）
- **THEN** `group.view(乙)` 返回非空快照，其 `systemPrompt` 含该轮实际追加的反应提示词（`kGroupReactionPrompt` 或 `kGroupMustRespondPrompt`），不是「本次运行内没发过言」

#### Scenario: 群聊方法失败可归因

- **WHEN** 客户端对不存在的组或成员调用群聊方法
- **THEN** 返回带原因与对象 id 的 JSON-RPC 错误，进程继续运行

#### Scenario: 分页语义不回归

- **WHEN** 客户端以 `anchor=head` + `afterSeq`、或以 `beforeSeq`、或不带游标调用 `message.query`
- **THEN** 行为与群聊引入前逐字一致（各自返回对应页与游标）

### Requirement: 组会话的取消与实例路由

组会话没有单 Agent 实例（成员实例按成员句柄注册，见 `agent-group-chat`），因此 `agent.cancel` 在组会话上 SHALL 按组路由，MUST NOT 直接按会话 id 查实例表后返回「该会话没有运行中的 Agent 实例」这种**假原因**：

- **反应链运行中**：SHALL 先停整条链（不再调度后续成员）并**清空排队**，取消当前正在运行的成员（若有）；链状态 SHALL 记 `status = cancelled` / `stopReason = cancelled` 并发 `group.chain.completed`；响应 SHALL 带 `cancelled: true`、`reactionChainStopped: true`，有当前成员时带其 `memberId` 与 `groupId`；
- 组内没有成员在运行且没有反应链：返回可归因结果，说明「该组当前没有成员在运行」（这是真话，不是查不到实例）；
- 组内有成员在运行（无反应链）：取消该成员（组级单运行门保证至多一个），响应 SHALL 带被取消成员的 `memberId` 与 `groupId`；
- 请求显式带 `memberId` 时：**该成员正在链中运行** ⇒ 取消它，响应 `cancelled: true` + `reactionChainStopped: true` + `memberId`；**该成员在链的参与快照里但尚未轮到（排队）** ⇒ 停整条链，响应 `cancelled: false` + `reactionChainStopped: true` + `memberId`（它确实没在运行，不谎报 cancelled）；**该成员既不在链里也没在运行** ⇒ 返回可归因结果（指明成员 id），MUST NOT 静默成功，也不冒领停链（链继续跑）。

#### Scenario: 组内无成员运行时取消

- **WHEN** 组里没有成员在运行、也没有反应链，客户端对组会话调用 `agent.cancel`
- **THEN** 返回可归因结果，reason 说明该组当前没有成员在运行（不是"查不到实例"）

#### Scenario: 取消正在发言的成员

- **WHEN** 成员「甲」正在流式回复（非反应链），客户端对组会话调用 `agent.cancel`
- **THEN** 该成员被取消，响应带 `groupId` 与 `memberId`，并推送该成员的流式收尾事件

#### Scenario: 指定成员取消

- **WHEN** 客户端带 `memberId` 调用 `agent.cancel`，而该成员不在运行
- **THEN** 返回可归因结果并指明成员 id，MUST NOT 返回静默成功

#### Scenario: 取消停整条反应链

- **WHEN** 反应链正在运行（成员「乙」正在流式，后面还排着「丙」），客户端对组会话调用 `agent.cancel`
- **THEN** 响应带 `reactionChainStopped: true` 与当前成员「乙」的 `memberId`；「乙」被取消，「丙」不再开始运行

#### Scenario: 链在成员间隙被取消

- **WHEN** 反应链刚跑完一个成员、下一个成员尚未开始，客户端调用 `agent.cancel`
- **THEN** 响应带 `reactionChainStopped: true`；链状态变为 `cancelled` 并发 `group.chain.completed`，不再启动任何成员

#### Scenario: 带 memberId 取消链中成员

- **WHEN** 反应链中「乙」在跑，客户端带 `memberId = 乙` 调用 `agent.cancel`
- **THEN** 「乙」被取消且链停止，响应 `cancelled: true` + `reactionChainStopped: true` + 「乙」；MUST NOT 让链继续调度其它成员

#### Scenario: 带 memberId 取消链中排队成员

- **WHEN** 反应链中「乙」在跑、后续还排着「丙」，客户端带 `memberId = 丙` 调用 `agent.cancel`
- **THEN** 整条链停止（「乙」的当前轮取消、「丙」不再开始），响应 `cancelled: false` + `reactionChainStopped: true` + 「丙」；不谎报「丙」被取消

#### Scenario: 带 memberId 取消链外未运行成员

- **WHEN** 反应链中「乙」在跑，客户端带 `memberId = 丁`（丁既不在链里也没在运行）调用 `agent.cancel`
- **THEN** 返回可归因「丁当前没有在运行」结果，`reactionChainStopped` 不为 true；「乙」的链继续运行
