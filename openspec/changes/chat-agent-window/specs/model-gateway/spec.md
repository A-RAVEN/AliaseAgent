# Model Gateway — Spec

## ADDED Requirements

### Requirement: Anthropic Messages API call
The C++ Sidecar SHALL construct and send HTTP POST requests to the Anthropic Messages API endpoint with the correct headers (`x-api-key`, `anthropic-version`, `content-type`) and JSON body (model, messages, system, tools, stream: true).

#### Scenario: Successful API call
- **WHEN** `send_message` is invoked with valid parameters
- **THEN** an HTTP POST is sent to `https://api.anthropic.com/v1/messages` with streaming enabled

#### Scenario: API key from config
- **WHEN** constructing the request
- **THEN** the API key is read from the provider configuration passed by Dart

#### Scenario: Invalid API key
- **WHEN** the API returns HTTP 401
- **THEN** `on_done` is called with error code and "Authentication failed" message

### Requirement: SSE stream parsing
The C++ Sidecar SHALL parse the Server-Sent Events (SSE) stream from the Anthropic API response, extracting `data:` lines and decoding JSON event objects.

#### Scenario: Parse text delta
- **WHEN** SSE event contains `{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello"}}`
- **THEN** `on_chunk` callback is invoked with "Hello"

#### Scenario: Parse message stop
- **WHEN** SSE event contains `{"type": "message_stop"}`
- **THEN** `on_done` callback is invoked with code 0

#### Scenario: Parse error event
- **WHEN** SSE event contains `{"type": "error", "error": {"message": "..."}}`
- **THEN** `on_done` callback is invoked with non-zero code and the error message

### Requirement: Tool use detection
The C++ Sidecar SHALL detect `content_block_start` events with `tool_use` type and invoke the `on_tool_call` callback with the tool name and input parameters.

#### Scenario: Tool use requested
- **WHEN** SSE event contains `{"type": "content_block_start", "content_block": {"type": "tool_use", "name": "read_file", "input": {...}}}`
- **THEN** `on_tool_call` is invoked with JSON containing tool name and input

### Requirement: HTTP timeout
The C++ Sidecar SHALL enforce a configurable HTTP timeout (default 120 seconds) for the API connection.

#### Scenario: Request timeout
- **WHEN** the API does not respond within the timeout period
- **THEN** the connection is closed and `on_done` is called with a timeout error

### Requirement: C++ logging
The C++ Sidecar SHALL write diagnostic logs to `~/.aliasagent/logs/` directory, recording all key events during API communication for debugging purposes.

#### Scenario: Request logging
- **WHEN** an HTTP request is initiated
- **THEN** the request URL, HTTP method, and model name are written to the log

#### Scenario: Response status logging
- **WHEN** an HTTP response is received
- **THEN** the response status code and headers are written to the log

#### Scenario: SSE event type logging
- **WHEN** each SSE event is received and parsed
- **THEN** the event type (e.g. `content_block_delta`, `message_stop`, `error`) is written to the log

#### Scenario: Unrecognized SSE event
- **WHEN** an SSE event with an unrecognized or unexpected event type is received
- **THEN** a warning is written to the log with the raw event type string

#### Scenario: JSON parse failure
- **WHEN** SSE event data fails to parse as valid JSON
- **THEN** an error is written to the log with the raw data fragment (truncated to 512 characters)

#### Scenario: Non-200 HTTP response
- **WHEN** the API returns a non-200 HTTP status code
- **THEN** the full response body is written to the log (truncated to 4096 characters)