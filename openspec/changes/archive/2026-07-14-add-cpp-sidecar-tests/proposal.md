## Why

The C++ Sidecar DLL handles all API communication (HTTP, SSE parsing, JSON assembly, tool execution) — the most critical and complex part of the system. Currently zero automated tests exist for the C++ side. The `ffi-bridge`, `model-gateway`, and `basic-tools` specs (40+ scenarios) have no verification beyond manual testing and the smoke test's "app launched and didn't crash" check. A C++ test harness with recorded/replayed SSE fixtures would catch regressions in the parsing and protocol layers.

## What Changes

- **Test infrastructure**: Embedded TCP mock server that replays SSE fixture files, allowing `ModelGateway::execute()` to be tested end-to-end without touching production code
- Add a C++ test project using Catch2 v3 (CMake FetchContent, same pattern as nlohmann/json) under `sidecar/test/`
- Create SSE fixture files (recorded from real API responses) covering: text delta, tool_use with fragmented input_json_delta (including content_block_start), thinking block, message_stop, error event, [DONE] marker, multi-block integration
- Test SSE parser: `content_block_delta` (text, empty text, missing delta), `content_block_start/stop` (tool_use + thinking + unknown types), `message_delta` → `message_stop` with stop_reason, `error` event, `[DONE]` marker, `message_start`, `ping`, unrecognized event type, JSON parse error in data line
- Test tool execution: `read_file` (valid, not found, outside workspace, binary, path-is-directory, cannot-open, cannot-resolve, no-workspace), `list_dir` (valid, empty dir, not found, not-a-directory, outside workspace, cannot-read, cannot-resolve, no-workspace), `set_workspace` (all 4 return paths)
- Test HTTP request construction: headers, body fields (including optional system/tools omission, max_tokens), default base_url, input validation (empty api_key, invalid messages_json, invalid tools_json) — verified by mock server inspecting incoming requests
- Add a CMake test target and document how to run: `cmake --build build/windows && ctest`

## Capabilities

### New Capabilities
- `sse-parser-tests`: C++ unit tests for SSE event stream parsing covering all event types, fragmentation, multi-block integration, and error handling
- `tool-execution-tests`: C++ unit tests for `read_file`, `list_dir`, and `set_workspace` covering all success and error paths
- `http-client-tests`: C++ unit tests for HTTP request construction (headers, body, input validation) — connection-layer testing (timeout, live HTTP) excluded per non-goal

### Removed Capabilities
- ~~`json-assembly-tests`~~ — Removed. The C++ side receives pre-built `messages_json` from Dart and does not construct content block arrays. The SSE parser's tool_use/thinking JSON assembly is already covered by `sse-parser-tests`.

### Modified Capabilities
<!-- None — pure test addition with prerequisite refactoring -->

## Impact

- `sidecar/test/` — new directory: custom `test_main.cpp`, `mock_server.h`, `temp_dir.h`, SSE fixtures, test source files
- `sidecar/CMakeLists.txt` — add test target: `enable_testing()`, `add_executable(sidecar_tests)`, `add_test()`, Catch2 FetchContent
- `sidecar/src/tools.h` — fix `list_dir` return format documentation (`entries` → `content`)
- `sidecar/include/sidecar_api.h` — fix `list_dir` return format documentation
- **No production code behavior changes** — `model_gateway.cpp` + `tools.cpp` 不变，测试通过独立线程 mock server 进行
- **Test binary links** `model_gateway.cpp` + `tools.cpp` + `logger.cpp`（不链接 `sidecar_api.cpp`，避免 `__declspec(dllimport)` 冲突）
- No Dart-side changes
- Adds Catch2 v3 as a C++ test dependency (CMake FetchContent, no runtime dep)
