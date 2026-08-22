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
- **WHEN** no completed assistant MessageBubble appears within 150 seconds AND (the conversation is still streaming (ChatArea.isStreaming == true) OR streaming was never observed during the wait — e.g. a hang in the pre-stream DB preamble that never reaches isStreaming == true)
- **THEN** the test SHALL fail with a TimeoutException (indicates an internal bug such as pipe deadlock or a pre-stream hang)

#### Scenario: Silent completion (empty reply or internal exception)
- **WHEN** the conversation stops streaming (ChatArea.isStreaming == false) without a completed assistant MessageBubble — either the model returned an empty final text (e.g. a thinking-only response under adaptive thinking) or an internal exception ended the turn (e.g. a failing message/DB insert or sidecar error), which the test cannot distinguish
- **THEN** the test SHALL fail with a clear attributable message naming the ambiguity ("model empty reply or internal exception"), preceded by an evidence dump ([OBS] tool calls and file state) — it SHALL NOT be skipped, because skipping would silently mask internal bugs and contradict the "Internal bugs SHALL fail" requirement

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

### Requirement: Live test output observability
窗口版 live 测试（真实模型驱动）SHALL 在**断言前及所有失败路径（等待超时 / 错误状态检测）**输出该轮**实际工具调用**（toolName / 完整 input / status / result）与涉及文件的**最终状态**（如有工具调用/文件修改；无工具调用的用例如实报告"无工具调用"），使失败可归因；不输出测试内容即规范违规。

#### Scenario: Tool calls are dumped before assertions
- **WHEN** a live test reaches its assertion phase with tool calls having occurred this turn
- **THEN** the test SHALL print each `ToolCallCard`'s `toolName`, `status`, complete `input`, and a result preview BEFORE the file-state assertions run

#### Scenario: Failure paths dump before fail/skip
- **WHEN** a live test fails (wait timeout / error-status detection) before or during its assertions
- **THEN** the test SHALL print the tool-call and file-state evidence BEFORE calling `fail(...)` or `markTestSkipped(...)`, so the failure is attributable

#### Scenario: File state is dumped for file-modifying tests
- **WHEN** a live test involves `write_file` / `edit_file` and reaches its assertions
- **THEN** the test SHALL dump the affected files' final content, attributable per-file

#### Scenario: No-tool-call tests report explicitly
- **WHEN** a live test case makes no tool calls (e.g. basic conversation / extended thinking)
- **THEN** the test SHALL first verify no `ToolCallCard` exists (not merely assume it), then print "无工具调用" instead of an empty dump
