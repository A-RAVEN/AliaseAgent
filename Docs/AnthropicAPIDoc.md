# Anthropic API 参考文档

> **抓取时间**：2026-09-20 14:54（UTC+8）／ 2026-09-20 06:54 UTC
> **数据来源**：`https://platform.claude.com/llms-full.txt`（官方全文文档聚合文件）
> **文件元信息**：35,216,650 字节（33.59 MB）／ 1,179,764 行 ／ 629 个页面区块
> **文件自述生成时间**：`Last generated: 2026-09-18T19:18:53.788Z`，`Total pages included: 629`
> **诚实披露**：`docs.anthropic.com` 与 `platform.claude.com/docs/**` 的**页面路由在本机所在区域被封锁**，
> 无法取得 HTML 页面内容（详见文末「来源 URL」）。本文件所有字段、表格与 JSON 示例**均逐字取自上述官方全文文件的对应区块**，
> 每个区块在文件内自带 `url:` 字段可溯源，**无任何凭记忆补写的内容**。

---

## 一、Messages API 参考

### 1.1 Endpoint

```http
POST https://api.anthropic.com/v1/messages
```

官方描述原文：

> Send a structured list of input messages with text and/or image content, and the model will generate the next message in the conversation.
>
> The Messages API can be used for either single queries or stateless multi-turn conversations.

API 根地址与相关端点（取自 `/docs/en/api/overview`）：

| API | Endpoint |
|---|---|
| Messages API | `POST /v1/messages` |
| Message Batches API | `POST /v1/messages/batches` |
| Token Counting API | `POST /v1/messages/count_tokens` |
| Models API | `GET /v1/models` |
| Files API | `POST /v1/files`、`GET /v1/files` |
| Skills API | `POST /v1/skills`、`GET /v1/skills` |

**请求体积上限**（官方表格）：

| Endpoint | Maximum request size |
|---|---|
| Messages, Token Counting | 32 MB |
| Message Batches API | 256 MB |
| Files API | 500 MB |
| Sessions, Agents, Environments | 32 MB |

> If you exceed these limits, you'll receive a 413 `request_too_large` error.

---

### 1.2 HTTP Headers

#### 1.2.1 请求 Headers（官方 `Authentication` 表）

| Header | Value | Required |
|---|---|---|
| `Authorization` | `Bearer <token>`，`<token>` 为 API key 或经 Workload Identity Federation 从 `POST /v1/oauth/token` 取得的短期 access token | Yes, unless `x-api-key` is set |
| `x-api-key` | Your API key from Console. Legacy fallback for `Authorization`, still supported | No |
| `anthropic-workspace-id` | 请求所属 workspace 的 ID（形如 `wrkspc_01JwQvzr7rXLA5AGx3HKfFUJ`） | Required with a multi-workspace API key. Optional for other API keys. Not used with Workload Identity Federation tokens |
| `anthropic-version` | API 版本（例如 `2023-06-01`） | Yes |
| `content-type` | `application/json` | Yes |

#### 1.2.2 `POST /v1/messages` 页面另列的 Headers

（取自 `/docs/en/api/messages/create` 的 `## Headers` 段）

- `"anthropic-user-profile-id": optional string`
  - The user profile ID to attribute this request to. Use when acting on behalf of a party other than your organization. Requires the `user-profiles` beta header.
- `"anthropic-workspace-id": optional string`

#### 1.2.3 Beta Headers（`anthropic-beta`）

官方原文：

> Beta headers allow you to access experimental features and new model capabilities before they become part of the standard API.

```http
POST /v1/messages
x-api-key: YOUR_API_KEY
anthropic-version: 2023-06-01
anthropic-beta: BETA_FEATURE_NAME
content-type: application/json
```

一次使用多个 beta 特性（两种等价写法）：

```http
anthropic-beta: feature1,feature2,feature3
```

```http
anthropic-beta: feature1
anthropic-beta: feature2
anthropic-beta: feature3
```

> You can also send the `anthropic-beta` header more than once in the same request. The Claude API reads every `anthropic-beta` header.

命名约定：

> Beta feature names typically follow the pattern `feature-name-YYYY-MM-DD`, where the date indicates when the beta was released. Always use the exact beta feature name as documented.

**端点专属 beta header**（官方表格）：

| Endpoints | Beta header |
|---|---|
| `/v1/agents`, `/v1/sessions`, `/v1/environments` | `managed-agents-2026-04-01` |
| `/v1/tunnels` | `mcp-tunnels-2026-06-22` |
| `/v1/memory_stores` and sub-resources | `agent-memory-2026-07-22` |

无效 beta 名会返回 `400`：

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "Unexpected value(s) `invalid-beta-name` for the `anthropic-beta` header. Please consult our documentation at platform.claude.com/docs or try again without the header."
  },
  "request_id": "req_011CcnGfC9fELffo2EALu4Wd"
}
```

#### 1.2.4 响应 Headers（官方表格）

| Header | Description |
|---|---|
| `request-id` | A globally unique identifier for the request, such as `req_018EeWyXxfu5pfWkrYcMdjWG`. Include it when you contact support about a specific request. |
| `anthropic-organization-id` | The ID of the organization that the API key or access token used in the request belongs to. |
| `anthropic-workspace-id` | The `wrkspc_`-prefixed ID of the workspace that the API key or access token resolved to, such as `wrkspc_01JwQvzr7rXLA5AGx3HKfFUJ`, including when that is your organization's Default Workspace. Absent when the credential doesn't resolve to a workspace (for example, on Admin API requests) or the request fails before authentication completes. |

---

### 1.3 Request Body 参数

#### 1.3.1 顶层参数总表

以下为官方 `## Body parameters` 段的**全部顶层参数**，类型逐字照录：

| 参数 | 类型 | 说明（官方原文摘要） |
|---|---|---|
| `max_tokens` | `number`（必填，minimum: 0） | The maximum number of tokens to generate before stopping. Note that our models may stop _before_ reaching this maximum. Set to `0` to populate the prompt cache without generating a response. |
| `messages` | `array of MessageParam`（必填） | Input messages. 详见 1.3.2。There is a limit of 100,000 messages in a single request. |
| `model` | `Model`（必填） | The model that will complete your prompt. |
| `cache_control` | `optional CacheControlEphemeral or null` | Top-level cache control automatically applies a cache_control marker to the last cacheable block in the request. |
| `container` | `optional MessageCreateParamsContainer or null` | Container identifier for reuse across requests. |
| `inference_geo` | `optional string or null` | Specifies the geographic region for inference processing. If not specified, the workspace's `default_inference_geo` is used. |
| `metadata` | `optional Metadata` | An object describing metadata about the request. |
| `output_config` | `optional OutputConfig` | Configuration options for the model's output, such as the output format. |
| `service_tier` | `optional "auto" or "standard_only"` | Determines whether to use priority capacity (if available) or standard capacity for this request. |
| `stop_sequences` | `optional array of string` | Custom text sequences that will cause the model to stop generating. |
| `stream` | `optional boolean` | Whether to incrementally stream the response using server-sent events. |
| `system` | `optional string or array of TextBlockParam` | System prompt. A system prompt is a way of providing context and instructions to Claude, such as specifying a particular goal or role. |
| `thinking` | `optional ThinkingConfigParam` | Configuration for enabling Claude's extended thinking. |
| `tool_choice` | `optional ToolChoice` | How the model should use the provided tools. 详见 3.6。 |
| `tools` | `optional array of ToolUnion` | Definitions of tools that the model may use. 详见 3.2。 |
| `temperature` | `optional number`（**Deprecated**，max 1 / min 0） | **Deprecated**: Deprecated. Models released after Claude Opus 4.6 do not support setting temperature. A value of 1.0 will be accepted for backwards compatibility, all other values will be rejected with a 400 error. |
| `top_k` | `optional number`（**Deprecated**，minimum: 0） | **Deprecated**: Deprecated. Models released after Claude Opus 4.6 do not accept top_k; any value will be rejected with a 400 error. |
| `top_p` | `optional number`（**Deprecated**，max 1 / min 0） | **Deprecated**: Deprecated. Models released after Claude Opus 4.6 do not support setting top_p. A value >= 0.99 will be accepted for backwards compatibility, all other values will be rejected with a 400 error. |

