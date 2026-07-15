# Design: Chat Agent Window

## Context

AliasAgent 一期目标是构建一个可对话的桌面窗口。Flutter 负责 UI（消息列表、Markdown 渲染、输入框），C++ Sidecar 负责 Anthropic-compatible API 调用（DeepSeek / Anthropic）和基础只读工具执行，两者通过 dart:ffi 同步调用 + 回调模式通信。

参考架构（来自已归档的 explore-agent-framework proposal）：
- Flutter 桌面应用（Win/Mac/Linux）
- C++ Sidecar via FFI（系统能力层）
- Provider 可配置的模型接入
- Agent Type 一等公民

## Goals / Non-Goals

**Goals:**
- 实现端到端对话流程：用户输入 → Dart → FFI → C++ → Anthropic-compatible API → SSE stream → C++ 回调 → Dart UI 渲染
- 搭好 dart:ffi 通信骨架，后续新增 C++ 能力只需扩展接口
- Agent Type 配置框架做到可扩展，一期只有 General
- SQLite 本地持久化会话和消息
- 支持 Anthropic 官方 API 和 DeepSeek Anthropic 兼容端点

**Non-Goals:**
- 移动端（后续阶段）
- 服务端 / 消息中继（后续阶段）
- 多 Agent 编排、群聊容器（后续阶段）
- 写文件、执行 shell 等危险工具（后续阶段）

## Decisions

### 1. 进程模型

```
┌──────────────────────────────────────────┐
│  Flutter 进程 (Desktop)                   │
│                                           │
│  Main Isolate (UI)       Worker Isolate   │
│  ┌─────────────────┐    ┌──────────────┐ │
│  │ - UI 渲染        │    │ - send_message│ │
│  │ - 消息管理        │    │ - curl_easy_  │ │
│  │ - SQLite         │    │   perform     │ │
│  │ - Agent Type 注册 │    │ - NativeCall- │ │
│  │ - 工具执行        │    │   able 回调   │ │
│  │                  │    │       │       │ │
│  │  ▲ SendPort      │    │       │       │ │
│  │  │ ReceivePort   │    │       ▼       │ │
│  │  │ await for     │    │  dart:ffi     │ │
│  │  │              │    │  (同步调用)    │ │
│  └──┼──────────────┘    └──────┼───────┘ │
│     │                          │          │
│     │                   ┌──────▼───────┐  │
│     │                   │  C++ 动态库   │  │
│     │                   │  (.dll/.so/  │  │
│     │                   │   .dylib)     │  │
│     │                   │  - HTTP/SSE  │  │
│     │                   │  - read_file │  │
│     │                   │  - list_dir  │  │
│     │                   └──────────────┘  │
│     │  同进程内加载, 非独立进程             │
└──────────────────────────────────────────┘
```

**Decision**: C++ 编译为动态库，Flutter 进程内通过 `dart:ffi` 加载调用。`send_message`（阻塞 HTTP 调用）在 worker isolate 中执行，通过 `Isolate.spawn` + `SendPort`/`ReceivePort` 与主 isolate 通信。`set_workspace`、`read_file`、`list_dir` 等快速本地调用保留在主 isolate 直接执行。

**Alternatives considered**:
- 独立进程 + IPC（gRPC/socket）：更隔离，崩溃不互相影响，但一期复杂度太高
- 进程内动态库：简单，零序列化开销，崩溃会带垮 Flutter 进程，但一期可接受
- 主 isolate 直接调用（原实现）：最简，但 `curl_easy_perform` 阻塞导致 UI 冻结，不可接受

**Rationale**: 一期 C++ 逻辑简单（HTTP + 两个 FS 工具），进程内加载最简。Worker isolate 解决 UI 冻结问题，同时不引入独立进程的复杂度。后期 C++ 职责加重后如需隔离，可再拆独立进程，FFI 接口层抽象好了迁移成本不高。

### 2. FFI 通信协议

**C 侧签名**（阻塞调用，运行在 worker isolate）:

