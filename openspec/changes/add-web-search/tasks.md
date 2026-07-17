# Tasks: Add Web Search Tool

## 1. C++ Search Provider Interface

- [ ] 1.1 Define `SearchResult` struct (`title`, `url`, `content`) and `SearchError` struct (`message`, `is_transient`) in `sidecar/src/search_provider.h`
- [ ] 1.2 Define `ProviderResult` struct (`results`, `error`) — empty results + empty error = "no matches"; empty results + non-empty error = failure
- [ ] 1.3 Define `ISearchProvider` abstract interface with `name()`, `description()`, `is_configured()`, `search(query, depth, max_results)` returning `ProviderResult`
- [ ] 1.4 Implement provider registry: on `ensure_search_infra` call, parse JSON and cache per-provider credentials into provider instances; expose `get_search_providers()` returning configured provider list (checking cached keys, NOT reading filesystem); per-provider key check (`search.zhipuai.api_key`, NOT flat `search.api_key`)
- [ ] 1.5 Implement parallel dispatch using `std::future` + `wait_for` (NOT `std::thread::join`): spawn each provider via `std::async`, await with 30s deadline via `wait_until`, aggregate completed results + timeout errors for incomplete; each provider uses own curl handle + buffer
- [ ] 1.6 Implement deadline enforcement: `std::future::wait_for` with 30s total deadline; after deadline, completed provider results returned + incomplete providers get timeout error; timed-out futures continue in background (no detach/leak — their destructors clean up naturally)
- [ ] 1.7 Implement per-provider timeouts (SearXNG: 5s via `CURLOPT_TIMEOUT`, ZhipuAI: 30s/round via SSE timeout, Kimi: 30s via `CURLOPT_TIMEOUT`)
- [ ] 1.8 Add `search_provider.cpp` / `search_provider.h` to `CMakeLists.txt` (both `sidecar` DLL and `sidecar_tests` targets)

## 2. C++ OpenAI Transport Layer

- [ ] 2.1 Implement OpenAI SSE parser utility: line-buffered → parse `data:` lines → dispatch on `choices[0].delta.content` (text), `choices[0].delta.tool_calls[].function` (tool call), `choices[0].finish_reason` (done)
- [ ] 2.2 Implement OpenAI HTTP request builder: `POST /v1/chat/completions`, `Authorization: Bearer`, OpenAI-format body (messages array, tools array, model)
- [ ] 2.3 Implement SSE parse error accumulation: count malformed lines per request, return error if count exceeds 10
- [ ] 2.4 Each adapter creates its own curl handle — no sharing with ModelGateway or other adapters

⛔ **STOP HERE** — Phase 1-2 完成后停止，等用户确认 "execute phase 3"

## 3. C++ Web Fetch Implementation

- [ ] 3.1 Implement SSRF socket-level protection via `CURLOPT_OPENSOCKETFUNCTION`: callback fires after DNS resolve before connect; validate `struct sockaddr` against blocklist (IPv4: 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 0.0.0.0/8, 100.64.0.0/10; IPv6: ::1/128, fe80::/10, fc00::/7); block returns CURL_SOCKOPT_ALREADY_CONNECTED
- [ ] 3.2 Implement URL pre-flight checks: case-insensitive scheme validation (lowercase before compare); reject localhost hostname (case-insensitive); set `CURLOPT_PROTOCOLS = CURLPROTO_HTTP | CURLPROTO_HTTPS`
- [ ] 3.3 Implement web_fetch write callback with incremental size cap: on each chunk, accumulate size; if >100KB return 0 to abort transfer; prevents zip bomb / infinite chunked response
- [ ] 3.4 Implement `web_fetch`: libcurl HTTP GET → Content-Type check → HTML: tag stripping + whitespace compression; non-HTML: return raw text (capped at 100KB by write callback)
- [ ] 3.5 Configure curl options: timeout (15s), `CURLOPT_FOLLOWLOCATION=1`, `CURLOPT_MAXREDIRS=5`, `CURLOPT_REDIR_PROTOCOLS_STR="http,https"`, User-Agent header
- [ ] 3.6 Handle errors: unreachable host, TLS failure, HTTP 4xx/5xx, timeout, blocked URL (SSRF), redirect to internal address

