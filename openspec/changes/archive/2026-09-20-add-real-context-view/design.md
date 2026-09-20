## Context

自动上下文压缩已实现：`CompactionEngine.buildTree` 决定哪些段折叠成摘要、哪些 verbatim；`ContextEstimator` 做确定性 token 估算；`_resolveSummaries` 调模型产 L1/L2 摘要；`_buildCompactionProjection` 把结果拼成 `[摘要][近段原文][当前]` 投影。

对话视图 `_chatItems`（`_buildChatItems` 从持久化历史重建，main.dart:605）显示**完整历史**，从不反映压缩投影——用户看到的和模型收到的往往不一致，且无任何手段核对"这次请求到底发了什么"。

关键事实（已本地核对）：
- `apiMessages` 是 `_callModel` 的局部变量（main.dart:839，五个分支赋值：850/885/891/894/899），在 `while(true)` 工具环里被**就地 `.add` 增长**（1204 追加 assistant(tool_use)、1293 追加 user(tool_result)），在 913 行 `jsonEncode` 后经 941 送 `_sidecar.sendMessage`。
- C++ `model_gateway.cpp:549-625` 忠实序列化 `system`/`messages`/`tools`（仅另加 model/stream/thinking/max_tokens/metadata 请求参数），**不发明或改写对话内容**。
- 因此"真实上下文"的忠实边界 = Dart 层交给 FFI 的 `systemPrompt` + `apiMessages` + `toolsJson`（main.dart:940/913/942）。

约束：docs/TESTING.md §5 rule 8 要求新功能必须带匹配层测试 + spec 更新 + 可自测 verify 任务；观察性规则要求测试输出可见。

## Goals / Non-Goals

**Goals:**
- 一个可与原版对话视图一键切换的"真实上下文视图"，忠实显示每次**主对话请求**实际发送的 system + messages + tools。
- 逐块还原（text / thinking / tool_use / tool_result / 摘要文字块），可折叠、可复制原始 JSON。
- 暴露为可观察状态（`ChatScreenState.contextSnapshot` getter），供 UI 与测试读取。
- 复用现有 `MessageBubble` / `ThinkingCard`，对既有渲染最小侵入。

**Non-Goals:**
- 不改 `context-compaction` / `chat-ui` 的任何既有行为要求（纯增量观察性）。
- 不展示 seam 选择器 / 摘要器同轮发的折叠内部请求（那些是 `sendMessage` 的另一批调用，形态为裸字符串 content，语义是内部机械）。
- 不做请求重放 / 逐轮历史版本对比 / 编辑上下文——只显示最近一次发送快照。
- 不改 C++ sidecar（观察边界定在 Dart 侧）。

## Decisions

### D1 捕获方式：每次发送时深拷贝 `apiMessages`
在 `await _sidecar.sendMessage(...)`（约 936 行）**之前、所有字段均在作用域处**深拷贝 `apiMessages` 为快照（每轮 send 一次），存 `ChatScreenState`。理由：`apiMessages` 在工具环被 `.add` 增长，单点一次捕获只拿到第 1 轮基座、丢工具轮；发送点是每次请求的必经点，且此时 `systemPrompt`（940 行）/`thinkingMode`/`thinkingEffort`（927-934 行）与 `toolsJson`（830 行）、`model` 均已就绪（而 913 行 `jsonEncode` 时这些字段尚未定义）；深拷贝（`jsonEncode`→`jsonDecode`）防止后续 `.add` 改掉已捕获引用。

- **备选（弃）**：在 899-906 之间"只捕获一次" → 丢失工具轮内容。
- **备选（弃）**：从 `_chatItems` / DB 重建上下文 → `_buildChatItems` 根本不产出 tool_result 块（tool_result 不是 ChatItem），且活轮/回放 elision 不对称，重建≠实际发送。

### D2 快照模型 + 暴露
`ContextSnapshot { sessionId, systemPrompt, messages, toolsJson, model, thinkingMode, thinkingEffort, capturedAt }`。`messages` 为深拷贝的 `List<Map<String,dynamic>>`；`systemPrompt`/`toolsJson` 由 `_callModel` 现有的 `toolsJson` 局部（main.dart:830）与 940 行内联 `systemPrompt` 表达式（需提前抽取为局部变量）提供。暴露 `ChatScreenState.contextSnapshot`（null = 自启动以来尚未捕获任何快照；会话切换时保留最近一次快照并以 `sessionId` 标注，见 D6/风险）。

- **备选（弃）**：只存 `messages` → 缺 system/tools，非"完整上下文"。
- **备选（弃）**：只存一条 raw JSON string → 无法逐块渲染（需结构化遍历）。

### D3 视图边界：仅主对话请求
视图只展示正文那条 `_sidecar.sendMessage` 的上下文。理由：seam 选择器 / 摘要器的内部请求是压缩机械、形态不同（裸字符串 content），展示会显著提高熵且并非"对话上下文"。
- **备选（弃）**：一并展示（"完整"但易误导，见 D4）。

### D4 诚实边界声明
视图"是主对话请求的上下文"，**不是**"本轮发给 AI 的一切"；`tool_result` 正文显示**现场发送版**（本 send 实际转发给网关的正文）。当本 send 为实时工具环轮时是未 elide 的原始正文；而当本 send 本身就是回放（完整历史发送或压缩投影，经 `_buildApiMessages`→`_elideOversizedToolResult`）时，超大正文可能已被 elide，且该 elide 标记就存在于正文中。视图如实呈现该正文（verbatim），并据其是否含 `[tool_result body elided:` 标记如实地标注 elided/un-elided——**绝不无条件声称 un-elided**（见 D5、风险与审查 F-impl-1）。理由：忠实于"这次调用到底发了什么"。此声明写入 spec，避免"完整"字样被从业者误读。

