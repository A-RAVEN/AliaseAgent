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