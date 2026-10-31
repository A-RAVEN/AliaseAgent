## MODIFIED Requirements

### Requirement: FFI call ring buffer
Each context's model gateway SHALL maintain a fixed-size ring buffer of the last 256 C-to-Dart callback invocations belonging to that context, recording callback type, parameter size, and timestamp. Contexts SHALL NOT write into one another's ring buffer.

#### Scenario: Ring buffer records callback invocations
- **WHEN** each C-to-Dart callback is invoked via `dispatch_events()` for a request on a context
- **THEN** an entry is pushed into that context's gateway ring buffer containing: callback type (`chunk`/`tool_call`/`thinking`/`done`), payload byte size, and monotonic timestamp

#### Scenario: Ring buffer wraps at capacity
- **WHEN** more than 256 callbacks are invoked on one context
- **THEN** that ring buffer's oldest entries are overwritten (circular buffer behavior)

#### Scenario: Ring buffer thread safety
- **WHEN** ring buffer push occurs from any thread
- **THEN** access is guarded by a lightweight spinlock (`std::atomic_flag`), independent of the Logger mutex

#### Scenario: Another context keeps its own entries
- **WHEN** context 甲 and context 乙 each complete a request
- **THEN** 甲's ring buffer SHALL contain only 甲's callbacks and 乙's SHALL contain only 乙's; neither SHALL clear or overwrite the other

### Requirement: Ring buffer dump on crash
On crash, the crash handler SHALL dump the ring buffer of the most recently registered live gateway to the crash log. Registration and lookup SHALL be guarded by one mutex; a destroyed gateway SHALL clear the pointer if it still points at that gateway, so the dump never dereferences freed memory.

#### Scenario: Crash after FFI calls
- **WHEN** a crash occurs after several FFI callback invocations
- **THEN** the crash log contains "Last N FFI calls:" followed by the most recently registered context's ring buffer contents with timestamps

#### Scenario: Crash before any FFI calls
- **WHEN** a crash occurs before any FFI callbacks were invoked
- **THEN** the crash log contains "FFI ring buffer: empty"

#### Scenario: Last gateway destroyed before crash
- **WHEN** the only contexts have been disposed and then a crash occurs
- **THEN** the crash log contains "FFI ring buffer: empty" and does not read the disposed gateway's memory
