---
name: fetch-api-docs
description: 并行爬取 Anthropic 和 DeepSeek 官方 API 文档，更新 Docs/ 下的本地参考文件。
---

从官方源重新抓取 API 文档并更新本地 `Docs/` 目录。Anthropic 和 DeepSeek 两个爬取任务并行执行。

**触发词**: "更新API文档"、"爬取API文档"、"fetch api docs"、"/fetch-api-docs"

## 执行方式

必须同时启动两个子 Agent 并行工作，**不可串行**（在同一轮里同时发起两个子 Agent 调用）。

---

## Agent 1: Anthropic API 文档爬取

### 源的选择（先读这条，别照着老 URL 硬爬）

`docs.anthropic.com` 与 `platform.claude.com/docs/**` 的**页面路由在本机所在区域被地区封锁**（不是反爬，换代理无效）。实测链路：

```
docs.anthropic.com/en/api/messages
  → 301 → platform.claude.com/docs/en/api/messages
  → 307 → www.anthropic.com/app-unavailable-in-region?utm_source=country
```

**可用的是静态全文文件**（实测 HTTP 200，不受地区封锁）：

| 文件 | 用途 |
| --- | --- |
| `https://platform.claude.com/llms-full.txt` | **主源**。官方全文文档聚合文件（约 42 MB / 1,358,000 行 / 700 个页面区块），每块自带 `url:` 字段可溯源 |
| `https://platform.claude.com/llms.txt` | 页面索引，用于定位 |

**做法**：取 `llms-full.txt`，按页面区块切分，只取下表页面的正文（用区块内自带的 `url:` 字段确认身份）：

| 目标章节 | llms-full.txt 内的 url 路径 |
| --- | --- |
| Messages API | `/docs/en/api/messages/create`、`/docs/en/api/overview`、`/docs/en/api/beta-headers` |
| Streaming / SSE | `/docs/en/build-with-claude/streaming` |
| Tool Use | `/docs/en/agents-and-tools/tool-use/` 下的 `overview`、`define-tools`、`handle-tool-calls`、`how-tool-use-works` |
| 辅助核对 | `/docs/en/build-with-claude/handling-stop-reasons`、`working-with-messages` |

> 若将来地区封锁解除，可回退直接抓页面：`platform.claude.com/docs/en/api/messages/create`、`.../build-with-claude/streaming`、`.../agents-and-tools/tool-use/overview`。**抓之前先用 `curl -sI` 探一下是不是 307。**

### 输出文件

写入 `Docs/AnthropicAPIDoc.md`，格式要求：

- Markdown，中文优先
- 标题结构固定为：`# Anthropic API 参考文档` → `## 一、Messages API 参考` → `## 二、Streaming Messages（SSE 流式）` → `## 三、Tool Use（工具调用 / 函数调用）` → `## 来源 URL`
- Messages API 完整参考（endpoint、headers 表格、request body 字段表、response JSON、stop reasons）
- Messages Format（content block 类型、role 规则）
- **Tool Use 完整说明**（tool 定义 JSON、`tool_use` 响应 block、`tool_result` 格式、`tool_choice` 四选项、多轮循环）
- Streaming/SSE 事件流类型表 + delta 类型表 + 完整 SSE 示例
- 末尾标注来源（含 `llms-full.txt` 及其区块路径）与抓取时间

> ### ⚠️ 关于 `tool_result` 数组要求 —— 不要写错
>
> 历史版本的本 skill 曾要求标注「**tool_result 的 content 必须为数组**」。**这条是错的，已核对官方原文推翻**：
>
> - 官方 `ToolResultBlockParam.content` 是 **optional，且可为 `string` 或 `array`**（元素为 `TextBlockParam` / `ImageBlockParam` / `SearchResultBlockParam` 等）。官方示例中 `"content": "15 degrees"`（字符串）合法，另有完全省略 `content` 的空结果示例。
> - 官方真正强制的是：**外层 user 消息的 `content` 必须是数组**，`tool_result` 必须是该数组的元素，且必须排在 `text` 之前，否则返回 `400`。
> - 若本项目的 DeepSeek 兼容端点另有「必须为数组」的更严约束，那是**实现方自加约束，不得写成 Anthropic 官方要求**。

### 注意事项

- `llms-full.txt` 下载超时可改用分段取，或退到 `llms.txt` 索引定位
- **三个老 URL 抓不到是预期行为**（地区封锁），如实记录即可，**不要用记忆填充**
- 保持 JSON 示例的准确性与完整性

