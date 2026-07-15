# Design: Debug Infrastructure for C++ Sidecar

## Context

AliasAgent 的 C++ sidecar 作为 Flutter 进程内 DLL 运行。当前调试能力有限：仅 `sidecar.log`（INFO/WARN/ERR 三级）、Dart 异常堆栈。Phase 13 的诊断过程暴露了核心痛点的缺失：悬空指针诊断、API 错误消息不可见、无崩溃后诊断数据。

Sidecar 通过 `dart:ffi` 加载，`send_message` 在 worker isolate 上执行（阻塞 HTTP + SSE 流），工具调用在主 isolate 上同步执行。C++ 侧崩溃会立即终止整个 Flutter 进程，无任何诊断 artifact。

## Goals / Non-Goals

**Goals:**
- C++ 崩溃时自动生成可分析的诊断数据（Windows minidump，Linux/macOS 栈回溯）
- 内存安全 bug 检测（ASan 构建模式，作用域限定于 `sidecar_tests`）
- C↔Dart FFI 边界调用可追踪（环形缓冲区 + LOG_TRACE）
- 更细粒度的日志级别控制（LOG_TRACE，环境变量开关）
- HTTP 错误响应内容可见（API 响应体日志，2048 字节截断）
- 日志文件大小管理（轮转：10MB × 3）

**Non-Goals:**
- 不在 Dart 侧添加性能分析（已有 Dart DevTools）
- 不添加远程崩溃收集或遥测
- 不添加 CI 集成（后续单独提案）
- 不在 Flutter 进程内用 ASan 检测 sidecar.dll（内存布局冲突风险）

## Decisions

### D1: Minidump 范围 — `MiniDumpNormal`，不含堆内存

**Decision**: 使用 `MiniDumpNormal`（仅栈 + 寄存器 + 已加载模块列表 + 线程信息），**不使用** `MiniDumpWithFullMemory` 或 `MiniDumpWithDataSegs`。

**Rationale**: 全量内存转储（`MiniDumpWithFullMemory`）会捕获 API key（在栈/堆的 HTTP header 字符串中），造成凭据泄露。`MiniDumpNormal` 典型大小为 1-5MB，足以通过 WinDbg 解析崩溃时的调用栈和变量值（栈上的局部变量已包含在内），无需堆转储。未来如需更多内存数据，可通过 `MiniDumpFilterMemory` 精确过滤敏感区域。

**Alternatives considered**:
- `MiniDumpWithFullMemory`：最全面，但包含 API key 明文 → **不安全**
- `MiniDumpFilterMemory` + 排除敏感堆范围：实现复杂，API key 可能在多个堆位置 → **过度工程化**
- 在崩溃前擦除 API key：`api_key` 是 Dart 管理的原始指针，C++ 无法可靠擦除 → **不可行**

### D2: 崩溃处理器可重入性 — 独立于 Logger 的崩溃日志路径

**Decision**: 崩溃处理器（`UnhandledExceptionFilter` / `terminate_handler`）中的日志调用使用专用的可重入函数 `crash_log(const char* msg)`，该函数通过 `WriteFile` Win32 API 直接写入预打开的 `CRASH_LOG_FILE` 句柄，不使用互斥锁、不调用 `malloc`、不访问 `Logger`。

**Rationale**: 崩溃可能发生在持有 `Logger::mutex_` 时。如果崩溃处理器调用 `LOG_ERR`，会尝试获取同一互斥锁 → 死锁。`WriteFile` 是异步 IO，内核处理同步，调用方无需锁保护。崩溃目录（`~/.aliasagent/crashes/`）在 `Logger::init()` 期间预创建，这样崩溃处理器就不需要调用 `mkdir`（在崩溃上下文中不可重入）。

**Implementation sketch**:
```cpp
// Pre-opened at Logger::init() time
static HANDLE g_crash_log_handle = INVALID_HANDLE_VALUE;

void crash_log(const char* msg) {
    if (g_crash_log_handle == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(g_crash_log_handle, msg, (DWORD)strlen(msg), &written, nullptr);
    WriteFile(g_crash_log_handle, "\r\n", 2, &written, nullptr);
}
```

### D3: ASan 范围 — 仅 `sidecar_tests`，非 sidecar.dll

**Decision**: ASan（`/fsanitize=address`）仅应用于 `sidecar_tests` 独立可执行文件，**不**应用于在 Flutter 进程中加载的 `sidecar.dll`。

**Rationale**: MSVC ASan 在 DLL 加载期间保留 shadow memory（0x10007fff8000 固定范围）。Dart VM 也保留大量内存用于堆和代码缓存。当 ASan 的 shadow 内存保留与 Dart 的现有映射重叠时，进程在 `DynamicLibrary.open()` 时崩溃，报错 "Shadow memory range interleaves with an existing memory mapping"。Google sanitizers issue #386 记录了 JNI（与 Dart FFI 最接近的类比）的完全相同错误，结果为 WontFix。