> ⚠️ 官方在 `working-with-messages` 页另有一处更严格的表述：
> "The `temperature`, `top_p`, and `top_k` sampling parameters are not supported on Claude 4.7 and later models and Claude Mythos Preview. Setting them to a non-default value returns a 400 error. Omit them from request payloads and use prompting to guide the model's behavior instead."

#### 1.3.2 `messages` 参数详解（Messages Format）

**官方原文（role / content 规则）**：

> Input messages.
>
> Our models are trained to operate on alternating `user` and `assistant` conversational turns. When creating a new `Message`, you specify the prior conversational turns with the `messages` parameter, and the model then generates the next `Message` in the conversation. **Consecutive `user` or `assistant` turns in your request will be combined into a single turn.**
>
> Each input message must be an object with a `role` and `content`. You can specify a single `user`-role message, or you can include multiple `user` and `assistant` messages.
>
> If the final message uses the `assistant` role, the response content will continue immediately from the content in that message. This can be used to constrain part of the model's response.

**`role` 字段**（官方类型定义）：

```
role: "user" or "assistant" or "system"
```

**`content` 字段**（官方类型定义）：

```
content: string or array of ContentBlockParam
```

> Each input message `content` may be either a single `string` or an array of content blocks, where each block has a specific `type`. Using a `string` for `content` is shorthand for an array of one content block of type `"text"`. The following input messages are equivalent:

```json
{"role": "user", "content": "Hello, Claude"}
```

```json
{"role": "user", "content": [{"type": "text", "text": "Hello, Claude"}]}
```

> Note that if you want to include a system prompt, you can use the top-level `system` parameter — **there is no `"system"` role for input messages in the Messages API.**

（注：上一条为 `create` 页的表述；`working-with-messages` 页另有「会话中途 system 消息」的新特性说明，见下。）

**`ContentBlockParam` 的全部变体**（官方在 `array of ContentBlockParam` 下列出的全部成员）：

| # | Block 类型 | `type` 值 |
|---|---|---|
| 1 | `TextBlockParam` | `"text"` |
| 2 | `ImageBlockParam` | `"image"` |
| 3 | `DocumentBlockParam` | `"document"` |
| 4 | `SearchResultBlockParam` | `"search_result"` |
| 5 | `ThinkingBlockParam` | `"thinking"` |
| 6 | `RedactedThinkingBlockParam` | `"redacted_thinking"` |
| 7 | `ToolUseBlockParam` | `"tool_use"` |
| 8 | `ToolResultBlockParam` | `"tool_result"` |
| 9 | `ServerToolUseBlockParam` | `"server_tool_use"` |
| 10 | `WebSearchToolResultBlockParam` | `"web_search_tool_result"` |
| 11 | `WebFetchToolResultBlockParam` | `"web_fetch_tool_result"` |
| 12 | `CodeExecutionToolResultBlockParam` | `"code_execution_tool_result"` |
| 13 | `BashCodeExecutionToolResultBlockParam` | `"bash_code_execution_tool_result"` |
| 14 | `TextEditorCodeExecutionToolResultBlockParam` | `"text_editor_code_execution_tool_result"` |
| 15 | `ToolSearchToolResultBlockParam` | `"tool_search_tool_result"` |
| 16 | `ContainerUploadBlockParam` | — |

**多轮对话示例**（官方）：

```json
[
  {"role": "user", "content": "Hello there."},
  {"role": "assistant", "content": "Hi, I'm Claude. How can I help you?"},
  {"role": "user", "content": "Can you explain LLMs in plain English?"}
]
```

**预填充（Prefilling）示例**（官方，末尾为 assistant 消息可约束模型输出）：

```json
[
  {"role": "user", "content": "What's the Greek name for Sun? (A) Sol (B) Helios (C) Sun"},
  {"role": "assistant", "content": "The best answer is ("}
]
```

> ⚠️ 官方在 `working-with-messages` 页标注：
> "Prefilling is not supported on Claude 4.6 and later models and Claude Mythos Preview. Requests using prefill with these models return a 400 error."

**会话中途的 `system` 消息**（官方 `working-with-messages` 页原文）：

> On Claude Fable 5.1, Claude Mythos 5.1, Claude Fable 5, Claude Mythos 5, Claude Opus 4.8, and Claude Opus 5, you can include messages with `"role": "system"` after a user turn (subject to placement rules) to add a new system instruction partway through a conversation. **A `system` message cannot be the first entry in `messages`.** Use the top-level `system` field for instructions that apply from the start.

**Messages API 是无状态的**：

> The Messages API is stateless, which means that you always send the full conversational history to the API. You can use this pattern to build up a conversation over time. Earlier conversational turns don't necessarily need to actually originate from Claude. You can use synthetic `assistant` messages.

#### 1.3.3 `model` 参数

```
model: Model
```

The model that will complete your prompt.

官方给出的完整取值枚举（`create` 页 `Model` 类型定义）：

```
"claude-fable-5-1" or "claude-mythos-5-1" or "claude-sonnet-5" or 14 more
```

即除上述三者外，官方类型中还列有 14 个模型字面量，另有 `string` 兜底分支（允许传入未在枚举中列出的模型名）。

#### 1.3.4 `system` 参数

```
system: optional string or array of TextBlockParam
```

System prompt. A system prompt is a way of providing context and instructions to Claude, such as specifying a particular goal or role.

空 `TextBlockParam` 的字段约束：`text` 的 `minLength: 1`，另可选 `cache_control`、`citations`。

#### 1.3.5 `thinking` 参数（Extended Thinking）

```
thinking: optional ThinkingConfigParam
```

> Configuration for enabling Claude's extended thinking.
>
> When enabled, responses include `thinking` content blocks showing Claude's thinking process before the final answer. **Requires a minimum budget of 1,024 tokens and counts towards your `max_tokens` limit.**

三种配置形态（官方类型定义）：

| 形态 | 字段 |
|---|---|
| `ThinkingConfigEnabled` | `type: "enabled"`、`budget_tokens: number`（minimum: 1024，Must be ≥1024 and less than `max_tokens`）、`display: optional "summarized" or "omitted" or null` |
| `ThinkingConfigDisabled` | `type: "disabled"` |
| `ThinkingConfigAdaptive` | `type: "adaptive"`、`display: optional "summarized" or "omitted" or null` |

