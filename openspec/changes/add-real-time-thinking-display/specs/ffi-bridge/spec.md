## ADDED Requirements

### Requirement: Callbacks created on main isolate
The Dart FFI bridge SHALL create the NativeCallable listeners (on_chunk, on_tool_call, on_thinking, on_done) on the main isolate and pass their native function pointers to the worker isolate via the isolate spawn arguments. This ensures callback messages are delivered to the main isolate's event loop in real-time.

#### Scenario: Main isolate receives callbacks in real-time
- **WHEN** the C++ side invokes a callback during an active curl stream
- **THEN** the callback Dart closure executes on the main isolate immediately (not queued behind a blocked worker isolate)

#### Scenario: Worker uses passed pointers
- **WHEN** the worker isolate invokes send_message via FFI
- **THEN** it passes the native function pointers created on the main isolate

### Requirement: sendMessage completion via Completer
The Dart bridge SHALL complete the sendMessage Future when the on_done callback fires, replacing any assumption that the FFI call return implies completion.

#### Scenario: Future completes on done
- **WHEN** on_done fires with code 0
- **THEN** the sendMessage Future completes successfully

#### Scenario: Future completes with error
- **WHEN** on_done fires with a non-zero code
- **THEN** the sendMessage Future completes with the error surfaced
