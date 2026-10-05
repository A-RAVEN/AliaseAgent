# deepseek-search-provider Specification

## Purpose

用 DeepSeek 自带的搜索能力当 `web_search` 的一个后端：不新增密钥、不新增账号，配好 DeepSeek 模型的人就有搜索。规范性重点在五处：凭据从哪来（复用会话模型那把，允许覆盖）、请求按固定形状发（一次完整模型调用 + 一个服务端搜索工具）、返回只认结构化的结果块（不拿模型写的回答当结果）、摘要可能为空时的处置、以及失败必须说得清（尤其是"压根没触发搜索"不能伪装成"没搜到"）。范围之外：把搜索结果塞进会话的流式装配链、一次请求连搜多轮、其它免费搜索路线。

## ADDED Requirements

### Requirement: 搜索后端与凭据来源（绝不把非 DeepSeek 的密钥发出去）

系统 SHALL 提供一个名为 `deepseek` 的搜索后端，与既有的 `zhipuai`、`kimi` 并列，实现同一个搜索后端接口（输入：查询、深度、条数上限；输出：一组 `{标题, 网址, 正文}` 与一条错误）。

**凭据只允许来自两处，其它一律不用**：

① `search.deepseek.api_key` / `search.deepseek.base_url`（写了就用写的）；
② **仅当**会话模型当前 provider 的地址**确实指向 DeepSeek**（地址中含 `api.deepseek.com`）**且** `search.deepseek` 段存在时，才允许回落复用它那一把密钥与地址。

**硬规矩**：只要这一份配置里要动用的**是**会话模型那把密钥**或**它的地址（也就是自己没把密钥与地址两样都写全），地址不是 DeepSeek 时该后端 SHALL 直接报告不可用，SHALL NOT 回落复用那把密钥、SHALL NOT 向该地址发出任何请求（不是"发出去再失败"，是根本不发）。`search` 段里没有 `deepseek` 这一项时，该后端 SHALL NOT 出现在可用清单里（除非它按第 ② 条回落成功）。

自己**同时写了** `api_key` 与 `base_url` 时，用的是这两份、没碰会话模型的任何东西，因此地址可以不指向 DeepSeek；这时该后端 SHALL 报告可用，并让地址写错这件事在失败说明里看得见（见下面"条数截断与错误说明"那条要求）。

`search.deepseek.model` SHALL 决定那次调用用的模型，缺省为一个固定的轻量模型；写了就用写的。搜索用的地址 SHALL 与会话模型的地址在配置上分开，SHALL NOT 因为会话模型换了地址就静默改用另一个端点。

#### Scenario: 自己写了密钥时用它

- **WHEN** `search.deepseek` 里写了 `api_key` 与 `base_url`
- **THEN** 该后端 SHALL 用这一份，SHALL NOT 去碰会话模型那把密钥

#### Scenario: 模型配的也是 DeepSeek 且写了 deepseek 段时回落

- **WHEN** 会话模型的 provider 地址是 `https://api.deepseek.com/anthropic`，`search.deepseek` 段存在但没写 `api_key`
- **THEN** 该后端 SHALL 复用它那把密钥与地址并报告可用

#### Scenario: 模型配的不是 DeepSeek 时绝不碰那把密钥

- **WHEN** 会话模型的 provider 地址不是 DeepSeek（例如某个自建网关），而 `search.deepseek` 里没写 `api_key`
- **THEN** 该后端 SHALL 报告不可用，且 SHALL NOT 向那个地址发出任何请求（测试要断言"没有请求发出"，而不是"请求失败了"）

#### Scenario: 自己把密钥与地址都写全时用它，地址可以不指向 DeepSeek

- **WHEN** `search.deepseek` 里同时写了 `api_key` 与 `base_url`，而那个地址不是 DeepSeek（例如用户自己的网关）
- **THEN** 该后端 SHALL 用这一份并报告可用（没有动用会话模型的任何东西），该次搜索失败时错误说明里 SHALL 带这个地址

#### Scenario: 只写了密钥、地址仍来自会话模型时受地址闸门管

- **WHEN** `search.deepseek` 里只写了 `api_key`，会话模型的地址不是 DeepSeek
- **THEN** 该后端 SHALL 报告不可用，且 SHALL NOT 发出任何请求

#### Scenario: 什么都没写时不出现

- **WHEN** `search` 段里没有 `deepseek` 这一项，会话模型的地址也不是 DeepSeek
- **THEN** 该后端 SHALL 报告不可用、不出现于清单；搜索初始化 SHALL 仍然成功

### Requirement: 请求按固定形状发出

后端 SHALL 向 `<搜索地址>/messages` 发一次 POST，请求体为：`{"model": <配置的模型>, "max_tokens": <固定上限>, "messages": [{"role":"user","content":[{"type":"text","text":"Perform a web search for the query: <查询>"}]}], "tools": [{"type":"web_search_20250305","name":"web_search","max_uses":1}]}`。请求 SHALL 带上密钥头与 `anthropic-version: 2023-06-01`；SHALL NOT 使用流式（要的是结构化结果块，不是逐字文本）。`max_uses` SHALL 固定为 1。请求 SHALL 有超时，到点按失败处理。

