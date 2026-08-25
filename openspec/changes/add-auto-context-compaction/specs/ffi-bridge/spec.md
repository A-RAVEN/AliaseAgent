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
