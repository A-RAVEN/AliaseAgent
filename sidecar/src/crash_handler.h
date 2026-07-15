#ifndef CRASH_HANDLER_H
#define CRASH_HANDLER_H

/// Reentrant crash log: writes directly to pre-opened file handle.
/// No mutex, no heap allocation, no Logger dependency — safe to call
/// from signal/exception handlers even if Logger::mutex_ is held.
void crash_log(const char* msg);

/// Platform-specific crash dump (Windows: minidump; Linux/macOS: backtrace).
void crash_write_dump();

/// Initialize crash infrastructure: open crash log handle, register handlers.
/// Idempotent — safe to call multiple times.
void crash_init(const char* crash_dir);

/// Enumerate .dmp files in crash_dir, delete oldest if count > max_files.
void crash_rotate_dumps(const char* crash_dir, int max_files);

/// Dump FFI ring buffer contents to crash log (defined in model_gateway.cpp).
/// Called by crash handler after writing exception info.
void dump_ffi_ring_buffer();

#endif // CRASH_HANDLER_H
