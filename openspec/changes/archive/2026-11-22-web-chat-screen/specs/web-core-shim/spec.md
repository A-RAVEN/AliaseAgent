## RENAMED Requirements

- FROM: `### Requirement: 本机静态服务与最小 web 验证页`
- TO: `### Requirement: 本机静态服务与 web 客户端`

## MODIFIED Requirements

### Requirement: 本机静态服务与 web 客户端
核心 SHALL serve web 客户端构建产物（React + TypeScript，渲染 Markdown），客户端经 WebSocket 完成"发一条消息 → 流式回复 → 工具卡片"的端到端流程。web 客户端的完整聊天屏 UI 行为契约（消息/工具轮渲染与折叠、贴底跟随、跳底按钮、会话虚拟滚动、消息分页加载、自动重连）由 `web-chat-screen` 能力规定；本能力只规定静态服务与端到端连通，不再限定为"最小验证页"。

#### Scenario: 打开 web 客户端完成一轮对话
- **WHEN** 浏览器打开回显 URL 并在 web 客户端发送一条消息
- **THEN** 页面经 WebSocket 收到流式回复并渲染 Markdown，若触发工具则显示工具卡片

#### Scenario: 静态服务 serve 构建产物
- **WHEN** 浏览器请求回显 URL 的根路径
- **THEN** 核心 serve web 客户端构建产物（index.html 与资源），客户端可加载运行

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