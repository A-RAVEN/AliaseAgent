## ADDED Requirements

### Requirement: Parse text delta event
The C++ SSE parser SHALL extract and deliver text content from content_block_delta events.

#### Scenario: Single text delta
- **WHEN** SSE stream contains `{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello"}}`
- **THEN** the on_chunk callback is invoked with "Hello"

#### Scenario: Multiple sequential text deltas
- **WHEN** SSE stream contains two consecutive content_block_delta events with text
- **THEN** on_chunk is invoked twice, once per event

### Requirement: Parse tool use events
The C++ SSE parser SHALL accumulate input_json_delta fragments and deliver the complete tool_use at content_block_stop.

#### Scenario: Single fragment tool use
- **WHEN** SSE stream contains content_block_start (tool_use) → input_json_delta (complete JSON) → content_block_stop
- **THEN** on_tool_call is invoked with JSON containing id, name, and complete input

#### Scenario: Fragmented input_json_delta
- **WHEN** SSE stream contains three input_json_delta events with partial JSON fragments followed by content_block_stop
- **THEN** all fragments are concatenated and delivered as a single complete JSON in on_tool_call

### Requirement: Parse thinking block events
The C++ SSE parser SHALL accumulate thinking and signature deltas and deliver at content_block_stop.

#### Scenario: Thinking block with signature
- **WHEN** SSE stream contains content_block_start (thinking) → thinking_delta → signature_delta → content_block_stop
- **THEN** on_thinking is invoked with JSON containing thinking text and signature

### Requirement: Parse message_stop event
The C++ SSE parser SHALL extract stop_reason from message_delta and deliver via on_done.

#### Scenario: end_turn stop reason
- **WHEN** SSE stream contains message_delta with stop_reason: "end_turn" followed by message_stop
- **THEN** on_done is called with code 0 and stop_reason "end_turn"

#### Scenario: tool_use stop reason
- **WHEN** SSE stream contains message_delta with stop_reason: "tool_use" followed by message_stop
- **THEN** on_done is called with code 0 and stop_reason "tool_use"

### Requirement: Parse error event
The C++ SSE parser SHALL handle error events and report via on_done.

#### Scenario: Error event with message
- **WHEN** SSE stream contains `{"type": "error", "error": {"message": "Invalid API key"}}`
- **THEN** on_done is called with non-zero code and the error message

### Requirement: Handle unrecognized event types
The C++ SSE parser SHALL not crash on unrecognized event types and SHALL log a warning.

#### Scenario: Unknown event type
- **WHEN** SSE stream contains an event with an unrecognized type field
- **THEN** the parser does not crash
- **AND** a warning is logged
