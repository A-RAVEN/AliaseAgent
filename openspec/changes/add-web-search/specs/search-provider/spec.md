# Search Provider — Spec

## ADDED Requirements

### Requirement: ISearchProvider interface with error channel
The C++ Sidecar SHALL define an `ISearchProvider` abstract interface. Each implementation SHALL provide `name()`, `description()`, `is_configured()`, and `search(query, depth, max_results)` returning `ProviderResult`. `ProviderResult` SHALL contain `results` (vector of SearchResult) and `error` (SearchError with message and is_transient flag). An empty `results` with empty `error.message` indicates "no matches found". An empty `results` with non-empty `error.message` indicates a failure.

#### Scenario: Provider identity
- **WHEN** `name()` is called on any provider
- **THEN** a unique kebab-case identifier is returned (e.g., `"zhipuai"`, `"searxng"`, `"kimi"`)

#### Scenario: Provider description for AI
- **WHEN** `description()` is called on any provider
- **THEN** a human-readable string describing the provider's capabilities is returned

#### Scenario: Provider configuration check
- **WHEN** `is_configured()` is called on ZhipuAI after Dart has passed search config via `ensure_search_infra` and the provider's cached API key is non-empty
- **THEN** `true` is returned

#### Scenario: SearXNG is_configured returns cached result
- **WHEN** `is_configured()` is called on SearXNG
- **THEN** the provider returns the cached result from `ensure_search_infra`'s one-time TCP liveness check (O(1), no new connection); `true` if SearXNG was reachable at init, `false` otherwise

#### Scenario: SearchResult normalization
- **WHEN** a provider produces results
- **THEN** each SearchResult has `title` (string, may be empty for Kimi), `url` (string, may be empty for Kimi), and `content` (string, shall be non-empty)

#### Scenario: Empty results vs error distinguishable
- **WHEN** a search finds no matches
- **THEN** `ProviderResult{results=[], error={message="", is_transient=false}}` is returned
- **WHEN** a search fails due to network error
- **THEN** `ProviderResult{results=[], error={message="Connection refused", is_transient=true}}` is returned

### Requirement: ZhipuAI search provider (OpenAI transport)
The C++ Sidecar SHALL provide a `ZhipuAISearch` class implementing `ISearchProvider`. It SHALL use its own curl handle with OpenAI-compatible HTTP/SSE transport (NOT ModelGateway). Requests SHALL use `POST /v1/chat/completions` with `Authorization: Bearer` header. The adapter SHALL intercept `choices[0].delta.tool_calls` for `msearch` and `mclick` tool functions.

#### Scenario: ZhipuAI basic search
- **WHEN** `ZhipuAISearch::search(query, "basic", 5)` is called
- **THEN** a mini conversation is sent via OpenAI-format SSE; `msearch` tool call outputs (WebBrowserOutput) are collected and mapped to SearchResult; the conversation is aborted before ZhipuAI generates its final text answer

#### Scenario: ZhipuAI deep search with partial mclick failure
- **WHEN** `ZhipuAISearch::search(query, "deep", 5)` is called and one of three mclick pages fails (e.g., HTTP 503)
- **THEN** results include full-text for the 2 successful mclicks and snippet-only results for the failed one; `ProviderResult.error` describes the partial failure with `is_transient=true`

#### Scenario: ZhipuAI loop-level timeout
- **WHEN** any single SSE round-trip exceeds 30 seconds
- **THEN** the provider returns partial results collected so far with a timeout error

### Requirement: SearXNG self-host provider
The C++ Sidecar SHALL provide a `SearXNGSelfHost` class implementing `ISearchProvider`. It SHALL use HTTP GET to the SearXNG JSON API at a configurable base URL (default `http://localhost:8888`). The query SHALL be URL-encoded before concatenation. The `max_results` parameter SHALL be applied via client-side truncation (SearXNG API has no `limit` parameter). `depth` SHALL be ignored.

#### Scenario: SearXNG search with client-side truncation
- **WHEN** `SearXNGSelfHost::search(query, "basic", 5)` is called
- **THEN** `GET /search?q=<url_encoded_query>&format=json` is sent; parsed `results[]` is truncated to 5 entries; results are mapped to `SearchResult{title, url, content}`

