# Design: Chat Agent Window

## Context

AliasAgent 一期目标是构建一个可对话的桌面窗口。Flutter 负责 UI（消息列表、Markdown 渲染、输入框），C++ Sidecar 负责 Anthropic API 调用和基础只读工具执行，两者通过 dart:ffi 同步调用 + 回调模式通信。

参考架构（来自已归档的 explore-agent-framework proposal）：
- Flutter 桌面应用（Win/Mac/Linux）
- C++ Sidecar via FFI（系统能力层）
- Provider 可配置的模型接入
- Agent Type 一等公民

## Goals / Non-Goals

**Goals:**
- 实现端到端对话流程：用户输入 → Dart → FFI → C++ → Anthropic API → SSE stream → C++ 回调 → Dart UI 渲染
- 搭好 dart:ffi 通信骨架，后续新增 C++ 能力只需扩展接口
- Agent Type 配置框架做到可扩展，一期只有 General
- SQLite 本地持久化会话和消息

**Non-Goals:**
- 移动端（后续阶段）
- 服务端 / 消息中继（后续阶段）
- 多 Agent 编排、群聊容器（后续阶段）
- 写文件、执行 shell 等危险工具（后续阶段）
- 多 provider 实际接入（框架预留，实际只接 Anthropic）

## Decisions

### 1. 进程模型

```
┌─────────────────────────┐
│  Flutter 进程 (Desktop)  │
│  - UI 渲染              │
│  - 消息管理              │
│  - SQLite (sqflite)     │
│  - Agent Type 注册表     │
│       │                  │
│       │ dart:ffi         │
│       │ (同步调用+回调)   │
│       ▼                  │
│  ┌───────────────────┐  │
│  │  C++ 动态库 (.so/  │  │
│  │  .dylib/.dll)      │  │
│  │  - HTTP/SSE Client │  │
│  │  - read_file       │  │
│  │  - list_dir        │  │
│  └───────────────────┘  │
│  同进程内加载, 非独立进程  │
└─────────────────────────┘
```

**Decision**: C++ 编译为动态库，Flutter 进程内通过 `dart:ffi` 加载调用，而非独立进程 IPC。

**Alternatives considered**:
- 独立进程 + IPC（gRPC/socket）：更隔离，崩溃不互相影响，但一期复杂度太高
- 进程内动态库：简单，零序列化开销，崩溃会带垮 Flutter 进程，但一期可接受

**Rationale**: 一期 C++ 逻辑简单（HTTP + 两个 FS 工具），进程内加载最简。后期 C++ 职责加重后如需隔离，可再拆独立进程，FFI 接口层抽象好了迁移成本不高。

### 2. FFI 通信协议

```
Dart 侧                           C 侧

// 发送消息 (同步，返回 request_id)
int send_message(
  const char* agent_type,  // "general"
  const char* model,       // "claude-sonnet-4-6"
  const char* system_prompt,
  const char* messages_json, // JSON: [{role,content},...]
  const char* tools_json,    // JSON: [{name,description,parameters},...]
  void (*on_chunk)(const char* text),    // 流式文本回调
  void (*on_tool_call)(const char* json), // 工具调用回调
  void (*on_done)(int code, const char* err) // 完成回调
);
```

**Decision**: 单一入口函数 + 三个回调。用 C 风格接口（`const char*`），Dart 侧通过 `Pointer<Utf8>` 传参。JSON 序列化在 Dart 侧完成，C 侧解析。

**Alternatives considered**:
- protobuf/flatbuffers：强类型，但引入构建复杂度
- 消息队列 + 事件循环：灵活但太重

**Rationale**: C 字符串 + JSON 是一期最轻量的方案。后期工具轮次复杂时，可演进为结构化协议。

### 3. Anthropic API 调用位置

**Decision**: C++ 侧调用 Anthropic Messages API with SSE streaming。

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
  token_count INTEGER,
  created_at INTEGER NOT NULL
);
```

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

**Decision**: 单文件同时包含 providers 和 agent_types。首次启动时如果没有该文件，弹窗引导用户输入 API key，写入配置。

**Rationale**: 一个文件覆盖全配置，编辑和迁移方便。Providers 和 Agent Types 物理上放在一起，逻辑上用 key 引用。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| C++ 动态库崩溃会带垮 Flutter 进程 | C++ 侧做好错误处理，避免未定义行为；后期可拆独立进程 |
| SSE 解析在 C 侧，调试困难 | 加日志输出到文件（C++ 侧 log 到 `~/.aliasagent/logs/`） |
| flutter_markdown 对复杂内容渲染有限 | 一期接受，后续可换更丰富的渲染方案 |
| Windows/Mac/Linux 三平台 FFI 构建差异 | CI 三平台构建矩阵；C++ 用 CMake 统一构建 |

## Open Questions

- C++ 动态库的构建如何集成到 Flutter 构建流程？（Flutter 官方无标准方案，需手动 CMake + flutter build hook）
- 工具调用后是否需要自动回传结果继续对话（tool use loop），还是一期先单轮？