# Tasks: Chat Agent Window

<!--
  ┌──────────────────────────────────────────────────────────────┐
  │  阶段依赖图                                                   │
  │                                                              │
  │  Phase 1 ──┬──▶ Phase 2 (config)                             │
  │            ├──▶ Phase 3 (persistence)                        │
  │            └──▶ Phase 4 (FFI bridge)                         │
  │                      │                                       │
  │                      ├──▶ Phase 5 (model gateway)  并行       │
  │                      ├──▶ Phase 6 (basic tools)   并行       │
  │                      └──▶ Phase 7 (chat UI)      并行       │
  │                               │                              │
  │                               ▼                              │
  │                          Phase 8 (integration)              │
  └──────────────────────────────────────────────────────────────┘
-->

## 1. Project Scaffolding

- [x] 1.1 Create Flutter desktop project with Win/Mac/Linux platform targets
- [x] 1.2 Add Flutter dependencies: `sqflite`, `path_provider`, `flutter_markdown`, `ffi`, `uuid`
- [x] 1.3 Create C++ Sidecar project with CMake build (shared library target)
- [x] 1.4 Set up C++ dependencies: libcurl (HTTP/SSE), nlohmann/json (JSON parsing)
- [x] 1.5 Integrate C++ build into Flutter build: CMake invocation in Flutter build hook, output dynamic library to correct platform directory

> [!CAUTION]
> ⛔ **STOP HERE** — After completing Phase 1 tasks, run the Checkpoint 1 verification below.
> Do NOT proceed to Phase 2 until the user explicitly says: "execute phase 2" or "start phase 2".

### 🔎 Checkpoint 1: FFI Ping

> 验收目标：Flutter 加载 C++ 动态库成功，基础 FFI 通信通路打通。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | C++ 库编译 | `cmake --build` 成功产出 `.so`/`.dylib`/`.dll` |
| B | Flutter 加载库 | 应用启动无 `dart:ffi` 加载错误 |
| C | Ping 往返 | Dart 调用 C `ping()` 返回预期值（如 `"pong"` 或版本号） |
| D | 三平台 | 在当前开发平台至少通过 A-C |

---

## 2. Agent Configuration

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 1 must be fully verified before starting Phase 2.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 2" or "start phase 2".

- [x] 2.1 Define Dart data models: `ProviderConfig`, `AgentTypeConfig`, `AppConfig`
- [x] 2.2 Implement config file reader: read and parse `~/.aliasagent/config.json`, handle missing/malformed cases
- [x] 2.3 Implement first-launch setup dialog: prompt for Anthropic API key, write initial config file
- [x] 2.4 Implement `AgentTypeRegistry`: register from config, lookup by name, list names
- [x] 2.5 Implement `ProviderResolver`: resolve provider by name, return api_key and base_url

### 🔎 Checkpoint 2: Config Round-trip

> 验收目标：配置系统可独立运行，不依赖其他模块。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 无配置文件启动 | 弹出 setup 对话框，输入 key 后写入 `config.json` |
| B | 有配置文件启动 | 跳过对话框，正确解析 providers 和 agent_types |
| C | 格式错误 | 显示明确错误信息，指出文件和问题 |
| D | Registry 查询 | `lookup("general")` 返回正确配置，`lookup("nonexistent")` 返回 null |
| E | Provider 解析 | 通过 provider name 能取到 api_key 和 base_url |

---

## 3. Session Persistence

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 2 must be fully verified before starting Phase 3.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 3" or "start phase 3".

- [x] 3.1 Define SQLite schema: `sessions` and `messages` tables with indexes
- [x] 3.2 Implement database initialization: auto-create DB file and tables on first launch
- [x] 3.3 Implement `SessionRepository`: CRUD operations (create, get, list ordered by updated_at desc, delete with cascade)
- [x] 3.4 Implement `MessageRepository`: insert user/assistant messages, query by session_id ordered by created_at

### 🔎 Checkpoint 3: Data Layer

