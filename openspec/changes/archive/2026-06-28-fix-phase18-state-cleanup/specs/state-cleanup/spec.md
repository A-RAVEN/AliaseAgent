## ADDED Requirements

### Requirement: Tool activity state cleanup on session delete
The system SHALL clear tool activity cards when the active session is deleted, preventing stale tool cards from appearing in the next active session.

#### Scenario: Delete active session with tool cards
- **WHEN** the user deletes the currently active session that has tool call cards displayed
- **THEN** `_toolActivities` is cleared to empty alongside `_messages`, `_isStreaming`, and `_streamingText`

### Requirement: Mounted check after async gap in send message
The system SHALL verify the widget is still mounted after any asynchronous operation in `_sendMessage` before proceeding with sidecar API calls.

#### Scenario: Widget disposed during session lookup
- **WHEN** `_sendMessage` performs `await _sessionRepo.get()` and the widget is disposed during this await
- **THEN** the method returns early without calling `_callModel()` or `_loadSessions()`

### Requirement: Tool call JSON parse errors logged
The system SHALL log parse failures in `onToolCall` and `onThinking` callbacks rather than silently swallowing them.

#### Scenario: Malformed JSON in onToolCall
- **WHEN** the sidecar delivers a `tool_call` event with unparseable JSON
- **THEN** the error is logged via `debugPrint` with the raw JSON content, and the tool call is skipped

### Requirement: Unique tool activity IDs
The system SHALL ensure each `ToolCallActivity` has a unique identifier for result matching.

#### Scenario: Tool call missing ID from API
- **WHEN** a tool call JSON from the API lacks an `id` field or has an empty `id`
- **THEN** a synthetic unique ID is generated **once** in the `onToolCall` callback via `tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}'` and stored directly on the tool call map, so all downstream consumers (tool execution, result matching) read the same value without recomputation

### Requirement: Streaming text displays current turn only
The system SHALL display only the current tool-call turn's text in the streaming bubble, not accumulated text from all prior turns.

#### Scenario: Multi-turn tool call with intermediate text
- **WHEN** a multi-turn tool call conversation produces text in intermediate turns (e.g., "Let me read that file" before a tool_use, then "The file contains: hello" in the final turn)
- **THEN** the streaming bubble shows only the current turn's text (`turnText`), not the concatenation of all turns (`allText`)

### Requirement: Session switch clears message list synchronously
The system SHALL clear `_messages` to empty in the same `setState` that updates `_currentId`, before the async `_loadMessages()` call, to prevent stale messages from the previous session appearing in the current session's UI.

#### Scenario: Switch session with messages present
- **WHEN** the user selects a different session in the sidebar while `_messages` contains the previous session's chat history
- **THEN** `_messages` is set to `[]` atomically with `_currentId` update
- **AND** `_loadMessages()` then loads the correct session's messages asynchronously

#### Scenario: Send message during async load gap
- **WHEN** the user sends a message after switching sessions but before `_loadMessages()` completes
- **THEN** `_sendMessage` snapshots `_messages` as `[]` (not the previous session's history)
- **AND** the API request is built with only the new user message, not mixed context from another session

### Requirement: No nested setState in _deleteSession
The system SHALL call `_endStreaming()` outside of any enclosing `setState` callback in `_deleteSession`, keeping each state mutation in its own `setState` block.

#### Scenario: Delete current session
- **WHEN** the user deletes the currently active session
- **THEN** `_endStreaming()` is invoked independently (not inside another `setState` callback)
- **AND** the session switch (`_currentId`, `_messages = []`) occurs in a separate `setState` call

### Requirement: _loadMessages handles DB errors gracefully
The system SHALL catch exceptions from the database query in `_loadMessages` and clear `_messages` to empty on failure, preventing permanently stale data display.

#### Scenario: Database query fails during session switch
- **WHEN** `_msgRepo.queryBySession()` throws an exception
- **THEN** the error is caught and `_messages` is set to `[]` via `setState`
- **AND** the UI shows an empty message list rather than retaining another session's history

### Requirement: Tool call callbacks do not mutate state for abandoned sessions
The system SHALL guard `_toolActivities` mutations in `_callModel`'s `onToolCall` callback and tool-execution loop with a `_currentId == sessionId` check, preventing stale callbacks from abandoned sessions from polluting the current session's tool activity cards.

#### Scenario: Switch sessions during in-flight tool call
- **WHEN** the user switches from session A to session B while session A has an in-flight API response containing a tool_use block
- **THEN** session A's `onToolCall` callback does NOT add a `ToolCallActivity` to `_toolActivities`
- **AND** session A's tool-result updates do NOT modify `_toolActivities` entries

#### Scenario: Tool result arrives after session switch
- **WHEN** session A's tool execution completes and the result callback fires after the user has switched to session B
- **THEN** the `_toolActivities[idx] = ...` assignment is skipped due to `_currentId != sessionId`

## MODIFIED Requirements

### Requirement: Auto-title from first user message
The system SHALL update the session title from the first user message via `SessionRepository.updateTitleIfDefault()`, which encapsulates the "New Chat" check and 30-character truncation logic.

#### Scenario: First message triggers title update via repository
- **WHEN** the first user message is added to a session with the default title "New Chat"
- **THEN** `SessionRepository.updateTitleIfDefault()` is called, which checks the title condition, truncates to 30 characters (with "..." if longer), and updates the session title; the sidebar is updated by patching the local `_sessions` list rather than full reload
