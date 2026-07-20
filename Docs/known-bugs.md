# Known Bugs

## model_gateway: SSE dispatch overwrites HTTP error on_done code

**来源**: `add-cpp-sidecar-tests` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `sidecar/src/model_gateway.cpp`, `sidecar/test/http_client_test.cpp`

### 症状

`http_client_test.cpp:274` 测试失败：
```
HTTP: 400 error body captured and logged
  REQUIRE( s_done_code == -1 )
  with expansion: 0 == -1
```

### 根因

`model_gateway.cpp` 在 HTTP 状态码检查之前先 dispatch SSE 事件：

```
curl_easy_perform() 完成
  ↓
dispatch_events()  ← SSE body 里有合法事件 → 触发 on_done(0, ...), done_dispatched = true
  ↓
http_code >= 400?  ← 检测到 400，想调 on_done(-1, ...)，但 done_dispatched 已经是 true，被跳过
```

HTTP 400 响应的 body 如果包含合法的 Anthropic SSE 事件（如测试用的 `text_delta.txt` fixture），`dispatch_events` 会先解析到 `message_stop` 事件并调用 `on_done(0, ...)`（成功码），后续 HTTP 错误处理想调 `on_done(-1, ...)` 时被 `done_dispatched` 标记阻止。

### 修复思路

将 HTTP 状态码检查移到 `dispatch_events` 之前。HTTP >= 400 时应直接报错，不解析 SSE body。

---

## debug-infra: task 6.7 未完成但标记为 done

**来源**: `debug-infra` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `sidecar/test/ffi_tracing_test.cpp`

### 症状

tasks.md 中 6.7 标记 `[x]`（已完成），描述为"写入 300 事件 → 验证环形缓冲区回绕 + dump 输出格式"。实际代码只有 3 个基本 ring buffer 测试，未覆盖回绕和 dump 格式验证。

### 修复

`ffi_tracing_test.cpp` 补写回绕和 dump 格式测试。环形缓冲区大小 256，写入 300 事件后可验证回绕行为。

---

## add-widget-interaction-tests: ChatScreen 场景不足

**来源**: `add-widget-interaction-tests` proposal（已归档）
**发现日期**: 2026-07-19
**相关文件**: `test/widget/chat_screen_test.dart`

### 症状

checkpoint C 要求 ChatScreen 至少 3 个测试场景，实际只写了 2 个（DI 注入 + 构造函数默认值）。

### 修复

`chat_screen_test.dart` 补至少 1 个场景。---

## sidecar_api: ensure_search_infra 无限递归

**来源**: `add-web-search` proposal
**发现日期**: 2026-07-19
**已修复**: 是 (2026-07-20 永久修复)
**相关文件**: `sidecar/src/sidecar_api.cpp:123`

### 根因

C API 包装函数 `ensure_search_infra` 和 C++ 实现函数 `ensure_search_infra` 都在全局命名空间。`::ensure_search_infra(const char*)` 被编译器解析为 C API 自身而非 C++ 实现 `ensure_search_infra(const std::string&)`。栈溢出 → ACCESS_VIOLATION。

同一 bug 也影响了 `web_fetch`（sidecar_api.cpp:174），但直到 2026-07-20 AI 首次调用 web_fetch tool 才触发。

### 修复

- **临时** (2026-07-19): `::ensure_search_infra(std::string(...))` 强制重载选择。
- **永久** (2026-07-20): C++ 实现函数重命名为 `ensure_search_infra_impl` 和 `web_fetch_impl`，彻底消除命名冲突。
