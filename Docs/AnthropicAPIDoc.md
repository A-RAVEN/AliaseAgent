# Anthropic API 参考文档

> 本文档由 Anthropic 官方开发者文档（Claude Developer Platform Docs）实际抓取整理，涵盖 Messages API、Streaming（SSE）和 Tool Use（工具调用 / 函数调用）三大板块。
> 抓取时间：2026-09-10
>
> **抓取来源说明**：原 `docs.anthropic.com` 与 `docs.claude.com` 的文档页 URL 现均 301 重定向至 `platform.claude.com/docs/...`。
> 本次抓取时 `platform.claude.com/docs/*` 的 HTML 页面被反爬门禁拦截（返回跨域重定向至 `www.anthropic.com`），
> 因此改用 Anthropic 官方在同一站点发布的**全文文档聚合文件** `https://platform.claude.com/llms-full.txt`（HTTP 200，42,389,957 字节 / 1,358,032 行 / 700 页）。
> 下文所有字段、参数、表格与 JSON 示例均**逐字取自该官方文件的对应页面**，每节标注其官方页面 URL。详见文末「来源 URL」。

---

## 一、Messages API 参考

### 1.1 Endpoint

| 项目 | 值 |
|---|---|
| HTTP 方法 | **post** |
| 路径 | `/v1/messages` |
| 完整 URL | `POST https://api.anthropic.com/v1/messages` |

官方原文描述：

> Send a structured list of input messages with text and/or image content, and the model will generate the next message in the conversation.
>
> The Messages API can be used for either single queries or stateless multi-turn conversations.

RESTful API 根地址（官方原文）：`The Claude API is a RESTful API at https://api.anthropic.com that provides programmatic access to Claude models and Claude Managed Agents.`

请求体积上限（来自 API overview 的 Request size limits 表）：

| Endpoint | Maximum request size |
|---|---|
| Messages, Token Counting | 32 MB |
| Message Batches API | 256 MB |
| Files API | 500 MB |
| Sessions, Agents, Environments | 32 MB |

> If you exceed these limits, you'll receive a 413 `request_too_large` error.

### 1.2 HTTP Headers

官方原文：`Requests to the Claude API include these headers:`

| Header | Value | 必需 |
|---|---|---|
| `Authorization` | `Bearer <token>`，其中 `<token>` 是 API key，或通过 Workload Identity Federation 经 `POST /v1/oauth/token` 取得的短期 access token | **是**（除非已设置 `x-api-key`） |
| `x-api-key` | 来自 Console 的 API key。`Authorization` 的 legacy fallback，仍受支持 | 否 |
| `anthropic-workspace-id` | 请求所属 workspace 的 ID（例如 `wrkspc_01JwQvzr7rXLA5AGx3HKfFUJ`）。见 Select a workspace | 多 workspace API key 时**必需**；其他 API key 可选。Workload Identity Federation token 不使用此项（在 token 交换时选定 workspace） |
| `anthropic-version` | API 版本（例如 `2023-06-01`） | **是** |
| `content-type` | `application/json` | **是** |
| `anthropic-user-profile-id` | 归因该请求的 user profile ID。代表组织以外的第三方操作时使用，需要 `user-profiles` beta header | 否 |
| `anthropic-beta` | 实验性（beta）功能名。用法示例：`anthropic-beta: BETA_FEATURE_NAME`；多个用逗号分隔 | 否 |

关于 `anthropic-beta`（Beta headers 页原文）：

```http
POST /v1/messages
x-api-key: YOUR_API_KEY
anthropic-version: 2023-06-01
anthropic-beta: BETA_FEATURE_NAME
content-type: application/json
```

> Beta headers allow you to access experimental features and new model capabilities before they become part of the standard API.
>
> Each feature's documentation states the exact beta name to send.

官方提示（API overview 原文）：

> If you are using the Client SDKs, the SDK sends the authentication, version, and content-type headers automatically; you pass `anthropic-workspace-id` yourself when your key needs it.

**响应 Headers**（API overview 原文表格，不属于请求参数，附带记录）：

| Header | Description |
|---|---|
| `request-id` | 请求的全局唯一标识，例如 `req_018EeWyXxfu5pfWkrYcMdjWG`。联系支持时请附上 |
| `anthropic-organization-id` | 请求所用 API key / access token 所属组织的 ID |
| `anthropic-workspace-id` | API key / access token 解析到的 workspace 的 `wrkspc_` 前缀 ID；凭据不解析到 workspace 时（例如 Admin API 请求）或请求在鉴权完成前失败时缺失 |

### 1.3 Request Body 参数

以下为官方 API 参考列出的顶层 body 参数（`Create a Message` 页面的 Body Parameters 完整清单）。官方以 `optional` 前缀区分可选参数，未标 `optional` 者为必填。

| 参数 | 类型 | 必需 | 官方说明摘要 |
|---|---|---|---|
| `model` | `Model`（enum 或 string） | **是** | 用于补全 prompt 的模型（取值见下） |
| `messages` | `array of MessageParam` | **是** | 输入消息数组 |
| `max_tokens` | `number` | **是** | 生成停止前的最大 token 数；模型可能在到达该上限前停止；设为 `0` 可在不生成响应的情况下预热 prompt cache |
| `system` | `string` 或 `array of TextBlockParam` | 否 | System prompt |
| `temperature` | `number` | 否 | 注入响应的随机程度。默认 `1.0`，范围 `0.0`–`1.0`。即使为 `0.0` 结果也不会完全确定 |
| `top_k` | `number` | 否 | 仅从每个后续 token 的 top K 候选中采样，用于去除长尾低概率响应。官方建议仅用于高级场景 |
| `top_p` | `number` | 否 | 核采样（nucleus sampling）。按概率降序累积分布，达到 `top_p` 指定概率后截断。官方建议仅用于高级场景 |
| `stop_sequences` | `array of string` | 否 | 自定义停止文本序列 |
| `stream` | `boolean` | 否 | 是否使用 server-sent events 增量流式返回 |
| `tools` | `array of ToolUnion` | 否 | 模型可使用的工具定义 |
| `tool_choice` | `ToolChoice` | 否 | 模型应如何使用所提供的工具 |
| `thinking` | `ThinkingConfigParam` | 否 | 扩展思考（extended thinking）配置 |
| `output_config` | `OutputConfig` | 否 | 模型输出配置（输出格式 / effort） |
| `metadata` | `Metadata` | 否 | 描述请求的元数据对象 |
| `service_tier` | `"auto"` 或 `"standard_only"` | 否 | 是否优先使用 priority 容量 |
| `container` | `MessageCreateParamsContainer` 或 `string` | 否 | 跨请求复用的容器标识符 |
| `cache_control` | `CacheControlEphemeral` 或 `null` | 否 | 顶层 cache control，自动对请求中最后一个可缓存 block 打 cache_control 标记 |
| `inference_geo` | `string` 或 `null` | 否 | 推理处理的地理区域；未指定时使用 workspace 的 `default_inference_geo` |