`display` 字段说明原文：

> Controls how thinking content appears in the response. When set to `summarized`, thinking is returned normally. When set to `omitted`, thinking content is redacted but a signature is returned for multi-turn continuity. Defaults to `summarized`.

#### 1.3.6 `metadata` 参数

```
metadata: optional Metadata
  user_id: optional string or null   (maxLength: 512)
```

> An external identifier for the user who is associated with the request.
>
> This should be a uuid, hash value, or other opaque identifier. Anthropic may use this id to help detect abuse. Do not include any identifying information such as name, email address, or phone number.

#### 1.3.7 `output_config` 参数

```
output_config: optional OutputConfig
  effort: optional "low" or "medium" or "high" or 2 more or null
  format: optional JSONOutputFormat or null
```

- `effort` 的完整枚举：`"low"`、`"medium"`、`"high"`、`"xhigh"`、`"max"`
- `format`：`type: "json_schema"`、`schema: map[unknown]`（The JSON schema of the format）

#### 1.3.8 `stop_sequences` 参数

```
stop_sequences: optional array of string
```

> Custom text sequences that will cause the model to stop generating.
>
> Our models will normally stop when they have naturally completed their turn, which will result in a response `stop_reason` of `"end_turn"`.
>
> If you want the model to stop generating when it encounters custom strings of text, you can use the `stop_sequences` parameter. If the model encounters one of the custom sequences, the response `stop_reason` value will be `"stop_sequence"` and the response `stop_sequence` value will contain the matched stop sequence.

#### 1.3.9 `stream` 参数

```
stream: optional boolean
```

> Whether to incrementally stream the response using server-sent events.

#### 1.3.10 `service_tier` 参数

```
service_tier: optional "auto" or "standard_only"
```

> Determines whether to use priority capacity (if available) or standard capacity for this request.

#### 1.3.11 `container` 参数

```
container: optional MessageCreateParamsContainer or null
```

> Container identifier for reuse across requests.

`ContainerParams`：`id: optional string or null`（Container id）、`skills: optional array of SkillParams or null`（maxItems: 20），每个 skill 含 `type: "anthropic" or "custom"`、`skill_id: string`、`version: optional string`。

---

### 1.4 Response 格式

#### 1.4.1 `Message` 对象字段表

| 字段 | 类型 | 说明（官方原文摘要） |
|---|---|---|
| `type` | `"message"`（default: message） | Object type. For Messages, this is always `"message"`. |
| `id` | `string` | Unique object identifier. The format and length of IDs may change over time. |
| `container` | `Container or null` | Information about the container used in the request (for the code execution tool). |
| `content` | `array of ContentBlock` | Content generated by the model. |
| `model` | `Model` | — |
| `role` | `"assistant"` | — |
| `stop_details` | `RefusalStopDetails or null` | `type: "refusal"`、`category: "cyber" or "bio" or "frontier_llm" or 2 more or null`、`explanation: string or null` |
| `stop_reason` | `StopReason or null` | The reason that we stopped. 详见 1.5。 |
| `stop_sequence` | `string or null` | Which custom stop sequence was generated, if any. |
| `usage` | `Usage` | Billing and rate-limit usage. |

**`content` 数组的 block 类型**（Response 侧，官方 `array of ContentBlock` 下的全部成员）：

`TextBlock`、`ThinkingBlock`、`RedactedThinkingBlock`、`ToolUseBlock`、`ServerToolUseBlock`、`WebSearchToolResultBlock`、`WebFetchToolResultBlock`、`CodeExecutionToolResultBlock`、`BashCodeExecutionToolResultBlock`、`TextEditorCodeExecutionToolResultBlock`、`ToolSearchToolResultBlock`、`ContainerUploadBlock`。

> If the request input `messages` ended with an `assistant` turn, then the response `content` will continue directly from that last turn. You can use this to constrain the model's output.

**`usage` 对象字段表**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `cache_creation` | `CacheCreation or null` | Breakdown of cached tokens by TTL |
| `cache_creation.ephemeral_1h_input_tokens` | `number`（default: 0, minimum: 0） | The number of input tokens used to create the 1 hour cache entry. |
| `cache_creation.ephemeral_5m_input_tokens` | `number`（default: 0, minimum: 0） | The number of input tokens used to create the 5 minute cache entry. |
| `cache_creation_input_tokens` | `number or null`（minimum: 0） | The number of input tokens used to create the cache entry. |
| `cache_read_input_tokens` | `number or null`（minimum: 0） | The number of input tokens read from the cache. |
| `inference_geo` | `string or null` | The geographic region where inference was performed for this request. |
| `input_tokens` | `number`（minimum: 0） | The number of input tokens which were used. |
| `output_tokens` | `number`（minimum: 0） | The number of output tokens which were used. |
| `output_tokens_details` | `OutputTokensDetails or null` | Breakdown of output tokens by category. |
| `output_tokens_details.thinking_tokens` | `number`（default: 0, minimum: 0） | Number of output tokens the model generated as internal reasoning, including the thinking-block delimiter tokens. Always ≤ `output_tokens`. |
| `server_tool_use` | `ServerToolUsage or null` | The number of server tool requests. |
| `server_tool_use.web_fetch_requests` | `number`（default: 0, minimum: 0） | The number of web fetch tool requests. |
| `server_tool_use.web_search_requests` | `number`（default: 0, minimum: 0） | The number of web search tool requests. |
| `service_tier` | `"standard" or "priority" or "batch" or null` | If the request used the priority, standard, or batch tier. |

官方关于 `usage` 的重要说明原文：

> Anthropic's API bills and rate-limits by token counts, as tokens represent the underlying cost to our systems.
>
> Under the hood, the API transforms requests into a format suitable for the model. The model's output then goes through a parsing stage before becoming an API response. As a result, the token counts in `usage` will not match one-to-one with the exact visible content of an API request or response.
>
> For example, `output_tokens` will be non-zero, even for an empty string response from Claude.
>
> **Total input tokens in a request is the summation of `input_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens`.**

#### 1.4.2 官方完整 Request 示例