```c
// 回调类型
typedef void (*OnChunkCallback)(const char* text);
typedef void (*OnToolCallCallback)(const char* json);
typedef void (*OnThinkingCallback)(const char* thinking_json);
typedef void (*OnDoneCallback)(int code, const char* err, const char* stop_reason);

// 发送消息 (阻塞 HTTP，回调在 curl_easy_perform 期间同步触发)
int send_message(
  const char* api_key,
  const char* base_url,
  const char* model,
  const char* system_prompt,
  const char* messages_json, // JSON: [{role,content},...]
  const char* tools_json,    // JSON: [{name,description,input_schema},...]
  OnChunkCallback on_chunk,
  OnToolCallCallback on_tool_call,
  OnThinkingCallback on_thinking,
  OnDoneCallback on_done
);

// 本地工具（主 isolate 直接调用，同步返回 JSON）
const char* set_workspace(const char* path);
const char* read_file(const char* path);
const char* list_dir(const char* path);
```

**回调触发时序**（一次 `send_message` 调用）：

```
SSE stream → C++ 解析 → impl->events 缓冲 → dispatch_events

按 events 顺序依次调用（全部在 curl_easy_perform 返回前完成）:
  1. on_thinking  — thinking 块（如有），在 text/tool_use 之前
  2. on_chunk     — 文本增量，可多次
  3. on_tool_call — 完整 tool_use JSON（累积 input_json_delta 后在 content_block_stop 时触发）
  4. on_done      — code + error + stop_reason

注意: NativeCallable.listener 是异步的 — C 调用回调时 Dart 仅将消息入队，
实际 Dart 闭包在 C 函数返回后才执行。因此传给回调的指针必须指向生命周期
长于 C 函数调用的内存（Impl 成员或静态存储），不能是局部变量。
```

**工具返回 JSON 格式**:

```json
// read_file → {"ok":true,"content":"..."}
// list_dir  → {"ok":true,"content":"[{\"name\":\"...\",\"type\":\"file\"},...]"}
// 错误     → {"ok":false,"error":"..."}
```

**Dart 侧包装**（`SidecarBridge`）:

```dart
class SidecarBridge {
  Future<void> sendMessage({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }); // 通过 Isolate.spawn + ReceivePort 实现

  String? setWorkspace(String path); // 主 isolate 同步
  String readFile(String path);
  String listDir(String path);
}
```

`sendMessage` work flow:
1. `Isolate.spawn(_workerMain, args)` — 启动 worker isolate
2. Worker isolate 加载 DLL、创建 `NativeCallable.listener` 回调（chunk / tool_call / thinking / done）、调用阻塞 `send_message` FFI
3. C 回调触发时，worker 通过 `SendPort` 将事件转发到主 isolate
4. 主 isolate `await for` 消费 `ReceivePort`，依次调用 Dart 回调 (`onChunk`/`onToolCall`/`onThinking`/`onDone`)

**Decision**: 单一入口函数 + 四个回调。用 C 风格接口（`const char*`），Dart 侧通过 `Pointer<Utf8>` 传参。JSON 序列化在 Dart 侧完成，C 侧解析。阻塞调用以 worker isolate 封装，保持 UI 响应。

**Alternatives considered**:
- protobuf/flatbuffers：强类型，但引入构建复杂度
- 消息队列 + 事件循环：灵活但太重
- 主 isolate 直接同步调用（原实现）：UI 冻结，已废弃

**Rationale**: C 字符串 + JSON 是一期最轻量的方案。后期工具轮次复杂时，可演进为结构化协议。

### 3. API 调用位置

**Decision**: C++ 侧调用 Anthropic-compatible Messages API with SSE streaming。支持 Anthropic 官方端点和 DeepSeek Anthropic 兼容端点（通过 `base_url` 区分）。

**Rationale**:
- 给 C++ 层实质职责，验证 FFI 通路
- Dart 侧保持纯 UI + 状态管理，不直接处理网络
- 后期需要 C++ 侧做 tool use loop（执行工具 -> 回传结果 -> 继续对话），如果在 Dart 侧则要反复跨越 FFI