#### `model` 取值（官方列举）

官方原文：`See models for additional details and options.` 可选值如下（含官方一句话说明）：

| 取值 | 官方说明 |
|---|---|
| `"claude-fable-5-1"` | Frontier intelligence for ambitious tasks across coding, scientific discovery, and enterprise workflows |
| `"claude-mythos-5-1"` | Our most capable model for cybersecurity and biology research, available through trusted access programs |
| `"claude-sonnet-5"` | High-performance model for coding and agents |
| `"claude-fable-5"` | Next generation of intelligence for the hardest knowledge work and coding problems |
| `"claude-mythos-5"` | Most capable model for cybersecurity and biology research |
| `"claude-opus-5"` | Powerful intelligence for long-running agents and coding |
| `"claude-opus-4-8"` | Powerful intelligence for long-running agents and coding |
| `"claude-opus-4-7"` | Powerful intelligence for long-running agents and coding |
| `"claude-mythos-preview"` | New class of intelligence, strongest in coding and cybersecurity |
| `"claude-opus-4-6"` | Powerful intelligence for long-running agents and coding |
| `"claude-sonnet-4-6"` | Best combination of speed and intelligence |
| `"claude-haiku-4-5"` | Fastest model with near-frontier intelligence |
| `"claude-haiku-4-5-20251001"` | Fastest model with near-frontier intelligence |
| `"claude-opus-4-5"` | Powerful intelligence for long-running agents and coding |
| `"claude-opus-4-5-20251101"` | Powerful intelligence for long-running agents and coding |
| `"claude-sonnet-4-5"` | High-performance model for agents and coding |
| `"claude-sonnet-4-5-20250929"` | High-performance model for agents and coding |

此外亦可为任意 `string`。

#### `messages` 参数详解

官方原文：

> Our models are trained to operate on alternating `user` and `assistant` conversational turns. When creating a new `Message`, you specify the prior conversational turns with the `messages` parameter, and the model then generates the next `Message` in the conversation. Consecutive `user` or `assistant` turns in your request will be combined into a single turn.
>
> Each input message must be an object with a `role` and `content`. You can specify a single `user`-role message, or you can include multiple `user` and `assistant` messages.
>
> If the final message uses the `assistant` role, the response content will continue immediately from the content in that message. This can be used to constrain part of the model's response.
>
> There is a limit of 100,000 messages in a single request.

`content` 字段类型：`string or array of ContentBlockParam`。官方原文：

> Each input message `content` may be either a single `string` or an array of content blocks, where each block has a specific `type`. Using a `string` for `content` is shorthand for an array of one content block of type `"text"`. The following input messages are equivalent:

```json
{"role": "user", "content": "Hello, Claude"}
```

```json
{"role": "user", "content": [{"type": "text", "text": "Hello, Claude"}]}
```

官方重要提示（关于 system prompt）：

> Note that if you want to include a system prompt, you can use the top-level `system` parameter — there is no `"system"` role for input messages in the Messages API.

单条 user 消息示例（官方）：

```json
[{"role": "user", "content": "Hello, Claude"}]
```

多轮对话示例（官方）：

```json
[
  {"role": "user", "content": "Hello there."},
  {"role": "assistant", "content": "Hi, I'm Claude. How can I help you?"},
  {"role": "user", "content": "Can you explain LLMs in plain English?"},
]
```

预填 assistant 响应示例（官方）：

```json
[
  {"role": "user", "content": "What's the Greek name for Sun? (A) Sol (B) Helios (C) Sun"},
  {"role": "assistant", "content": "The best answer is ("},
]
```

#### `system` 参数

`system: optional string or array of TextBlockParam`

TextBlockParam 结构（官方）：

- `text: string`
- `type: "text"`
- `cache_control: optional CacheControlEphemeral or null`
- `citations: optional array of TextCitationParam or null`

#### `thinking` 参数

`thinking: optional ThinkingConfigParam` — Configuration for enabling Claude's extended thinking.

> When enabled, responses include `thinking` content blocks showing Claude's thinking process before the final answer. Requires a minimum budget of 1,024 tokens and counts towards your `max_tokens` limit.

官方列出的三种变体：

**1. `ThinkingConfigAdaptive object { type, display }`**

```json
{"type": "adaptive"}
```

- `type: "adaptive"`
- `display: optional "summarized" or "omitted" or null`

**2. `ThinkingConfigEnabled object { budget_tokens, type, display }`**

- `budget_tokens: number` — Determines how many tokens Claude can use for its internal reasoning process. Larger budgets can enable more thorough analysis for complex problems, improving response quality. **Must be ≥1024 and less than `max_tokens`.**
- `type: "enabled"`
- `display: optional "summarized" or "omitted" or null` — 官方原文：`Controls how thinking content appears in the response. When set to summarized, thinking is returned normally. When set to omitted, thinking content is redacted but a signature is returned for multi-turn continuity. Defaults to summarized.`

**3. `ThinkingConfigDisabled object { type }`**

```json
{"type": "disabled"}
```

#### `output_config` 参数

`output_config: optional OutputConfig` — Configuration options for the model's output, such as the output format.

- `effort: optional "low" or "medium" or "high" or 2 more or null` — 全部可能取值：`"low"`、`"medium"`、`"high"`、`"xhigh"`、`"max"`
- `format: optional JSONOutputFormat or null` — A schema to specify Claude's output format in responses. 见 structured outputs
  - `schema: map[unknown]` — The JSON schema of the format
  - `type: "json_schema"`

#### `metadata` 参数

- `user_id: optional string or null`

> An external identifier for the user who is associated with the request.
>
> This should be a uuid, hash value, or other opaque identifier. Anthropic may use this id to help detect abuse. Do not include any identifying information such as name, email address, or phone number.

#### `stop_sequences` 参数

官方原文：

> Custom text sequences that will cause the model to stop generating.
>
> Our models will normally stop when they have naturally completed their turn, which will result in a response `stop_reason` of `"end_turn"`.
>
> If you want the model to stop generating when it encounters custom strings of text, you can use the `stop_sequences` parameter. If the model encounters one of the custom sequences, the response `stop_reason` value will be `"stop_sequence"` and the response `stop_sequence` value will contain the matched stop sequence.

#### `stream` 参数

> Whether to incrementally stream the response using server-sent events.
>
> See streaming for details.

#### `service_tier` 参数

`service_tier: optional "auto" or "standard_only"`

> Determines whether to use priority capacity (if available) or standard capacity for this request.

#### `container` 参数

`container: optional MessageCreateParamsContainer`（`ContainerParams object { id, skills }` 或 `string`）

- `id: optional string or null` — Container id
- `skills: optional array of SkillParams or null` — List of skills to load in the container
  - `skill_id: string`
  - `type: "anthropic" or "custom"`
  - `version: optional string` — Skill version or 'latest' for most recent version

#### `tools` 参数（顶层说明）

`tools: optional array of ToolUnion` — Definitions of tools that the model may use.

官方原文：

