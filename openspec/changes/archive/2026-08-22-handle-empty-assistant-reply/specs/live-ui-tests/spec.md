## MODIFIED Requirements

### Requirement: Error classification and resilience
External failures (API/network) SHALL cause the test to be skipped, not failed. Internal bugs SHALL cause the test to fail. Live UI tests SHALL NOT block other test suites.

#### Scenario: API key invalid or network unavailable
- **WHEN** the completed assistant MessageBubble content starts with "Error:"
- **THEN** the test SHALL be marked as skipped via markTestSkipped with the error message

#### Scenario: Internal bug detected
- **WHEN** a ToolCallCard shows status "Error", or the assistant reply is non-empty without "Error:" prefix but tool call failed
- **THEN** the test SHALL fail with an assertion error

#### Scenario: Test timeout
- **WHEN** no completed assistant MessageBubble appears within 150 seconds AND (the conversation is still streaming (ChatArea.isStreaming == true) OR streaming was never observed during the wait — e.g. a hang in the pre-stream DB preamble that never reaches isStreaming == true)
- **THEN** the test SHALL fail with a TimeoutException (indicates an internal bug such as pipe deadlock or a pre-stream hang)

#### Scenario: Silent completion (empty reply or internal exception)
- **WHEN** the conversation stops streaming (ChatArea.isStreaming == false) without a completed assistant MessageBubble — either the model returned an empty final text (e.g. a thinking-only response under adaptive thinking) or an internal exception ended the turn (e.g. a failing message/DB insert or sidecar error), which the test cannot distinguish
- **THEN** the test SHALL fail with a clear attributable message naming the ambiguity ("model empty reply or internal exception"), preceded by an evidence dump ([OBS] tool calls and file state) — it SHALL NOT be skipped, because skipping would silently mask internal bugs and contradict the "Internal bugs SHALL fail" requirement

#### Scenario: Live test skip does not block other tests
- **WHEN** all live UI test scenarios are skipped due to API unavailability
- **THEN** unit tests, widget tests, real sidecar tests, and smoke tests SHALL still run independently
