# Tasks: Add Web Search Tool

## 1. C++ Search Provider Interface

- [x] 1.1 Define `SearchResult` struct (`title`, `url`, `content`) and `SearchError` struct (`message`, `is_transient`) in `sidecar/src/search_provider.h`
- [x] 1.2 Define `ProviderResult` struct (`results`, `error`) — empty results + empty error = "no matches"; empty results + non-empty error = failure
- [x] 1.3 Define `ISearchProvider` abstract interface with `name()`, `description()`, `is_configured()`, `search(query, depth, max_results)` returning `ProviderResult`
- [x] 1.4 Implement provider registry: on `ensure_search_infra` call, parse JSON and cache per-provider credentials into provider instances; expose `get_search_providers()` returning configured provider list (checking cached keys, NOT reading filesystem); per-provider key check (`search.zhipuai.api_key`, NOT flat `search.api_key`)
- [x] 1.5 Implement parallel dispatch using `std::future` + `wait_for` (NOT `std::thread::join`): spawn each provider via `std::async`, await with 30s deadline via `wait_until`, aggregate completed results + timeout errors for incomplete; each provider uses own curl handle + buffer
- [x] 1.6 Implement deadline enforcement: `std::future::wait_for` with 30s total deadline; after deadline, completed provider results returned + incomplete providers get timeout error; timed-out futures continue in background (no detach/leak — their destructors clean up naturally)
- [x] 1.7 Implement per-provider timeouts (SearXNG: 5s via `CURLOPT_TIMEOUT`, ZhipuAI: 30s/round via SSE timeout, Kimi: 30s via `CURLOPT_TIMEOUT`)
- [x] 1.8 Add `search_provider.cpp` / `search_provider.h` to `CMakeLists.txt` (both `sidecar` DLL and `sidecar_tests` targets)

## 2. C++ OpenAI Transport Layer

- [x] 2.1 Implement OpenAI SSE parser utility: line-buffered → parse `data:` lines → dispatch on `choices[0].delta.content` (text), `choices[0].delta.tool_calls[].function` (tool call, include `.id` capture alongside `.function.name` and `.function.arguments`), `choices[0].finish_reason` (done)
- [x] 2.2 Implement OpenAI HTTP request builder: `POST /v1/chat/completions`, `Authorization: Bearer`, OpenAI-format body (messages array, tools array, model)
- [x] 2.3 Implement SSE parse error accumulation: count malformed lines per request, return error if count exceeds 10
- [x] 2.4 Implement SSE `line_buf` size guard: add 64KB upper limit in write callback (before `line_buf += c`); return 0 to abort transfer when exceeded; prevents unbounded memory growth on malicious/noisy streams; apply to both existing `model_gateway.cpp` and new SSE handlers
- [x] 2.5 Implement SSE delta accumulation for `function.arguments`: accumulate fragment strings by `tool_calls[].index` across multiple SSE delta events; capture `tool_calls[].id` for constructing follow-up tool messages; enforce 1MB aggregate per-event cap to prevent multi-line OOM; parse accumulated JSON only when all arguments have been received (indicated by `finish_reason` or block completion)
- [x] 2.6 Each adapter creates its own curl handle — no sharing with ModelGateway or other adapters. All HTTPS handles SHALL set `CURLOPT_SSL_VERIFYPEER=1L`
- [x] 2.7 Extract `json_escape()` from `tools.cpp:146-160` to `tools.h` as public function (remove `static`, add declaration); needed by all search provider .cpp files for D9 error message serialization

⛔ **STOP HERE** — Phase 1-2 完成后停止，等用户确认 "execute phase 3"

## 3. C++ Web Fetch Implementation

- [x] 3.1 Implement SSRF socket-level protection via `CURLOPT_OPENSOCKETFUNCTION`: callback fires after DNS resolve before connect; validate `struct sockaddr` against blocklist (IPv4: 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 0.0.0.0/8, 100.64.0.0/10; IPv6: ::1/128, fe80::/10, fc00::/7, ::ffff:0:0/96 with embedded IPv4 extraction, 64:ff9b::/96 NAT64 with embedded IPv4 extraction); block returns CURL_SOCKET_BAD; default-deny unknown sa_family values
- [x] 3.2 Implement URL pre-flight checks: case-insensitive scheme validation (lowercase before compare); reject localhost hostname (case-insensitive); set `CURLOPT_PROTOCOLS = CURLPROTO_HTTP | CURLPROTO_HTTPS`
- [x] 3.3 Implement web_fetch write callback with incremental size cap: on each chunk, accumulate size; if >100KB return 0 to abort transfer; prevents zip bomb / infinite chunked response
- [x] 3.4 Implement `web_fetch`: libcurl HTTP GET → Content-Type check (MIME type exact equality match before `;`, case-insensitive) → text/html (including `text/html; charset=utf-8`): tag stripping + whitespace compression; non-HTML / NULL Content-Type / missing header: return raw text (capped at 100KB by write callback)
- [x] 3.5 Configure curl options: timeout (15s via `CURLOPT_TIMEOUT`), `CURLOPT_CONNECTTIMEOUT=15L`, `CURLOPT_FOLLOWLOCATION=1`, `CURLOPT_MAXREDIRS=5`, `CURLOPT_REDIR_PROTOCOLS_STR="http,https"`, `CURLOPT_ACCEPT_ENCODING=""`, `CURLOPT_SSL_VERIFYPEER=1L`, User-Agent header
- [x] 3.6 Handle errors: unreachable host, TLS failure, HTTP 4xx/5xx, timeout, blocked URL (SSRF), redirect to internal address

## 4. C++ ZhipuAI Search Provider

- [x] 4.1 Implement `ZhipuAISearch` class inheriting `ISearchProvider` in `zhipuai_search.h/cpp`
- [x] 4.2 Implement non-streaming HTTP POST to ZhipuAI Chat API: construct messages `[{"role":"user","content": query}]` → register tool `[{"type":"web_search","web_search":{"search_result":true}}]` → POST `/chat/completions` with `stream: false` (model: `glm-4.7-flash` default, configurable via `search.zhipuai.model`). **Note: rewritten from SSE agent loop — now uses non-streaming JSON POST.**
- [x] 4.2a REWRITE: Replace SSE agent loop with non-streaming HTTP POST + JSON response parsing. Remove openai_transport dependency for ZhipuAI. Parse top-level `web_search[]` array from response JSON → map `{title, link, content}` → `SearchResult[]`. Optionally capture `message.content` as synthesized answer. D4 updated: tool format is `{"type":"web_search","web_search":{"search_result":true,...}}` — the `search_result` flag controls whether `web_search[]` appears in the response.
- [x] 4.3 DEPRECATED — depth parameter ignored. `web_search` tool does not support basic/deep control; platform auto-determines search depth.
- [x] 4.4 DEPRECATED — no mclick tool_result cycle needed. Platform handles search+reading internally.
- [x] 4.5 Normalize `web_search` response `{title, link, content}` → `SearchResult{title, url=link, content}`
- [x] 4.6 DEPRECATED — no SSE parsing, no tool_calls interception. Platform auto-executes search.
- [x] 4.7 Implement timeout: 30s for single non-streaming HTTP POST (CURLOPT_TIMEOUT)
- [x] 4.8 Add `zhipuai_search.cpp` to `CMakeLists.txt` (both targets)

⛔ **STOP HERE** — Phase 3-4 完成后停止，等用户确认 "execute phase 5"

## 5. C++ SearXNG Self-Host Provider

