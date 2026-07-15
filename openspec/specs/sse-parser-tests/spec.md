## ADDED Requirements

### Requirement: Parse text delta event
The C++ SSE parser SHALL extract and deliver text content from content_block_delta events.

#### Scenario: Single text delta
- **WHEN** SSE stream contains `{"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Hello"}}`
- **THEN** the on_chunk callback is invoked with "Hello"

#### Scenario: Multiple sequential text deltas
- **WHEN** SSE stream contains two consecutive content_block_delta events with text
- **THEN** on_chunk is invoked twice, once per event

#### Scenario: Empty text in text_delta
- **WHEN** SSE stream contains content_block_delta with text_delta where text is "" or missing
- **THEN** on_chunk is invoked with empty string ""

#### Scenario: content_block_delta without "delta" field
- **WHEN** SSE stream contains `{"type": "content_block_delta"}` with no "delta" key
- **THEN** the parser does not crash and no callback is invoked

### Requirement: Parse tool use events
The C++ SSE parser SHALL accumulate input_json_delta fragments and deliver the complete tool_use at content_block_stop.

#### Scenario: Single fragment tool use
- **WHEN** SSE stream contains content_block_start (tool_use) → input_json_delta (complete JSON) → content_block_stop
- **THEN** on_tool_call is invoked with JSON containing id, name, and complete input

#### Scenario: Fragmented input_json_delta
- **WHEN** SSE stream contains content_block_start → three input_json_delta events with partial JSON fragments → content_block_stop
- **THEN** all fragments are concatenated and delivered as a single complete JSON in on_tool_call

#### Scenario: Multiple tool_use blocks at different indices
- **WHEN** SSE stream contains two tool_use blocks at index 0 and index 1 interleaved
- **THEN** on_tool_call is invoked twice, each with the correct assembled JSON for its index

#### Scenario: tool_use input_json parse failure
- **WHEN** SSE stream contains content_block_start → malformed input_json_delta (not valid JSON) → content_block_stop
- **THEN** LOG_ERR is emitted and on_tool_call delivers the tool_use JSON without the "input" field

### Requirement: Parse thinking block events
The C++ SSE parser SHALL accumulate thinking and signature deltas and deliver at content_block_stop.

#### Scenario: Thinking block with signature
- **WHEN** SSE stream contains content_block_start (thinking) → thinking_delta → signature_delta → content_block_stop
- **THEN** on_thinking is invoked with JSON containing thinking text and signature

### Requirement: Parse message_stop event
The C++ SSE parser SHALL extract stop_reason from message_delta and deliver via on_done.

#### Scenario: end_turn stop reason
- **WHEN** SSE stream contains message_delta with stop_reason: "end_turn" followed by message_stop
- **THEN** on_done is called with code 0, empty string error, and stop_reason "end_turn"

#### Scenario: tool_use stop reason
- **WHEN** SSE stream contains message_delta with stop_reason: "tool_use" followed by message_stop
- **THEN** on_done is called with code 0, empty string error, and stop_reason "tool_use"

#### Scenario: message_delta without stop_reason field
- **WHEN** SSE stream contains message_delta without stop_reason → message_stop
- **THEN** on_done is called with code 0, empty string error, and empty string stop_reason

#### Scenario: message_stop without prior message_delta
- **WHEN** SSE stream contains message_stop without any prior message_delta
- **THEN** on_done is called with code 0, empty string error, and empty string stop_reason

### Requirement: Parse [DONE] marker
The C++ SSE parser SHALL handle the SSE protocol `[DONE]` marker and deliver via on_done.

#### Scenario: [DONE] marker after message_delta
- **WHEN** SSE stream contains data: [DONE] after a message_delta with stop_reason
- **THEN** on_done is called with code 0 and the carry-forward stop_reason

#### Scenario: [DONE] marker without prior message_delta
- **WHEN** SSE stream contains data: [DONE] with no prior message_delta
- **THEN** on_done is called with code 0, empty string error, and empty string stop_reason

### Requirement: Parse error event
The C++ SSE parser SHALL handle error events and report via on_done.

#### Scenario: Error event with message
- **WHEN** SSE stream contains `{"type": "error", "error": {"message": "Invalid API key"}}`
- **THEN** on_done is called with code -1 and the error message string, and empty string stop_reason

### Requirement: Handle recognized-but-ignored event types
The C++ SSE parser SHALL not crash on recognized event types that require no action and SHALL log appropriately.

#### Scenario: message_start event
- **WHEN** SSE stream contains `{"type": "message_start", ...}`
- **THEN** the parser does not crash, LOG_INFO is emitted, no callback is invoked

#### Scenario: ping event
- **WHEN** SSE stream contains `{"type": "ping"}`
- **THEN** the parser does not crash, no log output, no callback is invoked

#### Scenario: content_block_start with unknown type (e.g., "text")
- **WHEN** SSE stream contains content_block_start with type "text" (not tool_use or thinking)
- **THEN** the parser does not crash, LOG_INFO is emitted, no callback is invoked

### Requirement: Handle unrecognized event types
The C++ SSE parser SHALL not crash on unrecognized event types and SHALL log a warning.

#### Scenario: Unknown event type
- **WHEN** SSE stream contains an event with an unrecognized type field
- **THEN** the parser does not crash
- **AND** LOG_WARN is emitted with the type and a prefix of the raw data

### Requirement: Handle malformed SSE data
The C++ SSE parser SHALL handle non-JSON SSE data lines gracefully.

#### Scenario: JSON parse error in data line
- **WHEN** SSE stream contains a data line that is not valid JSON (e.g., truncated or corrupted)
- **THEN** the parser does not crash
- **AND** LOG_ERR is emitted
- **AND** subsequent valid events are still processed correctly

### Requirement: Multi-block stream integration
The C++ SSE parser SHALL correctly handle multiple block types interleaved in a single stream.

#### Scenario: Thinking + text + tool_use in one stream
- **WHEN** SSE stream contains thinking block (index 0), text deltas, and tool_use block (index 1) interleaved
- **THEN** all three callback types fire with correct content, in correct order, with no cross-contamination between index-keyed maps
