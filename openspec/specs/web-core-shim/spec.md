# web-core-shim Specification

## Purpose

规定 AliasAgent 的无头 Dart 核心（复用现有业务 services 与 C++ sidecar）与 web 客户端之间的端到端契约：同一回环 HTTP 服务上提供 WebSocket/JSON-RPC 通道与本机静态服务，并以完整 web 聊天屏完成「发消息 → 流式回复 → 工具卡片」的端到端流程。聊天屏的完整 UI 行为契约（消息/工具轮渲染与折叠、贴底跟随与跳底、会话虚拟滚动、消息分页加载、自动重连）见 `web-chat-screen` 能力；本能力只规定静态服务与端到端连通。

## Requirements

### Requirement: 无头核心进程独立启动并回显访问地址

系统 SHALL 提供一个不依赖 Flutter 渲染的无头 Dart 核心入口，复用现有业务 services 与 dart:ffi 加载的 C++ sidecar。核心 SHALL 仅绑定回环地址。

监听端口 SHALL 按以下优先级决定：显式 `--port <n>` > 配置项 `core.port` > 具名默认常量（出厂 16705，登记在用户文档的配置键表）。`--port 0` SHALL 保留「交回 OS 分配」的调试与测试形态。端口值 MUST NOT 以裸数字出现在代码里，SHALL 来自配置项默认值或具名常量。合法范围 SHALL 是 1–65535（TCP 端口域）。`<1024` 的低端口 MUST NOT 被描述成「需要管理员权限」——Windows 上没有 Unix 式特权端口（对抗审查实测非提权绑定 80 与 1023 均成功），它只是容易与系统服务相撞，文档 SHALL 写「不推荐」而不是「需要提权」。配置项 `core.port` 缺席、不是整数或越界时 SHALL 回落默认常量并留一行日志（回落可见，不静默），MUST NOT 因此拒绝启动；`--port` 是显式输入，非法时 SHALL 报错退出（不猜用户意图）。

启动输出 SHALL 回显实际可访问的 `http://127.0.0.1:<port>` 地址。端口被占用导致绑定失败时，核心 SHALL 抛可归因的启动失败（消息含端口号与「改 `core.port` 或用 `--port` 指定另一个端口」），MUST NOT 静默改用其它端口。**配置文件不存在时 SHALL 以空配置启动并 serve 首启向导**（web-management-ui 引入，修改原 notFound 拒启动门），使 web 端能独立完成首启；配置 malformed 仍 SHALL 可归因失败。

#### Scenario: 启动无头核心

- **WHEN** 以无头入口启动核心进程
- **THEN** 进程不依赖 Flutter 引擎即可运行，加载 sidecar 成功，并在输出中回显一个实际可访问的回环 URL（端口与进程实际监听端口一致）

#### Scenario: 固定端口取自配置

- **WHEN** 配置文件里写 `core.port` = 9000，且启动时没有传 `--port`
- **THEN** 核心监听 9000，回显的 URL 端口是 9000（不再是 OS 随机分配的端口）

#### Scenario: 显式参数覆盖配置

- **WHEN** 配置里写 `core.port` = 9000，启动时传 `--port 9100`
- **THEN** 核心监听 9100，配置里的值不生效且配置文件不被改写

#### Scenario: 显式 0 交回 OS 分配

- **WHEN** 启动时传 `--port 0`
- **THEN** 核心回到旧形态：由 OS 分配端口并回显实际端口（测试与调试依赖这条形态）

#### Scenario: 配置项非法时回落默认并留日志

- **WHEN** 配置里 `core.port` 是字符串、0、负数或大于 65535
- **THEN** 核心仍启动并绑定默认端口的同值端口，输出一行说明「取值非法已回落默认」；MUST NOT 静默无声

#### Scenario: 端口被占用可归因

- **WHEN** 目标端口已被另一个进程占用
- **THEN** 核心以可归因的启动失败退出，消息里点名端口并给出「改 `core.port` 或 `--port`」的出路；MUST NOT 换一个端口偷偷启动

#### Scenario: 低端口不被说成需要提权

- **WHEN** 用户文档与错误提示提到 `<1024` 的端口
- **THEN** 措辞是「容易与系统服务相撞、不推荐」，MUST NOT 出现「需要管理员权限」这类与 Windows 事实不符的说法

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

