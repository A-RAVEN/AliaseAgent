# Debugging Guide — AliasAgent C++ Sidecar

## Log Levels

The sidecar logger supports four log levels, controlled by the `ALIASAGENT_LOG_LEVEL` environment variable:

| Level | Value | Description |
|-------|-------|-------------|
| `TRACE` | 0 | All function entries, FFI callbacks, SSE dispatch details |
| `INFO`  | 1 | Request lifecycle, file operations, HTTP status (default) |
| `WARN`  | 2 | Access denials, unusual events |
| `ERROR` | 3 | API errors, connection failures, JSON parse failures |

**Usage:**
```bash
# Windows (CMD)
set ALIASAGENT_LOG_LEVEL=trace
flutter run -d windows

# Windows (PowerShell)
$env:ALIASAGENT_LOG_LEVEL = "trace"
flutter run -d windows

# Linux/macOS
ALIASAGENT_LOG_LEVEL=trace flutter run -d linux
```

Log files are written to:
- **Windows**: `%USERPROFILE%\.aliasagent\logs\sidecar.log`
- **Linux/macOS**: `~/.aliasagent/logs/sidecar.log`

Disabled TRACE messages incur zero string allocation overhead (level check before argument evaluation).

## Log Rotation

At startup, if `sidecar.log` exceeds 10 MB:
- `sidecar.log` → `sidecar.1.log`
- `sidecar.1.log` → `sidecar.2.log`
- `sidecar.3.log` is deleted

Maximum 3 historical log files retained.

## Crash Diagnosis

### Windows: Minidump

On an unhandled exception (access violation, C++ terminate), the sidecar writes:

1. **Minidump**: `%USERPROFILE%\.aliasagent\crashes\sidecar_crash_YYYYMMDD_HHMMSS.dmp`
   - `MiniDumpNormal` dump type: call stacks + registers + loaded modules (~1-5 MB)
   - **No heap memory** — API key is NOT in the dump
2. **Crash log**: `%USERPROFILE%\.aliasagent\crashes\crash.log`
   - Exception code, address, thread ID
   - Last N FFI callbacks (ring buffer dump)
3. **Lifecycle**: Maximum 10 `.dmp` files retained; oldest deleted on new crash

**Analyzing a minidump with WinDbg:**

1. Open WinDbg → File → Open Crash Dump → select `.dmp`
2. Load symbols:
   ```
   .sympath+ <path-to-your-project>\sidecar\build\windows\Debug
   .reload /f
   ```
