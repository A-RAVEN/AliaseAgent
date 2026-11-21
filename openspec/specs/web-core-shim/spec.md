# web-core-shim Specification

## Purpose

规定 AliasAgent 的无头 Dart 核心（复用现有业务 services 与 C++ sidecar）与最小 web 客户端之间的端到端契约：同一回环 HTTP 服务上提供 WebSocket/JSON-RPC 通道与本机静态服务，并用一个最小 web 聊天验证页完成「发消息 → 流式回复 → 工具卡片」的端到端流程。

## Requirements

### Requirement: 无头核心进程独立启动并回显访问地址
系统 SHALL 提供一个不依赖 Flutter 渲染的无头 Dart 核心入口，复用现有业务 services 与 dart:ffi 加载的 C++ sidecar。核心 SHALL 仅绑定回环地址，监听端口由 OS 分配（port 0），并在启动输出中回显实际可访问的 `http://127.0.0.1:<port>` 地址。系统 MUST NOT 写死固定端口魔数。

#### Scenario: 启动无头核心
- **WHEN** 以无头入口启动核心进程
- **THEN** 进程不依赖 Flutter 引擎即可运行，加载 sidecar 成功，并在输出中回显一个 OS 实际分配的回环 URL

#### Scenario: 端口由 OS 分配
- **WHEN** 核心启动时请求监听端口
- **THEN** 使用 port 0 让 OS 分配可用端口，回显的端口与实际监听端口一致，而非任何写死的常量

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
核心 SHALL 暴露会话列表与消息查询的 RPC 方法。消息查询 SHALL 支持游标/分页参数，按请求方给定的页返回，**在 message.query 读路径上** MUST NOT 一次性把整条会话历史全量载入内存。页大小 SHALL 由请求方必填，缺 pageSize SHALL 返回可区分错误（JSON-RPC -32602），核心 MUST NOT 发明默认上限魔数。分页方法 SHALL 以可选扩展/新接口提供，MUST NOT 改既有 MessageRepository 接口签名（保住 implements 夹具）。既有 Flutter 与 Agent.restore 使用的全量查询方法 SHALL 保留不变；**发送/创建路径经 restore 全量载入历史属现状，不在本能力范围**（"核心进程内存只留活跃投影"是后续规模能力的目标）。

#### Scenario: 分页查询消息
- **WHEN** 客户端以游标与页大小调用消息查询
- **THEN** 核心只返回该页消息与下一页游标，读路径不载入整条历史（SQL limit 或 repo 计数可证）

#### Scenario: 缺页大小返回错误
- **WHEN** 客户端调用消息查询但缺 pageSize
- **THEN** 核心返回 JSON-RPC -32602 错误，不套用任何隐藏默认页大小

#### Scenario: 会话列表
- **WHEN** 客户端调用会话列表方法
- **THEN** 核心返回顶层会话列表（不含一次性子运行记录），按最近更新倒序

### Requirement: 本机静态服务与最小 web 验证页
核心 SHALL serve web 客户端构建产物，提供一个最小聊天验证页，能完成"发一条消息 → 流式回复 → 工具卡片"的端到端流程。验证页 SHALL 用 React + TypeScript 渲染 Markdown。本能力 SHALL NOT 要求完整聊天屏、卡片折叠、自动贴底或跳底按钮（那些属后续能力）。

#### Scenario: 打开验证页完成一轮对话
- **WHEN** 浏览器打开回显 URL 并在验证页发送一条消息
- **THEN** 页面经 WebSocket 收到流式回复并渲染 Markdown，若触发工具则显示工具卡片

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