```bash
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

#### 1.4.3 官方完整 Response 示例（200）

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

---

### 1.5 Stop Reasons（停止原因）

#### 1.5.1 `stop_reason` 字段说明

> The reason that we stopped.
>
> This may be one the following values:
>
> * `"end_turn"`: the model reached a natural stopping point
> * `"max_tokens"`: we exceeded the requested `max_tokens` or the model's maximum
> * `"stop_sequence"`: one of your provided custom `stop_sequences` was generated
> * `"tool_use"`: the model invoked one or more tools
> * `"pause_turn"`: we paused a long-running turn. You may provide the response back as-is in a subsequent request to let the model continue.
> * `"refusal"`: when streaming classifiers intervene to handle potential policy violations
> * `"model_context_window_exceeded"`: we exceeded the model's context window
>
> **In non-streaming mode this value is always non-null. In streaming mode, it is null in the `message_start` event and non-null otherwise.**

#### 1.5.2 官方 Quick reference 表

| Value | When it occurs | What to do |
|---|---|---|
| `end_turn` | Claude finished its response naturally. | Use the response. |
| `max_tokens` | The response reached your `max_tokens` limit. | Raise `max_tokens` or continue the response. |
| `stop_sequence` | Claude emitted one of your `stop_sequences`. | Read `stop_sequence` to see which one fired. |
| `tool_use` | Claude is calling a tool. | Run the tool and return the result. A server tool call still missing its result block completes in a later response. |
| `pause_turn` | A server-tool loop reached its iteration limit. | Send the assistant content back to continue. |
| `refusal` | Claude declined to respond. | Read `stop_details` and retry on a fallback model. |
| `model_context_window_exceeded` | The response filled the model's context window. | Treat the response as truncated. |

官方 `pause_turn` 补充原文：

> Returned when the server-side sampling loop reaches its iteration limit while executing server tools such as web search. **The default limit is 10 iterations per request.**

#### 1.5.3 官方示例响应（带 `stop_details`）

```json
{
  "id": "msg_01234",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "Here's the answer to your question..."
    }
  ],
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "stop_details": null,
  "usage": {
    "input_tokens": 100,
    "output_tokens": 50
  }
}
```

#### 1.5.4 Streaming 场景下的 `stop_reason`

> When using streaming, `stop_reason` is:
>
> * Provided in the `message_delta` event

```bash
# The message_delta event in the SSE stream carries stop_reason.
jq -c 'select(.type == "message_delta") | .delta.stop_reason'
```

---

## 二、Streaming Messages（SSE 流式）

### 2.1 事件流顺序（Event Flow）

官方原文：

> Each server-sent event includes a named event type and associated JSON data. Each event uses an SSE event name (for example, `event: message_stop`), and includes the matching event `type` in its data.
>
> Each stream uses the following event flow:
>
> 1. `message_start`: contains a `Message` object with empty `content`.
> 2. A series of content blocks, each of which has a `content_block_start`, one or more `content_block_delta` events, and a `content_block_stop` event. Each content block has an `index` that corresponds to its index in the final Message `content` array.
> 3. One or more `message_delta` events, indicating top-level changes to the final `Message` object.
> 4. A final `message_stop` event.

> ⚠️ **The token counts shown in the `usage` field of the `message_delta` event are *cumulative*.**

### 2.2 事件类型表

| 事件 `type` | 说明 |
|---|---|
| `message_start` | 流的第一个事件。含一个 `content` 为空的 `Message` 对象。此事件中 `stop_reason` 为 `null`。 |
| `content_block_start` | 一个内容块开始。含 `index` 与该块的初始 `content_block`。 |
| `content_block_delta` | 内容块的增量更新。含 `index` 与 `delta`。 |
| `content_block_stop` | 一个内容块结束。含 `index`。 |
| `message_delta` | 顶层 `Message` 对象的变化（含 `stop_reason`、`stop_sequence` 与累计 `usage`）。 |
| `message_stop` | 流的最后一个事件。 |
| `ping` | 事件流中可出现任意数量的 `ping` 事件。 |
| `error` | 错误事件（见下）。 |

**`ping` 事件**（官方原文）：

> Event streams may also include any number of `ping` events.

**`error` 事件**（官方原文）：

> The API may occasionally send errors in the event stream. For example, during periods of high usage, you may receive an `overloaded_error`, which would normally correspond to an HTTP 529 in a non-streaming context:

```sse
event: error
data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}
```

**未知事件的处理**（官方原文）：

> In accordance with the versioning policy, new event types may be added, and your code should handle unknown event types gracefully.

### 2.3 Delta 类型表

每个 `content_block_delta` 事件包含一个 `delta`：

| `delta.type` | 携带字段 | 说明 |
|---|---|---|
| `text_delta` | `text` | `text` 内容块的文本增量 |
| `input_json_delta` | `partial_json` | `tool_use` 内容块的 `input` 增量（**部分 JSON 字符串**） |
| `thinking_delta` | `thinking` | `thinking` 内容块的思考文本增量 |
| `signature_delta` | `signature` | 思考块的签名，**在 `content_block_stop` 之前发送** |

#### 2.3.1 `text_delta`

```sse
event: content_block_delta
data: {"type": "content_block_delta","index": 0,"delta": {"type": "text_delta", "text": "ello frien"}}
```

#### 2.3.2 `input_json_delta`

官方原文（**关键**）：

> The deltas for `tool_use` content blocks correspond to updates for the `input` field of the block. To support maximum granularity, the deltas are *partial JSON strings*, whereas the final `tool_use.input` is always an *object*.
>
> You can accumulate the string deltas and parse the JSON once you receive a `content_block_stop` event, by using a library like Pydantic to do partial JSON parsing, or by using the SDKs, which provide helpers to access parsed incremental values.

```sse
event: content_block_delta
data: {"type": "content_block_delta","index": 1,"delta": {"type": "input_json_delta","partial_json": "{\"location\": \"San Fra"}}
```

> Note: Current models only support emitting one complete key and value property from `input` at a time. As such, when using tools, there may be delays between streaming events while the model is working. Once an `input` key and value are accumulated, they are emitted as multiple `content_block_delta` events with chunked partial JSON so that the format can automatically support finer granularity in future models.

#### 2.3.3 `thinking_delta` / `signature_delta`

官方原文：

> When using thinking with streaming enabled, you'll receive thinking content through `thinking_delta` events. These deltas correspond to the `thinking` field of the `thinking` content blocks.
>
> For thinking content, a special `signature_delta` event is sent just before the `content_block_stop` event. This signature is used to verify the integrity of the thinking block.
>
> When `display: "omitted"` is set on the thinking configuration, no thinking text is streamed. The thinking block opens, receives a `thinking_delta` with an empty `thinking` string and then a single `signature_delta`, and closes.

```sse
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "I need to find the GCD of 1071 and 462 using the Euclidean algorithm.\n\n1071 = 2 × 462 + 147"}}
```

```sse
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}
```

### 2.4 完整 SSE 示例

#### 2.4.1 基础流式响应（官方完整原始输出）

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

> 注意上例中 `content_block_start` 时 `tool_use.input` 是空对象 `{}`，真正的参数由后续 `input_json_delta` 的 `partial_json` 片段拼成。

#### 2.4.3 流式 + Thinking（官方完整原始输出）

```sse
event: message_start
data: {"type": "message_start", "message": {"id": "msg_01...", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5", "stop_reason": null, "stop_sequence": null}}

event: content_block_start
data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "I need to find the GCD of 1071 and 462 using the Euclidean algorithm.\n\n1071 = 2 × 462 + 147"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "\n462 = 3 × 147 + 21"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "\n147 = 7 × 21 + 0"}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "\nThe remainder is 0, so GCD(1071, 462) = 21."}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 0}

event: content_block_start
data: {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}

event: content_block_delta
data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "The greatest common divisor of 1071 and 462 is **21**."}}

event: content_block_stop
data: {"type": "content_block_stop", "index": 1}

event: message_delta
data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}}

