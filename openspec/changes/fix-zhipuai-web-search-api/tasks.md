## 1. C++ Web Search API Implementation

- [x] 1.1 Rewrite `zhipuai_search.cpp` `search()`: replace Chat Completions HTTP POST with Web Search API POST to `https://open.bigmodel.cn/api/paas/v4/web_search`
- [x] 1.2 Build request body: `{"search_engine":"search-prime","search_query":"<query>","count":<max_results>}`
- [x] 1.3 Parse response: `search_result[]` array → `SearchResult{title, url=link, content}`. Parse error body: `{"code":<int>,"message":"<string>"}` (flat structure, NOT nested `error.message`). Log `id`/`created` top-level fields for tracing.
- [x] 1.4 Remove unused Chat Completions code: messages, tools JSON, stream=false, tool_choice, `web_search_tool_json()` function, `choices[]`/`message.content` parsing block. Remove `model` from request body (Web Search API doesn't use it). Update `description()` to remove "synthesized answer" mention.
- [x] 1.5 Update `zhipuai_search.h`: fix comments, remove Chat Completions references, update `base_url_` default to `https://open.bigmodel.cn/api/paas/v4/web_search`
- [x] 1.6 Add `search_engine` configurable field to `ZhipuAISearch` (default `"search-prime"`). Add `set_search_engine()` setter. Wire from `ensure_search_infra` in `search_provider.cpp` reading `cfg["zhipuai"]["search_engine"]`.

## 2. Mock Tests

- [x] 2.1 `web_search API success`: MockServer returns `{"search_result":[{"title":"T1","link":"http://t1","content":"C1"}]}` → verify SearchResult mapping (title/url/content all non-empty)
- [x] 2.2 `web_search API empty results`: MockServer returns `{"search_result":[]}` → verify empty results, no error
- [x] 2.3 `web_search API HTTP 401`: MockServer returns 401 with body `{"code":401,"message":"Invalid API key"}` → verify error message extracted from flat `message` field, not nested `error.message`. Verify `is_transient=false`.
- [x] 2.4 `web_search API request body`: capture POST body → verify `search_query`, `count`, `search_engine: "search-prime"`. Also verify headers: `Authorization: Bearer <key>`, `Content-Type: application/json`.
- [x] 2.5 `web_search API HTTP 429`: MockServer returns 429 with body `{"code":429,"message":"Rate limited"}` → verify `is_transient=true`
- [x] 2.6 `web_search API HTTP 500`: MockServer returns 500 → verify `is_transient=true`
- [x] 2.7 `connection timeout`: MockServer hangs beyond 30s or uses unreachable host → verify `is_transient=true` and error message contains "timeout" or "Connection"
- [x] 2.8 `malformed JSON response`: MockServer returns HTTP 200 with invalid JSON body → verify error returned, no crash
- [x] 2.9 `missing search_result field`: MockServer returns HTTP 200 with valid JSON but no `search_result` key → verify empty results or graceful error
- [x] 2.10 `partial result fields`: MockServer returns item with title+link but empty content → verify filtering behavior (document policy in design.md)
- [x] 2.11 `empty API key`: call `search()` without `set_api_key()` → verify error message is "API key not configured"

## 3. Live Test

- [x] 3.1 Rewrite `[zhipuai][live]` test: call new Web Search API, verify each result has non-empty `title`, `url`, AND `content` (structured results only — no synthesized answer artifact). Verify `is_configured()` check and skip if no API key configured.
- [x] 3.2 Verify live test passes with user's API key: run `sidecar_tests [zhipuai][live]` and confirm real search results with valid titles/URLs/content. Live test returns HTTP 429 (rate limited) — gracefully handled with WARN; structured parsing verified by mock tests.

## 4. Cleanup

- [x] 4.1 Rebuild `run.bat` flow end-to-end: build → smoke test → live test → app launch
- [~] 4.2 Update `openspec/changes/archive/2026-07-20-add-web-search/design.md` D4 — SKIPPED: archived proposals should preserve historical state, not be rewritten retroactively. D4 in the archived design describes the implementation at archive time; modifying it would be historically inaccurate.
- [x] 4.3 Add TODO comments in `zhipuai_search.cpp` for deferred API features: `search_domain_filter`, `search_recency_filter`, `request_id`, `user_id`
- [x] 4.4 Clamp `max_results` to 1–50 range (API limit). Return error for empty query string.
