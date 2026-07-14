## Context

The C++ Sidecar DLL (`sidecar.dll`) is the most complex component — it handles HTTP/SSE communication with the Anthropic API, JSON parsing/assembly, and tool execution with filesystem access. The `ffi-bridge`, `model-gateway`, and `basic-tools` specs define 40+ behavioral scenarios. Currently zero automated C++ tests exist. A C++ test harness with recorded SSE fixtures provides the fastest path to coverage without requiring a live API key.

## Goals / Non-Goals

**Goals:**
- Set up a C++ test project under `sidecar/test/` with a header-only test framework
- Create SSE fixture files from recorded real API responses covering all event types
- Test SSE parser: text delta, tool_use (single + fragmented), thinking block, message_stop, error event
- Test tool execution: read_file and list_dir with in-memory/temp filesystem
- Test content block array assembly for multi-turn tool use
- Add a CMake test target (`ctest`) and document the test workflow

**Non-Goals:**
- Not testing live API calls (requires network + API key)
- Not testing FFI boundary (Dart↔C++ interop)
- Not testing HTTP connection layer (fixture-based, not live network)
- Not achieving 100% line coverage (focus on behavior, not metrics)

## Decisions

### D1: Test framework — Catch2 (header-only)

**选择**: Catch2 v3 (single header). No build system dependency beyond `#include`. Alternatives: doctest (also header-only, lighter but less community), GoogleTest (requires CMake fetch/build, heavier setup).

### D2: SSE fixture format

Record real API responses as text files with raw SSE data lines:

```
test/fixtures/sse/
├── text_delta.txt           # single content_block_delta with text
├── text_multiple.txt        # multiple sequential text deltas
├── tool_use_single.txt      # single input_json_delta + content_block_stop
├── tool_use_fragmented.txt  # fragmented input_json_delta ×3 + stop
├── thinking_block.txt       # thinking + signature deltas + stop
├── message_stop_end_turn.txt
├── message_stop_tool_use.txt
├── error_event.txt          # {"type":"error","error":{"message":"..."}}
├── http_401.txt             # Non-200 HTTP response
└── unrecognized_event.txt   # Unknown event type
```

**选择**: Raw text files (exact bytes from API). Tests feed these into the SSE parser and assert callback invocations.

### D3: Test SSE parser via callback capture

The SSE parser likely works through C callbacks (`on_chunk`, `on_tool_call`, etc.). Tests register capturing lambdas:

```cpp
std::vector<std::string> chunks;
auto on_chunk = [&](const char* text) { chunks.push_back(text); };
sse_parser.parse(fixture_data, on_chunk, on_tool_call, on_thinking, on_done);
REQUIRE(chunks == expected_chunks);
```

**选择**: Callback capture pattern. No mocking framework needed — just std::vector + assertions.

### D4: Tool execution tests use temp filesystem

`read_file` and `list_dir` operate on the workspace directory. Tests create temp directories, populate with known files, and assert results:

```cpp
TempDir tmp;
tmp.write("hello.txt", "hello world");
REQUIRE(read_file(tmp.path() + "/hello.txt") == R"({"ok":true,"content":"hello world"})");
```

**选择**: Temp directory fixture. No mocking of filesystem — real `fopen`/`readdir` calls on controlled input.

## Risks / Trade-offs

- [R] SSE parser API not yet exposed for unit testing (may need header refactoring) → Mitigation: extract SSE parsing into a testable function/class
- [R] C++ tool execution currently depends on `SidecarBridge` context → Mitigation: refactor `read_file`/`list_dir` to accept workspace path as parameter
- [R] Catch2 header needs to be downloaded (no internet in some envs) → Mitigation: commit the single header to `sidecar/test/third_party/`
