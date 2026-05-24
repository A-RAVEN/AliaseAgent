# Anthropic API 参考文档

> 本文档基于 Anthropic 官方文档抓取整理，涵盖 Messages API、Streaming（SSE）和 Tool Use（函数调用）三大核心板块。
> 抓取时间：2026-05-24

---

## 一、Messages API 参考

### 1.1 基本信息

- **Endpoint**: `POST https://api.anthropic.com/v1/messages`
- **Content-Type**: `application/json`

### 1.2 请求 Headers

| Header | 类型 | 必需 | 说明 |
|---|---|---|---|
| `x-api-key` | string | **是** | API 密钥，在 Console 中获取，每个密钥绑定到一个 Workspace |
| `anthropic-version` | string | **是** | API 版本号，例如 `2023-06-01` |
| `content-type` | string | **是** | 必须为 `application/json` |
| `anthropic-beta` | string[] | 否 | 实验性功能的 beta 版本号，多个用逗号分隔 |

### 1.3 Request Body 参数

| 参数 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `model` | string | **是** | 模型 ID，如 `claude-sonnet-4-20250514`，长度 1-256 |
| `messages` | object[] | **是** | 输入消息数组，上限 100,000 条。每条包含 `role` 和 `content` |
| `max_tokens` | integer | **是** | 最大生成 token 数，>= 1，模型可能提前停止 |
| `system` | string \| object[] | 否 | system prompt。可为字符串或 content block 数组 |
| `stop_sequences` | string[] | 否 | 自定义停止序列，触发时 `stop_reason` = `stop_sequence` |
| `stream` | boolean | 否 | 是否启用 SSE 流式响应，默认 false |
| `temperature` | number | 否 | 随机程度，范围 0.0-1.0，默认 1.0。0.0 也不会完全确定性 |
| `top_p` | number | 否 | nucleus 采样，0.0-1.0。与 temperature 二选一 |
| `top_k` | integer | 否 | 仅从 top K 选项采样，>= 0，仅高级场景 |
| `tools` | object[] | 否 | 工具定义数组，见第三章 Tool Use |
| `tool_choice` | object | 否 | 工具使用策略，见第三章 |
| `thinking` | object | 否 | 扩展思考（extended thinking）配置 |
| `metadata` | object | 否 | 外部元数据 |
| `metadata.user_id` | string \| null | 否 | 外部用户标识（UUID 等），最长 256，**不要包含 PII** |
| `service_tier` | enum | 否 | `auto`（默认）或 `standard_only` |
| `container` | string \| null | 否 | 跨请求复用的容器标识符 |
| `mcp_servers` | object[] | 否 | MCP 服务器配置 |

#### thinking 参数（扩展思考）

当启用扩展思考时，Claude 会先输出思考过程再给出最终答案。需要至少 1,024 token 预算。

```json
{
  "thinking": {
    "type": "enabled",
    "budget_tokens": 16000
  }
}
```

- `type`: `enabled`（固定值）
- `budget_tokens`: integer, >= 1024，且必须小于 `max_tokens`

#### system 参数格式

system prompt 支持两种格式：

**字符串形式（简写）**：
```json
"system": "You are a helpful assistant."
```

**Content block 数组形式**：
```json
"system": [
  {
    "type": "text",
    "text": "Today's date is 2024-06-01."
  }
]
```

### 1.4 messages 参数详解

#### Role 规则

Messages API 的训练基础是 **user 和 assistant 交替的对话轮次**。

- 每个消息必须包含 `role` 和 `content`
- role 支持：`user`、`assistant`（**注意没有 `system` role**）
- 连续的同 role 消息会被合并为单轮
- 如果最后一条消息 role 是 `assistant`，模型将从该消息末尾继续生成（可用于约束输出）

#### content 格式

每条消息的 `content` 可以是**字符串**或**content block 数组**。

