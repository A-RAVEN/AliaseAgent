## MODIFIED Requirements

### Requirement: Tool call display
The system SHALL display tool call requests and results as distinct cards within the message list, visually differentiated from regular user and assistant messages.

#### Scenario: Tool call card appears
- **WHEN** the model requests a tool invocation (on_tool_call callback)
- **THEN** a tool call card is inserted into the message list showing the tool name and input parameters, positioned directly before the assistant message that triggered the tool call (interleaved with messages, NOT appended after all messages)

#### Scenario: Tool result displayed — structured search results
- **WHEN** a web_search or web_fetch tool execution completes with a structured result
- **THEN** the tool call card updates to show a minimal summary when collapsed, and all individual result items when expanded

#### Scenario: Tool result displayed — error state
- **WHEN** a tool execution completes with an error (network timeout, rate limit, API error)
- **THEN** the tool call card header SHALL show "Error" status with error icon, and the result area SHALL display the error message (collapsible if long)

#### Scenario: Tool result displayed — non-search tools
- **WHEN** a non-search tool execution (read_file, list_dir, get_current_time) completes with a result
- **THEN** the tool call card updates to show the result summary (collapsible for long results) using the existing string-based display

#### Scenario: No empty bubble when model directly calls tool
- **WHEN** the model issues a tool call before generating any text (tool_use-only response), without any preceding text delta, in both live conversation and session reload
- **THEN** no empty assistant bubble (ChatStreamingItem or ChatMessageItem) SHALL appear before or around the tool call card; only the tool call card SHALL be visible. The intermediate assistant message SHALL still be persisted to the database for API context reconstruction.

#### Scenario: Streaming bubble appears on first text
- **WHEN** the model generates text output (onChunk callback fires for the first time in a turn)
- **THEN** a streaming assistant bubble SHALL be created and display the accumulating text

#### Scenario: No empty bubble for tool-only messages on session reload
- **WHEN** a persisted assistant message has empty content with tool calls (tool_use-only response), and the session is reloaded
- **THEN** no empty ChatMessageItem bubble SHALL be rendered for that message; only the corresponding ToolCallCard items SHALL be displayed

#### Scenario: Tool cards persist in session history
- **WHEN** the user switches to a different session and back, or restarts the application
- **THEN** all tool call cards from previous conversation turns are still rendered in their original positions within the message list (interleaved between user and assistant messages according to conversation turn order; NOT appended at the end of the list)
