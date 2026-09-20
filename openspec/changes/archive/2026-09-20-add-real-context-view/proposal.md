## Why

自动上下文压缩已经做了，但用户没有任何直观方式看到压缩后**真正发给 AI 的上下文**。对话视图显示的是完整持久化历史，而模型实际接收的是压缩投影（`[摘要][近段原文][当前]`，最旧内容可能只留盘不发送）——两者不一致。没有一种方式能核对"这次请求到底发了什么"，也难以用同样的视图做其它调试。因此要加一个可切换的"真实上下文视图"，忠实显示每次主对话请求实际发送的 system + messages + tools，可随时对照、可折叠、可复制、可观察。

## What Changes

- 新增"真实上下文视图"视图模式，可与原版对话视图一键切换（对话区顶部加小工具栏）。
- 每轮主对话请求发送时，深拷贝捕获实际待发的上下文快照（`systemPrompt` + `apiMessages` + `toolsJson` + 请求参数），暴露为可读 getter `ChatScreenState.contextSnapshot`。
- `ContextView` 逐块渲染 `apiMessages`：text / thinking / tool_use(JSON 排版) / tool_result(tool_use_id+正文) / 摘要文字块(独立 SummaryItem)；额外可折叠 "System Prompt"、"Tools (N)"、"Copy 原始 JSON"。
- 忠实边界（设计决策）：**仅主对话请求**——不含同一轮 seam 选择器 / 摘要器发的折叠内部请求；**tool_result 显示现场发送版（本 send 实际转发正文）**——实时工具环轮为未 elide 的原始正文，完整历史发送 / 压缩投影回放则可能携带已 elide 正文（正文内含 `[tool_result body elided:` 标记），视图如实呈现该正文并按其是否含该标记如实标注，而**不无条件声称 un-elided**（见 design D4/D5 与 spec Context fidelity boundary）。
- 处理渲染陷阱：空 content 纯工具 assistant 不得整条隐藏；多个摘要块合并进同一条 user 消息时逐块渲染；大 thinking / 嵌套 tool input 用折叠 + 限高滚动。
- 测试：匹配层 widget + headless 观察（`contextSnapshot` + `FakeSidecar.lastMessagesJson`）+ live `dumpContext`。
- 无 BREAKING 改动。

## Capabilities

### New Capabilities
- `real-context-view`: 展示每次主对话请求实际发送给 AI 的上下文（system prompt + messages + tools），逐块还原，可与原版对话视图实时切换，可折叠、可复制原始 JSON、可被测试观察。

### Modified Capabilities
<!-- 本改动为纯增量观察性，不改 context-compaction / chat-ui 的任何既有行为要求，无 delta。 -->

## Impact

- `lib/main.dart`：`_callModel` 内捕获实际待发的上下文快照（`_sidecar.sendMessage` 之前约 main.dart:936、所有字段（`apiMessages`/`systemPrompt`/`toolsJson`/`thinking` 参数）均就绪处深拷贝 `apiMessages`）；`ChatScreenState` 新增 `_contextSnapshot` 状态与 `contextSnapshot` getter；对话区顶部新增视图切换工具栏。
- `lib/ui/`：新增 `ContextView` 及块级渲染组件（如 JSON 排版折叠块、`SummaryItem`）；复用 `MessageBubble`（text）、`ThinkingCard`（thinking）。
- 测试：复用 `FakeSidecar.lastMessagesJson`（headless 观察通道）、`live_observability` 的 tool-card 扫描/`ChatScreenState.finalAssistantReply` 读取模式；遵循 docs/TESTING.md 分层策略。
- 新增 capability spec `real-context-view`；不改 `context-compaction` / `chat-ui` 的行为。
