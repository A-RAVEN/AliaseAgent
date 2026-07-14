## ADDED Requirements

### Requirement: Enter key submits message
The system SHALL submit the input text as a message when the Enter key is pressed without Shift.

#### Scenario: Enter submits non-empty input
- **WHEN** the input field has text "Hello" and user presses Enter (without Shift)
- **THEN** the message "Hello" is passed to the onSendMessage callback
- **AND** the input field is cleared

#### Scenario: Enter on empty input does nothing
- **WHEN** the input field is empty or whitespace-only and user presses Enter
- **THEN** no message is sent
- **AND** the input field remains empty

### Requirement: Shift+Enter inserts newline
The system SHALL insert a newline character in the input field when Shift+Enter is pressed, without submitting.

#### Scenario: Shift+Enter adds newline
- **WHEN** the input field has text "Line1" and user presses Shift+Enter
- **THEN** a newline is inserted (text becomes "Line1\n")
- **AND** no message is sent

#### Scenario: Multiple Shift+Enter
- **WHEN** user presses Shift+Enter twice in an empty input field
- **THEN** the input contains two newline characters
- **AND** no message is sent