> If you include `tools` in your API request, the model may return `tool_use` content blocks that represent the model's use of those tools. You can then run those tools using the tool input generated by the model and then optionally return results back to the model using `tool_result` content blocks.
>
> There are two types of tools: **client tools** and **server tools**. The behavior described below applies to client tools. For server tools, see their individual documentation as each has its own behavior (e.g., the web search tool).
>
> Each tool definition includes:
>
> * `name`: Name of the tool.
> * `description`: Optional, but strongly-recommended description of the tool.
> * `input_schema`: JSON schema for the tool `input` shape that the model will produce in `tool_use` output content blocks.

官方给出的完整 tools → tool_use → tool_result 流程示例：

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

> And then asked the model "What's the S&P 500 at today?", the model might produce `tool_use` content blocks in the response like this:

```json
[
  {
    "type": "tool_use",
    "id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
    "name": "get_stock_price",
    "input": { "ticker": "^GSPC" }
  }
]
```

> You might then run your `get_stock_price` tool with `{"ticker": "^GSPC"}` as an input, and return the following back to the model in a subsequent `user` message:

```json
[
  {
    "type": "tool_result",
    "tool_use_id": "toolu_01D7FLrfh4GYq7yT1ULFeyMV",
    "content": "259.75 USD"
  }
]
```

#### `tool_choice` 参数

`tool_choice: optional ToolChoice`

> How the model should use the provided tools. The model can use a specific tool, any available tool, decide by itself, or not use tools at all.

四种取值的完整定义见本文第三章 3.4 节。

### 1.4 Response 格式

#### 官方完整 Response 示例

官方 `Create a Message` 页面给出的示例请求（cURL）：

```http
curl https://api.anthropic.com/v1/messages \
    -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -H "X-Api-Key: $ANTHROPIC_API_KEY" \
    --max-time 600 \
    -d '{
          "max_tokens": 1024,
          "messages": [
            {
              "content": "Hello, world",
              "role": "user"
            }
          ],
          "model": "claude-opus-5",
          "stream": false,
          "system": [
            {
              "text": "Today'\''s date is 2024-06-01.",
              "type": "text"
            }
          ],
          "temperature": 1,
          "thinking": {
            "type": "adaptive"
          },
          "tools": [
            {
              "input_schema": {
                "type": "object",
                "properties": {
                  "location": "bar",
                  "unit": "bar"
                },
                "required": [
                  "location"
                ]
              },
              "name": "name"
            }
          ],
          "top_k": 5,
          "top_p": 0.7
        }'
```

对应 Response（官方完整 JSON，未删减）：

```json
{
  "id": "msg_013Zva2CMHLNnXjNJJKqJ2EF",
  "container": {
    "id": "container_011CpZohnwH4vuy7gazohgSP",
    "expires_at": "2019-12-27T18:11:19.117Z",
    "skills": [
      {
        "skill_id": "pdf",
        "type": "anthropic",
        "version": "latest"
      }
    ]
  },
  "content": [
    {
      "citations": [
        {
          "cited_text": "The grass is green. The sky is blue.",
          "document_index": 0,
          "document_title": "My Document",
          "end_char_index": 0,
          "file_id": "file_011CNha8iCJcU1wXNR6q4V8w",
          "start_char_index": 0,
          "type": "char_location"
        }
      ],
      "text": "Hi! My name is Claude.",
      "type": "text"
    }
  ],
  "model": "claude-opus-5",
  "role": "assistant",
  "stop_details": {
    "category": "cyber",
    "explanation": "This request was declined because it conflicts with Anthropic's Usage Policy.",
    "type": "refusal"
  },
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "type": "message",
  "usage": {
    "cache_creation": {
      "ephemeral_1h_input_tokens": 0,
      "ephemeral_5m_input_tokens": 0
    },
    "cache_creation_input_tokens": 2051,
    "cache_read_input_tokens": 2051,
    "inference_geo": "global",
    "input_tokens": 2095,
    "output_tokens": 503,
    "output_tokens_details": {
      "thinking_tokens": 0
    },
    "server_tool_use": {
      "web_fetch_requests": 2,
      "web_search_requests": 0
    },
    "service_tier": "standard"
  }
}
```

#### Response 字段说明

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 消息唯一 ID |
| `type` | `"message"` | Object type。官方原文：`For Messages, this is always "message".` |
| `role` | string | 固定为 `assistant` |
| `model` | string | 生成该响应的模型 |
| `content` | array | 内容 block 数组（`text` / `tool_use` / `thinking` 等） |
| `stop_reason` | `StopReason` or null | 停止原因，见 1.5 节 |
| `stop_sequence` | `string or null` | 命中的自定义停止序列（若有）。官方原文：`This value will be a non-null string if one of your custom stop sequences was generated.` |
| `stop_details` | object or null | 停止细节（如 `refusal` 类别与说明） |
| `container` | object | 容器信息（`id` / `expires_at` / `skills`） |
| `usage` | `Usage` | 计费与速率限制用量 |

`usage` 子字段（官方）：

| 子字段 | 类型 | 说明 |
|---|---|---|
| `input_tokens` | number | 使用的输入 token 数 |
| `output_tokens` | number | 使用的输出 token 数 |
| `cache_creation` | object or null | 按 TTL 拆分的缓存 token（`ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens`） |
| `cache_creation_input_tokens` | number or null | 用于创建缓存条目的输入 token 数 |
| `cache_read_input_tokens` | number or null | 从缓存读取的输入 token 数 |
| `inference_geo` | string or null | 本次请求执行推理的地理区域 |
| `output_tokens_details` | object or null | 输出 token 细分（如 `thinking_tokens`） |
| `server_tool_use` | object | 服务端工具使用计数（如 `web_fetch_requests` / `web_search_requests`） |
| `service_tier` | `"standard"` or `"priority"` or `"batch"` or null | 请求使用的服务层级 |

官方关于 usage 计数的原文提示：

> Anthropic's API bills and rate-limits by token counts, as tokens represent the underlying cost to our systems.
>
> Under the hood, the API transforms requests into a format suitable for the model. The model's output then goes through a parsing stage before becoming an API response. As a result, the token counts in `usage` will not match one-to-one with the exact visible content of an API request or response.
>
> For example, `output_tokens` will be non-zero, even for an empty string response from Claude.
>
> Total input tokens in a request is the summation of `input_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens`.

### 1.5 Stop Reasons（停止原因）

`stop_reason: StopReason or null` — The reason that we stopped.

官方原文（`This may be one the following values:`）：

| 取值 | 官方含义 |
|---|---|
| `"end_turn"` | the model reached a natural stopping point（模型到达自然停止点） |
| `"max_tokens"` | we exceeded the requested `max_tokens` or the model's maximum（超过请求的 `max_tokens` 或模型上限） |
| `"stop_sequence"` | one of your provided custom `stop_sequences` was generated（命中你提供的自定义停止序列） |
| `"tool_use"` | the model invoked one or more tools（模型调用了一个或多个工具） |
| `"pause_turn"` | we paused a long-running turn. You may provide the response back as-is in a subsequent request to let the model continue.（长时间运行的回合被暂停，可将该响应原样回传以让模型继续） |
| `"refusal"` | when streaming classifiers intervene to handle potential policy violations（流式分类器介入处理潜在策略违规） |
| `"model_context_window_exceeded"` | we exceeded the model's context window（超出模型上下文窗口） |

