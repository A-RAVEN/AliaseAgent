## ADDED Requirements

### Requirement: Curl execution on dedicated thread
The C++ Sidecar SHALL execute `curl_easy_perform` on a dedicated `std::thread`, with the FFI calling thread joining the curl thread before returning. This keeps the synchronous send_message contract while allowing callback dispatch to occur in real-time.

#### Scenario: Request executes on curl thread
- **WHEN** `send_message` is invoked
- **THEN** curl runs on a dedicated thread and the FFI call returns only after curl completes

#### Scenario: Callbacks fire during stream
- **WHEN** SSE events arrive during the curl stream
- **THEN** callbacks (on_chunk, on_thinking) are invoked from the curl thread in real-time, before curl completes

### Requirement: Request serialization
The C++ Sidecar SHALL serialize request execution: `execute()` SHALL hold a global request mutex across the entire request lifecycle (thread spawn + join), so that at most one active request exists at any time and no `impl_` state (curl handle, event buffers) is ever accessed concurrently. This makes concurrent `send_message` calls from multiple worker isolates safe.

#### Scenario: Concurrent calls serialize
- **WHEN** `send_message` is invoked while another request's curl thread is still streaming
- **THEN** the second call blocks on the request mutex until the first completes, then executes

#### Scenario: Curl handle never shared across threads
- **WHEN** two requests overlap in time
- **THEN** the same CURL handle is never used by more than one thread at any given time (libcurl requirement)

### Requirement: Cancellation support
The C++ Sidecar SHALL support cancelling an in-flight request via an FFI `cancel_request()` call: an atomic flag SHALL be set, the curl thread SHALL observe it (e.g., via CURLOPT_XFERINFOFUNCTION) and terminate promptly (CURLE_ABORTED_BY_CALLBACK), and `on_done(-1, "cancelled")` SHALL be delivered after the join completes from the FFI thread **provided the stream's done has not already been dispatched** (measured rationale: native callbacks invoked from the curl thread outside the libcurl call stack were observed to never reach the Dart isolate, while the FFI-thread path does; the curl thread is fully terminated by then, so closing the Dart NativeCallables after this done remains safe). A late abort after the stream already delivered its done (e.g. the Dart side cancelling while the curl thread finishes the connection close) SHALL NOT deliver a second done and SHALL NOT be logged as a cancellation (single-done invariant; 14.7). After cancellation, `execute()` returns normally and the request mutex is released.

#### Scenario: Cancel terminates streaming
- **WHEN** `cancel_request()` is called during an active stream whose done has not yet been dispatched
- **THEN** the curl thread terminates promptly, on_done(-1, "cancelled") is delivered after join, and execute returns

#### Scenario: Cancel before request start is a no-op
- **WHEN** `cancel_request()` is called with no active request
- **THEN** it returns without effect

### Requirement: Single done delivery
The Sidecar SHALL deliver exactly one done event per request. The `[DONE]` compatibility marker and `message_stop` SHALL be mutually exclusive at dispatch time (a `done_dispatched` guard checked when pushing the done event), so a successful response that contains both (as recorded in the DeepSeek endpoint fixture) triggers only one on_done.

#### Scenario: message_stop and [DONE] both present
- **WHEN** the stream contains both `message_stop` and a trailing `data: [DONE]`
- **THEN** on_done fires exactly once

### Requirement: Tool use remains block-complete delivery
Tool use JSON SHALL continue to be delivered only at `content_block_stop` after all `input_json_delta` fragments are accumulated and parsed. No incremental tool_use events SHALL be emitted.

#### Scenario: Tool use delivered at block stop
- **WHEN** a tool_use block streams input_json_delta fragments
- **THEN** on_tool_call fires once at content_block_stop with the complete JSON