> 验收目标：数据层独立可测，CRUD 完整。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 首次启动 | 数据库文件和两张表自动创建 |
| B | 再次启动 | 已存在的数据库不被覆盖，schema 不变；schema version 不匹配时删库重建 |
| C | 创建会话 | `sessions` 表插入新行，返回有效 UUID |
| D | 插入消息 | `messages` 表插入行，关联正确 session_id |
| E | 查询消息 | 按 session_id 查询，返回 created_at 升序 |
| F | 会话列表 | 按 updated_at 降序排列 |
| G | 删除会话 | session 和关联 messages 级联删除 |

---

## 4. FFI Bridge (Dart side)

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 3 must be fully verified before starting Phase 4.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 4" or "start phase 4".

- [x] 4.1 Define C function signatures in Dart using `dart:ffi`: `send_message`, `set_workspace`
- [x] 4.2 Define Dart callback types: `OnChunkCallback`, `OnToolCallCallback`, `OnDoneCallback`
- [x] 4.3 Implement `SidecarBridge` class: load library, bind functions, expose `sendMessage()` method
- [x] 4.4 Implement callback marshaling: convert Dart closures to C function pointers, handle thread safety

### 🔎 Checkpoint 4: FFI Contract

> 验收目标：Dart ↔ C 函数签名对齐，回调线程模型正确。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 函数签名 | Dart 侧 `send_message` 签名与 C 侧头文件一致（编译期检查） |
| B | 回调传递 | Dart 闭包成功转换为 C 函数指针，无 crash |
| C | 回调线程 | C 侧回调能从非 UI 线程安全到达 Dart（用 mock C 函数验证） |
| D | set_workspace | Dart 调 `set_workspace("/tmp/test")`，C 侧打印确认收到 |

---

## 5. Model Gateway (C++ side)

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 4 must be fully verified before starting Phase 5.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 5" or "start phase 5".

- [x] 5.1 Implement Anthropic API request builder: construct HTTP POST with headers (x-api-key, anthropic-version, content-type) and JSON body (model, messages, system, tools, stream: true)
- [x] 5.2 Implement SSE stream parser: read HTTP response body line by line, parse `data:` lines, decode JSON events
- [x] 5.3 Implement event dispatch: `content_block_delta` → on_chunk, `content_block_start` (tool_use) → on_tool_call, `message_stop` → on_done, `error` → on_done with error
- [x] 5.4 Implement `send_message` C entry point: accept parameters from Dart, drive HTTP request and SSE parsing, invoke callbacks
- [x] 5.5 Implement HTTP timeout (120s default) and connection error handling
- [x] 5.6 Add C++ logging to file (`~/.aliasagent/logs/`) for debugging

### 🔎 Checkpoint 5: Real API Call

> 验收目标：从 Dart 调用 sendMessage 到真实 Anthropic API，看到流式文本回到 Dart UI。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 简单对话 | 发送 "Hello"，收到流式文本回复，on_chunk 被多次回调 |
| B | 流式不丢字 | on_chunk 累计文本与最终 on_done 后的完整内容一致（允许少量拼接差异） |
| C | API 错误 | 使用无效 API key，on_done 收到非零 code 和错误信息 |
| D | 超时 | Mock 一个慢速 endpoint，验证 120s 超时触发 |
| E | 日志 | C++ 日志文件记录请求 URL、响应状态码、SSE 事件类型、未识别事件 warning、JSON 解析失败 error + 原始片段 |

---

## 6. Basic Tools (C++ side)

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 5 must be fully verified before starting Phase 6.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 6" or "start phase 6".

- [x] 6.1 Implement workspace path management: `set_workspace` C entry point, store and validate path
- [x] 6.2 Implement `read_file`: read file content, error on missing/binary/out-of-workspace
- [x] 6.3 Implement `list_dir`: enumerate directory entries with type indicator, error on missing/not-dir/out-of-workspace
- [x] 6.4 Implement path sandboxing: canonical path resolution, workspace boundary check for both tools

### 🔎 Checkpoint 6: Tool Execution

