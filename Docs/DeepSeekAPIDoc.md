# DeepSeek API 参考文档

> **抓取时间**: 2026-05-24
> **来源**: [DeepSeek API 官方文档](https://api-docs.deepseek.com/zh-cn/)

---

## 1. 概述

DeepSeek API 使用与 OpenAI / Anthropic 兼容的 API 格式，通过修改配置，可以使用 OpenAI / Anthropic SDK 来访问 DeepSeek API。

### 1.1 Base URL

| 格式 | base_url |
| --- | --- |
| OpenAI 兼容 | `https://api.deepseek.com` |
| Anthropic 兼容 | `https://api.deepseek.com/anthropic` |
| Beta 功能（如 strict 模式） | `https://api.deepseek.com/beta` |

### 1.2 可用模型

| 模型 ID | 说明 |
| --- | --- |
| `deepseek-v4-flash` | 当前主力模型（快） |
| `deepseek-v4-pro` | 当前主力模型（强） |
| `deepseek-chat` | **将于 2026/07/24 弃用**，对应 `deepseek-v4-flash` 非思考模式 |
| `deepseek-reasoner` | **将于 2026/07/24 弃用**，对应 `deepseek-v4-flash` 思考模式 |

> **注意**: 当给 DeepSeek 的 Anthropic API 传入不支持的模型名时，API 后端会自动将其映射到 `deepseek-v4-flash` 模型。

### 1.3 调用示例（OpenAI 格式）

```bash
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
  -d '{
        "model": "deepseek-v4-pro",
        "messages": [
          {"role": "system", "content": "You are a helpful assistant."},
          {"role": "user", "content": "Hello!"}
        ],
        "thinking": {"type": "enabled"},
        "reasoning_effort": "high",
        "stream": false
      }'
```

### 1.4 调用示例（Anthropic 格式）

```python
import anthropic

client = anthropic.Anthropic(
    base_url="https://api.deepseek.com/anthropic",
    api_key="<your api key>",
)

message = client.messages.create(
    model="deepseek-v4-pro",
    max_tokens=1000,
    system="You are a helpful assistant.",
    messages=[
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Hi, how are you?"
                }
            ]
        }
    ]
)
print(message.content)
```

---

## 2. Anthropic API 兼容性（重点）

DeepSeek 提供 Anthropic API 格式支持，base_url 为 `https://api.deepseek.com/anthropic`。通过设置 `ANTHROPIC_BASE_URL` 环境变量即可将 Anthropic SDK 指向 DeepSeek。

### 2.1 HTTP Header

| Field | Support Status |
| --- | --- |
| `anthropic-beta` | Ignored（忽略） |
| `anthropic-version` | Ignored（忽略） |
| `x-api-key` | **Fully Supported** |

### 2.2 Simple Fields

| Field | Support Status |
| --- | --- |
| `model` | **Use DeepSeek Model Instead**（需使用 DeepSeek 模型名） |
| `max_tokens` | **Fully Supported** |
| `container` | Ignored（忽略） |
| `mcp_servers` | Ignored（忽略） |
| `metadata` | 仅 `user_id` 支持，其他忽略。（详见限速与隔离文档） |
| `service_tier` | Ignored（忽略） |
| `stop_sequences` | **Fully Supported** |
| `stream` | **Fully Supported** |
| `system` | **Fully Supported** |
| `temperature` | **Fully Supported**（范围 [0.0 ~ 2.0]） |
| `thinking` | **Supported**（`budget_tokens` 被忽略） |
| `output_config` | 仅 `effort` 支持 |
| `top_k` | Ignored（忽略） |
| `top_p` | **Fully Supported** |

### 2.3 Tool Fields

#### tools 对象

| Field | Support Status |
| --- | --- |
| `name` | **Fully Supported** |
| `input_schema` | **Fully Supported** |
| `description` | **Fully Supported** |
| `cache_control` | Ignored（忽略） |

#### tool_choice 值

| Value | Support Status |
| --- | --- |
| `none` | **Fully Supported** |
| `auto` | **Supported**（`disable_parallel_tool_use` 被忽略） |
| `any` | **Supported**（`disable_parallel_tool_use` 被忽略） |
| `tool` | **Supported**（`disable_parallel_tool_use` 被忽略） |

### 2.4 Message Fields（完整对照表）

| Field | Variant | Sub-Field | Support Status |
| --- | --- | --- | --- |
| `content` | string | - | **Fully Supported** |
| | array, type="text" | `text` | **Fully Supported** |
| | | `cache_control` | Ignored |
| | | `citations` | Ignored |
| | array, type="image" | - | **Not Supported** |
| | array, type="document" | - | **Not Supported** |
| | array, type="search_result" | - | **Not Supported** |
| | array, type="thinking" | - | **Supported** |
| | array, type="redacted_thinking" | - | **Not Supported** |
| | array, type="tool_use" | `id` | **Fully Supported** |
| | | `input` | **Fully Supported** |
| | | `name` | **Fully Supported** |
| | | `cache_control` | Ignored |
| | array, type="tool_result" | `tool_use_id` | **Fully Supported** |
| | | `content` | **Fully Supported** |
| | | `cache_control` | Ignored |
| | | `is_error` | Ignored |
| | array, type="server_tool_use" | - | **Not Supported** |
| | array, type="web_search_tool_result" | - | **Not Supported** |
| | array, type="code_execution_tool_result" | - | **Not Supported** |
| | array, type="mcp_tool_use" | - | **Not Supported** |
| | array, type="mcp_tool_result" | - | **Not Supported** |
| | array, type="container_upload" | - | **Not Supported** |

---

## 3. 对话补全 API

```
POST /chat/completions
```

### 3.1 Request Body

#### 必需参数

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `messages` | object[] | 对话消息列表，至少 1 条。包含 `system`、`user`、`assistant`、`tool` 四种 role。`content` 为消息内容，`role` 指定角色。可选 `name` 字段区分同角色参与者。 |
| `model` | string | 模型 ID。可选值: `deepseek-v4-flash`、`deepseek-v4-pro` |

#### 可选参数

| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `thinking` | object / null | `{"type": "enabled"}` | 控制思考模式。`type`: `"enabled"`（思考模式）或 `"disabled"`（非思考模式）。 |
| `reasoning_effort` | string | `"high"` | 控制推理强度。可选 `"high"`、`"max"`。对 Agent 类请求自动设为 `"max"`。兼容映射: `low`/`medium` -> `high`, `xhigh` -> `max`。 |
| `max_tokens` | integer / null | - | 模型生成的最大 token 数。输入+输出 token 总长受模型上下文长度限制。 |
| `response_format` | object / null | `{"type": "text"}` | `{"type": "json_object"}` 启用 JSON 模式，确保输出有效 JSON。需在 system/user 消息中指示模型生成 JSON，否则可能卡住。若 `finish_reason="length"` 表示内容可能被截断。 |
| `stop` | string / string[] / null | - | 字符串或最多 16 个字符串的列表，遇到时停止生成。 |
| `stream` | boolean / null | - | `true` 时以 SSE 流式发送消息增量。以 `data: [DONE]` 结尾。 |
| `stream_options` | object / null | - | 仅当 `stream=true` 时可用。`include_usage`: `true` 时在 `data: [DONE]` 前插入 usage 块。 |
| `temperature` | number / null | `1` | 采样温度，范围 [0, 2]。不建议同时修改 temperature 和 top_p。 |
| `top_p` | number / null | `1` | 核采样，范围 [0, 1]。不建议同时修改 temperature 和 top_p。 |
| `tools` | object[] / null | - | 工具列表，最多 128 个 function。每个 tool 包含 `type: "function"`、`function.name`、`function.description`、`function.parameters`（JSON Schema）、`function.strict`（Beta）字段。 |
| `tool_choice` | string / object / null | `auto`（有 tool 时） | 控制 tool 调用行为: `none`（不调用）、`auto`（可选）、`required`（必须调用），或指定 `{"type": "function", "function": {"name": "xxx"}}` 强制调用特定 tool。 |
| `logprobs` | boolean / null | - | `true` 时返回输出 token 的对数概率。 |
| `top_logprobs` | integer / null | - | 0-20，每个位置返回 top N token 的对数概率。需 `logprobs: true`。 |
| `user_id` | string / null | - | 自定义用户标识。字符集 `[a-zA-Z0-9\-_]`，最大 512 字符。用于内容安全处理、KVCache 缓存隔离、调度隔离。**不要包含用户隐私信息。** |

#### 已弃用参数

| 参数 | 说明 |
| --- | --- |
| `frequency_penalty` | 不再支持，传入无效果。 |
| `presence_penalty` | 不再支持，传入无效果。 |

### 3.2 Response Schema

```json
{
  "id": "string (required) — 对话唯一标识符",
  "object": "chat.completion (required)",
  "created": 1234567890,
  "model": "deepseek-v4-pro",
  "system_fingerprint": "string — 后端配置指纹",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "string | null",
        "reasoning_content": "string | null — 仅思考模式，最终答案前的推理内容",
        "tool_calls": [
          {
            "id": "string",
            "type": "function",
            "function": {
              "name": "string",
              "arguments": "string (JSON)"
            }
          }
        ]
      },
      "finish_reason": "stop | length | content_filter | tool_calls | insufficient_system_resource",
      "logprobs": {
        "content": [
          {
            "token": "string",
            "logprob": 0.0,
            "bytes": [72, 105],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0.0,
                "bytes": [72, 105]
              }
            ]
          }
        ],
        "reasoning_content": [
          {
            "token": "string",
            "logprob": 0.0,
            "bytes": [72, 105],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0.0,
                "bytes": [72, 105]
              }
            ]
          }
        ]
      }
    }
  ],
  "usage": {
    "completion_tokens": 100,
    "prompt_tokens": 50,
    "prompt_cache_hit_tokens": 20,
    "prompt_cache_miss_tokens": 30,
    "total_tokens": 150,
    "completion_tokens_details": {
      "reasoning_tokens": 80
    }
  }
}
```

### 3.3 finish_reason 枚举值

| 值 | 含义 |
| --- | --- |
| `stop` | 模型自然停止，或遇到 `stop` 序列 |
| `length` | 达到 `max_tokens` 或上下文长度限制 |
| `content_filter` | 触发内容过滤策略 |
| `tool_calls` | 模型需要调用 tool |
| `insufficient_system_resource` | 系统推理资源不足，生成被打断 |

### 3.4 消息块 logprobs 说明

- `logprob`: token 的对数概率。`-9999.0` 代表该 token 输出概率极小，不在 top 20 最可能输出的 token 中。
- `bytes`: token 的 UTF-8 字节表示。当一个 UTF-8 字符被拆分成多个 token 时有用。无对应字节表示则为 `null`。
- `top_logprobs`: 该位置 top N 个候选 token 及对数概率。返回数量可能少于 `top_logprobs` 参数值。

---

## 4. Tool Calls（函数调用）

Tool Calls 让模型能够调用外部工具来增强自身能力。支持思考模式和非思考模式。

### 4.1 基本流程（OpenAI 格式）

以获取天气信息为例：

1. **用户**: 询问天气
2. **模型**: 返回 function call `get_weather({location: "Hangzhou"})`
3. **用户**: 执行 `get_weather`，将结果传回模型（role="tool", tool_call_id, content）
4. **模型**: 返回自然语言回答

> **注意**: 模型本身不执行函数，函数功能需由用户提供。

### 4.2 完整示例代码（Python / OpenAI SDK）

```python
from openai import OpenAI

def send_messages(messages):
    response = client.chat.completions.create(
        model="deepseek-v4-pro",
        messages=messages,
        tools=tools
    )
    return response.choices[0].message

client = OpenAI(
    api_key="<your api key>",
    base_url="https://api.deepseek.com",
)

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get weather of a location, the user should supply a location first.",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA",
                    }
                },
                "required": ["location"]
            },
        }
    },
]

messages = [{"role": "user", "content": "How's the weather in Hangzhou, Zhejiang?"}]
message = send_messages(messages)
print(f"User>\t {messages[0]['content']}")

tool = message.tool_calls[0]
messages.append(message)

messages.append({"role": "tool", "tool_call_id": tool.id, "content": "24℃"})
message = send_messages(messages)
print(f"Model>\t {message.content}")
```

### 4.3 思考模式下的 Tool Calls

从 DeepSeek-V3.2 开始，API 支持思考模式下的工具调用能力。详见思考模式文档。

### 4.4 Strict 模式（Beta）

在 `strict` 模式下，模型输出的 Function 调用严格遵循 JSON Schema 格式要求，确保输出始终符合函数定义。

**启用条件**：
1. 设置 `base_url="https://api.deepseek.com/beta"` 开启 Beta 功能
2. 所有 `function` 均需设置 `strict: true`
3. 服务端会校验 JSON Schema，不符合规范则返回错误

**Strict 模式 Tool 定义样例**：

```json
{
    "type": "function",
    "function": {
        "name": "get_weather",
        "strict": true,
        "description": "Get weather of a location, the user should supply a location first.",
        "parameters": {
            "type": "object",
            "properties": {
                "location": {
                    "type": "string",
                    "description": "The city and state, e.g. San Francisco, CA"
                }
            },
            "required": ["location"],
            "additionalProperties": false
        }
    }
}
```

### 4.5 Strict 模式支持的 JSON Schema 类型

| 类型 | 支持情况 |
| --- | --- |
| object | 支持 |
| string | 支持 |
| number | 支持 |
| integer | 支持 |
| boolean | 支持 |
| array | 支持 |
| enum | 支持 |
| anyOf | 支持 |
| `$ref` / `$def` | 支持 |

#### object 类型约束

- **所有属性均需设置为 `required`**
- **`additionalProperties` 必须为 `false`**

```json
{
    "type": "object",
    "properties": {
        "name": { "type": "string" },
        "age": { "type": "integer" }
    },
    "required": ["name", "age"],
    "additionalProperties": false
}
```

#### string 类型约束

**支持的参数**：
- `pattern`: 正则表达式约束格式
- `format`: 预定义格式校验，支持 `email`、`hostname`、`ipv4`、`ipv6`、`uuid`

**不支持的参数**: `minLength`、`maxLength`

```json
{
    "type": "object",
    "properties": {
        "user_email": {
            "type": "string",
            "description": "The user's email address",
            "format": "email"
        },
        "zip_code": {
            "type": "string",
            "description": "Six digit postal code",
            "pattern": "^\\d{6}$"
        }
    }
}
```

#### number / integer 类型约束

**支持的参数**: `const`、`default`、`minimum`、`maximum`、`exclusiveMinimum`、`exclusiveMaximum`、`multipleOf`

```json
{
    "type": "object",
    "properties": {
        "score": {
            "type": "integer",
            "description": "A number from 1-5, which represents your rating, the higher, the better",
            "minimum": 1,
            "maximum": 5
        }
    },
    "required": ["score"],
    "additionalProperties": false
}
```

#### array 类型约束

**不支持的参数**: `minItems`、`maxItems`

```json
{
    "type": "object",
    "properties": {
        "keywords": {
            "type": "array",
            "description": "Five keywords of the article, sorted by importance",
            "items": {
                "type": "string",
                "description": "A concise and accurate keyword or phrase."
            }
        }
    },
    "required": ["keywords"],
    "additionalProperties": false
}
```

#### enum

确保输出是有限的几个选项之一：

```json
{
    "type": "object",
    "properties": {
        "order_status": {
            "type": "string",
            "description": "Ordering status",
            "enum": ["pending", "processing", "shipped", "cancelled"]
        }
    }
}
```

#### anyOf

匹配多个 schema 中的任意一个：

```json
{
    "type": "object",
    "properties": {
        "account": {
            "anyOf": [
                { "type": "string", "format": "email", "description": "可以是电子邮件地址" },
                { "type": "string", "pattern": "^\\d{11}$", "description": "或11位手机号码" }
            ]
        }
    }
}
```

#### $ref 和 $def

支持定义可复用模块和递归结构：

```json
{
    "type": "object",
    "properties": {
        "report_date": {
            "type": "string",
            "description": "The date when the report was published"
        },
        "authors": {
            "type": "array",
            "description": "The authors of the report",
            "items": {
                "$ref": "#/$def/author"
            }
        }
    },
    "required": ["report_date", "authors"],
    "additionalProperties": false,
    "$def": {
        "author": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "author's name"
                },
                "institution": {
                    "type": "string",
                    "description": "author's institution"
                },
                "email": {
                    "type": "string",
                    "format": "email",
                    "description": "author's email"
                }
            },
            "additionalProperties": false,
            "required": ["name", "institution", "email"]
        }
    }
}
```

---

## 5. 错误码

| 错误码 | 原因 | 解决方法 |
| --- | --- | --- |
| **400 - 格式错误** | 请求体格式错误 | 根据错误信息提示修改请求体 |
| **401 - 认证失败** | API key 错误，认证失败 | 检查 API key 是否正确。如无 API key，请先创建。 |
| **402 - 余额不足** | 账号余额不足 | 确认账户余额，前往充值页面充值 |
| **422 - 参数错误** | 请求体参数错误 | 根据错误信息提示修改相关参数 |
| **429 - 请求速率达到上限** | 请求速率（TPM 或 RPM）达到上限 | 合理规划请求速率 |
| **500 - 服务器故障** | 服务器内部故障 | 等待后重试。若持续存在，联系官方。 |
| **503 - 服务器繁忙** | 服务器负载过高 | 稍后重试 |

---

## 6. Token 用量

### 6.1 Token 定义

Token 是模型用来表示自然语言文本的基本单位，也是计费单元。

换算比例（近似）：
- **1 个英文字符 ≈ 0.3 个 token**
- **1 个中文字符 ≈ 0.6 个 token**

不同模型分词存在差异，实际 token 数量以返回结果的 `usage` 字段为准。

### 6.2 离线计算

DeepSeek 提供 `deepseek_tokenizer.zip` 用于离线计算文本的 Token 用量。

### 6.3 Usage 响应字段

| 字段 | 说明 |
| --- | --- |
| `completion_tokens` | 模型 completion 产生的 token 数 |
| `prompt_tokens` | 用户 prompt 的 token 数（= `prompt_cache_hit_tokens` + `prompt_cache_miss_tokens`） |
| `prompt_cache_hit_tokens` | 命中上下文缓存的 token 数 |
| `prompt_cache_miss_tokens` | 未命中上下文缓存的 token 数 |
| `total_tokens` | 总 token 数（prompt + completion） |
| `completion_tokens_details.reasoning_tokens` | 推理模型产生的思维链 token 数量 |

---

## 7. 本项目相关要点

### DeepSeek Anthropic 兼容 API vs 官方 Anthropic API 关键差异

本项目通过 Sidecar (C++) 调用 DeepSeek 的 Anthropic 兼容 API（`https://api.deepseek.com/anthropic`），与官方 Anthropic API 相比存在以下关键差异：

1. **Base URL**: 必须使用 `https://api.deepseek.com/anthropic`，而非 `https://api.anthropic.com`。

2. **Model 名称**: 必须使用 DeepSeek 模型名（`deepseek-v4-pro` / `deepseek-v4-flash`）。传入不支持的模型名会自动 fallback 到 `deepseek-v4-flash`，可能导致非预期行为。

3. **Thinking / Extended Thinking**:
   - `thinking` 参数支持，但 **`budget_tokens` 被忽略**，无法像 Anthropic 官方那样精确控制思考 token 预算。
   - 不支持 `redacted_thinking` 类型块。
   - 通过 `reasoning_effort`（`high` / `max`）控制推理深度，而非 Anthropic 官方的 token budget 方式。

4. **`top_k`**: **不支持**，传入被忽略。DeepSeek 只支持 `temperature` 和 `top_p`。

5. **`cache_control`**: **完全忽略**。DeepSeek 不支持 Anthropic 的 prompt caching 机制（DeepSeek 有独立的 Context Caching 功能，需另外查阅文档）。

6. **`is_error` (tool_result)**: **被忽略**。若 tool 执行出错，无法通过 `is_error: true` 标记，需在 `content` 中以文本形式传达错误信息。

7. **多媒体内容（image / document）**: **不支持**。只能发送文本和 tool 消息。

8. **MCP / Server Tool / Web Search / Code Execution 等高级块类型**: **均不支持**。DeepSeek Anthropic 端点仅支持基础的 `text`、`tool_use`、`tool_result`、`thinking` 块。

9. **`disable_parallel_tool_use`**: **被忽略**。DeepSeek 在某些场景下可能会并行调用多个 tool。

10. **`metadata.user_id`**: 仅 `user_id` 被支持，可用于 KVCache 缓存隔离和调度隔离，对多用户场景有价值。其他 metadata 字段被忽略。

11. **弃用参数**: `frequency_penalty` 和 `presence_penalty` 在 OpenAI 兼容端点中已弃用且无效果。

12. **Strict 模式**: 需单独配置 `base_url="https://api.deepseek.com/beta"`，且 JSON Schema 约束比标准 JSON Schema 更严格（所有 object 属性必须 required、additionalProperties: false、string 不支持 minLength/maxLength、array 不支持 minItems/maxItems）。

13. **`anthropic-version` / `anthropic-beta` headers**: 均被忽略，DeepSeek 不处理这些版本控制 headers。

14. **Temperature 范围**: [0.0 ~ 2.0]，比 Anthropic 官方（0.0 ~ 1.0）更宽。

15. **tool_result content 格式**: Anthropic API 规范要求 `content` 为数组 `[{type:"tool_result", ...}]`。DeepSeek 声明 "Fully Supported"，但实际使用中建议严格遵循 Anthropic 官方格式（content 使用数组），避免 HTTP 400 错误。

---

## 8. 来源

| 页面 | URL | 抓取状态 |
| --- | --- | --- |
| 首次调用 API | [zh-cn/](https://api-docs.deepseek.com/zh-cn/) | 成功 |
| Anthropic API 兼容性（中文） | [zh-cn/guides/anthropic_api](https://api-docs.deepseek.com/zh-cn/guides/anthropic_api) | 成功 |
| Anthropic API（英文补充） | [guides/anthropic_api](https://api-docs.deepseek.com/guides/anthropic_api) | 成功 |
| 对话补全 API | [zh-cn/api/create-chat-completion](https://api-docs.deepseek.com/zh-cn/api/create-chat-completion) | 成功 |
| Tool Calls | [zh-cn/guides/tool_calls](https://api-docs.deepseek.com/zh-cn/guides/tool_calls) | 成功（第 3 次重试成功） |
| 错误码 | [zh-cn/quick_start/error_codes](https://api-docs.deepseek.com/zh-cn/quick_start/error_codes) | 成功 |
| Token 用量 | [zh-cn/quick_start/token_usage](https://api-docs.deepseek.com/zh-cn/quick_start/token_usage) | 成功 |
