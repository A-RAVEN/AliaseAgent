# web-search Specification

## Purpose

说清"搜索"这件事在本项目里是怎么组织的：模型看到一个 `web_search` 工具，工具背后是一份**后端清单**，每个后端各有自己的凭据来源与可用性判断；清单为空时工具不出现（而不是出现一个永远失败的按钮）。这份规范此前不存在 —— 本变更把这份清单与它的可用性规则补上，并把 `deepseek` 作为其中的第三个后端。范围之外：具体某个后端的请求细节（那是各后端自己的规范）、搜索结果的界面渲染（归工具结果显示那份规范）。

## ADDED Requirements

### Requirement: 后端清单与可用性

系统 SHALL 支持多个搜索后端，每个后端 SHALL 声明自己的名字与一句人能看懂的说明，并 SHALL 自己判断"我配好了没有"。可用的后端 SHALL 组成一份清单；一次搜索 SHALL 只发给本次调用指定的后端，未指定时发给全部可用后端。

至少 SHALL 支持这三个：`zhipuai`、`kimi`、`deepseek`。前两个需要各自在 `search` 段配密钥；`deepseek` 的凭据来源见 `deepseek-search-provider` 那份规范（自己写一份，或**仅当模型地址确实指向 DeepSeek 时**回落复用）。

#### Scenario: 可用清单反映真实配置

- **WHEN** 配置里写了 `search.deepseek` 且密钥可用
- **THEN** 可用后端清单 SHALL 至少包含 `deepseek`；清单里 SHALL NOT 出现没有配好凭据的后端

#### Scenario: 指定后端时只发给它

- **WHEN** 一次 `web_search` 调用指定了 `providers: ["kimi"]`
- **THEN** 这次搜索 SHALL 只调用 `kimi`，SHALL NOT 调用清单里的其它后端

### Requirement: 搜索工具的可见性

`web_search` 工具 SHALL 只在**可用后端清单非空**时出现在发给模型的工具定义里；清单为空时该工具 SHALL 完全不出现（而不是出现一个调用必然失败的工具）。这份清单 SHALL 在决定工具可见性的那一刻按当前配置算出来。

#### Scenario: 有 DeepSeek 模型就有搜索工具

- **WHEN** 会话模型用的是 Anthropic 兼容的 DeepSeek 端点且密钥齐全，`search` 段为空
- **THEN** 发给模型的工具定义里 SHALL 含 `web_search`（这条行为与改动前不同：以前必须有付费搜索密钥才有）

#### Scenario: 清单为空时工具不出现

- **WHEN** 所有后端都不可用
- **THEN** 工具定义里 SHALL 没有 `web_search`，SHALL NOT 用一个空清单去注册这个工具

### Requirement: 搜索入口的输入与返回形状

`web_search` 对模型暴露的参数 SHALL 保持不变：`query`（必填）、`providers`（可选，指定后端）、`depth`（可选）、`max_results`（可选，条数上限）。返回 SHALL 保持不变：按后端分组的命名空间结构，每组里是结果条目（标题、网址、正文）与可能的错误。新增后端 SHALL NOT 改变这两个形状。

#### Scenario: 形状不变

- **WHEN** 新增 `deepseek` 后端之后，模型调用 `web_search` 并得到结果
- **THEN** 返回 SHALL 仍是按后端分组的命名空间结构，条目字段仍是标题、网址、正文；SHALL NOT 出现只属于某个后端的私有字段

#### Scenario: 一个后端失败不影响别的

- **WHEN** 一次搜索同时发给两个后端，其中一个失败
- **THEN** 返回里那个后端 SHALL 带自己的错误说明，另一个后端的结果 SHALL 照常返回