> 验收目标：两个基础工具可被调用并返回正确结果，路径沙箱生效。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | read_file 正常 | 传入 workspace 内文本文件路径，返回内容字符串 |
| B | read_file 不存在 | 返回 "File not found" 错误 |
| C | read_file 越界 | 传入 `../../../etc/passwd` 风格路径，返回 "Access denied" |
| D | list_dir 正常 | 传入 workspace 内目录，返回文件/目录名和类型 |
| E | list_dir 越界 | 传入 workspace 外路径，返回 "Access denied" |
| F | set_workspace | 切换 workspace 后，工具范围随之改变 |

---

## 7. Chat UI (Flutter)

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 5 and/or Phase 6 must be fully verified before starting Phase 7.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 7" or "start phase 7".

- [x] 7.1 Build app shell: window title, sidebar layout (session list left, chat area right)
- [x] 7.2 Build session list sidebar: load sessions from repository, display sorted by updated_at, "New Chat" button, delete session
- [x] 7.3 Build message list: scrollable list, differentiate user/assistant messages visually, auto-scroll to bottom on new content
- [x] 7.4 Build Markdown message bubble component: render fenced code blocks with syntax highlighting, inline formatting, links
- [x] 7.5 Build message input: multi-line text field, Enter to submit, Shift+Enter for newline, send button, block empty submit
- [x] 7.6 Build streaming indicator: show "..." animation while assistant generating, remove on completion

### 🔎 Checkpoint 7: UI Ready

> 验收目标：完整 UI 可交互，但不接后端。用 mock 数据验证所有交互状态。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 空状态 | 无会话时显示 "没有对话" 占位 |
| B | 新建会话 | 点 "New Chat"，侧边栏出现新条目 |
| C | 切换会话 | 点击不同会话，消息列表切换 |
| D | 删除会话 | 删除会话后从列表消失 |
| E | 发送消息 | 输入文字按 Enter，消息出现在列表（mock assistant 回 "echo"） |
| F | Shift+Enter | 插入换行不发送 |
| G | Markdown 渲染 | 代码块有 monospace 字体，`**粗体**` 生效，链接可点击 |
| H | Streaming 效果 | Mock 分 3 段延迟回调 on_chunk，UI 逐段显示 |
| I | 滚动 | 消息超过可视区时自动滚到底部 |

---

## 8. Integration & Wiring

> [!CAUTION]
> ⛔ **STOP HERE** — Phases 4, 5, 6, and 7 must ALL be fully verified before starting Phase 8.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 8" or "start phase 8".

- [x] 8.1 Wire session persistence: load session list on startup, load messages on session switch, save messages after send/response
- [x] 8.2 Wire config → FFI: pass provider config (api_key) and agent type config (model, system_prompt, tools) to C++ send_message
- [x] 8.3 Wire tools: display tool call requests in the message UI, pass tool results back to model (single turn for now)
- [x] 8.4 Handle errors end-to-end: network errors, API errors, FFI errors → display in UI as error message bubbles
- [x] 8.5 Wire message send flow: user input → store user message → SidecarBridge.sendMessage() → stream on_chunk into UI → on_done → store assistant message

### 🔎 Checkpoint 8: End-to-End Acceptance

> 验收目标：全链路打通，实现一期完整功能。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 完整对话 | 首次启动 → 输入 key → 新建会话 → 发消息 → 看到流式回复 → 消息存入 DB |
| B | 会话恢复 | 关闭并重启应用 → 之前的会话和消息完整保留 → 可继续对话 |
| C | 多会话 | 创建 2+ 个会话，各自发送不同内容 → 切换后消息列表独立正确 |
| D | 错误处理 | 断网后发消息 → UI 显示错误提示（不 crash） |
| E | 单轮工具 | Agent 回复中调用 read_file → UI 显示工具调用卡片 → 工具结果回传并显示后续回复 |
| F | 跨平台 | 在目标平台完成完整对话流程（至少一个桌面平台）

---

## 9. 会话隔离修复

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 8 must be fully verified before starting Phase 9.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 9" or "start phase 9".

### 问题

