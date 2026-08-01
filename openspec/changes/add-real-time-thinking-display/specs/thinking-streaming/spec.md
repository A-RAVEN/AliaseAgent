## ADDED Requirements

### Requirement: Real-time thinking delta delivery
The C++ Sidecar SHALL deliver thinking content incrementally in real-time while the API stream is active, not after curl completes. Each `thinking_delta` SSE event SHALL trigger an immediate `on_thinking` callback with `{"type":"thinking_delta","index":N,"delta":"<partial>"}`. At `content_block_stop`, the Sidecar SHALL deliver the final complete block as `{"type":"thinking","index":N,"thinking":"<full>","signature":"<sig>"}`.

#### Scenario: Thinking deltas delivered in real-time
- **WHEN** the API streams `thinking_delta` events for block index 0
- **THEN** each delta triggers an immediate `on_thinking` callback with `type:"thinking_delta"` and the delta text, before curl completes

#### Scenario: Final thinking block after deltas
- **WHEN** the thinking block reaches `content_block_stop`
- **THEN** `on_thinking` is invoked with `type:"thinking"` containing the complete thinking text and signature

#### Scenario: Delta ordering preserved
- **WHEN** multiple thinking deltas arrive for the same block index
- **THEN** they are delivered in arrival order with consistent index values

### Requirement: Real-time text delta delivery
The C++ Sidecar SHALL invoke `on_chunk` immediately for each `text_delta` SSE event during the stream, rather than buffering until curl completes.

#### Scenario: Text streams while curl is active
- **WHEN** the API streams `text_delta` events
- **THEN** each delta triggers an immediate `on_chunk` callback before curl completes

### Requirement: Callback string lifetime safety
All strings passed to callbacks from the curl thread SHALL remain valid until the corresponding Dart callback has completed its synchronous copy. The implementation SHALL use stable-address storage (e.g., `std::deque<std::string>` with mutex) cleared only at the start of the next request, after the previous request's done callback has been processed.

#### Scenario: No use-after-free across threads
- **WHEN** the curl thread invokes callbacks while the main isolate processes them asynchronously
- **THEN** all string pointers remain valid (no crash, no garbage data)

#### Scenario: Storage cleared safely
- **WHEN** a new request starts
- **THEN** pending string storage from the previous request is cleared only after the previous done callback was delivered (SendPort ordering guarantees all prior callbacks completed)

### Requirement: Thinking card dynamic rendering
The UI SHALL render thinking content incrementally as deltas arrive: a ThinkingCard appears when the first delta for a block arrives, and its content grows with each subsequent delta.

#### Scenario: Card appears on first delta
- **WHEN** the first `thinking_delta` for block index N arrives
- **THEN** a ThinkingCard is created for index N showing the partial text

#### Scenario: Card content grows incrementally
- **WHEN** subsequent `thinking_delta` events arrive for index N
- **THEN** the existing card's content is appended with each delta

#### Scenario: Final block updates card
- **WHEN** the final `type:"thinking"` event arrives for index N
- **THEN** the card content is replaced with the complete thinking text and signature stored