`sidecar_tests` 链接了所有三个生产源文件（`logger.cpp`、`model_gateway.cpp`、`tools.cpp`），并在独立进程中运行 → 不存在与 Dart VM 的内存冲突，同时捕获这些源中的所有 ASan bug。

**vcpkg triplet**: 需要自定义 triplet `x64-windows-asan-static`，以 `/fsanitize=address` + 静态 CRT（`/MT`）编译 libcurl，避免在运行时需要 ASan DLL。

### D4: 响应体捕获 — 有界原始缓冲区，SSE 解析前追加

**Decision**: `ModelGateway::Impl` 中新增成员 `std::string raw_body`（最大 64KB）。在 `write_callback` 中，数据**先**追加到 `raw_body`，**再**逐字符 SSE 解析。`curl_easy_perform()` 返回后，如果 `http_code >= 400`，将 `raw_body` 的前 2048 字节输出到 `LOG_ERR`。

**Rationale**: 当前 `write_callback` 只解析 SSE `data:` 行，静默丢弃其他所有内容（包括错误响应 JSON）。`libcurl` 仅支持单一 `CURLOPT_WRITEFUNCTION`，因此 SSE 解析和原始捕获必须共享同一回调。64KB 上限可防止在无限流中耗尽内存；2048 字节截断可防止日志膨胀，同时捕获大多数 API 错误消息。

### D5: LOG_TRACE 宏 — 求值前进行级别检查

**Decision**: `LOG_TRACE` 宏实现为一个 if-guard，在参数求值**之前**检查日志级别：
```cpp
#define LOG_TRACE(msg) \
    do { if (Logger::instance().level() <= Logger::TRACE) \
         Logger::instance().log(Logger::TRACE, msg); } while(0)
```

**Rationale**: 现有的 `LOG_INFO("SSE: text=\"" + text + "\"")` 模式会急切地求值字符串拼接，即使日志被禁用也会进行分配。通过在 `do/while` 块内的级别检查后放置 `log()` 调用，`msg` 参数仅在跟踪启用时才会被求值。级别本身存储在 `std::atomic<int>` 中，无需上锁即可实现廉价读取。

### D6: FFI 环形缓冲区 — 256 条记录，始终开启

**Decision**: 在 `ModelGateway::Impl` 中实现一个固定大小 256 条记录的环形缓冲区，记录最近的 FFI 回调调用。由独立的轻量级 spinlock（`std::atomic_flag`）保护，与 Logger 互斥锁隔离。在 Debug 构建中始终开启；崩溃时将内容写入崩溃日志。

**Rationale**: 没有环形缓冲区，FFI 追踪就只是更冗长的日志行——在流式传输期间丢失在噪声中，在崩溃时丢失在缓冲刷新延迟中。环形缓冲区提供了结构化、始终可用的最近 256 次跨边界调用的记录。"可选"方案很容易被废弃，且永远不会被实现。

### D7: 崩溃处理器注册 — 早期，DLL 加载后

**Decision**: 在 `sidecar_api.cpp` 中添加 `void ensure_debug_infra()` 函数，被 `send_message()` 和工具函数延迟调用。该函数注册 `SetUnhandledExceptionFilter` + `std::set_terminate`，并初始化崩溃日志句柄。**不在** `DllMain` 中注册（DLL 加载时 CRT 未完全就绪）。

**Rationale**: `sidecar_api.cpp` 已有 `ensure_log()` 懒初始化模式；`ensure_debug_infra()` 遵循相同模式。`SetUnhandledExceptionFilter` 捕获 SEH 异常（访问冲突、除零），`std::set_terminate` 捕获 C++ 未捕获异常。两者同时注册以实现完整覆盖。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Minidump 栈跟踪在无 PDB 情况下部分有用 | MSVC 默认为 Debug 构建生成 PDB；文档说明如何定位和加载 |
| ASan 产生误报（例如 libcurl 自定义分配器） | ASan 范围仅限 `sidecar_tests`；检测到的任何 bug 都会进行审核 |
| 环形缓冲区 spinlock 有争议 | 256 条记录 → 竞争极低；回调是同步且单线程的（`curl_easy_perform` 不创建线程） |
| 日志轮转暂时阻塞 `init()` | 轮转在启动时发生一次；日志文件可能增长到 ~10MB，重命名是即时的 |
| 崩溃处理器中的 `WriteFile` 可能在被杀死的进程中永远不会刷新 | 这是 crash-time 日志记录固有的问题；`WriteFile` 是内核调度的，在大多数崩溃场景中会在进程终止前完成 |
| ASan vcpkg triplet 在 vcpkg 更新时可能需要维护 | triplet 文件是项目的源代码；vcpkg 更新时像任何其他构建配置一样进行测试 |