## 4. C++ ZhipuAI Search Provider

- [ ] 4.1 Implement `ZhipuAISearch` class inheriting `ISearchProvider` in `zhipuai_search.h/cpp`
- [ ] 4.2 Implement mini agent loop with OpenAI transport: construct prompt → POST to ZhipuAI Chat API → intercept `tool_calls` for `msearch`/`mclick` → collect `WebBrowserOutput`
- [ ] 4.3 Support `depth="basic"`: collect `msearch` outputs only, abort before `mclick`
- [ ] 4.4 Support `depth="deep"`: respond to `mclick` tool calls; on partial mclick failure, return full text for successful + snippet for failed
- [ ] 4.5 Normalize `WebBrowserOutput{title, link, content}` → `SearchResult{title, url, content}`
- [ ] 4.6 Stop agent loop before ZhipuAI generates final text answer (abort on `finish_reason="stop"`)
- [ ] 4.7 Implement loop-level timeout: 30s per SSE round-trip, 90s total max for multi-round deep search
- [ ] 4.8 Add `zhipuai_search.cpp` to `CMakeLists.txt` (both targets)

⛔ **STOP HERE** — Phase 3-4 完成后停止，等用户确认 "execute phase 5"

## 5. C++ SearXNG Self-Host Provider

- [ ] 5.1 Implement `SearXNGSelfHost` class inheriting `ISearchProvider` in `searxng_search.h/cpp`
- [ ] 5.2 Implement search: URL-encode query → GET `/search?q=<encoded>&format=json` (no `limit` param — SearXNG doesn't support it) → parse JSON → client-side truncate to `max_results` → map to `SearchResult[]`
- [ ] 5.3 Handle HTTP 403 with clear error: "ensure format: json is enabled in settings.yml"
- [ ] 5.4 Handle SearXNG unavailable: connection refused / timeout (5s) → return `ProviderResult` with transient error
- [ ] 5.5 Add `searxng_search.cpp` to `CMakeLists.txt` (both targets)
- [ ] 5.6 Create `scripts/setup_searxng.bat` (Windows) and `scripts/setup_searxng.sh` (Linux/macOS): clone SearXNG to `tools/searxng/` with `--depth 1` → check prerequisites (Python 3.7+, git) with clear error messages → create venv → install pre-reqs (`pyyaml msgspec typing-extensions pybind11 tomli tzdata`) → pip install -e . (with proxy guidance on failure) → generate `settings.yml` with `use_default_settings: true`, `format: [html, json]`, Bing engines with `base_url: https://cn.bing.com`, `port: 8888`, `bind_address: "127.0.0.1"`, random `secret_key`, `valkey.url: false` → launch `python -m searx.webapp`; include stop/update commands; `tools/searxng/` is in `.gitignore`

## 6. C++ Kimi Search Provider

- [ ] 6.1 Implement `KimiSearch` class inheriting `ISearchProvider` in `kimi_search.h/cpp`
- [ ] 6.2 Set `"thinking": {"type": "disabled"}` in request body (required by Kimi for `$web_search`)
- [ ] 6.3 Implement NO-OP relay with OpenAI transport: register `$web_search` as `builtin_function` → intercept `tool_calls` → return arguments unchanged as `tool_result` → collect final text answer
- [ ] 6.4 Normalize: single `SearchResult` with synthesized answer in `content`, empty `title`/`url`
- [ ] 6.5 Handle errors: API error, timeout, empty response
- [ ] 6.6 Implement Kimi-specific HTTP 429 retry: up to 2 retries with exponential backoff (1s, 2s), respecting `Retry-After` header; on third 429 return transient error. SearXNG and ZhipuAI do NOT retry in v1
- [ ] 6.7 Add `kimi_search.cpp` to `CMakeLists.txt` (both targets)

⛔ **STOP HERE** — Phase 5-6 完成后停止，等用户确认 "execute phase 7"

## 7. C++ Sidecar API

- [ ] 7.1 Add `web_search(const char* request_json)` function → catch all exceptions (D9), parses providers[], dispatches in parallel via future+wait_for, serializes namespaced content as JSON string before returning
- [ ] 7.2 Add `web_fetch(const char* request_json)` function → catch all exceptions (D9), validates URL, fetches, returns JSON result
- [ ] 7.3 Declare `web_search` / `web_fetch` / `ensure_search_infra` / `get_search_providers` with `SIDECAR_API` in `sidecar_api.h` (all snake_case, matching existing `send_message`/`read_file`/`list_dir` convention)
- [ ] 7.4 Add `get_search_providers()` function with `SIDECAR_API` → returns JSON array of configured provider `{name, description}`
- [ ] 7.5 Implement `ensure_search_infra(const char* search_config_json)`: catch all exceptions (D9), parse JSON → cache per-provider API keys + SearXNG base URL into provider instances; perform SearXNG liveness check once (TCP connect to localhost:8888, 2s timeout), cache result; called once at startup before tool definition construction
- [ ] 7.6 Implement D9 exception safety: every `extern "C"` function wraps body in try/catch(std::exception&) + catch(...), returning `{"ok":false,"error":"..."}`; each provider thread wraps search() in try/catch → ProviderResult with is_transient=false for unexpected errors

## 8. Dart Tool Integration

- [ ] 8.1 Extend `AppConfig` model: add `search` field (`Map<String, dynamic>?`) to carry `search.zhipuai.api_key`, `search.kimi.api_key`, `search.searxng.baseUrl` from `config.json`; `fromJson()` reads `json['search']` as nullable map; `toJson()` conditionally includes `search` when non-null and non-empty (prevents ConfigService.save() from silently dropping the search block on unrelated config changes)
- [ ] 8.2 At startup, read search config from `ConfigService` → serialize to JSON → call C++ `ensure_search_infra` via FFI (following same path as `sendMessage`'s `api_key` parameter); only then build tool definitions
- [ ] 8.3 Build `web_search` tool definition dynamically: fetch provider list from Sidecar via `get_search_providers()` → generate description with per-provider capabilities → set `providers` enum (default empty array = use all configured) and `depth` parameter
- [ ] 8.4 Add `web_fetch` tool definition to `_toolDefs` in `lib/main.dart` (v1: extract_mode only "text")
- [ ] 8.5 Add `web_search` and `web_fetch` dispatch branches to `_executeTool`; serialize content as JSON string for tool result contract compatibility
- [ ] 8.6 Conditionally include tools only when at least one search provider is configured (check per-provider keys via `get_search_providers()` result, NOT by re-reading config.json)
- [ ] 8.7 Add `web_search` / `web_fetch` / `get_search_providers` / `ensure_search_infra` FFI bindings in `lib/services/sidecar_bridge.dart` (Dart typedefs use camelCase pointing to snake_case C symbols)
- [ ] 8.8 Wrap `web_search` / `web_fetch` FFI calls in worker isolates following existing `sendMessage` pattern (`Isolate.spawn` + `SendPort`/`ReceivePort`)
- [ ] 8.9 Add search result display handling for tool call cards: per-namespace display showing provider name + result count + first result preview (title + URL if present, content truncated at 200 chars per result); error namespaces show error message truncated at 200 chars; total per-namespace rendered length capped at 2000 chars with `... (N more results)` overflow indicator

⛔ **STOP HERE** — Phase 7-8 完成后停止，等用户确认 "execute phase 9"

## 9. C++ Tests (Tier 1 — Provider Logic)

- [ ] 9.0 Enhance MockServer: support configurable Content-Type (not just text/event-stream); support plain (non-chunked) response body mode for SearXNG and web_fetch tests; support optional multi-request loop mode for ZhipuAI/Kimi SSE sequences

### Interface & Dispatch
- [ ] 9.1 `ISearchProvider` interface: mock provider → verify `ProviderResult` normalization (empty results with no error vs empty results with error distinguishable)
- [ ] 9.2 Parallel dispatch: three mock providers → verify per-namespace output and error isolation
- [ ] 9.3 Provider registry: register 3 providers, configure 2 → verify only configured ones appear
- [ ] 9.4 Provider timeout: mock provider sleeps 10s → verify dispatcher returns timeout error for that namespace while other results intact

### Web Fetch
- [ ] 9.5 `web_fetch` HTML: MockServer returns HTML → verify tag stripping + whitespace compression
- [ ] 9.6 `web_fetch` JSON: MockServer returns `application/json` → verify raw text returned (no tag stripping)
- [ ] 9.7 `web_fetch` SSRF: verify `http://127.0.0.1/` rejected (IPv4 loopback); `http://[::1]:8080/` rejected (IPv6 loopback); `http://localhost/` rejected (hostname); `HTTP://169.254.169.254/` rejected (case-insensitive scheme + link-local); `file:///etc/passwd` rejected (scheme); `https://example.com` allowed; `http://127.0.0.1.nip.io/` rejected (DNS rebinding → socket callback catches resolved IP); HTTP 301 redirect to internal IP rejected (redirect target re-validated)
- [ ] 9.8 `web_fetch` error: MockServer returns HTTP 500 → verify error message

### ZhipuAI Provider
- [ ] 9.9 ZhipuAI basic search: MockServer simulates OpenAI SSE msearch stream → verify mapping to SearchResult
- [ ] 9.10 ZhipuAI deep search: inject mock event sequence (msearch + mclick) directly into adapter (bypass HTTP) → verify full page text collected
- [ ] 9.11 ZhipuAI partial mclick failure: mock 2/3 mclick success → verify 2 full-text + 1 snippet returned
- [ ] 9.12 ZhipuAI abort: mock content after msearch → verify final text answer discarded

### SearXNG Provider
- [ ] 9.13 SearXNG success: MockServer returns valid JSON → verify `results[]` → `SearchResult` mapping with client-side truncation
- [ ] 9.14 SearXNG empty results: MockServer returns `{"results":[]}` → verify empty `ProviderResult` with no error
- [ ] 9.15 SearXNG unavailable: connection refused → verify transient error
- [ ] 9.16 SearXNG 403: format=json disabled → verify clear error message

### Kimi Provider
- [ ] 9.17 Kimi success: MockServer simulates SSE with `$web_search` → verify thinking disabled in request, answer captured
- [ ] 9.18 Kimi 429: MockServer returns 429 twice then 200 → verify retry logic
- [ ] 9.19 Kimi error: MockServer returns HTTP 400 → verify error

### Build
- [ ] 9.20 Add `search_provider_test.cpp` to `CMakeLists.txt`

### SearXNG Live Integration (requires local SearXNG)
- [ ] 9.21 SearXNG live: start local SearXNG via `tools/searxng/venv/Scripts/python -m searx.webapp` → `GET /search?q=hello&format=json&engines=bing` → verify HTTP 200 + `results[]` non-empty + valid `{title, url, content}` structure; skip test if `tools/searxng/` not set up (`--skip-searxng-live`)
- [ ] 9.22 SearXNG live — empty query: search for random gibberish → verify HTTP 200 + `results` empty array (not an error)
- [ ] 9.23 SearXNG live — request timeout: stop SearXNG mid-search → verify `ProviderResult` with transient error `is_transient=true`
- [ ] 9.24 SearXNG test helper: create `test/test_utils/searxng_harness.h/cpp` — `SearXNGHarness` class that starts `tools/searxng/` venv python, waits for `localhost:8888` readiness (poll up to 10s), stops on destruction; returns `is_available()` bool for test skip logic
- [ ] 9.25 Live API key loader: create `test/test_utils/api_key_loader.h/cpp` — reads `%USERPROFILE%\.aliasagent\config.json` (Windows) or `~/.aliasagent/config.json` (Linux/macOS), extracts `search.zhipuai.api_key` and `search.kimi.api_key`; returns empty string if config missing or key absent

### ZhipuAI Live Integration (requires API key in config.json)
- [ ] 9.26 ZhipuAI live — basic search: load API key from config.json → `ZhipuAISearch::search("Python programming", "basic", 5)` → verify `results[]` non-empty, each has valid `{title, url, content}`; skip if `search.zhipuai.api_key` missing
- [ ] 9.27 ZhipuAI live — deep search: `ZhipuAISearch::search("Python programming", "deep", 3)` → verify results include full page content (not just snippets), content length significantly longer than basic; skip if key missing
- [ ] 9.28 ZhipuAI live — empty results: search for random 20-char gibberish → verify graceful handling (empty results or small set, no crash); skip if key missing

### Kimi Live Integration (requires API key in config.json)
- [ ] 9.29 Kimi live — basic search: load API key from config.json → `KimiSearch::search("latest AI news", "basic", 1)` → verify single `SearchResult` with non-empty `content` (synthesized answer), empty `title`/`url`; verify `"thinking": {"type": "disabled"}` was set in request; skip if `search.kimi.api_key` missing
- [ ] 9.30 Kimi live — no results for nonsense: search for random gibberish → verify `ProviderResult` with empty results but no error; skip if key missing

## 10. Dart Widget Tests (Tier 2 — Tool Dispatch + FakeSidecar)

- [ ] 10.1 Add `web_search` / `web_fetch` / `get_search_providers` / `ensure_search_infra` to `ISidecar` abstract interface
- [ ] 10.2 Update `FakeSidecar` with new methods returning configurable preset data
- [ ] 10.3 Tool definition: FakeSidecar returns providers → verify description includes names + `depth` in input_schema
- [ ] 10.4 Tool definition with multiple providers: verify all in enum
- [ ] 10.5 Conditional registration — no providers: FakeSidecar returns empty → tools absent
- [ ] 10.6 `_executeTool` dispatch — web_search: verify isolate spawn + correct JSON
- [ ] 10.7 `_executeTool` dispatch — web_fetch: verify isolate spawn + correct URL
- [ ] 10.8 `_executeTool` error propagation: Sidecar returns error → verify passed to model

⛔ **STOP HERE** — Phase 9-10 完成后停止，等用户确认 "execute phase 11"

## 11. Dart Integration Tests (Tier 3 — End-to-End + UI)

- [ ] 11.1 web_search end-to-end: FakeSidecar returns namespaced results → verify ToolCallCard renders provider summary
- [ ] 11.2 Multi-provider display: verify namespaces visible in result card
- [ ] 11.3 Provider error display: verify error shown per namespace
- [ ] 11.4 web_fetch end-to-end: verify result displayed

### SearXNG Live Integration (Tier 3 — real Sidecar + real SearXNG)
- [ ] 11.5 SearXNG live end-to-end: start SearXNG → start app with real Sidecar → trigger `web_search` with provider `searxng` → verify ToolCallCard renders real search result titles; skip if `tools/searxng/` not set up

## 12. Documentation

- [ ] 12.1 Document provider config (per-provider snake_case keys: `search.zhipuai.api_key`, `search.kimi.api_key`; SearXNG Python dev mode deployment via `scripts/setup_searxng.bat`) in DEBUGGING.md
- [ ] 12.2 Document API key security: plaintext in config.json; crash dumps use MiniDumpNormal (no heap); log body at DEBUG not INFO; config key naming uses snake_case (`api_key`) consistent with existing `ProviderConfig.api_key`
- [ ] 12.3 Add search tool usage examples to DEBUGGING.md
