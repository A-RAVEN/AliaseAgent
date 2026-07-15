## Context

The C++ Sidecar DLL (`sidecar.dll`) is the most complex component — it handles HTTP/SSE communication with the Anthropic API, JSON parsing/assembly, and tool execution with filesystem access. The `ffi-bridge`, `model-gateway`, and `basic-tools` specs define 40+ behavioral scenarios. Currently zero automated C++ tests exist. A C++ test harness with recorded SSE fixtures provides the fastest path to coverage without requiring a live API key.

**Code structure reality**: SSE parsing is NOT a standalone class — it is inline in the static `write_callback()` function (`model_gateway.cpp:68-206`) tightly coupled to `ModelGateway::Impl*`. HTTP request construction is NOT a separate builder — headers, body, and CURL options are built inline in `ModelGateway::execute()` (`model_gateway.cpp:293-351`). Rather than refactoring production code, tests use an embedded TCP mock server — `ModelGateway::execute()` sends requests to localhost where the mock server replays SSE fixture data and inspects incoming request headers/body.

## Goals / Non-Goals

**Goals:**
- Set up a C++ test project under `sidecar/test/` with the Catch2 test framework
- Create SSE fixture files from recorded real API responses covering all event types
- Test SSE parser: text delta, tool_use (single + fragmented + multi-block), thinking block, message_stop, error event, `[DONE]` marker, all recognized-but-ignored events, edge cases
- Test tool execution: `read_file` (8 paths), `list_dir` (8 paths), `set_workspace` (4 paths) with temp filesystem
- Test HTTP request construction: headers, body fields, input validation (NOT connection-layer testing)
- Add a CMake test target (`ctest`) and document the test workflow

**Non-Goals:**
- Not testing live API calls (requires network + API key)
- Not testing FFI boundary (Dart↔C++ interop)
- Not testing HTTP connection layer (timeout, live network, DNS) — fixture-based only
- Not achieving 100% line coverage (focus on behavior, not metrics)
- Not testing Dart-side content block array assembly (belongs in Dart widget/unit tests)

## Decisions

### D1: Test framework — Catch2 v3 (latest, CMake FetchContent)

**选择**: Catch2 v3 (latest release)。通过 CMake `FetchContent` 引入，与项目中已有的 nlohmann/json 依赖相同的引入方式。

```cmake
FetchContent_Declare(
  Catch2
  GIT_REPOSITORY https://github.com/catchorg/Catch2.git
  GIT_TAG v3.11.0
)
FetchContent_MakeAvailable(Catch2)
# 注意：不使用 Catch2WithMain，需要自定义 main() 进行 CURL/Winsock 初始化
target_link_libraries(sidecar_tests PRIVATE Catch2::Catch2)
```

**自定义 `test_main.cpp`**（不用 `Catch2::Catch2WithMain`）：需要在测试启动时初始化 `curl_global_init()` 和 Windows Winsock（`WSAStartup`）。测试项目提供自己的 `main()`：

```cpp
// sidecar/test/test_main.cpp
#define CATCH_CONFIG_RUNNER
#include <catch2/catch_all.hpp>
#include <curl/curl.h>
#ifdef _WIN32
#include <winsock2.h>
#endif

int main(int argc, char* argv[]) {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    curl_global_init(CURL_GLOBAL_ALL);

    int result = Catch::Session().run(argc, argv);

    curl_global_cleanup();
#ifdef _WIN32
    WSACleanup();
#endif
    return result;
}
```

Catch2 v3 不再以单头文件分发，但 `FetchContent` 使得引入开销为零——CMake 自动拉取、编译、链接。

### D2: SSE fixture format

Record real API responses as raw text files with complete SSE data lines. **Critical**: fixtures must include `content_block_start` events before `content_block_delta` for tool_use and thinking blocks, matching real API behavior.

