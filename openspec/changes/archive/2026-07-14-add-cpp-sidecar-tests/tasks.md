## 1. Test Infrastructure

- [x] 1.1 创建 `sidecar/test/` 目录结构 + 更新 `sidecar/CMakeLists.txt`：
  - `enable_testing()` + `add_executable(sidecar_tests ...)` + `add_test(NAME ... COMMAND sidecar_tests)`
  - `FetchContent` 引入 Catch2 v3，链接 `Catch2::Catch2`（不使用 `Catch2WithMain`）
  - 测试 target 链接 `model_gateway.cpp` + `tools.cpp` + `logger.cpp`（不链接 `sidecar_api.cpp`，避免 `__declspec(dllimport)` 冲突）
  - 继承主项目的 `CURL::libcurl`、nlohmann/json include、`_CRT_SECURE_NO_WARNINGS`、`WIN32_LEAN_AND_MEAN`、`NOMINMAX`、`ws2_32`
- [x] 1.2 创建 `sidecar/test/test_main.cpp` — 自定义 Catch2 runner，初始化 `curl_global_init()` + `WSAStartup`（Windows），退出时清理（见 D1）
- [x] 1.3 实现 `sidecar/test/mock_server.h` — 嵌入 TCP mock server：
  - 独立 `std::thread` accept/send，测试线程 `curl_easy_perform`
  - 启动时 `bind(0)` 随机端口 → `listen()` → `promise.set_value(port)` 通知就绪
  - `wait_ready(timeout)`：`future.wait_for()` 阻塞等待，超时抛异常
  - 收到连接后构造完整 HTTP 响应：`HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{chunk_size}\r\n{fixture}\r\n0\r\n\r\n`
  - 解析 HTTP 请求：提取 method、path、headers、body 供测试断言
  - `#ifdef _WIN32` Winsock2 / `#else` POSIX socket
  - `set_timeout(5)` 在 setUp 中将 CURL 超时降到 5 秒，避免 mock server 故障时 hang 30s
- [x] 1.4 实现 `sidecar/test/temp_dir.h` — RAII 临时目录 + `WorkspaceGuard`（D4）
- [x] 1.5 创建 `sidecar/test/fixtures/sse/` 目录，从真实 API 响应录制 SSE fixture 文件（含 content_block_start、[DONE] marker、multi-block integration、message_delta_no_stop_reason 等）
- [x] 1.6 修复 `sidecar/src/tools.h:28` 和 `sidecar/include/sidecar_api.h:51` 中 `list_dir` 返回格式注释：`"entries"` → `"content"`

## 2. SSE Parser Tests

- [x] 2.1 `sidecar/test/sse_parser_test.cpp`：测试 text_delta 解析 → on_chunk 回调正确触发
- [x] 2.2 测试 tool_use 解析（单 fragment + 多 fragment input_json_delta）→ on_tool_call 含完整 input JSON
- [x] 2.3 测试 thinking block 解析（content_block_start(thinking) → thinking_delta → signature_delta → content_block_stop）→ on_thinking 含 thinking + signature
- [x] 2.4 测试 message_stop 解析 → on_done(0, "", stop_reason) （注意：空字符串非 nullptr）
- [x] 2.5 测试 error event 解析 → on_done(-1, error_message, "")
- [x] 2.6 测试 unrecognized event type → 不崩溃，LOG_WARN
- [x] 2.7 测试 `[DONE]` marker → on_done(0, "", stop_reason)（含 stop_reason carry-forward）
- [x] 2.8 测试 JSON parse error in data line → 不崩溃，LOG_ERR，跳过该行
- [x] 2.9 测试 content_block_delta 缺少 "delta" 字段 → 不崩溃，静默跳过
- [x] 2.10 测试空 text_delta（text=""）→ on_chunk 仍触发（空字符串）
- [x] 2.11 测试 content_block_start 未知类型（如 "text"）→ 不崩溃，LOG_INFO
- [x] 2.12 测试 message_start 事件 → 不崩溃，LOG_INFO，无 callback
- [x] 2.13 测试 ping 事件 → 不崩溃，无任何输出
- [x] 2.14 测试 message_delta 无 stop_reason → last_stop_reason 保持空字符串
- [x] 2.15 测试 multi-block integration（thinking + text + tool_use 交错）→ 各 callback 独立触发
- [x] 2.16 测试多个 tool_use blocks（不同 index）→ 各自独立组装
- [x] 2.17 测试 tool_use input_json parse 失败 → LOG_ERR，tool_use 不含 input 字段

