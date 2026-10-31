## MODIFIED Requirements

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
