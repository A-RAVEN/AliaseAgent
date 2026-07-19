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

### Requirement: ZhipuAI search provider (non-streaming HTTP POST)
The C++ Sidecar SHALL provide a `ZhipuAISearch` class implementing `ISearchProvider`. It SHALL use its own curl handle for non-streaming HTTP POST (NOT SSE, NOT ModelGateway). Requests SHALL use `POST /chat/completions` with `Authorization: Bearer` header and `stream: false`. The request body SHALL include `tools: [{"type": "web_search"}]` — the platform executes search internally. The response JSON SHALL be parsed for top-level `web_search[]` array and `choices[0].message.content` synthesized answer. `depth` parameter SHALL be ignored (platform auto-determines search depth). Default model SHALL be `glm-4.7-flash` (configurable via `search.zhipuai.model`).

#### Scenario: ZhipuAI web_search success
- **WHEN** `ZhipuAISearch::search(query, "basic", 5)` is called
- **THEN** a non-streaming POST is sent with `stream: false` and `tools: [{"type":"web_search"}]`; the top-level `web_search[]` array in the JSON response is parsed; each item `{title, link, content}` is mapped to `SearchResult{title, url=link, content}`; optionally `message.content` is captured as a synthesized answer result

#### Scenario: ZhipuAI empty web_search results
- **WHEN** the response contains `"web_search": []`
- **THEN** `ProviderResult.results` is empty with no error (success state — no matches)

#### Scenario: ZhipuAI HTTP error
- **WHEN** the API returns HTTP 4xx or 5xx
- **THEN** `ProviderResult` is returned with error containing the HTTP status code

#### Scenario: ZhipuAI single-request timeout
- **WHEN** the non-streaming POST exceeds 30 seconds
- **THEN** the provider returns `ProviderResult` with timeout error and `is_transient=true`

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
The C++ Sidecar SHALL provide a `KimiSearch` class implementing `ISearchProvider`. It SHALL use its own curl handle with OpenAI-compatible HTTP/SSE transport. The request body SHALL include `"thinking": {"type": "disabled"}` (required by Kimi for `$web_search`). The `$web_search` tool SHALL be registered as `builtin_function`. The request body SHALL include `tool_choice: {"type": "builtin_function", "builtin_function": {"name": "$web_search"}}` to force search invocation. The adapter SHALL act as a NO-OP relay: accumulate `function.arguments` by `tool_calls[].index` across SSE deltas, return complete tool_call arguments unchanged as tool_result, then collect the final text answer. If tool_call arguments are missing or null, the adapter SHALL return a ProviderResult error. Default model SHALL be `moonshot-v1-auto` (configurable via `search.kimi.model`).

#### Scenario: Kimi search with thinking disabled
- **WHEN** `KimiSearch::search(query, "basic", 1)` is called
- **THEN** the request body includes `"thinking": {"type": "disabled"}`; `$web_search` is registered as `builtin_function`; the adapter relays arguments and collects the text response; returns a single SearchResult with empty title/url

#### Scenario: Kimi HTTP 429 retry (Kimi-only)
- **WHEN** Kimi API returns HTTP 429
- **THEN** the provider retries up to 2 times with exponential backoff (1s, 2s), respecting `Retry-After` header; on third 429, returns `ProviderResult` with transient error
- **NOTE**: HTTP 429 retry is Kimi-specific for v1. SearXNG and ZhipuAI providers SHALL NOT retry on 429 in this change (deferred to future iteration).

### Requirement: Transport layer independence
Each provider SHALL own its curl handle. Providers SHALL NOT share curl handles or ModelGateway state. All HTTPS curl handles SHALL set `CURLOPT_SSL_VERIFYPEER=1L`. SearXNG and ZhipuAI SHALL use non-streaming HTTP (GET and POST respectively). Kimi SHALL use SSE streaming.

### Requirement: SSE tool_call delta handling (Kimi only)
Kimi's SSE parser SHALL capture `tool_calls[].id` alongside `function.name` and `function.arguments` in each delta. The `tool_call_id` SHALL be preserved for constructing follow-up `{"role": "tool", "tool_call_id": "...", "content": "..."}` messages. `function.arguments` delta fragments SHALL be accumulated by `tool_calls[].index` with a 1MB aggregate per-event cap.

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

### Requirement: Input validation at provider interface
The C++ dispatcher SHALL validate `query` is non-empty before dispatching to providers. If `max_results` is outside the range [1, 10], the dispatcher SHALL clamp it to the nearest valid bound. Invalid provider names in the `providers` array SHALL be silently ignored (only configured providers execute).

#### Scenario: Empty query rejected
- **WHEN** the model calls `web_search` with `query=""` (empty string)
- **THEN** the dispatcher returns `{"ok":false,"error":"Search query is empty"}` without calling any provider

#### Scenario: max_results out of range clamped
- **WHEN** the model calls `web_search` with `max_results=0` or `max_results=100`
- **THEN** the dispatcher clamps to 1 or 10 respectively before passing to providers

### Requirement: Provider registry and tool description generation
All registered providers SHALL be discoverable at initialization time. The set of configured providers SHALL be exposed to the Dart layer via `get_search_providers()` for dynamic tool definition generation. `is_configured()` SHALL check per-provider API keys (e.g., `search.zhipuai.api_key`, `search.kimi.api_key`) NOT a flat `search.api_key`.

#### Scenario: Registered providers listed
- **WHEN** the search infrastructure initializes
- **THEN** each configured provider's `name()` and `description()` are available for tool definition generation

#### Scenario: Per-provider API key check
- **WHEN** `is_configured()` is called on ZhipuAI after `ensure_search_infra` has been called
- **THEN** the check reads the provider's cached API key (previously set via FFI from Dart's `search.zhipuai.api_key` in config.json, NOT a flat `search.api_key`)
