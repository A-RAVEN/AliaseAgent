# web-core-shim Specification

## Purpose

规定 AliasAgent 的无头 Dart 核心（复用现有业务 services 与 C++ sidecar）与 web 客户端之间的端到端契约：同一回环 HTTP 服务上提供 WebSocket/JSON-RPC 通道与本机静态服务，并以完整 web 聊天屏完成「发消息 → 流式回复 → 工具卡片」的端到端流程。聊天屏的完整 UI 行为契约（消息/工具轮渲染与折叠、贴底跟随与跳底、会话虚拟滚动、消息分页加载、自动重连）见 `web-chat-screen` 能力；本能力只规定静态服务与端到端连通。

## Requirements

### Requirement: 无头核心进程独立启动并回显访问地址
系统 SHALL 提供一个不依赖 Flutter 渲染的无头 Dart 核心入口，复用现有业务 services 与 dart:ffi 加载的 C++ sidecar。核心 SHALL 仅绑定回环地址，监听端口由 OS 分配（port 0），并在启动输出中回显实际可访问的 `http://127.0.0.1:<port>` 地址。系统 MUST NOT 写死固定端口魔数。**配置文件不存在时 SHALL 以空配置启动并 serve 首启向导**（web-management-ui 引入，修改原 notFound 拒启动门），使 web 端能独立完成首启；配置 malformed 仍 SHALL 可归因失败。

#### Scenario: 启动无头核心
- **WHEN** 以无头入口启动核心进程
- **THEN** 进程不依赖 Flutter 引擎即可运行，加载 sidecar 成功，并在输出中回显一个 OS 实际分配的回环 URL

#### Scenario: 端口由 OS 分配
- **WHEN** 核心启动时请求监听端口
- **THEN** 使用 port 0 让 OS 分配可用端口，回显的端口与实际监听端口一致，而非任何写死的常量

#### Scenario: 空配置启动供向导
- **WHEN** 配置文件不存在时启动无头核心
- **THEN** 核心以空配置启动并 serve 首启向导（而非拒启动退出），web 可打开完成首启配置

#### Scenario: 坏配置仍可归因失败
- **WHEN** 配置文件存在但 malformed
- **THEN** 核心可归因失败（指明配置损坏），不静默以空配置覆盖

### Requirement: 核心业务层与 Flutter foundation 解耦且行为不变
核心 services **及其传递依赖的 models** SHALL 能在纯 Dart VM（`dart run`）下运行，不依赖 `package:flutter`。解耦 SHALL 仅替换 `debugPrint` 与 `@visibleForTesting` 的来源（日志 shim + `package:meta`），MUST NOT 改变任何业务逻辑。debugPrint shim SHALL 是与 foundation 同签名 `(String?, {int? wrapWidth})` 的**可重赋值全局函数变量**，以保住既有日志捕获测试。解耦后既有全量测试 MUST 原样全部通过。

#### Scenario: 纯 Dart 运行核心
- **WHEN** 在不含 Flutter 引擎的纯 Dart VM 中加载核心 services 与依赖 models
- **THEN** 加载与运行成功，不因缺少 package:flutter 而失败

#### Scenario: 解耦不改行为
- **WHEN** 完成 foundation 解耦后重跑既有全量测试
- **THEN** 既有测试原样全部通过，无断言被修改、无行为漂移

#### Scenario: 日志捕获钩子保留
- **WHEN** 既有测试重赋值 debugPrint 捕获日志做断言
- **THEN** shim 可被同样重赋值，正向与负向（泄漏检查）断言均按原样工作

### Requirement: WebSocket JSON-RPC 通道
核心 SHALL 在同一回环 HTTP 服务上提供 WebSocket 升级，通道 SHALL 使用 JSON-RPC 2.0：带 id 的请求/响应用于方法调用，无 id 的 notification 用于服务端事件推送。非法 JSON-RPC 输入 SHALL 返回可区分的错误响应而非崩溃。

#### Scenario: 建立通道并调用方法
- **WHEN** web 客户端连接 WebSocket 并发送一个带 id 的合法 JSON-RPC 请求
- **THEN** 核心返回对应 id 的 JSON-RPC 响应

#### Scenario: 非法输入不崩溃
- **WHEN** 通道收到非法 JSON 或缺失必需字段的 JSON-RPC 消息
- **THEN** 核心返回 JSON-RPC 错误响应，进程继续运行不崩溃