3. View call stack: `k`
4. Set symbol path to include PDB directory:
   - `sidecar.pdb` — for `sidecar.dll` (located in `sidecar\build\windows\Debug\`)
   - `sidecar_tests.pdb` — for test binary

**PDB files** are generated automatically by MSVC for Debug builds at:
- `sidecar\build\windows\Debug\sidecar.pdb`
- `sidecar\build\windows\Debug\sidecar_tests.pdb`

### Linux/macOS: Stack Trace

On `SIGSEGV` or `SIGABRT`, the signal handler writes:
- Crash timestamp and signal info to `~/.aliasagent/crashes/crash.log`
- Symbolicated backtrace to `~/.aliasagent/crashes/crash_backtrace_YYYYMMDD_HHMMSS.log`

The backtrace uses `backtrace()` + `backtrace_symbols()` for function name resolution.
For best results with C++ symbols, pipe through `c++filt`:
```bash
c++filt < ~/.aliasagent/crashes/crash_backtrace_*.log
```

## API Error Logging

When the model API returns HTTP ≥ 400, the sidecar logs:
- HTTP status code
- First 2048 bytes of the raw response body

The raw body is captured in a 64 KB buffer during SSE streaming. This is essential for diagnosing API errors (e.g., invalid model name, DeepSeek 400 errors) without external tools like curl.

Example log output:
```
2026-07-15 12:34:56.789 [ERROR] API returned HTTP 400
2026-07-15 12:34:56.789 [ERROR] API error body: {"error":{"message":"Invalid model: claude-sonnet-4-6"}}
```

## FFI Tracing

Set `ALIASAGENT_LOG_LEVEL=trace` to enable FFI boundary tracing:

**C→Dart callbacks**: every callback invocation is recorded in the crash-handler
ring buffer (dumped on crash); the log only emits a TRACE line for `on_done`:
```
2026-07-15 12:34:56.789 [TRACE] FFI: on_done(code=0)
```

**SSE wire diagnostics** (per-event, also TRACE): text/thinking deltas,
content_block events, message_stop, request body — all off by default.

**Dart→C entry points** (sensitive data redacted):
```
2026-07-15 12:34:56.000 [TRACE] send_message: model=claude-sonnet-4-6 api_key=<REDACTED>
2026-07-15 12:34:57.000 [TRACE] read_file: path=/workspace/src/main.cpp
```

**Ring buffer**: Last 256 C→Dart callbacks are stored in a lock-free ring buffer. On crash, the buffer is dumped to the crash log before writing the minidump.

## Enabling ASan

AddressSanitizer (memory error detector) is available for `sidecar_tests`:

```bash
# CMD
scripts\rebuild_sidecar.bat Debug --asan

# PowerShell
.\scripts\rebuild_sidecar.ps1 -BuildType Debug -Asan
```

**Important:** ASan is applied ONLY to `sidecar_tests` (standalone executable), NOT to `sidecar.dll`. The Flutter Dart VM reserves memory ranges that conflict with ASan's shadow memory (Google sanitizers issue #386).

The ASan build:
1. Configures a separate build directory (`sidecar/build/asan/`)
2. Compiles `sidecar_tests` with `/fsanitize=address`
3. Runs the full test suite, checking for memory errors and leaks
4. Uses static ASan runtime (no external DLL dependency)

**vcpkg requirements:** A custom triplet `x64-windows-asan-static` is provided at `sidecar/vcpkg/triplets/`. Install dependencies with:
```bash
vcpkg install --triplet x64-windows-asan-static
```

## Search Provider Configuration

### Config Keys (snake_case, per-provider)

Search providers are configured in `%USERPROFILE%\.aliasagent\config.json` (Windows) or `~/.aliasagent/config.json` (Linux/macOS) under the `search` key:

```json
{
  "search": {
    "zhipuai": {
      "api_key": "your-zhipuai-api-key",
      "model": "glm-4-flash"
    },
    "kimi": {
      "api_key": "sk-your-kimi-api-key",
      "model": "moonshot-v1-auto"
    },
    "searxng": {
      "base_url": "http://localhost:8888"
    }
  }
}
```

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `search.zhipuai.api_key` | Yes (for ZhipuAI) | — | ZhipuAI API key. If not set, ZhipuAI provider is disabled. |
| `search.zhipuai.model` | No | `glm-4-flash` | ZhipuAI model for web search |
| `search.kimi.api_key` | Yes (for Kimi) | — | Kimi API key. If not set, Kimi provider is disabled. |
| `search.kimi.model` | No | `moonshot-v1-auto` | Kimi model for web search |
| `search.searxng.base_url` | No | `http://localhost:8888` | Local SearXNG instance URL. No API key needed. |

**Naming convention**: All config keys use `snake_case` (`api_key`, `base_url`), consistent with the existing `ProviderConfig.api_key` field.

### SearXNG Deployment

SearXNG runs locally as a Python dev-mode service. Use the setup script:

**Windows:**
```bat
scripts\setup_searxng.bat
```

**Linux/macOS:**
```bash
bash scripts/setup_searxng.sh
```

The script will:
1. Clone SearXNG to `tools/searxng/` (depth=1)
2. Create a Python virtual environment
3. Install dependencies
4. Generate `settings.yml` with JSON format enabled and Bing engine configured

**Start SearXNG:**
```bash
cd tools/searxng
source venv/bin/activate   # or: venv\Scripts\activate
python -m searx.webapp
```

Access at `http://localhost:8888`. Test the JSON API:
```
http://localhost:8888/search?q=test&format=json
```

**Stop**: Ctrl+C. **Update**: `cd tools/searxng && git pull`.

### API Key Security

- API keys are stored as **plaintext** in `config.json` (same protection level as the main model API key)
- Crash dumps use `MiniDumpNormal` — **no heap memory** is included, so API keys are NOT in minidump files
- HTTP request bodies and per-event SSE diagnostics are logged at `TRACE` level (the logger has TRACE/INFO/WARN/ERR — no DEBUG level), so they are off by default. Set `ALIASAGENT_LOG_LEVEL=trace` to enable them
- Auth headers (`Authorization: Bearer`, `x-api-key`) are **never logged**
- Config key naming uses `snake_case` (`api_key`), consistent with the existing `ProviderConfig.api_key`

## Search Tool Usage Examples

### web_search

The model can invoke `web_search` to search across configured providers:

```
User: What's the latest news about Flutter 4.0?
→ Model calls web_search(query="Flutter 4.0 latest news", providers=[], depth="basic")
→ Sidecar queries all configured providers in parallel
→ Results returned per-namespace: {zhipuai: [...], searxng: [...], kimi: "..."}
```

**Troubleshooting web_search:**

1. **"No search providers configured"** — Check that at least one provider has a valid API key in `config.json`
2. **Provider timeout** — The dispatcher waits 30s (basic) or 90s (deep). Check network connectivity.
3. **ZhipuAI "did not invoke search tool"** — This indicates the model returned a text response without calling the search tool. Try rephrasing the query.

### web_fetch

The model can fetch web pages to get full article text:

```
→ Model calls web_fetch(url="https://example.com/article", extract_mode="text")
→ Sidecar fetches with SSRF protection, strips HTML tags
→ Returns extracted text (capped at 100KB)
```

**Troubleshooting web_fetch:**

1. **"Fetch failed: URL scheme not allowed"** — Only `http://` and `https://` schemes are allowed
2. **"Fetch failed: internal address not allowed"** — The URL resolved to a private/internal IP (SSRF protection)
3. **"Fetch failed: timeout"** — The target site didn't respond within 15 seconds
4. **"Fetch failed: HTTP 403/404/500"** — The target server returned an error

### glob_file / grep_file (ripgrep-backed file search)

The model can discover files (`glob_file`) and search file contents (`grep_file`) within the workspace. Both run `rg` as a subprocess with a 30s timeout.

```
→ Model calls glob_file(pattern="lib/**/*.dart", max_results=200)
→ Sidecar runs rg --files --no-require-git -g "lib/**/*.dart" <workspace>
→ Returns workspace-relative paths

→ Model calls grep_file(pattern="request_mutex", glob="sidecar/src/*.cpp", ignore_case=false)
→ Sidecar runs rg --json -n --no-require-git --glob ... -- <pattern> <workspace>
→ Returns path:line:text matches
```

**Troubleshooting glob_file / grep_file:**

1. **"rg not found — install ripgrep or place rg.exe in tools/"** — The rg binary is missing. Windows: place `rg.exe` in `tools/` (or `../share/aliasagent/tools/`) relative to the DLL. Linux/macOS: install via package manager (`apt/dnf/brew install ripgrep`).
2. **"glob_file timed out after 30 seconds"** — The search exceeded the 30s subprocess timeout (large workspace or pathological regex).
3. **"invalid regex: ..."** — The pattern is not a valid regex for rg's engine (rg exit code 2 with a regex parse error).
4. **"search failed: ..."** — rg exit code 2 from a soft error (e.g., unreadable file); stderr is included.

### Log Examples

Set `ALIASAGENT_LOG_LEVEL=trace` to see search-related logs:

```
2026-07-18 12:34:56.000 [TRACE] ensure_search_infra called
2026-07-18 12:34:56.100 [INFO] SearXNG liveness check: reachable
2026-07-18 12:34:56.200 [TRACE] get_search_providers called
2026-07-18 12:34:57.000 [TRACE] web_search called
2026-07-18 12:34:57.001 [INFO] web_search: query="test" depth=basic max_results=5 providers=2 deadline=30s
2026-07-18 12:34:57.500 [INFO] SearXNG: GET http://localhost:8888/search?q=test&format=json
2026-07-18 12:34:57.800 [INFO] ZhipuAI search: query="test" depth=basic max_results=5
2026-07-18 12:34:58.200 [INFO] SearXNG: 3 results (from 10 total)
2026-07-18 12:34:59.000 [INFO] ZhipuAI search: 5 results
2026-07-18 12:35:00.000 [TRACE] web_fetch called
2026-07-18 12:35:00.001 [INFO] web_fetch: url=https://example.com/article
2026-07-18 12:35:02.000 [INFO] web_fetch: Content-Type=text/html; charset=utf-8 — stripping HTML tags
```