`_callModel()` 在 `await SidecarBridge.sendMessage()` 之后直接引用 `_currentId!` 和 `_messages`，但用户可能在 await 期间切换/创建了新会话，导致异步回调中的 `setState` 和 `_msgRepo.insert` 操作到错误的 session。

根本原因：`_currentId` / `_messages` 是 state field，被多个异步操作共享，没有在 await 边界前做快照。

### 修复任务

- [x] 9.1 在 `_sendMessage()` 中 await `_callModel()` 前，将 `_currentId!` 和 `_messages` 快照到局部变量并传入 `_callModel()`
- [x] 9.2 将所有 `_currentId!`、`_messages` 的引用替换为传入的局部参数
- [x] 9.3 `setState` 中增加 `_currentId == sessionId` 守卫，防止在已切换的会话中更新 UI
- [x] 9.4 清理多余的 `_currentId!` 断言（传入参数后不再需要）
- [x] 9.5 `_storeError()` 改为接收 `sessionId` 参数，不再读取 `_currentId!`；调用处传入已快照的 sessionId

### 🔎 Checkpoint 9: 会话隔离

> 验收目标：多会话并发操作时回复不会串到错误会话。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 流式回复隔离 | 会话 A 发消息 → 不等回复切到会话 B → A 的回复仍然存入会话 A，不在 B 的 UI 中闪现 |
| B | 新建会话隔离 | 会话 A 发消息 → 不等回复新建会话 B → A 的回复正确存入会话 A，B 的消息列表保持空（仅 welcome） |
| C | UI 不错误更新 | 会话切换后，旧请求的 `setState` 被 `_currentId == sessionId` 守卫拦截，不会往当前 UI 插入不属于当前会话的消息 |
| D | 数据库一致性 | 最终 assistant 消息的 `session_id` 与 user 消息一致 |
| E | 错误消息隔离 | API 错误或网络异常回复存入正确会话，不污染切换后的会话 |

---

## 10. 多轮工具调用文本修复

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 9 must be fully verified before starting Phase 10.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 10" or "start phase 10".

### 问题

`_callModel()` 中 `allText` 跨轮次累加（`allText += text`），多轮 tool call 场景下最终存储的 assistant 消息包含所有轮次的文本拼接，且无分隔符。

例如：第一轮模型回复 "让我读取文件" + tool call，第二轮回复 "文件内容是 hello"。存入 DB 的 content 为 `"让我读取文件文件内容是 hello"`，而非仅最终轮次的 `"文件内容是 hello"`。

根本原因：`allText` 设计为全程累加，但对单条 assistant 消息而言，前面轮次的文本已作为 API history 的一部分，不应重复出现在最终消息内容中。

### 修复任务

- [x] 10.1 将存储 assistant 消息时的 `content` 从 `allText` 改为 `turnText`（当前轮次文本），仅保留最终轮次的回复内容
- [x] 10.2 确认 `_streamingText` UI 显示逻辑不受影响（流式显示仍可展示过程文本）

### 🔎 Checkpoint 10: 多轮文本正确性

> 验收目标：多轮工具调用场景下存入 DB 的 assistant 消息内容正确。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 单轮无工具 | 存储的 assistant 消息内容与 `_streamingText` 一致，不受影响 |
| B | 多轮有工具 | 最终 assistant 消息仅包含最后轮次文本，不含前面轮次文本 |
| C | 单轮有工具 | 仅工具调用无文本时，不产生空 content 消息 |

---

## 11. 输入防护与 mounted 检查

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 10 must be fully verified before starting Phase 11.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 11" or "start phase 11".

### 问题

1. `_sendMessage()` 无 `_isStreaming` 检查：流式回复期间用户仍可按 Send 或 Enter 触发新请求，导致并发调用
2. `_callModel()` 中多个 `await sendMessage()` 之后的 `setState` 缺少 `mounted` 检查（当前仅 onChunk 回调中有），Widget 销毁后会 crash
3. `_storeError()` 中 `setState` 同样缺少 `mounted` 守卫

### 修复任务

