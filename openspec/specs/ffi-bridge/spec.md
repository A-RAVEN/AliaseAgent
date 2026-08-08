# FFI Bridge — Spec

## ADDED Requirements

### Requirement: Dynamic library loading
The system SHALL load the C++ Sidecar dynamic library at Flutter application startup using `dart:ffi`, supporting `.so` (Linux), `.dylib` (Mac), and `.dll` (Windows).

#### Scenario: Library found and loaded
- **WHEN** the Flutter app starts and the Sidecar dynamic library exists at the expected path
- **THEN** the library is loaded successfully and FFI function pointers are resolved

#### Scenario: Library not found
- **WHEN** the Flutter app starts and the Sidecar library is missing
- **THEN** the app displays an error message indicating the Sidecar component is not installed and exits gracefully

### Requirement: Send message via FFI
The system SHALL provide a C function `send_message` that accepts api key, base URL, model, system prompt, messages JSON, tools JSON, thinking mode (string), thinking effort (string), and four callback function pointers (on_chunk, on_tool_call, on_thinking, on_done). The function SHALL return a request ID integer.

#### Scenario: Successful invocation
- **WHEN** Dart calls `send_message` with valid parameters and callbacks
- **THEN** C++ side begins processing and returns a non-negative request ID

#### Scenario: Thinking mode and effort passed
- **WHEN** Dart calls `send_message` with `thinking_mode = "adaptive"` and `thinking_effort = "high"`
- **THEN** the C++ side receives both values and includes adaptive thinking configuration in the API request

#### Scenario: Thinking disabled
- **WHEN** Dart calls `send_message` with `thinking_mode = "disabled"` or empty string
- **THEN** the C++ side sends no thinking configuration and uses default max_tokens

#### Scenario: Invalid parameters
- **WHEN** Dart calls `send_message` with null or invalid parameters
- **THEN** C++ side returns a negative error code and calls on_done with error message

### Requirement: Streaming text callback
The system SHALL invoke the `on_chunk` callback from C++ to Dart for each text chunk received from the model API via SSE.

#### Scenario: Text chunk delivered
- **WHEN** C++ receives a `content_block_delta` event with `text_delta` type
- **THEN** the `on_chunk` callback is invoked with the text string, and Dart appends it to the UI

### Requirement: Tool call callback
The system SHALL invoke the `on_tool_call` callback from C++ to Dart when a tool use block is fully assembled. The callback SHALL fire at `content_block_stop`, after all `input_json_delta` partial fragments have been accumulated and parsed into the complete `input` JSON object.

#### Scenario: Tool call delivered
- **WHEN** C++ receives `content_block_start` (tool_use) → accumulates `input_json_delta` fragments → receives `content_block_stop` for that block index
- **THEN** the `on_tool_call` callback is invoked with the complete tool_use JSON (including `id`, `name`, and fully assembled `input`)

### Requirement: Thinking block callback
The system SHALL invoke the `on_thinking` callback from C++ to Dart when a thinking content block is complete. The callback SHALL fire at `content_block_stop` for the thinking block, after all `thinking_delta` and `signature_delta` fragments have been accumulated.

#### Scenario: Thinking block delivered
- **WHEN** C++ receives `content_block_start` (thinking) → accumulates `thinking_delta` (thinking text) and `signature_delta` (signature) → receives `content_block_stop` for the thinking block index
- **THEN** the `on_thinking` callback is invoked with a JSON object `{"type":"thinking","thinking":"...","signature":"..."}`

#### Scenario: No thinking in response
- **WHEN** the model response does not include extended thinking (or thinking is disabled)
- **THEN** the `on_thinking` callback is not invoked

### Requirement: Completion callback
The system SHALL invoke the `on_done` callback from C++ to Dart when the API response is complete (end of stream) or an error occurs. The callback SHALL include the `stop_reason` extracted from `message_delta`.

#### Scenario: Successful completion
- **WHEN** C++ receives `message_stop` event
- **THEN** `on_done` is called with code 0, empty error, and the `stop_reason` from `message_delta` (e.g. "end_turn", "tool_use", "max_tokens")

#### Scenario: Error completion
- **WHEN** C++ encounters an HTTP error or network failure
- **THEN** `on_done` is called with non-zero code, descriptive error message, and the last known `stop_reason` (may be empty)

### Requirement: Callback pointer lifetime safety
All string pointers passed to C→Dart callbacks SHALL remain valid beyond the C function return. Because `NativeCallable.listener` is asynchronous (Dart closures execute after the C function returns), pointers to local stack variables are forbidden.

#### Scenario: Error message pointer safety
- **WHEN** an error occurs during `send_message` and on_done is called with an error string
- **THEN** the error string pointer references memory in the sidecar's stable string pool (`pending_strings` deque member, cleared only at the start of the next request after the previous done was processed), not a local `std::string`

#### Scenario: String literal safety
- **WHEN** a fixed error message is passed to a callback
- **THEN** string literals are acceptable as they reside in static storage

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