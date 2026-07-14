## 1. Test Infrastructure

- [ ] 1.1 创建 `sidecar/test/` 目录结构 + `CMakeLists.txt` 测试 target
- [ ] 1.2 下载/添加 Catch2 单头文件到 `sidecar/test/third_party/catch2.hpp`
- [ ] 1.3 创建 `sidecar/test/fixtures/sse/` 目录，从真实 API 响应录制 SSE fixture 文件

## 2. SSE Parser Tests

- [ ] 2.1 `sidecar/test/sse_parser_test.cpp`：测试 text_delta 解析 → on_chunk 回调正确触发
- [ ] 2.2 测试 tool_use 解析（单 fragment + 多 fragment input_json_delta）→ on_tool_call 含完整 input JSON
- [ ] 2.3 测试 thinking block 解析（thinking_delta + signature_delta）→ on_thinking 含 thinking 和 signature
- [ ] 2.4 测试 message_stop 解析 → on_done(0, null, stop_reason) 正确
- [ ] 2.5 测试 error event 解析 → on_done(nonzero, error_msg, null)
- [ ] 2.6 测试 unrecognized event type → 不崩溃，记录日志

## 3. Tool Execution Tests

- [ ] 3.1 `sidecar/test/tool_execution_test.cpp`：测试 read_file 读取存在的文本文件 → `{"ok":true,"content":"..."}`
- [ ] 3.2 测试 read_file 文件不存在 → error "File not found"
- [ ] 3.3 测试 read_file 路径越权（..） → error "Access denied"
- [ ] 3.4 测试 list_dir 列出目录内容 → entries 数组含 name + type
- [ ] 3.5 测试 list_dir 目录不存在 → error "Directory not found"
- [ ] 3.6 测试 list_dir 路径是文件 → error "Not a directory"

## 4. HTTP Client Tests

- [ ] 4.1 `sidecar/test/http_client_test.cpp`：测试请求构造含正确 headers（x-api-key, anthropic-version, content-type）
- [ ] 4.2 测试请求 body 含 model, messages, system, tools, stream:true
- [ ] 4.3 测试 HTTP 401 响应 → on_done(code≠0, "Authentication failed")
- [ ] 4.4 测试 HTTP 500 响应 → on_done(code≠0, response body)

## 5. JSON Assembly Tests

- [ ] 5.1 `sidecar/test/json_assembly_test.cpp`：测试 text-only 消息 content 为 `[{"type":"text","text":"..."}]`
- [ ] 5.2 测试含 tool_use 的消息 content 包含完整的 tool_use block
- [ ] 5.3 测试 tool_result 消息 content 为 `[{"type":"tool_result","tool_use_id":"...","content":"..."}]`
- [ ] 5.4 测试多轮 tool use 后 messages 数组结构正确（user → assistant+tool_use → user+tool_result）

## 6. Documentation

- [ ] 6.1 在 `sidecar/test/README.md` 写测试构建和运行说明：`cmake --build build && ctest`

### 🔎 Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | CMake 构建成功 | `cmake --build build --target sidecar_tests` 无错误 |
| B | SSE 解析测试通过 | `ctest -R sse_parser` 全部 pass |
| C | 工具执行测试通过 | `ctest -R tool_execution` 全部 pass |
| D | HTTP 测试通过 | `ctest -R http_client` 全部 pass |
| E | JSON 测试通过 | `ctest -R json_assembly` 全部 pass |
| F | 全量通过 | `ctest` 全部 pass |
