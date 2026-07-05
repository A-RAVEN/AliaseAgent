# Debug Infrastructure for C++ Sidecar

## Summary

当前 C++ sidecar 的排障手段非常有限——只能靠 `sidecar.log` 日志、Dart 异常栈、以及源码阅读来定位问题。在 Phase 13 的悬空指针 bug 诊断中暴露了这个问题：一个本应 10 分钟定位的内存生命周期问题，花费了大量时间推演。

需要在 C→Dart FFI 边界加装调试基础设施。

## Motivation

| 问题 | 诊断耗时 | 有基础设施的话 |
|------|----------|----------------|
| `NativeCallable.listener` 悬空指针 crash | 源码推演 + 日志推测 | ASan 直接报 use-after-free，秒定位 |
| ABI 不匹配（2 参数 vs 3 参数） | 反复验证 DLL 版本 | 函数签名日志 + 堆栈回溯直接暴露 |
| 崩溃在 Dart 侧，C++ 侧无感知 | 只能从 Dart 异常反推 | C++ minidump + 符号化 |

## Proposed Scope

### 1. C++ 崩溃堆栈回溯
- 注册 `SetUnhandledExceptionFilter`，崩溃时写 minidump（`.dmp`）
- 输出到 `~/.aliasagent/crashes/`
- 用 `dbghelp.dll` 捕获，后续用 WinDbg / VS 打开分析

### 2. ASan 构建模式
- CMake option `-DENABLE_ASAN=ON`
- 仅 Debug 模式可用
- rebuild 脚本加 `--asan` flag

### 3. FFI 边界追踪
- 每个 `NativeCallable.listener` 回调注册时打 log：参数签名 + 地址
- 回调被 C 调用时打 log：参数值 + 线程 ID
- 可选：简单的 ring buffer 记录最近 N 次 FFI 调用

### 4. LOG_TRACE 级别
- 当前只有 `LOG_INFO` / `LOG_WARN` / `LOG_ERR`
- 加 `LOG_TRACE` 用于函数出入口和关键变量值
- 运行时可通过环境变量切换级别：`ALIASAGENT_LOG_LEVEL=trace`

### 5. API 响应体日志
- HTTP 错误时（`http_code >= 400`）输出完整响应体到日志
- 当前仅记录 `HTTP 400` 行，无错误消息内容
- 例如：DeepSeek 返回 `{"error":{"message":"The content[].thinking ... must be passed back..."}}` 只有靠 curl 外部测试才看到，日志里完全不可见
- 响应体可能较大，建议限制前 2048 字节

## Non-Goals（不做）
- 不在 Dart 侧加性能 profiling（已有 Dart DevTools）
- 不加远程崩溃收集 / telemetry
- 不加 CI 集成

## Open Questions
- minidump 文件大小控制？（当前 `.dll` 约 1.3MB，`.dmp` 可能数 MB 起）
- ASan 构建模式是否需要单独的 vcpkg triplet？
- 是否需要始终启用，还是仅在 Debug 构建中？