### Requirement: 无头组合根完整复刻启动逻辑
无头组合根 SHALL 复刻 Flutter 入口的三段启动逻辑：sqflite ffi 工厂初始化、工具目录播种与条件注册（基础工具+load_skill+按 search/browser 可用性动态注册）、发送门禁与 summaryStoreOpen 真实谓词。默认模板 SHALL 能成功创建实例并 send，MUST NOT 因 ToolCatalog 为空抛 UnknownToolsException 或因摘要存储谓词为假静默禁用摘要。工具播种逻辑 SHALL 抽取为共享函数供 Flutter 与无头两侧调用，避免复制分叉。

#### Scenario: 默认模板可创建并发送
- **WHEN** 无头核心以默认 general 模板创建会话并发送消息
- **THEN** 工具目录已播种、实例创建成功、send 端到端走通，不抛 UnknownToolsException

#### Scenario: 摘要存储不被静默禁用
- **WHEN** 数据库已打开时创建实例
- **THEN** summaryStoreOpen 谓词为真，摘要存储可用，而非默认 _neverOpen 的静默禁用

### Requirement: 发送消息并流式推送事件
核心 SHALL 暴露发送消息的 RPC 方法，复用 `Agent.send` 与 `AgentFactory.ensure`。发送后 SHALL 通过 `AgentCallbacks` 把流式文本、思考、工具调用、工具结果、助手/用户消息、流式状态、回合完成、快照、压缩状态、标题、计量等事件以 JSON-RPC notification 推送给客户端，payload 带 sessionId 与事件类型。事件**类型与语义** SHALL 复用现有模型，MUST NOT 新造事件类型；序列化 SHALL 分类处理——有现成 toJson 的直接用，Message/ContextSnapshot/CompactionStatus 由 RPC 层显式适配（快照适配 MUST 包含占用环所需字段，不得静默丢 breakdown）。技能失败明细 SHALL 随快照事件推送（每个失败技能一行：名+原因），MUST NOT 只剩计数。复用已存在实例时 SHALL 把回调指向当前 WS 订阅者。

#### Scenario: 发送并收到流式回复
- **WHEN** 客户端调用发送方法提交一条用户消息
- **THEN** 核心经 Agent.send 处理，并按序推送流式文本事件与最终助手消息事件，payload 均带对应 sessionId

#### Scenario: 工具轮事件可见
- **WHEN** 一轮回复触发工具调用
- **THEN** 核心推送工具调用事件与工具结果事件，客户端能据此渲染工具活动

#### Scenario: 快照事件含完整占用数据与技能提示
- **WHEN** 一轮装配产生快照且存在加载失败的技能
- **THEN** 快照事件 payload 含窗口/拆分数据（非仅 toRawJson 三键）与逐条技能失败明细

#### Scenario: 重连后事件发往当前订阅者
- **WHEN** 客户端重连并对已存在实例的会话再次 ensure
- **THEN** 后续事件发往当前 WS 订阅者，而非旧回调

#### Scenario: 取消在途请求
- **WHEN** 客户端调用取消方法
- **THEN** 核心取消该会话在途请求，并推送流式状态收尾事件

#### Scenario: 整轮失败可观察
- **WHEN** send 返回但整轮 failed（如超过工具轮次上限）
- **THEN** 核心推送可归因的失败事件（含原因），客户端能显示错误，MUST NOT 静默停止

### Requirement: 会话与消息查询支持分页
核心 SHALL 暴露会话列表与消息查询的 RPC 方法。消息查询 SHALL 支持游标/分页参数，按请求方给定的页返回，**在 message.query 读路径上** MUST NOT 一次性把整条会话历史全量载入内存。页大小 SHALL 由请求方必填，缺 pageSize SHALL 返回可区分错误（JSON-RPC -32602），核心 MUST NOT 发明默认上限魔数。分页方法 SHALL 以可选扩展/新接口提供，MUST NOT 改既有 MessageRepository 接口签名（保住 implements 夹具）。既有 Flutter 与 Agent.restore 使用的全量查询方法 SHALL 保留不变；**发送/创建路径经 restore 全量载入历史属现状，不在本能力范围**。

**additive 扩展（web-chat-screen 引入，保留前向兼容）**：消息查询 SHALL 支持**尾锚模式**（anchor=tail，缺省）——不传游标时返回**最新一页**（按 seq 降序取 pageSize 条再反转为升序）；SHALL 支持**反向游标 beforeSeq**（`seq < beforeSeq` 降序取页再反转）用于上翻加载更早页；返回 SHALL 含 `prevCursor`（本页首条 seq，指向更早页，无更早时为 null）。既有 afterSeq/nextCursor 前向语义与 anchor=head 行为 SHALL 保留不变（Flutter 不受影响）。