官方关于非流式 / 流式差异的原文：

> In non-streaming mode this value is always non-null. In streaming mode, it is null in the `message_start` event and non-null otherwise.

---

## 二、Streaming Messages（SSE 流式）

官方原文：

> When creating a Message, you can set `"stream": true` to incrementally stream the response using server-sent events (SSE).

启用方式（官方基本流式请求示例）：

```bash
curl https://api.anthropic.com/v1/messages \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -d '{
    "model": "claude-opus-5",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 256,
    "stream": true
  }'
```

### 2.1 事件流顺序（Event Flow）

官方原文：

> Each server-sent event includes a named event type and associated JSON data. Each event uses an SSE event name (for example, `event: message_stop`), and includes the matching event `type` in its data.
>
> Each stream uses the following event flow:
>
> 1. `message_start`: contains a `Message` object with empty `content`. ...
> 2. A series of content blocks, each of which has a `content_block_start`, one or more `content_block_delta` events, and a `content_block_stop` event. Each content block has an `index` that corresponds to its index in the final Message `content` array. ...
> 3. One or more `message_delta` events, indicating top-level changes to the final `Message` object.
> 4. A final `message_stop` event.

**重要提示（官方 Warning）**：

> The token counts shown in the `usage` field of the `message_delta` event are *cumulative*.

### 2.2 事件类型一览

| 事件类型（`event:` / `type`） | 说明（依据官方 Event types 章节） |
|---|---|
| `message_start` | 包含一个 `content` 为空的 `Message` 对象。官方原文：`contains a Message object with empty content` |
| `content_block_start` | 一个内容 block 开始。每个 content block 都在最终 Message 的 `content` 数组中有对应的 `index` |
| `content_block_delta` | 内容 block 的增量更新，包含 `index` 与 `delta` |
| `content_block_stop` | 一个内容 block 结束 |
| `message_delta` | 对最终 `Message` 对象的顶层变更（如 `stop_reason`、`stop_sequence`、`usage`） |
| `message_stop` | 流的最终事件 |
| `ping` | 官方原文：`Event streams may also include any number of ping events.` |
| `error` | 官方原文：`The API may occasionally send errors in the event stream. For example, during periods of high usage, you may receive an overloaded_error, which would normally correspond to an HTTP 529 in a non-streaming context` |

官方关于未知事件的提示：

> In accordance with the versioning policy, new event types may be added, and your code should handle unknown event types gracefully.

`error` 事件官方示例：

```sse
event: error
data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}
```

### 2.3 Delta 类型详解

官方原文：`Each content_block_delta event contains a delta of a type that updates the content block at a given index.`

#### 2.3.1 `text_delta`

官方原文：`A text content block delta looks like:`

```sse
event: content_block_delta
data: {"type": "content_block_delta","index": 0,"delta": {"type": "text_delta", "text": "ello frien"}}
```

#### 2.3.2 `input_json_delta`

官方原文：

> The deltas for `tool_use` content blocks correspond to updates for the `input` field of the block. To support maximum granularity, the deltas are *partial JSON strings*, whereas the final `tool_use.input` is always an *object*.
>
> You can accumulate the string deltas and parse the JSON once you receive a `content_block_stop` event, by using a library like Pydantic to do partial JSON parsing, or by using the SDKs, which provide helpers to access parsed incremental values.

```sse
event: content_block_delta
data: {"type": "content_block_delta","index": 1,"delta": {"type": "input_json_delta","partial_json": "{\"location\": \"San Fra"}}}
```

官方重要提示：

> Note: Current models only support emitting one complete key and value property from `input` at a time. As such, when using tools, there may be delays between streaming events while the model is working. Once an `input` key and value are accumulated, they are emitted as multiple `content_block_delta` events with chunked partial JSON so that the format can automatically support finer granularity in future models.

#### 2.3.3 `thinking_delta`

官方原文：

> When using thinking with streaming enabled, you'll receive thinking content through `thinking_delta` events. These deltas correspond to the `thinking` field of the `thinking` content blocks.
>
> For thinking content, a special `signature_delta` event is sent just before the `content_block_stop` event. This signature is used to verify the integrity of the thinking block.
>
> When `display: "omitted"` is set on the thinking configuration, no `thinking_delta` events are sent. The thinking block opens, receives a single `signature_delta`, and closes. With `display: "updates"` (beta), reasoning blocks stream the same way, and only the progress updates that some models write between tool calls stream `thinking_delta` events.

```sse
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "I need to find the GCD of 1071 and 462 using the Euclidean algorithm.\n\n1071 = 2 × 462 + 147"}}
```

#### 2.3.4 `signature_delta`

官方原文：`For thinking content, a special signature_delta event is sent just before the content_block_stop event. This signature is used to verify the integrity of the thinking block.`

```sse
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}
```

#### 2.3.5 Delta 类型汇总

| Delta 类型 | 所属 block | 载荷字段 | 说明 |
|---|---|---|---|
| `text_delta` | `text` | `text` | 文本增量 |
| `input_json_delta` | `tool_use` | `partial_json` | 工具入参的部分 JSON 字符串，需累积后解析；最终 `tool_use.input` 始终是 object |
| `thinking_delta` | `thinking` | `thinking` | 思考内容增量（`display: "omitted"` 时不发送） |
| `signature_delta` | `thinking` | `signature` | 在 `content_block_stop` 之前发送，用于校验 thinking block 完整性 |

### 2.4 完整的 SSE 示例

#### 2.4.1 基础流式响应（官方完整原始输出）

官方原文：`A stream response consists of: 1. A message_start event; 2. Potentially multiple content blocks, each of which contains: A content_block_start event, Potentially multiple content_block_delta events, A content_block_stop event; 3. One or more message_delta events; 4. A message_stop event`

```sse
event: message_start
data: {"type": "message_start", "message": {"id": "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

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

#### 2.4.2 流式 + Tool Use（官方完整原始输出）

请求（官方 cURL，注意 `tool_choice` 为 `{"type": "any"}`、`stream: true`）：

```bash
curl https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-opus-5",
    "max_tokens": 1024,
    "tools": [
      {
        "name": "get_weather",
        "description": "Get the current weather in a given location",
        "input_schema": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "The city and state, e.g. San Francisco, CA"
            }
          },
          "required": ["location"]
        }
      }
    ],
    "tool_choice": {"type": "any"},
    "messages": [
      {
        "role": "user",
        "content": "What is the weather like in San Francisco?"
      }
    ],
    "stream": true
  }'