```
test/fixtures/sse/
├── text_delta.txt              # single content_block_delta with text
├── text_multiple.txt           # multiple sequential text deltas
├── text_empty.txt              # content_block_delta with empty text field
├── content_block_delta_no_delta.txt  # content_block_delta missing 'delta' key
├── tool_use_single.txt         # content_block_start → input_json_delta → content_block_stop
├── tool_use_fragmented.txt     # content_block_start → 3×input_json_delta → content_block_stop
├── tool_use_multi_block.txt    # two tool_use blocks at different indices
├── thinking_block.txt          # content_block_start(thinking) → thinking_delta → signature_delta → content_block_stop
├── multi_block_integration.txt # thinking(index 0) + text deltas + tool_use(index 1) interleaved
├── message_stop_end_turn.txt   # message_delta(stop_reason:end_turn) → message_stop
├── message_stop_tool_use.txt   # message_delta(stop_reason:tool_use) → message_stop
├── message_stop_no_delta.txt   # message_stop without prior message_delta
├── message_delta_no_stop_reason.txt  # message_delta without stop_reason field → message_stop
├── done_marker.txt             # data: [DONE]
├── done_marker_with_stop_reason.txt  # message_delta → [DONE] (stop_reason carry-forward)
├── error_event.txt             # {"type":"error","error":{"message":"..."}}
├── message_start.txt           # message_start event (recognized, ignored)
├── ping_event.txt              # ping event (recognized, ignored)
├── unrecognized_event.txt      # Unknown event type
├── json_parse_error.txt        # Non-JSON data line (truncated/corrupted)
├── content_block_start_text.txt # content_block_start with type "text" (recognized, ignored)
└── tool_input_json_parse_fail.txt  # accumulated partial_json that fails json::parse
```

**选择**: Raw text files (exact bytes from API). Tests feed these into the extracted SSE parser and assert callback invocations.

### D3: Test via embedded TCP mock server (separate thread)

不修改生产代码。Mock server 在**独立线程**上运行（`curl_easy_perform` 同步阻塞测试线程），监听随机端口。

#### 线程模型

```
测试线程                               Mock Server 线程
─────────                              ────────────────
server.start(fixture_path)  ──启动──▶  bind(0) → listen()
server.wait_ready(timeout)  ←─就绪──  promise.set_value(port)
gw.execute(base_url=localhost:{port})  accept() ← 阻塞等待
    ↓                                              ↓
curl_easy_perform() ← 阻塞          recv() → 记录 HTTP 请求
    ↓                                              ↓
write_callback ← CURL 收数据          send(HTTP 响应 + fixture)
    ↓                                              ↓
dispatch_events → callbacks          close() → 线程退出
    ↓
server.join()
CHECK(callbacks == expected)
CHECK(server.last_request() == expected)
```

#### HTTP 响应构造

Mock server 发送完整 HTTP 响应（不只是 raw fixture 字节）：

```http
HTTP/1.1 200 OK\r\n
Content-Type: text/event-stream\r\n
Transfer-Encoding: chunked\r\n
\r\n
{chunk-size in hex}\r\n
{SSE fixture data}\r\n
0\r\n
\r\n
```

**关键细节**：
- `Transfer-Encoding: chunked` — CURL 依赖 `0\r\n\r\n` 终止 chunk 来判断流结束。没有它会产生 `CURLE_PARTIAL_FILE` 错误
- 响应后立即关闭 socket（`close()` 在 `send` 之后），阻止 CURL keep-alive 连接复用
- `Content-Type: text/event-stream` 是 Anthropic API 的标准 SSE 响应头

#### Mock Server API

```cpp
class MockServer {
public:
    /// 启动 server 线程，绑定随机端口，注册 {path → fixture} 映射
    void start(const std::string& fixture_path);
    /// 等待 server 就绪（listen 完成），超时抛出异常
    void wait_ready(std::chrono::seconds timeout = std::chrono::seconds(2));
    /// 返回 "http://localhost:{port}"
    std::string base_url() const;
    /// 阻塞等待 server 线程退出
    void join();

    /// 最后一次请求的 HTTP method（"POST" / "GET"）
    std::string last_method() const;
    /// 最后一次请求的 URL path（如 "/v1/messages"）
    std::string last_path() const;
    /// 最后一次请求的指定 header 值，不存在返回空
    std::string last_header(const std::string& name) const;
    /// 最后一次请求的 body 内容
    std::string last_body() const;

private:
    std::thread thread_;
    std::promise<uint16_t> ready_;
    uint16_t port_ = 0;
    // ... request recording fields, mutex-protected
};
```

#### 测试代码

```cpp
// SSE parser test
MockServer server;
server.start(fixture_path);
server.wait_ready();

ModelGateway gw;
std::vector<std::string> chunks;
gw.execute("sk-test", server.base_url().c_str(), "claude-sonnet-4-6",
           "", messages_json, "",
           [&](const char* t) { chunks.push_back(t); },
           /*on_tool_call*/nullptr, /*on_thinking*/nullptr,
           [&](int c, const char* e, const char* r) { ... });

server.join();
REQUIRE(chunks == expected_chunks);

// HTTP request construction test — same flow, inspect after
REQUIRE(server.last_method() == "POST");
REQUIRE(server.last_header("x-api-key") == "sk-test");
REQUIRE(server.last_header("anthropic-version") == "2023-06-01");
// ... verify body fields via JSON parse of server.last_body()
```

