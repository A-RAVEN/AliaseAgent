## Why

后续要让同一上下文的只读工具并行、让不同上下文与子 agent 同时执行，但 sidecar 的执行状态仍是进程级单例：结果返回缓冲、一个浏览器会话、一个工作区根、一个 spill 序号、一个模型网关。一旦真的并发，后一个调用会覆盖前一个的返回缓冲，后一个浏览器命令会打进前一个的页面。当前界面仍有全局 `_isStreaming`，本变更不是宣称界面已经支持多会话同时聊天，而是先补齐底层并发前提。

## What Changes

- 新增 `create_context(name)` 与 `dispose_context(handle)`。两者都返回 JSON：创建成功给出 `{"ok":true,"handle":"<原名>","created":true|false}`；空名字、`no-session`、测试保留前缀 `_it_` 返回可区分错误；销毁幂等。句柄是不透明字符串，**不假设它等于会话 id**。
- **BREAKING**：19 个既有导出改签名，上下文工具与模型请求首参加句柄，`cancel_request` 同时带句柄与请求 id。`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` 是机器/应用级接口，保持无句柄，避免启动时尚无上下文却无法初始化。
- **会话状态按上下文分**：工作区根、文件版本表 `g_observed`、spill 调用序号、模型网关、浏览器会话。每份上下文有状态锁与写操作闸门；`write_file` / `edit_file` 还共用进程级暂存文件锁，避免两个上下文互删对方的 `.tmp-*`。上下文注册表用共享引用与在途调用计数保证并发查找和销毁安全。
- **返回缓冲按调用线程分，不按上下文分**：18 个 `g_*_result` **以及 11 处函数局部 `err_static`** 全部改成线程本地存储。原因是同一上下文也可能并发调工具；只把缓冲搬进上下文仍会竞争，而锁在函数返回后就保护不到 Dart 的字符串复制。
- **销毁先排空再释放**：C++ `dispose_context` 先停止接收新调用，取消该上下文的模型请求，等待模型与工具调用结束，再关浏览器上下文、删 spill 目录并释放网关。Dart 侧还要等整轮对话 Future（含 `sendMessage` 之后的数据库写入）与后台压缩写库结束，才允许删会话数据。销毁中同名重建必须报 `context_disposing`，不能与旧上下文并存；取消失败导致的 `context_poisoned` 不得假装释放成功。
- **取消超时不再伪造模型 done**：现有「取消后 30 秒无 done 就合成 done 并放行」会破坏回调字符串寿命；改成让等待的 Future 以错误结束，并把该上下文标为 `context_poisoned`，在销毁前禁止新请求。
- spill 目录的键从 `spill_session` 字段改成首参句柄，`read_spill` 只允许读**本上下文**目录，且必须先做平台规范化（POSIX 用 `realpath`）再判断前缀；清理挪进 `dispose_context`。目录名保留集收紧为 `[a-z0-9_-]`，其余字节写成 `%XX`。序号在上下文创建时扫描本目录已有最大值后继续，避免重启从 1 覆盖旧引用。
- Dart 增加幂等的 `ensureContext`：覆盖启动恢复、切换、新建会话，只在 C++ 返回 `created:true` 时设工作区。`sendMessage`、普通取消、超时取消、摘要生成与摘要分段选择都传句柄；`_chain`、`_lastRequestId`、`_pendingRequests` 全部按上下文分。
- 浏览器仍共用一个 Python 子进程和一个 `Browser` 对象，只按上下文各开一个 `BrowserContext`；不得为每个上下文各 `chromium.launch()`。子进程每次重启产生新代次，上下文发现代次变化必须先收到一次「页面已消失」，未知上下文不得被静默创建。
- 明确共享而非假装全部上下文化：日志与崩溃设施、搜索配置与 provider 实例、Python/浏览器可用性探针、浏览器子进程及生命周期锁、全局请求 id 计数器继续共享；FFI 环形缓冲按上下文网关归属，但崩溃转储只读最近登记且仍存活的那一只，销毁后清空指针。每项的线程安全责任写进 design。

## Capabilities

### New Capabilities

- `context-handle`: 上下文的接口返回契约、注册与销毁生命周期、同上下文并发规则、按调用线程隔离的返回缓冲，以及机器级共享设施的边界。

### Modified Capabilities

- `ffi-bridge`: 新句柄导出；`send_message`、`read_image`、`read_clipboard_image`、`read_spill` 与取消接口的签名；Dart 侧建销、请求排队与取消都按上下文。
- `model-gateway`: 「全局只能有一个请求」改为「同一上下文串行、不同上下文可并行」；取消状态按上下文。
- `thinking-streaming`: 回调字符串的清理条件从全局请求锁改为该上下文的请求锁与排队闸门。
- `ffi-tracing`: 回调环形缓冲按上下文网关归属；崩溃转储只读最近登记且仍存活的那一只，销毁后清空指针。
- `browser-tool`: 每上下文一个浏览器会话；子进程代次变化与未知上下文必须可见。
- `command-tool`: spill 路径从 `<会话>` 改为按上下文句柄编码的目录。
- `tool-execution-tests`: 工作区断言从进程级 `g_workspace` 改为每上下文；同步 spill 路径、引用尾部位置与跨上下文读回限制。
- `tool-output-spill`: spill 序号按上下文且同上下文并发不撞；`read_spill` 只能读本上下文目录；销毁时清理。
- `real-sidecar-tests`: 真实动态库测试先建上下文，机器级接口与上下文接口分开调用。

## Impact

- **C++ 接口**：`sidecar/include/sidecar_api.h` 现有 23 个导出：19 个改签名，4 个保持原样（`ping` / `browser_available` / `ensure_search_infra` / `get_search_providers`），另增 2 个上下文导出。实现涉及 `sidecar_api.cpp`、`tools.cpp`、`model_gateway.cpp`（含 `g_ffi_ring` 的销毁清空与按上下文路由环形缓冲）、`browser.cpp`、`spill.cpp`、`search_provider.cpp`、新上下文注册表与新增的 `result_buffer`/`context_api` 源码；后两者要同时编进 `sidecar_tests`。
- **Python 浏览器子进程**：`scripts/browser_worker.py` 从「每个 `BrowserSession` 自己 launch 一个 Edge」改成「一个 `Browser` + 按上下文多份 `BrowserContext`」，并对未知上下文、`stats`、`close` 给出明确协议。
- **Dart 侧**：`lib/services/sidecar_bridge.dart`、`lib/main.dart`、`lib/services/spill_paths.dart`；摘要接口 `lib/services/compaction/summary_provider.dart`、`model_summary_provider.dart`、`seam_selector.dart` 也要带会话句柄；`test/integration/helpers/fake_sidecar.dart` 同步接口。
- **测试**：`sidecar/test/`、`test/unit/`、`test/integration/`、`integration_test/` 覆盖不同上下文与同一上下文并发、销毁中删除、恢复会话、浏览器代次变化。
- **不受影响**：消息与摘要的存储（本来就按 `session_id` 隔离）、模型 HTTP 请求体格式、界面布局。
- **范围边界**：本变更验收的是底层两个上下文可同时执行；不开放界面层多会话同时发送，现有 `_isStreaming` 交互另立变更。
