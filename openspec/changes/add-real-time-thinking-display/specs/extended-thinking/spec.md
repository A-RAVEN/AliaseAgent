## ADDED Requirements

### Requirement: Thinking block index in events
The system SHALL include a numeric `index` in both `thinking_delta` and final `thinking` events, identifying which content block the event belongs to. The index SHALL match the SSE event's `index` field from `content_block_delta` / `content_block_stop`.

#### Scenario: Delta events carry index
- **WHEN** a `thinking_delta` SSE event has index 0
- **THEN** the corresponding `on_thinking` payload contains `"index":0`

#### Scenario: Final block carries index
- **WHEN** a thinking block with index 0 reaches content_block_stop
- **THEN** the final `on_thinking` payload contains `"index":0`
