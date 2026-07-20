## Context

ZhipuAI 提供两种搜索方式：
1. **Chat Completions web_search tool** — 在 `/chat/completions` 请求中注册 `tools: [{type: "web_search", ...}]`，模型自动搜索后生成综合回答。需要模型支持 tool calling。
2. **Web Search API** — 独立的 REST API，`POST /api/paas/v4/web_search`，直接返回结构化搜索结果。不依赖模型。

当前实现用的是方式 1，但 `glm-4.7-flash` 不支持 tool calling，导致搜索不执行。

## Goals / Non-Goals

**Goals:**
- ZhipuAI `search()` 改用 Web Search API，不依赖模型 tool calling
- 返回结构化搜索结果（`title`, `link`, `content`）

**Non-Goals:**
- 不添加搜索意图识别（Web Search API 自动处理）
- 不添加 `search_domain_filter` 或 `search_recency_filter`（后续可加）
- 不修改 Kimi 和 SearXNG provider

## Decisions

### D1: Web Search API 端点

```
POST https://open.bigmodel.cn/api/paas/v4/web_search
Authorization: Bearer <api_key>
Content-Type: application/json

{
  "search_engine": "search-prime",
  "search_query": "<query>",
  "count": <max_results>
}
```

**Rationale**: 参考官方 API 文档 (docs.z.ai/api-reference/tools/web-search)。`search-prime` 是智谱 AI 高级版搜索引擎。`search_engine` 可通过 config 覆盖（默认 `"search-prime"`）。

### D2: 响应格式

成功响应 (HTTP 200):
```json
{
  "id": "<string>",
  "created": 123,
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

错误响应 (HTTP 4xx/5xx) — API 可能返回两种格式:
```json
// 格式1 (open.bigmodel.cn 实际返回): 嵌套 error 对象
{"error":{"code":"1113","message":"余额不足或无可用资源包,请充值。"}}

// 格式2 (docs.z.ai 文档): 平铺格式
{"code":401,"message":"Invalid API key"}
```

实现 SHALL 兼容两种格式：先尝试 `error.message`，回退到顶层 `message`。

映射：`title→SearchResult.title`, `link→SearchResult.url`, `content→SearchResult.content`。`media`/`icon`/`publish_date`/`refer` 暂不映射（`SearchResult` 保持最小化，后续可按需扩展）。`id`/`created` 仅用于日志追踪，不暴露给上层。

### D3: 非流式 HTTP POST

单个 curl POST，写入回调捕获完整 JSON body。5MB 响应上限。30s 超时。不需要 SSE、不需要 agent loop。

### D4: 不使用 Chat Completions

彻底移除 Chat Completions 相关代码：不构建 messages、不注册 tools、不设 `stream: false`（非流式 POST 本身就一次请求）。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Web Search API 可能收费（0.01-0.05 元/次） | `search_engine` 可配置，未来若有更便宜的引擎可切换 |
| 不再返回 AI 综合回答（只有结构化结果） | 结构化结果对下游 AI 模型更有用；综合回答可在 App 层由主模型自行生成 |
| API 可能不可用（超时） | 30s 超时，curl error 返回 transient error |
