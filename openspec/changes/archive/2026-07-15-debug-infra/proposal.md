# Debug Infrastructure for C++ Sidecar

## Summary

当前 C++ sidecar 的排障手段非常有限——只能靠 `sidecar.log` 日志、Dart 异常栈、以及源码阅读来定位问题。在 Phase 13 的悬空指针 bug 诊断中暴露了这个问题：一个本应 10 分钟定位的内存生命周期问题，花费了大量时间推演。

需要在 C→Dart FFI 边界加装调试基础设施。

## Motivation

| 问题 | 诊断耗时 | 有基础设施的话 |
|------|----------|----------------|
| `NativeCallable.listener` 悬空指针 crash | 源码推演 + 日志推测 | ASan 直接报 use-after-free，秒定位 |
| ABI 不匹配（2 参数 vs 3 参数） | 反复验证 DLL 版本 | 函数签名日志直接暴露 |
| 崩溃在 Dart 侧，C++ 侧无感知 | 只能从 Dart 异常反推 | C++ minidump + 符号化 |
| DeepSeek 400 错误消息不可见 | curl 外部测试才看到 | API 响应体日志 → 直接定位 |

## Proposed Scope

### 1. C++ 崩溃 Minidump（Windows）

- 注册 `SetUnhandledExceptionFilter` + `std::set_terminate`（覆盖 SEH 和 C++ 异常两条崩溃路径）
- 崩溃时写 minidump 到 `~/.aliasagent/crashes/sidecar_crash_YYYYMMDD_HHMMSS.dmp`
- **安全约束**：使用 `MiniDumpNormal`（仅栈+寄存器+已加载模块，不含堆内存），避免 API key 泄露
- 崩溃目录在 `Logger::init()` 时预创建（避免 handler 内 IO 重入）
- 崩溃处理器使用独立的可重入日志函数（直接 `WriteFile` Win32 API，**不使用 Logger mutex**）
- 保留最多 10 个 .dmp 文件，超出时删除最旧的
- Linux：`sigaction(SIGSEGV/SIGABRT)` + `backtrace()` + `backtrace_symbols()`（文本栈回溯，非 minidump）
- macOS：同 Linux 方案

### 2. ASan 构建模式

- CMake option `-DENABLE_ASAN=ON`
- 仅 Debug 模式可用
- MSVC：`/fsanitize=address` → 不依赖外部 ASan DLL（使用静态 ASan 运行时）
- **仅应用于 `sidecar_tests` 可执行文件**，不应用于被 Flutter 进程加载的 `sidecar.dll`
  - 原因：MSVC ASan 在 DLL 加载时保留 shadow memory，可能与 Dart VM 的内存布局冲突 → 进程中止
  - `sidecar_tests` 是独立进程，无此冲突，且覆盖所有生产代码（`logger.cpp + model_gateway.cpp + tools.cpp`）
- 自定义 vcpkg triplet `x64-windows-asan-static`：libcurl + 所有依赖以 `/fsanitize=address` 编译并静态链接
- rebuild 脚本：`rebuild_sidecar.bat Debug --asan` → 通过 `-DENABLE_ASAN=ON` 传递至 CMake
- CI 中 ASan 构建作为可选 step

### 3. FFI 边界追踪

- 在 C++ 侧的 `dispatch_events()` 和四个入口函数（`send_message`、`set_workspace`、`read_file`、`list_dir`）加 LOG_TRACE
- 回调调用时记录：回调类型 + 线程 ID
- **安全约束**：`send_message` 入口日志**不得**记录 `api_key` 参数值，替换为 `<REDACTED>`
- 环形缓冲区：固定在 256 条记录，始终开启（Debug 构建），线程安全（独立于 Logger mutex 的轻量级 spinlock）
- 内容：最近 256 次 C→Dart 回调调用记录（类型 + 参数大小 + 时间戳）

### 4. LOG_TRACE 级别

- `Logger::Level` 新增 `TRACE`
- 环境变量 `ALIASAGENT_LOG_LEVEL=trace` 在 `Logger::init()` 时读取并锁定（进程生命周期内不变，无需运行时切换）
- `LOG_TRACE` 宏实现：级别检查 **先于** 参数求值（避免即使禁用也在热路径上构造字符串）
- 同时重构现有 `LOG_INFO`/`LOG_WARN`/`LOG_ERR` 宏：在宏中加上级别检查，而非在 `log()` 方法内无条件执行

### 5. API 响应体日志（错误响应）

- `ModelGateway::Impl` 新增 `std::string raw_body` 成员（最大 64KB）
- `write_callback` 中：**先**追加到 `raw_body`，**再**按现有逻辑逐行 SSE 解析
- HTTP ≥400 时：将 `raw_body` 前 2048 字节输出到 `LOG_ERR`
- 不改变正常流 SSE 解析行为

### 6. 日志轮转

- `Logger::init()` 时检查 `sidecar.log` 大小
- 超过 10MB → 重命名为 `sidecar.1.log`，保留最后 3 个文件
- 轮转在 `init()` 中同步执行，之后所有日志操作继续 flush-only

### Scope Decisions（Open Questions 决议）

| 问题 | 决议 |
|------|------|
| Minidump 文件大小？ | `MiniDumpNormal`，典型大小 1-5MB，不含堆内存 |
| ASan 需要单独的 vcpkg triplet？ | 是。创建 `x64-windows-asan-static` triplet 用于 libcurl |
| Debug-only 还是始终启用？ | Minidump + ASan = Debug only；LOG_TRACE + API 响应体日志 = 始终编译，运行时环境变量控制 |

## Test Strategy

| 功能 | 验证方式 |
|------|----------|
| Minidump | 手动：Debug 构建中故意 null 指针解引用 → 验证 `.dmp` 产生 → WinDbg 可打开分析 |
| ASan | 自动化：`sidecar_tests` 以 ASan 模式构建运行 → 所有 53 个测试通过 + 无泄漏报告 |
| LOG_TRACE | 手动：`ALIASAGENT_LOG_LEVEL=trace` 启动 → 验证 TRACE 行出现在日志中 |
| API 响应体日志 | 自动化：MockServer 返回 HTTP 400 JSON → 验证 `LOG_ERR` 中包含响应体 |
| 日志轮转 | 单元测试：Logger `init()` 检测 10MB 文件 → 验证轮转执行 |
| FFI 环形缓冲区 | 自动化：`sidecar_tests` 验证 256 条记录封装 + 溢出回绕 |

## Non-Goals（不做）

- 不在 Dart 侧加性能 profiling（已有 Dart DevTools）
- 不加远程崩溃收集 / telemetry
- 不加 CI 集成（后续单独提案）
- 不添加 Worker isolate 错误处理（Dart 侧 isolate 管理 — 后续单独提案）
- 不添加 DLL 加载诊断（后续单独提案）
