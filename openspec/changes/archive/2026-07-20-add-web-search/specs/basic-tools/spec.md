# Basic Tools — Delta Spec

## ADDED Requirements

### Requirement: Web search tool dispatch
The Dart-side `_executeTool` function SHALL dispatch `web_search` tool calls to the C++ Sidecar's web search function. The tool call input (query, providers, depth, max_results) SHALL be serialized as JSON and passed via FFI. Results SHALL be deserialized and returned to the main model as a tool result with `content` as a JSON string.

#### Scenario: web_search dispatched
- **WHEN** the main model calls `web_search` with `{"query":"...","providers":["searxng"],"depth":"basic","max_results":5}`
- **THEN** the Dart `_executeTool` dispatches to Sidecar's webSearch; the namespaced result content is JSON-encoded as a string and returned via the standard tool result contract

#### Scenario: web_search error handling
- **WHEN** the Sidecar search function returns an error
- **THEN** `_executeTool` propagates the error to the model as `{"ok":false,"error":"..."}`

### Requirement: Web fetch tool dispatch
The Dart-side `_executeTool` function SHALL dispatch `web_fetch` tool calls to the C++ Sidecar's web fetch function via a worker isolate.

#### Scenario: web_fetch dispatched
- **WHEN** the main model calls `web_fetch` with `{"url":"https://example.com","extract_mode":"text"}`
- **THEN** the Dart `_executeTool` dispatches to Sidecar via worker isolate and returns `{"ok":true,"content":"<extracted text>"}`

#### Scenario: web_fetch error handling
- **WHEN** the Sidecar fetch function returns an error
- **THEN** `_executeTool` propagates the error to the model as `{"ok":false,"error":"Fetch failed: <reason>"}`

### Requirement: Tool definitions include web_search and web_fetch
The Dart-side tool definitions SHALL include `web_search` and `web_fetch` only when at least one search provider is configured. Dart `ConfigService` SHALL read the `search` block from `config.json` and pass it to C++ via `ensure_search_infra` before querying `get_search_providers()`. Configuration check SHALL verify per-provider keys (`search.zhipuai.api_key`, `search.kimi.api_key`) or SearXNG localhost reachability.

#### Scenario: Tools present with provider configured
- **WHEN** Dart reads `config.json` containing `search.zhipuai.api_key`, passes it to C++ via `ensure_search_infra`, and C++ confirms at least one provider is configured
- **THEN** the tools list sent to the main model includes `web_search` and `web_fetch`

#### Scenario: Tools absent with no provider
- **WHEN** no per-provider API keys are configured AND SearXNG is unreachable
- **THEN** the tools list does NOT include `web_search` or `web_fetch`