**选择**: 独立线程 Mock server 回放方案。零生产代码改动。测试链接 `model_gateway.cpp` + `tools.cpp`（不链接 `sidecar_api.cpp`，避免 `SIDECAR_API`/`__declspec(dllimport)` 冲突）。`send_message()` 的输入验证（空 api_key、JSON parse 失败）在 `model_gateway.cpp` 层面测试。

### D4: Tool execution tests use temp filesystem + RAII workspace lifecycle

`read_file` and `list_dir` operate on the workspace directory set via `set_workspace()`. `g_workspace` is a file-static global (`tools.cpp:26`). Use a **RAII fixture** — destructor calls `set_workspace("")` so cleanup runs even if assertions throw:

```cpp
struct WorkspaceGuard {
    explicit WorkspaceGuard(const std::string& path) {
        tools::set_workspace(path);
    }
    ~WorkspaceGuard() {
        tools::set_workspace(""); // guaranteed cleanup
    }
};

// In test:
TempDir tmp;
tmp.write("hello.txt", "hello world");
WorkspaceGuard ws(tmp.path());  // RAII — destructor always runs
REQUIRE(tools::read_file("hello.txt") == R"({"ok":true,"content":"hello world"})");
// If REQUIRE above fails, ~WorkspaceGuard still resets g_workspace
```

**注意**: `set_workspace()` calls `canonical()` which requires the path to **already exist** on disk.

### D5: list_dir output format (`"content"` not `"entries"`)

The actual `list_dir()` implementation (and `read_file()`) both use the shared `ok_result()` helper which produces `{"ok":true,"content":"<json_escaped_string>"}`. The entries JSON array is an **escaped string** inside the `"content"` field, NOT a direct JSON array under `"entries"`.

```json
{"ok":true,"content":"[{\"name\":\"file.txt\",\"type\":\"file\"},{\"name\":\"subdir\",\"type\":\"directory\"}]"}
```

Test assertions must account for this double-encoding. The `tools.h` and `sidecar_api.h` header comments are also wrong and should be fixed.

## Risks / Trade-offs

- [R1] Mock server 线程启动失败（端口绑定、fixture 加载异常）时，测试线程的 `curl_easy_perform` 会阻塞直到 `CURLOPT_CONNECTTIMEOUT`（30s）→ **Mitigation**: `MockServer::wait_ready()` 使用 `std::promise`/`std::future` — server 线程 `listen()` 成功后设置 promise，测试线程超时 2s 内失败并输出明确错误消息。同时在 setUp 中调用 `gw.set_timeout(5)` 将 CURL 超时降到 5 秒。
- [R2] 跨平台 socket API 差异（Windows Winsock vs Unix socket）→ **Mitigation**: `mock_server.h` 内部 `#ifdef _WIN32` 使用 Winsock2（`WSAStartup` 在 `test_main.cpp` 中已完成），Unix 使用 POSIX socket。仅需 bind/listen/accept/send/recv/close 六个函数。
- [R3] Tool execution 依赖 file-static global `g_workspace` → **Mitigation**: RAII `WorkspaceGuard`（D4）保证析构函数在断言异常时仍然执行清理。测试单线程运行（Catch2 默认）。
- [R4] Catch2 v3 通过 FetchContent 下载，无网络环境需提前缓存 → Mitigation: 与 nlohmann/json 同样处理，设置 `FETCHCONTENT_SOURCE_DIR_CATCH2` 指向本地缓存路径。
- [R5] Logger singleton 在测试中默认是 no-op（未 `init()` 时 `LOG_*` 宏写向空 `ofstream`）→ Mitigation: `test_main.cpp` 中调用 `Logger::instance().init("/tmp/sidecar_test_logs")`。验证 "LOG_WARN 被调用" 的测试改为验证行为（callback 未被触发）而非日志内容。
- [R6] `SIDECAR_API` / `__declspec(dllimport)` 冲突：如果直接链接 `sidecar_api.cpp`，在 Windows 非 `SIDECAR_EXPORTS` 下符号会标记为从 DLL 导入 → Mitigation: **测试不链接 `sidecar_api.cpp`**。`send_message()` 的输入验证逻辑直接在 `model_gateway.cpp` 层面测试（通过 `ModelGateway::execute()`）。`set_workspace`/`read_file`/`list_dir` 直接调用 `tools::` 命名空间函数。
- [R7] `sidecar_api.cpp` 中的 `send_message()` 空 api_key 校验路径无法直接测试（不链接该文件）→ Mitigation: 该路径是简单的 if-null-early-return（`sidecar_api.cpp:47-50`），行为明确。如需覆盖，在 tasks 中标记为 code-review 验证。
