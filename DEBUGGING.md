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

**C→Dart callbacks** (each invocation logged):
```
2026-07-15 12:34:56.123 [TRACE] FFI: on_chunk(len=42)
2026-07-15 12:34:56.456 [TRACE] FFI: on_tool_call(len=512)
2026-07-15 12:34:56.789 [TRACE] FFI: on_done(code=0)
```

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
