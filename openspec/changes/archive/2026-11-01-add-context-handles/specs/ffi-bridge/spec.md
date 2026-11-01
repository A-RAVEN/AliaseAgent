## ADDED Requirements

### Requirement: Context handle exports

Dart 桥 SHALL 解析 **`create_context` 与 `dispose_context` 两者**的 JSON 返回（成功与失败形状都要覆盖），并提供幂等的 `ensureContext(sessionId)`。启动恢复、切换、新建会话以及每次模型/工具调用前 SHALL 能确保对应上下文存在；新建后 SHALL 初始化该上下文的工作区。`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` SHALL 继续无句柄调用。

`disposeContext` SHALL 先标记关闭并拒绝新调用，等待该上下文的排队请求、工具 Future 与 Dart 回调处理结束，再异步调用 C++ `dispose_context` 完成底层排空；对应请求队列与计数 SHALL NOT 提前删除。删除会话的调用方 SHALL 另外等待 `ChatScreen` 登记的整轮 Future（含 `sendMessage` 之后的数据库写入与后台压缩写库）；数据库删除 SHALL 晚于这些层全部结束，而不只晚于 C++ 返回。

#### Scenario: 恢复既有会话也能取得上下文

- **WHEN** 应用重启后从数据库恢复一条会话，或切换到一条尚未在本进程建过上下文的会话
- **THEN** `ensureContext` SHALL 创建或复用对应上下文并确保工作区已初始化，随后工具调用 SHALL NOT 报 `unknown_context`

#### Scenario: 工具调用不读取错误的当前会话

- **WHEN** 一次模型轮次属于会话甲，执行工具前界面已切到会话乙
- **THEN** 这次工具调用 SHALL 仍使用调用方显式传入的甲句柄，SHALL NOT 读取当时的 `_currentId` 顶替

#### Scenario: 删会话先排空再删数据

- **WHEN** 删除一条仍有模型请求或长命令的会话
- **THEN** 桥 SHALL 先停止该上下文新调用并等待 `disposeContext` 完成，再删除数据库消息与更新列表；spill 目录 SHALL 由同一次 `dispose_context` 清理

#### Scenario: 没拿到句柄时不发工具请求

- **WHEN** 一次工具调用无法取得所属会话的句柄
- **THEN** 桥 SHALL 报错并 SHALL NOT 用空句柄、机器级默认句柄或别的会话句柄发出请求

## MODIFIED Requirements

### Requirement: Send message via FFI
The system SHALL provide a C function `send_message` whose first parameter is the context handle, followed by api key, base URL, model, system prompt, messages JSON, tools JSON, thinking mode (string), thinking effort (string), four callback function pointers (on_chunk, on_tool_call, on_thinking, on_done), and finally `int request_id`. The function SHALL return a request ID integer. An unknown or disposed handle SHALL return a negative code and deliver an `unknown_context` error through `on_done` without starting HTTP. The existing empty-or-null-api-key early return SHALL remain `return 1` with `on_done(0, "", "", 0, 0)` and no HTTP request; it is not the invalid-parameter error path.

#### Scenario: Successful invocation
- **WHEN** Dart calls `send_message` with a valid context handle, valid parameters and callbacks
- **THEN** C++ side begins processing on that context's model gateway and returns a non-negative request ID

#### Scenario: Thinking mode and effort passed
- **WHEN** Dart calls `send_message` with `thinking_mode = "adaptive"` and `thinking_effort = "high"`
- **THEN** the C++ side receives both values and includes adaptive thinking configuration in the API request

#### Scenario: Thinking disabled
- **WHEN** Dart calls `send_message` with `thinking_mode = "disabled"` or empty string
- **THEN** the C++ side sends no thinking configuration and uses default max_tokens

#### Scenario: Invalid parameters
- **WHEN** Dart calls `send_message` with an invalid context-independent parameter (for example malformed messages JSON)
- **THEN** C++ side returns a negative error code and calls on_done with the corresponding error

#### Scenario: Empty api key keeps the existing early return
- **WHEN** Dart calls `send_message` with an empty or null api key on a valid context
- **THEN** C++ side returns 1, calls on_done(0, "", "", 0, 0), and starts no HTTP request

#### Scenario: Unknown context
- **WHEN** Dart calls `send_message` with an unknown context handle
- **THEN** C++ returns a negative code, delivers `unknown_context` through on_done, and does not enqueue the request

