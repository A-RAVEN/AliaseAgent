## Context

ZhipuAI 提供两种搜索方式：
1. **Chat Completions web_search tool** — 在 `/chat/completions` 请求中注册 `tools: [{type: "web_search", ...}]`，模型自动搜索后生成综合回答。需要模型支持 tool calling。
2. **Web Search API** — 独立的 REST API，`POST /api/paas/v4/tools/web_search`，直接返回结构化搜索结果。不依赖模型。

当前实现用的是方式 1，但 `glm-4.7-flash` 不支持 tool calling，导致搜索不执行。

## Goals / Non-Goals

**Goals:**
- ZhipuAI `search()` 改用 Web Search API，不依赖模型 tool calling
- 返回结构化搜索结果（`title`, `link`, `content`）
- 保留 `content_size` 可配置以控制摘要长度

**Non-Goals:**
- 不添加搜索意图识别（Web Search API 自动处理）
- 不添加 `search_domain_filter` 或 `search_recency_filter`（后续可加）
- 不修改 Kimi 和 SearXNG provider

## Decisions

### D1: Web Search API 端点

```
POST https://open.bigmodel.cn/api/paas/v4/tools/web_search
Authorization: Bearer <api_key>
Content-Type: application/json

{
  "search_engine": "search_pro",
  "search_query": "<query>",
  "count": <max_results>,
  "content_size": "medium"
}
```

**Rationale**: 官方 Python SDK 使用 `client.web_search.web_search()` 对应此端点。`search_pro` 是多引擎高级版，`search_std` 是基础版。默认用 `search_pro`，可通过 config 覆盖。

### D2: 响应格式

```json
{
  "search_result": [
    {
      "title": "...",
      "link": "https://...",
      "content": "...",
      "icon": "...",
      "media": "...",
      "publish_date": "...",
      "refer": "ref_1"
    }
  ]
}
```

映射：`title→SearchResult.title`, `link→SearchResult.url`, `content→SearchResult.content`

### D3: 非流式 HTTP POST

单个 curl POST，写入回调捕获完整 JSON body。5MB 响应上限。30s 超时。不需要 SSE、不需要 agent loop。

### D4: 不使用 Chat Completions

彻底移除 Chat Completions 相关代码：不构建 messages、不注册 tools、不设 `stream: false`（非流式 POST 本身就一次请求）。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Web Search API 可能收费（0.01-0.05 元/次） | 可配置 `search_engine` 选更便宜的 `search_std` |
| 不再返回 AI 综合回答（只有结构化结果） | 结构化结果对下游 AI 模型更有用；综合回答可在 App 层由主模型自行生成 |
| API 可能不可用（超时） | 30s 超时，curl error 返回 transient error |