event: message_stop
data: {"type": "message_stop"}
```

#### 2.4.4 SDK 侧获取完整 Message

官方原文：

> The `.stream()` call keeps the HTTP connection alive with server-sent events, then `.get_final_message()` (Python) or `.finalMessage()` (TypeScript) accumulates all events and returns the complete `Message` object. In Go, you call `message.Accumulate(event)` inside the stream loop to build the same complete `Message`. In Java, use `MessageAccumulator.create()` and call `accumulator.accumulate(event)` on each event. In C#, await the stream's `.Aggregate()` extension method to get the complete `Message`, or pass a `MessageContentAggregator` to `.CollectAsync()` to aggregate while handling events. In Ruby, call `.accumulated_message` on the stream. In the PHP SDK, you iterate over stream events manually to accumulate the response.

#### 2.4.5 官方「完整 HTTP 流响应」组成

> A stream response consists of:
>
> 1. A `message_start` event
> 2. Potentially multiple content blocks, each of which contains:
>    * A `content_block_start` event
>    * Potentially multiple `content_block_delta` events
>    * A `content_block_stop` event
> 3. One or more `message_delta` events
> 4. A `message_stop` event
>
> There may be `ping` events dispersed throughout the response as well.

### 2.5 错误恢复（Error Recovery）

官方按模型代次给出两套策略：

**Claude 4.5 及更早**

> For Claude 4.5 models and earlier, you can recover a streaming request that was interrupted because of network issues, timeouts, or other errors by resuming from where the stream was interrupted. This approach saves you from re-processing the entire response.
>
> 1. **Capture the partial response:** Save all content that was successfully received before the error occurred.
> 2. **Construct a continuation request:** Create a new API request that includes the partial assistant response as the beginning of a new assistant message.
> 3. **Resume streaming:** Continue receiving the rest of the response from where it was interrupted.

**Claude 4.6 及更晚**

> For Claude 4.6 and later models, the same capture-and-resume strategy applies, but step 2 changes: instead of placing the partial response in an assistant message, add a user message that instructs the model to continue from where it left off.
>
> ```text
> Your previous response was interrupted and ended with [previous_response]. Continue from where you left off.
> ```

**最佳实践**（官方原文）：

> 1. **Use SDK features:** Leverage the SDK's built-in message accumulation and error handling capabilities.
> 2. **Handle content types:** Be aware that messages can contain multiple content blocks (`text`, `tool_use`, `thinking`). **Tool use and extended thinking blocks cannot be partially recovered.** You can resume streaming from the most recent text block.

---

## 三、Tool Use（工具调用 / 函数调用）

### 3.1 概述：工具在哪里执行

官方把工具按**代码在哪里执行**分为三类（取自 `how-tool-use-works`）：

| 类别 | 谁执行 | 工具 |
|---|---|---|
| **User-defined tools**（客户端执行） | 你的应用 | 绝大多数工具调用流量属于这一类，schema 由你自己写 |
| **Anthropic-schema tools**（客户端执行） | 你的应用 | `memory`、`bash`、`text_editor`、`computer`、`browser` |
| **Server-executed tools**（服务端执行） | Anthropic | `web_search`、`web_fetch`、`code_execution`、`tool_search` |

> Tool use is a contract between your application and the model. You specify what operations are available and what shape their inputs and outputs take; Claude determines when and how to call them. **The model never executes anything on its own.** It emits a structured request, your code (or Anthropic's servers) runs the operation, and the result flows back into the conversation.

**client tools 的往返**（官方原文）：

> **Client tools** (including user-defined tools and tools with Anthropic-defined schemas, such as `bash` and `text_editor`) run in your application. Claude responds with `stop_reason: "tool_use"` and one or more `tool_use` blocks. Your code executes the operation and sends back a `tool_result`.

**server tools 的往返**（官方原文）：

> **Server tools** (such as `web_search`, `web_fetch`, `code_execution`, and `tool_search`) run on Anthropic's infrastructure: you see the results directly without handling execution, unless Claude calls the tool in the same group of parallel tool calls as one of your client tools.

> For `web_search`, `web_fetch`, `code_execution`, and `tool_search`, Anthropic runs the code. You enable the tool in your request and the server handles everything else. **You never construct a `tool_result` block for these tools.**

**与其他 API 的差异**（官方原文）：

> Unlike APIs that separate tool use or use special roles like `tool` or `function`, the Claude API integrates tools directly into the `user` and `assistant` message structure.
>
> Messages contain arrays of `text`, `image`, `tool_use`, and `tool_result` blocks. `user` messages include client content and `tool_result`, while `assistant` messages contain AI-generated content and `tool_use`.

### 3.2 Tool 定义（JSON Schema）

#### 3.2.1 顶层 `tools` 参数

```
tools: optional array of ToolUnion
```

官方原文：

> Definitions of tools that the model may use.
>
> If you include `tools` in your API request, the model may return `tool_use` content blocks that represent the model's use of those tools. You can then run those tools using the tool input generated by the model and then optionally return results back to the model using `tool_result` content blocks.
>
> There are two types of tools: **client tools** and **server tools**. The behavior described below applies to client tools.
>
> Each tool definition includes:
>
> * `name`: Name of the tool.
> * `description`: Optional, but strongly-recommended description of the tool.
> * `input_schema`: JSON schema for the tool `input` shape that the model will produce in `tool_use` output content blocks.

#### 3.2.2 官方 Tool 定义字段表

（取自 `define-tools` 页 `Specifying client tools`）

| Parameter | Description |
|---|---|
| `name` | The name of the tool. Must match the regex `^[a-zA-Z0-9_-]{1,128}$`. |
| `description` | A detailed plaintext description of what the tool does, when it should be used, and how it behaves. |
| `input_schema` | A JSON Schema object defining the expected parameters for the tool. |
| `input_examples` | (Optional) An array of example input objects to help Claude understand how to use the tool. |

**`Tool` 对象（`create` 页官方类型定义）的全部字段**：

```
- `Tool object`
  - `type: optional "custom" or null`
  - `input_schema: object`          (必填)
    - `type: "object"`
    - `properties: optional map[unknown] or null`
    - `required: optional array of string or null`
  - `name: string`                  (必填)
    maxLength: 128, minLength: 1, pattern: ^[a-zA-Z0-9_-]{1,128}$
  - `allowed_callers: optional array of "direct" or "code_execution_20250825"
       or "code_execution_20260120" or "code_execution_20260521"`
  - `cache_control: optional CacheControlEphemeral or null`
  - `defer_loading: optional boolean`
      If true, tool will not be included in initial system prompt.
      Only loaded when returned via tool_reference from tool search.
  - `description: optional string`
  - `eager_input_streaming: optional boolean or null`
  - `input_examples: optional array of map[unknown]`
  - `strict: optional boolean`
      When true, guarantees schema validation on tool names and inputs
```

#### 3.2.3 官方 Tool 定义示例

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

#### 3.2.4 Tool use 系统提示词（官方公开）

> When you call the Claude API with the `tools` parameter, the API constructs a special system prompt from the tool definitions, tool configuration, and any user-specified system prompt.

```text
In this environment you have access to a set of tools you can use to answer the user's question.
{{ FORMATTING INSTRUCTIONS }}
String and scalar parameters should be specified as is, while lists and objects should use JSON format. Note that spaces for string values are not stripped. The output is not expected to be valid XML and is parsed with regular expressions.
Here are the functions available in JSONSchema format:
{{ TOOL DEFINITIONS IN JSON SCHEMA }}
{{ USER SYSTEM PROMPT }}
{{ TOOL CONFIGURATION }}
```

### 3.3 `tool_use` 响应 content block 格式

当模型决定调用工具时，响应的 `stop_reason` 为 `"tool_use"`，且 `content` 数组中包含一个或多个 `tool_use` block。

官方原文（`handle-tool-calls` 页）：

> The response will have a `stop_reason` of `tool_use` and one or more `tool_use` content blocks that include:
>
> * `id`: A unique identifier for this particular tool use block. This will be used to match up the tool results later.
> * `name`: The name of the tool being used.
> * `input`: An object containing the input being passed to the tool, conforming to the tool's `input_schema`.

**`ToolUseBlock`（Response 侧）官方类型定义**：

```
- `ToolUseBlock object`
  - `type: "tool_use"`              (default: tool_use)
  - `id: string`                    pattern: ^[a-zA-Z0-9_-]+$
  - `caller: DirectCaller or ServerToolCaller or ServerToolCaller20260120`
      default: {"type":"direct"}
  - `input: map[unknown]`
  - `name: string`                  minLength: 1
  - `toolset_name: optional string or null`
