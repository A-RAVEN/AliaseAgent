## Why

ZhipuAI provider 当前使用 Chat Completions 的 `web_search` tool（对话中的网络搜索），但这要求模型支持 tool calling——用户使用的 `glm-4.7-flash` 不支持，导致模型忽略搜索工具直接凭训练记忆回答。ZhipuAI 有一个独立的 **Web Search API**（`POST /api/paas/v4/web_search`），不依赖模型 tool calling，直接返回结构化搜索结果。本次将 ZhipuAI provider 切换到该独立 API。

## What Changes

- **BREAKING**: ZhipuAI provider 从 Chat Completions + web_search tool 改为 Web Search API HTTP POST
- 移除对模型 tool calling 的依赖，任意 ZhipuAI API key 可用
- 保留 `glm-4.7-flash` 作为默认模型（仅用于可配置项，Web Search API 不需要模型参数）
- 新增真实 API 调用测试（C++ Catch2 `[live]` 测试）
- 新增 mock 测试（JSON 响应解析 + HTTP 错误处理）

## Capabilities

### New Capabilities
- `zhipuai-web-search-api`: ZhipuAI Web Search API 独立调用，返回结构化搜索结果 `{title, link, content}`

### Modified Capabilities
- `search-provider`: ZhipuAI provider 的 `search()` 实现从 Chat Completions 改为 Web Search API；旧 `web_search[]` 响应解析逻辑移除

## Impact

- `sidecar/src/zhipuai_search.cpp` — 完全重写 `search()` 方法（HTTP POST 到 Web Search API，非流式 JSON 解析）
- `sidecar/src/zhipuai_search.h` — 更新默认模型说明，base_url 改为 Web Search API 端点
- `sidecar/test/search_provider_test.cpp` — 新增 ZhipuAI Web Search API mock 测试 + 更新 live 测试
- `openspec/changes/archive/2026-07-20-add-web-search/design.md` — 更新 D4 描述（archived change）