#### Scenario: 分页查询消息
- **WHEN** 客户端以游标与页大小调用消息查询
- **THEN** 核心只返回该页消息与游标，读路径不载入整条历史（SQL limit 或 repo 计数可证）

#### Scenario: 缺页大小返回错误
- **WHEN** 客户端调用消息查询但缺 pageSize
- **THEN** 核心返回 JSON-RPC -32602 错误，不套用任何隐藏默认页大小

#### Scenario: 尾锚取最新页
- **WHEN** 客户端不传游标（或 anchor=tail）调用消息查询
- **THEN** 返回最新一页（seq 最大的 pageSize 条，升序排列）与 prevCursor，而非最旧页

#### Scenario: 反向游标加载更早
- **WHEN** 客户端以 beforeSeq（上一页 prevCursor）调用消息查询
- **THEN** 返回 seq < beforeSeq 的更早一页（升序）与新 prevCursor，不与当前页重叠

#### Scenario: 前向兼容保留
- **WHEN** 客户端以 afterSeq（anchor=head）调用消息查询
- **THEN** 行为与扩展前一致（seq > afterSeq 升序取页 + nextCursor），Flutter 既有路径不受影响

#### Scenario: 会话列表
- **WHEN** 客户端调用会话列表方法
- **THEN** 核心返回顶层会话列表（不含一次性子运行记录），按最近更新倒序

### Requirement: 本机静态服务与 web 客户端
核心 SHALL serve web 客户端构建产物（React + TypeScript，渲染 Markdown），客户端经 WebSocket 完成"发一条消息 → 流式回复 → 工具卡片"的端到端流程。web 客户端的完整聊天屏 UI 行为契约（消息/工具轮渲染与折叠、贴底跟随、跳底按钮、会话虚拟滚动、消息分页加载、自动重连）由 `web-chat-screen` 能力规定；本能力只规定静态服务与端到端连通，不再限定为"最小验证页"。

#### Scenario: 打开 web 客户端完成一轮对话
- **WHEN** 浏览器打开回显 URL 并在 web 客户端发送一条消息
- **THEN** 页面经 WebSocket 收到流式回复并渲染 Markdown，若触发工具则显示工具卡片

#### Scenario: 静态服务 serve 构建产物
- **WHEN** 浏览器请求回显 URL 的根路径
- **THEN** 核心 serve web 客户端构建产物（index.html 与资源），客户端可加载运行

### Requirement: 与 Flutter 界面并行共存
无头核心 SHALL 与现有 Flutter 界面灰度共存，本能力 MUST NOT 删除或修改 Flutter UI 的行为。无头核心启动 SHALL 取单实例守卫（锁文件/命名互斥体），检测到已有核心运行时 MUST 显式失败退出并提示，MUST NOT 双开导致 sqlite 双写或 dispose_context 删除另一进程在用的 spill 目录。"同一时刻只跑一个核心"约定 SHALL 写入用户文档。

#### Scenario: 不启动无头核心即回退
- **WHEN** 用户不启动无头核心进程
- **THEN** 现有 Flutter 应用照常可用，无数据迁移、无行为变化

#### Scenario: 双开被守卫拒绝
- **WHEN** 已有核心运行时再启动一个无头核心
- **THEN** 第二个进程显式失败退出并提示"已有核心在运行"，不触碰 DB/spill 目录

#### Scenario: 文档写明单核心约定
- **WHEN** 用户查阅无头核心用户文档
- **THEN** 文档明确"同一时刻只跑一个核心"的约定、单实例守卫行为与启动/回退方式

### Requirement: 错误路径可观察
核心的启动失败、sidecar 加载失败、RPC 方法失败 SHALL 产生可归因的错误信息（输出或 JSON-RPC 错误响应），MUST NOT 静默失败。测试 SHALL 能在断言前观察到实际事件/调用与错误现场。

#### Scenario: sidecar 加载失败可归因
- **WHEN** 无头核心启动时 sidecar 加载失败
- **THEN** 输出可归因的错误信息指明失败原因，进程不假装就绪

#### Scenario: RPC 方法失败返回错误
- **WHEN** 客户端调用一个会失败的方法（如不存在的会话）
- **THEN** 核心返回带可归因信息的 JSON-RPC 错误响应，而非无响应或崩溃

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
