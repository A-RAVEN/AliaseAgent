## ADDED Requirements

### Requirement: Send message flow
The system SHALL accept text input, send it as a user message, and add the message to the list.

#### Scenario: User types and sends a message
- **WHEN** user enters "Hello world" in the input field
- **AND** presses the send button (or Enter key)
- **THEN** the onSendMessage callback is invoked with "Hello world"
- **AND** the input field is cleared

#### Scenario: Empty message not sent
- **WHEN** the input field is empty or contains only whitespace
- **THEN** the send button is disabled or pressing Enter does not invoke onSendMessage

### Requirement: Auto-title update after first message
The system SHALL update the session title from the default "New Chat" after the first user message is sent.

#### Scenario: First message triggers title update
- **WHEN** a session has the default title "New Chat"
- **AND** the first user message "帮我写代码" is sent
- **THEN** the session title in the sidebar updates to reflect the message content (first 30 characters or full message if shorter)

### Requirement: Session switching
The system SHALL switch the active session and load its messages when a different session is selected from the sidebar.

#### Scenario: Switch to another session
- **WHEN** two sessions exist with different messages
- **AND** user taps on the second session in the sidebar
- **THEN** the message list updates to show the second session's messages
- **AND** the first session's messages are no longer visible

### Requirement: Tool call activity display
The system SHALL display tool call activities in the message area when a tool is invoked during a conversation.

#### Scenario: Tool call occurs during streaming
- **WHEN** a ToolCallActivity with name "list_dir" appears in the tool activities list
- **THEN** a tool call card for "list_dir" is visible in the message area
- **AND** the tool input parameters are displayed on the card

### Requirement: Error state display
The system SHALL display error messages in the message list when an API call or tool execution fails.

#### Scenario: API error renders error message
- **WHEN** a message with `role: assistant` and content prefixed with "Error:" is added to the message list
- **THEN** the error message appears as a standard assistant bubble
- **AND** the error text (including the "Error:" prefix) is visible to the user

### Requirement: New chat creation
The system SHALL create a new empty session when the "New Chat" button is pressed.

#### Scenario: New chat from sidebar
- **WHEN** user presses the "New Chat" button in the sidebar
- **THEN** a new session with default title "New Chat" is created
- **AND** the message area clears to show the empty state placeholder
