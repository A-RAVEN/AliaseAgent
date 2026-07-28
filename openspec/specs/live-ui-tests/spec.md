## ADDED Requirements

### Requirement: Basic conversation via UI
The system SHALL support an integration test that types a message into the chat TextField, taps Send, and waits for a COMPLETED (non-streaming) assistant response.

#### Scenario: User sends message and gets completed AI reply
- **WHEN** the test enters a message into the TextField and taps the Send button
- **THEN** within 150 seconds, a MessageBubble with role "assistant" and isStreaming == false SHALL appear with non-empty content that does not start with "Error:"

#### Scenario: Streaming completion detection
- **WHEN** the AI is streaming a response (isStreaming == true)
- **THEN** the test SHALL NOT match the streaming bubble as a completed response; it SHALL wait until isStreaming becomes false

#### Scenario: Streaming animation does not block test
- **WHEN** the StreamingDots animation is active
- **THEN** the test SHALL use manual pump loops (not pumpAndSettle) and SHALL NOT hang

### Requirement: Tool call via UI conversation
The system SHALL support an integration test that triggers a web_fetch tool call through a natural language message and verifies the tool call card appears and completes. This test SHALL only run when search providers are configured (web_fetch tool registration is gated behind hasProviders).

#### Scenario: AI triggers web_fetch and responds
- **WHEN** search providers are configured AND the test enters an explicit web_fetch request and taps Send
- **THEN** within 150 seconds, a ToolCallCard SHALL appear with toolName "web_fetch"
- **AND** the ToolCallCard status SHALL transition to "Done"
- **AND** a completed assistant MessageBubble SHALL appear with non-empty content

#### Scenario: No search providers configured
- **WHEN** no search providers are configured in config.json
- **THEN** the web_fetch test scenario SHALL be skipped (web_fetch tool is not registered without providers)

### Requirement: Error classification and resilience
External failures (API/network) SHALL cause the test to be skipped, not failed. Internal bugs SHALL cause the test to fail. Live UI tests SHALL NOT block other test suites.

#### Scenario: API key invalid or network unavailable
- **WHEN** the completed assistant MessageBubble content starts with "Error:"
- **THEN** the test SHALL be marked as skipped via markTestSkipped with the error message

#### Scenario: Internal bug detected
- **WHEN** a ToolCallCard shows status "Error", or the assistant reply is non-empty without "Error:" prefix but tool call failed
- **THEN** the test SHALL fail with an assertion error

#### Scenario: Test timeout
- **WHEN** no completed assistant MessageBubble appears within 150 seconds
- **THEN** the test SHALL fail with a TimeoutException (indicates possible internal bug such as pipe deadlock)

#### Scenario: Live test skip does not block other tests
- **WHEN** all live UI test scenarios are skipped due to API unavailability
- **THEN** unit tests, widget tests, real sidecar tests, and smoke tests SHALL still run independently

### Requirement: Test data isolation
Live UI tests SHALL use a temporary database via `DatabaseService.openAt(tempDir)`. The temporary database SHALL be closed and deleted in tearDown.

#### Scenario: Test sessions do not pollute user data
- **WHEN** a live UI test creates sessions and messages
- **THEN** they SHALL be stored in a temporary database; the user's real aliasagent.db SHALL remain unchanged

#### Scenario: Cleanup after test
- **WHEN** the test completes (pass, fail, or skip)
- **THEN** tearDown SHALL close the database connection via DatabaseService.close() and delete the temporary directory

### Requirement: AppShell-based test setup
Live UI tests SHALL pump the full AppShell widget (not bare ChatScreen with injected sidecar), so that _initSearchAndTools() executes and registers all tool definitions including web_fetch.

#### Scenario: Config exists
- **WHEN** ~/.aliasagent/config.json exists with valid API key and search providers
- **THEN** AppShell SHALL initialize normally, tools SHALL be registered, and the test SHALL proceed

#### Scenario: Config missing
- **WHEN** ~/.aliasagent/config.json does not exist
- **THEN** the test SHALL be skipped (SetupDialog would block the test)
