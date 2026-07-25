# Chat UI — Spec

## ADDED Requirements

### Requirement: Message list display
The system SHALL display a scrollable message list showing all messages in the current session, with user messages and assistant messages visually differentiated.

#### Scenario: New session starts empty
- **WHEN** user creates a new session
- **THEN** the message list area is empty with a placeholder hint

#### Scenario: User sends a message
- **WHEN** user submits a message via the input box
- **THEN** the message appears immediately in the message list, aligned to the right (or styled as user message)

#### Scenario: Assistant streams response
- **WHEN** the assistant generates a response via SSE streaming
- **THEN** the response text appears incrementally in the message list, aligned to the left (or styled as assistant message)

#### Scenario: Scroll to bottom on new content
- **WHEN** new message content appears (user message or streaming assistant response)
- **THEN** the message list auto-scrolls to the bottom

### Requirement: Markdown rendering
The system SHALL render assistant message content as Markdown, supporting at minimum: headings, bold/italic, inline code, code blocks with monospace font, unordered/ordered lists, and links.

#### Scenario: Code block rendering
- **WHEN** assistant response contains a fenced code block (```)
- **THEN** the code block is rendered with monospace font, visually distinct from normal text

#### Scenario: Inline formatting
- **WHEN** assistant response contains **bold**, *italic*, or `inline code`
- **THEN** each is rendered with appropriate styling

### Requirement: Message input
The system SHALL provide a text input area at the bottom of the chat window that supports multi-line input and submission via Enter key or send button.

#### Scenario: Submit via Enter
- **WHEN** user presses Enter (without Shift) in the input box
- **THEN** the message is submitted and the input box clears

#### Scenario: Newline via Shift+Enter
- **WHEN** user presses Shift+Enter in the input box
- **THEN** a newline is inserted in the input text without submitting

#### Scenario: Submit via button
- **WHEN** user clicks the send button
- **THEN** the message is submitted and the input box clears

#### Scenario: Empty message blocked
- **WHEN** user attempts to submit an empty or whitespace-only message
- **THEN** the message is not sent

### Requirement: Streaming indicator
The system SHALL show a visual indicator (e.g., blinking cursor or "..." animation) while the assistant is generating a response.

#### Scenario: Indicator shows during generation
- **WHEN** user sends a message and the assistant begins generating
- **THEN** a streaming indicator appears in the message list until the response completes

#### Scenario: Indicator clears on completion
- **WHEN** the assistant finishes generating (on_done callback)
- **THEN** the streaming indicator is removed

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

### Requirement: Session list sidebar
The system SHALL display a sidebar listing all saved sessions, ordered by last update time descending, with the ability to switch between sessions and create new ones.

#### Scenario: Switch session
- **WHEN** user clicks on a different session in the sidebar
- **THEN** the message list updates to show that session's messages

#### Scenario: Create new session
- **WHEN** user clicks "New Chat" button
- **THEN** a new session is created with default title, and appears at top of session list

#### Scenario: Session list updates on new message
- **WHEN** a new message is added to the current session
- **THEN** that session moves to the top of the session list