```

完整响应（官方未经删减的 SSE 原始输出）：

```sse
event: message_start
data: {"type":"message_start","message":{"id":"msg_014p7gG3wDgGV9EUtLvnow3U","type":"message","role":"assistant","model":"claude-opus-5","stop_sequence":null,"usage":{"input_tokens":472,"output_tokens":2},"content":[],"stop_reason":null}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: ping
data: {"type": "ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":","}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" let"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'s"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" check"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" the"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" weather"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" for"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" San"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Francisco"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":","}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" CA"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":":"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"San"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Francisc"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o,"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" CA\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}

event: message_stop
data: {"type":"message_stop"}
```

#### 2.4.3 流式 + Thinking 请求（官方示例）

官方原文：`This request enables thinking with streaming. The display: "summarized" setting streams a condensed summary of Claude's reasoning rather than the full chain of thought.`

```bash
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-opus-5",
    "max_tokens": 20000,
    "stream": true,
    "thinking": {
      "type": "adaptive",
      "display": "summarized"
    },
    "messages": [
      {
        "role": "user",
        "content": "What is the greatest common divisor of 1071 and 462?"
      }
    ]
  }'
```

#### 2.4.4 SDK 侧获取完整 Message

官方原文：

> The `.stream()` call keeps the HTTP connection alive with server-sent events, then `.get_final_message()` (Python) or `.finalMessage()` (TypeScript) accumulates all events and returns the complete `Message` object.

> If you don't need to process text as it arrives, the SDKs provide a way to use streaming internally while returning the complete `Message` object, identical to what `.create()` returns. This is especially useful for requests with large `max_tokens` values, where the SDKs require streaming to avoid HTTP timeouts.

---

## 三、Tool Use（工具调用 / 函数调用）

### 3.1 概述

官方原文（Tool use with Claude 页）：

> Tool use (also called function calling) lets Claude call functions that you define or that Anthropic provides. Claude determines when to call a tool based on the user's request and the tool's description. It then returns a structured call that your application executes (client tools) or that Anthropic executes (server tools).

官方关于「工具在哪里执行」的三分类：

| 类别 | 执行方 | 官方说明摘要 |
|---|---|---|
| User-defined tools（client-executed） | 你的应用 | 你写 schema、你执行代码、你返回结果。绝大多数工具调用流量属于此类 |
| Anthropic-schema tools（client-executed） | 你的应用 | Anthropic 发布 schema，你的应用负责执行。包含 `memory`、`bash`、`text_editor`、`computer`、`browser` |
| Server-executed tools | Anthropic 服务器 | 包含 `web_search`、`web_fetch`、`code_execution`、`tool_search`。官方原文：`You never construct a tool_result block for these tools.` |

官方最小示例（使用 server tool web_search）：

```bash
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-opus-5",
    "max_tokens": 1024,
    "tools": [{"type": "web_search_20260209", "name": "web_search"}],
    "messages": [{"role": "user", "content": "What'\''s the latest on the Mars rover?"}]
  }'
```

### 3.2 Tool 定义（JSON Schema）

官方原文（Define tools 页）：

> Client tools are specified in the `tools` top-level parameter of the API request. ... A user-defined tool definition includes:

| Parameter | 官方说明 |
|---|---|
| `name` | The name of the tool. **Must match the regex `^[a-zA-Z0-9_-]{1,128}$`.** |
| `description` | A detailed plaintext description of what the tool does, when it should be used, and how it behaves. |
| `input_schema` | A JSON Schema object defining the expected parameters for the tool. |
| `input_examples` | (Optional) An array of example input objects to help Claude understand how to use the tool. |

官方补充：

> For the full set of optional properties available on any single tool definition, including `cache_control`, `strict`, `defer_loading`, and `allowed_callers`, see the Tool reference. A client toolset entry accepts `cache_control` and `allowed_callers` on the entry and sets `defer_loading` per member.

官方「Example simple tool definition」（完整 JSON）：

```json
{
  "name": "get_weather",
  "description": "Get the current weather in a given location",
  "input_schema": {
    "type": "object",
    "properties": {
      "location": {
        "type": "string",
        "description": "The city and state, e.g. San Francisco, CA"
      },
      "unit": {
        "type": "string",
        "enum": ["celsius", "fahrenheit"],
        "description": "The unit of temperature, either 'celsius' or 'fahrenheit'"
      }
    },
    "required": ["location"]
  }
}
```

官方解释：`This tool, named get_weather, expects an input object with a required location string and an optional unit string that must be either "celsius" or "fahrenheit".`

`strict` 字段（来自 API 参考 tools 参数定义）：

- `strict: optional boolean` — 官方原文：`When true, guarantees schema validation on tool names and inputs`

`input_examples` 的官方完整示例（含 cURL）：

```bash
curl -sS https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d @- <<'EOF'
{
  "model": "claude-opus-5",
  "max_tokens": 1024,
  "tools": [
    {
      "name": "get_weather",
      "description": "Get the current weather in a given location",
      "input_schema": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The city and state, e.g. San Francisco, CA"
          },
          "unit": {
            "type": "string",
            "enum": ["celsius", "fahrenheit"],
            "description": "The unit of temperature"
          }
        },
        "required": ["location"]
      },
      "input_examples": [
        {"location": "San Francisco, CA", "unit": "fahrenheit"},
        {"location": "Tokyo, Japan", "unit": "celsius"},
        {"location": "New York, NY"}
      ]
    }
  ],
  "messages": [
    {"role": "user", "content": "What's the weather like in San Francisco?"}
  ]
}
EOF
```

`input_examples` 的官方 Requirements and limitations：

> * **Schema validation** - Each example must be valid according to the tool's `input_schema`. Invalid examples return a 400 error
> * **Not supported for server-side tools or client toolsets** - Input examples work on user-defined and Anthropic-schema client tools other than the computer use and browser use toolsets, but not on server tools such as web search or code execution
> * **Token cost** - Examples add to prompt tokens: ~20–50 tokens for simple examples, ~100–200 tokens for complex nested objects

### 3.3 tool_use 响应 content block 格式

官方原文（Handle tool calls 页）：

> The response will have a `stop_reason` of `tool_use` and one or more `tool_use` content blocks that include:
>
> * `id`: A unique identifier for this particular tool use block. This will be used to match up the tool results later.
> * `name`: The name of the tool being used.
> * `input`: An object containing the input being passed to the tool, conforming to the tool's `input_schema`.

官方「Example API response with a `tool_use` content block」：

```json
{
  "id": "msg_01Aq9w938a90dw8q",
  "model": "claude-opus-5",
  "stop_reason": "tool_use",
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "I'll check the current weather in San Francisco for you."
    },
    {
      "type": "tool_use",
      "id": "toolu_01A09q90qw90lq917835lq9",
      "name": "get_weather",
      "input": { "location": "San Francisco, CA", "unit": "celsius" }
    }
  ]
}
```

官方关于「模型响应中先有自然语言文本」的原文：

> When using tools, Claude often comments on what it's doing or responds naturally to the user before calling tools.

对应的官方 JSON 示例：

```json
{
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "I'll help you check the current weather and time in San Francisco."
    },
    {
      "type": "tool_use",
      "id": "toolu_01A09q90qw90lq917835lq9",
      "name": "get_weather",
      "input": { "location": "San Francisco, CA" }
    }
  ]
}
```

#### `tool_use` 的流式增量

工具调用的部分 JSON 通过 `input_json_delta` 的 `partial_json` 字段增量下发（完整示例见 2.4.2）：

```sse
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
```

### 3.4 tool_result 格式（重点）

#### ⚠️ 重点标注一：承载 `tool_result` 的 user 消息 `content` 必须是数组

官方原文（Handle tool calls 页，Important formatting requirements）：

> * Tool result blocks must immediately follow their corresponding tool use blocks in the message history. You cannot include any messages between the assistant's tool use message and the user's tool result message.
> * In the user message containing tool results, the tool_result blocks must come FIRST in the content array. Any text must come AFTER all tool results.

官方给出的**会触发 400 错误**的写法（`content` 是 `tool_result` 之前夹了 text）：

```json
{
  "role": "user",
  "content": [
    { "type": "text", "text": "Here are the results:" }, // ❌ Text before tool_result
    { "type": "tool_result", "tool_use_id": "toolu_01" /* ... */ }
  ]
}
```

官方给出的**正确**写法（仅调用 client tools 时）：

```json
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "toolu_01" /* ... */ },
    { "type": "text", "text": "What should I do next?" } // ✅ Text after tool_result
  ]
}
```

官方还给出该错误的排查提示：

> If you receive an error like "tool_use ids were found without tool_result blocks immediately after", check that your tool results are formatted correctly.

因此：**外层 user 消息的 `content` 必须是内容 block 数组**，其中每个 `tool_result` 是数组中的一个元素；多个工具结果放在同一个 user 消息的不同 content block 中。

#### ⚠️ 重点标注二（与任务书表述的差异，务必注意）

任务书要求标注「`tool_result` 的 `content` 必须为数组」。经本次实际抓取核对，**当前官方文档并非如此规定**，必须如实记录如下：

1. **外层 user 消息的 `content` 必须是数组** —— 这一条成立（见上文重点标注一）。
2. **`tool_result` block 自身的 `content` 字段是「可选」的，且既可以是字符串、也可以是内容 block 数组。**

官方 API 参考（Create a Message）中 `ToolResultBlockParam` 的定义原文：

```
- `ToolResultBlockParam object { tool_use_id, type, cache_control, 3 more }`
  - `tool_use_id: string`
  - `type: "tool_result"`
  - `cache_control: optional CacheControlEphemeral or null`
  - `content: optional string or array of TextBlockParam or ImageBlockParam or SearchResultBlockParam or 3 more`
    - `string`
    - `array of TextBlockParam or ImageBlockParam or SearchResultBlockParam or 3 more`
```

官方 Handle tool calls 页对 `content` 的原文说明：

> `content` (optional): The result of the tool, as a string (for example, `"content": "15 degrees"`), a list of nested content blocks (for example, `"content": [{"type": "text", "text": "15 degrees"}]`), or a list of document blocks (for example, `"content": [{"type": "document", "source": {"type": "text", "media_type": "text/plain", "data": "15 degrees"}}]`). These content blocks can use the `text`, `image`, `document`, or `search_result` types.

官方给出的四种 `tool_result` 形态原文示例（其中第一种即为**字符串** `content`，第三种**完全没有** `content` 字段）：

**（1）成功的工具结果（`content` 为字符串）**

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": "15 degrees"
    }
  ]
}
```

**（2）带图片的工具结果（`content` 为内容 block 数组）**

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": [
        { "type": "text", "text": "15 degrees" },
        {
          "type": "image",
          "source": {
            "type": "base64",
            "media_type": "image/jpeg",
            "data": "/9j/4AAQSkZJRg..."
          }
        }
      ]
    }
  ]
}
```

