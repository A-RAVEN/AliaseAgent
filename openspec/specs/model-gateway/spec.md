# Model Gateway — Spec

## ADDED Requirements

### Requirement: Anthropic-compatible Messages API call
The C++ Sidecar SHALL construct and send HTTP POST requests to the Messages API endpoint with the correct headers (`x-api-key`, `anthropic-version`, `content-type`) and JSON body (model, messages, system, tools, stream: true). The base URL is configurable to support both Anthropic official (`https://api.anthropic.com`) and DeepSeek Anthropic-compatible (`https://api.deepseek.com/anthropic`) endpoints.

#### Scenario: Successful API call
- **WHEN** `send_message` is invoked with valid parameters
- **THEN** an HTTP POST is sent to `{base_url}/v1/messages` with streaming enabled

#### Scenario: API key from config
- **WHEN** constructing the request
- **THEN** the API key is read from the provider configuration passed by Dart

#### Scenario: Invalid API key
- **WHEN** the API returns HTTP 401
- **THEN** `on_done` is called with error code and "Authentication failed" message

### Requirement: SSE stream parsing
The C++ Sidecar SHALL parse the Server-Sent Events (SSE) stream from the API response, extracting `data:` lines and decoding JSON event objects.

#### Scenario: Parse text delta
- **WHEN** SSE event contains `{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello"}}`
- **THEN** `on_chunk` callback is invoked with "Hello"

#### Scenario: Parse message stop
- **WHEN** SSE event contains `{"type": "message_stop"}`
- **THEN** `on_done` callback is invoked with code 0 and the `stop_reason` accumulated from `message_delta`

#### Scenario: Parse error event
- **WHEN** SSE event contains `{"type": "error", "error": {"message": "..."}}`
- **THEN** `on_done` callback is invoked with non-zero code and the error message

### Requirement: input_json_delta accumulation
The C++ Sidecar SHALL accumulate `input_json_delta.partial_json` fragments per content block index, and SHALL only invoke `on_tool_call` at `content_block_stop` after assembling the complete `input` JSON object.

#### Scenario: Single input_json_delta
- **WHEN** SSE stream contains `content_block_start` (tool_use, input:{}) → `input_json_delta` (full JSON) → `content_block_stop`
- **THEN** the complete input JSON is parsed and included in the `on_tool_call` payload

#### Scenario: Fragmented input_json_delta
- **WHEN** SSE stream contains multiple `input_json_delta` events for the same block index with incremental `partial_json` strings
- **THEN** all fragments are concatenated and parsed as a single JSON object at `content_block_stop`

### Requirement: Tool use detection
The C++ Sidecar SHALL detect `content_block_start` events with `tool_use` type, track the block index, accumulate `input_json_delta` fragments, and invoke `on_tool_call` at `content_block_stop` with the fully assembled tool_use JSON (including `id`, `name`, and complete `input` object).

#### Scenario: Tool use requested
- **WHEN** SSE stream contains `content_block_start` (tool_use) → `input_json_delta` (accumulated) → `content_block_stop`
- **THEN** `on_tool_call` is invoked with JSON containing tool id, name, and fully resolved input parameters

### Requirement: Thinking block handling
The C++ Sidecar SHALL detect `content_block_start` events with `thinking` type, accumulate `thinking_delta.thinking` and `signature_delta.signature` per block index, and invoke `on_thinking` at `content_block_stop` with the complete thinking block JSON `{"type":"thinking","thinking":"...","signature":"..."}`.

#### Scenario: Thinking block with signature
- **WHEN** SSE stream contains `content_block_start` (thinking) → `thinking_delta` ×N → `signature_delta` → `content_block_stop`
- **THEN** `on_thinking` is invoked with complete thinking and signature fields

#### Scenario: No thinking in response
- **WHEN** the model is not using extended thinking or thinking is disabled
- **THEN** no `on_thinking` callback is invoked, no thinking-related warnings are logged

### Requirement: stop_reason extraction
The C++ Sidecar SHALL extract `stop_reason` from the `message_delta` SSE event and pass it to the `on_done` callback.

#### Scenario: tool_use stop reason
- **WHEN** `message_delta` contains `delta.stop_reason: "tool_use"`
- **THEN** `on_done` receives `stop_reason = "tool_use"`

#### Scenario: end_turn stop reason
- **WHEN** `message_delta` contains `delta.stop_reason: "end_turn"`
- **THEN** `on_done` receives `stop_reason = "end_turn"`

### Requirement: Content array format
When building subsequent API requests, the system SHALL consistently use the content block array format `[{"type":"text","text":"..."}, ...]` for all messages. Single content blocks SHALL NOT be unwrapped to bare strings or bare objects.

#### Scenario: Assistant message with text only
- **WHEN** an assistant message contains only text
- **THEN** its content is `[{"type":"text","text":"..."}]`, not a bare string

#### Scenario: Assistant message with tool_use
- **WHEN** an assistant message contains a tool_use block
- **THEN** its content is `[{"type":"tool_use","id":"...","name":"...","input":{...}}]`, not a bare tool_use object

#### Scenario: Tool result message content
- **WHEN** a tool result is sent back to the API
- **THEN** its content is `[{"type":"tool_result","tool_use_id":"...","content":"..."}]`, not a bare tool_result object

### Requirement: HTTP timeout
The C++ Sidecar SHALL enforce a configurable HTTP timeout (default 120 seconds) for the API connection.

#### Scenario: Request timeout
- **WHEN** the API does not respond within the timeout period
- **THEN** the connection is closed and `on_done` is called with a timeout error

### Requirement: C++ logging
The C++ Sidecar SHALL write diagnostic logs to `~/.aliasagent/logs/` directory, recording all key events during API communication for debugging purposes.

#### Scenario: Request logging
- **WHEN** an HTTP request is initiated
- **THEN** the request URL, HTTP method, model name, and full request body are written to the log

#### Scenario: Response status logging
- **WHEN** an HTTP response is received
- **THEN** the response status code is written to the log

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
- **WHEN** the API returns HTTP ≥ 400
- **THEN** the full response body is written to the log (truncated to 2048 characters)