#### Scenario: SearXNG format=json not enabled server-side
- **WHEN** SearXNG returns HTTP 403 (format=json disabled in settings.yml)
- **THEN** `ProviderResult.error` contains "SearXNG returned HTTP 403 — ensure format: json is enabled in settings.yml"

#### Scenario: SearXNG unavailable during search
- **WHEN** `SearXNGSelfHost::search` is called and the instance is unreachable
- **THEN** `ProviderResult{results=[], error={message="SearXNG unavailable", is_transient=true}}` is returned

### Requirement: Kimi search provider (OpenAI transport)
The C++ Sidecar SHALL provide a `KimiSearch` class implementing `ISearchProvider`. It SHALL use its own curl handle with OpenAI-compatible HTTP/SSE transport. The request body SHALL include `"thinking": {"type": "disabled"}` (required by Kimi for `$web_search`). The `$web_search` tool SHALL be registered as `builtin_function`. The adapter SHALL act as a NO-OP relay: return tool_call arguments unchanged as tool_result, then collect the final text answer.

#### Scenario: Kimi search with thinking disabled
- **WHEN** `KimiSearch::search(query, "basic", 1)` is called
- **THEN** the request body includes `"thinking": {"type": "disabled"}`; `$web_search` is registered as `builtin_function`; the adapter relays arguments and collects the text response; returns a single SearchResult with empty title/url

#### Scenario: Kimi HTTP 429 retry (Kimi-only)
- **WHEN** Kimi API returns HTTP 429
- **THEN** the provider retries up to 2 times with exponential backoff (1s, 2s), respecting `Retry-After` header; on third 429, returns `ProviderResult` with transient error
- **NOTE**: HTTP 429 retry is Kimi-specific for v1. SearXNG and ZhipuAI providers SHALL NOT retry on 429 in this change (deferred to future iteration).

### Requirement: Transport layer independence
Each SSE-based provider (ZhipuAI, Kimi) SHALL own its curl handle and SSE parser. Providers SHALL NOT share curl handles or ModelGateway state. SearXNG SHALL use a standalone curl handle for simple HTTP GET (no SSE).

#### Scenario: ZhipuAI and Kimi adapters use independent curl handles
- **WHEN** ZhipuAISearch and KimiSearch are both executing in parallel
- **THEN** each uses its own curl handle with no shared state; no race conditions on HTTP state

#### Scenario: ModelGateway not reused for search
- **WHEN** a search provider executes
- **THEN** `g_gateway` (ModelGateway singleton) is NOT accessed

### Requirement: SSE error accumulation
SSE parsers in search providers SHALL accumulate JSON parse error counts. If parse errors exceed a threshold (10 per request), the provider SHALL emit an error.

#### Scenario: SSE parse errors below threshold
- **WHEN** an SSE stream has 2 malformed lines out of 100
- **THEN** the malformed lines are logged and skipped; valid lines are processed normally

#### Scenario: SSE parse errors exceed threshold
- **WHEN** an SSE stream has 15 malformed lines
- **THEN** the provider returns `ProviderResult` with error "Excessive SSE parse errors" and `is_transient=true`

### Requirement: Provider registry and tool description generation
All registered providers SHALL be discoverable at initialization time. The set of configured providers SHALL be exposed to the Dart layer via `get_search_providers()` for dynamic tool definition generation. `is_configured()` SHALL check per-provider API keys (e.g., `search.zhipuai.api_key`, `search.kimi.api_key`) NOT a flat `search.api_key`.

#### Scenario: Registered providers listed
- **WHEN** the search infrastructure initializes
- **THEN** each configured provider's `name()` and `description()` are available for tool definition generation

#### Scenario: Per-provider API key check
- **WHEN** `is_configured()` is called on ZhipuAI after `ensure_search_infra` has been called
- **THEN** the check reads the provider's cached API key (previously set via FFI from Dart's `search.zhipuai.api_key` in config.json, NOT a flat `search.api_key`)
