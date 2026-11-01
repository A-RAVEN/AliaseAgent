# Thinking Streaming — Spec

## Purpose

约束思考过程的流式呈现：增量到达、可折叠、不与正文混淆。

## Requirements

### Requirement: Real-time thinking delta delivery
The C++ Sidecar SHALL deliver thinking content incrementally in real-time while the API stream is active, not after curl completes. Each wire `content_block_delta` event with `delta.type == "thinking_delta"` SHALL trigger an immediate `on_thinking` callback with the sidecar-composed payload `{"type":"thinking_delta","index":N,"delta":"<partial>"}` (wire mapping: `content_block_delta.index` → `index`, `delta.thinking` → `delta`; the composed format is internal to the sidecar callback, NOT a wire event type). At `content_block_stop` — which in the wire stream carries only `type` and `index` and NO content block object — the Sidecar SHALL deliver the final complete block, accumulated by the parser from the preceding `thinking_delta`/`signature_delta` events, as `{"type":"thinking","index":N,"thinking":"<full>","signature":"<sig>"}`.

#### Scenario: Thinking deltas delivered in real-time
- **WHEN** the API streams `content_block_delta` events with `delta.type == "thinking_delta"` for block index 0
- **THEN** each delta triggers an immediate `on_thinking` callback with `type:"thinking_delta"` and the delta text, before curl completes

#### Scenario: Final thinking block after deltas
- **WHEN** the thinking block reaches `content_block_stop`
- **THEN** `on_thinking` is invoked with `type:"thinking"` containing the complete thinking text (accumulated from deltas by the parser) and signature

#### Scenario: Delta ordering preserved
- **WHEN** multiple thinking deltas arrive for the same block index
- **THEN** they are delivered in arrival order with consistent index values

### Requirement: Real-time text delta delivery
The C++ Sidecar SHALL invoke `on_chunk` immediately for each `text_delta` SSE event during the stream, rather than buffering until curl completes.

#### Scenario: Text streams while curl is active
- **WHEN** the API streams `text_delta` events
- **THEN** each delta triggers an immediate `on_chunk` callback before curl completes

### Requirement: Callback string lifetime safety
All strings passed to callbacks from the curl thread SHALL remain valid until the corresponding Dart callback has completed its synchronous copy. The implementation SHALL use stable-address storage (e.g., `std::deque<std::string>` with mutex) owned by each context's ModelGateway and cleared only at the start of the next request **on that same context**, when the following hold simultaneously: (a) that context's previous curl thread has joined (its execute has released that context's request mutex), and (b) that context's previous done callback has been processed by the main isolate (the Dart bridge serializes new requests on that context behind its active request's completion — done is the last callback message, delivered in order on the isolate message queue; VM ordering is a stable implementation behavior, empirically verified). A request on another context SHALL NOT clear or reuse this storage.

#### Scenario: No use-after-free across threads
- **WHEN** the curl thread invokes callbacks while the main isolate processes them asynchronously
- **THEN** all string pointers remain valid (no crash, no garbage data)

#### Scenario: Storage cleared safely
- **WHEN** a new request starts on one context
- **THEN** only that context's pending string storage from its previous request is cleared, and only after that previous done callback was delivered and that previous curl thread terminated (that context's request mutex + Dart per-context serialization gate guarantee both)

#### Scenario: Another context cannot clear the storage
- **WHEN** context 甲 has callback strings awaiting Dart delivery while context 乙 starts a request
- **THEN** 乙's gateway SHALL NOT clear or reuse 甲's pending string storage

### Requirement: Thinking card dynamic rendering
The UI SHALL render thinking content incrementally as deltas arrive: a ThinkingCard appears when the first delta for a block arrives, and its content grows with each subsequent delta. During the turn, the card's collapsed/expanded state SHALL remain entirely user-controlled — the program SHALL NOT auto-expand or auto-collapse the card at any point (delta arrival, turn completion, or otherwise).

#### Scenario: Card appears on first delta
- **WHEN** the first `thinking_delta` for block index N arrives
- **THEN** a ThinkingCard is created for index N showing the partial text

#### Scenario: Card content grows incrementally
- **WHEN** subsequent `thinking_delta` events arrive for index N
- **THEN** the existing card's content is appended with each delta

#### Scenario: Final block updates card
- **WHEN** the final `type:"thinking"` event arrives for index N
- **THEN** the card content is replaced with the complete thinking text and signature stored

#### Scenario: Collapse state stays user-controlled during streaming
- **WHEN** thinking deltas arrive while the card is collapsed
- **THEN** the card remains collapsed (content still accumulates internally), and the program does not change the user's expand/collapse choice
