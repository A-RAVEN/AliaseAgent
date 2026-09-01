# FFI Bridge — Spec (delta)

## MODIFIED Requirements

### Requirement: Completion callback
The system SHALL invoke the `on_done` callback from C++ to Dart when the API response is complete (end of stream) or an error occurs. The callback SHALL include the `stop_reason` extracted from `message_delta`, and SHALL carry the measured usage (input/output tokens) so Dart can persist it to the message's `token_count`. (This extends the prior on_done signature; a dedicated `on_usage` callback MAY be used instead.)

#### Scenario: Successful completion
- **WHEN** C++ receives `message_stop` event
- **THEN** `on_done` is called with code 0, empty error, the `stop_reason` from `message_delta`, and the measured usage (input/output tokens)

#### Scenario: Error completion
- **WHEN** C++ encounters an HTTP error or network failure
- **THEN** `on_done` is called with non-zero code, descriptive error message, and the last known `stop_reason` (may be empty)

#### Scenario: token_count written from usage
- **WHEN** Dart receives usage for a message
- **THEN** the token_count column for that message row is written

### Requirement: Request-id targeted cancel (assign a per-request id)
The Dart bridge SHALL assign a unique monotonically-increasing `request_id` to every `sendMessage` **before** it is enqueued on the serialization gate, and pass it to the C++ `send_message`; it SHALL also pass the id into the worker isolate. `cancelRequest()` SHALL invoke the C++ `cancel_request(id)` with the id of the request it wants to cancel — the most recently enqueued/active request, which at a background-fold preempt is the fold's request (the user's own request is enqueued AFTER with a different id). This makes cancellation request-id targeted (a queued-but-not-starting fold request is aborted, the user request is unaffected), satisfying the "background folding never delays the user" contract.

#### Scenario: Bridge assigns unique ids
- **WHEN** `sendMessage` is called
- **THEN** a fresh monotonically-increasing `request_id` is assigned before enqueueing and passed to the C++ `send_message`

#### Scenario: cancelRequest targets the fold's request id
- **WHEN** `cancelRequest()` is invoked while a background fold request is the most recently enqueued/active request
- **THEN** `cancel_request(foldRequestId)` is called (NOT a no-arg cancel), so the fold request aborts and the user request (different id) is unaffected
