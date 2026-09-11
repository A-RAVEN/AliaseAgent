# DeepSeek API 参考文档

> **抓取时间**: 2026-09-10
> **来源**: DeepSeek 官方 API 文档站（`https://api-docs.deepseek.com/zh-cn/`），本文全部内容均由 `web_fetch` 于本次实际抓取（见 §8 来源表），逐字搬运，**未使用任何记忆、先验知识或推测内容**。
> **已知缺口**: 官方「对话补全 API」页面在抓取时被工具截断，其响应示例 JSON 与 `200 (Streaming)` 部分**未能抓取到**，已在 §3.4 / §8 明确标注；官方「思考模式」页面同样在末尾被截断（§2.7）。

---

## 1. 概述

DeepSeek API 使用与 OpenAI/Anthropic 兼容的 API 格式，通过修改配置，您可以使用 OpenAI/Anthropic SDK 来访问 DeepSeek API，或使用与 OpenAI/Anthropic API 兼容的软件。

### 1.1 base_url 与基本参数

| PARAM | VALUE |
| --- | --- |
| base_url (OpenAI) | `https://api.deepseek.com` |
| base_url (Anthropic) | `https://api.deepseek.com/anthropic` |
| api_key | 申请一个 [API key](https://platform.deepseek.com/api_keys) |
| model | `deepseek-flash`(1)<br>`deepseek-v4-pro`(2) |

(1) 模型名请使用 `deepseek-flash`。旧模型名 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍可调用，但对应模型已下线，请求将由 DeepSeek-V4.1-Flash 模型提供服务，并按 Flash 价格计费。

(2) 经多方测试，V4.1 Flash 在性能、费用、速度、总用时等各项指标上已全面超越 V4 Pro，因此我们计划有序下线 V4 Pro。北京时间 2026 年 9 月 14 日 12:00 之后，至未来 V4.1 Pro 上线之前，您访问 `deepseek-v4-pro` 的请求将全部路由到 V4.1 Flash，并按 V4.1 Flash 价格计费。

> 补充（来自 §4 Tool Calls 页面）：`strict` 模式等 Beta 功能需要设置 `base_url="https://api.deepseek.com/beta"` 来开启。（原文见 §4.4）

### 1.2 可用模型列表

| 模型 ID | 说明（原文照录） |
| --- | --- |
| `deepseek-flash` | 官方推荐使用的模型名 |
| `deepseek-v4-pro` | 计划有序下线；2026-09-14 12:00（北京时间）后请求全部路由到 V4.1 Flash，并按 V4.1 Flash 价格计费 |

> 官方「对话补全 API」页面对 `model` 字段的枚举值为：**Possible values:** [`deepseek-flash`, `deepseek-v4-pro`]（详见 §3.1）。
>
> **注意**：当您给 DeepSeek 的 Anthropic API 传入不支持的模型名时，API 后端会自动将其映射到 `deepseek-flash` 模型。

### 1.3 接入 Agent 工具

DeepSeek Harness 开发者预览版面向全球 Harness 开发者开放测试。详见 [DeepSeek Harness 入门](https://deepseek-harness.github.io/deepseek-harness/guide/quickstart)。

DeepSeek API 已接入多种主流 AI Agent 与编程助手工具。如果你使用 Claude Code、GitHub Copilot、OpenCode 等工具，可以直接将 DeepSeek 作为后端模型，无需编写代码即可开始使用。详见 [Agent 工具接入指南](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code)。

### 1.4 调用对话 API（OpenAI 格式，curl）

在创建 API key 之后，你可以使用以下样例脚本，通过 OpenAI API 格式来访问 DeepSeek 模型。样例为非流式输出，您可以将 stream 设置为 true 来使用流式输出。

```bash
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
  -d '{
        "model": "deepseek-flash",
        "messages": [
          {"role": "system", "content": "You are a helpful assistant."},
          {"role": "user", "content": "Hello!"}
        ],
        "thinking": {"type": "enabled"},
        "reasoning_effort": "high",
        "stream": false
      }'
```

> 抓取说明：官方页面的 curl 代码块在被 `web_fetch` 提取时换行被压平为一行；以上按语句边界还原了换行，**未增删任何字符内容**。全文所有还原换行的代码块同理（§2.7、§4.1 已另行标注）。

---

## 2. Anthropic API 兼容性（重点）

为了满足大家对 Anthropic API 生态的使用需求，我们的 API 新增了对 Anthropic API 格式的支持，其 `base_url` 为 `https://api.deepseek.com/anthropic`。

通过简单的配置，即可将 DeepSeek 的能力，接入到 Anthropic API 生态中。

### 2.1 通过 Anthropic API 调用 DeepSeek 模型

1. 安装 Anthropic SDK

```bash
pip install anthropic
```

2. 配置环境变量

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_API_KEY=${YOUR_API_KEY}
```

3. 调用 API

```python
import anthropic
client = anthropic.Anthropic()
message = client.messages.create(
    model="deepseek-flash",
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

**注意**：当您给 DeepSeek 的 Anthropic API 传入不支持的模型名时，API 后端会自动将其映射到 `deepseek-flash` 模型。

### 2.2 Anthropic 模型映射

您在使用 Anthropic API 时，我们会对您传入的 claude 模型名进行映射：

- claude-opus 开头的模型，会映射到 `deepseek-v4-pro`
- claude-haiku、claude-sonnet 开头的模型，会映射到 `deepseek-flash`

claude-opus 映射到的 `deepseek-v4-pro` 在 2026 年 9 月 14 日 12:00 之前仍按 V4 Pro 价格计费；此后 `deepseek-v4-pro` 也将路由到 V4.1 Flash，并按 Flash 价格计费。

通过这样的映射，您在使用新版 Claude Desktop APP 的 developer 模式时，可以绕过 APP 对模型名的限制，只需改动 base_url 和 api_key，即可在其中接入 DeepSeek 模型。

### 2.3 HTTP Header

| 字段 | 支持情况 |
| --- | --- |
| anthropic-beta | `/messages` 忽略；Files API 端点必须携带（`files-api-2025-04-14`）——见 [Files API](https://api-docs.deepseek.com/zh-cn/guides/files_api#anthropic-compatible-files-api) |
| anthropic-version | 忽略 |
| x-api-key | 完全支持 |

### 2.4 简单字段（Simple Fields）

| 字段 | 支持情况 |
| --- | --- |
| model | 改为使用 DeepSeek 模型 |
| max_tokens | 完全支持 |
| container | 忽略 |
| mcp_servers | 忽略 |
| metadata | 支持 `user_id`，其它字段忽略<br>关于 `user_id` 参数的更多信息，请参考 [限速与隔离](https://api-docs.deepseek.com/zh-cn/quick_start/rate_limit)。 |
| service_tier | 忽略 |
| stop_sequences | 完全支持 |
| stream | 完全支持 |
| system | 完全支持 |
| temperature | 完全支持（范围 [0.0 ~ 2.0]） |
| thinking | 支持（`budget_tokens` 被忽略） |
| output_config | 仅支持 `effort` |
| top_k | 忽略 |
| top_p | 仅思考模式下生效（下限为 `0.95`）；非思考模式下恒为 `1.0` |

### 2.5 Tool 字段（Tool Fields）

#### tools

| 字段 | 支持情况 |
| --- | --- |
| name | 完全支持 |
| input_schema | 完全支持 |
| description | 完全支持 |
| cache_control | 忽略 |

#### tool_choice

| 取值 | 支持情况 |
| --- | --- |
| none | 完全支持 |
| auto | 支持（`disable_parallel_tool_use` 被忽略） |
| any | 支持（`disable_parallel_tool_use` 被忽略） |
| tool | 支持（`disable_parallel_tool_use` 被忽略） |

### 2.6 Message 字段（Message Fields，完整对照表）

| 字段 | 变体 | 子字段 | 支持情况 |
| --- | --- | --- | --- |
| content | string |  | 完全支持 |
| content | array, type="text" | text | 完全支持 |
| content | array, type="text" | cache_control | 忽略 |
| content | array, type="text" | citations | 忽略 |
| content | array, type="image" | source | 支持。`source.type` 可为 base64（媒体类型：jpeg、png、gif、webp）、url 或 file（file 形式需带请求头 `anthropic-beta: files-api-2025-04-14`） |
| content | array, type = "document" |  | 不支持 |
| content | array, type = "search_result" |  | 不支持 |
| content | array, type = "thinking" |  | 支持 |
| content | array, type="redacted_thinking" |  | 不支持 |
| content | array, type = "tool_use" | id | 完全支持 |
| content | array, type = "tool_use" | input | 完全支持 |
| content | array, type = "tool_use" | name | 完全支持 |
| content | array, type = "tool_use" | cache_control | 忽略 |
| content | array, type = "tool_result" | tool_use_id | 完全支持 |
| content | array, type = "tool_result" | content | 完全支持 |
| content | array, type = "tool_result" | cache_control | 忽略 |
| content | array, type = "tool_result" | is_error | 忽略 |
| content | array, type = "server_tool_use" |  | 支持 |
| content | array, type = "web_search_tool_result" |  | 支持 |
| content | array, type = "code_execution_tool_result" |  | 不支持 |
| content | array, type = "mcp_tool_use" |  | 不支持 |
| content | array, type = "mcp_tool_result" |  | 不支持 |
| content | array, type = "container_upload" |  | 不支持 |

> **表格结构说明**：官方页面的 Message Fields 表为 4 列（`字段 | 变体 | 子字段 | 支持情况`），其中「字段」列首行为 `content`，后续各行的该列为空白（同一 `content` 字段的各个变体）。上表已按此逻辑显式补齐 `content`，**未合并、未删减任何变体或子字段**，支持情况文字逐字照录。
>
> **中英文对照核验**：本次同时抓取了英文版 `https://api-docs.deepseek.com/guides/anthropic_api`，其上列 HTTP Header / Simple Fields / Tool Fields / Message Fields 四张表与中文版条目一一对应、内容一致（英文为 "Fully Supported / Ignored / Not Supported / Supported"），可交叉确证。

### 2.7 思考模式（Thinking）相关（来自官方「思考模式」指南）

#### 2.7.1 思考模式开关与思考强度控制

官方页面原始表格为 4 列（空表头 + OpenAI 格式 / Anthropic 格式 / Responses API 格式），抓取时部分空单元格丢失，**列归属无法完全确定**。以下按抓取到的原始单元格顺序照录：

| 项 | 抓取到的控制参数 |
| --- | --- |
| 思考模式开关(1) | `{"thinking": {"type": "enabled/disabled"}}`；`{"reasoning": {"effort": "none/low/high/max"}}`（none 表示关闭思考模式） |
| 思考强度控制(2) | `{"reasoning_effort": "low/high/max"}`；`{"output_config": {"effort": "low/high/max"}}` |

(1) 思考模式默认打开，且 effort 默认为 `high`
(2) 用户设置的 effort 与模型推理 effort 映射表如下：

| 请求传入 effort | 实际映射 effort |
| --- | --- |
| minimal | low |
| low | low |
| medium | high |
| high | high |
| xhigh | high |
| max | max |
| ultra | max |

> 交叉确证（依据本次抓取到的其它官方页面原文）：
> - `{"thinking": {"type": ...}}` 属 **OpenAI 格式**：本页示例将其放入 `extra_body`，原文为 `extra_body={"thinking": {"type": "enabled"}}`；
> - `{"output_config": {"effort": ...}}` 属 **Anthropic 格式**：§2.4 简单字段表载明 Anthropic 的 `output_config`「仅支持 `effort`」；
> - `{"reasoning": {"effort": ...}}` 与 Responses API 相关：本页表头列名为「Responses API 格式」。
> 以上仅为**列的归属**提供已抓取原文的旁证；列归属本身在抓取结果中有歧义，如与官方页面显示不一致，请以官方页面为准。

#### 2.7.2 在 OpenAI SDK 中设置 thinking 参数

```
response = client.chat.completions.create(
  model="deepseek-flash",
  # ...
  reasoning_effort="high",
  extra_body={"thinking": {"type": "enabled"}}
)
```

#### 2.7.3 输入输出参数

思考模式不支持 `temperature`、`presence_penalty`、`frequency_penalty` 参数。请注意，为了兼容已有软件，设置参数不会报错，但也不会生效。

`top_p` 在思考模式下生效，但下限为 `0.95`：小于 `0.95` 的值会被抬升至 `0.95`。在非思考模式下，该参数恒为 `1.0`，传入的值会被忽略。

在思考模式下，思维链内容通过 `reasoning_content` 参数返回，与 `content` 同级。在后续轮次的请求中，`reasoning_content` 是否需要回传、是否会被拼接进上下文，取决于请求是否携带 `tools` 参数：

- 若请求**携带 `tools` 参数**：历史轮次的 `reasoning_content` 均应回传给 API，并会被拼接进上下文。
- 若请求**未携带 `tools` 参数**：`reasoning_content` 无需回传；即使传入 API，也会被忽略，不会拼接进上下文。

#### 2.7.4 工具调用（思考模式）

DeepSeek 模型的思考模式支持工具调用功能。模型在输出最终答案之前，可以进行多轮的思考与工具调用，以提升答案的质量。

请注意，携带了 `tools` 参数的请求，在后续所有请求中，必须完整回传 `reasoning_content` 给 API——即使该轮模型未实际进行工具调用。若您的代码中未正确回传 `reasoning_content`，API 会返回 400 报错。

`response.choices[0].message` 携带了 `assistant` 消息的所有必要字段，包括 `content`、`reasoning_content`、`tool_calls`。简单起见，可以直接用如下代码将消息 append 到 messages 结尾：

```
messages.append(response.choices[0].message)
```

这行代码等价于：

```
messages.append({
    'role': 'assistant',
    'content': response.choices[0].message.content,
    'reasoning_content': response.choices[0].message.reasoning_content,
    'tool_calls': response.choices[0].message.tool_calls,
})
```

> **抓取缺口**：官方「思考模式」页面（`https://api-docs.deepseek.com/zh-cn/guides/thinking_mode`）在本次抓取中同样被工具截断，其**流式样例代码及其后内容未能抓取到**，本节仅覆盖已抓取到的部分。本页中的长篇样例代码未收录（未抓全，避免断章取义）。

#### 2.7.5 本地实测记录（非官方抓取）

> ⚠️ **本小节不是官方文档内容**。来源为本项目 2026-08-26 的 live 探测，用于补齐官方页面未覆盖、且与官方表格存在冲突的端点行为。**引用时不得当作官方记载**；官方内容以 §2.7.1–§2.7.4 及官方页面为准。

**探测条件**：`POST https://api.deepseek.com/anthropic/v1/messages`，model `deepseek-v4-pro`，同一消息、3 种字段配置对比。

| 结论 | 实测结果 |
| --- | --- |
| `{"thinking":{"type":"disabled"}}` | ✅ 在 `/v1/messages` 上**确实关闭思考**（响应无 thinking block） |
| `reasoning.effort="none"`（或 `reasoning_effort`） | ❌ 在 `/v1/messages` 上**不关闭思考**（仍返回 reasoning block）——该字段属 OpenAI / chat-completions 路径 |
| 思考默认状态 | 默认**开启**，默认 effort `high`（不发送 `thinking` 字段时，响应含 thinking block）→ **缺席 ≠ 关闭** |
| `/v1/messages` 的强度控制字段 | `output_config.effort`（`low` / `high` / `max`） |
| `{"thinking":{"type":"adaptive","display":"summarized"}}` | 端点接受并返回完整 thinking 流（thinking_delta 增量）；但 **DeepSeek 官方文档未记载该格式**，仅 `output_config.effort` 有官方依据。本项目交互路径即使用此写法 |

> **与 §2.7.1 官方表格的冲突提示**：§2.7.1 照录的官方表格把 `{"reasoning":{"effort":"none/low/high/max"}}`（`none` 表示关闭思考模式）列在「思考模式开关」一行。但本项目 live 实测表明，**在 Anthropic 兼容端点 `/v1/messages` 上该写法不生效**——开关必须用 `thinking.type`，`reasoning.effort` 仅对 OpenAI / chat-completions 路径有效。
>
> 本项目实际走 `https://api.deepseek.com/anthropic`（Anthropic 路径），故禁用思考统一使用 `{"thinking":{"type":"disabled"}}`。§2.7.1 自身也已标注该表的列归属存在歧义，两节请结合阅读。

---

## 3. 对话补全 API

`POST /chat/completions` —— 根据输入的上下文，来让模型补全对话内容。

请求体类型：`application/json`。

### 3.1 Request Body

| 参数 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `messages` | object[] | **required** | 对话的消息列表。**Possible values:** `>= 1`。数组元素 `oneOf` 四个变体：**System message / User message / Assistant message / Tool message**。（抓取到的字段明细仅展开了 System message 变体，见下方说明） |
| `model` | string | **required** | 使用的模型的 ID。请使用 `deepseek-flash` 或 `deepseek-v4-pro`。**Possible values:** [`deepseek-flash`, `deepseek-v4-pro`] |
| `thinking` | object \| nullable | 否 | 控制思考模式与非思考模式的转换 |
| `thinking.type` | string | 否 | **Possible values:** [`enabled`, `disabled`]；**Default value:** `enabled`。如果设为 `enabled`，则使用思考模式。如果设为 `disabled`，则使用非思考模式 |
| `reasoning_effort` | string | 否 | **Possible values:** [`none`, `low`, `high`, `max`]。控制思考模式开关与思考强度。`none` 关闭思考模式；`low` / `high` / `max` 开启思考模式。默认强度为 `high`。出于兼容考虑，`minimal` 映射为 `low`，`medium` / `xhigh` 映射为 `high`。 |
| `max_tokens` | integer \| nullable | 否 | 限制一次请求中模型生成 completion 的最大 token 数。取值范围为 1 到 384K（393216）。未设置时，非思考模式默认 8K，思考模式默认 64K（`reasoning_effort` 为 `max` 时为 128K）。输入 token 和输出 token 的总长度受模型的上下文长度的限制。 |
| `response_format` | object \| nullable | 否 | 一个 object，指定模型必须输出的格式。设置为 `{ "type": "json_object" }` 以启用 JSON 模式，该模式保证模型生成的消息是有效的 JSON。 |
| `response_format.type` | string | 否 | **Possible values:** [`text`, `json_object`]；**Default value:** `text`。Must be one of `text` or `json_object`. |
| `stop` | object \| **nullable** | 否 | 一个 string 或最多包含 16 个 string 的 list，在遇到这些词时，API 将停止生成更多的 token。`oneOf`: MOD1 / MOD2（string） |
| `stream` | boolean \| nullable | 否 | 如果设置为 True，将会以 SSE（server-sent events）的形式以流式发送消息增量。消息流以 `data: [DONE]` 结尾。 |
| `stream_options` | object \| nullable | 否 | 流式输出相关选项。必须与 `stream: true` 一起使用；如果 `stream` 未设置为 `true`，API 会返回 `400` 错误。 |
| `stream_options.include_usage` | boolean | 否 | 见下方「include_usage 语义」 |
| `temperature` | number \| nullable | 否 | **Possible values:** `<= 2`；**Default value:** `1`。采样温度，介于 0 和 2 之间。更高的值，如 0.8，会使输出更随机，而更低的值，如 0.2，会使其更加集中和确定。我们通常建议可以更改这个值或者更改 `top_p`，但不建议同时对两者进行修改。思考模式下不生效。 |
| `top_p` | number \| nullable | 否 | **Possible values:** `<= 1`；**Default value:** `1`。作为调节采样温度的替代方案，模型会考虑前 `top_p` 概率的 token 的结果。所以 0.1 就意味着只有包括在最高 10% 概率中的 token 会被考虑。取值必须大于 0 且不超过 1。我们通常建议修改这个值或者更改 `temperature`，但不建议同时对两者进行修改。该参数在思考模式下生效，但小于 0.95 的值会被抬升至 0.95；在非思考模式下恒为 1.0，传入的值会被忽略。 |
| `tools` | object[] \| nullable | 否 | 模型可能会调用的 tool 的列表。目前，仅支持 function 作为工具。使用此参数来提供以 JSON 作为输入参数的 function 列表。tool 名称必须唯一。 |
| `tools[].type` | string | **required** | **Possible values:** [`function`]。tool 的类型。目前仅支持 function。 |
| `tools[].function` | object | **required** | — |
| `tools[].function.description` | string | 否 | function 的功能描述，供模型理解何时以及如何调用该 function。 |
| `tools[].function.name` | string | **required** | 要调用的 function 名称。必须由 a-z、A-Z、0-9 字符组成，或包含下划线和连字符，最大长度为 128 个字符。 |
| `tools[].function.parameters` | object | 否 | function 的输入参数，以 JSON Schema 对象描述。请参阅 Tool Calls 指南获取示例，并参阅 JSON Schema 参考了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。 |
| `tools[].function.parameters.property name*` | any | 否 | function 的输入参数，以 JSON Schema 对象描述。（同上说明） |
| `tools[].function.strict` | boolean | 否 | **Default value:** `false`。如果设置为 true，API 将在函数调用中使用 strict 模式，以确保输出始终符合函数的 JSON schema 定义。该功能为 Beta 功能。 |
| `tool_choice` | object \| **nullable** | 否 | 控制模型调用 tool 的行为（详见下方「tool_choice 语义」）。`oneOf`: ChatCompletionToolChoice / ChatCompletionNamedToolChoice；string **Possible values:** [`none`, `auto`, `required`] |
| `logprobs` | boolean \| nullable | 否 | 是否返回所输出 token 的对数概率。如果为 true，则在 `message` 的 `content` 中返回每个输出 token 的对数概率。 |
| `top_logprobs` | integer \| nullable | 否 | **Possible values:** `<= 20`。一个介于 0 到 20 之间的整数 N，指定每个输出位置返回输出概率 top N 的 token，且返回这些 token 的对数概率。指定此参数时，logprobs 必须为 true。 |
| `user_id` | nullable | 否 | 您自定义的 user_id，可选字符集为 `[a-zA-Z0-9\-_]`，最大长度为 512。请不要在 user_id 中包含用户隐私信息。 |
| `frequency_penalty` | **deprecated** | — | 该参数已不再支持。传入该参数将不会产生任何效果。 |
| `presence_penalty` | **deprecated** | — | 该参数已不再支持。传入该参数将不会产生任何效果。 |

#### messages 数组说明

官方 schema 中 `messages` 的 `oneOf` 声明了四个变体：**System message / User message / Assistant message / Tool message**。抓取到的页面文本**只展开了 System message 变体的字段明细**：

| 字段 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `content` | string | **required** | system 消息的内容。 |
| `role` | string | **required** | **Possible values:** [`system`]。该消息的发起角色，其值为 `system`。 |
| `name` | string | 否 | 可以选填的参与者的名称，为模型提供信息以区分相同角色的参与者。 |

> **诚实标注**：User message / Assistant message / Tool message 三个变体的字段明细在本次抓取到的页面文本中**未展开**（属于官方页面的折叠区块），因此**本文件不列其字段**。`role: "tool"` 与 `tool_call_id` 的用法可在 §4.1 的官方样例代码中看到（`{"role": "tool", "tool_call_id": tool.id, "content": "24℃"}`）。

#### tool_choice 语义（原文照录）

控制模型调用 tool 的行为。

- `none` 意味着模型不会调用任何 tool，而是生成一条消息。
- `auto` 意味着模型可以选择生成一条消息或调用一个或多个 tool。
- `required` 意味着模型必须调用一个或多个 tool。
- 通过 `{"type": "function", "function": {"name": "my_function"}}` 指定特定 tool，会强制模型调用该 tool。
- 当没有 tool 时，默认值为 `none`。如果有 tool 存在，默认值为 `auto`。
- **思考模式下不支持 `required` 和指定具体 tool 的用法，API 会返回 `400` 错误。请先关闭思考模式。**

#### include_usage 语义（原文照录）

如果设置为 `true`，流式返回的所有块都会包含 `usage` 字段，其中除最后一个块外，该字段的值均为 `null`。如果不设置或设置为 `false`，则除最后一个块外，其余块都不含 `usage` 字段。

无论是否设置，`data: [DONE]` 之前的最后一个块都会在其 `usage` 字段中给出整个请求的 token 使用统计信息。请注意，这里不会单独下发一个只含 usage 的块：统计信息附加在最后一个内容块上，该块的 `choices` 数组始终只包含一个元素，其中不含新增内容且 `finish_reason` 非 null。

#### response_format 注意事项（原文照录）

**注意:** 使用 JSON 模式时，你还必须通过系统或用户消息指示模型生成 JSON。否则，模型可能会生成不断的空白字符，直到生成达到令牌限制，从而导致请求长时间运行并显得“卡住”。此外，如果 finish_reason="length"，这表示生成超过了 max_tokens 或对话超过了最大上下文长度，消息内容可能会被部分截断。

#### user_id 用途（原文照录）

- user_id 可用于区分您业务侧的用户身份，以帮助我们进行内容安全处理。
- user_id 可用于 KVCache 缓存隔离，以进行隐私管理。
- user_id 可用于我们对您业务侧用户进行调度隔离。

### 3.2 Response Schema（200, No streaming）

OK, 返回一个 `chat completion` 对象。响应类型：`application/json`。页面提供三个标签页：`Schema` / `Example (from schema)` / `Example`。

| 字段路径 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `id` | string | required | 该对话的唯一标识符。 |
| `choices` | object[] | required | 模型生成的 completion 的选择列表。 |
| `choices[].finish_reason` | string | required | **Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`, `aborted`]（逐项含义见 §3.3） |
| `choices[].index` | integer | required | 该 completion 在模型生成的 completion 的选择列表中的索引。 |
| `choices[].message` | object | required | 模型生成的 completion 消息。 |
| `choices[].message.content` | string \| nullable | required | 该 completion 的内容。 |
| `choices[].message.reasoning_content` | string \| nullable | 否 | 仅适用于思考模式。内容为 assistant 消息中在最终答案之前的推理内容。 |
| `choices[].message.tool_calls` | object[] | 否 | 模型生成的 tool 调用，例如 function 调用。 |
| `choices[].message.tool_calls[].id` | string | required | tool 调用的 ID。 |
| `choices[].message.tool_calls[].type` | string | required | **Possible values:** [`function`]。tool 的类型。目前仅支持 `function`。 |
| `choices[].message.tool_calls[].function` | object | required | 模型调用的 function。 |
| `choices[].message.tool_calls[].function.name` | string | required | 模型调用的 function 名。 |
| `choices[].message.tool_calls[].function.arguments` | string | required | 要调用的 function 的参数，由模型生成，格式为 JSON。请注意，模型并不总是生成有效的 JSON，并且可能会臆造出你函数模式中未定义的参数。在调用函数之前，请在代码中验证这些参数。 |
| `choices[].message.role` | string | required | **Possible values:** [`assistant`]。生成这条消息的角色。 |
| `choices[].logprobs` | object \| nullable | required | 该 choice 的对数概率信息。 |
| `choices[].logprobs.content` | object[] \| nullable | required | 一个包含输出 token 对数概率信息的列表。 |
| `choices[].logprobs.content[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.content[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.content[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.content[].top_logprobs` | object[] | required | 一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。 |
| `choices[].logprobs.content[].top_logprobs[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.content[].top_logprobs[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。（同上说明） |
| `choices[].logprobs.reasoning_content` | object[] \| nullable | 否 | 一个包含输出 token 对数概率信息的列表。 |
| `choices[].logprobs.reasoning_content[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。（同上说明） |
| `choices[].logprobs.reasoning_content[].top_logprobs` | object[] | required | 一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。（同上说明） |
| `choices[].logprobs.reasoning_content[].top_logprobs[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。（同上说明） |
| `created` | integer | required | 创建聊天完成时的 Unix 时间戳（以秒为单位）。 |
| `model` | string | required | 生成该 completion 的模型名。 |
| `system_fingerprint` | string | required | This fingerprint represents the backend configuration that the model runs with.（官方中文页此描述为英文原文） |
| `object` | string | required | **Possible values:** [`chat.completion`]。对象的类型, 其值为 `chat.completion`。 |
| `usage` | object | 否 | 该对话补全请求的用量信息。 |
| `usage.completion_tokens` | integer | required | 模型 completion 产生的 token 数。 |
| `usage.prompt_tokens` | integer | required | 用户 prompt 所包含的 token 数。该值等于 `prompt_cache_hit_tokens + prompt_cache_miss_tokens` |
| `usage.prompt_tokens_details` | object | required | prompt tokens 的详细信息。 |
| `usage.prompt_tokens_details.cached_tokens` | integer | 否 | 用户 prompt 中，命中上下文缓存的 token 数。与 `prompt_cache_hit_tokens` 相同。 |
| `usage.prompt_tokens_details.prompt_cache_hit_tokens` | integer | required | 用户 prompt 中，命中上下文缓存的 token 数。 |
| `usage.prompt_tokens_details.prompt_cache_miss_tokens` | integer | required | 用户 prompt 中，未命中上下文缓存的 token 数。 |
| `usage.total_tokens` | integer | required | 该请求中，所有 token 的数量（prompt + completion）。 |
| `usage.completion_tokens_details` | object | 否 | completion tokens 的详细信息。 |
| `usage.completion_tokens_details.reasoning_tokens` | integer | 否 | 推理模型所产生的思维链 token 数量 |

> ⚠️ **抓取截断点**：官方页面在该行（`usage.completion_tokens_details.reasoning_tokens`）之后的内容**未能抓取到**（`web_fetch` 在两次尝试中均于同一位置截断）。因此以下内容**本文件无法提供**，绝不以记忆填充：
> 1. `usage.completion_tokens_details` 之后是否还有其它响应字段；
> 2. 官方页面的 `Example (from schema)` 与 `Example` 两段示例 JSON；
> 3. 响应标签页中的 **`200 (Streaming)`** 部分（流式 chunk 的 schema 与示例）——**完全未能抓取到**。
> 英文版 `https://api-docs.deepseek.com/api/create-chat-completion` 亦被抓取用于对照，同样在同一位置截断，无法补齐。

### 3.3 finish_reason 枚举值

模型停止生成 token 的原因。**Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`, `aborted`]

| 取值 | 含义（原文照录） |
| --- | --- |
| `stop` | 模型自然停止生成，或遇到 `stop` 序列中列出的字符串。 |
| `length` | 输出长度达到了模型上下文长度限制，或达到了 `max_tokens` 的限制。 |
| `content_filter` | 输出内容因触发过滤策略而被过滤。 |
| `tool_calls` | 模型进行了工具调用。 |
| `insufficient_system_resource` | 系统推理资源不足，生成被打断。 |
| `aborted` | 生成过程被中断。 |

### 3.4 本章节的抓取缺口

**本章节未能抓取到官方以下内容**（页面被工具截断，重试一次仍截断，英文对照页同样截断）：

- 响应示例 JSON（`Example (from schema)` / `Example`）；
- `200 (Streaming)` 的响应 schema 与示例；
- `usage.completion_tokens_details.reasoning_tokens` 之后（若有）的响应字段。

> 与 /chat/completions 相关的、本次**已抓取到**的补充官方说明（来源：官方「多轮对话」页，`https://api-docs.deepseek.com/zh-cn/guides/multi_round_chat`）：DeepSeek `/chat/completions` API 是一个“无状态” API，即服务端不记录用户请求的上下文，用户在每次请求时，**需将之前所有对话历史拼接好后**，传递给对话 API。

---

## 4. Tool Calls（函数调用）

Tool Calls 让模型能够调用外部工具，来增强自身能力。

Tool Calls 的具体 API 格式请参考[对话补全](https://api-docs.deepseek.com/zh-cn/api/create-chat-completion/)文档。

### 4.1 非思考模式：样例代码与完整流程

这里以获取用户当前位置的天气信息为例，展示了使用 Tool Calls 的完整 Python 代码。

```python
from openai import OpenAI

def send_messages(messages):
    response = client.chat.completions.create(
        model="deepseek-flash",
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

> 抓取说明：官方页面该代码块被 `web_fetch` 提取时换行被压平，以上按语句边界还原换行，**未增删任何字符内容**。

这个例子的执行流程如下：

1. 用户：询问现在的天气
2. 模型：返回 function `get_weather({location: 'Hangzhou'})`
3. 用户：调用 function `get_weather({location: 'Hangzhou'})`，并传给模型。
4. 模型：返回自然语言，"The current temperature in Hangzhou is 24°C."

注：上述代码中 `get_weather` 函数功能需由用户提供，模型本身不执行具体函数。

### 4.2 思考模式

从 DeepSeek-V3.2 开始，API 支持了思考模式下的工具调用能力，详见[思考模式](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode#tool-calls)。（本次已抓取到的相关要求见 §2.7.4）

### 4.3 在对话中间插入工具调用（对本项目重要）

在部分 Agent 场景中，客户端需要把并非由模型生成的工具调用及其结果，动态插入到对话历史的中间。各 API 格式对此的支持情况不同：

- [Anthropic API](https://api-docs.deepseek.com/zh-cn/guides/anthropic_api)（`/messages`）与 [Responses API](https://api-docs.deepseek.com/zh-cn/guides/responses_api) 支持在对话中间插入工具调用消息，也支持在对话中间插入 `system` 消息；
- Chat Completion 接口不支持在对话中间插入工具调用，但支持在对话中间插入 `system` 消息；如需插入工具调用，请改用 Anthropic API 或 Responses API。

### 4.4 `strict` 模式（Beta）

在 `strict` 模式下，模型在输出 Function 调用时会严格遵循 Function 的 JSON Schema 的格式要求，以确保模型输出的 Function 符合用户的定义。在思考与非思考模式下的工具调用，均可使用 `strict` 模式。

要使用 `strict` 模式，需要：

1. 用户需要设置 `base_url="https://api.deepseek.com/beta"` 来开启 Beta 功能
2. 在传入的 `tools` 列表中，所有 `function` 均需设置 `strict` 属性为 `true`
3. 服务端会对用户传入的 Function 的 JSON Schema 进行校验，如不符合规范，或遇到服务端不支持的 JSON Schema 类型，将返回错误信息

以下是 `strict` 模式下 tool 的定义样例：

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
                    "description": "The city and state, e.g. San Francisco, CA",
                }
            },
            "required": ["location"],
            "additionalProperties": false
        }
    }
}
```

### 4.5 `strict` 模式支持的 JSON Schema 类型

- object
- string
- number
- integer
- boolean
- array
- enum
- anyOf

#### object 类型

object 定义一个包含键值对的深层结构，其中 properties 定义了对象中每个键（属性）的 schema。**每个 `object` 的所有属性均需设置为 `required`，且 `object` 中 `additionalProperties` 属性必须为 `false`**。

示例：

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

#### string 类型

- 支持的参数：
  - pattern：使用正则表达式来约束字符串的格式
  - format：使用预定义的常见格式进行校验，目前支持：
    - email：电子邮件地址
    - hostname：主机名
    - ipv4：IPv4 地址
    - ipv6：IPv6 地址
    - uuid：uuid
- 不支持的参数
  - minLength
  - maxLength

示例：

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

#### number/integer 类型

- 支持的参数
  - const：固定数字为常数
  - default：数字的默认值
  - minimum：最小值
  - maximum：最大值
  - exclusiveMinimum：不小于
  - exclusiveMaximum：不大于
  - multipleOf：数字输出为这个值的倍数

示例：

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

#### array 类型

- 不支持的参数
  - minItems
  - maxItems

示例：

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

enum 可以确保输出是预期的几个选项之一，例如在订单状态的场景下，只能是有限几个状态之一。

样例：

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

匹配所提供的多个 schema 中的任意一个，可以处理可能具有多种有效格式的字段，例如用户的账户可能是邮箱或者手机号中的一个：

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
  }}
```

#### $ref 和 $def

可以使用 $def 定义模块，再用 $ref 引用以减少模式的重复和模块化，此外还可以单独使用 $ref 定义递归结构。

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

您在调用 DeepSeek API 时，可能会遇到以下错误。这里列出了相关错误的原因及其解决方法。

| 错误码 | 描述 |
| --- | --- |
| 400 - 格式错误 | **原因**：请求体格式错误<br>**解决方法**：请根据错误信息提示修改请求体 |
| 401 - 认证失败 | **原因**：API key 错误，认证失败<br>**解决方法**：请检查您的 API key 是否正确，如没有 API key，请先 [创建 API key](https://platform.deepseek.com/api_keys) |
| 402 - 余额不足 | **原因**：账号余额不足<br>**解决方法**：请确认账户余额，并前往 [充值](https://platform.deepseek.com//top_up) 页面进行充值 |
| 422 - 参数错误 | **原因**：请求体参数错误<br>**解决方法**：请根据错误信息提示修改相关参数 |
| 429 - 请求速率达到上限 | **原因**：请求速率（TPM 或 RPM）达到上限<br>**解决方法**：请合理规划您的请求速率。 |
| 500 - 服务器故障 | **原因**：服务器内部故障<br>**解决方法**：请等待后重试。若问题一直存在，请联系我们解决 |
| 503 - 服务器繁忙 | **原因**：服务器负载过高<br>**解决方法**：请稍后重试您的请求 |

> 本次已抓取到的页面中，另有与状态码相关的 400 场景（来自 §3.1 / §4）：思考模式下使用 `tool_choice: "required"` 或指定具体 tool 会返回 `400`；`stream_options` 未与 `stream: true` 同时使用会返回 `400`；思考模式携带 `tools` 时未回传 `reasoning_content` 会返回 `400`（§2.7.4）。

---

## 6. Token 用量

token 是模型用来表示自然语言文本的基本单位，也是我们的计费单元，可以直观的理解为“字”或“词”；通常 1 个中文词语、1 个英文单词、1 个数字或 1 个符号计为 1 个 token。

一般情况下模型中 token 和字数的换算比例大致如下：

- 1 个英文字符 ≈ 0.3 个 token。
- 1 个中文字符 ≈ 0.6 个 token。

但因为不同模型的分词不同，所以换算比例也存在差异，每一次实际处理 token 数量以模型返回为准，您可以从返回结果的 `usage` 中查看。

### 6.1 离线计算 Token 用量

您可以通过如下压缩包中的代码来运行 tokenizer，以离线计算一段文本的 Token 用量。

[deepseek_tokenizer.zip](https://cdn.deepseek.com/api-docs/deepseek_v4_tokenizer.zip)

### 6.2 计算图片 Token 用量

您可以通过图片尺寸估算图片所占用的 token 数量。图片在进入模型前会被自动缩放，每张图片消耗的 token 数存在上限，详见[图像理解](https://api-docs.deepseek.com/zh-cn/guides/vision#token-usage)。

此处为估算值，实际处理时转换得到的 token 数量可能存在一定误差，请以接口返回的用量为准。

官方页面还提供了一个「图片 Token 计算器」交互组件（输入：宽度 (px)、高度 (px)；按钮：计算）——该组件为前端交互，抓取到的页面文本中**不含其计算公式或结果**，故本文无法给出计算公式。

### 6.3 Usage 响应字段

响应中的 `usage` 字段结构见 §3.2（`completion_tokens` / `prompt_tokens` / `prompt_tokens_details` / `total_tokens` / `completion_tokens_details`）。

---

## 7. 本项目相关要点

### DeepSeek Anthropic 兼容 API 与官方 Anthropic API 的关键差异

> **本节依据**：**仅**依据本次抓取到的 DeepSeek 官方「使用 Anthropic API」页面（`https://api-docs.deepseek.com/zh-cn/guides/anthropic_api`，中英文版互校）中的「支持情况」列。官方 Anthropic API 规范细节**不在本次抓取范围内**，故本节不做“官方 Anthropic 如何如何”的断言，只陈述 **DeepSeek 侧明确记载的行为**。

**入口与鉴权**

1. `base_url` 为 `https://api.deepseek.com/anthropic`（官方 Anthropic 的端点路径不同；DeepSeek 侧文档只给出该 base_url）。
2. `anthropic-version` 请求头被**忽略**——无需（也不校验）版本头。
3. `anthropic-beta` 请求头在 `/messages` 上被**忽略**；仅在 Files API 端点**必须**携带（`files-api-2025-04-14`）。
4. `x-api-key` **完全支持**。

**模型名**

5. `model`：「改为使用 DeepSeek 模型」。传入不支持的模型名时后端自动映射到 `deepseek-flash`。
6. claude 模型名会被映射：`claude-opus*` → `deepseek-v4-pro`；`claude-haiku*` / `claude-sonnet*` → `deepseek-flash`。据此可在 Claude Desktop APP developer 模式下仅改 base_url 与 api_key 接入。

**请求字段：被忽略 / 仅部分支持（对本项目最关键的差异面）**

7. **忽略**的字段：`container`、`mcp_servers`、`service_tier`、`top_k`；tools 的 `cache_control`；text 块的 `cache_control` 与 `citations`；tool_use 块的 `cache_control`；tool_result 块的 `cache_control` 与 `is_error`。
   - 推论（工程影响）：**`cache_control` 不生效**，按 Anthropic 习惯打缓存断点无效；**`tool_result.is_error` 不生效**，工具失败信息不能依赖该标记传递，须写进 `content`。
8. `metadata`：**仅** `user_id` 支持，其它字段忽略（`user_id` 可用于限速与隔离）。
9. `thinking`：支持，但 **`budget_tokens` 被忽略**。
10. `output_config`：**仅支持 `effort`**。
11. `top_p`：**仅思考模式下生效**（下限 `0.95`）；**非思考模式下恒为 `1.0`**，传入值被忽略。
12. `temperature`：完全支持，范围 `[0.0 ~ 2.0]`。
13. `max_tokens`、`stop_sequences`、`stream`、`system`：完全支持。

**工具字段**

14. `tools`：`name` / `input_schema` / `description` 完全支持。
15. `tool_choice`：`none` 完全支持；`auto` / `any` / `tool` 支持，但 **`disable_parallel_tool_use` 被忽略**（即无法通过该开关禁止并行工具调用）。

**消息内容块：不支持的类型（会导致该块无法使用）**

16. **不支持**：`document`、`search_result`、`redacted_thinking`、`code_execution_tool_result`、`mcp_tool_use`、`mcp_tool_result`、`container_upload`。
17. **支持**：`text`、`image`（`source.type` 可为 base64（jpeg/png/gif/webp）、url、file（需 `anthropic-beta: files-api-2025-04-14` 头））、`thinking`、`tool_use`（`id`/`input`/`name`）、`tool_result`（`tool_use_id`/`content`）、`server_tool_use`、`web_search_tool_result`；`content` 为 string 时完全支持。

**对话结构能力（本项目 Agent 循环直接相关）**

18. Anthropic API（`/messages`）**支持在对话中间插入工具调用消息**，也**支持在对话中间插入 `system` 消息**；Chat Completion 接口**不支持**在对话中间插入工具调用（但支持中间插入 `system` 消息）。（来源：§4.3 官方 Tool Calls 页面）

**本项目落地时的检查清单（由上述条款直接推出）**

- 走 Anthropic 兼容端点时不要指望 `anthropic-version` 校验，也不要指望 `/messages` 上的 beta 头生效；
- 不要把 prompt 缓存寄托在 `cache_control` 上（被忽略）；
- 工具错误不要靠 `is_error` 传（被忽略），要写进 `tool_result.content`；
- 想限制并行工具调用不能用 `disable_parallel_tool_use`（被忽略）；
- 思考预算不能用 `budget_tokens` 控制（被忽略），用 `thinking.type` 与 `output_config.effort`；
- 非思考模式下 `top_p` 恒为 1.0；思考模式下小于 0.95 会被抬到 0.95；
- 不要发送 `document` / `search_result` / `redacted_thinking` / `mcp_*` / `code_execution_tool_result` / `container_upload` 内容块；
- 若需要在对话历史中间插入工具调用消息，必须走 Anthropic API 或 Responses API，不能用 Chat Completions。

---

## 8. 来源

| 页面 | URL | 抓取状态 |
| --- | --- | --- |
| 首次调用 API（中文） | https://api-docs.deepseek.com/zh-cn/ | ✅ 成功（HTTP 200，1 次成功） |
| 使用 Anthropic API（中文，§2 主源） | https://api-docs.deepseek.com/zh-cn/guides/anthropic_api | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| Chat Completions API（中文，§3 主源） | https://api-docs.deepseek.com/zh-cn/api/create-chat-completion | ⚠️ **部分成功**：HTTP 200，抓取 2 次均在同一位置（`usage.completion_tokens_details.reasoning_tokens`）被工具截断；响应示例 JSON 与 `200 (Streaming)` 部分**未获取到** |
| Tool Calls（中文，§4 主源） | https://api-docs.deepseek.com/zh-cn/guides/tool_calls | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| 错误码（中文，§5 主源） | https://api-docs.deepseek.com/zh-cn/quick_start/error_codes | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| Token 用量计算（中文，§6 主源） | https://api-docs.deepseek.com/zh-cn/quick_start/token_usage | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| 使用 Anthropic API（英文，§2 对照补充） | https://api-docs.deepseek.com/guides/anthropic_api | ✅ 成功（HTTP 200，1 次成功；四张对照表与中文版一致） |
| Chat Completions API（英文，§3 对照补充） | https://api-docs.deepseek.com/api/create-chat-completion | ⚠️ **部分成功**：与中文版在同一位置截断，未能补齐缺口 |
| 思考模式（中文，§2.7 补充源，非任务指定） | https://api-docs.deepseek.com/zh-cn/guides/thinking_mode | ⚠️ **部分成功**：HTTP 200，末尾（流式样例代码及其后内容）被工具截断 |
| 多轮对话（中文，§3.4 补充源，非任务指定） | https://api-docs.deepseek.com/zh-cn/guides/multi_round_chat | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| 探测尝试：`.md` 后缀变体 | https://api-docs.deepseek.com/zh-cn/api/create-chat-completion.md | ❌ 无效（HTTP 200 但返回英文首页，非目标页面内容） |
| 探测尝试：锚点片段 | https://api-docs.deepseek.com/api/create-chat-completion#example | ❌ 无效（锚点不改变服务端返回，仍在同一位置截断） |

**未能覆盖的章节/内容（如实记录）**

1. **§3.4**：`/chat/completions` 的响应示例 JSON、`200 (Streaming)` 响应 schema 与示例、`usage.completion_tokens_details.reasoning_tokens` 之后（若有）的字段——官方页面被抓取工具截断，重试一次仍截断，英文对照页同样截断。
2. **§3.1 messages**：`messages` 数组的 User message / Assistant message / Tool message 三个变体的字段明细未在抓取到的页面文本中展开，故未列出（未以记忆补写）。
3. **§2.7**：官方「思考模式」页面的末尾（流式样例代码及其后内容）被截断；该页长样例代码未收录。
4. **§2.7.1**：思考模式控制参数表的「Anthropic 格式 / Responses API 格式」两列归属在抓取结果中存在歧义（表格空单元格丢失），已按原始单元格照录并标注旁证，未强行断定。
5. **§6.2**：官方「图片 Token 计算器」为前端交互组件，抓取文本中不含计算公式。

> 抓取时间：2026-09-10