**（3）空的工具结果（省略 `content`）**

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9"
    }
  ]
}
```

**（4）带 document 的工具结果**

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": [
        { "type": "text", "text": "The weather is" },
        {
          "type": "document",
          "source": {
            "type": "text",
            "media_type": "text/plain",
            "data": "15 degrees"
          }
        }
      ]
    }
  ]
}
```

**结论**：若实现中强制要求 `tool_result.content` 为数组（例如为兼容某些第三方 Anthropic 兼容端点），那是**实现方自加的更严格约束**，不能标注为「Anthropic 官方要求」。官方要求的是**外层消息 `content` 为数组**。

#### `tool_result` block 字段表

| 字段 | 类型 | 必需 | 官方说明 |
|---|---|---|---|
| `type` | `"tool_result"` | **是** | 固定值 |
| `tool_use_id` | string | **是** | The `id` of the tool use request this is a result for |
| `content` | `string` 或内容 block 数组 | 否（`optional`） | 工具结果。可为字符串、嵌套内容 block 数组或 document block 数组；可用的 block 类型为 `text`、`image`、`document`、`search_result` |
| `cache_control` | `CacheControlEphemeral` or null | 否 | 在该内容 block 建立 cache control 断点 |

#### 客户端工具调用的处理流程（官方）

> When you receive a tool use response for a client tool, you should:
>
> 1. Extract the `name`, `id`, and `input` from the `tool_use` block.
> 2. Run the actual tool in your codebase corresponding to that tool name, passing in the tool `input`.
> 3. Continue the conversation by sending a new message with the `role` of `user`, and a `content` block containing the `tool_result` type and the following information: ...

### 3.5 错误处理 `is_error`

`is_error` (optional)：Set to `true` if the tool execution resulted in an error.

**工具执行错误（官方示例）**：

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": "ConnectionError: the weather service API is not available (HTTP 500)",
      "is_error": true
    }
  ]
}
```

官方原文：`Claude will then incorporate this error into its response to the user.` 并建议：

> Write instructive error messages. Instead of generic errors like `"failed"`, include what went wrong and what Claude should try next (for example, `"Rate limit exceeded. Retry after 60 seconds."`). This gives Claude the context it needs to recover or adapt without guessing.

**无效工具名 / 缺参数（官方示例）**：

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": "Error: Missing required 'location' parameter",
      "is_error": true
    }
  ]
}
```

官方原文：`If a tool request is invalid or missing parameters, Claude will retry 2-3 times with corrections before apologizing to the user.`

**Server tool 错误**：官方原文：`When server tools encounter errors (for example, network issues with Web Search), Claude will transparently handle these errors and attempt to provide an alternative response or explanation to the user. Unlike client tools, you do not need to handle is_error results for server tools.` web search 可能的错误码：`too_many_requests`、`invalid_input`、`max_uses_exceeded`、`query_too_long`、`unavailable`。

### 3.6 tool_choice 选项

官方原文（Define tools 页）：

> When working with the `tool_choice` parameter, there are four possible options:
>
> * `auto` allows Claude to decide whether to call any provided tools or not. This is the default value when `tools` are provided.
> * `any` tells Claude that it must use one of the provided tools, but doesn't force a particular tool.
> * `tool` forces Claude to always use a particular tool.
> * `none` prevents Claude from using any tools. This is the default value when no `tools` are provided.