#### Scenario: 请求形状可核

- **WHEN** 拦截该后端发出的请求（单测里用假的传输层或核对构造出的请求体）
- **THEN** 它 SHALL 与上面的形状逐项一致：查询出现在那句固定前缀之后、服务端搜索工具的 `type` 为 `web_search_20250305`、`max_uses` 为 1、请求头里有版本号，且请求体里没有流式开关

#### Scenario: 超时算失败

- **WHEN** 端点在该后端的超时时间内没有响应
- **THEN** 该次搜索 SHALL 返回失败（带可读说明），SHALL NOT 挂住不放

### Requirement: 只认结构化的结果块

后端 SHALL 只从返回里 `type == "web_search_tool_result"` 的块取结果：块里每条 `type == "web_search_result"` 的条目取 `网址`、`标题`、`日期`（`page_age`，可为空）；同一网址 SHALL 只保留一次（按出现顺序去重）。返回里那段"模型写的回答文字"（`type == "text"` 的块）SHALL NOT 作为结果内容；它只允许被用来读引用片段（见下一条）。

`HTTP 200` 但返回里**没有**任何结构化结果块时，SHALL 返回失败并说明"这次调用没有触发服务端搜索"，SHALL NOT 回退成把模型写的文字当结果、也 SHALL NOT 当成"搜到 0 条"。

#### Scenario: 结果块被映射成搜索结果

- **WHEN** 返回里有 `web_search_tool_result` 块，内含两条不同网址的 `web_search_result`
- **THEN** 搜索结果 SHALL 是两条，各自带网址与标题（标题为空时允许为空串），并按网址去重

#### Scenario: 同一网址出现两次只留一条

- **WHEN** 返回里两个结果块里出现同一个网址
- **THEN** 结果里该网址 SHALL 只出现一次

#### Scenario: 没有结果块时明确报错

- **WHEN** 返回是 `HTTP 200`，内容块里只有 `text` 与 `thinking`，没有任何 `web_search_tool_result`
- **THEN** 该次搜索 SHALL 返回失败，错误说明里 SHALL 指出"没有触发服务端搜索"；SHALL NOT 返回模型写的那段文字、也 SHALL NOT 返回"0 条结果算成功"

#### Scenario: 模型写的回答不作为结果内容

- **WHEN** 返回里同时有 `text` 块（一篇回答）与 `web_search_tool_result` 块
- **THEN** 每一条搜索结果的正文 SHALL NOT 是那段回答的整体或片段（只允许来自引用片段或标题兜底）

### Requirement: 摘要与标题的处置

每条结果的正文 SHALL 按这个顺序取：① 若返回里 `text` 块的 `citations` 里有与该网址匹配的 `cited_text`，用它；② 否则用标题兜底，并在实现里明确标记这是"没有摘要"而不是真摘要。正文 SHALL NOT 被塞入编造的内容。标题里出现非法字节时 SHALL NOT 让解析失败（按仓库既有做法替换成替换字符）。

#### Scenario: 有引用片段时用它当正文

- **WHEN** 返回的 `text` 块里有 `citations`，其中一条的网址与某条结果相同、且带 `cited_text`
- **THEN** 那条结果的正文 SHALL 等于该 `cited_text`

#### Scenario: 没有引用时用标题兜底

- **WHEN** `text` 块没有 `citations`（实测经常如此）
- **THEN** 每条结果的正文 SHALL 用标题兜底，SHALL NOT 为空、SHALL NOT 是编造的句子

#### Scenario: 标题含非法字节不崩

- **WHEN** 某条结果的标题里含有非法的 UTF-8 字节序列
- **THEN** 解析 SHALL 成功完成，该标题里的坏字节 SHALL 被替换字符取代，其余结果的标题不受影响

#### Scenario: 日期为空是正常情况

- **WHEN** 结果条目的 `page_age` 为空
- **THEN** 它 SHALL 被当成正常结果（日期为空），SHALL NOT 让这条结果被丢弃、也 SHALL NOT 让整次搜索失败

### Requirement: 条数截断与错误说明

服务端不提供"要几条"的参数，因此 `max_results` SHALL 由后端在映射完成后按顺序截断（保留前面的）。任何失败（凭据不可用、网络失败、HTTP 非 200、超时、没有结果块）SHALL 返回一条可读说明，并在说明里带上**本次实际使用的搜索地址**，好让"端点配错了"与"查询写错了"能区分开。

#### Scenario: 超出上限时截断

- **WHEN** 服务端返回 10 条结果、调用方给的上限是 3
- **THEN** 返回的结果 SHALL 只有 3 条，且是前 3 条

#### Scenario: 失败说明里带实际端点

- **WHEN** 该次搜索失败（例如地址不可达）
- **THEN** 错误说明 SHALL 含本次实际使用的地址，便于判断是不是端点配错