- [x] 11.1 `_sendMessage()` 开头增加 `if (_isStreaming) return;` 防护
- [x] 11.2 `_callModel()` 中所有 await 后的 `setState` 加上 `if (mounted)` 守卫（行 346、363、368、404、428）
- [x] 11.3 `_storeError()` 中 `setState` 增加 `if (mounted)` 守卫

### 🔎 Checkpoint 11: 健壮性

> 验收目标：并发发送被阻止，Widget 销毁后回调不 crash。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 流式中发送 | 流式回复期间按 Send 或 Enter 不触发新请求 |
| B | 正常发送恢复 | 流式结束后可正常发送新消息 |
| C | mounted 守卫 | Widget 销毁后回调不 crash（可通过快速切换会话模拟） |

---

## 12. SSE 解析与 API 格式修复

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 11 must be fully verified before starting Phase 12.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 12" or "start phase 12".

### 背景

对照最新 Anthropic/DeepSeek API 文档（2026-05-24 抓取），发现当前实现存在两个严重 bug 和两个健壮性缺口。

### 问题 1：`input_json_delta` 未处理，tool input 永远为空

**根因**：`model_gateway.cpp` SSE 解析器只处理 `text_delta`，未处理 `input_json_delta`。当前在 `content_block_start`（tool_use）时直接 dump 整个 `content_block`，但 Anthropic 流式规范中 tool_use block 的 `input` 在 start 事件时始终为 `{}`，实际参数通过后续 `input_json_delta` 事件的 `partial_json` 增量下发。

流式 tool use 的标准时序：
```
content_block_start  → tool_use {id:"toolu_xxx", name:"read_file", input:{}}
content_block_delta  → input_json_delta {partial_json: "{\"path\": \"/src/main.dart\"}"}
content_block_stop
```

当前行为：`content_block_start` 时抓到的 tool_use 里 `input` 永远是 `{}`，工具调用拿不到参数。

### 问题 2：单 tool_use / tool_result 的 content 未包裹为数组

**根因**：`_callModel()` 中构建 assistant 消息和 tool result 消息时，对单元素做了"解包"优化（`length == 1 ? blocks[0] : blocks`）。但 Anthropic API 规范要求 content 必须是**字符串**或 **content block 数组**。单个 `{"type": "tool_use", ...}` 或 `{"type": "tool_result", ...}` 对象直接作为 content 值不符合规范，会导致 HTTP 400。

### 问题 3：`stop_reason` 未从 `message_delta` 提取

**根因**：当前仅靠"是否收到 `content_block_start`(tool_use)" 推断工具调用，而非解析 `message_delta.stop_reason`。若模型输出了空的 tool_use 块但又取消了调用，逻辑会误判。

### 问题 4：`thinking_delta` / `signature_delta` 未处理

**根因**：SSE 解析器未处理 `thinking_delta` 和 `signature_delta`。当模型启用 extended thinking 时，这些事件会落入 `else` 分支产生 "unrecognized event type" warning，且思考文本被丢弃。

### 修复任务

- [x] 12.1 SSE 解析器增加 `input_json_delta` 处理：累积 `partial_json`，在 `content_block_stop` 时拼接完整 input JSON，替换 tool_use block 中的 `input` 字段
- [x] 12.2 `_callModel()` 中 assistantBlocks 和 toolResults 的 content 始终使用数组格式（去掉单元素解包逻辑）
- [x] 12.3 SSE 解析器从 `message_delta` 提取 `stop_reason` 并透传至回调（`on_done` 增加 stop_reason 参数或通过现有机制传递）
- [x] 12.4 SSE 解析器增加 `thinking_delta` / `signature_delta` 识别（暂不暴露到 UI，仅打日志，避免 unrecognized event warning）

### 🔎 Checkpoint 12: API 规范合规