字符串形式是单 `text` block 的简写，以下两条等价：
```json
{"role": "user", "content": "Hello, Claude"}
```
```json
{"role": "user", "content": [{"type": "text", "text": "Hello, Claude"}]}
```

#### 示例

**单条 user 消息**：
```json
{"role": "user", "content": "Hello, Claude"}
```

**多轮对话**：
```json
[
  {"role": "user", "content": "Hello there."},
  {"role": "assistant", "content": "Hi, I'm Claude. How can I help you?"},
  {"role": "user", "content": "Can you explain LLMs in plain English?"}
]
```

**部分填充（prefill）**：
```json
[
  {"role": "user", "content": "What's the Greek name for Sun? (A) Sol (B) Helios (C) Sun"},
  {"role": "assistant", "content": "The best answer is ("}
]
```
模型将从 `"B)"` 继续输出。

### 1.5 Content Block 类型

Content block 的 `type` 字段决定其结构和用途：

| type | 说明 | 方向 |
|---|---|---|
| `text` | 文本内容 | user / assistant |
| `image` | 图片（base64） | user |
| `tool_use` | 模型请求调用工具 | assistant |
| `tool_result` | 工具执行结果 | user |
| `thinking` | 扩展思考过程 | assistant |
| `redacted_thinking` | 被过滤的思考内容 | assistant |
| `server_tool_use` | 服务端工具使用 | assistant |
| `web_search_tool_result` | 网页搜索结果 | user |
| `code_execution_tool_result` | 代码执行结果 | user |

### 1.6 Response 格式

#### 成功响应（200）

```json
{
  "id": "msg_013Zva2CMHLNnXjNJJKqJ2EF",
  "type": "message",
  "role": "assistant",
  "model": "claude-sonnet-4-20250514",
  "content": [
    {
      "type": "text",
      "text": "Hi! My name is Claude."
    }
  ],
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 2095,
    "output_tokens": 503
  }
}
```

#### Response 字段说明

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 消息唯一 ID，格式可能变化 |
| `type` | string | 始终为 `"message"` |
| `role` | string | 始终为 `"assistant"` |
| `model` | string | 处理请求的模型 ID |
| `content` | object[] | 生成的 content block 数组 |
| `stop_reason` | enum \| null | 停止原因（非流式下必为非 null） |
| `stop_sequence` | string \| null | 匹配到的自定义停止序列 |
| `usage` | object | token 用量信息 |

#### usage 子字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `input_tokens` | integer | 输入 token 数 |
| `output_tokens` | integer | 输出 token 数 |
| `cache_creation_input_tokens` | integer \| null | 用于创建 cache 的输入 token |
| `cache_read_input_tokens` | integer \| null | 从 cache 读取的输入 token |
| `cache_creation` | object \| null | 按 TTL 分解的缓存创建 token |
| `server_tool_use` | object \| null | 服务端工具使用次数 |
| `service_tier` | enum \| null | `standard` / `priority` / `batch` |

**总输入 token = `input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`**

### 1.7 Stop Reasons（停止原因）完整列表

| stop_reason | 说明 |
|---|---|
| `end_turn` | 模型自然结束本轮回答 |
| `max_tokens` | 达到 `max_tokens` 或模型上限 |
| `stop_sequence` | 生成了自定义停止序列（`stop_sequences` 中定义） |
| `tool_use` | 模型决定调用一个或多个工具 |
| `pause_turn` | 长时间运行的轮次被暂停，可以原样发回继续 |
| `refusal` | 流式分类器触发了安全策略拦截 |

> 非流式模式下 `stop_reason` 始终非 null。流式模式下在 `message_start` 事件中为 null，后续事件中非 null。

---

## 二、Streaming Messages（SSE 流式）

### 2.1 启用方式

在请求中设置 `"stream": true`，响应将以 Server-Sent Events（SSE）格式逐步下发。

### 2.2 事件流（Event Flow）

流式响应的标准顺序：

