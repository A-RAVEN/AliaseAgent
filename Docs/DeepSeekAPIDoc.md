# DeepSeek API 参考文档

> **抓取时间**: 2026-09-20 14:53（UTC+8）
> **来源**: DeepSeek 官方 API 文档站（`https://api-docs.deepseek.com/zh-cn/`）。本文全部官方内容均由 `web_fetch` 与 `curl.exe` 于本次实际抓取（见 §8 来源表），逐字搬运，**未使用任何记忆、先验知识或推测内容**。
> **保留的非官方内容**: §2.7.5「本地实测记录（非官方抓取）」是本项目本地 live 探测结论，**不是官方文档内容**，已原样保留并保留其标注。
>
> **本次（2026-09-20）相对上一版（2026-09-10）的抓取变化**
>
> 1. **上一版的截断缺口本次已全部补齐。** 上一版记录的「`create-chat-completion` 页被工具截断，响应示例 JSON 与 `200 (Streaming)` 未能抓取到」，本次改用 `curl.exe` 取原始 HTML 后**已完整取得**（见 §3.3–§3.7）。原因：截断是 `web_fetch` 工具的正文长度上限所致，不是服务端缺内容。
> 2. **上一版 §2.7.1 的「控制表列归属无法确定」已解决。** 本次从 HTML 的 `colspan` / `rowspan` 精确确认了三列归属（见 §2.7.1）。
> 3. **官方「首次调用 API」页删除了 `deepseek-v4-pro` 的下线/路由脚注 (2)**，`model` 行现在只带脚注 (1)（见 §1.1 的变化提示）。
> 4. **本项目 §2.7.5 的实测结论与本次确认后的官方表格不再冲突**，说明见 §2.7.5 末尾的补充段落。
>
> **本次（2026-10-24）增补：图像理解**
>
> 上一版未收录官方「图像理解」页（`https://api-docs.deepseek.com/zh-cn/guides/vision`）。本项目要加图片输入能力，本次用 `web_fetch` 抓取该页（HTTP 200，正文完整），新增 §6.4 **逐字照录**该页内容；并在 §6.2 末尾补一段**明确标注为「本项目推导 + 实测校准」**的图片 token 估算式。§8 来源表与「未能覆盖的章节」已同步。
>
> 除 §6.2 末尾那一段（已标注非官方）与 §6.4.5 末尾那句「本项目备注」外，本次新增内容均为官方原文照录。

---

## 1. 概述

DeepSeek API 使用与 OpenAI/Anthropic 兼容的 API 格式，通过修改配置，您可以使用 OpenAI/Anthropic SDK 来访问 DeepSeek API，或使用与 OpenAI/Anthropic API 兼容的软件。

### 1.1 base_url 与基本参数

