## MODIFIED Requirements

### Requirement: Request serialization
The C++ Sidecar SHALL serialize request execution **per context**: each context SHALL own its ModelGateway and `execute()` SHALL hold that context's request mutex across the entire request lifecycle (thread spawn + join), so that at most one active request exists **per context** and no gateway `impl_` state (curl handle, event buffers) is ever accessed concurrently. Requests belonging to different contexts MAY execute concurrently because they use different gateways and mutexes.

#### Scenario: Concurrent calls serialize within one context
- **WHEN** `send_message` is invoked on a context while that context's previous curl thread is still streaming
- **THEN** the second call blocks on that context's request mutex until the first completes, then executes

#### Scenario: Different contexts do not serialize globally
- **WHEN** two contexts each invoke `send_message` while neither has completed
- **THEN** their execution intervals SHALL overlap; the second context SHALL NOT wait for the first context's global completion

#### Scenario: Curl handle never shared across threads
- **WHEN** two requests overlap in time
- **THEN** the same CURL handle is never used by more than one thread at any given time (libcurl requirement)

### Requirement: Cancellation support (request-id targeted cancel)
The C++ Sidecar SHALL support cancelling a request via an FFI `cancel_request(handle, id)` call that is **request-id targeted within the given context**. The sidecar SHALL keep cancellation state per context; that state's `cancel_request_id` is NOT reset at request start. When `cancel_request(handle, id)` is called, a request on that same context whose id matches SHALL be aborted whether it is already in-flight (observed via XFERINFO — `CURLE_ABORTED_BY_CALLBACK`, `cancelled` set, not mislabeled a connection error) OR only enqueued/not-yet-started (checked at execute() start, before any network I/O), and SHALL deliver `on_done(-1, "cancelled")` in both cases. The `cancel_request_id` SHALL be cleared once that specific request resolves, so a later request that reuses the id is not spuriously cancelled. Requests on other contexts are unaffected even when their ids match. A late abort after the stream already delivered its done SHALL NOT deliver a second done (single-done invariant). After cancellation, `execute()` returns normally and that context's request mutex is released. An unknown context SHALL return a JSON `unknown_context` error and SHALL NOT cancel any request.

#### Scenario: In-flight request-id cancel
- **WHEN** `cancel_request(handle, id)` is called while the request with that id on the same context is streaming
- **THEN** the transfer aborts (`CURLE_ABORTED_BY_CALLBACK`), `cancelled` is set (not mislabeled a connection error), and `on_done(-1, "cancelled")` is delivered after join

#### Scenario: Enqueued-not-started request-id cancel
- **WHEN** `cancel_request(handle, id)` is called while the request with that id on the same context is queued but not yet running
- **THEN** `execute()` aborts at its start check (before network I/O) and delivers `on_done(-1, "cancelled")`

#### Scenario: Latch cleared after the target resolves
- **WHEN** the request identified by `cancel_request_id` on one context completes (cancelled or otherwise)
- **THEN** that context's `cancel_request_id` is cleared so a later request reusing the id is not spuriously cancelled

#### Scenario: Cancellation does not cross contexts
- **WHEN** two contexts each have an active request and one context cancels its own request id
- **THEN** only that context's request aborts; the other context's request continues even if the numeric request ids match