---

## Agent 2: DeepSeek API 文档爬取

### URL 列表

依次抓取以下页面，提取完整内容：

1. `https://api-docs.deepseek.com/zh-cn/` — 首次调用 API（概览、base_url、模型列表）
2. `https://api-docs.deepseek.com/zh-cn/guides/anthropic_api` — Anthropic API 兼容性（字段支持表格、Message Fields 完整对照）
3. `https://api-docs.deepseek.com/zh-cn/api/create-chat-completion` — 对话补全 API（完整 request/response schema）
4. `https://api-docs.deepseek.com/zh-cn/guides/tool_calls` — Tool Calls（function calling 流程、strict 模式）
5. `https://api-docs.deepseek.com/zh-cn/quick_start/error_codes` — 错误码
6. `https://api-docs.deepseek.com/zh-cn/quick_start/token_usage` — Token 用量

补充：英文版 `https://api-docs.deepseek.com/guides/anthropic_api` 可与中文版逐条交叉确证。

### 输出文件

写入 `Docs/DeepSeekAPIDoc.md`，格式要求：

- Markdown，中文优先
- 标题结构固定为：`# DeepSeek API 参考文档` → `## 1. 概述` → `## 2. Anthropic API 兼容性（重点）` → `## 3. 对话补全 API` → `## 4. Tool Calls（函数调用）` → `## 5. 错误码` → `## 6. Token 用量` → `## 7. 本项目相关要点` → `## 8. 来源`
- 概述：base_url 表格、可用模型列表
- **§2 重点**：HTTP Header / Simple Fields / Tool Fields / Message Fields 完整字段对照表，逐字段照录，不合并、不删减
- 对话补全 API 完整 Schema（`POST /chat/completions`）
- Tool Calls 流程、Strict 模式及 JSON Schema 约束
- 错误码表格、Token 用量说明
- §7 总结 DeepSeek Anthropic 兼容 API 与官方 Anthropic API 的关键差异

### 注意事项

- 官方页面对 `web_fetch` 有**硬截断**（`create-chat-completion` 页在 `usage.completion_tokens_details.reasoning_tokens` 处被截断，中英文两版截断点相同）。重试一次仍截断则**如实标注「未能抓取到」**，不得用记忆补写
- 某些页面可能超时，重试一次后仍失败则跳过并记录
- 保持 JSON 示例的准确性与完整性

---

## 工具约定

- 一律使用 `web_fetch`（抓取）与 `web_search`（找替代地址）。
- **不要引用 `mcp__web-reader__webReader`** —— 该工具在 DeepSeek Harness（dsh）中不存在，写了会直接失败。
- 需要看 HTTP 状态/重定向链时用 `pwsh` 跑 `curl.exe -sI`。

---

## ⚠️ 覆盖文件前必读：不得丢失「本地实测」注记

两份文档里除了官方抓取内容，还夹着**项目本地 live 实测结论**（如 `DeepSeekAPIDoc.md` §2.7.5「本地实测记录（非官方抓取）」）。**重写文件时按以下流程操作：**

1. **先 `git show HEAD:<file>` 把旧版读出来**，找出所有标注为「本地实测 / 实测修正 / live 验证 / 非官方」的段落。
2. 这些段落**必须原样保留**在重写后的文件里，并保留其「非官方」标注。
3. **禁止以「不是本次抓取内容」为由删掉它们** —— 它们往往是产品代码注释引用的依据。
4. 保留后，**检查代码注释引用的章节号是否仍然成立**：`sidecar/src/model_gateway.cpp` 等文件里写死了 `§x.y` 锚点；**若本次抓取改变了章节编号，必须同步修正代码注释**。
   - 历史事故：某次刷新把「思考模式」从 `§2.5` 挪到 `§2.7`，`§2.5` 变成「Tool 字段」，导致 `model_gateway.cpp` 里 5 处锚点全部指错。

---

## 完成后

等待两个 Agent 都完成，然后确认：

1. `Docs/AnthropicAPIDoc.md` 和 `Docs/DeepSeekAPIDoc.md` 都存在
2. 报告每个文件的行数和最后更新时间
3. **检查两份文档里的「本地实测」小节是否仍在**（见上节）
4. **检查代码注释引用的章节号是否仍然成立**（见上节）
5. 将文件加入 git 暂存区（但**不提交**，除非用户明确要求）
