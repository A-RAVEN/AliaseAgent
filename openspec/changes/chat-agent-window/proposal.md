# Proposal: Chat Agent Window — 一期可对话桌面窗口

## Why

AliasAgent 作为通用 AI 编程 Agent 框架，需要一个可运行的最小闭环来验证核心架构决策。一期聚焦于「与 Agent 对话」这一最基础的用户交互场景，同时搭好 Dart ↔ C++ FFI 架构骨架，为后续多 Agent 编排、复杂文档处理等能力打基础。

## What Changes

- 新建 Flutter 桌面应用，支持 Windows / Mac / Linux
- 实现对话窗口：消息列表（Markdown 渲染 + 流式输出）+ 输入框
- 实现 C++ Sidecar 模块，通过 dart:ffi（同步调用 + 回调）与 Flutter 通信
- C++ 侧负责 Anthropic API 调用（SSE 流式解析）及基础只读工具执行
- 实现 Agent Type 配置框架，一期仅运行 General 类型
- 实现 provider 配置文件管理（`~/.aliasagent/config.json`），支持多 provider 扩展
- 实现 SQLite 本地会话持久化（sessions + messages）
- 实现基础只读工具：read_file、list_dir

## Capabilities

### New Capabilities

- `chat-ui`: Flutter 桌面对话窗口 — 消息列表、Markdown 渲染、流式输出、输入框
- `ffi-bridge`: Dart ↔ C++ FFI 通信层 — 同步调用 + 回调模式
- `agent-config`: Agent Type 与 Provider 配置框架 — 配置文件管理、Type 注册机制
- `session-persistence`: SQLite 本地会话与消息持久化
- `model-gateway`: Anthropic API 调用与 SSE 流式解析（C++ 侧）
- `basic-tools`: 基础只读工具 — read_file、list_dir（C++ 侧执行）

### Modified Capabilities

<!-- No existing capabilities to modify, this is the first implementation phase -->

## Impact

- 新建 Flutter 项目（desktop），引入 `sqflite`、`flutter_markdown` 等依赖
- 新建 C++ 项目（Sidecar），引入 `libcurl`（HTTP/SSE）、`SQLite3`（或复用 Dart 侧数据库）
- dart:ffi 绑定层，定义 C 接口函数签名
- 无服务端依赖，纯本地运行
- 无移动端适配（后续阶段）