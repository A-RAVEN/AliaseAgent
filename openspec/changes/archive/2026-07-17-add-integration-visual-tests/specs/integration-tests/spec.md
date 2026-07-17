## ADDED Requirements

### Requirement: End-to-end message send and receive
The system SHALL verify the full message send→receive→render pipeline using a FakeSidecar and fake repos.

#### Scenario: User sends message and receives reply
- **WHEN** a user message "Hello" is sent via ChatArea input
- **AND** FakeSidecar returns chunk("Hi there!") and done(0, "end_turn")
- **THEN** "Hi there!" appears in the message area as an assistant message

### Requirement: Tool call flow
The system SHALL verify that tool call events are rendered as ToolCallCard widgets.

#### Scenario: Tool call appears during conversation
- **WHEN** FakeSidecar emits a tool_call event for "list_dir"
- **THEN** a ToolCallCard with name "list_dir" appears in the message area

### Requirement: Auto-title update
The system SHALL verify that the session title updates from "New Chat" after the first message.

#### Scenario: First message triggers title update
- **WHEN** a session has default title "New Chat"
- **AND** user sends "帮我写代码" as the first message
- **AND** FakeSidecar returns a reply
- **THEN** the session title in the sidebar updates to the first 30 characters of the message

### Requirement: Error propagation
The system SHALL verify that error stop reasons are reflected in the UI.

#### Scenario: API error bubbles up
- **WHEN** FakeSidecar returns onDone with code 1 and error "Authentication failed"
- **THEN** an error message appears in the message list with the error text

### Requirement: Streaming state management
The system SHALL verify that streaming state transitions correctly during message sending.

#### Scenario: Streaming starts
- **WHEN** `sendMessage()` is called
- **THEN** `isStreaming` becomes true
- **AND** the send button is disabled or inactive

#### Scenario: Streaming ends
- **WHEN** `onDone` is called by the sidecar
- **THEN** `isStreaming` becomes false
- **AND** the input field and send button are re-enabled
