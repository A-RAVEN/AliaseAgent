## 1. C++ Web Search API Implementation

- [ ] 1.1 Rewrite `zhipuai_search.cpp` `search()`: replace Chat Completions HTTP POST with Web Search API POST to `https://open.bigmodel.cn/api/paas/v4/tools/web_search`
- [ ] 1.2 Build request body: `{"search_engine":"search_pro","search_query":"<query>","count":<max_results>,"content_size":"medium"}`
- [ ] 1.3 Parse response: `search_result[]` array → `SearchResult{title, url=link, content}`
- [ ] 1.4 Remove unused Chat Completions code: messages, tools JSON, stream=false, tool_choice
- [ ] 1.5 Update `zhipuai_search.h`: fix comments, remove Chat Completions references
- [ ] 1.6 Add `search_engine` configurable field to `ZhipuAISearch` (default `"search_pro"`)

## 2. Mock Tests

- [ ] 2.1 `web_search API success`: MockServer returns `{"search_result":[{"title":"T1","link":"http://t1","content":"C1"}]}` → verify SearchResult mapping
- [ ] 2.2 `web_search API empty results`: MockServer returns `{"search_result":[]}` → verify empty results, no error
- [ ] 2.3 `web_search API HTTP 401`: MockServer returns 401 → verify error contains status code
- [ ] 2.4 `web_search API request body`: capture POST body → verify `search_query`, `count`, `search_engine` fields

## 3. Live Test

- [ ] 3.1 Update `[zhipuai][live]` test to call new Web Search API and verify real search results with non-empty title/url/content
- [ ] 3.2 Verify live test passes with user's API key

## 4. Cleanup

- [ ] 4.1 Rebuild `run.bat` flow end-to-end: build → smoke test → live test → app launch
- [ ] 4.2 Update `openspec/changes/add-web-search/design.md` D4 to reflect Web Search API change