## 3. Tool Execution Tests

- [x] 3.1 `sidecar/test/tool_execution_test.cpp`：测试 `set_workspace` 成功 → 返回 ""
- [x] 3.2 测试 `set_workspace` 空路径 → 返回 "Workspace path is empty"
- [x] 3.3 测试 `set_workspace` 无效路径 → 返回 "Invalid workspace path: ..."
- [x] 3.4 测试 `set_workspace` 路径不是目录 → 返回 "Workspace is not a directory: ..."
- [x] 3.5 测试 `read_file` 读取存在的文本文件 → `{"ok":true,"content":"<content>"}`
- [x] 3.6 测试 `read_file` 文件不存在 → `{"ok":false,"error":"File not found: <path>"}`
- [x] 3.7 测试 `read_file` 路径越权（..）→ `{"ok":false,"error":"Access denied: path outside workspace"}`
- [x] 3.8 测试 `read_file` 二进制文件 → `{"ok":false,"error":"Cannot read binary file"}`
- [x] 3.9 测试 `read_file` 路径是目录 → `{"ok":false,"error":"Path is a directory, not a file: <path>"}`
- [x] 3.10 测试 `read_file` 空文件 → `{"ok":true,"content":""}`
- [x] 3.11 测试 `read_file` 无 workspace → `{"ok":false,"error":"No workspace set"}`
- [x] 3.12 测试 `read_file` 无法解析路径 → `{"ok":false,"error":"Cannot resolve path: <path>"}` ⚠️ best-effort（平台相关）
- [x] 3.13 测试 `list_dir` 列出目录内容 → `{"ok":true,"content":"[{\"name\":\"...\",\"type\":\"file|directory\"},...]"}`（JSON-escaped string）
- [x] 3.14 测试 `list_dir` 空目录 → `{"ok":true,"content":"[]"}`
- [x] 3.15 测试 `list_dir` 目录不存在 → `{"ok":false,"error":"Directory not found: <path>"}`
- [x] 3.16 测试 `list_dir` 路径是文件 → `{"ok":false,"error":"Not a directory: <path>"}`
- [x] 3.17 测试 `list_dir` 路径越权（..）→ `{"ok":false,"error":"Access denied: path outside workspace"}`
- [x] 3.18 测试 `list_dir` 无法读取目录 → `{"ok":false,"error":"Cannot read directory: <path>"}` ⚠️ best-effort（OS 权限相关）
- [x] 3.19 测试 `list_dir` 无 workspace → `{"ok":false,"error":"No workspace set"}`
- [x] 3.20 测试 `list_dir` 无法解析路径 → `{"ok":false,"error":"Cannot resolve path: <path>"}` ⚠️ best-effort（平台相关）

## 4. HTTP Request Construction Tests

- [x] 4.1 `sidecar/test/http_client_test.cpp`：测试请求 headers（mock server 检验收到的 x-api-key, anthropic-version, content-type）
- [x] 4.2 测试请求 body 含 model, messages, system, tools, stream:true, max_tokens:4096（mock server 检验 JSON body）
- [x] 4.3 测试 system 或 tools 为空/null 时 body 不包含对应字段
- [x] 4.4 测试 base_url 为空时默认为 `https://api.anthropic.com/v1/messages`（通过 mock server URL 断言）
- [x] 4.5 测试 api_key 为空 → on_done(0, "", "") 直接返回 1，不发 HTTP 请求（mock server 无连接）
- [x] 4.6 测试 messages_json 解析失败 → on_done(-1, "Invalid messages JSON", "")
- [x] 4.7 测试 tools_json 解析失败 → on_done(-1, "Invalid tools JSON", "")
- [x] 4.8 测试 request_id 单调递增

## 5. Documentation

- [x] 5.1 在 `sidecar/test/README.md` 写测试构建和运行说明：`cmake --build build/windows && ctest`

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | CMake 构建成功 | `cmake --build build/windows --target sidecar_tests` 无错误 |
| B | SSE 解析测试通过 | `ctest -R sse_parser` 全部 pass |
| C | 工具执行测试通过 | `ctest -R tool_execution` 全部 pass |
| D | HTTP 测试通过 | `ctest -R http_client` 全部 pass |
| E | 全量通过 | `ctest` 全部 pass |
