# FFI Boundary Tracing — Spec

## ADDED Requirements

### Requirement: C-to-Dart callback invocation tracing
The sidecar SHALL log each invocation of a C-to-Dart callback (on_chunk, on_tool_call, on_thinking, on_done) at TRACE level with callback type and thread ID.

#### Scenario: on_chunk callback traced
- **WHEN** `dispatch_events()` invokes `on_chunk`
- **THEN** a TRACE log entry is written: `"FFI: on_chunk(len=<N>) thread=<TID>"`

#### Scenario: on_tool_call callback traced
- **WHEN** `dispatch_events()` invokes `on_tool_call`
- **THEN** a TRACE log entry is written: `"FFI: on_tool_call(len=<N>) thread=<TID>"`

### Requirement: Dart-to-C entry function tracing
The sidecar SHALL log each entry into a C function called from Dart (`send_message`, `set_workspace`, `read_file`, `list_dir`) at TRACE level.

#### Scenario: send_message entry traced
- **WHEN** `send_message` is called from Dart
- **THEN** a TRACE log entry is written with model name and message count
- **AND** the `api_key` parameter is redacted as `<REDACTED>`

#### Scenario: set_workspace entry traced
- **WHEN** `set_workspace` is called from Dart
- **THEN** a TRACE log entry is written with the workspace path

#### Scenario: read_file entry traced
- **WHEN** `read_file` is called from Dart
- **THEN** a TRACE log entry is written with the file path

### Requirement: FFI call ring buffer
The sidecar SHALL maintain a fixed-size ring buffer of the last 256 C-to-Dart callback invocations, recording callback type, parameter size, and timestamp.

#### Scenario: Ring buffer records callback invocations
- **WHEN** each C-to-Dart callback is invoked via `dispatch_events()`
- **THEN** an entry is pushed into the ring buffer containing: callback type (`chunk`/`tool_call`/`thinking`/`done`), payload byte size, and monotonic timestamp

#### Scenario: Ring buffer wraps at capacity
- **WHEN** more than 256 callbacks are invoked
- **THEN** the oldest entries are overwritten (circular buffer behavior)

#### Scenario: Ring buffer thread safety
- **WHEN** ring buffer push occurs from any thread
- **THEN** access is guarded by a lightweight spinlock (`std::atomic_flag`), independent of the Logger mutex

### Requirement: Ring buffer dump on crash
On crash, the crash handler SHALL dump the entire ring buffer contents to the crash log.

#### Scenario: Crash after FFI calls
- **WHEN** a crash occurs after several FFI callback invocations
- **THEN** the crash log contains "Last N FFI calls:" followed by the ring buffer contents with timestamps

#### Scenario: Crash before any FFI calls
- **WHEN** a crash occurs before any FFI callbacks were invoked
- **THEN** the crash log contains "FFI ring buffer: empty"