官方 API 参考中的四种类型定义：

| `tool_choice.type` | 完整结构 | 官方说明 |
|---|---|---|
| `"auto"` | `ToolChoiceAuto object { type, disable_parallel_tool_use }` | The model will automatically decide whether to use tools. |
| `"any"` | `ToolChoiceAny object { type, disable_parallel_tool_use }` | The model will use any available tools. |
| `"tool"` | `ToolChoiceTool object { name, type, disable_parallel_tool_use }` | The model will use the specified tool with `tool_choice.name`. |
| `"none"` | `ToolChoiceNone object { type }` | The model will not be allowed to use tools. |

`disable_parallel_tool_use` 官方说明（三种类型共有，`none` 无此字段）：

- 在 `auto` 下：`Defaults to false. If set to true, the model will output at most one tool use.`
- 在 `any` / `tool` 下：`Defaults to false. If set to true, the model will output exactly one tool use.`

`tool_choice.name`：`The name of the tool to use.`（仅 `type: "tool"` 时使用）

**强制使用特定工具的官方请求示例（cURL）**：

```bash
curl -sS https://api.anthropic.com/v1/messages \
  -H "content-type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d @- <<'EOF'
{
  "model": "claude-opus-5",
  "max_tokens": 1024,
  "tools": [
    {
      "name": "get_weather",
      "description": "Get the current weather in a given location",
      "input_schema": {
        "type": "object",
        "properties": {
          "location": {
            "type": "string",
            "description": "The city and state, e.g. San Francisco, CA"
          }
        },
        "required": ["location"]
      }
    }
  ],
  "tool_choice": {"type": "tool", "name": "get_weather"},
  "messages": [
    {"role": "user", "content": "What's the weather like in San Francisco?"}
  ]
}
EOF
```

**官方重要行为提示**：

> Note that when you have `tool_choice` as `any` or `tool`, the API prefills the assistant message to force a tool to be used. This means that the models will not emit a natural language response or explanation before `tool_use` content blocks, even if explicitly asked to do so.

> Testing has shown that this should not reduce performance. If you would like the model to provide natural language context or explanations while still requesting that the model use a specific tool, you can use `{"type": "auto"}` for `tool_choice` (the default) and add explicit instructions in a `user` message.

**强制工具使用的模型/设置限制（官方表格）**：

| Model or setting | Restriction | What to use instead |
|---|---|---|
| Manual extended thinking (`thinking: {type: "enabled"}`) | `any` and `tool` are not supported and result in an error | `auto` or `none`. Adaptive thinking, including on models where thinking is on by default such as Claude Opus 5, supports forced tool use |
| Claude Fable 5.1 and Claude Mythos 5.1 | `any` and `tool` return a 400 error | `auto` with strict tool use to guarantee schema-valid tool inputs, or structured outputs when you need a response in a fixed JSON shape. Prompting still influences which tool `auto` picks. `none` is also supported |

**官方 Tip（保证工具一定被调用且入参合法）**：

> On models that support forced tool use, combine `tool_choice: {"type": "any"}` with strict tool use to guarantee both that one of your tools is called and that the tool inputs strictly follow your schema. Set `strict: true` on your tool definitions to enable schema validation.

**Prompt caching 注意（官方 Note）**：

> When using prompt caching, changes to the `tool_choice` parameter will invalidate cached message blocks. Tool definitions and system prompts remain cached, but message content must be reprocessed.

### 3.7 多轮工具调用流程

官方原文（How tool use works 页，「The agentic loop (client tools)」）：

> Client-executed tools (both user-defined and Anthropic-schema) require your application to drive a loop. The model can't run your code, so every tool call is a round trip: the model asks, you execute, you report back, the model continues.
>
> The canonical shape is a `while` loop keyed on `stop_reason`:
>
> 1. Send a request with your `tools` array and the user message.
> 2. Claude responds with `stop_reason: "tool_use"` and one or more `tool_use` blocks.
> 3. Execute each tool. Format the outputs as `tool_result` blocks.
> 4. Send a new request containing the original messages, the assistant's response, and a user message with the `tool_result` blocks.
> 5. Repeat from step 2 while `stop_reason` is `"tool_use"`.

官方关于循环退出条件：

> In practice this reads as: while `stop_reason == "tool_use"`, execute the tools and continue the conversation. The loop exits on any other stop reason (`"end_turn"`, `"max_tokens"`, `"stop_sequence"`, or `"refusal"`), which means Claude has either produced a final answer or stopped for another reason that your application should handle.

**多轮消息数组的构造形态（依据官方示例推导的字段排列，非新增字段）**：第一轮 assistant 返回的 `tool_use` block 必须原样放回 `messages`，紧随其后是携带 `tool_result` 的 user 消息：

```json
[
  {"role": "user", "content": "What's the weather like in San Francisco?"},
  {
    "role": "assistant",
    "content": [
      {"type": "text", "text": "I'll check the current weather in San Francisco for you."},
      {
        "type": "tool_use",
        "id": "toolu_01A09q90qw90lq917835lq9",
        "name": "get_weather",
        "input": { "location": "San Francisco, CA", "unit": "celsius" }
      }
    ]
  },
  {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
        "content": "15 degrees"
      }
    ]
  }
]
```

> 说明：上面的**三段式组合**是依据官方「tool_use 响应示例」＋「tool_result 示例」＋「agentic loop 步骤 4」拼接而成的结构示意，字段本身均逐字取自官方示例；官方未在同一处给出这一完整的三段拼接 JSON。

官方关于 `pause_turn` 与 server tool 的补充：

> This internal loop has an iteration limit. If the model is still iterating when it hits the cap, the response comes back with `stop_reason: "pause_turn"` instead of `"end_turn"`. A paused turn means the work isn't finished; re-send the conversation (including the paused response) to let the model continue where it left off.

> The loop also hands control back to you before a server tool runs if Claude calls that server tool and a client tool in the same group of parallel tool calls. The response then comes back with `stop_reason: "tool_use"` and a `server_tool_use` block that has no result block yet; the API runs it after you return the client tool results.

### 3.8 官方 Tool 定义最佳实践

官方原文（Define tools 页）：