### 4. 会话数据模型

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT 'New Chat',
  agent_type TEXT NOT NULL DEFAULT 'general',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  tool_calls TEXT,
  token_count INTEGER,
  created_at INTEGER NOT NULL
);
```
`tool_calls` 列为 JSON 数组，存储该 assistant 消息关联的工具调用记录，每条记录包含 `id`、`name`、`input`、`status`、`result`。渲染时解析为 `ToolCallCard` 并插入该消息之前在消息列表中。

**Decision**: 两个表，外键约束，UUID 主键。

**Alternatives considered**:
- JSON 文件：更简单，但多会话查询不方便
- C++ 侧 SQLite：C++ 也可以操作 SQLite，但 UI 绑数据更方便在 Dart 侧

**Rationale**: SQLite + sqflite 是 Flutter 生态成熟方案。后面加服务端同步时，表结构可直接作为同步单元。

### 5. Agent Type 注册机制

```dart
// Agent Type 配置（从配置文件读取）
class AgentTypeConfig {
  final String name;
  final String provider;
  final String model;
  final String systemPrompt;
  final List<String> tools; // 工具名列表
}

// 注册表（单例）
class AgentTypeRegistry {
  void register(AgentTypeConfig config);
  AgentTypeConfig? lookup(String name);
  List<String> listNames();
}
```

**Decision**: 简单注册表模式。配置文件 JSON 定义所有 Agent Type，启动时解析并注册。一期只配 General。

**Rationale**: 足够简单，后期扩展为动态加载（从服务端下发、从插件加载等）时接口不变。

### 6. Provider 配置文件结构

```json
// ~/.aliasagent/config.json
{
  "version": 1,
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-...",
      "base_url": "https://api.anthropic.com"
    }
  },
  "agent_types": {
    "general": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["read_file", "list_dir"]
    }
  }
}
```

**Decision**: 单文件同时包含 providers 和 agent_types。首次启动时如果没有该文件，弹窗引导用户输入 API key，写入配置。`base_url` 为空时默认 `https://api.anthropic.com`，可改为 `https://api.deepseek.com/anthropic` 以使用 DeepSeek。

**Rationale**: 一个文件覆盖全配置，编辑和迁移方便。Providers 和 Agent Types 物理上放在一起，逻辑上用 key 引用。

### 7. 工具调用多轮循环

**Decision**: `_callModel()` 内置最多 5 轮 tool use loop：

```
User msg → API Request #1 → model returns tool_use
  → execute tool → API Request #2 (with tool_result)
  → model returns text → store & display
```

每轮构建 assistant content blocks 时保持顺序 `[thinking?, text?, tool_use...]`，tool_result 以 user role 消息发送，content 使用数组格式。

**Rationale**: 单轮交互无法完成需要工具辅助的任务。5 轮上限防止无限循环。工具调用在主 isolate 同步执行（`read_file` / `list_dir` 是本地 I/O，< 100ms），不会阻塞 UI。

### 8. DeepSeek / Anthropic API 兼容性

**Decision**: API 请求体统一使用 Anthropic Messages API 格式，`content` 始终使用数组格式 `[{"type":"text","text":"..."}]`，不混用字符串和数组。

DeepSeek Anthropic 兼容端点差异：
- `anthropic-version` / `anthropic-beta` header 被忽略
- `thinking` 默认为 `{"type":"enabled"}`（Anthropic 官方需显式 opt-in）
- `cache_control` 被忽略
- `is_error` (tool_result) 被忽略
- `budget_tokens` (thinking) 被忽略
- 不支持 `redacted_thinking`、image、document 等块类型

### 9. ChatItem 统一列表模型

**Decision**: 使用 Dart 3 sealed class 而非 enum + nullable 字段。三种变体：

```dart
sealed class ChatItem { const ChatItem(); }
class ChatMessageItem extends ChatItem { final Message message; }
class ChatToolCallItem extends ChatItem { final ToolCallActivity activity; }
class ChatStreamingItem extends ChatItem { final String text; }
```

`ChatArea` 接收 `List<ChatItem> items`，`ListView.builder` 通过 `switch (item)` 穷尽分发三种 widget。每个 widget 使用对应 ID 的 `ValueKey` 保持交互状态（如 ToolCallCard 展开/折叠）。

**Rationale**: enum + nullable 方案 (`type` + `message?` + `toolCall?`) 每个变体都带着不相关的 null 字段，穷尽匹配靠 `switch (type)` 而非语言级别检查。sealed class 消除 nullable、`switch` 穷尽保证编译期检查，发现新变体时编译器给出错误而非运行期漏掉。Phase 18 的工具卡片持久化是消息列表模型的第一次结构性重构，用更强的类型系统为后续扩展留余地。

