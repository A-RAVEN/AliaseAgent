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
The system SHALL provide a C function `send_message` that accepts agent type, model, system prompt, messages JSON, tools JSON, and three callback function pointers (on_chunk, on_tool_call, on_done). The function SHALL return a request ID integer.

#### Scenario: Successful invocation
- **WHEN** Dart calls `send_message` with valid parameters and callbacks
- **THEN** C++ side begins processing and returns a non-negative request ID

#### Scenario: Invalid parameters
- **WHEN** Dart calls `send_message` with null or invalid parameters
- **THEN** C++ side returns a negative error code and calls on_done with error message

### Requirement: Streaming text callback
The system SHALL invoke the `on_chunk` callback from C++ to Dart for each text chunk received from the model API via SSE.

#### Scenario: Text chunk delivered
- **WHEN** C++ receives a `content_block_delta` event with `text` delta
- **THEN** the `on_chunk` callback is invoked with the text string, and Dart appends it to the UI

### Requirement: Tool call callback
The system SHALL invoke the `on_tool_call` callback from C++ to Dart when the model requests a tool execution.

#### Scenario: Tool call delivered
- **WHEN** C++ receives a `content_block_start` event with `tool_use` type
- **THEN** the `on_tool_call` callback is invoked with the tool name and parameters as JSON, and Dart displays it in the UI

### Requirement: Completion callback
The system SHALL invoke the `on_done` callback from C++ to Dart when the API response is complete (end of stream) or an error occurs.

#### Scenario: Successful completion
- **WHEN** C++ receives `message_stop` event
- **THEN** `on_done` is called with code 0 and null error

#### Scenario: Error completion
- **WHEN** C++ encounters an HTTP error or network failure
- **THEN** `on_done` is called with non-zero code and descriptive error message