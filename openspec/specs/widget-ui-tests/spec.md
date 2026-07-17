## ADDED Requirements

### Requirement: Empty state placeholder text
The system SHALL display a placeholder text in the input field when no conversation is active.

#### Scenario: ChatArea with no messages
- **WHEN** ChatArea is rendered with an empty message list
- **THEN** the input field displays "Type a message..." placeholder text

### Requirement: Message bubble rendering
The system SHALL render user messages and assistant messages with distinct visual styles.

#### Scenario: User message displayed
- **WHEN** a message with `role: user` and content "Hello" is in the message list
- **THEN** the text "Hello" is visible in the message area
- **AND** the user bubble is visually distinct from an assistant bubble

#### Scenario: Assistant message displayed
- **WHEN** a message with `role: assistant` and content "Hi there" is in the message list
- **THEN** the text "Hi there" is visible in the message area

### Requirement: Session sidebar rendering
The system SHALL display a list of sessions in the sidebar with the current session highlighted.

#### Scenario: Sessions exist
- **WHEN** SessionSidebar is rendered with 3 sessions and `currentId` matching the second session
- **THEN** all 3 session titles are visible
- **AND** the matched session has a highlighted/selected visual state

#### Scenario: No sessions exist
- **WHEN** SessionSidebar is rendered with an empty session list
- **THEN** a "New Chat" button is still visible for creating a new session

### Requirement: Tool call card rendering
The system SHALL render tool call activities as visually distinct cards showing tool name and input.

#### Scenario: Tool call card displayed
- **WHEN** a ToolCallActivity with name "read_file" and input text is in the list
- **THEN** the tool name "read_file" is visible in a distinct card
- **AND** the card is visually differentiated from regular message bubbles

### Requirement: Error message rendering
The system SHALL render error messages as assistant-styled message bubbles with an error content prefix.

#### Scenario: Error message displayed
- **WHEN** a message with `role: assistant` and content starting with "Error:" is in the message list
- **THEN** the error text is visible in a standard assistant bubble
- **AND** the "Error:" prefix identifies it as an error to the user

### Requirement: Streaming state indication
The system SHALL display streaming text distinctly from completed messages.

#### Scenario: Streaming in progress
- **WHEN** `isStreaming` is true and `streamingText` is "Thinking..."
- **THEN** the streaming text "Thinking..." is visible in the message area
- **AND** a loading indicator or animation is shown to indicate active streaming