> 验收目标：工具调用拿到正确参数，API 请求格式符合官方规范。

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | tool input 完整 | 模型调用 `read_file` 时，C++ 侧回调的 tool_use JSON 中 `input.path` 有正确的路径值，不是空 `{}` |
| B | tool_result content 格式 | 单工具结果时请求体的 `content` 字段为数组格式 `[{type:"tool_result",...}]`，非单个对象 |
| C | assistant tool_use content 格式 | 纯 tool_use（无 text）时 assistant 消息的 `content` 为数组格式 |
| D | stop_reason 传递 | `message_delta.stop_reason` 被正确解析，`on_done` 可区分 `end_turn` / `tool_use` / `max_tokens` |
| E | thinking delta 不报 warning | 启用 thinking 的模型不再产生 "unrecognized event type" 日志 warning |
| F | 回归：单轮无工具 | 普通对话功能不受影响 |
| G | 回归：多轮工具调用 | 工具调用 → 结果回传 → 模型继续回复全流程正常 |

---

## 13. on_done 回调悬空指针修复

> [!CAUTION]
> ⛔ **STOP HERE** — Phase 12 must be fully verified before starting Phase 13.
> Do NOT implement any task in this phase until the user explicitly says: "execute phase 13" or "start phase 13".

### 背景

`NativeCallable.listener` 的 C→Dart 回调是**异步**的：C 代码调用回调时，Dart 侧只是将消息放入 isolate 事件队列，实际 Dart 闭包在 C 函数返回后才执行。因此传给 `on_done` 的指针必须在 C 函数返回后仍然有效。

`dispatch_events()` 中的 DONE 事件是安全的 — `done_err` / `done_stop_reason` 存储在 `impl->events` 中，持久到下一次 `send_message` 调用。但若干 fallback `on_done` 错误路径直接使用了**局部变量**的 `.c_str()`：

| 行 | 代码 | 安全性 |
|----|------|--------|
| 327 | `on_done(-1, err.c_str(), "")` | ❌ `err` 是局部 `std::string` |
| 340 | `on_done(-1, "Authentication failed", "")` | ✓ 字符串字面量 |
| 350 | `on_done(-1, err.c_str(), "")` | ❌ `err` 是局部 `std::string` |
| 359 | `on_done(0, "", "")` | ✓ 字符串字面量 |

### 复现条件

多轮工具调用：第一轮返回 `tool_use` → 工具执行 → 第二轮 API 返回 HTTP 400（如 DeepSeek 拒绝某些请求），走到 350 行局部变量路径 → crash。

### 修复任务

- [x] 13.1 在 `ModelGateway::Impl` 中添加 `std::string last_error` 成员，`execute()` 开始时清空
- [x] 13.2 将 327 行和 350 行的 fallback `on_done` 调用改为使用 `impl_->last_error` 而非局部变量

### 🔎 Checkpoint 13: 悬空指针修复

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 多轮工具调用不 crash | 模型请求工具 → 工具执行 → 第二轮 API 调用（无论成败）不出现 `FormatException` crash |
| B | 错误信息正确传递 | HTTP 错误码 / CURL 错误信息正确显示在 UI 中 |
| C | 回归：单轮正常 | 单轮对话功能不受影响 |

---

## 14. list_dir 工具结果格式统一

> ⛔ **STOP HERE** — Phase 13 must be fully verified before starting Phase 14.

### 问题

`list_dir` 返回 `{"ok":true,"entries":[...]}`，没有 `content` 字段。Dart 侧读取 `result['content']` 得到 `null` → 空字符串，导致第二轮 API 请求的 `tool_result.content` 为空，DeepSeek 返回 HTTP 400。

`read_file` 使用 `ok_result()` helper 返回 `{"ok":true,"content":"..."}` 没有问题。

### 修复任务

- [x] 14.1 将 `tools.cpp:298` 中 `list_dir` 的手工拼 JSON 改为调用 `ok_result(entries_json)`

### 🔎 Checkpoint 14: 工具返回格式统一

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | list_dir 后第二轮 API 不 400 | 模型调用 list_dir → 工具执行 → 第二轮 API 正常返回 |
| B | list_dir 内容正确传递 | 模型能看到目录列表并基于它继续回答 |

---

## 15. DeepSeek API 兼容性修复（content 格式统一）

> ⛔ **STOP HERE** — Phase 14 must be fully verified before starting Phase 15.