```

**官方完整响应示例**：

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

官方说明：

> When using tools, Claude often comments on what it's doing or responds naturally to the user before calling tools.
>
> It's important to note that Claude may use various phrasings and approaches when explaining its actions. Your code should treat these responses like any other assistant-generated text, and not rely on specific formatting conventions.

**`tool_use` 的流式增量**（官方原文）：

> The deltas for `tool_use` content blocks correspond to updates for the `input` field of the block. To support maximum granularity, the deltas are *partial JSON strings*, whereas the final `tool_use.input` is always an *object*.

### 3.4 `tool_result` 格式（重点）

#### 3.4.1 `ToolResultBlockParam` 官方类型定义（逐字照录）

```
- `ToolResultBlockParam object`

  - `type: "tool_result"`

  - `tool_use_id: string`
      pattern: ^[a-zA-Z0-9_-]+$

  - `cache_control: optional CacheControlEphemeral or null`
      Create a cache control breakpoint at this content block.

  - `content: optional string or array of TextBlockParam or ImageBlockParam
       or SearchResultBlockParam or 3 more`
    - `string`
    - `array of TextBlockParam or ImageBlockParam or SearchResultBlockParam or 3 more`
      - `TextBlockParam object`
      - `ImageBlockParam object`
      - `SearchResultBlockParam object`
      - `DocumentBlockParam object`
      - `ToolReferenceBlockParam object`
      - `BrowserStateBlockParam object`

  - `is_error: optional boolean`

  - `toolset_name: optional string or null`
