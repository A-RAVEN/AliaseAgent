## ADDED Requirements

### Requirement: Thinking block index in events
The system SHALL include a numeric `index` in both `thinking_delta` and final `thinking` events, identifying which content block the event belongs to. The index SHALL match the SSE event's `index` field from `content_block_delta` / `content_block_stop`. The index SHALL be scoped to the current turn: the SSE index restarts at 0 for each new message, so incremental lookup never matches cards from previous turns or from history rebuilds.

#### Scenario: Delta events carry index
- **WHEN** a `thinking_delta` SSE event has index 0
- **THEN** the corresponding `on_thinking` payload contains `"index":0`

#### Scenario: Final block carries index
- **WHEN** a thinking block with index 0 reaches content_block_stop
- **THEN** the final `on_thinking` payload contains `"index":0`

### Requirement: Persistence contains final blocks only
The system SHALL persist ONLY final `thinking` events (complete text + signature) into `thinking_json`. `thinking_delta` events SHALL drive UI incremental rendering only and SHALL NOT be added to `turnThinkingBlocks`, persisted, or fed back to the API as content blocks (the content array in a Messages request accepts text/thinking/tool_use/etc. types, NOT `thinking_delta`).

#### Scenario: Deltas not persisted
- **WHEN** a turn streams N `thinking_delta` events and 1 final `thinking` event for a block
- **THEN** `thinking_json` contains only the final block (1 entry, complete text + signature), not the N delta fragments

#### Scenario: API context reconstruction stays valid
- **WHEN** a multi-turn tool loop reconstructs the assistant message from `thinking_json`
- **THEN** every persisted block is a valid `type:"thinking"` content block (never `type:"thinking_delta"`)

### Requirement: Rebuilt cards derive index from array order
When `ChatThinkingItem` objects are rebuilt from persisted `thinking_json` (session reload or turn-completion transition), their `index` SHALL be derived from the block's position in the stored array (0..N-1) — the index is NOT a persisted field. Data written by `add-extended-thinking` (blocks without index) SHALL rebuild correctly with derived indexes; no fallback or migration is required.

#### Scenario: History rebuild assigns derived indexes
- **WHEN** a session with 2 persisted thinking blocks (no index field) is reloaded
- **THEN** the rebuilt ChatThinkingItems have indexes 0 and 1 in array order

#### Scenario: Turn completion preserves index on instance rebuild
- **WHEN** the streaming→completed transition rebuilds ChatThinkingItem instances (isStreaming false)
- **THEN** the rebuilt instances keep the same derived indexes as their streaming counterparts