| PARAM | VALUE |
| --- | --- |
| base_url (OpenAI) | `https://api.deepseek.com` |
| base_url (Anthropic) | `https://api.deepseek.com/anthropic` |
| api_key | 申请一个 [API key](https://platform.deepseek.com/api_keys) |
| model | `deepseek-flash`(1)<br>`deepseek-v4-pro` |

(1) 模型名请使用 `deepseek-flash`。旧模型名 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍可调用，但对应模型已下线，请求将由 DeepSeek-V4.1-Flash 模型提供服务，并按 Flash 价格计费。

> **本次抓取发现的变化（如实记录）**：上一版（抓取于 2026-09-10）此处另有一条脚注 **(2)**，大意为「V4.1 Flash 已全面超越 V4 Pro，计划有序下线 V4 Pro；北京时间 2026 年 9 月 14 日 12:00 之后，`deepseek-v4-pro` 的请求将全部路由到 V4.1 Flash，并按 V4.1 Flash 价格计费」。
>
> **本次抓取（`web_fetch` 与 `curl.exe` 原始 HTML 双向核对）该脚注已不存在**：`model` 单元格只带 `(1)`，全页检索不到「9 月 14」「路由」「V4 Pro」字样（「V4.1」仅出现在脚注 (1) 的 `DeepSeek-V4.1-Flash` 中）。因此**本文件不再保留该「下线 / 路由到 V4.1 Flash」说法**，如需该信息请以官方页面当前显示为准。

> 补充（来自 §4 Tool Calls 页面）：`strict` 模式等 Beta 功能需要设置 `base_url="https://api.deepseek.com/beta"` 来开启。（原文见 §4.4）

### 1.2 可用模型列表

官方「首次调用 API」页只给出 §1.1 表格中 `model` 一行的两个取值；官方「对话补全 API」页对 `model` 字段的枚举值为 **Possible values:** [`deepseek-flash`, `deepseek-v4-pro`]（见 §3.1）。

| 模型 ID | 说明（原文照录） |
| --- | --- |
| `deepseek-flash` | 官方推荐使用的模型名（脚注 (1)：「模型名请使用 `deepseek-flash`」） |
| `deepseek-v4-pro` | 与 `deepseek-flash` 并列为 `model` 字段的合法取值；官方「使用 Anthropic API」页称 claude-opus 开头的模型名会映射到它，且「按 V4 Pro 价格计费」（见 §2.2） |
| `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` | 旧模型名，仍可调用，但对应模型已下线，请求将由 DeepSeek-V4.1-Flash 模型提供服务，并按 Flash 价格计费（脚注 (1) 原文） |

> **注意**：当您给 DeepSeek 的 Anthropic API 传入不支持的模型名时，API 后端会自动将其映射到 `deepseek-flash` 模型。（§2.1 原文）

### 1.3 接入 Agent 工具

DeepSeek Harness 开发者预览版面向全球 Harness 开发者开放测试。详见 [DeepSeek Harness 入门](https://deepseek-harness.github.io/deepseek-harness/guide/quickstart)。

DeepSeek API 已接入多种主流 AI Agent 与编程助手工具。如果你使用 Claude Code、GitHub Copilot、OpenCode 等工具，可以直接将 DeepSeek 作为后端模型，无需编写代码即可开始使用。详见 [Agent 工具接入指南](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code)。

### 1.4 调用对话 API（OpenAI 格式，curl）

在创建 API key 之后，你可以使用以下样例脚本，通过 OpenAI API 格式来访问 DeepSeek 模型。样例为非流式输出，您可以将 stream 设置为 true 来使用流式输出。

官方页面在本节提供 `curl` / `python` / `nodejs` 三个标签页，本文件照录 `curl` 标签页（原文另有一句：「Anthropic API 格式的访问样例，请参考 [Anthropic API](https://api-docs.deepseek.com/zh-cn/guides/anthropic_api)」）：

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

> 抓取说明：官方页面的代码块在 `web_fetch` 提取时换行被压平为一行；以上按语句边界还原了换行，**未增删任何字符内容**。全文所有还原换行的代码块同理（§2.1、§2.7.2、§4.1 已另行标注）。

---

## 2. Anthropic API 兼容性（重点）

为了满足大家对 Anthropic API 生态的使用需求，我们的 API 新增了对 Anthropic API 格式的支持，其 `base_url` 为 `https://api.deepseek.com/anthropic`。

通过简单的配置，即可将 DeepSeek 的能力，接入到 Anthropic API 生态中。

官方本页在开头另有一小节「将 DeepSeek 模型接入 Claude Code」，正文仅为一句指引：请参考 [接入 Claude Code](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code)。（该指南页不在本次抓取范围内，本文件未收录其内容。）

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

claude-opus 映射到的 `deepseek-v4-pro` 按 V4 Pro 价格计费。

通过这样的映射，您在使用新版 Claude Desktop APP 的 developer 模式时，可以绕过 APP 对模型名的限制，只需改动 base_url 和 api_key，即可在其中接入 DeepSeek 模型。

> **本次抓取发现的变化**：上一版此处的原文为「claude-opus 映射到的 `deepseek-v4-pro` 在 2026 年 9 月 14 日 12:00 之前仍按 V4 Pro 价格计费；此后 `deepseek-v4-pro` 也将路由到 V4.1 Flash，并按 Flash 价格计费」。**本次抓取到的原文已不含该时间点与路由说法**，只剩「按 V4 Pro 价格计费」。中英文两版一致（英文："The claude-opus mapping points to `deepseek-v4-pro`, which is billed at the V4 Pro price."）。

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

> **本次抓取未发现变化**：上表 14 行与上一版逐字一致；英文版（`https://api-docs.deepseek.com/guides/anthropic_api`）的 Simple Fields 表 14 行亦逐条对应——`model` = "Use DeepSeek Model Instead"、`max_tokens` = "Fully Supported"、`container` / `mcp_servers` / `service_tier` / `top_k` = "Ignored"、`metadata` = "`user_id` is supported, others are ignored"、`stop_sequences` / `stream` / `system` = "Fully Supported"、`temperature` = "Fully Supported (range \[0.0 ~ 2.0\])"、`thinking` = "Supported (`budget_tokens` is ignored)"、`output_config` = "Only `effort` is supported"、`top_p` = "Only takes effect in thinking mode (with a lower bound of `0.95`); in non-thinking mode it is fixed at `1.0`"。

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

> **中英文对照核验**：英文版 `tools` 表为 name / input_schema / description = "Fully Supported"、cache_control = "Ignored"；`tool_choice` 表为 none = "Fully Supported"，auto / any / tool = "Supported (`disable_parallel_tool_use` is ignored)"。与中文版逐条一致。

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
> **中英文对照核验**：本次同时抓取了英文版 `https://api-docs.deepseek.com/guides/anthropic_api`，其上 HTTP Header / Simple Fields / Tool Fields / Message Fields 四张表与中文版条目一一对应、内容一致（英文为 "Fully Supported / Ignored / Not Supported / Supported"），可交叉确证。

### 2.7 思考模式（Thinking）相关（来自官方「思考模式」指南）

官方页面开头原文：DeepSeek 模型支持思考模式：在输出最终回答之前，模型会先输出一段思维链内容，以提升最终答案的准确性。

#### 2.7.1 思考模式开关与思考强度控制

官方表格结构（**本次已从页面 HTML 的 `colspan` / `rowspan` 精确确认，不再存在列归属歧义**）：

| （行标签） | 控制参数（OpenAI 格式） | 控制参数（Anthropic 格式） | 控制参数（Responses API 格式） |
| --- | --- | --- | --- |
| 思考模式开关(1) | `{"thinking": {"type": "enabled/disabled"}}` | （同左：该单元格 `colspan="2"`，同时覆盖 OpenAI 与 Anthropic 两列） | `{"reasoning": {"effort": "none/low/high/max"}}`<br>(none 表示关闭思考模式) |
| 思考强度控制(2) | `{"reasoning_effort": "low/high/max"}` | `{"output_config": {"effort": "low/high/max"}}` | （由上一行的 `rowspan="2"` 覆盖，即同为 `{"reasoning": {"effort": ...}}`） |

> **列归属的证据（原文 HTML 结构）**：
>
> - 表头行 4 个单元格：空 / `控制参数（OpenAI 格式）` / `控制参数（Anthropic 格式）` / `控制参数（Responses API 格式）`；
> - 「思考模式开关」行的 `{"thinking": {"type": "enabled/disabled"}}` 单元格带 **`colspan="2"`** ⇒ 它同时属于 **OpenAI 格式列与 Anthropic 格式列**；
> - 「思考模式开关」行的 `{"reasoning": {"effort": "none/low/high/max"}}` 单元格带 **`rowspan="2"`** ⇒ 它只属于 **Responses API 格式列**，并被下一行共用；
> - 「思考强度控制」行的两个单元格分别是 `{"reasoning_effort": "low/high/max"}`（OpenAI 列）与 `{"output_config": {"effort": "low/high/max"}}`（Anthropic 列）。
>
> 结论：**Anthropic 格式的开关是 `thinking.type`，强度是 `output_config.effort`；`reasoning.effort` / `reasoning_effort` 都不是 Anthropic 格式的字段。**

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

#### 2.7.2 在 OpenAI SDK 中设置 thinking 参数

官方原文：您在 OpenAI SDK 中使用 Chat Completion 设置 thinking 参数时，需要将 thinking 参数传入 `extra_body` 中：

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

`top_p` 仅在思考模式下生效，有效取值范围为 0.95–1.0，低于 0.95 的取值会按 0.95 处理。在非思考模式下，该参数恒为 1.0，传入的值会被忽略。

在思考模式下，思维链内容通过 `reasoning_content` 参数返回，与 `content` 同级。在后续轮次的请求中，`reasoning_content` 是否需要回传、是否会被拼接进上下文，取决于请求是否携带 `tools` 参数：

- 若请求**携带 `tools` 参数**：历史轮次的 `reasoning_content` 均应回传给 API，并会被拼接进上下文。详见工具调用。
- 若请求**未携带 `tools` 参数**：`reasoning_content` 无需回传；即使传入 API，也会被忽略，不会拼接进上下文。详见多轮对话拼接。

##### 多轮对话拼接（官方小节）

在每一轮对话过程中，模型会输出思维链内容（`reasoning_content`）和最终回答（`content`）。如果请求未携带 `tools` 参数，则在下一轮对话中，之前轮输出的思维链内容不会被拼接到上下文中，如下图所示：

（官方此处配有一张示意图；图为前端资源，本文件未收录图片本身。）

官方随后给出「非流式」与「流式」两个标签页的样例代码，原文如下（代码块换行已按语句边界还原，未增删字符）——非流式：

```
from openai import OpenAI
client = OpenAI(api_key="<DeepSeek API Key>", base_url="https://api.deepseek.com")
# Turn 1
messages = [{"role": "user", "content": "9.11 and 9.8, which is greater?"}]
response = client.chat.completions.create(
    model="deepseek-flash",
    messages=messages,
    reasoning_effort="high"
    extra_body={"thinking": {"type": "enabled"}},
)
reasoning_content = response.choices[0].message.reasoning_content
content = response.choices[0].message.content
# Turn 2
# The reasoning_content will be ignored by the API
messages.append(response.choices[0].message)
messages.append({'role': 'user', 'content': "How many Rs are there in the word 'strawberry'?"})
response = client.chat.completions.create(
    model="deepseek-flash",
    messages=messages,
    reasoning_effort="high"
    extra_body={"thinking": {"type": "enabled"}},
)
# ...
```

流式：

```
from openai import OpenAI
client = OpenAI(api_key="<DeepSeek API Key>", base_url="https://api.deepseek.com")
# Turn 1
messages = [{"role": "user", "content": "9.11 and 9.8, which is greater?"}]
response = client.chat.completions.create(
    model="deepseek-flash",
    messages=messages,
    stream=True,
    reasoning_effort="high"
    extra_body={"thinking": {"type": "enabled"}},
)
reasoning_content = ""
content = ""
for chunk in response:
    if chunk.choices[0].delta.reasoning_content:
        reasoning_content += chunk.choices[0].delta.reasoning_content
    else:
        content += chunk.choices[0].delta.content
# Turn 2
# The reasoning_content will be ignored by the API
messages.append({"role": "assistant", "reasoning_content": reasoning_content, "content": content})
messages.append({'role': 'user', 'content': "How many Rs are there in the word 'strawberry'?"})
response = client.chat.completions.create(
    model="deepseek-flash",
    messages=messages,
    stream=True,
    reasoning_effort="high"
    extra_body={"thinking": {"type": "enabled"}},
)
# ...
```

#### 2.7.4 工具调用（思考模式）

DeepSeek 模型的思考模式支持工具调用功能。模型在输出最终答案之前，可以进行多轮的思考与工具调用，以提升答案的质量。其调用模式如下图所示：（官方此处配图，本文件未收录图片本身。）

请注意，携带了 `tools` 参数的请求，在后续所有请求中，必须完整回传 `reasoning_content` 给 API——即使该轮模型未实际进行工具调用。若您的代码中未正确回传 `reasoning_content`，API 会返回 400 报错。正确回传方法请您参考下面的样例代码。

官方样例代码（完整照录；代码块换行已按语句边界还原）：

```
import os
import json
from openai import OpenAI
from datetime import datetime
# The definition of the tools
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_date",
            "description": "Get the current date",
            "parameters": { "type": "object", "properties": {} },
        }
    },
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get weather of a location, the user should supply the location and date.",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": { "type": "string", "description": "The city name" },
                    "date": { "type": "string", "description": "The date in format YYYY-mm-dd" },
                },
                "required": ["location", "date"]
            },
        }
    },
]
# The mocked version of the tool calls
def get_date_mock():
    return datetime.now().strftime("%Y-%m-%d")
def get_weather_mock(location, date):
    return "Cloudy 7~13°C"
TOOL_CALL_MAP = {
    "get_date": get_date_mock,
    "get_weather": get_weather_mock
}
def run_turn(turn, messages):
    sub_turn = 1
    while True:
        response = client.chat.completions.create(
            model='deepseek-flash',
            messages=messages,
            tools=tools,
            reasoning_effort="high",
            extra_body={ "thinking": { "type": "enabled" } },
        )
        messages.append(response.choices[0].message)
        reasoning_content = response.choices[0].message.reasoning_content
        content = response.choices[0].message.content
        tool_calls = response.choices[0].message.tool_calls
        print(f"Turn {turn}.{sub_turn}\n{reasoning_content=}\n{content=}\n{tool_calls=}")
        # If there is no tool calls, then the model should get a final answer and we need to stop the loop
        if tool_calls is None:
            break
        for tool in tool_calls:
            tool_function = TOOL_CALL_MAP[tool.function.name]
            tool_result = tool_function(**json.loads(tool.function.arguments))
            print(f"tool result for {tool.function.name}: {tool_result}\n")
            messages.append({
                "role": "tool",
                "tool_call_id": tool.id,
                "content": tool_result,
            })
        sub_turn += 1
    print()
client = OpenAI(
    api_key=os.environ.get('DEEPSEEK_API_KEY'),
    base_url=os.environ.get('DEEPSEEK_BASE_URL'),
)
# The user starts a question
turn = 1
messages = [{
    "role": "user",
    "content": "How's the weather in Hangzhou Tomorrow"
}]
run_turn(turn, messages)
# The user starts a new question
turn = 2
messages.append({
    "role": "user",
    "content": "How's the weather in Guangzhou Tomorrow"
})
run_turn(turn, messages)
```

官方随后原文说明：

在 Turn 1 的每个子请求中，都携带了该 Turn 下产生的 `reasoning_content` 给 API，从而让模型继续之前的思考。`response.choices[0].message` 携带了 `assistant` 消息的所有必要字段，包括 `content`、`reasoning_content`、`tool_calls`。简单起见，可以直接用如下代码将消息 append 到 `messages` 结尾：

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

且在 Turn 2 的请求中，我们仍然携带着 Turn1 所产生的 `reasoning_content` 给 API。

> 官方页面在该样例后另给出「该代码的样例输出」（覆盖 Turn 1.1 / 1.2 / 1.3 与 Turn 2.1 / 2.2 的 `reasoning_content` / `content` / `tool_calls` 实际取值）。那属于运行输出而非接口定义，本文件未逐行转录；如需请查官方页面。

> **抓取情况说明**：上一版记录「官方『思考模式』页面在末尾被 `web_fetch` 截断，其流式样例代码及其后内容未能抓取到」。**本次改用 `curl.exe` 取原始 HTML，该页已完整取得**，上面的多轮对话样例、工具调用样例与说明均为本次实际抓到的原文。

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

> **本次抓取后的补充说明（2026-09-20，属官方抓取内容，不是 §2.7.5 的实测结论；§2.7.5 的实测内容本身未作任何改动）**：
>
> 上面这段「与 §2.7.1 官方表格的冲突提示」写于上一版，当时 §2.7.1 表格的三列归属无法从抓取文本判定。本次已从官方页面 HTML 的 `colspan` / `rowspan` 精确确认：`{"reasoning": {"effort": "none/low/high/max"}}` 位于**「控制参数（Responses API 格式）」列**，官方从未把它列在 Anthropic 格式列。
>
> 也就是说：**官方表格与本项目实测并不冲突**——`reasoning.effort` 本来就不是 Anthropic 路径的开关（与实测一致），而 Anthropic 格式的开关确实是 `thinking.type`、强度确实是 `output_config.effort`（与实测一致）。上面那段提示中「§2.7.1 自身也已标注该表的列归属存在歧义」一句已因本次抓取而失效，其余实测结论仍然有效。

---

## 3. 对话补全 API

`POST /chat/completions` —— 根据输入的上下文，来让模型补全对话内容。

请求体类型：`application/json`。

> **本章抓取情况**：官方页面对 `web_fetch` 存在正文长度上限，会在 `usage.completion_tokens_details.reasoning_tokens` 处截断（本次 `web_fetch` 复现了该截断）。**本章改用 `curl.exe` 抓取原始 HTML（HTTP 200，跟随 1 次 302 重定向到带尾斜杠的地址，145,964 字节）后已完整取得全部内容**，包括响应示例 JSON 与 `200 (Streaming)` 部分。

### 3.1 Request Body

| 参数 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `messages` | object[] | **required** | 对话的消息列表。**Possible values:** `>= 1`。数组元素 `oneOf` 四个变体：**System message / User message / Assistant message / Tool message**。（抓取到的页面内容仅展开了 System message 变体，见下方说明） |
| `model` | string | **required** | 使用的模型的 ID。请使用 `deepseek-flash` 或 `deepseek-v4-pro`。**Possible values:** [`deepseek-flash`, `deepseek-v4-pro`] |
| `thinking` | object \| nullable | 否 | 控制思考模式与非思考模式的转换 |
| `thinking.type` | string | 否 | **Possible values:** [`enabled`, `disabled`]；**Default value:** `enabled`。如果设为 `enabled`，则使用思考模式。如果设为 `disabled`，则使用非思考模式 |
| `reasoning_effort` | string | 否 | **Possible values:** [`none`, `low`, `high`, `max`]。控制思考模式开关与思考强度。`none` 关闭思考模式；`low` / `high` / `max` 开启思考模式。默认强度为 `high`。出于兼容考虑，`minimal` 映射为 `low`，`medium` / `xhigh` 映射为 `high`。 |
| `max_tokens` | integer \| nullable | 否 | 限制一次请求中模型生成 completion 的最大 token 数。取值范围为 1 到 384K（393216）。未设置时，非思考模式默认 8K，思考模式默认 64K（`reasoning_effort` 为 `max` 时为 128K）。输入 token 和输出 token 的总长度受模型的上下文长度的限制。详见[模型 & 价格](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)。 |
| `response_format` | object \| nullable | 否 | 一个 object，指定模型必须输出的格式。设置为 `{ "type": "json_object" }` 以启用 JSON 模式，该模式保证模型生成的消息是有效的 JSON。**注意:** 使用 JSON 模式时，你还必须通过系统或用户消息指示模型生成 JSON。否则，模型可能会生成不断的空白字符，直到生成达到令牌限制，从而导致请求长时间运行并显得“卡住”。此外，如果 finish_reason="length"，这表示生成超过了 max_tokens 或对话超过了最大上下文长度，消息内容可能会被部分截断。 |
| `response_format.type` | string | 否 | **Possible values:** [`text`, `json_object`]；**Default value:** `text`。Must be one of `text` or `json_object`. |
| `stop` | object \| **nullable** | 否 | 一个 string 或最多包含 16 个 string 的 list，在遇到这些词时，API 将停止生成更多的 token。`oneOf`: MOD1 / MOD2（string） |
| `stream` | boolean \| nullable | 否 | 如果设置为 True，将会以 SSE（server-sent events）的形式以流式发送消息增量。消息流以 `data: [DONE]` 结尾。 |
| `stream_options` | object \| nullable | 否 | 流式输出相关选项。必须与 `stream: true` 一起使用；如果 `stream` 未设置为 `true`，API 会返回 `400` 错误。 |
| `stream_options.include_usage` | boolean | 否 | 见下方「include_usage 语义」 |
| `temperature` | number \| nullable | 否 | **Possible values:** `<= 2`；**Default value:** `1`。采样温度，介于 0 和 2 之间。更高的值，如 0.8，会使输出更随机，而更低的值，如 0.2，会使其更加集中和确定。我们通常建议可以更改这个值或者更改 `top_p`，但不建议同时对两者进行修改。思考模式下不生效。 |
| `top_p` | number \| nullable | 否 | **Possible values:** `<= 1`；**Default value:** `1`。作为调节采样温度的替代方案，模型会考虑前 `top_p` 概率的 token 的结果。所以 0.1 就意味着只有包括在最高 10% 概率中的 token 会被考虑。取值必须大于 0 且不超过 1。我们通常建议修改这个值或者更改 `temperature`，但不建议同时对两者进行修改。该参数仅在思考模式下生效，有效取值范围为 0.95–1.0，低于 0.95 的取值会按 0.95 处理；在非思考模式下恒为 1.0，传入的值会被忽略。 |
| `tools` | object[] \| nullable | 否 | 模型可能会调用的 tool 的列表。目前，仅支持 function 作为工具。使用此参数来提供以 JSON 作为输入参数的 function 列表。tool 名称必须唯一。 |
| `tools[].type` | string | **required** | **Possible values:** [`function`]。tool 的类型。目前仅支持 function。 |
| `tools[].function` | object | **required** | — |
| `tools[].function.description` | string | 否 | function 的功能描述，供模型理解何时以及如何调用该 function。 |
| `tools[].function.name` | string | **required** | 要调用的 function 名称。必须由 a-z、A-Z、0-9 字符组成，或包含下划线和连字符，最大长度为 128 个字符。 |
| `tools[].function.parameters` | object | 否 | function 的输入参数，以 JSON Schema 对象描述。请参阅 [Tool Calls 指南](https://api-docs.deepseek.com/zh-cn/guides/tool_calls)获取示例，并参阅 [JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。 |
| `tools[].function.parameters.property name*` | any | 否 | function 的输入参数，以 JSON Schema 对象描述。请参阅 [Tool Calls 指南](https://api-docs.deepseek.com/zh-cn/guides/tool_calls)获取示例，并参阅 [JSON Schema 参考](https://json-schema.org/understanding-json-schema/)了解有关格式的文档。省略 `parameters` 会定义一个参数列表为空的 function。 |
| `tools[].function.strict` | boolean | 否 | **Default value:** `false`。如果设置为 true，API 将在函数调用中使用 strict 模式，以确保输出始终符合函数的 JSON schema 定义。该功能为 Beta 功能，详细使用方式请参阅 [Tool Calls 指南](https://api-docs.deepseek.com/zh-cn/guides/tool_calls) |
| `tool_choice` | object \| **nullable** | 否 | 控制模型调用 tool 的行为（原文在此字段内直接给出语义，见下方「tool_choice 语义」）。`oneOf`: ChatCompletionToolChoice / ChatCompletionNamedToolChoice；string **Possible values:** [`none`, `auto`, `required`] |
| `logprobs` | boolean \| nullable | 否 | 是否返回所输出 token 的对数概率。如果为 true，则在 `message` 的 `content` 中返回每个输出 token 的对数概率。 |
| `top_logprobs` | integer \| nullable | 否 | **Possible values:** `<= 20`。一个介于 0 到 20 之间的整数 N，指定每个输出位置返回输出概率 top N 的 token，且返回这些 token 的对数概率。指定此参数时，logprobs 必须为 true。 |
| `user_id` | nullable | 否 | 您自定义的 user_id，可选字符集为 `[a-zA-Z0-9\-_]`，最大长度为 512。请不要在 user_id 中包含用户隐私信息。（原文在此字段内直接列出三条用途，见下方「user_id 用途」） |
| `frequency_penalty` | **deprecated** | — | 该参数已不再支持。传入该参数将不会产生任何效果。 |
| `presence_penalty` | **deprecated** | — | 该参数已不再支持。传入该参数将不会产生任何效果。 |

> **本次抓取发现的措辞变化（相对上一版）**，均为官方原文更新，如实记录：
>
> 1. `max_tokens` 末尾新增指引「详见[模型 & 价格](https://api-docs.deepseek.com/zh-cn/quick_start/pricing)。」；
> 2. `top_p` 的说明由「该参数在思考模式下生效，但小于 0.95 的值会被抬升至 0.95」改为「该参数**仅**在思考模式下生效，**有效取值范围为 0.95–1.0**，低于 0.95 的取值**会按 0.95 处理**」（与 §2.7.3 一致）；
> 3. `tools[].function.parameters.property name*` 不再写「（同上说明）」，而是重复完整说明；
> 4. `tools[].function.strict` 由「该功能为 Beta 功能。」补充为「该功能为 Beta 功能，详细使用方式请参阅 [Tool Calls 指南]」；
> 5. `tool_choice` 的语义说明与 `user_id` 的三条用途，本次都**内联在字段说明里**（上一版把它们另列为两个小节），内容本身一致。

#### messages 数组说明

官方 schema 中 `messages` 的 `oneOf` 声明了四个变体：**System message / User message / Assistant message / Tool message**。抓取到的页面内容**只展开了 System message 变体的字段明细**：

| 字段 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `content` | string | **required** | system 消息的内容。 |
| `role` | string | **required** | **Possible values:** [`system`]。该消息的发起角色，其值为 `system`。 |
| `name` | string | 否 | 可以选填的参与者的名称，为模型提供信息以区分相同角色的参与者。 |

> **诚实标注**：User message / Assistant message / Tool message 三个变体的字段明细**本次仍未抓取到**。这三个变体在官方页面上是「嵌套标签页」形式，**服务端返回的 HTML 里只有 System message 面板的内容**——本次对原始 HTML 检索 `User message` / `Assistant message` / `Tool message` / `tool_call_id`，各只出现 1 次（即标签文字本身），**没有对应的字段明细**。因此**本文件不列其字段**，也不以记忆补写。`role: "tool"` 与 `tool_call_id` 的用法可在 §4.1 的官方样例代码中看到（`{"role": "tool", "tool_call_id": tool.id, "content": "24℃"}`）。

#### tool_choice 语义（原文照录）

控制模型调用 tool 的行为。

- `none` 意味着模型不会调用任何 tool，而是生成一条消息。
- `auto` 意味着模型可以选择生成一条消息或调用一个或多个 tool。
- `required` 意味着模型必须调用一个或多个 tool。
- 通过 `{"type": "function", "function": {"name": "my_function"}}` 指定特定 tool，会强制模型调用该 tool。
- 当没有 tool 时，默认值为 `none`。如果有 tool 存在，默认值为 `auto`。
- 思考模式下不支持 `required` 和指定具体 tool 的用法，API 会返回 `400` 错误。请先关闭思考模式。

#### include_usage 语义（原文照录）

如果设置为 `true`，流式返回的所有块都会包含 `usage` 字段，其中除最后一个块外，该字段的值均为 `null`。如果不设置或设置为 `false`，则除最后一个块外，其余块都不含 `usage` 字段。

无论是否设置，`data: [DONE]` 之前的最后一个块都会在其 `usage` 字段中给出整个请求的 token 使用统计信息。请注意，这里不会单独下发一个只含 usage 的块：统计信息附加在最后一个内容块上，该块的 `choices` 数组始终只包含一个元素，其中不含新增内容且 `finish_reason` 非 null。

#### user_id 用途（原文照录）

- user_id 可用于区分您业务侧的用户身份，以帮助我们进行内容安全处理。
- user_id 可用于 KVCache 缓存隔离，以进行隐私管理。
- user_id 可用于我们对您业务侧用户进行调度隔离。
- 关于 user_id 参数更详细的描述，请参考[限速与隔离](https://api-docs.deepseek.com/zh-cn/quick_start/rate_limit)

### 3.2 Response Schema（200, No streaming）

OK, 返回一个 `chat completion` 对象。响应类型：`application/json`。页面提供三个标签页：`Schema` / `Example (from schema)` / `Example`。

| 字段路径 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `id` | string | required | 该对话的唯一标识符。 |
| `choices` | object[] | required | 模型生成的 completion 的选择列表。 |
| `choices[].finish_reason` | string | required | **Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`, `aborted`]（逐项含义见 §3.8） |
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
| `choices[].logprobs.content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.reasoning_content` | object[] \| nullable | 否 | 一个包含输出 token 对数概率信息的列表。 |
| `choices[].logprobs.reasoning_content[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.reasoning_content[].top_logprobs` | object[] | required | 一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
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

> **Schema 的最后一个字段就是 `usage.completion_tokens_details.reasoning_tokens`**（本次从原始 HTML 确认其后不再有其它响应字段；上一版记录的「截断点之后是否还有字段」这一疑问，答案是没有）。

### 3.3 Example (from schema)

官方 `Example (from schema)` 标签页的完整 JSON（原文照录）：

```json
{
  "id": "string",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "string",
        "reasoning_content": "string",
        "tool_calls": [
          {
            "id": "string",
            "type": "function",
            "function": {
              "name": "string",
              "arguments": "string"
            }
          }
        ],
        "role": "assistant"
      },
      "logprobs": {
        "content": [
          {
            "token": "string",
            "logprob": 0,
            "bytes": [
              0
            ],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0,
                "bytes": [
                  0
                ]
              }
            ]
          }
        ],
        "reasoning_content": [
          {
            "token": "string",
            "logprob": 0,
            "bytes": [
              0
            ],
            "top_logprobs": [
              {
                "token": "string",
                "logprob": 0,
                "bytes": [
                  0
                ]
              }
            ]
          }
        ]
      }
    }
  ],
  "created": 0,
  "model": "string",
  "system_fingerprint": "string",
  "object": "chat.completion",
  "usage": {
    "completion_tokens": 0,
    "prompt_tokens": 0,
    "prompt_tokens_details": {
      "cached_tokens": 0
    },
    "prompt_cache_hit_tokens": 0,
    "prompt_cache_miss_tokens": 0,
    "total_tokens": 0,
    "completion_tokens_details": {
      "reasoning_tokens": 0
    }
  }
}
```

> **原文自身的不一致（如实记录，不作修正）**：在 §3.2 的 Schema 表里，`prompt_cache_hit_tokens` 与 `prompt_cache_miss_tokens` 是 `usage.prompt_tokens_details` 的**子字段**；但在上面这个 `Example (from schema)` 里，它们是 `usage` 的**直接子字段**（与 `prompt_tokens_details` 平级）。本次已回原始 HTML 逐字核对，官方页面确实如此。

### 3.4 Example

官方 `Example` 标签页的完整 JSON（原文照录）：

```json
{
  "id": "930c60df-bf64-41c9-a88e-3ec75f81e00e",
  "choices": [
    {
      "finish_reason": "stop",
      "index": 0,
      "message": {
        "content": "Hello! How can I help you today?",
        "role": "assistant"
      },
      "logprobs": null
    }
  ],
  "created": 1705651092,
  "model": "deepseek-flash",
  "object": "chat.completion",
  "system_fingerprint": "fp_7a09fdf9c2",
  "usage": {
    "completion_tokens": 10,
    "prompt_tokens": 16,
    "total_tokens": 26,
    "prompt_tokens_details": {
      "cached_tokens": 0
    },
    "prompt_cache_hit_tokens": 0,
    "prompt_cache_miss_tokens": 16
  }
}
```

### 3.5 Response Schema（200, Streaming）

官方原文：OK, 返回包含一系列 `chat completion chunk` 对象的流式输出。响应类型：`text/event-stream`。页面同样提供 `Schema` / `Example (from schema)` / `Example` 三个标签页。

| 字段路径 | 类型 | 必填 | 说明（原文照录） |
| --- | --- | --- | --- |
| `id` | string | required | 该对话的唯一标识符。 |
| `choices` | object[] | required | 模型生成的 completion 的选择列表。 |
| `choices[].delta` | object | required | 流式返回的一个 completion 增量。 |
| `choices[].delta.content` | string \| nullable | — | completion 增量的内容。 |
| `choices[].delta.reasoning_content` | string \| nullable | — | 仅适用于思考模式。内容为 assistant 消息中在最终答案之前的推理内容。 |
| `choices[].delta.role` | string | — | **Possible values:** [`assistant`]。产生这条消息的角色。 |
| `choices[].delta.tool_calls` | object[] | — | 模型生成的 tool 调用，例如 function 调用。**每个 tool 调用的第一个 chunk 携带 `id`、`type` 和 `function` 字段，后续 chunk 只携带 `function` 参数。** |
| `choices[].delta.tool_calls[].index` | integer | required | —（原文该字段无说明文字） |
| `choices[].delta.tool_calls[].id` | string | — | tool 的 ID。 |
| `choices[].delta.tool_calls[].type` | string | — | **Possible values:** [`function`]。tool 的类型。目前仅支持 function。 |
| `choices[].delta.tool_calls[].function.name` | string | — | 要调用的 function 名。 |
| `choices[].delta.tool_calls[].function.arguments` | string | — | 要调用的 function 的参数，由模型生成，格式为 JSON。请注意，模型并不总是生成有效的 JSON，并且可能会臆造出你的函数模式中未定义的参数。在调用函数之前，请在代码中验证这些参数。 |
| `choices[].logprobs` | object \| nullable | required | 该 choice 的对数概率信息。 |
| `choices[].logprobs.content` | object[] \| nullable | required | 一个包含输出 token 对数概率信息的列表。 |
| `choices[].logprobs.content[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.content[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.content[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.content[].top_logprobs` | object[] | required | 一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。 |
| `choices[].logprobs.content[].top_logprobs[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.content[].top_logprobs[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.reasoning_content` | object[] \| nullable | 否 | 一个包含输出 token 对数概率信息的列表。 |
| `choices[].logprobs.reasoning_content[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].logprobs.reasoning_content[].top_logprobs` | object[] | required | 一个包含在该输出位置上，输出概率 top N 的 token 的列表，以及它们的对数概率。在罕见情况下，返回的 token 数量可能少于请求参数中指定的 `top_logprobs` 值。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].token` | string | required | 输出的 token。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].logprob` | number | required | 该 token 的对数概率。`-9999.0` 代表该 token 的输出概率极小，不在 top 20 最可能输出的 token 中。 |
| `choices[].logprobs.reasoning_content[].top_logprobs[].bytes` | integer[] \| nullable | required | 一个包含该 token UTF-8 字节表示的整数列表。一般在一个 UTF-8 字符被拆分成多个 token 来表示时有用。如果 token 没有对应的字节表示，则该值为 `null`。 |
| `choices[].finish_reason` | string \| nullable | required | **Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`, `aborted`]。模型停止生成 token 的原因：`stop`：模型自然停止生成，或遇到 `stop` 序列中列出的字符串。`length` ：输出长度达到了模型上下文长度限制，或达到了 `max_tokens` 的限制。`content_filter`：输出内容因触发过滤策略而被过滤。`tool_calls`：模型进行了工具调用。**`insufficient_system_resource`: 由于后端推理资源受限，请求被打断。**`aborted`：生成过程被中断。 |
| `choices[].index` | integer | required | 该 completion 在模型生成的 completion 的选择列表中的索引。 |
| `created` | integer | required | 创建聊天完成时的 Unix 时间戳（以秒为单位）。**流式响应的每个 chunk 的时间戳相同。** |
| `model` | string | required | 生成该 completion 的模型名。 |
| `system_fingerprint` | string | required | This fingerprint represents the backend configuration that the model runs with. |
| `object` | string | required | **Possible values:** [`chat.completion.chunk`]。对象的类型, 其值为 `chat.completion.chunk`。 |

> **两处原文差异（如实记录，不作修正）**：
>
> 1. `insufficient_system_resource` 的说明，非流式 Schema 写「系统推理资源不足，生成被打断。」，流式 Schema 写「由于后端推理资源受限，请求被打断。」——两处措辞不同。
> 2. 流式 Schema 中**没有列出 `usage` 字段**，但官方下方 `Example` 的最后一个 SSE chunk 里确实带有 `usage`。

### 3.6 Example (from schema)（Streaming）

官方 `Example (from schema)` 标签页的完整 JSON（原文照录，外层是一个数组）：

```json
[
  {
    "id": "string",
    "choices": [
      {
        "delta": {
          "content": "string",
          "reasoning_content": "string",
          "role": "assistant",
          "tool_calls": [
            {
              "index": 0,
              "id": "string",
              "type": "function",
              "function": {
                "name": "string",
                "arguments": "string"
              }
            }
          ]
        },
        "logprobs": {
          "content": [
            {
              "token": "string",
              "logprob": 0,
              "bytes": [
                0
              ],
              "top_logprobs": [
                {
                  "token": "string",
                  "logprob": 0,
                  "bytes": [
                    0
                  ]
                }
              ]
            }
          ],
          "reasoning_content": [
            {
              "token": "string",
              "logprob": 0,
              "bytes": [
                0
              ],
              "top_logprobs": [
                {
                  "token": "string",
                  "logprob": 0,
                  "bytes": [
                    0
                  ]
                }
              ]
            }
          ]
        },
        "finish_reason": "stop",
        "index": 0
      }
    ],
    "created": 0,
    "model": "string",
    "system_fingerprint": "string",
    "object": "chat.completion.chunk"
  }
]
```

### 3.7 Example（Streaming, SSE）

官方 `Example` 标签页的完整 SSE 流（原文照录）：

```
data: {"id": "1f633d8bfc032625086f14113c411638", "choices": [{"index": 0, "delta": {"content": "", "role": "assistant"}, "finish_reason": null, "logprobs": null}], "created": 1718345013, "model": "deepseek-flash", "system_fingerprint": "fp_a49d71b8a1", "object": "chat.completion.chunk"}
data: {"choices": [{"delta": {"content": "Hello", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": "!", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " How", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " can", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " I", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " assist", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " you", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": " today", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": "?", "role": "assistant"}, "finish_reason": null, "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1"}
data: {"choices": [{"delta": {"content": "", "role": null}, "finish_reason": "stop", "index": 0, "logprobs": null}], "created": 1718345013, "id": "1f633d8bfc032625086f14113c411638", "model": "deepseek-flash", "object": "chat.completion.chunk", "system_fingerprint": "fp_a49d71b8a1", "usage": {"completion_tokens": 9, "prompt_tokens": 17, "total_tokens": 26, "prompt_tokens_details": {"cached_tokens": 0}, "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 17}}
data: [DONE]
```

> 官方页面的这个示例块在原始 HTML 里以 `Loading...` 占位符结尾，即该段是前端异步渲染的代码块；上面转录的是渲染后的完整内容（含 `data: [DONE]` 结束行）。

### 3.8 finish_reason 枚举值

模型停止生成 token 的原因。**Possible values:** [`stop`, `length`, `content_filter`, `tool_calls`, `insufficient_system_resource`, `aborted`]

| 取值 | 含义（原文照录，非流式 Schema） |
| --- | --- |
| `stop` | 模型自然停止生成，或遇到 `stop` 序列中列出的字符串。 |
| `length` | 输出长度达到了模型上下文长度限制，或达到了 `max_tokens` 的限制。 |
| `content_filter` | 输出内容因触发过滤策略而被过滤。 |
| `tool_calls` | 模型进行了工具调用。 |
| `insufficient_system_resource` | 系统推理资源不足，生成被打断。 |
| `aborted` | 生成过程被中断。 |

### 3.9 补充：/chat/completions 是无状态 API

与 `/chat/completions` 相关的、本次**已抓取到**的补充官方说明（来源：官方「多轮对话」页，`https://api-docs.deepseek.com/zh-cn/guides/multi_round_chat`，上一版抓取）：DeepSeek `/chat/completions` API 是一个“无状态” API，即服务端不记录用户请求的上下文，用户在每次请求时，**需将之前所有对话历史拼接好后**，传递给对话 API。

> 该页本次未重新抓取，该句沿用上一版（2026-09-10）的抓取结果。

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

> **【本项目推导 + 实测校准，非官方原文】**（2026-10-24 增补）
>
> 官方虽未公布「像素 → token」的逐点公式，但官方「图像理解」页（见 §6.4）给出了缩放规则与每张图的 token 上限，据此可反推一个可用的估算式：
>
> 1. **缩放规则（官方原文）**：总像素小于约 544×544 的图片会被保持长宽比**放大**；更大的图片会被保持长宽比**缩小**，缩小后的总像素约相当于 **1300×1300** 的图片。
> 2. **上限（官方原文）**：每张图片消耗的 token 数存在上限（**1024** 个）；「2000×2000 和 5000×5000 的图片，经缩放后消耗的 token 数是相同的」。
> 3. **反推比例**：1300 × 1300 = 1690000 像素对应 1024 token ⇒ 约 **1650 像素 / token**。（两个输入数字都来自官方原文，除数 1650 是它俩相除的结果。）
> 4. **估算式**：`缩放后总像素 = min(1300×1300, max(544×544, 宽 × 高))`；`图片 token ≈ min(1024, 缩放后总像素 ÷ 1650)`。
> 5. **实测校准（本项目，2026-10-24）**：全部走 Anthropic 兼容端点 `https://api.deepseek.com/anthropic`、`thinking.type = "disabled"`、同一张 512×512 纯色 PNG（红 / 蓝两张 242 与 2055 字节）、同一个问法「这张图片的主要颜色是什么？只回答一个中文颜色词。」
>
>    | 请求 | 模型 | `usage.input_tokens` | 回答 | 说明 |
>    | --- | --- | --- | --- | --- |
>    | 文字（不带图，对照） | `deepseek-v4-pro` | 14 | 白色 | 看不见图时的基线 |
>    | 文字 + 纯红图 | `deepseek-v4-pro` | 22 | 蓝色 | 只多 8 token，且答错 |
>    | 文字 + 纯蓝图 | `deepseek-v4-pro` | 22 | 白色 | 与红图同为 22，答案与图像内容无关 |
>    | 文字 + 纯红图 | `deepseek-flash` | 201 | 红色 | 真的看了图 |
>    | 纯红图放在 `tool_result.content` 数组里 | `deepseek-flash` | 485 | 红色 | 工具结果带图的通道可用 |
>    | 纯红图放在 `tool_result.content` 数组里 | `deepseek-v4-pro` | 312 | 自称看到「Unsupported Image」 | 该模型不支持图片输入 |
>
>    由第 1、4 条估算：512×512 = 262144 像素低于 544×544，应被放大到约 295936 像素，295936 ÷ 1650 ≈ 179 token；实测 `deepseek-flash` 那一次是 201（含约 14～22 token 的文字），图片部分约 180～187，与估算吻合。
>
>    **结论**：`deepseek-flash` 能看图；`deepseek-v4-pro` 收下图片但不看（只计 8 token、答案与内容无关），且不报错。
> 6. **使用建议**：这是拟合值，不是官方承诺；做上下文预算时**直接按上限 1024 token/张计**（官方原文数字，只会高估不会低估），要显示给用户的估算值再用第 4 条。

### 6.3 Usage 响应字段

响应中的 `usage` 字段结构见 §3.2（非流式：`completion_tokens` / `prompt_tokens` / `prompt_tokens_details` / `total_tokens` / `completion_tokens_details`）与 §3.3 的示例 JSON。流式响应中 `usage` 出现在最后一个 chunk 上，见 §3.7 最后一个 `data:` 行与 §3.1 的「include_usage 语义」。

### 6.4 图像理解（图片输入）

> **来源**：`https://api-docs.deepseek.com/zh-cn/guides/vision`，2026-10-24 用 `web_fetch` 抓取（HTTP 200，正文完整）。以下官方内容逐字照录，未使用记忆或推测。

`deepseek-flash` 模型支持在文本之外输入图片，你可以让模型描述图片、识别截图中的文字、分析图表等。旧模型名 `deepseek-v4-flash-vision-exp` 仍可调用，但该模型已下线，其请求同样由最新的 Flash 模型承接。

支持的图片格式：**JPEG、PNG、GIF、WebP**。格式由文件实际内容判断，而非文件名或声明的 MIME 类型。

#### 6.4.1 三种传入方式

> 原文：共有三种方式向模型提供图片，均使用标准的 OpenAI 兼容对话补全格式，即 `content` 为一个块（block）数组，而非纯字符串。

| 方式 | 承载字段 | 关键限制（原文） |
| --- | --- | --- |
| 1. Base64 编码图片（内联） | `{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,<DATA>"}}` | 编码后的数据会计入 **48 MiB** 请求体大小限制 |
| 2. 外部图片 URL | `{"type":"image_url","image_url":{"url":"https://…"}}` | URL 长度最多 **8192 个字符**；图片文件最大 **32 MiB**；需在 **60 秒**内完成下载 |
| 3. Files API `file_id` | `{"type":"file","file_id":"file-api-…"}` | 最大可达 **64 MiB**，且不受 32 MiB 单图检查限制 |

第三种方式也可用 `file_data` 以 base64 形式内联携带图片，原文：`file_data` 与 `file_id` 二者互斥，形如 `{"type":"file","file_data":"data:image/jpeg;base64,<DATA>","filename":"image.jpg"}`。

#### 6.4.2 细节级别（Detail Level）

> 原文：对于 `image_url` 输入，你可以选填 `detail` 字段来控制图片的处理方式。

| 取值 | 行为（原文） |
| --- | --- |
| `low` | 推理前将图片缩放到 512×512。当不需要精细视觉细节时更快、更省 token。 |
| `high` | 保留原图。（为兼容性提供，等价于 `original`。） |
| `original` | 保留原图。 |
| `auto` | 自动选择。当前等价于 `original`。 |

#### 6.4.3 限制（原文表格逐字照录）

| 限制项 | 数值 |
| --- | --- |
| 支持的格式 | JPEG、PNG、GIF、WebP |
| 外部 URL 长度 | 8192 个字符 |
| 请求体大小 | 48 MiB |
| 单张图片最大大小（base64 / 外部 URL） | 32 MiB |
| 单张图片最大大小（Files API `file_id`） | 64 MiB |
| 单个请求最大图片数 | 600 |
| 单个请求图片总大小 | 不含 `file_id` 图片最多 64 MiB；包含 `file_id` 图片最高 200 MiB |
| 图片最大尺寸 | 单边最长 8192 像素；单个请求包含 15 张及以上图片时，降为单边最长 4096 像素 |

#### 6.4.4 使用限制（原文）

- 图片仅支持出现在 `user` 消息中。`system` 或 `assistant` 消息携带图片会返回 `400` 错误。

#### 6.4.5 通过 Anthropic 兼容端点（`/messages`）传图

> 原文：除了上面的 OpenAI 兼容端点，你也可以通过 Anthropic 兼容的 `/messages` 端点发送图片（`base_url` 为 `https://api.deepseek.com/anthropic`）。基础配置请参考 [Anthropic API](https://api-docs.deepseek.com/zh-cn/guides/anthropic_api)。区别在于图片内容块的结构。Anthropic 不使用 `image_url`，而是使用 `image` 块，其 `source` 对象的 `type` 为 `base64`、`url` 或 `file` 之一。

| `source.type` | 对应的 OpenAI 方式 | 说明（原文） |
| --- | --- | --- |
| `base64` | Base64 编码图片 | 需要 `media_type` 字段（`image/jpeg`、`image/png`、`image/gif` 或 `image/webp`）。 |
| `url` | 外部图片 URL | 最多 8192 个字符。 |
| `file` | Files API `file_id` | 需要请求头 `anthropic-beta: files-api-2025-04-14`。 |

原文示例（Anthropic SDK，`model="deepseek-flash"`，`content` 数组里的图片块）：

```python
{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "<BASE64_DATA>"}}
```

> **本项目备注（非官方）**：该页没有为 Anthropic 端点的 `image` 块列出 `detail` 字段（只有 §6.4.2 说的 `image_url` 输入可填）。因此走 `/messages` 时无法用 `detail: "low"` 让服务端把小图按 512×512 处理；要省 token 只能在客户端自己缩小后再送（见 §6.2 的估算式）。

#### 6.4.6 Token 用量（原文）

图片会根据其尺寸换算成 token，并与文本 token 一起计费。

在进入模型前，每张图片都会被自动缩放：

- 总像素小于约 544×544 的图片会被保持长宽比放大；
- 更大的图片会被保持长宽比缩小，缩小后的总像素约相当于 **1300×1300** 的图片。

因此，每张图片消耗的 token 数存在上限（**1024** 个）：例如 2000×2000 和 5000×5000 的图片，经缩放后消耗的 token 数是相同的。单个请求包含多张图片时，每张图片独立按同一规则计算，不存在额外的计算方式。

如需估算具体尺寸图片的 token 消耗，请使用 [Token 与用量计算](https://api-docs.deepseek.com/zh-cn/quick_start/token_usage) 页面的图片 Token 计算器。

> **本项目备注（非官方）**：第 6.2 节末尾那段「缩放后总像素 ÷ 1650」的估算式就是据此反推的，含推导与实测校准，**不是官方公式**。

---

## 7. 本项目相关要点

### DeepSeek Anthropic 兼容 API 与官方 Anthropic API 的关键差异

> **本节依据**：**仅**依据本次抓取到的 DeepSeek 官方「使用 Anthropic API」页面（`https://api-docs.deepseek.com/zh-cn/guides/anthropic_api`，中英文版互校）中的「支持情况」列，以及本次抓取的其它官方页面（§2.7、§4）。官方 Anthropic API 规范细节**不在本次抓取范围内**，故本节不做“官方 Anthropic 如何如何”的断言，只陈述 **DeepSeek 侧明确记载的行为**。

**入口与鉴权**

1. `base_url` 为 `https://api.deepseek.com/anthropic`（官方 Anthropic 的端点路径不同；DeepSeek 侧文档只给出该 base_url）。
2. `anthropic-version` 请求头被**忽略**——无需（也不校验）版本头。
3. `anthropic-beta` 请求头在 `/messages` 上被**忽略**；仅在 Files API 端点**必须**携带（`files-api-2025-04-14`）。
4. `x-api-key` **完全支持**。

**模型名**

5. `model`：「改为使用 DeepSeek 模型」。传入不支持的模型名时后端自动映射到 `deepseek-flash`。
6. claude 模型名会被映射：`claude-opus*` → `deepseek-v4-pro`（按 V4 Pro 价格计费）；`claude-haiku*` / `claude-sonnet*` → `deepseek-flash`。据此可在 Claude Desktop APP developer 模式下仅改 base_url 与 api_key 接入。
7. 走 Anthropic 兼容入口时，`model` 的合法取值来自 §3.1 的枚举 [`deepseek-flash`, `deepseek-v4-pro`]。

**请求字段：被忽略 / 仅部分支持（对本项目最关键的差异面）**

8. **忽略**的字段：`container`、`mcp_servers`、`service_tier`、`top_k`；tools 的 `cache_control`；text 块的 `cache_control` 与 `citations`；tool_use 块的 `cache_control`；tool_result 块的 `cache_control` 与 `is_error`。
   - 推论（工程影响）：**`cache_control` 不生效**，按 Anthropic 习惯打缓存断点无效；**`tool_result.is_error` 不生效**，工具失败信息不能依赖该标记传递，须写进 `content`。
9. `metadata`：**仅** `user_id` 支持，其它字段忽略（`user_id` 可用于限速与隔离）。
10. `thinking`：支持（开关为 `{"thinking": {"type": "enabled/disabled"}}`），但 **`budget_tokens` 被忽略**。
11. `output_config`：**仅支持 `effort`**（`low` / `high` / `max`），这是 Anthropic 格式的强度控制；`reasoning` / `reasoning_effort` 属 OpenAI 与 Responses API 格式，**不是 Anthropic 路径的字段**（§2.7.1 列归属已确认）。
12. `top_p`：**仅思考模式下生效**（下限 `0.95`）；**非思考模式下恒为 `1.0`**，传入值被忽略。
13. `temperature`：完全支持，范围 `[0.0 ~ 2.0]`（但在思考模式下不生效，见 §2.7.3）。
14. `max_tokens`、`stop_sequences`、`stream`、`system`：完全支持。

**工具字段**

15. `tools`：`name` / `input_schema` / `description` 完全支持。
16. `tool_choice`：`none` 完全支持；`auto` / `any` / `tool` 支持，但 **`disable_parallel_tool_use` 被忽略**（即无法通过该开关禁止并行工具调用）。

**消息内容块：不支持的类型（会导致该块无法使用）**

17. **不支持**：`document`、`search_result`、`redacted_thinking`、`code_execution_tool_result`、`mcp_tool_use`、`mcp_tool_result`、`container_upload`。
18. **支持**：`text`、`image`（`source.type` 可为 base64（jpeg/png/gif/webp）、url、file（需 `anthropic-beta: files-api-2025-04-14` 头））、`thinking`、`tool_use`（`id`/`input`/`name`）、`tool_result`（`tool_use_id`/`content`）、`server_tool_use`、`web_search_tool_result`；`content` 为 string 时完全支持。

**对话结构能力（本项目 Agent 循环直接相关）**

19. Anthropic API（`/messages`）**支持在对话中间插入工具调用消息**，也**支持在对话中间插入 `system` 消息**；Chat Completion 接口**不支持**在对话中间插入工具调用（但支持中间插入 `system` 消息）。（来源：§4.3 官方 Tool Calls 页面）

**思考模式往返（本项目上下文压缩与工具循环直接相关，来源 §2.7.3 / §2.7.4）**

20. 携带 `tools` 的请求，**历史轮次的 `reasoning_content` 必须完整回传**，否则 API 返回 `400`；未携带 `tools` 时 `reasoning_content` 无需回传，传了也被忽略。
21. 思考模式**默认开启**（`thinking.type` 默认 `enabled`，effort 默认 `high`）⇒ **不发送 `thinking` 字段不等于关闭思考**（与 §2.7.5 实测一致）。

**本项目落地时的检查清单（由上述条款直接推出）**

- 走 Anthropic 兼容端点时不要指望 `anthropic-version` 校验，也不要指望 `/messages` 上的 beta 头生效；
- 不要把 prompt 缓存寄托在 `cache_control` 上（被忽略）；
- 工具错误不要靠 `is_error` 传（被忽略），要写进 `tool_result.content`；
- 想限制并行工具调用不能用 `disable_parallel_tool_use`（被忽略）；
- 思考预算不能用 `budget_tokens` 控制（被忽略）；Anthropic 路径上开关用 `thinking.type`、强度用 `output_config.effort`，**不要用 `reasoning` / `reasoning_effort`**；
- 非思考模式下 `top_p` 恒为 1.0；思考模式下有效范围 0.95–1.0，低于 0.95 按 0.95 处理；
- 不要发送 `document` / `search_result` / `redacted_thinking` / `mcp_*` / `code_execution_tool_result` / `container_upload` 内容块；
- 若需要在对话历史中间插入工具调用消息，必须走 Anthropic API 或 Responses API，不能用 Chat Completions；
- 只要请求带 `tools`，就不要丢历史 `reasoning_content`（否则 400）。

---

## 8. 来源

| 页面 | URL | 抓取状态（2026-09-20） |
| --- | --- | --- |
| 首次调用 API（中文） | https://api-docs.deepseek.com/zh-cn/ | ✅ 成功（HTTP 200，1 次成功；另用 `curl.exe` 取原始 HTML 44479 字节复核，确认脚注 (2) 已移除） |
| 使用 Anthropic API（中文，§2 主源） | https://api-docs.deepseek.com/zh-cn/guides/anthropic_api | ✅ 成功（HTTP 200，内容完整；另取原始 HTML 31290 字节复核） |
| 使用 Anthropic API（英文，§2 对照） | https://api-docs.deepseek.com/guides/anthropic_api | ✅ 成功（HTTP 200；HTTP Header / Simple Fields / Tool Fields / Message Fields 四张表与中文版逐条对应一致） |
| Chat Completions API（中文，§3 主源） | https://api-docs.deepseek.com/zh-cn/api/create-chat-completion | ✅ **本次已完整取得**。`web_fetch` 仍在 `usage.completion_tokens_details.reasoning_tokens` 处截断（与上一版同一位置，已复现）；改用 `curl.exe -L` 取原始 HTML（HTTP 200，经 1 次 302 跳转到带尾斜杠地址，145964 字节）后取得全部内容，含 `Example (from schema)`、`Example` 与 `200 (Streaming)` 的 Schema / 两个示例 |
| Tool Calls（中文，§4 主源） | https://api-docs.deepseek.com/zh-cn/guides/tool_calls | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| 错误码（中文，§5 主源） | https://api-docs.deepseek.com/zh-cn/quick_start/error_codes | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| Token 用量计算（中文，§6 主源） | https://api-docs.deepseek.com/zh-cn/quick_start/token_usage | ✅ 成功（HTTP 200，1 次成功，内容完整） |
| 图像理解（中文，§6.4 主源；2026-10-24 增补） | https://api-docs.deepseek.com/zh-cn/guides/vision | ✅ 成功（2026-10-24 抓取，HTTP 200，正文完整：三种传图方式、Detail Level 表、限制表、使用限制、Anthropic/Responses 两节俱全，未触发 `web_fetch` 截断） |
| 思考模式（中文，§2.7 来源，非任务指定） | https://api-docs.deepseek.com/zh-cn/guides/thinking_mode | ✅ **本次已完整取得**（上一版此处被截断）。`curl.exe -L` 取原始 HTML 108003 字节，取得控制参数表（含 `colspan`/`rowspan` 结构）、两个多轮样例代码、工具调用样例与说明 |

**未能覆盖的章节 / 内容（如实记录）**

1. **§3.1 `messages` 数组**：`messages` 的 `oneOf` 四个变体中，**User message / Assistant message / Tool message 三个变体的字段明细未能抓取到**。这不是长度截断，而是官方页面把它们放在**嵌套标签页**里，服务端返回的 HTML 中只有 System message 面板的字段；对原始 HTML 检索 `User message` / `Assistant message` / `Tool message` / `tool_call_id`，各只出现 1 次（标签文字本身），无字段明细。**本文件不列其字段，也不以记忆补写。**
2. **§2 开头「将 DeepSeek 模型接入 Claude Code」**：官方该小节只有一句指引，指向 `https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code`；该指南页不在本次抓取范围，未收录其内容。
3. **§2.7.3 与 §2.7.4 的示意图**：官方页面各配有一张调用流程示意图，属前端图片资源，本文件未收录图片本身。
4. **§2.7.4 的样例输出**：官方给出该工具调用样例的完整运行输出（Turn 1.1 ~ Turn 2.2），属运行输出而非接口定义，本文件未逐行转录。
5. **§6.2 图片 Token 计算器**：官方为前端交互组件，抓取到的页面文本中**仍不含其计算公式**（2026-10-24 抓取的「图像理解」页也没给公式，只给了缩放规则与每张图 1024 token 的上限，见 §6.4；据此反推的估算式见 §6.2 末尾那一段，已标注为本项目推导）。
6. **§1.4 的 `python` / `nodejs` 标签页**：官方「调用对话 API」提供三个标签页，本文件只照录了 `curl` 标签页。
7. **§3.9 的无状态说明**：来自「多轮对话」页，本次未重新抓取，沿用上一版结果。

**本次抓取方式说明（供复核）**

- 正文优先用 `web_fetch`；`web_fetch` 出现正文长度截断或需要核对 HTML 结构（表格 `colspan`/`rowspan`、嵌套标签页）时，改用 `curl.exe -sL <url>` 取原始 HTML，再用 PowerShell 去标签后逐字转录。
- `https://api-docs.deepseek.com/zh-cn/api/create-chat-completion` 直接 GET 返回 **302**，`Location: /zh-cn/api/create-chat-completion/`；必须跟随重定向（`curl -L`）才能取到正文。
- 所有转录内容均未使用记忆或推测；发现官方页面自相矛盾之处（§3.3 的 `prompt_cache_*` 层级、§3.5 的 `insufficient_system_resource` 措辞与缺失的 `usage` 字段）均在原处如实标注，未作"修正"。
