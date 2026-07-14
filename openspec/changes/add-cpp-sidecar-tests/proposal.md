## Why

The C++ Sidecar DLL handles all API communication (HTTP, SSE parsing, JSON assembly, tool execution) — the most critical and complex part of the system. Currently zero automated tests exist for the C++ side. The `ffi-bridge`, `model-gateway`, and `basic-tools` specs (40+ scenarios) have no verification beyond manual testing and the smoke test's "app launched and didn't crash" check. A C++ test harness with recorded/replayed SSE fixtures would catch regressions in the parsing and protocol layers.

## What Changes

- Add a C++ test project using a lightweight framework (Catch2 or doctest) under `sidecar/test/`
- Create SSE fixture files (recorded from real API responses) covering: text delta, tool_use with fragmented input_json_delta, thinking block, message_stop, error event, HTTP 401
- Test SSE parser: `content_block_delta` (text), `content_block_start/stop` (tool_use + thinking), `message_stop` with stop_reason, `error` event, unrecognized event type
- Test tool execution: read_file (valid, not found, outside workspace, binary), list_dir (valid, not found, not-a-directory, outside workspace)
- Test JSON assembly: input_json_delta accumulation across fragments, content block array format for messages
- Test HTTP client: timeout, non-200 response handling
- Add a CMake test target and document how to run: `cmake --build build && ctest`

## Capabilities

### New Capabilities
- `sse-parser-tests`: C++ unit tests for SSE event stream parsing covering all event types, fragmentation, and error handling
- `tool-execution-tests`: C++ unit tests for read_file and list_dir tool implementations covering success and error paths
- `http-client-tests`: C++ unit tests for HTTP request construction, timeout handling, and error response processing
- `json-assembly-tests`: C++ unit tests for input_json_delta accumulation and content block array format construction

### Modified Capabilities
<!-- None — pure test addition -->

## Impact

- `sidecar/test/` — new directory with C++ test sources
- `sidecar/test/fixtures/` — recorded SSE response fixtures (JSON files)
- `sidecar/CMakeLists.txt` — add test target
- No Dart-side changes
- Adds Catch2 or doctest as a C++ test dependency (header-only, no runtime dep)