```
message_start          → Message 对象，content 为空
 ├─ content_block_start    → 开始一个新的 content block
 ├─ content_block_delta    → 增量更新 content block
 ├─ content_block_delta    → （可能多个 delta）
 ├─ content_block_stop     → content block 结束
 ├─ ...（可能有更多 content block）
message_delta           → 顶层 Message 的增量更新（stop_reason 等）
message_stop            → 消息结束
```

每个 content block 对应最终 Message `content` 数组中的一个 index。

### 2.3 事件类型一览

| SSE event 名 | JSON type | 说明 |
|---|---|---|
| `message_start` | `message_start` | 包含 Message 对象（content 为空数组），stop_reason 为 null |
| `content_block_start` | `content_block_start` | 新 content block 开始，包含 `index` 和 `content_block` |
| `content_block_delta` | `content_block_delta` | content block 增量更新，包含 `index` 和 `delta` |
| `content_block_stop` | `content_block_stop` | content block 完成，包含 `index` |
| `message_delta` | `message_delta` | Message 顶层增量，含 stop_reason、stop_sequence、usage |
| `message_stop` | `message_stop` | 消息流结束 |
| `ping` | `ping` | 心跳事件，保持连接 |
| `error` | `error` | 错误事件 |

### 2.4 Delta 类型详解

#### text_delta

文本增量，更新 `text` content block 的 `text` 字段。

```
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "ello frien"}}
```

#### input_json_delta

工具调用 JSON 增量。Delta 中的 `partial_json` 是**部分 JSON 字符串**，而最终的 `tool_use.input` 是**完整的 JSON 对象**。

> **重要**：需要将所有 partial_json 累积拼接后，在收到 `content_block_stop` 事件时一次性解析为完整 JSON 对象。或使用 Pydantic 等库进行增量 JSON 解析。当前模型一次只发出一个完整的 key-value 属性对。

```
event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": "{\"location\": \"San Fra"}}
```

#### thinking_delta

扩展思考增量，更新 `thinking` content block 的 `thinking` 字段。

```
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Let me solve this step by step:\n\n1. First break down 27 * 453"}}
```

#### signature_delta

思考块签名增量，在 thinking content block 的 `content_block_stop` 事件**之前**发送。用于验证 thinking 块完整性。

```
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}
```

### 2.5 Delta 类型汇总表

| delta type | 对应 content block type | 字段 | 说明 |
|---|---|---|---|
| `text_delta` | `text` | `text` | 文本增量字符串 |
| `input_json_delta` | `tool_use` | `partial_json` | 部分 JSON 字符串，需累积解析 |
| `thinking_delta` | `thinking` | `thinking` | 思考文本增量 |
| `signature_delta` | `thinking` | `signature` | 思考块签名（在 stop 前发送） |

### 2.6 Ping 事件

流中可能穿插 `ping` 事件，用于保持连接活跃：

```
event: ping
data: {"type": "ping"}
```

### 2.7 Error 事件

流中可能偶尔发送错误事件。例如高负载时收到 `overloaded_error`：

```
event: error
data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}
```

### 2.8 完整流式示例

**请求**：
```bash
curl https://api.anthropic.com/v1/messages \
     --header "anthropic-version: 2023-06-01" \
     --header "content-type: application/json" \
     --header "x-api-key: $ANTHROPIC_API_KEY" \
     --data '{
  "model": "claude-3-7-sonnet-20250219",
  "messages": [{"role": "user", "content": "Hello"}],
  "max_tokens": 256,
  "stream": true
}'
```

**响应**：
```
event: message_start
data: {"type": "message_start", "message": {"id": "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", "type": "message", "role": "assistant", "content": [], "model": "claude-3-7-sonnet-20250219", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

event: ping
data: {"type": "ping"}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "!"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence":null}, "usage": {"output_tokens": 15}}

event: message_stop
data: {"type": "message_stop"}
```

### 2.9 流式 + Tool Use 示例

在流式 Tool Use 场景下，响应可能包含 `text` content block（链式思考）和 `tool_use` content block：

