# Proposal: Chat Agent Window — 一期可对话桌面窗口

## Why

AliasAgent 作为通用 AI 编程 Agent 框架，需要一个可运行的最小闭环来验证核心架构决策。一期聚焦于「与 Agent 对话」这一最基础的用户交互场景，同时搭好 Dart ↔ C++ FFI 架构骨架，为后续多 Agent 编排、复杂文档处理等能力打基础。

## What Changes

- 新建 Flutter 桌面应用，支持 Windows / Mac / Linux
- 实现对话窗口：消息列表（Markdown 渲染 + 流式输出）+ 输入框
- 实现 C++ Sidecar 模块，通过 dart:ffi 同步调用 + 回调与 Flutter 通信，Dart 侧以 worker isolate 封装避免阻塞 UI
- C++ 侧负责 API 调用（SSE 流式解析）及基础只读工具执行，支持 Anthropic 官方 API 和 DeepSeek Anthropic 兼容端点
- 实现 Agent Type 配置框架，一期仅运行 General 类型
- 实现 provider 配置文件管理（`~/.aliasagent/config.json`），支持多 provider 扩展
- 实现 SQLite 本地会话持久化（sessions + messages）
- 实现基础只读工具：read_file、list_dir
- 实现多轮工具调用循环（tool use loop），模型请求工具 → 执行 → 结果回传 → 模型继续回复
- 实现扩展思考（extended thinking）块透传，确保 DeepSeek 等默认开启思考模式的 API 正常工作

## Capabilities

### New Capabilities

- `chat-ui`: Flutter 桌面对话窗口 — 消息列表、Markdown 渲染、流式输出、输入框
- `ffi-bridge`: Dart ↔ C++ FFI 通信层 — 同步调用 + 回调模式（chunk / tool_call / thinking / done）
- `agent-config`: Agent Type 与 Provider 配置框架 — 配置文件管理、Type 注册机制
- `session-persistence`: SQLite 本地会话与消息持久化
- `model-gateway`: API 调用与 SSE 流式解析（C++ 侧），支持 Anthropic + DeepSeek
- `basic-tools`: 基础只读工具 — read_file、list_dir（C++ 侧执行）

### Modified Capabilities

<!-- No existing capabilities to modify, this is the first implementation phase -->

## Impact

- 新建 Flutter 项目（desktop），引入 `sqflite`、`flutter_markdown` 等依赖
- 新建 C++ 项目（Sidecar），引入 `libcurl`（HTTP/SSE）、`nlohmann/json`（JSON 解析）
- dart:ffi 绑定层，定义 C 接口函数签名（4 个回调类型）
- 无服务端依赖，纯本地运行
- 无移动端适配（后续阶段）