- [x] 5.1 Implement `SearXNGSelfHost` class inheriting `ISearchProvider` in `searxng_search.h/cpp`
- [x] 5.2 Implement search: URL-encode query → GET `/search?q=<encoded>&format=json` (no `limit` param — SearXNG doesn't support it) → parse JSON → client-side truncate to `max_results` → map to `SearchResult[]`
- [x] 5.3 Handle HTTP 403 with clear error: "ensure format: json is enabled in settings.yml"
- [x] 5.4 Handle SearXNG unavailable: connection refused / timeout (5s) → return `ProviderResult` with transient error
- [x] 5.5 Add `searxng_search.cpp` to `CMakeLists.txt` (both targets)
- [x] 5.6 Create `scripts/setup_searxng.bat` (Windows) and `scripts/setup_searxng.sh` (Linux/macOS): clone SearXNG to `tools/searxng/` with `--depth 1` → check prerequisites (Python 3.7+, git) with clear error messages → create venv → install pre-reqs (`pyyaml msgspec typing-extensions pybind11 tomli tzdata`) → pip install -e . (with proxy guidance on failure) → generate `settings.yml` with `use_default_settings: true`, `format: [html, json]`, Bing engines with `base_url: https://cn.bing.com`, `port: 8888`, `bind_address: "127.0.0.1"`, random `secret_key`, `valkey.url: false` → launch `python -m searx.webapp`; include stop/update commands; `tools/searxng/` is in `.gitignore`

## 6. C++ Kimi Search Provider

- [x] 6.1 Implement `KimiSearch` class inheriting `ISearchProvider` in `kimi_search.h/cpp`
- [x] 6.2 Set `"thinking": {"type": "disabled"}` in request body (required by Kimi for `$web_search`)
- [x] 6.3 Implement NO-OP relay with OpenAI transport: register `$web_search` as `builtin_function` → set `tool_choice: {"type": "builtin_function", "builtin_function": {"name": "$web_search"}}` (force search invocation) → intercept `tool_calls` → accumulate `function.arguments` by `tool_calls[].index` → return complete arguments unchanged as `tool_result` → collect final text answer; if arguments missing/null return ProviderResult error
- [x] 6.4 Normalize: single `SearchResult` with synthesized answer in `content`, empty `title`/`url`
- [x] 6.5 Handle errors: API error, timeout, empty response, missing/null tool_call arguments, no tool_calls before finish_reason=stop
- [x] 6.6 Implement Kimi-specific HTTP 429 retry: up to 2 retries with exponential backoff (1s, 2s), respecting `Retry-After` header; on third 429 return transient error. SearXNG and ZhipuAI do NOT retry in v1
- [x] 6.7 Use `moonshot-v1-auto` as default Kimi model (configurable via `search.kimi.model` in config.json)
- [x] 6.8 Add `kimi_search.cpp` to `CMakeLists.txt` (both targets)

⛔ **STOP HERE** — Phase 5-6 完成后停止，等用户确认 "execute phase 7"

## 7. C++ Sidecar API

- [x] 7.1 Add `web_search(const char* request_json)` function → catch all exceptions (D9), parses providers[], dispatches in parallel via future+wait_for, serializes namespaced content as JSON string before returning
- [x] 7.2 Add `web_fetch(const char* request_json)` function → catch all exceptions (D9), validates URL, fetches, returns JSON result
- [x] 7.3 Declare `web_search` / `web_fetch` / `ensure_search_infra` / `get_search_providers` with `SIDECAR_API` in `sidecar_api.h` (all snake_case, matching existing `send_message`/`read_file`/`list_dir` convention)
- [x] 7.4 Add `get_search_providers()` function with `SIDECAR_API` → catch all exceptions (D9) → returns JSON array of configured provider `{name, description}`
- [x] 7.5 Implement `ensure_search_infra(const char* search_config_json)`: catch all exceptions (D9), parse JSON → cache per-provider API keys + SearXNG base URL into provider instances; perform SearXNG liveness check once (TCP connect to localhost:8888, 2s timeout), cache result; use `static bool` or `std::call_once` to guarantee idempotency (repeated calls return `{"ok":true}` immediately without re-running TCP check); called once at startup before tool definition construction
- [x] 7.6 Implement D9 exception safety: every `extern "C"` function wraps body in try/catch(std::exception&) + catch(...), returning `{"ok":false,"error":"..."}`; **error messages SHALL pass through `json_escape()` (existing `tools.cpp:146-160`, extract to `tools.h`)** before embedding in JSON; thread-safety: D9 static string pattern per-function is acceptable given serialized Dart tool execution, but add comment documenting the serialization assumption; each provider thread wraps search() in try/catch → ProviderResult with is_transient=false for unexpected errors

## 8. Dart Tool Integration

- [x] 8.1 Extend `AppConfig` model: add `search` field (`Map<String, dynamic>?`) to carry `search.zhipuai.api_key`, `search.kimi.api_key`, `search.searxng.baseUrl` from `config.json`; `fromJson()` reads `json['search']` as nullable map; `toJson()` conditionally includes `search` when non-null and non-empty (prevents ConfigService.save() from silently dropping the search block on unrelated config changes)
- [x] 8.2 At startup, read search config from `ConfigService` → serialize to JSON → call C++ `ensure_search_infra` via FFI (following same path as `sendMessage`'s `api_key` parameter); only then build tool definitions
- [x] 8.3 Refactor `_toolDefs` from `static const` to an instance-level `late final` field (or static `late final`), initialized at startup: `read_file` + `list_dir` + conditionally `web_search`/`web_fetch` (based on `get_search_providers()` result). Build `web_search` tool definition dynamically: fetch provider list from Sidecar via `get_search_providers()` → generate description with per-provider capabilities → set `providers` enum (default empty array = use all configured) and `depth` parameter
- [x] 8.3a Change `_executeTool` signature to `Future<Map<String, dynamic>>` (from sync to async); add `await` at the tool loop call site (`lib/main.dart` line 521-522). Existing synchronous `read_file`/`list_dir` calls remain valid inside the async method
- [x] 8.4 Add `web_fetch` tool definition to `_toolDefs` in `lib/main.dart` (v1: extract_mode only "text"), conditionally included per provider availability
- [x] 8.5 Add `web_search` and `web_fetch` dispatch branches to `_executeTool`; web_search/web_fetch branches use async `Isolate.spawn` + `ReceivePort` pattern; serialize content as JSON string for tool result contract compatibility
- [x] 8.6 Conditionally include tools only when at least one search provider is configured (check per-provider keys via `get_search_providers()` result, NOT by re-reading config.json). When `AppConfig.search` is null (config.json has no `search` key), Dart SHALL pass `"{}"` to `ensure_search_infra`
- [x] 8.7 Add `web_search` / `web_fetch` / `get_search_providers` / `ensure_search_infra` FFI bindings in `lib/services/sidecar_bridge.dart` (Dart typedefs use camelCase pointing to snake_case C symbols)
- [x] 8.8 Wrap `web_search` / `web_fetch` FFI calls in worker isolates following existing `sendMessage` pattern (`Isolate.spawn` + `SendPort`/`ReceivePort`); add `.timeout(Duration(seconds: 120))` on ReceivePort to prevent isolate hang if Sidecar process crashes via SEH exception
- [x] 8.8a Retrofit existing `sendMessage` ReceivePort (`sidecar_bridge.dart` line 136 `await for` loop) with `.timeout(Duration(seconds: 120))` — same SEH crash hang protection as 8.8, but for the main model inference path
- [x] 8.9 Add search result display handling for tool call cards: per-namespace display showing provider name + result count + first result preview (title + URL if present, content truncated at 200 chars per result); error namespaces show error message truncated at 200 chars; total per-namespace rendered length capped at 2000 chars with `... (N more results)` overflow indicator

⛔ **STOP HERE** — Phase 7-8 完成后停止，等用户确认 "execute phase 9"

## 9. C++ Tests (Tier 1 — Provider Logic)

每个测试任务包含：被测行为（对应 spec 哪条 requirement）、前置条件、测试步骤、断言。

### 9.0 — 测试基础设施增强

9.0 的所有子任务必须在其他测试任务之前完成，因为后续测试全部依赖这些基础设施。

- [x] 9.0a Content-Type 可配置
  - **做什么**: 在 MockServer 增加 `set_content_type(string)` 方法
  - **改动文件**: `sidecar/test/mock_server.h`，加 `string content_type_` 成员和 setter
  - **验证**: `build_response()` 的 `Content-Type` header 使用设置值而非硬编码 `text/event-stream`

- [x] 9.0b plain 模式
  - **做什么**: 增加 `set_plain_mode(bool)`，为 true 时使用 `Content-Length` + body（非 chunked），为 false 时用 `Transfer-Encoding: chunked`
  - **改动文件**: `sidecar/test/mock_server.h`，加 `bool plain_mode_` 成员和 setter，修改 `build_response()`
  - **验证**: plain=true 时响应不含 `Transfer-Encoding` header，含 `Content-Length`

- [x] 9.0c inline body
  - **做什么**: 增加 `set_response_body(string)`，直接设置响应体字符串，不依赖 fixture 文件
  - **改动文件**: `sidecar/test/mock_server.h`，加 `string response_body_` 成员和 setter
  - **验证**: 不传 fixture 文件启动 MockServer，响应 body 等于 set_response_body 设置的值

- [x] 9.0d multi-request 模式 + response queue
  - **做什么**: (a) 增加 `set_multi_request(bool)` 使 `serve()` 循环 accept 直到 `stop()`；(b) 增加 `queue_response(int status, string content_type, string body)` 预置每次请求的响应到 `vector<Response>` 队列，每次 accept 取出队首（`queue_response` 可多次调用，依次入队）；(c) 增加 `request_count()` 返回已处理的请求数
  - **改动文件**: `sidecar/test/mock_server.h`，加 `bool multi_request_`、`bool stop_`、`struct Response {int status; string content_type; string body;}`、`vector<Response> response_queue_`、`atomic<int> request_count_`
  - **验证**: multi-request=true + queue 3 个响应 → 3 次 HTTP 请求各得对应的响应，`request_count()==3`

- [x] 9.0e mock provider 注入机制
  - **被测需求**: 以下 dispatch 测试（9.2a/9.2b/9.2c）需要用 mock provider 模拟各种场景
  - **做什么**: 在 `search_provider.h/cpp` 增加 `void set_test_providers(vector<shared_ptr<ISearchProvider>>)` 函数，`get_configured_providers()` 在 test providers 非空时返回 test providers 而非真实 provider
  - **改动文件**: `search_provider.h`（声明）、`search_provider.cpp`（`static vector<shared_ptr<ISearchProvider>> g_test_providers` + setter + 修改 `get_configured_providers()`）
  - **验证**: 注入 2 个 MockProvider → `get_configured_providers().size()==2` → dispatch 使用 mock

### Interface & Dispatch（纯逻辑，不涉及网络）

- [x] 9.1 `ISearchProvider` 接口 — `ProviderResult` 归一化
  - **被测行为**: spec `search-provider.md` "Empty results vs error distinguishable"
  - **前置**: 创建 MockProvider（只实现接口，不做网络请求），配置两个实例：一个返回 `results=[] + error={message="", is_transient=false}`，另一个返回 `results=[] + error={message="Network error", is_transient=true}`
  - **步骤**: (a) 调用第一个 provider 的 `search()`；(b) 调用第二个 provider 的 `search()`
  - **断言**: (a) `results.size() == 0 && error.message == ""`；(b) `results.size() == 0 && error.message == "Network error" && error.is_transient == true`
  - **基础设施**: 无需 MockServer

- [x] 9.2 并行调度 — 无 provider 时返回错误
  - **被测行为**: spec `web-search/spec.md` "All providers fail" — 调用 dispatch 时无 provider 可用
  - **前置**: 不调用 `set_test_providers()`（test providers 为空），真实 provider 也未配置
  - **步骤**: `dispatch_web_search(R"({"query":"test","depth":"basic","max_results":5})")`
  - **断言**: `ok == false`，`error` 包含 "No search providers configured"
  - **基础设施**: 依赖 9.0e

- [x] 9.2a 并行调度 — 一个成功一个失败
  - **被测行为**: spec `web-search/spec.md` "One provider fails, others succeed" + "Namespaced search results with error isolation"
  - **前置**: 9.0e mock 注入。创建两个 MockProvider：`success_provider` 返回 `{title:"OK", url:"http://ok", content:"good"}`，`fail_provider` 返回 `error={message:"fail", is_transient:true}`
  - **步骤**: `set_test_providers({fail_provider, success_provider})` → `dispatch_web_search(...)`
  - **断言**: (a) `ok == true`（有一个成功就不算全失败）；(b) `content.fail_provider.error=="fail"` 且 `results` 为空；(c) `content.success_provider.results[0].title=="OK"`；(d) `content.success_provider.error` 字段不存在或为 null
  - **基础设施**: 9.0e

- [x] 9.2b 并行调度 — 超时隔离
  - **被测行为**: spec `web-search/spec.md` "Hung provider times out, fast providers complete"
  - **前置**: 9.0e + 一个 sleep mock provider（`search()` 中 `this_thread::sleep_for(35s)`，默认 deadline 30s）+ 一个快速 mock provider
  - **步骤**: `set_test_providers({sleep_provider, fast_provider})` → `dispatch_web_search(deadline=30s)`
  - **断言**: (a) `content.fast_provider` 有正常结果；(b) `content.sleep_provider.error` 含 "Timeout"
  - **基础设施**: 9.0e

- [x] 9.2c 并行调度 — provider 选择（单 provider + 多 provider）
  - **被测行为**: spec `web-search/spec.md` "Main model selects single provider" + "Main model selects multiple providers"
  - **前置**: 9.0e + 3 个快速 mock provider（mock_a, mock_b, mock_c）
  - **步骤**:
    - (a) 单 provider 选择: `dispatch_web_search(R"({"query":"test","providers":["mock_a"],"depth":"basic","max_results":3})")` → 断言 `content` 只包含 `mock_a`，不含 `mock_b` 和 `mock_c`
    - (b) 多 provider 选择: `dispatch_web_search(R"({"query":"test","providers":["mock_a","mock_b"],"depth":"basic","max_results":3})")` → 断言 `content` 包含 `mock_a` 和 `mock_b`，不含 `mock_c`
    - (c) 空 providers 数组（默认全选）: `dispatch_web_search(R"({"query":"test","depth":"basic","max_results":3})")`（不传 providers）→ 断言所有 3 个 mock provider 都被调用
  - **基础设施**: 9.0e

- [x] 9.3 Provider registry — 仅已配置的 provider 出现
  - **被测行为**: spec `search-provider/spec.md` "Provider registry and tool description generation"
  - **前置**: 调用 `ensure_search_infra(...)` 传入含 ZhipuAI api_key 的 JSON，然后调用 `get_search_providers_json()`
  - **步骤**: (a) `ensure_search_infra(R"({"zhipuai":{"api_key":"test_key"}})")`；(b) `string json = get_search_providers_json()`；(c) 解析 JSON 数组
  - **断言**: 返回数组包含一个元素 `{name: "zhipuai", description: "..."}`; 不包含 kimi 或 searxng（没有传他们的配置）
  - **基础设施**: 依赖 `ensure_search_infra` 正确缓存 api_key 到 `get_zhipuai_provider()` 实例

- [x] 9.4a Input validation
  - **被测行为**: spec `search-provider/spec.md` "Input validation at provider interface"
  - **步骤**:
    - (a) `dispatch_web_search(R"({"query":""})")` → 断言 `ok==false, error 含 "empty"`
    - (b) `dispatch_web_search(R"({"query":"test","max_results":0})")` → 在 dispatcher 内部 `max_results` clamp 逻辑已验证后，注入一个记录 `max_results` 实际值的 mock provider。断言 mock provider 的 `search()` 收到 `max_results==1`（而非 0）。不依赖真实 provider——通过 9.0e mock 注入实现
    - (c) `dispatch_web_search(R"({"query":"test","max_results":100})")` → 断言 dispatcher 将 100 clamp 为 10
  - **基础设施**: 无需 MockServer

- [x] 9.4b Dispatcher all providers fail
  - **被测行为**: spec `web-search/spec.md` "All providers fail" scenario
  - **前置**: 无 provider 配置 → dispatcher 直接返回 error
  - **步骤**: `dispatch_web_search(R"({"query":"test","depth":"basic","max_results":5})")`
  - **断言**: `ok == false`, `error` 字段存在且非空
  - **基础设施**: 无需 MockServer

- [x] 9.4c D9 exception safety
  - **被测行为**: design D9 — extern "C" 函数内 catch 所有异常
  - **步骤**:
    - (a) 传 malformed JSON 给 `dispatch_web_search("not valid json{{{{")` → 断言 `ok==false, error 非空`
    - (b) 传 malformed JSON 给 `web_fetch("bad json")` → 同样断言不崩溃、返回 error
    - (c) 通过 `sidecar_api.h` 的 `web_search()` / `web_fetch()` wrapper 传 nullptr → 断言不崩溃
  - **基础设施**: 无需 MockServer

- [x] 9.4d Permanent errors not retried
  - **被测行为**: spec `web-search/spec.md` "Permanent errors not retried" — HTTP 401/403 立即返回，不重试
  - **前置**: 9.0e + 2 个 mock provider：一个在 `search()` 中返回 `error={message="401 Unauthorized", is_transient=false}`，另一个返回正常结果
  - **步骤**: `set_test_providers({unauth_provider, ok_provider})` → `dispatch_web_search(...)`
  - **断言**: (a) `content.unauth_provider.error` 非空，`is_transient` 应为 false（但序列化后不保留，通过 error string 判断——含 "401"）；(b) `content.ok_provider` 正常；(c) `ok == true`（有一个成功）
  - **说明**: is_transient 字段在 dispatcher 序列化时被丢弃（design D3），所以断言只检查 error 字符串内容
  - **基础设施**: 9.0e

- [x] 9.4e SearXNG and Kimi ignore depth
  - **被测行为**: spec `web-search/spec.md` "SearXNG and Kimi ignore depth" — depth 参数传入但不影响搜索行为
  - **策略**: 直接测 provider 接口，不需要完整 dispatch
  - **步骤**: (a) `get_searxng_provider()->search("test", "deep", 5)` → 断言和 `search("test", "basic", 5)` 结果一致（都是同样的 GET + JSON 解析，不因 depth 不同而改变行为）；(b) `get_kimi_provider()->search("test", "deep", 1)` → 断言 depth 不影响请求（Kimi 的 `search()` 签名中 depth 参数被忽略，始终发同样的 POST）
  - **说明**: 这两个 provider 在实现中明确忽略了 depth 参数，测试只需要验证传入任意 depth 值都不会崩溃或改变行为
  - **基础设施**: MockServer 单请求（SearXNG）/ 9.0d（Kimi 可能 multi-turn）

### Web Fetch

> **注意**: web_fetch 有 SSRF 防护，会拦截 localhost 连接。MockServer 绑在 localhost 上，所以 web_fetch 不能直接对 MockServer 做 e2e 测试。以下测试分两类：
> - **纯函数测试**（直接测 `strip_html_tags`、`is_blocked_ipv4` 等内部函数）
> - **需 MockServer 的测试**（特指 9.15/9.16 SearXNG 测试，因为 SearXNG provider 直接发 curl 请求不走 web_fetch SSRF）

- [x] 9.5 HTML tag stripping
  - **被测行为**: spec `web-fetch/spec.md` "HTML page extracted to text" + "Content-Type based extraction"
  - **步骤**:
    - (a) `strip_html_tags("<html><body><h1>Hello</h1><p>World</p><script>alert(1)</script></body></html>")`
    - (b) `strip_html_tags("<div>  hello    world  </div>")`
  - **断言**:
    - (a) 结果包含 "Hello" 和 "World"，不含 `<h1>`、`<script>`、`alert`
    - (b) 结果包含 "hello world"（多个空格压缩为一个），不含连续空格
  - **基础设施**: 无需 MockServer（纯函数）

- [x] 9.5a web_fetch Content-Type text/html with charset
  - **被测行为**: spec `web-fetch/spec.md` "HTML with charset suffix extracted to text"
  - **前置**: 需要一个 HTTP server 返回 `Content-Type: text/html; charset=utf-8` 且 body 为 HTML
  - **约束**: web_fetch SSRF 拦截 localhost，无法用 MockServer。当前测试策略：**直接测试 MIME type 提取逻辑**——`web_fetch.cpp` 内部 `extract_mime_type("text/html; charset=utf-8")` 应返回 `"text/html"`，且 `iequals("text/html", "text/html")` 为 true
  - **步骤**: (a) 调用 `extract_mime_type("text/html; charset=utf-8")` → "text/html"；(b) 调用 `extract_mime_type("text/plain")` → "text/plain"；(c) 调用 `iequals("text/html", "TEXT/HTML")` → true
  - **断言**: 各返回值正确
  - **基础设施**: 需要将 `extract_mime_type` 和 `iequals` 从 `web_fetch.cpp` 内部 static 函数改为测试可访问（移到 header 或用 `#ifdef TEST`）
  - **替代方案**: 如果上面的函数不方便暴露，则写一个集成测试——MockServer bind 到 `127.0.0.1`，测试代码**绕过 web_fetch 的 URL pre-flight 检查**（直接调用内部的 curl 请求函数），验证 Content-Type 解析和 tag strip 行为。这需要将 web_fetch 的核心逻辑拆分为：URL 验证 → curl 请求 → Content-Type 解析 → body 处理，且各步骤可独立测试

- [x] 9.5b web_fetch missing Content-Type defaults to raw
  - **被测行为**: spec `web-fetch/spec.md` "Missing Content-Type defaults to raw"
  - **约束**: 同 9.5a
  - **策略**: MockServer 返回无 Content-Type header 的响应（`set_content_type("")`），绕过 SSRF 的方式同 9.5a。验证 body 原样返回
  - **断言**: `ok==true`, `content` 等于原始 body（未被 tag-stripped）

- [x] 9.6 web_fetch JSON 返回 raw
  - **被测行为**: spec `web-fetch/spec.md` "JSON response returned raw"
  - **约束**: 同 9.5a
  - **策略**: MockServer Content-Type 设为 `application/json`，body 为 `{"key":"value"}`。验证 body 不被 tag-strip 修改
  - **断言**: `ok==true`, `content` 包含 `{"key":"value"}`

- [x] 9.6a web_fetch text/plain 返回 raw
  - **被测行为**: spec `web-fetch/spec.md` "Plain text returned as-is"
  - **约束**: 同 9.5a
  - **策略**: MockServer Content-Type 设为 `text/plain`，body 含 `<brackets>`。验证 tag 不被 strip（`<brackets>` 保留）
  - **断言**: `ok==true`, `content` 包含 `<brackets>`

- [x] 9.7 web_fetch SSRF — URL pre-flight + socket 层 blocklist
  - **被测行为**: spec `web-fetch/spec.md` SSRF protection 全部 16 个 scenario
  - **策略**: (a) URL pre-flight 检查（scheme/hostname）通过直接调用 `web_fetch()` 测试，因为它们在 socket 连接之前就返回错误；（b) socket 层 IP blocklist 通过直接测试内部函数 `is_blocked_ipv4()` 和 `is_blocked_ipv6()` 实现，因为 SSRF 正确拦截 localhost 导致 MockServer 不可达
  - **步骤 — URL pre-flight（通过直接调用 `web_fetch()` 测试，不涉及 socket 连接）**:
    - (pf1) `web_fetch(R"({"url":"file:///etc/passwd","extract_mode":"text"})")` → `ok==false, error 含 "scheme not allowed"`
    - (pf2) `web_fetch(R"({"url":"http://localhost:8080/admin","extract_mode":"text"})")` → `ok==false, error 含 "internal address not allowed"`（hostname "localhost" 在 URL 解析阶段被拒绝，不进入 socket）
    - (pf3) `web_fetch(R"({"url":"HTTP://169.254.169.254/","extract_mode":"text"})")` → scheme 小写化后匹配 `http:`，进入 socket callback → 被 IP blocklist 拦截。断言 `ok==false, error 含 "internal address"`（证明了 case-insensitive scheme 检查）
  - **步骤 — socket 层 blocklist（直接测试内部 SSRF 函数）**:
    - (a) `is_blocked_ipv4(ntohl(inet_addr("127.0.0.1")))` → true
    - (b) `is_blocked_ipv4(ntohl(inet_addr("10.0.0.1")))` → true
    - (c) `is_blocked_ipv4(ntohl(inet_addr("172.16.0.1")))` → true
    - (d) `is_blocked_ipv4(ntohl(inet_addr("192.168.1.1")))` → true
    - (e) `is_blocked_ipv4(ntohl(inet_addr("169.254.1.1")))` → true
    - (f) `is_blocked_ipv4(ntohl(inet_addr("0.0.0.1")))` → true
    - (g) `is_blocked_ipv4(ntohl(inet_addr("100.64.0.1")))` → true
    - (h) `is_blocked_ipv4(ntohl(inet_addr("8.8.8.8")))` → false（公网 IP）
    - (i) IPv6 loopback `::1` → true
    - (j) IPv6 link-local `fe80::1` → true
    - (k) IPv6 ULA `fc00::1` → true
    - (l) IPv4-mapped IPv6 `::ffff:127.0.0.1` → true（提取嵌入 IPv4 二次检查）
    - (m) NAT64 `64:ff9b::c0a8:0101`（嵌入 192.168.1.1）→ true
    - (n) 公网 IPv6 `2001:4860:4860::8888` → false
  - **额外**: `opensocket_callback` 传 `nullptr` → 返回 `CURL_SOCKET_BAD`（default-deny）
  - **基础设施**: 需要将 `is_blocked_ipv4`/`is_blocked_ipv6`/`opensocket_callback` 暴露给测试（声明在 `web_fetch.h` 或用 `#include "web_fetch.cpp"` 的 Catch2 方式）

- [x] 9.7a web_fetch write callback 100KB cap
  - **被测行为**: spec `web-fetch/spec.md` "Incremental size limit in write callback"
  - **策略**: 直接测试 `fetch_write_callback` 函数（当前为 `web_fetch.cpp` 内部 static）
  - **步骤**: (a) 创建 `FetchWriteCtx ctx`；(b) 循环调用 `fetch_write_callback(ptr, 1, MAX_RESPONSE_SIZE+1, &ctx)`，每次 `ptr = "A"`；(c) 当 `accumulated + 1 > MAX_RESPONSE_SIZE` 时，回调应返回 0
  - **断言**: 回调返回 0；`ctx.body.size() == MAX_RESPONSE_SIZE`（恰好 100KB，不多）
  - **基础设施**: `FetchWriteCtx` 和 `fetch_write_callback` 需暴露给测试（或移到 header）

- [x] 9.7b web_fetch timeout
  - **被测行为**: spec `web-fetch/spec.md` "Connection timeout" — 15s 内返回 timeout error
  - **前置**: MockServer accept 连接后不发送任何数据（模拟服务器挂死）
  - **步骤**: (a) 启动 MockServer（plain 模式，但不写响应）；(b) 调用 `web_fetch(url)`；(c) 等待最多 20s
  - **断言**: 返回 `ok==false, error 含 "timeout"`
  - **说明**: 此测试需要 15-20s。标记为 `[timeout_test]` 以便 CI 排除。SSRF 会拦截 localhost，需用 `127.0.0.1` 绕过 hostname 检查——但 socket 层也会拦截。**当前阻塞**：web_fetch 对 localhost/127.0.0.1 全部拦截，此测试需要额外绕过方案（如 build flag `-DTEST_DISABLE_SSRF`）。

- [x] 9.8 web_fetch HTTP error
  - **被测行为**: spec `web-fetch/spec.md` "HTTP error response" — HTTP 4xx/5xx 返回 structured error
  - **约束**: 同 9.5a（SSRF 拦截 localhost）
  - **步骤**: MockServer 返回 HTTP 500，验证 web_fetch 返回 `ok==false, error 含 "500"`
  - **断言**: 同 9.5a 的绕过方案

- [x] 9.5c Normal content under 100KB limit
  - **被测行为**: spec `web-fetch/spec.md` "Normal content under limit" — 50KB 内容正常通过
  - **策略**: 测 `fetch_write_callback` 函数。构造 50KB 数据，分多次写入
  - **步骤**: 创建 `FetchWriteCtx`，1000 次调用 `fetch_write_callback` 每次 50 字节（总共 50KB）
  - **断言**: 每次回调都返回写入的字节数（不返回 0，表示未中止）；`ctx.body.size() == 50000`
  - **基础设施**: 同 9.7a，`FetchWriteCtx` 和 `fetch_write_callback` 需暴露

- [x] 9.6b CURLOPT_PROTOCOLS + CURLOPT_REDIR_PROTOCOLS_STR enforced
  - **被测行为**: spec `web-fetch/spec.md` "CURLOPT_PROTOCOLS enforced" + "Redirect protocol switch blocked"
  - **策略**: 代码审查断言，不测试完整 web_fetch
  - **步骤**: (a) 确认 `web_fetch.cpp` 中有 `curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS)`；(b) 确认有 `curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https")`；(c) 确认没有设置其他 protocol flag
  - **断言**: 两行都存在且值正确。`CURLOPT_PROTOCOLS` 限制初始请求和重定向的全部 transfer；`CURLOPT_REDIR_PROTOCOLS_STR` 独立设置防止 HTTP→FTP 等协议切换攻击

- [x] 9.7c Default extract_mode
  - **被测行为**: spec `web-fetch/spec.md` "Default extract mode" — 不传 extract_mode 时默认 "text"
  - **策略**: 直接在 `web_fetch()` 函数逻辑中验证——传入 `{"url":"https://example.com"}`（无 extract_mode），函数内部 `req.value("extract_mode", "text")` 应返回 "text"
  - **步骤**: 用 `nlohmann::json::parse(R"({"url":"https://example.com"})")` 解析请求，取 `extract_mode` 默认值
  - **断言**: `extract_mode == "text"`
  - **基础设施**: 无需 MockServer（纯 JSON 解析测试）

- [x] 9.8a web_fetch TLS error
  - **被测行为**: spec `web-fetch/spec.md` "Fetch timeout and error handling" — TLS errors 返回 structured error
  - **策略**: 同 9.5a，用 MockServer 绕过 SSRF 后，测试 TLS 错误场景。MockServer 作为普通 HTTP server，web_fetch 用 HTTPS URL 连它 → curl 报 TLS 错误
  - **步骤**: MockServer 启动在 plain HTTP 端口，web_fetch URL 用 `https://127.0.0.1:PORT` → curl 尝试 TLS 握手失败
  - **断言**: `ok==false, error 含 "TLS"`
  - **基础设施**: 同 9.5a 的 SSRF 绕过方案

### ZhipuAI Provider

> **说明**: ZhipuAI 使用非流式 HTTP POST + JSON 响应。平台在内部完成搜索→阅读→综合，客户端只需解析返回的 `web_search[]` 结构化数组和 `choices[0].message.content` 综合回答。不需要 SSE、不需要 agent loop、不需要 tool_result 回传。
> MockServer 使用 plain 模式 + JSON Content-Type 模拟 chat completions 响应。

- [x] 9.9 ZhipuAI web_search success — JSON 解析 + SearchResult 映射
  - **被测行为**: spec `search-provider/spec.md` "ZhipuAI web_search" + spec `web-search/spec.md`
  - **前置**: MockServer plain 模式 + `application/json` Content-Type。响应体包含 `choices[0].message.content` 和顶层 `web_search[]` 数组
  - **步骤**: MockServer 返回 `{"choices":[{"message":{"content":"综合回答...[来源：ref_1]..."}}],"web_search":[{"title":"T1","link":"http://t1","content":"C1"},{"title":"T2","link":"http://t2","content":"C2"}]}` → `ZhipuAISearch::search("test", "basic", 5)`
  - **断言**: `results.size() >= 2`；`results[0].title == "T1"`；`results[0].url == "http://t1"`；`results[0].content == "C1"`
  - **注意**: 旧测试代码（search_provider_test.cpp:717）测试的是 SSE + msearch tool_call 旧格式，需重写为 JSON 响应解析测试。MockServer 用 plain 模式 + `Content-Type: application/json`，不需要 SSE 或 chunked 模式。
  - **基础设施**: MockServer 单请求 plain 模式 + JSON body

- [x] 9.9a ZhipuAI empty web_search results
  - **被测行为**: `web_search[]` 为空 — 成功态（无匹配结果）
  - **前置**: MockServer 返回 `{"web_search":[]}`
  - **断言**: `results.empty() && error.message.empty()`
  - **基础设施**: 同 9.9

- [x] 9.10 DEPRECATED — ZhipuAI deep search: 不再适用。web_search 不支持 depth 参数。
- [x] 9.11 DEPRECATED — ZhipuAI partial mclick: 不再适用。平台内部处理。
- [x] 9.12 DEPRECATED — ZhipuAI abort: 不再适用。无 agent loop。

- [x] 9.12b ZhipuAI HTTP error handling
  - **被测行为**: Chat API 返回 HTTP 4xx/5xx → 返回带错误信息的 ProviderResult
  - **前置**: MockServer 返回 HTTP 401/500（plain 模式 + JSON Content-Type）
  - **断言**: `error.message` 非空，含 HTTP 状态码
  - **注意**: 旧测试代码（search_provider_test.cpp:765）测试的是 SSE 流式错误场景（no tool_calls returns error），需重写为 HTTP 状态码错误测试。
  - **基础设施**: MockServer 单请求 plain 模式

- [x] 9.12c ZhipuAI request body verification
  - **被测行为**: 验证发送给 ZhipuAI 的 POST body 格式正确（非流式 JSON，不是 SSE）
  - **前置**: MockServer 接收 POST，通过 `last_body()` 暴露请求体
  - **步骤**: 调用搜索 → 检查 `last_body()` JSON
  - **断言**: body 含 `model`（默认 `glm-4.7-flash`）、`tools: [{"type":"web_search","web_search":{"search_result":true,...}}]`、`stream: false`、messages 非空
  - **注意**: 旧测试代码（search_provider_test.cpp:814）断言 `stream == true`（SSE 流式），需改为断言 `stream == false`。
  - **基础设施**: MockServer 单请求 plain 模式

### SearXNG Provider

> **说明**: SearXNG provider 直接发 GET 请求，不走 web_fetch SSRF。MockServer 单请求模式即可测试全部场景。

- [x] 9.13 SearXNG success — JSON → SearchResult 映射 + 客户端截断
  - **被测行为**: spec `search-provider/spec.md` "SearXNG search with client-side truncation"
  - **前置**: MockServer 返回 Content-Type `application/json`，body 为 `{"results":[{title:"T1",url:"http://1",content:"C1"},{title:"T2",url:"http://2",content:"C2"},{title:"T3",url:"http://3",content:"C3"}]}`
  - **步骤**: `get_searxng_provider()` → `set_base_url(server.base_url())` → `search("test", "basic", 2)`
  - **断言**: `results.size() == 2`（截断到 max_results=2）；`results[0].title == "T1"`；`results[1].url == "http://2"`
  - **基础设施**: MockServer（单请求模式即可），plain 模式 + JSON Content-Type

- [x] 9.14 SearXNG empty results
  - **被测行为**: spec `search-provider/spec.md` "SearXNG search" — 空 results 不是错误
  - **前置**: MockServer 返回 `{"results":[]}`
  - **步骤**: `search("gibberish", "basic", 5)`
  - **断言**: `results.empty() == true && error.message.empty() == true`（成功态，无错误）
  - **基础设施**: 同 9.13

- [x] 9.15 SearXNG unavailable
  - **被测行为**: spec `search-provider/spec.md` "SearXNG unavailable during search"
  - **前置**: MockServer 不启动，直接连不存在的端口 19999
  - **步骤**: `set_base_url("http://127.0.0.1:19999")` → `search("test", "basic", 5)`。需要 5s（CURLOPT_TIMEOUT）
  - **断言**: `error.is_transient == true`, `error.message` 含 "unavailable" 或连接错误
  - **说明**: 耗时 ~5s，CI 中标记为慢测试
  - **基础设施**: 无需 MockServer

- [x] 9.16 SearXNG 403 — format=json disabled
  - **被测行为**: spec `search-provider/spec.md` "SearXNG format=json not enabled server-side"
  - **前置**: MockServer 返回 HTTP 403
  - **步骤**: `search("test", "basic", 5)`
  - **断言**: `error.message` 同时包含 "403" 和 "format: json"
  - **基础设施**: MockServer 单请求，HTTP 403

### Kimi Provider

> **说明**: Kimi provider 也分两轮 POST，依赖 9.0d multi-request MockServer。

- [x] 9.19 Kimi error — HTTP 400
  - **被测行为**: spec `search-provider/spec.md` "Kimi HTTP 429 retry" — HTTP 400 不重试，直接返回错误
  - **前置**: MockServer 返回 HTTP 400
  - **步骤**: `KimiSearch::search("test", "basic", 1)`
  - **断言**: `results.empty()`, `error.message` 非空
  - **基础设施**: MockServer 单请求（单轮 POST 直接失败）

- [x] 9.18 Kimi 429 retry
  - **被测行为**: spec `search-provider/spec.md` "Kimi HTTP 429 retry (Kimi-only)"
  - **前置**: 9.0d multi-request MockServer + `queue_response(429, "rate limited")` 两次 → `queue_response(200, "...SSE with answer...")`
  - **步骤**: `search("test", "basic", 1)`
  - **断言**: 最终返回 `ok` 结果（第三次请求成功），重试了 2 次
  - **验证方法**: 检查 MockServer 的请求计数（需在 MockServer 加 `request_count()`）
  - **基础设施**: 9.0d multi-request + response queue

- [x] 9.19c Kimi request body verification
  - **被测行为**: spec `search-provider/spec.md` — thinking disabled + tool_choice + model
  - **策略**: 直接测试 `build_openai_request` 输出，不通过 provider
  - **步骤**: 调用 `build_openai_request("moonshot-v1-auto", messages, tools, tc_json, R"({"thinking":{"type":"disabled"}})")`
  - **断言**: 返回 JSON 中 `model == "moonshot-v1-auto"`, `tool_choice.type == "builtin_function"`, `tool_choice.builtin_function.name == "$web_search"`, `thinking.type == "disabled"`
  - **基础设施**: 无需 MockServer

- [x] 9.19d Kimi arguments delta accumulation
  - **被测行为**: 同 9.12b，但针对 `$web_search` 的 arguments
  - **策略**: 直接测 `openai_write_callback` → `ctx.state.accumulated_args`，喂 3 个 `function.arguments` 片段
  - **断言**: 拼接后为完整 JSON `{"q":"test query"}`
  - **基础设施**: 无需 MockServer（transport 层测试）

- [x] 9.19e Kimi tool_call_id capture
  - **被测行为**: spec `search-provider/spec.md` "SSE tool_call delta handling"
  - **策略**: 喂 SSE delta 含 `tool_calls[0].id = "call_kimi_123"`，验证 `ctx.state.tool_call_ids[0]` 被正确捕获
  - **断言**: `ctx.state.tool_call_ids[0] == "call_kimi_123"`
  - **基础设施**: 无需 MockServer（transport 层测试）

- [x] 9.17 Kimi success: 依赖 9.0d multi-request MockServer（实现 9.0d 后，两轮 POST: tool_call → tool_result → text answer）
- [x] 9.19a Kimi missing arguments: 单请求 MockServer 即可（`search()` 在 arguments 缺失时直接返回错误，不发 HTTP 请求）
  - **被测行为**: spec `search-provider/spec.md` "Kimi search provider" — arguments 缺失/null 时返回 ProviderResult error
  - **前置**: MockServer 单请求，返回 SSE 含 tool_call 但 `function.arguments` 为空字符串或 null
  - **步骤**: SSE `data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"$web_search"}}]}}]}\n`（无 arguments 字段）→ `data: [DONE]\n` → 调用 `KimiSearch::search("test", "basic", 1)`
  - **断言**: `results.empty()`, `error.message` 非空
  - **基础设施**: MockServer 单请求

- [x] 9.19b Kimi no tool_calls: 单请求 MockServer 即可（第一轮 SSE 无 tool_call 直接返回 error）
  - **被测行为**: spec `search-provider/spec.md` "Kimi search provider" — finish_reason="stop" 但无 tool_call → error
  - **前置**: MockServer 单请求，返回 SSE 只有 text content 没有 tool_calls
  - **步骤**: SSE `data: {"choices":[{"index":0,"delta":{"content":"I don't know"}}]}\n` → `data: {"choices":[{"index":0,"finish_reason":"stop"}]}\n` → `data: [DONE]\n` → 调用 `KimiSearch::search("test", "basic", 1)`
  - **断言**: `results.empty()`, `error.message` 非空，含 "did not invoke" 或类似
  - **基础设施**: MockServer 单请求

- [x] 9.17a Kimi result normalization — empty title/url
  - **被测行为**: spec `search-provider/spec.md` "SearchResult normalization" — Kimi 结果 title 和 url 可为空
  - **策略**: 由于 Kimi success 测试（9.17）依赖 9.0d，先通过代码审查 + 接口契约验证
  - **步骤**: (a) 检查 `kimi_search.cpp` 中 `search()` 的归一化代码——`SearchResult r; r.title = ""; r.url = ""; r.content = text_answer;`；(b) 创建 `KimiSearch` 实例，手动设置 api_key，调用 `search()`。MockServer 返回单轮 SSE（tool_call + finish_reason="stop"）
  - **断言**: `results[0].title.empty() && results[0].url.empty() && !results[0].content.empty()`
  - **说明**: 如果单轮 MockServer 能完成（取决于 Kimi 代码实际流程），此测试可以独立于 9.0d 运行

- [x] 9.18a Kimi 429 respects Retry-After header
  - **被测行为**: spec `web-search/spec.md` "Kimi retry after 429" — 尊重 Retry-After header
  - **前置**: 9.0d multi-request MockServer + response queue
  - **步骤**: (a) `queue_response(429, "text/event-stream", "rate limited", 附带 header `Retry-After: 3`)`；(b) `queue_response(200, "text/event-stream", "...SSE with answer...")`；(c) 记录两次请求之间的时间间隔；(d) 调用 `KimiSearch::search("test", "basic", 1)`
  - **断言**: (a) 第一次返回 429 后等待了约 3 秒（不是默认的 1 秒 backoff）；(b) 第二次请求成功；(c) `request_count() == 2`
  - **说明**: MockServer 需要支持在 `build_response()` 中添加额外的 response header。在 9.0d 中增加 `queue_response` 的 `extra_headers` 参数
  - **基础设施**: 9.0d + response queue 支持 extra headers

### Transport & Infrastructure

- [x] 9.31 SSE parse errors — below/above threshold
  - **被测行为**: spec `search-provider/spec.md` "SSE error accumulation" — <10 个 malformed lines 跳过继续，>10 个返回 error
  - **策略**: 直接测 `openai_write_callback` + `OpenAITransferCtx`
  - **步骤**: (a) 喂 2 条 malformed SSE 行：`data: {bad json{{{` + `data: {more bad}` → `ctx.state.parse_errors==2`，回调不返回 0；(b) 继续喂 15 条 malformed 行 → `ctx.state.parse_errors > 10` → `ctx.aborted == true`
  - **断言**: (a) 2 条错误不中止；(b) >10 条错误中止，`abort_reason` 含 "Excessive SSE parse errors"
  - **基础设施**: 无需 MockServer

- [x] 9.33 Independent curl handles
  - **被测行为**: spec `search-provider/spec.md` "Transport layer independence" — ZhipuAI 和 Kimi 各自创建 curl handle，不共享
  - **策略**: 代码审查 + 实例验证
  - **步骤**: (a) 检查 `zhipuai_search.cpp` 中每次 `search()` 调用是否通过 `create_openai_curl_handle()` 创建新的 CURL 句柄；(b) 检查 `kimi_search.cpp` 中同理；(c) 确认两个 provider 不引用 `g_gateway`（ModelGateway 单例）
  - **断言**: (a) 每个 `search()` 调用内部有 `curl_easy_init()` 或 `create_openai_curl_handle()`（含 curl_easy_init）；(b) 没有代码访问 `g_gateway`；(c) 两个 provider 的 curl handle 是不同的指针（可以注入检测代码：在 `create_openai_curl_handle` 中记录返回的指针地址，两次调用返回不同地址）
  - **基础设施**: 无需 MockServer（代码审查 + 注入检测）

- [x] 9.34 Web search/fetch worker isolate
  - **被测行为**: spec `web-search/spec.md` "Web search execution on worker isolate" + spec `web-fetch/spec.md` "Web fetch execution on worker isolate"
  - **策略**: 这是 Dart 侧的测试，不属于 Catch2 C++ 测试。但场景来自 C++ spec，所以在此列出并指向 Dart 测试
  - **步骤**: (a) 在 `sidecar_bridge.dart` 中检查 `webSearch()`/`webFetch()` 方法是否通过 `Isolate.spawn` 在 worker isolate 上执行 FFI 调用；(b) 在 Dart widget 测试中验证——调用 `webSearch()` 时 UI 帧率不受阻塞
  - **断言**: `webSearch()` 和 `webFetch()` 内部有 `Isolate.spawn` 调用，返回 `Future<String>`
  - **说明**: 此测试的实现放在 Phase 10/11 的 Dart 测试中。C++ 测试只验证代码结构

- [x] 9.32 SSE line_buf 64KB cap
  - **被测行为**: design D0 — 单行超过 64KB 中止传输
  - **步骤**: 构造一个 65KB 字符串（无换行符），通过 `openai_write_callback` 逐个字符喂入 `OpenAITransferCtx`
  - **断言**: 回调返回 0（中止），`ctx.aborted == true`，`ctx.abort_reason` 含 "64KB"
  - **基础设施**: 无需 MockServer（直接测 callback）

### Build

- [x] 9.20 CMakeLists.txt 包含 `search_provider_test.cpp`
  - **断言**: `sidecar_tests` 目标编译成功（所有测试文件编译链接无错误）

### Live Integration（需真实 API key 或本地服务，不在 CI 中运行）

- [x] 9.24 SearXNG test helper — `test_utils/searxng_harness.h`: `SearXNGHarness::is_available()` 检查 localhost:8888 是否可达（2s TCP 超时），`wait_ready(timeout)` 轮询等待。不再负责启动/停止 SearXNG 进程（太复杂，用户手动启动）
- [x] 9.25 API key loader — `test_utils/api_key_loader.h`: `ApiKeyLoader::get_zhipuai_key()` 和 `get_kimi_key()` 从 `%USERPROFILE%\.aliasagent\config.json` 读取。config 不存在或 key 缺失时返回空字符串
- [x] 9.21-9.23, 9.26-9.30: 全部标记 `[live]`，需要用户手动提供真实 API key 或启动本地 SearXNG 后运行。不纳入默认测试集

---

**当前阻塞清单**:
| 阻塞项 | 影响的任务 | 需要的修复 |
|--------|-----------|-----------|
| MockServer 不支持 multi-request + response queue | 9.10, 9.11, 9.12, 9.17, 9.18, 9.18a | 9.0d — 增加 `queue_response()` + accept 循环 + extra_headers |
| web_fetch SSRF 拦截 localhost | 9.5a, 9.5b, 9.6, 9.6a, 9.7b, 9.8, 9.8a | 纯函数测试或暴露内部函数给测试 |
| dispatcher 无 mock 注入机制 | 9.2a, 9.2b, 9.2c, 9.4d | 9.0e — `set_test_providers()` + `g_test_providers` |
| 需要真实 API key | 9.21-9.30 | 标记 [live]，用户选择性运行 |

**覆盖完整性检查** — 对照三个 spec 的所有 scenario：

| Spec | Scenario | 对应任务 |
|------|----------|---------|
| web-search | Main model selects single provider | 9.2c（多 provider 选择） |
| web-search | Main model selects multiple providers with deep depth | 9.2c |
| web-search | Tool description reflects configured providers | 9.3 |
| web-search | All providers succeed | 9.2a（一个成功一个失败场景 + 断言 `ok==true`） |
| web-search | One provider fails, others succeed | 9.2a |
| web-search | Provider returns empty results (no matches) | 9.14（SearXNG empty results） |
| web-search | All providers fail | 9.4b |
| web-search | Hung provider times out | 9.2b |
| web-search | Deep search round-trip timeout | 9.10（依赖 9.0d） |
| web-search | Web search does not block UI | 9.34（Dart 侧） |
| web-search | Normalized results serialized for tool result | 9.13（SearXNG 结果映射验证了归一化） |
| web-search | ZhipuAI basic search | 9.9 |
| web-search | ZhipuAI deep search with partial mclick failure | 9.11（依赖 9.0d） |
| web-search | SearXNG and Kimi ignore depth | 9.4e |
| web-search | Kimi retry after 429 | 9.18（依赖 9.0d）+ 9.18a |
| web-search | Permanent errors not retried | 9.4d |
| web-fetch | Main model invokes web_fetch | 9.5a（e2e 受限于 SSRF） |
| web-fetch | Default extract mode | 9.7c |
| web-fetch | HTTPS URL allowed | 9.7（公网 IP 测试） |
| web-fetch | file:// scheme blocked | 9.7 |
| web-fetch | Localhost hostname blocked | 9.7 |
| web-fetch | IPv4 loopback blocked at socket level | 9.7 |
| web-fetch | IPv6 loopback blocked at socket level | 9.7 |
| web-fetch | IPv4-mapped IPv6 blocked | 9.7 |
| web-fetch | IPv6 link-local blocked | 9.7 |
| web-fetch | Private IPv4 blocked at socket level | 9.7 |
| web-fetch | Cloud metadata endpoint blocked | 9.7 |
| web-fetch | CURLOPT_PROTOCOLS enforced | 9.6b |
| web-fetch | Case-insensitive scheme validation | 9.7 |
| web-fetch | DNS rebinding mitigated by socket callback | 9.7 |
| web-fetch | HTTP redirect target re-validated | 9.7 |
| web-fetch | Redirect protocol switch blocked | 9.7 |
| web-fetch | IPv4 blocklist completeness | 9.7 |
| web-fetch | IPv6 blocklist completeness | 9.7 |
| web-fetch | NAT64 encoded IPv4 blocked | 9.7 |
| web-fetch | Normal content under limit | 9.5c |
| web-fetch | Oversized content aborted early | 9.7a |
| web-fetch | Redirect followed with re-validation | 9.7 |
| web-fetch | Redirect to internal IP blocked | 9.7 |
| web-fetch | HTML page extracted to text | 9.5 |
| web-fetch | HTML with charset suffix extracted to text | 9.5a |
| web-fetch | JSON response returned raw | 9.6 |
| web-fetch | Plain text returned as-is | 9.6a |
| web-fetch | Missing Content-Type defaults to raw | 9.5b |
| web-fetch | Connection timeout | 9.7b |
| web-fetch | HTTP error response | 9.8 |
| web-fetch | Web fetch does not block UI | 9.34（Dart 侧） |
| search-provider | Provider identity | 9.3（含 name() 验证） |
| search-provider | Provider description for AI | 9.3 |
| search-provider | Provider configuration check | 9.3 |
| search-provider | SearXNG is_configured returns cached result | 9.3 |
| search-provider | SearchResult normalization | 9.1, 9.17a |
| search-provider | Empty results vs error distinguishable | 9.1 |
| search-provider | ZhipuAI basic search | 9.9 |
| search-provider | ZhipuAI deep search with partial mclick failure | 9.11（依赖 9.0d） |
| search-provider | ZhipuAI loop-level timeout | 9.10（依赖 9.0d） |
| search-provider | SearXNG search with client-side truncation | 9.13 |
| search-provider | SearXNG format=json not enabled server-side | 9.16 |
| search-provider | SearXNG unavailable during search | 9.15 |
| search-provider | Kimi search with thinking disabled | 9.19c |
| search-provider | Kimi HTTP 429 retry (Kimi-only) | 9.18（依赖 9.0d）+ 9.18a |
| search-provider | Transport layer independence | 9.33 |
| search-provider | SSE tool_call delta handling | 9.12b, 9.19d, 9.19e |
| search-provider | ZhipuAI and Kimi use independent curl handles | 9.33 |
| search-provider | ModelGateway not reused for search | 9.33 |
| search-provider | SSE parse errors below threshold | 9.31 |
| search-provider | SSE parse errors exceed threshold | 9.31 |
| search-provider | Input validation — empty query rejected | 9.4a |
| search-provider | Input validation — max_results clamped | 9.4a |
| search-provider | Registered providers listed | 9.3 |
| search-provider | Per-provider API key check | 9.3 |

## 10. Dart Widget Tests (Tier 2 — Tool Dispatch + FakeSidecar)

- [x] 10.1 Add `web_search` / `web_fetch` / `get_search_providers` / `ensure_search_infra` to `ISidecar` abstract interface
- [x] 10.2 Update `FakeSidecar` with new methods returning configurable preset data
- [x] 10.3 Tool definition: FakeSidecar returns providers → verify description includes names + `depth` in input_schema
- [x] 10.4 Tool definition with multiple providers: verify all in enum
- [x] 10.5 Conditional registration — no providers: FakeSidecar returns empty → tools absent
- [x] 10.6 `_executeTool` dispatch — web_search: verify isolate spawn + correct JSON
- [x] 10.7 `_executeTool` dispatch — web_fetch: verify isolate spawn + correct URL
- [x] 10.8 `_executeTool` error propagation: Sidecar returns error → verify passed to model

⛔ **STOP HERE** — Phase 9-10 完成后停止，等用户确认 "execute phase 11"

## 11. Dart Integration Tests (Tier 3 — End-to-End + UI)

- [x] 11.1 web_search end-to-end: FakeSidecar returns namespaced results → verify ToolCallCard renders provider summary
- [x] 11.2 Multi-provider display: verify namespaces visible in result card
- [x] 11.3 Provider error display: verify error shown per namespace
- [x] 11.4 web_fetch end-to-end: FakeSidecar returns fetched text → verify ToolCallCard renders extracted content; verify error display for fetch failures (timeout, HTTP 4xx/5xx, SSRF block); verify web_fetch result card distinguishable from web_search result card

### SearXNG Live Integration (Tier 3 — real Sidecar + real SearXNG)
- [x] 11.5 SearXNG live end-to-end: start SearXNG → start app with real Sidecar → trigger `web_search` with provider `searxng` → verify ToolCallCard renders real search result titles; skip if `tools/searxng/` not set up

## 12. Documentation

- [x] 12.1 Document provider config (per-provider snake_case keys: `search.zhipuai.api_key`, `search.kimi.api_key`; SearXNG Python dev mode deployment via `scripts/setup_searxng.bat`) in DEBUGGING.md
- [x] 12.2 Document API key security: plaintext in config.json; crash dumps use MiniDumpNormal (no heap); log body at DEBUG not INFO; config key naming uses snake_case (`api_key`) consistent with existing `ProviderConfig.api_key`
- [x] 12.3 Add search tool usage examples to DEBUGGING.md
