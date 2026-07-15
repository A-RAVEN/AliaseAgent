# Sidecar C++ Tests

C++ unit tests for the Sidecar DLL, covering SSE parsing, tool execution, and HTTP request construction.

## Prerequisites

- CMake 3.20+
- C++17 compiler
- libcurl (with development headers)
- Internet connection (first build only, for Catch2 FetchContent download)

## Build

```bash
# From the repository root:
cmake -B build/windows -S sidecar
cmake --build build/windows --target sidecar_tests
```

Or if sidecar.dll is also needed:

```bash
cmake -B build/windows -S sidecar
cmake --build build/windows
```

## Run Tests

```bash
# Run all tests
ctest --test-dir build/windows

# Run a specific test suite
ctest --test-dir build/windows -R sse_parser
ctest --test-dir build/windows -R tool_execution
ctest --test-dir build/windows -R http_client

# Run with Catch2 verbose output
./build/windows/sidecar_tests -v
```

## Test Structure

| File | Description |
|------|-------------|
| `test_main.cpp` | Custom Catch2 runner with CURL + Winsock init |
| `mock_server.h` | Embedded TCP mock server (replays SSE fixtures) |
| `temp_dir.h` | RAII temp directory + WorkspaceGuard |
| `sse_parser_test.cpp` | SSE event stream parsing (17+ tests) |
| `tool_execution_test.cpp` | Tool execution: read_file, list_dir, set_workspace (20+ tests) |
| `http_client_test.cpp` | HTTP request construction verification (8+ tests) |
| `fixtures/sse/` | 22 recorded SSE fixture files |

## Architecture

Tests link `model_gateway.cpp` + `tools.cpp` + `logger.cpp` directly (NOT `sidecar_api.cpp` to avoid `__declspec(dllimport)` conflicts). SSE and HTTP tests use an embedded TCP mock server on a separate thread that replays fixture files as complete HTTP SSE responses.
