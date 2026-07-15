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
The system SHALL provide a C function `send_message` that accepts agent type, model, system prompt, messages JSON, tools JSON, and four callback function pointers (on_chunk, on_tool_call, on_thinking, on_done). The function SHALL return a request ID integer.

#### Scenario: Successful invocation
- **WHEN** Dart calls `send_message` with valid parameters and callbacks
- **THEN** C++ side begins processing and returns a non-negative request ID

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
- **THEN** the error string pointer references memory in Impl member (`last_error`) or static storage, not a local `std::string`

#### Scenario: String literal safety
- **WHEN** a fixed error message is passed to a callback
- **THEN** string literals are acceptable as they reside in static storage