```

#### 3.4.2 ⚠️ 结论：`content` 是**可选**的，且**可以是字符串或数组**

**（1）`content` 字段是可选的（`optional`）**，类型为 `string` 或内容 block 数组。

**官方 `handle-tool-calls` 页对 `content` 的原文说明**：

> `content` (optional): The result of the tool, as a string (for example, `"content": "15 degrees"`), a list of nested content blocks (for example, `"content": [{"type": "text", "text": "15 degrees"}]`), or a list of document blocks (for example, `"content": [{"type": "document", "source": {"type": "text", "media_type": "text/plain", "data": "15 degrees"}}]`). These content blocks can use the `text`, `image`, `document`, or `search_result` types.

**（2）官方给出的四种 `tool_result` 形态**（逐字照录）：

**① 成功的工具结果（`content` 为字符串）**

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

**② 带图片的工具结果（`content` 为内容 block 数组）**

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

**③ 空的工具结果（完全省略 `content`）**

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

**④ 带文档的工具结果**

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

#### 3.4.3 ⚠️ 官方真正强制的是什么（会返回 400 的两条规则）

官方 `handle-tool-calls` 页 `Important formatting requirements` 原文：

> * Tool result blocks must immediately follow their corresponding tool use blocks in the message history. **You cannot include any messages between the assistant's tool use message and the user's tool result message.**
> * **In the user message containing tool results, the tool_result blocks must come FIRST in the content array. Any text must come AFTER all tool results.**

**会触发 400 错误的写法**（`tool_result` 之前夹了 `text`）：

```json
{
  "role": "user",
  "content": [
    { "type": "text", "text": "Here are the results:" }, // ❌ Text before tool_result
    { "type": "tool_result", "tool_use_id": "toolu_01" /* ... */ }
  ]
}
```

**正确的写法**（仅调用 client tools 时）：

```json
{
  "role": "user",
  "content": [
    { "type": "tool_result", "tool_use_id": "toolu_01" /* ... */ },
    { "type": "text", "text": "What should I do next?" } // ✅ Text after tool_result
  ]
}
```

官方排查提示：

> If you receive an error like "tool_use ids were found without tool_result blocks immediately after", check that your tool results are formatted correctly.

官方 `handling-stop-reasons` 页对同一错误的补充原文：

> Leaving out a `tool_result`, or putting one after other content, fails earlier with the standard `tool_use ids were found without tool_result blocks immediately after` error instead. To give Claude more input, send it as a separate user message after the turn completes.

**归纳**：官方强制的是 ——

1. 外层 user 消息的 `content` 是内容 block **数组**，每个 `tool_result` 是该数组中的一个元素；
2. `tool_result` block 必须**排在该数组的所有 `text` 之前**；
3. `tool_result` 消息必须**紧跟在**对应的 assistant `tool_use` 消息之后，中间不能插入任何其它消息；
4. 每个 `tool_use` 都要有一个对应的 `tool_result`（否则报 `tool_use ids were found without tool_result blocks immediately after`）。

而 `tool_result` **自身**的 `content` 字段是**可选的**，且**允许是字符串**（官方示例 `"content": "15 degrees"`），也允许完全省略。

> ⚠️ **范围说明**：本节写的是 **Anthropic 官方**的要求。
> 若本项目的 DeepSeek Anthropic 兼容端点对 `tool_result.content` 另有更严约束（例如要求必须为数组），
> 那是**实现方自加约束**，不属于 Anthropic 官方要求，不得记为本节内容。

#### 3.4.4 客户端工具调用处理流程（官方三步）

> When you receive a tool use response for a client tool, you should:
>
> 1. Extract the `name`, `id`, and `input` from the `tool_use` block.
> 2. Run the actual tool in your codebase corresponding to that tool name, passing in the tool `input`.
> 3. Continue the conversation by sending a new message with the `role` of `user`, and a `content` block containing the `tool_result` type and the following information:
>    * `tool_use_id`: The `id` of the tool use request this is a result for.
>    * `content` (optional): The result of the tool, as a string… / a list of nested content blocks… / a list of document blocks…
>    * `is_error` (optional): Set to `true` if the tool execution resulted in an error.

#### 3.4.5 安全提示（官方原文）

> Tool results often carry content from sources outside your control: web pages, inbound email, user uploads, third-party APIs. **Treat that content as untrusted**: an attacker who can influence it may embed instructions that try to redirect Claude (indirect prompt injection). Keep untrusted content inside `tool_result` blocks rather than `system` prompts or plain user `text` blocks.

#### 3.4.6 toolset 相关的更窄约束（computer use / browser use）

官方原文：

> A `tool_result` that answers a computer use or browser use member block must also echo the same `toolset_name` value as the `tool_use` block; **a member result that omits it is rejected**. Its `content` is also narrower: a member result may contain only `text` and `image` blocks, and a browser use result may add one `browser_state` block.

### 3.5 错误处理 `is_error`

官方定义的三类工具错误：

**（1）工具执行错误**（tool execution error）

> If the tool itself throws an error during execution (for example, a network error when fetching weather data), you can return the error message in the `content` along with `"is_error": true`:

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

> Claude will then incorporate this error into its response to the user.
>
> Write instructive error messages. Instead of generic errors like `"failed"`, include what went wrong and what Claude should try next (for example, `"Rate limit exceeded. Retry after 60 seconds."`).

**（2）工具名无效 / 缺参数**

> If Claude's attempted use of a tool is invalid (for example, missing required parameters), it usually means that there wasn't enough information for Claude to use the tool correctly. Your best bet during development is to try the request again with more-detailed `description` values in your tool definitions.

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

> If a tool request is invalid or missing parameters, Claude will retry 2-3 times with corrections before apologizing to the user.

**（3）server tool 错误**

> When server tools encounter errors (for example, network issues with Web Search), Claude will transparently handle these errors and attempt to provide an alternative response or explanation to the user. **Unlike client tools, you do not need to handle `is_error` results for server tools.**

web search 可能的错误码：

| 错误码 | 含义 |
|---|---|
| `too_many_requests` | Rate limit exceeded |
| `invalid_input` | Invalid search query parameter |
| `max_uses_exceeded` | Maximum web search tool uses exceeded |
| `query_too_long` | Query exceeds maximum length |
| `unavailable` | An internal error occurred |

### 3.6 `tool_choice` 参数（四个选项）

```
tool_choice: optional ToolChoice
```

官方说明：

> How the model should use the provided tools. The model can use a specific tool, any available tool, decide by itself, or not use tools at all.

**官方四个选项的类型定义（逐字照录）**：

| 选项 | 类型定义 | 官方说明 |
|---|---|---|
| `auto` | `ToolChoiceAuto object`：`type: "auto"`、`disable_parallel_tool_use: optional boolean` | The model will automatically decide whether to use tools. `disable_parallel_tool_use` 默认 `false`；设为 `true` 时 **the model will output at most one tool use**。 |
| `any` | `ToolChoiceAny object`：`type: "any"`、`disable_parallel_tool_use: optional boolean` | The model will use any available tools. `disable_parallel_tool_use` 默认 `false`；设为 `true` 时 **the model will output exactly one tool use**。 |
| `tool` | `ToolChoiceTool object`：`type: "tool"`、`name: string`（The name of the tool to use）、`disable_parallel_tool_use: optional boolean` | The model will use the specified tool with `tool_choice.name`. 设为 `true` 时 **the model will output exactly one tool use**。 |
| `none` | `ToolChoiceNone object`：`type: "none"` | The model will not be allowed to use tools. |

**四种选项的 JSON 形态**：

```json
{"type": "auto"}
```

```json
{"type": "any"}
```

```json
{"type": "tool", "name": "get_weather"}
```

```json
{"type": "none"}
```

**强制工具调用的限制**（官方原文）：

> Not every model and setting supports forced tool use. Where it isn't supported, `tool_choice: {"type": "any"}` and `tool_choice: {"type": "tool", "name": "..."}` fail, while `tool_choice: {"type": "auto"}` (the default) and `tool_choice: {"type": "none"}` still work:

| Model or setting | Restriction | What to use instead |
|---|---|---|
| Manual extended thinking (`thinking: {type: "enabled"}`) | `any` and `tool` are not supported and result in an error | `auto` or `none`. Adaptive thinking, including on models where thinking is on by default such as Claude Opus 5, supports forced tool use |
| Claude Fable 5.1 and Claude Mythos 5.1 | `any` and `tool` return a 400 error | `auto` with strict tool use to guarantee schema-valid tool inputs, or structured outputs when you need a response in a fixed JSON shape. Prompting still influences which tool `auto` picks. `none` is also supported |

**官方强制调用示例**：

```json
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
```

### 3.7 多轮工具调用循环

**官方给出的 client tools 循环（`how-tool-use-works` 页，`The agentic loop`）**：

> Client-executed tools (both user-defined and Anthropic-schema) require your application to drive a loop. The model can't run your code, so every tool call is a round trip: the model asks, you execute, you report back, the model continues.
>
> The canonical shape is a `while` loop keyed on `stop_reason`:
>
> 1. Send a request with your `tools` array and the user message.
> 2. Claude responds with `stop_reason: "tool_use"` and one or more `tool_use` blocks.
> 3. Execute each tool. Format the outputs as `tool_result` blocks.
> 4. Send a new request containing the original messages, the assistant's response, and a user message with the `tool_result` blocks.
> 5. Repeat from step 2 while `stop_reason` is `"tool_use"`.
>
> In practice this reads as: **while `stop_reason == "tool_use"`, execute the tools and continue the conversation.** The loop exits on any other stop reason (`"end_turn"`, `"max_tokens"`, `"stop_sequence"`, or `"refusal"`), which means Claude has either produced a final answer or stopped for another reason that your application should handle.

**官方完整两轮请求示例（cURL，第一轮定义工具并取得 `tool_use`，第二轮回传 `tool_result`）**：

```bash
# Claude replies with a tool_use block naming the tool and its arguments.
TOOLS='[
  {
    "name": "get_weather",
    "description": "Get the current weather for a given location.",
    "input_schema": {
      "type": "object",
      "properties": {
        "location": {"type": "string", "description": "City and state, e.g. San Francisco, CA"}
      },
      "required": ["location"]
    }
  }
]'
USER_MSG="What's the weather in San Francisco?"
RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$(jq -n --argjson tools "$TOOLS" --arg msg "$USER_MSG" '{
    model: "claude-opus-5",
    max_tokens: 1024,
    tools: $tools,
    # Ask for at most one tool call per turn.
    tool_choice: {type: "auto", disable_parallel_tool_use: true},
    messages: [{role: "user", content: $msg}]
  }')")
TOOL_USE=$(echo "$RESPONSE" | jq '.content[] | select(.type == "tool_use")')
echo "Claude called $(echo "$TOOL_USE" | jq -r '.name') with $(echo "$TOOL_USE" | jq -c '.input')"

# Run the tool, then send the result back in a tool_result block.
# Claude uses the result to answer the original question.
WEATHER="15 degrees Celsius, partly cloudy"
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$(jq -n \
    --argjson tools "$TOOLS" \
    --arg msg "$USER_MSG" \
    --argjson assistant "$(echo "$RESPONSE" | jq '.content')" \
    --arg tool_use_id "$(echo "$TOOL_USE" | jq -r '.id')" \
    --arg weather "$WEATHER" \
    '{
      model: "claude-opus-5",
      max_tokens: 1024,
      tools: $tools,
      tool_choice: {type: "auto", disable_parallel_tool_use: true},
      messages: [
        {role: "user", content: $msg},
        {role: "assistant", content: $assistant},
        {role: "user", content: [
          {type: "tool_result", tool_use_id: $tool_use_id, content: $weather}
        ]}
      ]
    }')"
