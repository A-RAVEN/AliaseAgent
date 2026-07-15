# Tasks: Debug Infrastructure for C++ Sidecar

## 1. Logger Enhancements (LOG_TRACE + Rotation)

- [x] 1.1 Add `TRACE` to `Logger::Level` enum and `level_str()` switch in `logger.h` / `logger.cpp`
- [x] 1.2 Add `std::atomic<int> current_level_` member to Logger; read from `ALIASAGENT_LOG_LEVEL` env var in `init()`; default to `INFO`
- [x] 1.3 Add `level()` accessor returning `current_level_.load()` for fast lock-free reads
- [x] 1.4 Implement `LOG_TRACE` macro with lazy evaluation: `do { if (Logger::instance().level() <= Logger::TRACE) Logger::instance().log(Logger::TRACE, msg); } while(0)`
- [x] 1.5 Refactor existing `LOG_INFO`/`LOG_WARN`/`LOG_ERR` macros to guard with level check before evaluation (same pattern as TRACE)
- [x] 1.6 Implement log rotation in `Logger::init()`: check `sidecar.log` size, if > 10MB rotate (`.log` → `.1.log` → `.2.log`, max 3 files)
- [x] 1.7 Add LOG_TRACE calls at key function entries in `model_gateway.cpp` (SSE event dispatch, tool assembly) and `tools.cpp` (entry/exit)
- [x] 1.8 Add LOG_TRACE calls in `sidecar_api.cpp` (send_message entry, tool function entries)

## 2. API Error Response Body Logging

- [x] 2.1 Add `std::string raw_body` member to `ModelGateway::Impl`; clear on each `execute()` call
- [x] 2.2 Modify `write_callback`: before SSE line parsing, append received data to `raw_body` (capped at 64KB)
- [x] 2.3 After `curl_easy_perform`, if `http_code >= 400`, log first 2048 bytes of `raw_body` via `LOG_ERR("API error body: " + ...)`
- [x] 2.4 Add unit test: MockServer returns HTTP 400 with JSON error body → verify `raw_body` captured and logged

## 3. Crash Diagnostics — Common Infrastructure

- [x] 3.1 Create `crash_handler.h` / `crash_handler.cpp` with `crash_log()` (reentrant: `WriteFile` to pre-opened handle, no mutex, no malloc)
- [x] 3.2 Add platform abstraction: `crash_init()` opens crash log handle; `crash_write_dump()` writes platform-specific dump
- [x] 3.3 Add `ensure_debug_infra()` to `sidecar_api.cpp`, called lazily on first function use (same pattern as `ensure_log()`)
- [x] 3.4 In `Logger::init()`, pre-create `~/.aliasagent/crashes/` directory and open crash log file handle
- [x] 3.5 Register `std::set_terminate` handler that calls `crash_log("terminate called")` + `crash_write_dump()` then re-throws
- [x] 3.6 Implement dump file lifecycle: enumerate `.dmp` files in crashes dir, delete oldest if count > 10

## 4. Crash Diagnostics — Windows (Minidump)

- [x] 4.1 Implement `crash_write_dump()` for Windows: dynamically load `dbghelp.dll` via `LoadLibrary`, resolve `MiniDumpWriteDump`
- [x] 4.2 Generate crash dump filename: `sidecar_crash_YYYYMMDD_HHMMSS.dmp`
- [x] 4.3 Register `SetUnhandledExceptionFilter` with handler that calls `crash_log()` + `MiniDumpWriteDump(MiniDumpNormal)`
- [x] 4.4 Write exception information (code, address, thread ID) to crash log before dump
- [x] 4.5 Dump FFI ring buffer (see Section 6) to crash log in the exception handler
- [ ] 4.6 Test: manual crash via intentional null deref in test build → verify `.dmp` produced + openable in WinDbg

## 5. Crash Diagnostics — Linux/macOS (Stack Trace)

- [x] 5.1 Implement `crash_write_dump()` for Linux/macOS: `sigaction(SIGSEGV, ...)` + `sigaction(SIGABRT, ...)`
- [x] 5.2 In signal handler: write signal info to crash log, call `backtrace()` + `backtrace_symbols()`, append to crash log
- [x] 5.3 Implement `crash_init()` for non-Windows: register signal handlers at `ensure_debug_infra()` time
- [ ] 5.4 Test: manual crash via `raise(SIGSEGV)` in test build → verify backtrace in crash log

## 6. FFI Boundary Tracing + Ring Buffer

- [x] 6.1 Add ring buffer struct to `ModelGateway::Impl`: `std::array<FfiEvent, 256>` + `std::atomic<size_t> write_idx` + `std::atomic_flag spinlock`
- [x] 6.2 Define `FfiEvent` struct: `enum Type { CHUNK, TOOL_CALL, THINKING, DONE }`, `size_t payload_size`, `uint64_t timestamp_ms`
- [x] 6.3 Push event atomically in `dispatch_events()` before each callback invocation
- [x] 6.4 Add `LOG_TRACE` call for each callback invocation: type + payload size + thread ID
- [x] 6.5 Add `LOG_TRACE` call in `sidecar_api.cpp` for Dart→C entries with sensitive parameter redaction (`api_key=<REDACTED>`)
- [x] 6.6 Add `dump_ring_buffer()` function (lock-free snapshot read) callable from crash handler via `crash_log()`
- [x] 6.7 Add Catch2 test: populate ring buffer with 300 events, verify wrap-around, verify dump output format

## 7. ASan Build Mode

- [x] 7.1 Create `vcpkg/triplets/x64-windows-asan-static.cmake` with `/fsanitize=address`, static CRT, static linkage
- [x] 7.2 Add `-DENABLE_ASAN=ON` option to sidecar `CMakeLists.txt`: when ON, add `/fsanitize=address` to `sidecar_tests` target only (NOT `sidecar` DLL)
- [x] 7.3 Ensure ASan flags include static runtime linking (no `clang_rt.asan_dynamic` dependency)
- [x] 7.4 Update `rebuild_sidecar.bat` to accept `--asan` flag → passes `-DENABLE_ASAN=ON` to CMake; validate only with Debug
- [x] 7.5 Update `rebuild_sidecar.ps1` similarly for PowerShell variant
- [ ] 7.6 Rebuild sidecar_tests with ASan, run full test suite, verify zero ASan violations
- [x] 7.7 Document ASan build instructions in `sidecar/test/README.md`

## 8. PDB / Symbol Management

- [x] 8.1 Verify MSVC generates `.pdb` files for Debug builds by default; confirm path in build output
- [x] 8.2 Document in `DEBUGGING.md`: how to locate PDB files, how to load into WinDbg for minidump analysis

## 9. Documentation

- [x] 9.1 Create `DEBUGGING.md` at project root with sections: Log Levels, Enabling ASan, Crash Diagnosis (minidump + WinDbg), FFI Tracing, API Error Logging
- [x] 9.2 Add `DEBUGGING.md` reference from `README.md` and `CLAUDE.md`
