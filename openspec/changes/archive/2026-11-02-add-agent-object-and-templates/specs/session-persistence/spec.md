## MODIFIED Requirements

### Requirement: Session storage

The system SHALL persist chat sessions to a local SQLite database, with each session having an ID, title, agent type, creation timestamp, and last update timestamp. The stored agent type SHALL be used as the template selector when an Agent is created or restored for that session; it SHALL NOT be treated as display-only metadata. The current session UI SHALL allow the user to switch its Agent template, persist the new `agent_type`, and use that template for the replacement Agent and subsequent requests. The update path SHALL confirm that exactly one existing session row was updated, re-read that row before creating the replacement Agent, and make the UI selection reflect the actually persisted value after any failure. A missing stored template SHALL produce a distinguishable error rather than silently selecting another template. Existing rows without an agent type SHALL continue to use the existing `general` default. Template names SHALL be immutable after creation so the template management UI does not create dangling `agent_type` references or name-collision overwrites.

#### Scenario: Create new session
- **WHEN** user creates a new chat session
- **THEN** a session row is inserted with auto-generated title "New Chat", current timestamp, and the default agent type

#### Scenario: Update session timestamp
- **WHEN** a message is added to a session
- **THEN** the session's `updated_at` field is set to the current time

#### Scenario: Auto-title from first user message
- **WHEN** the first user message is added to a session with the default title "New Chat"
- **THEN** the session title is updated to the first 30 characters of the message content (truncated with "..." if longer)

#### Scenario: Restore uses stored agent type
- **WHEN** a persisted session whose agent type is not `general` is restored
- **THEN** the Agent created for that session resolves the stored template and uses its model and execution configuration

#### Scenario: Switch the current session template
- **WHEN** the user selects a different valid Agent template for the current session
- **THEN** the session's persisted `agent_type` changes to that name, a replacement Agent is created, and the next request uses the selected template's model and execution configuration

#### Scenario: Switched template survives restoration
- **WHEN** a session's Agent template has been switched and the application later restores that session
- **THEN** restoration uses the newly persisted template rather than `general` or the previously selected template

#### Scenario: Invalid switch has no side effects
- **WHEN** candidate preflight finds a missing template or provider, an invalid context window, or an unknown tool
- **THEN** the switch is rejected with the candidate name, and the existing Agent, persisted `agent_type`, and UI selection remain unchanged

#### Scenario: Switch requires an existing session row
- **WHEN** the template update affects no session row because the session is missing or was deleted
- **THEN** the switch fails visibly and does not create or register a replacement Agent

#### Scenario: Failure restores the persisted UI value
- **WHEN** retirement, persistence, or replacement creation fails after preflight
- **THEN** the UI reports the failed stage and candidate name, re-reads the session row, and displays the actually persisted `agent_type` rather than claiming an uncreated Agent is running

#### Scenario: Stored template is missing
- **WHEN** a persisted session names an agent type that no longer exists in the template registry
- **THEN** restoration reports the missing template name and does not silently run the session with `general`

#### Scenario: Delete session
- **WHEN** user deletes a session from the sidebar
- **THEN** the session and all its messages are removed from the database (cascading delete)
