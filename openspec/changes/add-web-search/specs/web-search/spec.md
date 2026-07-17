# Web Search — Spec

## ADDED Requirements

### Requirement: Web search tool definition — AI-driven provider selection
The system SHALL expose a `web_search` tool to the main model. The tool description SHALL dynamically list all configured search providers with their capabilities. The tool SHALL accept `query` (required), `providers` (array of provider names, default to all configured), `depth` ("basic" | "deep", default "basic"), and `max_results` (1-10, default 5).

#### Scenario: Main model selects single provider
- **WHEN** the main model calls `web_search` with `{"query":"Flutter FFI","providers":["searxng"],"depth":"basic","max_results":5}`
- **THEN** only the SearXNG provider is executed

#### Scenario: Main model selects multiple providers with deep depth
- **WHEN** the main model calls `web_search` with `{"query":"Flutter FFI","providers":["searxng","zhipuai"],"depth":"deep","max_results":3}`
- **THEN** both providers execute in parallel, zhipuai receives `depth="deep"` (full page extraction), searxng ignores depth but still executes

#### Scenario: Tool description reflects configured providers
- **WHEN** the tool definition is generated for the main model
- **THEN** the description lists each configured provider's name and capabilities; `depth` parameter is present in input_schema

### Requirement: Namespaced search results with error isolation
Search results SHALL use per-namespace result objects rather than parallel content/errors maps. Each namespace SHALL contain `results` (array) and `error` (string or null). `error` being non-null SHALL imply `results` is an empty array.

#### Scenario: All providers succeed
- **WHEN** `web_search` executes with providers `["searxng","zhipuai"]` and both succeed
- **THEN** result format is `{"ok":true,"content":{"searxng":{"results":[...],"error":null},"zhipuai":{"results":[...],"error":null}}}`

#### Scenario: One provider fails, others succeed
- **WHEN** `web_search` executes and zhipuai returns an error but searxng succeeds
- **THEN** `content.zhipuai.results` is empty, `content.zhipuai.error` is non-null; `content.searxng.results` has valid results; overall `ok` is true

#### Scenario: Provider returns empty results (no matches)
- **WHEN** a search provider completes successfully but finds no matching results
- **THEN** `results` is empty array and `error` is null (distinct from a failure where `error` is non-null)

### Requirement: Provider timeout and overall deadline
Each provider SHALL have a configurable timeout. The dispatcher SHALL enforce an overall deadline. Providers exceeding their individual timeout or the overall deadline SHALL return an error for that namespace only.

#### Scenario: Hung provider times out, fast providers complete
- **WHEN** searxng returns in 0.5s but zhipuai hangs
- **AND** the overall deadline (30s) is reached
- **THEN** `content.searxng` has valid results; `content.zhipuai.error` contains timeout error; other providers' results are returned immediately

#### Scenario: Deep search round-trip timeout
- **WHEN** ZhipuAI deep search exceeds 30s per SSE round-trip
- **THEN** the provider returns partial results collected so far with a timeout error

### Requirement: Web search execution on worker isolate
The `web_search` FFI call SHALL execute on a Dart worker isolate, NOT the main UI isolate. The pattern SHALL follow the existing `sendMessage` isolate model (`Isolate.spawn` + `SendPort`/`ReceivePort`).

#### Scenario: Web search does not block UI
- **WHEN** `web_search` is executing for 5+ seconds
- **THEN** the Flutter UI remains responsive (animations continue, user can switch sessions)

### Requirement: Search result normalization
All search results from any provider SHALL be normalized to `{title, url, content}` format. The `content` field SHALL be serialized as a JSON string before embedding in the tool result sent to the main model, consistent with the existing tool result contract (`_executeTool` casting `content` as `String`).

#### Scenario: Normalized results serialized for tool result
- **WHEN** web_search returns namespaced results
- **THEN** the C++ side serializes content as `jsonEncode(namespaced_content)` before returning via FFI; Dart `_executeTool` receives a flat JSON string

### Requirement: Search depth control
The `depth` parameter SHALL be specified by the main model. Providers that support depth differentiation SHALL respect it; providers that don't SHALL ignore it.

#### Scenario: ZhipuAI basic search
- **WHEN** `depth="basic"` on ZhipuAI provider
- **THEN** the provider executes only `msearch` and returns snippet-level results

#### Scenario: ZhipuAI deep search with partial mclick failure
- **WHEN** `depth="deep"` on ZhipuAI and some mclick pages fail to load
- **THEN** results include full text for successful mclicks and snippet-only for failed ones; per-mclick errors are aggregated in the provider error

#### Scenario: SearXNG and Kimi ignore depth
- **WHEN** SearXNG or Kimi receive any `depth` value
- **THEN** the search proceeds normally (depth has no effect)

### Requirement: HTTP 429 rate limit handling
Providers SHALL retry on HTTP 429 responses up to 2 times with exponential backoff (1s, 2s), respecting the `Retry-After` header if present.

#### Scenario: Retry after 429
- **WHEN** a search provider receives HTTP 429 with `Retry-After: 3`
- **THEN** the provider waits 3 seconds and retries; on second 429, waits longer and retries; on third 429, returns an error

#### Scenario: Permanent errors not retried
- **WHEN** a search provider receives HTTP 401 or 403
- **THEN** the provider returns an error immediately without retrying
