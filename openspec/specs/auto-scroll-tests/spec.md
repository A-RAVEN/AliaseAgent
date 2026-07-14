## ADDED Requirements

### Requirement: Scroll to bottom on new user message
The system SHALL auto-scroll the message list to the bottom when a user sends a message.

#### Scenario: User message triggers scroll
- **WHEN** a user message is added to the message list
- **THEN** the scroll position moves to the bottom of the list

### Requirement: Scroll to bottom on streaming content
The system SHALL auto-scroll to the bottom as assistant streaming text arrives.

#### Scenario: Streaming text triggers scroll
- **WHEN** the assistant is streaming a response (isStreaming=true, streamingText updates)
- **THEN** the scroll position stays at the bottom as new text appears

### Requirement: Scroll to bottom on stream completion
The system SHALL auto-scroll to the bottom when streaming completes and the final assistant message is added.

#### Scenario: Done callback triggers final scroll
- **WHEN** the assistant finishes generating (onDone callback) and the final message is appended
- **THEN** the scroll position moves to the bottom
