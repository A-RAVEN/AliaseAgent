# FFI Bridge — Delta Spec

## ADDED Requirements

### Requirement: Web search via FFI (async on worker isolate)
The system SHALL provide a C function `web_search` callable from Dart via FFI. The Dart-side wrapper SHALL execute the call on a worker isolate using `Isolate.spawn` + `SendPort`/`ReceivePort`, following the existing `sendMessage` pattern. The function SHALL NOT block the main UI isolate.

#### Scenario: Successful web search
- **WHEN** Dart calls `webSearch` with `{"query":"Flutter","providers":["searxng"],"depth":"basic","max_results":3}`
- **THEN** the call is dispatched to a worker isolate; C++ executes the search via the configured providers; results are returned as a JSON string

#### Scenario: Web search does not block UI thread
- **WHEN** `webSearch` is executing a search that takes 10+ seconds
- **THEN** the Flutter UI remains responsive (animations, scrolling, session switching)

#### Scenario: Search with no providers configured
- **WHEN** Dart calls `webSearch` but no search provider is configured
- **THEN** C++ returns `{"ok":false,"error":"Search not configured — no providers available"}`

### Requirement: Web fetch via FFI (async on worker isolate)
The system SHALL provide a C function `web_fetch` callable from Dart via FFI. The Dart-side wrapper SHALL execute the call on a worker isolate using `Isolate.spawn` + `SendPort`/`ReceivePort`. The function SHALL NOT block the main UI isolate.

#### Scenario: Successful web fetch
- **WHEN** Dart calls `webFetch` with `{"url":"https://example.com","extract_mode":"text"}`
- **THEN** the call is dispatched to a worker isolate; C++ fetches the URL, extracts text, and returns `{"ok":true,"content":"<text>"}`

#### Scenario: Web fetch does not block UI thread
- **WHEN** `webFetch` is executing a fetch that takes 10+ seconds
- **THEN** the Flutter UI remains responsive

### Requirement: Search infrastructure initialization via FFI
The system SHALL provide a C function `ensure_search_infra` callable from Dart via FFI. Dart SHALL pass the `search` config block from `config.json` as a JSON string. C++ SHALL parse the configuration and cache per-provider credentials in memory, eliminating the need for C++ to read the filesystem directly. This SHALL be called once at startup before tool definitions are built. C++ FFI function names SHALL use snake_case (consistent with existing `send_message`/`read_file`/`list_dir`).

#### Scenario: Search infra initialized with provider keys
- **WHEN** Dart calls `ensure_search_infra` with `{"zhipuai":{"api_key":"xxx"},"kimi":{"api_key":"sk-yyy"}}`
- **THEN** C++ caches the API keys; subsequent `is_configured()` on ZhipuAI and Kimi return `true`; SearXNG `is_configured()` returns the cached TCP liveness check result

#### Scenario: Search infra initialized with empty config
- **WHEN** Dart calls `ensure_search_infra` with `{}`
- **THEN** only SearXNG is potentially available (if reachable); ZhipuAI and Kimi `is_configured()` return `false`

#### Scenario: Config not passed before provider query
- **WHEN** `get_search_providers()` or `is_configured()` is called before `ensure_search_infra`
- **THEN** all providers return not configured (empty list / `false`); SearXNG defaults to unavailable because no cached TCP check result exists; no crash or undefined behavior

#### Scenario: AppConfig.search is null (config.json has no search key)
- **WHEN** `AppConfig.search` is null (config.json has no `search` top-level key)
- **THEN** Dart SHALL pass `"{}"` to `ensure_search_infra` (not skip the call entirely); only SearXNG reachability determines tool availability

### Requirement: Search provider listing via FFI
The system SHALL provide a C function `get_search_providers` callable from Dart via FFI. It SHALL return a JSON array of configured provider objects `[{"name":"searxng","description":"..."},...]`. Dart SHALL use this to dynamically build the `web_search` tool definition's provider enum.

#### Scenario: Multiple providers configured
- **WHEN** `ensure_search_infra` has cached ZhipuAI and Kimi keys, and SearXNG is reachable
- **THEN** `get_search_providers()` returns `[{"name":"searxng","description":"..."},{"name":"zhipuai","description":"..."},{"name":"kimi","description":"..."}]`

#### Scenario: Only SearXNG available
- **WHEN** no API keys are configured but SearXNG is reachable
- **THEN** `get_search_providers()` returns `[{"name":"searxng","description":"..."}]`

#### Scenario: No providers available
- **WHEN** no API keys are configured and SearXNG is unreachable
- **THEN** `get_search_providers()` returns `[]`; Dart SHALL NOT register `web_search` or `web_fetch` tools
