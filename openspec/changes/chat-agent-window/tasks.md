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

- [ ] 6.1 Implement workspace path management: `set_workspace` C entry point, store and validate path
- [ ] 6.2 Implement `read_file`: read file content, error on missing/binary/out-of-workspace
- [ ] 6.3 Implement `list_dir`: enumerate directory entries with type indicator, error on missing/not-dir/out-of-workspace
- [ ] 6.4 Implement path sandboxing: canonical path resolution, workspace boundary check for both tools

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

- [ ] 7.1 Build app shell: window title, sidebar layout (session list left, chat area right)
- [ ] 7.2 Build session list sidebar: load sessions from repository, display sorted by updated_at, "New Chat" button, delete session
- [ ] 7.3 Build message list: scrollable list, differentiate user/assistant messages visually, auto-scroll to bottom on new content
- [ ] 7.4 Build Markdown message bubble component: render fenced code blocks with syntax highlighting, inline formatting, links
- [ ] 7.5 Build message input: multi-line text field, Enter to submit, Shift+Enter for newline, send button, block empty submit
- [ ] 7.6 Build streaming indicator: show "..." animation while assistant generating, remove on completion

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

- [ ] 8.1 Wire session persistence: load session list on startup, load messages on session switch, save messages after send/response
- [ ] 8.2 Wire config → FFI: pass provider config (api_key) and agent type config (model, system_prompt, tools) to C++ send_message
- [ ] 8.3 Wire tools: display tool call requests in the message UI, pass tool results back to model (single turn for now)
- [ ] 8.4 Handle errors end-to-end: network errors, API errors, FFI errors → display in UI as error message bubbles
- [ ] 8.5 Wire message send flow: user input → store user message → SidecarBridge.sendMessage() → stream on_chunk into UI → on_done → store assistant message

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