### D5 渲染：`ContextView` 逐块遍历 `apiMessages`
- 消息 header：`[idx] role`（首个 user 从 0 编号）。
- 块类型分派：
  - `text` → 复用 `MessageBubble(role, content)`；`content` 为空 → `(no text)` 占位（**不整条隐藏**——空 content 纯工具 assistant 是其 tool_use 的首属主，main.dart:2042-2045）。
  - `thinking` → 复用 `ThinkingCard`（构造静态 `ChatThinkingItem`：折叠 + maxHeight 400 滚动）。
  - `tool_use` → **新增 `JsonBlock`**：`const JsonEncoder.withIndent('  ').convert(input)` 美化 + 折叠 + 限高滚动（input 常含绝对路径=重执行键，不可截断）。
  - `tool_result` → 显示 `tool_use_id` + `content`（JSON 内容走 `JsonBlock` 美化，纯文本直出）；正文为**现场发送版（本 send 实际转发正文，verbatim 呈现，含 elide 标记则如实呈现）**；大正文折叠 + 限高；标注"现场发送版 ({elided|un-elided})"，据正文是否含 `[tool_result body elided:` 标记决定（**绝不无条件声称 un-elided**，见 D4、审查 F-impl-1）。
  - 摘要文字块（`content` 以 `## 更早上下文` 开头）→ `SummaryItem`（marker/层级 + 折叠）。
- 额外可折叠 section："System Prompt"、"Tools (N)"（列 name，细节可展开）、"Copy 原始 JSON"（`SelectableText` 承载 `jsonEncode({system,messages,tools})`）。

### D6 视图切换
对话区顶部加小工具栏（`SegmentedButton`：`对话视图 | 真实上下文`），状态存 `ChatScreenState._viewMode`（默认对话视图）。`ChatScreen.build`（main.dart:2506，现为裸 `Row`）把 `Expanded` 内容包一层 `Column`，上部放工具栏下部分显 `ChatArea` 或 `ContextView`。
- **备选（弃）**：引入 `Scaffold`+`AppBar` → 结构性大改、无现成 AppBar（main.dart 全局仅 config-error Scaffold 有 AppBar）。

### D7 测试（匹配层 + 观察性）
- tier2 widget（`test/widget/`）：注入 `FakeSidecar` + `FakeSummaryProvider`，驱动一轮含工具调用的对话；断言 toggle 可切、`ContextView` 渲染出 tool_use JSON / thinking / 摘要；观察性：断言前 `debugPrint [OBS] contextSnapshot`；读 `ChatScreenState.contextSnapshot`。
- headless 观察通道：`FakeSidecar.lastMessagesJson`（fake_sidecar.dart:84-138）断言实际发出的投影与快照一致。
- live（`integration_test/`）：`live_observability` 加 `dumpContext`，在断言前打印快照（观察性优先）。

### D8 渲染陷阱处理
空 content 消息不整条隐藏；多个摘要块合并进同一条 user 消息时逐块渲染（`_buildCompactionProjection` 会把 summaryBlocks `insertAll` 进首条 user 的 content）；大 thinking / 嵌套 tool input 用折叠 + 限高；长上下文用 `ListView.builder` + 每条可折叠（复用 ChatArea 的 lazy-list 模式）。

## Risks / Trade-offs

- **[每次发送都深拷贝 `apiMessages`，多轮工具时次数多]** → 开销为消息量级，仅在发送点做、不常驻；可接受。
- **[会话切换后 `_loadMessages` 不重跑 `_callModel`，无新快照]** → 保留最近一次快照并标注 `sessionId`（避免误导为当前会话），视图 header 显示 `snapshot for session=<id>`。
- **[现场发送版 vs 回放 elide 版 tool_result 差异]** → spec 明确声明显示"现场发送版（本 send 实际转发正文）"，并注明 `kToolResultElisionThreshold=8000`；视图据正文是否含 `[tool_result body elided:` 标记如实标注 elided/un-elided，不无条件声称 un-elided（回放/压缩投影路径可能携带已 elide 正文，见 D4）。
- **["完整"字样可能被误读]** → spec 用限定语"主对话请求的上下文"。
- **[大 JSON/thinking 占满视图]** → 折叠 + 限高 + 选择性 Copy，不阻塞列表。
- **[测试观察性]** → 所有断言前 `debugPrint` 快照 / 响应，遵循 observability 原则；失败可归因。

## Migration Plan

纯增量。无 DB / 接口 / 依赖变更。默认仍是"对话视图"，用户手动切到"真实上下文视图"；无回滚风险（additive）。不需要特性开关。

## Open Questions

- **快照在会话切换时**：**决策 = 保留 + 标注 `sessionId`**。切换会话不静默清空；若目标会话未发送但保留了旧快照，视图显示 "snapshot for session=\<id\>"（非占位），避免误导为当前会话所发（见 D2 与风险）。
- **是否给 `ContextView` 过滤器**（"只看摘要区"/"只看 system"）：可选，初始不做，留待后续。对实现无阻塞。
