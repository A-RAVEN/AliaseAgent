## ADDED Requirements

### Requirement: 群聊 RPC 面与成员身份事件

核心 SHALL 暴露群聊 RPC：`group.create` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（带发言者指定）/ `group.view`（带成员 id）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`，与 `_registerMethods` 的实现一致（漏注册抛 `StateError`）。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员与原因），MUST NOT 静默失败或崩溃。

`session.list` 返回的每个会话 SHALL 序列化 `kind`（`single` / `group`）与 `overrides`（会话级覆盖层，可空）；组会话 SHALL 以 `kind = group` 让客户端路由到组视图。`group.list` 的每个成员项 SHALL 带成员 id、显示名、模板名、`removedAt`（已移除成员仍返回）、`overrides` 与 `effective`（生效工具清单、生效思考模式与强度）。

组会话的 `agent.event` notification SHALL 在既有 `sessionId` 之外携带成员身份：`groupId` 与 `memberId`。事件**类型与语义** SHALL 继续复用现有模型，MUST NOT 为群聊新造事件类型。`message.query` 返回的每条消息 SHALL 序列化 `author` 与 `visibility`（可空字段如实写出，MUST NOT 静默丢弃）。

`group.view` SHALL 返回该成员**本次运行内**最近一次真实发出的上下文快照（`system` / `messages` / `tools` 加窗口与 breakdown）；该成员本次运行内从未发言时 SHALL 返回空结果（重启后视图为空属既定语义）。SHALL NOT 用历史拼装一份未真正发出的上下文。

既有分页语义 SHALL 保持不变：尾锚默认、`beforeSeq` 反向游标、`anchor=head` 前向游标与 `pageSize` 必填的行为都不因群聊而改变。

#### Scenario: 群聊方法注册且清单一致

- **WHEN** 核心启动并注册群聊 RPC
- **THEN** 每个群聊方法都能被调用，且 `kCoreRpcMethodNames` 与实现一致（漏注册抛错）

#### Scenario: 会话列表带 kind

- **WHEN** 客户端调用 `session.list` 且库里同时有单会话与组会话
- **THEN** 两项都返回且各带自己的 `kind`（组为 group、单会话为 single），客户端可据此分流到组视图或聊天屏

#### Scenario: 成员事件带身份

- **WHEN** 用户先后点名两个成员各发一轮
- **THEN** 两轮的事件 payload 都带同一个 `groupId`（等于组会话 id）与各自的 `memberId`，`sessionId` 字段保留

#### Scenario: 消息查询带作者与可见性

- **WHEN** 客户端对组会话调用 `message.query`
- **THEN** 返回的每条消息都含 `author` 与 `visibility` 字段，私有行的 visibility 为 private-to-author

#### Scenario: 取成员视图只给本次运行内真实发出的内容

- **WHEN** 成员「甲」发言后用 `group.view(甲)` 取快照，成员「乙」从未发言也用同样方法取
- **THEN** 「甲」得到该轮实际发出的上下文；「乙」得到空结果（界面显示占位）

#### Scenario: 群聊方法失败可归因

- **WHEN** 客户端对不存在的组或成员调用群聊方法
- **THEN** 返回带原因与对象 id 的 JSON-RPC 错误，进程继续运行

#### Scenario: 分页语义不回归

- **WHEN** 客户端以 `anchor=head` + `afterSeq`、或以 `beforeSeq`、或不带游标调用 `message.query`
- **THEN** 行为与群聊引入前逐字一致（各自返回对应页与游标）

### Requirement: 组会话的取消与实例路由

组会话没有单 Agent 实例（成员实例按成员句柄注册，见 `agent-group-chat`），因此 `agent.cancel` 在组会话上 SHALL 按组路由，MUST NOT 直接按会话 id 查实例表后返回「该会话没有运行中的 Agent 实例」这种**假原因**：

- 组内没有成员在运行时：返回可归因结果，说明「该组当前没有成员在运行」（这是真话，不是查不到实例）；
- 组内有成员在运行时：取消该成员（组级单运行门保证至多一个），响应 SHALL 带被取消成员的 `memberId` 与 `groupId`；
- 请求显式带 `memberId` 时：只取消该成员；该成员不在运行 SHALL 返回可归因结果（指明成员 id），MUST NOT 静默成功。

#### Scenario: 组内无成员运行时取消

- **WHEN** 组里没有成员在运行，客户端对组会话调用 `agent.cancel`
- **THEN** 返回可归因结果，reason 说明该组当前没有成员在运行（不是"查不到实例"）

#### Scenario: 取消正在发言的成员

- **WHEN** 成员「甲」正在流式回复，客户端对组会话调用 `agent.cancel`
- **THEN** 该成员被取消，响应带 `groupId` 与 `memberId`，并推送该成员的流式收尾事件

#### Scenario: 指定成员取消

- **WHEN** 客户端带 `memberId` 调用 `agent.cancel`，而该成员不在运行
- **THEN** 返回可归因结果并指明成员 id，MUST NOT 返回静默成功
