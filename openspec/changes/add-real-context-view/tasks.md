# Add Real Context View — Tasks

## 1. Context Snapshot Capture

- [ ] 1.1 定义 `ContextSnapshot` 模型（新建，如在 `lib/services/context_snapshot.dart`）：字段 `sessionId`、`systemPrompt`、`messages`（深拷贝 `List<Map<String,dynamic>>`）、`toolsJson`、`model`、`thinkingMode`、`thinkingEffort`、`capturedAt`。纯数据类，无副作用。
- [ ] 1.2 在 `_callModel`（lib/main.dart 约 934-943）把内联 `systemPrompt` 表达式（940 行）**抽取为局部变量**（如 `final systemPrompt = ...`），使其在捕获点可读——不改其发给网关的最终内容。
- [ ] 1.3 在 `await _sidecar.sendMessage(...)`（约 936 行）**之前、所有字段均在作用域处**，深拷贝 `apiMessages`（`jsonEncode`→`jsonDecode` 或等价深拷贝），连同此处已就绪的 `systemPrompt`（940 行局部）、`toolsJson`（830 行局部）、`agentType.model` / `thinkingMode` / `thinkingEffort`（927-934 行）组装成 `ContextSnapshot`，调用 `setState` 写入 `ChatScreenState._contextSnapshot`（每轮 send 一次，含工具环增长后的版本）。**注意** 913 行 `jsonEncode(apiMessages)` 时 `systemPrompt`/`thinkingMode`/`thinkingEffort` 尚未在作用域，故捕获点不能在 913，必须在 sendMessage 调用前。
- [ ] 1.4 暴露 `ChatScreenState.contextSnapshot` 只读 getter（返回 `_contextSnapshot`，未发送时 null）。`_loadMessages` / 会话切换语义：**保留最近一次快照并标注其 `sessionId`**（视图 header 显示 `snapshot for session=<id>`），不在切换时静默清空（避免用户误以为当前会话发了该请求）；若当前会话无快照则显示占位。

## 2. ContextView Rendering Components

- [ ] 2.1 新建 `lib/ui/context_view.dart`：`ContextView(snapshot)` 骨架——`ListView.builder`（复用 ChatArea 的 lazy-list 模式），每条消息 header 为 `[idx] role`（首个 user 从 0 编号），为 `snapshot.messages` 空时显示占位。
- [ ] 2.2 块类型分派：`text` → 复用 `MessageBubble(role, content)`；`thinking` → 复用 `ThinkingCard`（构造静态 `ChatThinkingItem`）。
- [ ] 2.3 新建 `JsonBlock`（如在 `lib/ui/context_view.dart` 内）：用 `const JsonEncoder.withIndent('  ').convert(value)` 美化（**注意** Dart 顶层 `jsonEncode` 无 `indent` 参数，传 `jsonEncode(x, indent:2)` 会编译报错），折叠 + 限高滚动（`maxHeight` + 可展开/收起），用于 `tool_use.input`（常含绝对路径=重执行键，**不截断**）与需要美化的 `tool_result.content`。
- [ ] 2.4 `SummaryItem`：识别 `text` 块内容以 `## 更早上下文` 开头的摘要块，渲染为独立卡片（marker/层级 + 折叠），**不并入同一段落**（`_buildCompactionProjection` 会把多个 summaryBlocks `insertAll` 进首条 user 的 content）。
- [ ] 2.5 `tool_result` 块：显示 `tool_use_id` + `content`（JSON 内容走 `JsonBlock` 美化，纯文本直接出）；正文为**现场发送版（未 elide 的完整正文）**，故**不显示截断标记**（截断仅出现在回放 elision，本视图不展示回放）；大正文折叠 + 限高，并标注"现场发送版 (un-elided)"。
- [ ] 2.6 渲染陷阱：内容为空的 assistant（纯工具轮）**不整条隐藏**——渲染其 `tool_use`/`thinking` 块并把空 `text` 块显示为 `(no text)` 占位；大 thinking / 嵌套 JSON 高度钳制 + 滚动。为 `ContextView` 加可折叠 "System Prompt" 与 "Tools (N)"（列 name，细节可展开）两个 section。
- [ ] 2.7 "Copy 原始 JSON" 卸载于 `ContextView`：用 `SelectableText` 承载 `jsonEncode({'system':…,'messages':…,'tools':…})`，选中可复制。

## 3. View Mode Toggle

- [ ] 3.1 `ChatScreenState` 新增 `_viewMode`（enum `conversation` / `context`），默认 `conversation`。
- [ ] 3.2 `ChatScreen.build`（约 2506，现裸 `Row`）把 `Expanded` 内容包一层 `Column`：顶部加小工具栏（`SegmentedButton`：`对话视图 | 真实上下文`），下部按 `_viewMode` 渲染 `ChatArea(items: _chatItems, …)` 或 `ContextView(snapshot: _contextSnapshot)`；切换时 `setState`。

## 4. Tests (Matching Layer + Observability)

- [ ] 4.1 widget/mock（tier2，`test/widget/`）：注入 `FakeSidecar` + `FakeSummaryProvider`，驱动**两轮**覆盖所有块类型：(i) 一轮含工具调用 → 断言 `ContextView` 渲染出 tool_use JSON 块 + thinking 块；(ii) 一轮**超出 `maxContextTokens` 触发压缩**（会话超过 budget + `FakeSummaryProvider` 注出更小摘要）→ 断言 `ContextView` 渲染出**摘要块**（`## 更早上下文` 开头的 `SummaryItem`）；每轮断言 (a) `ChatScreenState.contextSnapshot` 可读且 `messages` 与 `FakeSidecar.lastMessagesJson` 一致；(b) 切换 toggle 生效且显示 `ContextView`；**断言前** `debugPrint '[OBS] contextSnapshot: …'`（观察性优先，失败可归因）。
- [ ] 4.2 headless 观察通道：用 `FakeSidecar.lastMessagesJson` 断言实际发出的投影与快照捕获内容一致（覆盖压缩投影路径与未压缩路径）。
- [ ] 4.3 live（`integration_test/`）：`live_observability` 加 `dumpContext`（读取 `ChatScreenState.contextSnapshot` 并在断言前打印 system+messages+tools 概览），让真实窗口/模型测试可归因地看到上下文视图内容。

## 5. Honesty Review

- [ ] 5.1 诚实性审查：对全套 artifacts（proposal/design/spec/tasks）与上述实现跑 **Workflow 对抗验证**（N≥3 REFUTE 怀疑者 + 多数决 kill，多维度交叉，离线参照本地文档），核对：捕获是否忠实于实际发送、视图边界声明是否如实（仅主对话请求、tool_result 现场发送版）、渲染陷阱是否覆盖（空 content 不隐藏/多摘要逐块/大 JSON 限高）、是否越界（未改 context-compaction/chat-ui 行为、未改 C++ sidecar）、测试观察性是否满足。发现问题按执行顺序插入修复任务（不倒退已勾选任务），全部到 `[x]` 后输出诚实性审查报告（已审查轮数、每轮问题数、最终任务状态）。