### 问题

API 请求体中第一条用户消息的 `content` 是纯字符串（`"你好"`），但后续 assistant/tool_result 消息的 `content` 是数组。DeepSeek 的 Anthropic 代理对混用格式的请求返回 HTTP 400（仅 68ms 就返回，属于请求体格式校验失败）。

DeepSeek 文档示例中即使是简单文本也使用 `[{"type":"text","text":"..."}]` 数组格式。

### 修复任务

- [x] 15.1 在 `model_gateway.cpp` 中增加 `LOG_INFO("body=" + body_str)` 打印实际请求体
- [x] 15.2 将 `main.dart` 中从 DB 读取的消息 content 从纯字符串改为 `[{"type":"text","text":"..."}]` 数组格式

### 🔎 Checkpoint 15: DeepSeek API 兼容

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 工具调用后第二轮 API 不 400 | list_dir 工具调用 → 第二轮 API 正常返回 text 回复 |
| B | 纯文本对话不受影响 | 无工具调用的正常对话不出现格式错误 |

---

## 16. Thinking 块透传

> ⛔ **STOP HERE** — Phase 15 must be fully verified before starting Phase 16.

### 问题

DeepSeek 默认启用思考模式（`thinking: {"type":"enabled"}`），assistant 回复的 `content[]` 中第一个元素是 `{"type":"thinking","thinking":"...","signature":"..."}` 块。后续请求**必须原样传回**此块，否则 API 返回 HTTP 400。

当前 C++ SSE 解析器仅打日志忽略 thinking 块，Dart 侧构建 assistantBlocks 也不包含它，导致 thinking 块丢失。

详见 design.md Decision 2（FFI 通信协议）、Decision 8（API 兼容性），以及 specs/model-gateway（Thinking block handling）。

### 修复任务

- [ ] 16.1 `SseEvent` 新增 `std::string thinking_json` 字段；`SseEventKind` 新增 `THINKING`；`Impl` 新增 `std::map<int, PendingThinking>`（含 `thinking` + `signature` 两个 string）
- [ ] 16.2 `content_block_start` 分支增加 `type == "thinking"` 处理，记录 index 到 `pending_thinking`
- [ ] 16.3 `thinking_delta` → 累积 `pending_thinking[idx].thinking`；`signature_delta` → 累积 `pending_thinking[idx].signature`
- [ ] 16.4 `content_block_stop` 分支优先检查 `pending_thinking`，命中则生成 `{"type":"thinking","thinking":"...","signature":"..."}` JSON → `SseEventKind::THINKING` 事件
- [ ] 16.5 `dispatch_events()` 新增 `on_thinking` 参数，处理 THINKING 事件
- [ ] 16.6 `sidecar_api.h` 新增 `OnThinkingCallback` typedef；`send_message` 新增第 10 参数；`model_gateway.h` 同步
- [ ] 16.7 `execute()` 开头清空 `pending_thinking`
- [ ] 16.8 `sidecar_bridge.dart` 新增 `OnThinkingNative` / `OnThinkingCallback` 类型；`sendMessage()` 新增 `onThinking` 参数（可选）；worker isolate 新增 `NativeCallable` + `'thinking'` message type
- [ ] 16.9 `_callModel()` 新增 `turnThinkingBlocks` 列表，`onThinking` 回调捕获，每轮重置
- [ ] 16.10 assistant 消息 content 拼装顺序：`[thinking..., text, tool_use...]`

### 🔎 Checkpoint 16: Thinking 块透传

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 工具调用后第二轮 API 不 400 | thinking 块正确传回，API 正常返回 text 回复 |
| B | 非思考模式不受影响 | 模型不返回 thinking 时，`pending_thinking` 为空，无 THINKING 事件 |
| C | thinking 块内容完整 | 传回的 `thinking`/`signature` 字段与 SSE 流式输出完全一致 |
| D | 多轮工具调用 | 每一轮 assistant thinking 块都被正确捕获和传回 |
| E | assistantBlocks 顺序正确 | content 数组中 thinking 块始终在 text/tool_use 之前 |