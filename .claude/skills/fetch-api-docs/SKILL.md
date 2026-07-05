---
name: fetch-api-docs
description: 并行爬取 Anthropic 和 DeepSeek 官方 API 文档，更新 Docs/ 下的本地参考文件。
---

从官方源重新抓取 API 文档并更新本地 `Docs/` 目录。Anthropic 和 DeepSeek 两个爬取任务并行执行。

**触发词**: "更新API文档"、"爬取API文档"、"fetch api docs"、"/fetch-api-docs"

## 执行方式

必须同时启动两个子 Agent 并行工作，不可串行。

### Agent 1: Anthropic API 文档爬取

```
Agent(
  description: "Fetch Anthropic API docs",
  subagent_type: "general-purpose",
  prompt: """
从 Anthropic 官方文档站点抓取 API 参考文档，然后写入 `Docs/AnthropicAPIDoc.md`。

## URL 列表

依次抓取以下页面（使用 mcp__web-reader__webReader），提取完整内容：

1. https://docs.anthropic.com/en/api/messages — Messages API（请求/响应格式、Stop Reasons）
2. https://docs.anthropic.com/en/api/messages-streaming — SSE Streaming（事件流、delta 类型）
3. https://docs.anthropic.com/en/docs/build-with-claude/tool-use — Tool Use（tool 定义、tool_use/tool_result 格式）

## 输出文件

写入 `Docs/AnthropicAPIDoc.md`，格式要求：
- Markdown 格式，中文优先
- 包含 Messages API 完整参考（endpoint、headers、request body 表格、response JSON、stop reasons）
- 包含 Messages Format（content block 类型、role 规则）
- 包含 Tool Use 完整说明（tool 定义 JSON、tool_use 响应格式、**重点标注 tool_result 必须为数组**）
- 包含 Streaming/SSE 事件流和 Delta 类型表格
- 末尾标注来源 URL 和抓取时间

## 注意事项
- 如果 WebFetch 被限制，改用 mcp__web-reader__webReader
- 如果某个 URL 404，跳过但记录在文档末尾
- 保持代码示例（JSON）的准确性和完整性
"""
)
```

### Agent 2: DeepSeek API 文档爬取

```
Agent(
  description: "Fetch DeepSeek API docs",
  subagent_type: "general-purpose",
  prompt: """
从 DeepSeek 官方 API 文档站点抓取 API 参考文档，然后写入 `Docs/DeepSeekAPIDoc.md`。

## URL 列表

使用 mcp__web-reader__webReader 依次抓取以下页面，提取完整内容：

1. https://api-docs.deepseek.com/zh-cn/ — 首次调用 API（概览、base_url、模型列表）
2. https://api-docs.deepseek.com/zh-cn/guides/anthropic_api — Anthropic API 兼容性（字段支持表格、Message Fields 完整对照）
3. https://api-docs.deepseek.com/zh-cn/api/create-chat-completion — 对话补全 API（完整 request/response schema）
4. https://api-docs.deepseek.com/zh-cn/guides/tool_calls — Tool Calls（function calling 流程、strict 模式）
5. https://api-docs.deepseek.com/zh-cn/quick_start/error_codes — 错误码
6. https://api-docs.deepseek.com/zh-cn/quick_start/token_usage — Token 用量

## 输出文件

写入 `Docs/DeepSeekAPIDoc.md`，格式要求：
- Markdown 格式，中文优先
- 包含概述（base_url 表格、可用模型列表）
- **重点：Anthropic API 兼容性完整字段对照表**（HTTP Header / Simple Fields / Tool Fields / Message Fields）
- 包含对话补全 API 完整 Schema（POST /chat/completions）
- 包含 Tool Calls 流程、Strict 模式及 JSON Schema 约束
- 包含错误码表格
- 包含 Token 用量说明
- 末尾加一节「本项目相关要点」总结 DeepSeek Anthropic 兼容 API 与官方 Anthropic API 的关键差异
- 标注来源 URL 和抓取时间

## 注意事项
- 某些页面可能超时，重试一次后仍失败则跳过并记录
- 英文版 `https://api-docs.deepseek.com/guides/anthropic_api` 可作为中文版的补充
- 保持代码示例（JSON）的准确性和完整性
"""
)
```

## 完成后

等待两个 Agent 都完成，然后确认：
1. `Docs/AnthropicAPIDoc.md` 和 `Docs/DeepSeekAPIDoc.md` 都存在
2. 报告每个文件的行数和最后更新时间
3. 将文件加入 git 暂存区（但不提交，除非用户要求）
