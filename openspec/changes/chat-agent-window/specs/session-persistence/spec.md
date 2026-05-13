# Session Persistence — Spec

## ADDED Requirements

### Requirement: Session storage
The system SHALL persist chat sessions to a local SQLite database, with each session having an ID, title, agent type, creation timestamp, and last update timestamp.

#### Scenario: Create new session
- **WHEN** user creates a new chat session
- **THEN** a session row is inserted with auto-generated title "New Chat", current timestamp, and the default agent type

#### Scenario: Update session timestamp
- **WHEN** a message is added to a session
- **THEN** the session's `updated_at` field is set to the current time

#### Scenario: Delete session
- **WHEN** user deletes a session from the sidebar
- **THEN** the session and all its messages are removed from the database (cascading delete)

### Requirement: Message storage
The system SHALL persist all chat messages to the local SQLite database, with each message having an ID, session ID (foreign key), role (user/assistant), content, optional token count, and creation timestamp.

#### Scenario: Store user message
- **WHEN** user submits a message
- **THEN** a message row is inserted with role "user", the message content, and current timestamp

#### Scenario: Store assistant response
- **WHEN** assistant finishes generating a complete response
- **THEN** a message row is inserted with role "assistant", the full response content, and current timestamp

#### Scenario: Load messages for session
- **WHEN** user switches to a session
- **THEN** all messages for that session are loaded, ordered by `created_at` ascending

### Requirement: Session listing
The system SHALL query and return all sessions ordered by `updated_at` descending for display in the sidebar.

#### Scenario: List sessions
- **WHEN** the app loads or sessions change
- **THEN** sessions are returned sorted by most recently updated first

#### Scenario: Empty state
- **WHEN** no sessions exist in the database
- **THEN** an empty list is returned and the UI shows a "No conversations yet" placeholder

### Requirement: Database initialization
The system SHALL automatically create the SQLite database file and schema (sessions table, messages table) on first launch.

#### Scenario: First launch
- **WHEN** the app launches and no database file exists
- **THEN** the database file is created with the sessions and messages tables

#### Scenario: Schema already exists
- **WHEN** the app launches and the database file already has the correct schema
- **THEN** no schema changes are applied