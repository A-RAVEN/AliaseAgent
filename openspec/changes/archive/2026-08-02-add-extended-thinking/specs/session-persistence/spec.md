## MODIFIED Requirements

### Requirement: Message storage
The system SHALL persist all chat messages to the local SQLite database, with each message having an ID, session ID (foreign key), role (user/assistant), content, optional token count, optional tool calls JSON, optional thinking JSON, and creation timestamp.

#### Scenario: Store user message
- **WHEN** user submits a message
- **THEN** a message row is inserted with role "user", the message content, and current timestamp

#### Scenario: Store assistant response with thinking
- **WHEN** assistant finishes generating a response that includes thinking blocks
- **THEN** a message row is inserted with role "assistant", the full response content, and the thinking blocks serialized as JSON in the `thinking_json` column

#### Scenario: Store assistant response with tool calls
- **WHEN** assistant finishes generating a response that includes tool call invocations
- **THEN** a message row is inserted with role "assistant", the full response content, the tool calls serialized as JSON in the `tool_calls` column, and current timestamp

#### Scenario: Load messages for session
- **WHEN** user switches to a session
- **THEN** all messages for that session are loaded, ordered by `created_at` ascending, including thinking_json and tool_calls columns

## ADDED Requirements

### Requirement: Schema migration v2 to v3
The system SHALL add a `thinking_json TEXT` column to the messages table when upgrading from schema version 2 to version 3, preserving all existing data. The `onUpgrade` handler SHALL use specific version checks instead of a destructive else-branch.

#### Scenario: Migration from v2
- **WHEN** the database is opened with schema version 2 and the app expects version 3
- **THEN** `ALTER TABLE messages ADD COLUMN thinking_json TEXT` is executed, and existing rows retain NULL for the new column

#### Scenario: Fresh install at v3
- **WHEN** the database is created from scratch at schema version 3
- **THEN** the messages table includes the `thinking_json TEXT` column in its CREATE TABLE statement

#### Scenario: No data loss on migration
- **WHEN** the database migrates from v2 to v3
- **THEN** all existing sessions and messages are preserved (no tables are dropped)

#### Scenario: Both onCreate branches updated
- **WHEN** the database is created via either `_init` or `openAt` paths
- **THEN** both CREATE TABLE statements include the `thinking_json TEXT` column