### Requirement: Request serialization gate and cancellation
The Dart bridge SHALL serialize requests **per context**: a new `sendMessage` on one context SHALL NOT start until that context's active request's done callback has been processed (or its active request has been cancelled and its done delivered). Requests on different contexts SHALL NOT wait for each other. On timeout or session switch, the bridge SHALL invoke the C++ cancel path (FFI `cancel_request`, which takes the context handle and the request id) and wait for the resulting done before allowing a new request on that context — it SHALL NOT fake a done callback. If the cancellation path never delivers a real done, the waiting Future SHALL complete with an error and the context SHALL become `context_poisoned`; the bridge SHALL NOT synthesise `onDone`, SHALL NOT release the context for new requests, and SHALL keep callables open. NativeCallable listeners SHALL be closed only after a real done (success or cancellation) has been received, never while the curl thread may still invoke callbacks.

#### Scenario: New request waits for active request
- **WHEN** `sendMessage` is called on a context while that context's previous request is still streaming
- **THEN** the new call waits until the previous request's done has been processed, then proceeds

#### Scenario: Another context does not wait
- **WHEN** two different contexts each call `sendMessage` while neither has an active request
- **THEN** both requests SHALL be in flight at the same time; neither SHALL be held behind the other's done

#### Scenario: Timeout triggers real cancellation
- **WHEN** the 120s receive timeout fires
- **THEN** `cancel_request(handle, request_id)` is invoked, the C++ request terminates, and on_done(-1) is delivered by the curl thread before the bridge closes callables or allows a new request

#### Scenario: Cancel never delivers done
- **WHEN** the existing fallback window expires after cancellation without a real done
- **THEN** the waiting Future SHALL fail with an error, the context SHALL become `context_poisoned`, no synthetic model on_done SHALL be delivered, and a new request on that context SHALL be rejected until disposal or process restart

