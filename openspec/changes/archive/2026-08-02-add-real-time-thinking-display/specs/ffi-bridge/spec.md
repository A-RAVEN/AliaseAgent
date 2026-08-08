## ADDED Requirements

### Requirement: Callbacks created on main isolate
The Dart FFI bridge SHALL create the NativeCallable listeners (on_chunk, on_tool_call, on_thinking, on_done) on the main isolate and pass their native function pointer **addresses** (int) to the worker isolate via the isolate spawn arguments; the worker SHALL rebuild the pointers with `Pointer.fromAddress` before FFI calls. Passing the address integer rather than the Pointer object avoids reliance on undocumented Pointer sendability (official docs contradict: legacy `SendPort.send` exception lists include `Pointer`; current SDK 3.11.x empirically accepts it — the design does not depend on that). This ensures callback messages are delivered to the main isolate's event loop in real-time.

#### Scenario: Main isolate receives callbacks in real-time
- **WHEN** the C++ side invokes a callback during an active curl stream
- **THEN** the callback Dart closure executes on the main isolate immediately (not queued behind a blocked worker isolate)

#### Scenario: Worker uses rebuilt pointers
- **WHEN** the worker isolate invokes send_message via FFI
- **THEN** it rebuilds the native function pointers from their addresses (received via spawn args) and passes them

### Requirement: sendMessage completion via Completer
The Dart bridge SHALL complete the sendMessage Future when the on_done callback fires, replacing any assumption that the FFI call return implies completion. Completion SHALL be idempotent: if on_done fires more than once (the DeepSeek Anthropic-compatible endpoint emits both `message_stop` and a `[DONE]` marker on every successful response), the second and later on_done calls SHALL be ignored without error.

#### Scenario: Future completes on done
- **WHEN** on_done fires with code 0
- **THEN** the sendMessage Future completes successfully

#### Scenario: Future completes with error
- **WHEN** on_done fires with a non-zero code
- **THEN** the sendMessage Future completes with the error surfaced

#### Scenario: Duplicate done ignored
- **WHEN** on_done fires a second time (e.g., `message_stop` followed by `[DONE]` marker)
- **THEN** the second invocation is ignored; no StateError is thrown and the Future is not completed twice

### Requirement: Request serialization gate and cancellation
The Dart bridge SHALL serialize requests: a new `sendMessage` SHALL NOT start until the active request's done callback has been processed (or the active request has been cancelled and its done delivered). On timeout or session switch, the bridge SHALL invoke the C++ cancel path (FFI `cancel_request`) and wait for the resulting done before allowing a new request — it SHALL NOT fake a done callback. NativeCallable listeners SHALL be closed only after a real done (success or cancellation) has been received, never while the curl thread may still invoke callbacks.

#### Scenario: New request waits for active request
- **WHEN** `sendMessage` is called while a previous request is still streaming
- **THEN** the new call waits until the previous request's done has been processed, then proceeds

#### Scenario: Timeout triggers real cancellation
- **WHEN** the 120s receive timeout fires
- **THEN** `cancel_request()` is invoked, the C++ request terminates, and on_done(-1) is delivered by the curl thread before the bridge closes callables or allows a new request
