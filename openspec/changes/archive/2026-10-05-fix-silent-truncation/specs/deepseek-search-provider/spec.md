# deepseek-search-provider Specification

## MODIFIED Requirements

### Requirement: 请求按固定形状发出
后端 SHALL 向 `<搜索地址>/messages` 发一次 POST，请求体为：`{"model": <配置的模型>, "messages": [{"role":"user","content":[{"type":"text","text":"Perform a web search for the query: <查询>"}]}], "tools": [{"type":"web_search_20250305","name":"web_search","max_uses":1}]}`。请求 SHALL 带上密钥头与 `anthropic-version: 2023-06-01`；SHALL NOT 使用流式（要的是结构化结果块，不是逐字文本）。`max_uses` SHALL 固定为 1。请求 SHALL 有超时，到点按失败处理。

**输出长度 SHALL NOT 由本项目钉死**：请求体里 SHALL NOT 出现 `max_tokens`（或任何等价的本项目自定上限），输出长度交给平台默认 —— `Docs/DeepSeekAPIDoc.md` 记着该参数的取值范围与"未设置时的默认值"。这样做的原因是：本项目的取值只能靠猜，而猜小了会把结果砍掉、猜大了又不解决任何问题。

#### Scenario: 请求形状可核

- **WHEN** 拦截该后端发出的请求（单测里用假的传输层或核对构造出的请求体）
- **THEN** 它 SHALL 与上面的形状逐项一致：查询出现在那句固定前缀之后、服务端搜索工具的 `type` 为 `web_search_20250305`、`max_uses` 为 1、请求头里有版本号，且请求体里没有流式开关、**没有 `max_tokens`**

#### Scenario: 超时算失败

- **WHEN** 端点在该后端的超时时间内没有响应
- **THEN** 该次搜索 SHALL 返回失败（带可读说明），SHALL NOT 挂住不放

## ADDED Requirements

### Requirement: 输出被截断时必须报错
返回顶层 `stop_reason` 为 `"max_tokens"` 时（本地文档：`Docs/AnthropicAPIDoc.md` 第 1.5.1 节「`"max_tokens"`: we exceeded the requested `max_tokens` or the model's maximum」），后端 SHALL 把这次搜索判为失败，说明里 SHALL 写清"输出被截断、本次结果可能不全"并附上实际读到的 `stop_reason` 原文。其它取值（例如 `"end_turn"`）SHALL NOT 影响正常解析。这一条 SHALL NOT 依赖"设一个自己的上限"来实现 —— 它是对平台行为的观测。

#### Scenario: 截断被报出来

- **WHEN** 返回里 `stop_reason` 为 `"max_tokens"`
- **THEN** 该次搜索 SHALL 返回失败，错误说明里含"截断"字样与 `max_tokens` 原文；SHALL NOT 把已经拿到的部分结果当成功返回而不做任何说明

#### Scenario: 正常结束不受影响

- **WHEN** 返回里 `stop_reason` 为 `"end_turn"`
- **THEN** 结果 SHALL 正常解析，SHALL NOT 因为这条要求而报错
