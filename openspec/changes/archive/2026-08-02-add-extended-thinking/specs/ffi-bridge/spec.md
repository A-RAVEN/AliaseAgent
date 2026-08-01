## MODIFIED Requirements

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
