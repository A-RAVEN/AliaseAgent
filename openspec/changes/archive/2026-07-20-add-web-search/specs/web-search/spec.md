# Web Search — Spec

## ADDED Requirements

### Requirement: Web search tool definition — AI-driven provider selection
The system SHALL expose a `web_search` tool to the main model. The tool description SHALL dynamically list all configured search providers with their capabilities. The tool SHALL accept `query` (required), `providers` (array of provider names, default to all configured), `depth` ("basic" | "deep", default "basic"), and `max_results` (1-10, default 5).

#### Scenario: Main model selects single provider
- **WHEN** the main model calls `web_search` with `{"query":"Flutter FFI","providers":["searxng"],"depth":"basic","max_results":5}`
- **THEN** only the SearXNG provider is executed

#### Scenario: Main model selects multiple providers
- **WHEN** the main model calls `web_search` with `{"query":"Flutter FFI","providers":["searxng","zhipuai"],"depth":"basic","max_results":3}`
- **THEN** both providers execute in parallel; zhipuai handles search+reading+synthesis via platform web_search tool; searxng returns snippet results via REST API

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

#### Scenario: All providers fail
- **WHEN** `web_search` executes and ALL providers fail (e.g., SearXNG unreachable, ZhipuAI 401, Kimi timeout)
- **THEN** `ok` SHALL be `false`; `error` SHALL contain a summary like "All search providers failed"; per-namespace errors are preserved in `content`

### Requirement: Provider timeout and overall deadline
Each provider SHALL have a configurable timeout. The dispatcher SHALL enforce an overall deadline. Providers exceeding their individual timeout or the overall deadline SHALL return an error for that namespace only.

#### Scenario: Hung provider times out, fast providers complete
- **WHEN** searxng returns in 0.5s but zhipuai hangs
- **AND** the overall deadline (30s) is reached
- **THEN** `content.searxng` has valid results; `content.zhipuai.error` contains timeout error; other providers' results are returned immediately

#### Scenario: ZhipuAI single-request timeout
- **WHEN** ZhipuAI non-streaming POST exceeds 30s
- **THEN** the provider returns a timeout error

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
The `depth` parameter SHALL be specified by the main model. All providers SHALL ignore `depth` in this change — ZhipuAI's web_search tool auto-determines depth, SearXNG and Kimi have no depth concept. The parameter is reserved for future differentiation.

#### Scenario: ZhipuAI ignores depth
- **WHEN** any `depth` value is passed to ZhipuAI provider
- **THEN** the search proceeds normally — platform auto-determines search depth via `web_search` tool

#### Scenario: ZhipuAI returns structured results and synthesized answer
- **WHEN** ZhipuAI search completes successfully
- **THEN** `web_search[]` structured data is mapped to `SearchResult[]`; `message.content` synthesized answer is optionally captured

#### Scenario: SearXNG and Kimi ignore depth
- **WHEN** SearXNG or Kimi receive any `depth` value
- **THEN** the search proceeds normally (depth has no effect)

### Requirement: HTTP 429 rate limit handling (Kimi-only for v1)
The Kimi provider SHALL retry on HTTP 429 responses up to 2 times with exponential backoff (1s, 2s), respecting the `Retry-After` header if present. SearXNG and ZhipuAI providers SHALL NOT retry on HTTP 429 in this change (deferred to future iteration).

#### Scenario: Kimi retry after 429
- **WHEN** the Kimi provider receives HTTP 429 with `Retry-After: 3`
- **THEN** the provider waits 3 seconds and retries; on second 429, waits longer and retries; on third 429, returns an error

#### Scenario: Permanent errors not retried
- **WHEN** any search provider receives HTTP 401 or 403
- **THEN** the provider returns an error immediately without retrying
