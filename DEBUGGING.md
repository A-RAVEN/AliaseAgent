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

## Running Live Tests

窗口版 live 套件（`integration_test/live_file_tools_test.dart`）在**真实桌面窗口**（`-d windows`）运行完整应用，真实模型 + 真实 sidecar + 真实 ripgrep 端到端，**能看到真实 AI 在窗口里回答**——项目 live 测试规范形态（仿 `integration_test/real_api_test.dart`，design D1）。隔离由 `@Tags(['live'])` + `dart_test.yaml`（`tags.live.skip`）控制，该隔离对 `flutter test integration_test/... -d windows` **已实测生效**（task 12.1 探针确认）：

- **默认 `flutter test` 排除 live**：live 测试显示为 skipped（带原因），不发真实网络请求。这是设计行为，不是失败。
- **显式运行窗口版 live 套件（规范命令）**：
  ```
  flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows
  ```
  `--tags live` 选择 live 测试，`--run-skipped` 解除 config 的 skip。只带 `--tags live`（缺 `--run-skipped`）不会运行被 skip 的测试。`-d windows` 在真实桌面窗口运行（应用会构建 ~3 分钟）。

**前置条件：**
1. `%USERPROFILE%\.aliasagent\config.json` 含 **api_key + base_url + model**（`providers.anthropic.api_key` / `providers.anthropic.base_url` / `agent_types.general.model`）。config 缺失/不可用 → 每用例 `markTestSkipped` 优雅跳过（不发请求）；API 调用失败（如 key 无效/配额）→ 首个用例捕获 `Error:` 回复后 `markTestSkipped`，后续用例跳过。base_url/model 无 fallback 默认值——项目端点为 DeepSeek Anthropic 兼容（`Docs/DeepSeekAPIDoc.md`），不要回退到 `api.anthropic.com` / `deepseek-chat`。
2. `tools/rg.exe`（Windows）已就位——`glob_file` / `grep_file` 依赖。
3. `thinking_effort` 影响指令遵循性（design finding 11）：`agent_types.general.thinking_effort` 缺失则 thinking disabled（`_callModel` 按 config 决定）。当前真实 config 为 `"max"`（adaptive 启用）。若缺失，复杂指令（Test 2 单次批量、Test 3 只改 countA）遵循性可能下降——套件仍如实记录实际工具调用与文件状态，不静默硬失败。

**成本提示：** live 套件 4 个用例各驱动真实模型多轮工具调用（每用例 5 分钟 timeout，pumpUntilFound 每阶段 150s），运行耗真实 API token。按需运行。

**套件内容（design D3）：** 窗口版 `integration_test/live_file_tools_test.dart`：Test 1 自然多工具（grep_file + edit_file 卡片均 done + 文件含 DONE）、Test 2 批量 edits 数组（断言 `ToolCallActivity.input['edits'].length>=2` + 行锚定文件断言）、Test 3 唯一匹配拒绝/自愈（countA/countB 区域 + comment-token 锚定断言，软记录是否出现过 error 卡片）、Test 4 glob_file 专项（卡片结果含 `src/a.dart` + `src/b.dart`）。每个用例 pump 完整应用后**重新 `setWorkspace`** 到独立 fixture temp（`AppShell.initState` 会把 workspace 重置到 homeDir，必须在 pump 后重设——design D2），模型只读写 fixture，绝不触碰真实用户文件。

**输出内容说明（change add-live-test-observability，共享 helper `integration_test/live_observability.dart`）：** 每个窗口版 live 用例（`live_file_tools_test.dart` / `real_api_test.dart`）在**断言前**与**所有失败路径**（等待超时 / 错误状态检测）输出 `[OBS]` 前缀的可观测 dump，运行者应看到：

- **工具调用 dump**（`dumpToolCards`）：`[OBS] <phase> — tool=<toolName> status=<status> id=<id>` + **完整 input**（缩进 JSON）+ **result 预览**（前 500 字符；结构化结果如 web_fetch 按 section 汇总）——经 UI `ToolCallCard` 读取（窗口版观察通道），滚动扫描聊天列表（ListView.builder 回收，按 `ToolCallActivity.id` 去重 + 拖拽上限 12 次）。
- **文件状态 dump**（`dumpFile`）：`[OBS] <label> — file: <path>` + 文件**最终内容**——涉及 edit_file / write_file 的用例在断言前输出（如 `live_file_tools_test` Test 1/2/3 的 fixture 文件、`real_api_test` 3.3 的测试文件）。
- **无工具调用**（`dumpNoTool`）：`[OBS] <phase> — 无工具调用（扫描确认聊天列表内无 ToolCallCard）`——无工具用例（`real_api_test` 3.1 基础对话 / 3.4 扩展思考）**先滚动扫描确认无卡片**再如实报告；若模型偏离实际发出工具调用则 dump 真实卡片，不谎报。
- **失败路径同样有现场**：每个 `on TimeoutException` 分支在 `fail(...)` / `markTestSkipped(...)` **之前** dump；`_waitForTurnComplete` 裸超时（"对话永不完成"）4 个调用点包 `try/on TimeoutException`，rethrow 前 dump 工具卡片 + 涉及文件。
- dump 为**纯 `debugPrint` 增量**：不参与断言、不改任何 `expect` / `fail` / `markTestSkipped` 行为、不弱化既有断言。

**headless 套件**（`test/integration/live_file_tools_test.dart`，flutter_tester 无窗口）：初版返工遗留，**形态不符合 live 规范**（无窗口、看不到 AI 回答）。已按用户确认**删除**（change add-file-tools-live-tests task 12.6）；其打磨的 fixture / 指令文本已继承到窗口版套件。