### 10. DB Schema 迁移策略（v1 → v2）

**Decision**: 非破坏性渐进迁移。`_schemaVersion` 从 1 升到 2，`onUpgrade` 中按 `oldVersion` 分支处理：

```
oldVersion == 1 → ALTER TABLE messages ADD COLUMN tool_calls TEXT
                   (保留所有现有数据)
oldVersion == ? → DROP + 重建（仅用于无法识别的版本 gap）
```

`onCreate` 和 `openAt` 同步更新到 v2 schema（建表时直接包含 `tool_calls TEXT` 列）。

**Rationale**: 当前 `database_service.dart:49-52` 的 `onUpgrade` 无条件 `DROP TABLE`，一旦 `_schemaVersion` 从 1 升到 2，所有用户聊天历史静默丢失。Spec `session-persistence` 明确要求："for known migration paths, a non-destructive migration is applied to preserve existing data"。旧会话升级后 tool_calls 列为 NULL，渲染时按无工具调用处理（向后兼容）。

### 11. ChatItem 重构的向后兼容

**Decision**: `ChatArea` 的 public API 从三个独立参数改为单一 `List<ChatItem> items`：

```dart
// Before (Phase 18.1-18.5)
ChatArea(messages: [...], toolActivities: [...], streamingText: '...')

// After (Phase 18.10)
ChatArea(items: [ChatMessageItem(...), ChatToolCallItem(...), ChatStreamingItem(...)])
```

**Impact scope**:
- `ChatArea` widget — 构造函数 + `ListView.builder` 分发逻辑
- `_ChatScreenState` — `_messages` + `_toolActivities` → `_chatItems`；`_loadMessages()` 从 tool_calls JSON 重建 ChatToolCallItem
- 现有 widget tests（`chat_area_test.dart` 等）— 调用点需同步更新
- `tool_call_card_test.dart` — 不受影响（ToolCallCard 组件 API 不变）

**`_endStreaming()` 新语义**: 只移除 `ChatStreamingItem`，保留 `ChatMessageItem` 和 `ChatToolCallItem`。不再执行 `_toolActivities = []`。

**Rationale**: sealed class 重构是结构性变更，影响面可控（2 个源文件 + 若干测试）。现有测试的更新量小——主要是将 `messages:` + `toolActivities:` 参数替换为 `items:` 列表。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| C++ 动态库崩溃会带垮 Flutter 进程 | C++ 侧做好错误处理，避免未定义行为；后期可拆独立进程 |
| SSE 解析在 C 侧，调试困难 | 加日志输出到文件（C++ 侧 log 到 `~/.aliasagent/logs/`） |
| `NativeCallable.listener` 异步回调导致悬空指针 | 所有传给回调的字符串指针必须存储在 Impl 成员或静态存储中，不能是局部变量 `.c_str()` |
| DB schema 升级丢失用户数据 | v1→v2 用 `ALTER TABLE ADD COLUMN` 非破坏性迁移（见 section 10）；不可识别版本才 DROP |
| ChatItem sealed class 重构破坏现有测试 | 同步更新 `chat_area_test.dart`、integration tests 的 ChatArea 构造调用 |
| FakeSidecar listDir stub 返回格式与真实 C++ 不一致 | stub 默认值从 `{"ok":true,"entries":[]}` 修正为 `{"ok":true,"content":"[]"}` |
| Tool card 排列位置不穿插在消息之间 | ChatItem 模型按 turn 顺序插入，ToolCallCard 出现在对应 assistant message 之前 |
| DeepSeek thinking 块必须透传 | `OnThinkingCallback` 捕获 thinking 块，Dart 侧在 assistant content 中原样回传；不传回会导致 HTTP 400 |
| API 响应体错误信息不可见 | HTTP ≥400 时将响应体写入日志（debug-infra 提案项） |
| flutter_markdown 对复杂内容渲染有限 | 一期接受，后续可换更丰富的渲染方案 |
| Windows/Mac/Linux 三平台 FFI 构建差异 | CI 三平台构建矩阵；C++ 用 CMake 统一构建 |