```
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\": \"San Francisco, CA\", \"unit\": \"fahrenheit\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}
```

### 2.10 流式 + Extended Thinking 示例

扩展思考流式会在 tool_use 或最终回答之前先流式输出 thinking content block：

```
event: message_start
data: {"type": "message_start", "message": {"id": "msg_01...", "type": "message", "role": "assistant", "content": [], "model": "claude-3-7-sonnet-20250219", "stop_reason": null, "stop_sequence": null}}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Let me solve this step by step:\n\n1. First break down 27 * 453"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: content_block_start
data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "27 * 453 = 12,231"}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 1}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}}

event: message_stop
data: {"type": "message_stop"}
```

---

## 三、Tool Use（工具调用 / 函数调用）

### 3.1 概述

Claude 可以与外部客户端工具交互。通过在请求中提供 `tools` 参数，模型可以在适当的时候返回 `tool_use` content block，表示请求调用某个工具。

**标准流程**：
1. 在请求中定义 tools（名称、描述、input_schema）
2. Claude 返回 `stop_reason: "tool_use"` 和 `tool_use` content block
3. 客户端执行实际工具，获取结果
4. 将结果以 `tool_result` content block 返回给 Claude
5. Claude 根据结果继续生成回复

> 步骤 3-4 是可选的。某些场景下，单次 tool_use 响应可能已经满足需求。

### 3.2 Tool 定义（JSON Schema）

```json
[
  {
    "name": "get_stock_price",
    "description": "Get the current stock price for a given ticker symbol.",
    "input_schema": {
      "type": "object",
      "properties": {
        "ticker": {
          "type": "string",
          "description": "The stock ticker symbol, e.g. AAPL for Apple Inc."
        }
      },
      "required": ["ticker"]
    }
  }
]
```

#### Tool 定义字段详解

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `name` | string | **是** | 工具名称，匹配 `^[a-zA-Z0-9_-]{1,64}$` |
| `description` | string | 否（强烈推荐） | 详细描述工具功能、何时使用、如何行为。**越详细越好，至少 3-4 句** |
| `input_schema` | object | **是** | JSON Schema 定义 tool 的 input 参数结构 |
| `input_schema.type` | enum | **是** | 固定为 `"object"` |
| `input_schema.properties` | object \| null | 否 | 参数定义 |
| `input_schema.required` | string[] \| null | 否 | 必需参数列表 |
| `type` | enum \| null | 否 | 工具类型，默认 `custom` |
| `cache_control` | object \| null | 否 | 缓存控制断点 |

### 3.3 tool_choice 参数

控制模型如何使用已提供的工具：

| tool_choice.type | 说明 |
|---|---|
| `auto` | Claude 自行决定是否调用工具（默认值） |
| `any` | Claude 必须使用提供的工具之一，但不指定具体哪个 |
| `tool` | 强制 Claude 使用某个特定工具 |

`disable_parallel_tool_use` 子字段（boolean，默认 false）：
- 在 `tool_choice` type = `auto` 时，确保最多使用一个工具
- 在 `tool_choice` type = `any`/`tool` 时，确保恰好使用一个工具

### 3.4 tool_use 响应格式

当 Claude 决定调用工具时，返回：

```json
{
  "id": "msg_01...",
  "type": "message",
  "role": "assistant",
  "model": "claude-sonnet-4-20250514",
  "stop_reason": "tool_use",
  "content": [
    {
      "type": "text",
      "text": "I'll look up the current weather for San Francisco."
    },
    {
      "type": "tool_use",
      "id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
      "name": "get_weather",
      "input": {
        "location": "San Francisco, CA"
      }
    }
  ]
}
```

`tool_use` content block 字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | string | 固定为 `"tool_use"` |
| `id` | string | 此工具调用的唯一 ID，后续用于匹配 `tool_result` |
| `name` | string | 被调用的工具名称 |
| `input` | object | 传递给工具的输入参数（符合 input_schema） |

