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

### Requirement: Thinking card display
The system SHALL display thinking content blocks as collapsible `ThinkingCard` widgets in the message list, interleaved chronologically with tool call cards and assistant messages. Each thinking card SHALL include a header row with a thinking icon (e.g., 💭), "Thinking" label, expand/collapse chevron, and a content summary ("· N chars" when collapsed). Thinking blocks arrive as complete units from C++ at `content_block_stop`.

#### Scenario: Thinking card appears inline
- **WHEN** an `on_thinking` callback fires with a complete thinking block and a `ChatThinkingItem` is added to `_chatItems`
- **THEN** a `ThinkingCard` widget appears at its chronological position in the chat list, styled distinctly from both `ToolCallCard` and `MessageBubble`, default collapsed

#### Scenario: Thinking card header during turn
- **WHEN** a thinking block has been received but the overall turn is still in progress
- **THEN** the thinking card header shows an animated "Thinking..." indicator with dots

#### Scenario: Thinking card header after turn completion
- **WHEN** the turn completes (on_done callback fires)
- **THEN** all thinking card headers switch from animated dots to "· N chars" character count; expand/collapse state is unchanged

#### Scenario: Click to toggle expansion
- **WHEN** user clicks a thinking card header
- **THEN** the card toggles between expanded (showing full thinking text) and collapsed (header only)

#### Scenario: Multiple thinking cards interleaved
- **WHEN** a turn produces thinking → tool_use → thinking → text
- **THEN** the chat list renders in order: ThinkingCard → ToolCallCard → ThinkingCard → MessageBubble

### Requirement: Thinking card visual distinction
The `ThinkingCard` widget SHALL use a visual style that is clearly distinct from both tool call cards and assistant message bubbles, using a muted color palette and smaller font. The thinking body SHALL be scrollable with a max-height constraint to handle long thinking content without layout overflow.

#### Scenario: Visual style
- **WHEN** a `ThinkingCard` is rendered
- **THEN** it uses a muted background color (distinct from tool card blue and message bubble), smaller or italic body text, and a thinking-specific icon

#### Scenario: Long thinking content
- **WHEN** thinking content exceeds the body max-height (e.g., 400px)
- **THEN** the body uses a scrollable container to prevent layout overflow, matching existing `ToolCallCard` scroll pattern

### Requirement: Thinking card incremental updates
The UI SHALL update the ThinkingCard content incrementally as thinking deltas arrive, using the block index to locate the correct card. Index lookup SHALL be scoped to the current turn (the SSE index restarts at 0 for each new message): deltas for index N in the current turn SHALL NOT match cards created in earlier turns or cards rebuilt from history.

#### Scenario: First delta creates card
- **WHEN** the first `thinking_delta` event with a new index arrives in the current turn
- **THEN** a ChatThinkingItem with that index is created and a ThinkingCard renders with the partial text, header showing the streaming indicator

#### Scenario: Subsequent deltas append content
- **WHEN** a `thinking_delta` event arrives for an existing index in the current turn
- **THEN** the ChatThinkingItem at that index is replaced with a new instance whose content is the previous content plus the delta

#### Scenario: Final block replaces content
- **WHEN** the final `type:"thinking"` event arrives for an index
- **THEN** the card content is set to the complete thinking text and the signature is stored

#### Scenario: No cross-turn index collision
- **WHEN** a new turn (e.g., a tool-loop follow-up message) streams a thinking delta with index 0
- **THEN** the delta updates the current turn's card only; cards from the previous turn are not modified

### Requirement: Session-switch cancellation does not persist error cards
When an in-flight request is cancelled by a session switch (selecting another session, creating a new chat, or deleting the current session), the system SHALL NOT persist a misleading error card into the abandoned session's history. The cancellation context SHALL be captured at switch time via a request generation counter (epoch): a session switch records the generation of the in-flight call, and any done (success or error) of a call whose generation was invalidated by a switch SHALL be treated as a switch-cancellation — its reply SHALL NOT be persisted, rendered, or allowed to tear down a newer request's streaming state (rapid A→B→A switches included).

#### Scenario: Switch mid-stream
- **WHEN** a request is streaming in session A and the user switches to session B (cancelRequest issued, cancel context recorded for A)
- **THEN** the cancelled done is processed without storing any error card into session A's history

#### Scenario: Rapid switch back before cancel completes
- **WHEN** the user switches A→B→A before the cancellation done arrives
- **THEN** the done is still recognized as a switch-cancellation (context captured at switch time) and no error card is stored

#### Scenario: Cancelled request completes successfully
- **WHEN** a switch-cancelled request finishes with doneCode 0 (lost-cancel window)
- **THEN** the cancel context is cleared (a later real error in that session is still surfaced) and the stale request's completion does not tear down a newer request's streaming state

### Requirement: Collapse state stays user-controlled during streaming
The ThinkingCard SHALL NOT auto-expand or auto-collapse: during streaming, a collapsed card stays collapsed (content accumulates internally), and the program does not change the user's expand/collapse choice at any point (delta arrival, turn completion, or otherwise). This requirement SHALL be enforceable as an explicit spec clause, not merely inherited from prior behavior.

#### Scenario: User collapses a streaming card
- **WHEN** the user collapses a card while its thinking is still streaming
- **THEN** it stays collapsed until the user expands it; content continues to accumulate

#### Scenario: Turn completion does not change state
- **WHEN** a turn completes (streaming indicator switches to character count)
- **THEN** each card keeps the exact collapsed/expanded state it had before