### Requirement: 核心优雅停机

核心 SHALL 暴露 JSON-RPC 方法 `core.shutdown`（无参数）。**时序 SHALL 是「先回包、再停机」**：handler 只返回 `{"ok": true}`（并登记「响应已刷出」回调），WebSocket 侧先把响应写出、再关闭该连接（Dart 的 `WebSocket.close()` 会先发完排队消息），然后才触发停机。MUST NOT 先停机再回包——那样连接会被提前关掉，响应留在队列里，调用方看到的是「调了但没回」。

核心 SHALL 提供**入口与测试共用的**停机等待点 `serveUntilShutdown()`：等待「`core.shutdown` 的响应已刷出」或 SIGINT，随后执行停机并返回停机报告。测试 MUST NOT 自拼一套停机序列（否则验的是测试自己）。

停机顺序 SHALL 是：对所有运行中的 Agent 调 `cancel()` → **等待在途整轮收尾**（`Agent.waitForRounds()` 等价的等待点；`cancel()` 只是同步置取消标志、不等待整轮结束，少了这一步「收尾事件在通道关闭前到达」在实现上不成立）→ 断开 WebSocket 客户端 → 关闭 HTTP 服务器 → 销毁 Agent → 关闭数据库 → 释放单实例锁，随后进程退出。**停机异常 SHALL 可见**：`stop()` 期间 `disposeAll` / 数据库关闭的失败 MUST NOT 被吞成一行日志——每一项 SHALL 进停机报告的告警清单并写入核心日志；有告警时进程退出码 SHALL 非 0（`kExitCodeShutdownWithWarnings`，与既有的 1=启动失败、2=参数错误区分）。

该方法名 SHALL 出现在 `kCoreRpcMethodNames` 里、与 `_registerMethods` 的实现一致（漏注册即抛错），并 SHALL 出现在用户文档里：`web-core-shim.md` 的 RPC 表补齐它单独一行（该守卫按 RPC 表首列逐行核对）；管理屏 `web-management.md` 的管理 RPC 表也补一行（**该守卫只是整篇子串检查** `text.contains`，不是按表行——本 change 如实写明这条强度差异，不把两者说成一样强）。

调用之后 MUST NOT 遗留服务器监听或锁占用：同一端口与同一锁文件上的下一次核心启动 SHALL 成功。`core.shutdown` 落在「本机回环、无鉴权」的服务面上——任何本机进程（包括本机网页）都能关掉核心——这两条边界 SHALL 写进用户文档的已知限制。

#### Scenario: 调用后先回包再停机且锁释放

- **WHEN** 客户端经 WebSocket 调用 `core.shutdown`
- **THEN** 客户端收到 `{"ok": true}` 响应（不是连接被直接掐断），随后核心停止服务、释放单实例锁并以 0 退出；用同一锁路径再启动一个核心 SHALL 成功

#### Scenario: 方法与清单、两处文档一致

- **WHEN** 核心启动并注册方法
- **THEN** `core.shutdown` 可被调用，`kCoreRpcMethodNames` 与实现一致，`Docs/user-guide/web-core-shim.md` 的 RPC 表与 `Docs/user-guide/web-management.md` 的管理 RPC 表里都有它单独一行

#### Scenario: 停机有告警时退出码非 0

- **WHEN** 停机过程中销毁 Agent 或关闭数据库抛错
- **THEN** 停机报告带上告警、日志里逐条写明，进程以非 0 码退出（不是假装成功）；壳侧把它记成「停机有告警」而不是崩溃

#### Scenario: 停机不破坏数据

- **WHEN** 在有会话数据的情况下调用 `core.shutdown` 后重新启动核心
- **THEN** 会话与消息仍可读（正常关库路径，不是被强杀后的残留状态）

#### Scenario: 在途发送被取消而不是被强杀

- **WHEN** 调用 `core.shutdown` 时某会话正在流式回复
- **THEN** 该 Agent 先被取消（在途发送收到取消）、在途整轮被等待收尾，通道关闭前客户端收到收尾事件，随后才关服务器与数据库；MUST NOT 只置取消标志就关通道