> 注意：`tool_use` block 之前通常有一个 `text` content block（链式思考）。

### 3.5 tool_result 响应格式（重点）

> **关键规则：`tool_result` 的 `content` 字段必须在消息数组中作为数组元素传递。工具结果消息的 content 是 content block 数组，其中每个 `tool_result` 是一个 block。多个工具结果也应放在同一个 user 消息的不同 content block 中。**

当客户端执行完工具后，将结果以 user 消息形式返回给 Claude：

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
      "content": "The current temperature in San Francisco is 15 degrees Celsius."
    }
  ]
}
```

`tool_result` content block 字段：

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `type` | string | **是** | 固定为 `"tool_result"` |
| `tool_use_id` | string | **是** | 对应的 `tool_use` 块的 id |
| `content` | string \| object[] | **是** | 工具执行结果。可为字符串或 nested content block 数组 |
| `is_error` | boolean | 否 | 若工具执行出错，设置为 `true` |

**多个工具结果的示例**：

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90...",
      "content": "65 degrees"
    },
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01B12r34...",
      "content": "sunny"
    }
  ]
}
```

**错误结果示例**：

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
  "content": "ConnectionError: unable to reach weather API",
  "is_error": true
}
```

**错误格式对比**：

```json
// ✅ 正确 — content 为 content block 数组，tool_result 是数组中的元素
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
      "content": "259.75 USD"
    }
  ]
}

// ❌ 错误 — content 直接是单个 tool_result 对象，不是数组
{
  "role": "user",
  "content": {
    "type": "tool_result",
    "tool_use_id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
    "content": "259.75 USD"
  }
}
```

### 3.6 最佳实践

1. **提供极其详细的 tool description** — 这是工具性能最重要的因素。至少 3-4 句，涵盖功能、使用场景、每个参数的含义和影响、任何注意事项或限制。
2. **描述优先于示例** — 先完善描述，再考虑添加示例。
3. **合理选择模型** — 复杂工具用 Claude 3.5 Sonnet 或 Claude 3 Opus；简单工具可用 Claude 3.5 Haiku 或 Claude 3 Haiku（但可能推断缺失参数）。
4. **链式思考（chain of thought）** — Claude 在调用工具前通常会展示推理过程。Claude 3 Opus 默认在 `auto` 模式下会输出；Sonnet/Haiku 可通过 prompt 显式要求。不要依赖 `<thinking>` 等特定 XML 标签格式。
5. **Tool use 不仅限函数调用** — 任何需要模型按特定 schema 输出 JSON 的场景都可以使用 tools。
6. **JSON Output** — 可以使用 tools 机制强制模型输出符合特定 JSON Schema 的结果，即使不需要调用实际的客户端函数。

### 3.7 常见错误类型

| 错误 | 说明 |
|---|---|
| `tool_use` 中使用了未定义的工具名 | 模型调用了 tools 参数中未定义的工具名称 |
| `input` JSON 不符合 schema | 模型生成的输入参数类型不符合 input_schema 定义 |
| 错误处理后的工具重试 | Claude 会根据 `is_error: true` 自动调整并重试 |

### 3.8 计费说明

Tool use 请求的定价与普通 API 请求相同，基于总 token 数。额外消耗来自：

- 请求中 `tools` 参数（工具名、描述、schema）
- 请求和响应中的 `tool_use` content block
- 请求中的 `tool_result` content block
- 自动注入的 tool use system prompt（各模型不同，约 159-530 tokens）

---

## 来源 URL

1. https://docs.anthropic.com/en/api/messages — Messages API（请求/响应格式、Stop Reasons）
2. https://docs.anthropic.com/en/api/messages-streaming — SSE Streaming（事件流、delta 类型）
3. https://docs.anthropic.com/en/docs/build-with-claude/tool-use — Tool Use（tool 定义、tool_use/tool_result 格式）

> 抓取时间：2026-05-24
> 文档版本基于 Anthropic API 当前最新版本。如有更新请访问上述官方 URL。