> * **Provide extremely detailed descriptions.** This is by far the most important factor in tool performance. Your description should explain every detail about the tool, including:
>   * What the tool does
>   * When it should be used (and when it shouldn't)
>   * What each parameter means and how it affects the tool's behavior
>   * Any important caveats or limitations... Aim for at least 3–4 sentences for each tool description, more if the tool is complex.
> * **Prioritize descriptions, but consider using `input_examples` for complex tools.**
> * **Consolidate related operations into fewer tools.** Rather than creating a separate tool for every action (`create_pr`, `review_pr`, `merge_pr`), group them into a single tool with an `action` parameter.
> * **Use meaningful namespacing in tool names.** When your tools span multiple services or resources, prefix names with the service (for example, `github_list_prs`, `slack_send_message`).
> * **Design tool responses to return only high-signal information.** Return semantic, stable identifiers (for example, slugs or UUIDs) rather than opaque internal references...

官方「good tool description」示例：

```json
{
  "name": "get_stock_price",
  "description": "Retrieves the current stock price for a given ticker symbol. The ticker symbol must be a valid symbol for a publicly traded company on a major US stock exchange like NYSE or NASDAQ. The tool will return the latest trade price in USD. It should be used when the user asks about the current or most recent price of a specific stock. It will not provide any other information about the stock or company.",
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
```

官方「poor tool description」示例：

```json
{
  "name": "get_stock_price",
  "description": "Gets the stock price for a ticker.",
  "input_schema": {
    "type": "object",
    "properties": {
      "ticker": {
        "type": "string"
      }
    },
    "required": ["ticker"]
  }
}
```

### 3.9 Tool use 系统提示词（官方公开）

官方原文：`When you call the Claude API with the tools parameter, the API constructs a special system prompt from the tool definitions, tool configuration, and any user-specified system prompt.`

```text
In this environment you have access to a set of tools you can use to answer the user's question.
{{ FORMATTING INSTRUCTIONS }}
String and scalar parameters should be specified as is, while lists and objects should use JSON format. Note that spaces for string values are not stripped. The output is not expected to be valid XML and is parsed with regular expressions.
Here are the functions available in JSONSchema format:
{{ TOOL DEFINITIONS IN JSON SCHEMA }}
{{ USER SYSTEM PROMPT }}
{{ TOOL CONFIGURATION }}
```

---

## 来源 URL

### 本次实际抓取结果

**根 URL（任务指定的 3 个原始 URL）——全部重定向，未取得内容：**

| # | 任务指定 URL | 抓取结果 |
|---|---|---|
| 1 | `https://docs.anthropic.com/en/api/messages` | **未取得内容**。跨域重定向 → `https://platform.claude.com/en/api/messages`；跟随该地址后再次跨域重定向 → `https://www.anthropic.com`（反爬门禁）。`https://www.anthropic.com/en/api/messages` 直接访问返回 **HTTP 404**（`Not Found \ Anthropic`）。注：工具仅报告「cross-origin redirect」，未回报具体 HTTP 状态码，故此处不臆测 301/302/308。 |
| 2 | `https://docs.anthropic.com/en/api/messages-streaming` | **未取得内容**。重定向链同上 → `platform.claude.com` → `www.anthropic.com`。 |
| 3 | `https://docs.anthropic.com/en/docs/build-with-claude/tool-use` | **未取得内容**。重定向链同上；另 `https://docs.claude.com/en/docs/build-with-claude/tool-use` 亦重定向 → `platform.claude.com` → `www.anthropic.com`。 |

**补充尝试（均为官方域名，全部失败）：**

| URL | 结果 |
|---|---|
| `https://platform.claude.com/en/api/messages` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://platform.claude.com/docs/en/api/messages` / `.md` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://platform.claude.com/docs/en/api/messages-streaming` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://platform.claude.com/docs/en/build-with-claude/streaming.md` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview.md` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://platform.claude.com/docs/zh-CN/api/messages` | 跨域重定向 → `www.anthropic.com`（失败） |
| `https://docs.claude.com/en/api/messages` / `.md` / `en/api/streaming` | 重定向 → `platform.claude.com` → `www.anthropic.com`（失败） |
| `https://web.archive.org/web/2025/https://docs.anthropic.com/en/api/messages` | **抓取失败**：`TypeError: fetch failed`（网络不可达） |
| `https://raw.githubusercontent.com/anthropics/anthropic-sdk-python/main/README.md` | **抓取失败**：`URL hostname "raw.githubusercontent.com" resolves to a non-public IP address`（被工具策略拒绝） |

**最终成功抓取的官方来源（HTTP 200）：**

| # | URL | 结果 | 用途 |
|---|---|---|---|
| 1 | `https://platform.claude.com/llms-full.txt` | **成功**（HTTP 200，42,389,957 字节 / 1,358,032 行 / 700 个页面区块） | 官方全文文档聚合文件，下文所有内容均逐字取自其中 |
| 2 | `https://platform.claude.com/llms.txt` | 成功（HTTP 200） | 官方文档页面索引，用于定位各页面的官方 URL |
| 3 | `https://www.anthropic.com/` | 成功（HTTP 200） | 仅用于确认 `www.anthropic.com` 可达、门禁为 `platform.claude.com/docs/*` 专属 |

**从 `llms-full.txt` 中实际提取并逐字引用的官方页面（均标注在文件内的 `url:` 字段）：**

| # | 官方页面 URL | 文件内行号区间 | 覆盖章节 |
|---|---|---|---|
| 1 | `https://platform.claude.com/docs/en/api/messages/create` | 876676–880789 | 1.1 Endpoint、1.2（`anthropic-user-profile-id`）、1.3 全部 request body 参数、1.4 Response 示例与字段、1.5 stop_reason |
| 2 | `https://platform.claude.com/docs/en/api/overview` | 162329 起 | 1.1 根地址与请求体积上限、1.2 Headers 表与响应 Headers |
| 3 | `https://platform.claude.com/docs/en/api/beta-headers` | 提取为 `api_beta-headers.txt` | 1.2 `anthropic-beta` header |
| 4 | `https://platform.claude.com/docs/en/build-with-claude/streaming` | 16954–18486 | 第二章全部（事件流、事件类型、delta 类型、完整 SSE 示例） |
| 5 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview` | 26896–27802 | 3.1 概述、3.1 最小示例 |
| 6 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools` | 36995–37908 | 3.2 tool 定义、3.6 tool_choice、3.8 最佳实践、3.9 系统提示词 |
| 7 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls` | 37909–38191 | 3.3 tool_use 响应、3.4 tool_result 格式、3.5 is_error |
| 8 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/how-tool-use-works` | 38192–38293 | 3.1 工具执行位置、3.7 多轮工具调用流程 |
| 9 | `https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons` | 3546–7223 | 辅助核对 stop_reason（正文取自 #1） |
| 10 | `https://platform.claude.com/docs/en/build-with-claude/working-with-messages` | 7224–8287 | 辅助核对 messages 参数（正文取自 #1） |

> **诚实披露**：任务书指定的 3 个 `docs.anthropic.com` URL **本次全部未能取得页面内容**（被重定向至 `www.anthropic.com` 反爬门禁）。
> 本文档内容**并非**来自这 3 个 URL，而是来自 Anthropic 官方在同一站点（`platform.claude.com`）发布的全文文档文件 `llms-full.txt`，
> 其中包含了与上述 3 个页面**等价的新地址**（`/docs/en/api/messages/create`、`/docs/en/build-with-claude/streaming`、`/docs/en/agents-and-tools/tool-use/*`）。
> 所有字段、表格与 JSON 示例均逐字取自该官方文件，无任何凭记忆补写的内容；两处与任务书表述不一致之处已在 3.4 节明确标注。

> 抓取时间：2026-09-10