### Requirement: Request-id targeted cancel (assign a per-request id)
The Dart bridge SHALL assign a unique monotonically-increasing `request_id` to every `sendMessage` **before** it is enqueued on that context's serialization gate, and pass both the context handle and the id to the C++ `send_message`; it SHALL also pass them into the worker isolate. The serialization chain, last enqueued request id and pending-request count SHALL be kept per context. `cancelRequest(handle)` SHALL invoke the C++ `cancel_request(handle, id)` for the most recently enqueued/active request **of that context**, which at a background-fold preempt is the fold's request (the user's own request is enqueued AFTER with a different id). The timeout path SHALL cancel with the same context handle and the exact timed-out request id. Summary and seam-selection requests SHALL carry their owning session's handle. This makes cancellation request-id targeted (a queued-but-not-starting fold request is aborted, the user request is unaffected), satisfying the "background folding never delays the user" contract.

#### Scenario: Bridge assigns unique ids
- **WHEN** `sendMessage` is called
- **THEN** a fresh monotonically-increasing `request_id` is assigned before enqueueing and passed to the C++ `send_message`

#### Scenario: cancelRequest targets the fold's request id
- **WHEN** `cancelRequest()` is invoked while a background fold request is the most recently enqueued/active request of that context
- **THEN** `cancel_request(handle, foldRequestId)` is called (NOT a no-arg cancel), so the fold request aborts and the user request (different id) is unaffected

#### Scenario: Cancel does not reach another context
- **WHEN** two contexts each have a request in flight and one context cancels its own
- **THEN** only that context's request aborts; the other context's request keeps streaming

### Requirement: read_spill via FFI

动态库 SHALL 导出 `read_spill(const char* handle, const char* request_json)`，`handle` 是上下文句柄，`request_json` 形如 `{"ref":"<spill 引用>","offset":0,"limit":1000}`，返回以 NUL 结尾的 JSON 字符串。

- `offset` 与 `limit` 的单位都是**字节**；`offset` 省略时按 0 处理，`limit` 省略时按 `preview_chars × 2` 处理。
  > **单位说明**：`preview_chars × 2` 只是**复用了那个数字**，不是"与内联预览的上界一致"—— 内联预览按**字符**计（1000 个汉字 = 1000 字符 = 3000 字节），而 `limit` 按**字节**计，缺省 2000 字节只够 666 个汉字。要取"预览里那 1000 个字符的字节数"，调用方必须自己按字节算区间；本条不承诺两者相等。
- 成功：`{"ok":true,"text":"<该区间原文>","bytes_read":N,"total_bytes":M}`；
- 失败：`{"ok":false,"error":"<原因>"}`，与其它工具失败形状一致。

失败情形 SHALL 可区分且各有场景：引用不在 spill 根目录内、引用不存在、偏移/长度越界、区间切在多字节字符中间、spill 根目录不可读。

#### Scenario: 符号解析并返回区间
- **WHEN** Dart 用一份合法引用与合法区间调用导出的 `read_spill`
- **THEN** 返回的 JSON SHALL 满足 `ok == true`，且 `text` 与 spill 文件对应区间逐字节相同

#### Scenario: 越界报错
- **WHEN** `offset + limit` 超过该引用的总字节数
- **THEN** 返回 SHALL 是 `ok:false`，`error` 里 SHALL 说明是越界，而不是静默返回能读到的部分

#### Scenario: 引用不在 spill 根目录内
- **WHEN** `ref` 指向 `~/.aliasagent/config.json`
- **THEN** 返回 SHALL 是 `ok:false`，且错误文本与"引用不存在"不同

#### Scenario: 切点多字节字符
- **WHEN** 区间起点落在某个中文字符的第二个字节上
- **THEN** 返回 SHALL 是 `ok:false` 并说明切点落在多字节字符中间，SHALL NOT 返回半个字符

#### Scenario: 句柄指向另一个上下文时不串
- **WHEN** 上下文 `甲` 与 `乙` 各有一份 spill 文件，用 `乙` 的句柄去读 `甲` 的引用
- **THEN** 返回 SHALL 是 `ok:false`（引用不属于该上下文的目录），SHALL NOT 读回 `甲` 的内容

### Requirement: read_image via FFI

The dynamic library SHALL export `read_image(const char* handle, const char* request_json)` where `handle` is the context handle and `request_json` is `{"path":"…"}`. It SHALL return a NUL-terminated UTF-8 JSON string owned by the calling thread's result buffer: `{"ok":true,"content":"…","image":{…}}` on success, `{"ok":false,"error":"…"}` on failure. Dart SHALL resolve the symbol at startup and a missing symbol SHALL surface as a startup error naming the function, not a crash.

#### Scenario: Symbol resolves and returns JSON
- **WHEN** Dart calls the exported `read_image` with a valid context handle and a valid image path inside that context's workspace
- **THEN** the returned string parses as JSON with `ok == true`, and `image.media_type` / `image.width` / `image.height` / `image.bytes` are all present

#### Scenario: Failure shape matches the other tools
- **WHEN** the exported `read_image` is called with a non-existent path
- **THEN** the returned JSON has `ok == false` and an `error` string, and no `image` object

### Requirement: read_clipboard_image via FFI

The dynamic library SHALL export `read_clipboard_image(const char* handle, const char* request_json)` where `handle` is the context handle and `request_json` is `{"dest_dir":"<absolute directory>"}`. It SHALL read the current clipboard image, write it as a PNG file into that directory, and return `{"ok":true,"path":"<absolute path>","media_type":"image/png","width":W,"height":H,"bytes":N}`. When the clipboard holds no image it SHALL return `{"ok":false,"error":"clipboard has no image"}`. When the directory cannot be created or the file cannot be written it SHALL return `{"ok":false,"error":"<reason>"}`.

It MUST NOT open any window. The clipboard read SHALL be reachable through an injectable function so the test binary never calls Win32 `OpenClipboard`; the real Win32 path is covered only by the live test.

#### Scenario: Clipboard holds an image
- **WHEN** the injected clipboard source yields bitmap bytes and `read_clipboard_image` is called with a valid context handle and an existing directory
- **THEN** a new `.png` file exists in that directory and the JSON reports its absolute path, `image/png`, and non-zero width/height/bytes

#### Scenario: Clipboard holds text only
- **WHEN** the injected clipboard source yields nothing
- **THEN** the call returns `ok:false` with `error` equal to `clipboard has no image`, and no file is written

#### Scenario: Destination directory is created
- **WHEN** `dest_dir` points at a directory that does not exist yet
- **THEN** the directory is created recursively and the PNG is written inside it
