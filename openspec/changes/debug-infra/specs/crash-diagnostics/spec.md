# Crash Diagnostics — Spec

## ADDED Requirements

### Requirement: Unhandled exception filter registration
The C++ sidecar SHALL register a crash handler via `SetUnhandledExceptionFilter` and `std::set_terminate` on first use of any sidecar function, covering both SEH exceptions (access violation, divide-by-zero) and C++ uncaught exceptions.

#### Scenario: Crash handler registered on first send_message
- **WHEN** any sidecar function is called for the first time (e.g., `send_message` or `set_workspace`)
- **THEN** `ensure_debug_infra()` is called, registering both `SetUnhandledExceptionFilter` and `std::set_terminate`

#### Scenario: Crash handler idempotent
- **WHEN** sidecar functions are called multiple times
- **THEN** the crash handler is registered only once (idempotent guard)

### Requirement: Minidump generation on crash (Windows)
On Windows, the crash handler SHALL write a minidump file using `MiniDumpWriteDump` with `MiniDumpNormal` dump type (call stacks + registers + loaded modules, no heap memory).

#### Scenario: Access violation produces minidump
- **WHEN** an unhandled access violation occurs in C++ sidecar code
- **THEN** a minidump file is written to `~/.aliasagent/crashes/sidecar_crash_YYYYMMDD_HHMMSS.dmp`
- **AND** the crash log file records the crash timestamp and exception code

#### Scenario: C++ uncaught exception produces minidump
- **WHEN** an uncaught C++ exception propagates through `extern "C"` boundary
- **THEN** `std::terminate` handler writes a minidump before process exit

#### Scenario: Minidump does not contain heap memory
- **WHEN** a crash occurs during `send_message` while `api_key` is in memory
- **THEN** the resulting `.dmp` file does NOT contain the API key in extractable form (no heap dump)

### Requirement: Crash directory pre-creation
The crash output directory SHALL be created at `Logger::init()` time, before any crash can occur.

#### Scenario: Crashes directory exists before sidecar use
- **WHEN** `Logger::init()` completes
- **THEN** the directory `~/.aliasagent/crashes/` exists

### Requirement: Crash log using reentrant writer
The crash handler SHALL use a dedicated crash log function that writes via `WriteFile` to a pre-opened file handle, with no mutex, no heap allocation, and no Logger dependency.

#### Scenario: Crash during logging does not deadlock
- **WHEN** a crash occurs while `Logger::mutex_` is held (e.g., during a `LOG_INFO` call)
- **THEN** the crash handler successfully writes the crash record without deadlocking

#### Scenario: Crash log written to crashes directory
- **WHEN** a crash is handled
- **THEN** a crash log entry is appended to `~/.aliasagent/crashes/crash.log` with timestamp and exception information

### Requirement: Crash dump lifecycle management
The system SHALL retain at most 10 crash dump files, deleting the oldest when the limit is exceeded.

#### Scenario: Old dumps rotated out
- **WHEN** a new crash dump is written and the total count exceeds 10
- **THEN** the oldest `.dmp` file in the crashes directory is deleted

### Requirement: Cross-platform crash handling (Linux/macOS)
On Linux and macOS, the crash handler SHALL register signal handlers for `SIGSEGV` and `SIGABRT`, and produce a text stack trace using `backtrace()` / `backtrace_symbols()`.

#### Scenario: Signal produces text backtrace
- **WHEN** a segmentation fault occurs on Linux
- **THEN** a text backtrace with function names is appended to the crash log file