```

> 注意第二轮请求中：`messages` 依次是 `user`（原始问题）→ `assistant`（模型上一轮完整 `content`）→ `user`（只含 `tool_result` 数组），且 `tools` 数组保持不变。

**server tools 的循环**（官方原文）：

> Server-executed tools run their own loop inside Anthropic's infrastructure. A single request from your application might trigger several web searches or code executions before a response comes back.
>
> This internal loop has an iteration limit. If the model is still iterating when it hits the cap, the response comes back with `stop_reason: "pause_turn"` instead of `"end_turn"`. A paused turn means the work isn't finished; re-send the conversation (including the paused response) to let the model continue where it left off.

**server tool 未完成时的续传规则**（官方 `handling-stop-reasons` 页原文）：

> The continuation is a user message of `tool_result` blocks, one for every `tool_use` block in the response, with two extra rules: **that message must contain nothing except the `tool_result` blocks, and the request must keep the same `tools` array.** A resume request that no longer defines the waiting server tool fails with a 400 whose message ends ``but no `web_search` tool was provided``.

```text
`web_search` tool use with id `srvtoolu_01HxbWnMRmbWyMfUtJKC45rA` was found without a corresponding `web_search_tool_result` block
```

### 3.8 官方 Tool 定义最佳实践

（`define-tools` 页 `Best practices for tool definitions` 原文）

* **Provide extremely detailed descriptions.** This is by far the most important factor in tool performance. Your descriptions should explain every detail about the tool, including:
  * What the tool does
  * When it should be used (and when it shouldn't)
  * What each parameter means and how it affects the tool's behavior
  * Any important caveats or limitations… Aim for at least 3–4 sentences for each tool description, more if the tool is complex.

* **Prioritize descriptions, but consider using `input_examples` for complex tools.**

* **Consolidate related operations into fewer tools.** Rather than creating a separate tool for every action (`create_pr`, `review_pr`, `merge_pr`), group them into a single tool with an `action` parameter.

* **Use meaningful namespacing in tool names.** When your tools span multiple services or resources, prefix names with the service (for example, `github_list_prs`, `slack_send_message`).

* **Design tool responses to return only high-signal information.** Return semantic, stable identifiers (for example, slugs or UUIDs) rather than opaque internal references, and include only the fields Claude needs to reason about its next step.

**官方「好的描述」示例**：

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

**官方「差的描述」示例**：

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

> The good description clearly explains what the tool does, when to use it, what data it returns, and what the `ticker` parameter means. The poor description is too brief and leaves Claude with many open questions about the tool's behavior and usage.

### 3.9 何时该用工具（官方判断）

**适合**：

* **Actions with side effects.** Sending an email, writing a file, updating a record.
* **Fresh or external data.** Current prices, today's weather, the contents of a database.
* **Structured, guaranteed-shape outputs.** When you need a JSON object with specific fields rather than prose.
* **Calling into existing systems.** Databases, internal APIs, filesystems.

> A clear sign that you should be using tools: **if you're writing a regex to extract a decision from model output, that decision should have been a tool call.**

**不适合**：

* The model can answer from training alone. Summarization, translation, and general-knowledge questions don't need a tool round trip.
* The interaction is one-shot Q&A with no side effects.
* Tool-calling latency would dominate a trivial response.

---

## 来源 URL

### 本次抓取结果总览

**抓取时间**：2026-09-20 14:54（UTC+8）／ 2026-09-20 06:54 UTC

| # | URL | 结果 | 用途 |
|---|---|---|---|
| 1 | `https://platform.claude.com/llms-full.txt` | **成功**（HTTP 200，35,216,650 字节 / 1,179,764 行 / 629 个页面区块） | 主源。官方全文文档聚合文件，本文件所有内容均逐字取自其中 |
| 2 | `https://platform.claude.com/llms.txt` | **成功**（HTTP 200，68,036 字节） | 官方文档页面索引 |

`llms-full.txt` 的文件自述尾部原文：

```text
Last generated: 2026-09-18T19:18:53.788Z
Total pages included: 629
```

### 未能抓取到的内容（如实记录，未用记忆补写）

| URL | 实际现象 |
|---|---|
| `https://docs.anthropic.com/en/api/messages` | **未取得内容**。链路：`docs.anthropic.com/en/api/messages` → 301 → `platform.claude.com/docs/en/api/messages` → 307 → `www.anthropic.com/app-unavailable-in-region`（地区封锁，非反爬） |
| `https://platform.claude.com/docs/**` 全部页面路由 | **同上，未取得内容**。静态全文文件不受影响，页面路由被地区封锁 |
| `https://platform.claude.com/docs/en/api/messages/create`（HTML） | **未取得内容**（同上，307 → 地区封锁页）。其正文改为自 `llms-full.txt` 内 `url: https://platform.claude.com/docs/en/api/messages/create` 区块取得 |
| `https://platform.claude.com/docs/en/build-with-claude/streaming`（HTML） | **未取得内容**（同上）。正文取自 `llms-full.txt` 内同名区块 |
| `https://platform.claude.com/docs/en/agents-and-tools/tool-use/*`（HTML） | **未取得内容**（同上）。正文取自 `llms-full.txt` 内同名区块 |

> **说明**：本次未尝试任何绕过地区封锁的手段（按任务要求不绕过）。

### 本文件实际引用的 `llms-full.txt` 区块（行号为本文件内 1-based 行号）

| # | 区块内 `url:` 字段（官方页面地址） | 文件内行号区间 | 覆盖章节 |
|---|---|---|---|
| 1 | `https://platform.claude.com/docs/en/api/messages/create` | 711155–721874 | 1.1 Endpoint、1.2.2、1.3 全部 request body 参数、1.4 Response 字段表与示例、1.5 stop_reason、3.2.2 Tool 对象、3.3 ToolUseBlock、3.4.1 ToolResultBlockParam、3.6 tool_choice 类型定义 |
| 2 | `https://platform.claude.com/docs/en/api/overview` | 163746–163939 | 1.1 根地址与请求体积上限、1.2.1 Headers 表、1.2.4 响应 Headers |
| 3 | `https://platform.claude.com/docs/en/api/beta-headers` | 163940–164168 | 1.2.3 `anthropic-beta` header 全部内容 |
| 4 | `https://platform.claude.com/docs/en/build-with-claude/streaming` | 16975–18513 | 第二章全部（事件流、事件类型、delta 类型、完整 SSE 示例、错误恢复） |
| 5 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview` | 27140–28046 | 3.1 概述、3.7 官方两轮请求示例 |
| 6 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools` | 37231–38144 | 3.2 工具定义表与示例、3.2.4 系统提示词、3.6 强制调用限制、3.8 最佳实践 |
| 7 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls` | 38145–38427 | 3.3 tool_use 响应、3.4 全部 tool_result 内容、3.5 is_error、3.1 与其他 API 的差异 |
| 8 | `https://platform.claude.com/docs/en/agents-and-tools/tool-use/how-tool-use-works` | 38428–38529 | 3.1 三类工具分类、3.7 agentic loop、3.9 何时用工具 |
| 9 | `https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons` | 3547–7238 | 1.5.2 Quick reference、1.5.4 流式 stop_reason、3.7 server tool 续传规则 |
| 10 | `https://platform.claude.com/docs/en/build-with-claude/working-with-messages` | 7239–8302 | 1.3.2 多轮与预填充规则、会话中途 system 消息、temperature/top_p/top_k 限制 |

> **说明**：以上行号来自本次下载的 `llms-full.txt`（35,216,650 字节版本）。
> 该文件会随官方更新而重新生成，**行号会变**；区块身份请以区块内自带的 `url:` 字段为准。
