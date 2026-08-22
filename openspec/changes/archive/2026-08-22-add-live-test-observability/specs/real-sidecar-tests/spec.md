## ADDED Requirements

### Requirement: Live test output observability
窗口版 live 测试（真实模型驱动）SHALL 在**断言前及所有失败路径（等待超时 / 错误状态检测）**输出该轮**实际工具调用**（toolName / 完整 input / status / result）与涉及文件的**最终状态**（如有工具调用/文件修改；无工具调用的用例如实报告"无工具调用"），使失败可归因；不输出测试内容即规范违规。同一要求约束 `live_file_tools_test.dart`（本 change 的窗口版 live 套件，其窗口版形态与端到端覆盖需求已在本 spec 中）。

#### Scenario: Tool calls are dumped before assertions
- **WHEN** a live test reaches its assertion phase with tool calls having occurred this turn
- **THEN** the test SHALL print each `ToolCallCard`'s `toolName`, `status`, complete `input`, and a result preview BEFORE the file-state assertions run

#### Scenario: Failure paths dump before fail/skip
- **WHEN** a live test fails (wait timeout / error-status detection) before or during its assertions
- **THEN** the test SHALL print the tool-call and file-state evidence BEFORE calling `fail(...)` or `markTestSkipped(...)`, so the failure is attributable

#### Scenario: Conversation-never-completes timeout still dumps
- **WHEN** the wait-for-turn-complete helper throws its bare `TimeoutException`
- **THEN** the dump SHALL run before the exception propagates (call-site try/on with dump, then fail/rethrow)

#### Scenario: File state is dumped for file-modifying tests
- **WHEN** a live test involves `edit_file` / `write_file` and reaches its assertions
- **THEN** the test SHALL dump the affected files' final content, attributable per-file
