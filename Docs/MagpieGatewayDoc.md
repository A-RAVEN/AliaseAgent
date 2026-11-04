# Magpie 网关事实源

本文只记录**外部事实**：`yetone/magpie` 网关的公开文档原文与本机实测响应。产品侧如何使用这些字段写在
`openspec/specs/provider-model-discovery/spec.md` 与 `Docs/user-guide/provider-models.md`，不在这里重复。

## 来源与抓取时间

- 来源仓库：`yetone/magpie`
- README 来源 URL：`https://github.com/yetone/magpie/blob/main/README.md`
- 字段语义来源 URL：`https://github.com/yetone/magpie/blob/main/docs/reference.md`
- 抓取时间：2026-11-04（Asia/Hong_Kong）
- 实测端点：`http://127.0.0.1:3425/v1/models`（本机 `magpie-windows-amd64.exe`，HTTP 200，共 10 条模型、3 个上游）
- 抓取方式：`GET /v1/models` 用 `System.Net.WebClient.DownloadData` 取原始字节后按 UTF-8 解码（避免 PowerShell 5.1
  用错字符集把 `·` 读成 `Â·`）；`docs/reference.md` 经 GitHub Contents API
  （`https://api.github.com/repos/yetone/magpie/contents/docs/reference.md`，返回 base64，解码后 239768 字符）取回。

## `GET /v1/models` 实测响应

顶层形状是 `{"data":[...]}`，每个模型是 `data` 数组里的一个对象。该端点**免鉴权可达**；带上
`x-api-key` 与 `anthropic-version: 2023-06-01` 两个头同样返回 200（与产品对话请求同源的鉴权头）。

下面两条是从 2026-11-04 那次真实响应里逐字摘出的完整对象（字段顺序、空白与数值都保持原样，未做格式化）：

`kimi/kimi-for-coding`：

```json
{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"K2.8 Preview","id":"kimi/kimi-for-coding","magpie_label":"K2.8 Preview · Kimi Code","max_input_tokens":1048576,"max_output_tokens":32768,"modalities":{"input":["text","image","video"],"output":["text"]},"native_endpoints":["/v1/chat/completions","/v1/messages"],"object":"model","owned_by":"kimi","reasoning":true,"reasoning_levels":["none","low","high","max"],"supported_reasoning_levels":[{"effort":"none"},{"effort":"low"},{"effort":"high"},{"effort":"max"}],"type":"model"}
```

`deepseek/deepseek-flash`：

```json
{"context_length":1048576,"context_window":1048576,"created":0,"created_at":"2025-01-01T00:00:00Z","display_name":"DeepSeek-V4.1-Flash","id":"deepseek/deepseek-flash","magpie_label":"DeepSeek-V4.1-Flash · DeepSeek","max_input_tokens":1048576,"max_output_tokens":393216,"modalities":{"input":["text","image"],"output":["text"]},"native_endpoints":["/v1/chat/completions","/v1/responses","/v1/messages"],"object":"model","owned_by":"deepseek","pricing":{"completion":"0.0000006","input_cache_read":"0.000000003","prompt":"0.00000015"},"reasoning":true,"reasoning_levels":["none","low","high","max"],"supported_reasoning_levels":[{"effort":"none"},{"effort":"low"},{"effort":"high"},{"effort":"max"}],"type":"model"}
```

这两条同时钉住了本 change 依赖的几个实测数字与取值：`context_window` 是 `1048576`；`deepseek/deepseek-flash`
的 `modalities.input` 是 `text` + `image`；`kimi/kimi-for-coding` 的 `modalities.input` 含 `video`；
`supported_reasoning_levels[].effort` 出现 `none` / `low` / `high` / `max`；`deepseek/deepseek-flash` 带
`pricing`，`kimi/kimi-for-coding` 没有 `pricing`（未知就整个省略，不写 0）。

## 字段语义英文原文（reference.md）

### `native_endpoints`

所在小节：`### Connecting anything else`

```text
`native_endpoints` (`["/v1/messages"]`) names the APIs a request for the model is passed straight through on; it is left out of a routing group, and of a model every request to which is translated anyway.
```

含义（本文作者的直译，仅供产品理解，不替代原文）：它标的是"哪些协议路径原生直通"；路由组、以及每个请求都要翻译的模型，
整个省略这个字段。

### `reasoning_levels`

所在小节：`### Connecting anything else`

```text
Each `/v1/models` entry includes `reasoning` and `supported_reasoning_levels` (`[{"effort":"low"}, ...]`), and the same levels as plain names in `reasoning_levels` (`["low", ...]`, `[]` when there are none), which clients of the Catwalk schema (Crush and kin) read (#2576).
```

含义：`reasoning_levels` 是纯名字数组；**没有任何已知档位时是 `[]`**，这是合法语义，不是解析失败。

### `pricing`

所在小节：`#### Agent plugins`

```text
Each is left out when it isn't known (a routing group has no `native_endpoints`, an unpriced model no `pricing`), never empty or 0:
```

含义：`native_endpoints` 与 `pricing` 都是"未知就整个省略、绝不补空集合或 0"；所以产品不能把"缺这个字段"读成
"这个模型不能用"。

## DeepSeek Anthropic 兼容端点对照

同一台机器上对 DeepSeek 的 Anthropic 兼容端点做同一请求（基址取本机 `~/.aliasagent/config.json` 里
`providers.anthropic.base_url` 的值 `https://api.deepseek.com/anthropic`，再拼 `/v1/models`）：

请求原文：

```text
GET https://api.deepseek.com/anthropic/v1/models
x-api-key: <已略去：用户配置里的密钥，长度 35；密钥不得进入文档与日志>
anthropic-version: 2023-06-01
```

响应原文：

```text
HTTP/1.1 404 Not Found
（无响应体，Content-Length: 0）
```

对照：同一个地址不带 `x-api-key` 时返回 `401 Authorization Required`；带上密钥后返回 `404 Not Found`。
结论是这条 Anthropic 兼容端点没有模型目录路由（404），不是鉴权问题。DeepSeek 的模型目录在别的方言下
（平铺 `input_modalities`、`effort.supported_levels`），本产品本期只按 magpie 方言解析，见
`openspec/changes/add-provider-model-discovery/design.md` 的 D5 与 proposal 的「不做」。
