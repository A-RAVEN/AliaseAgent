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

#### Scenario: Auto-title from first user message
- **WHEN** the first user message is added to a session with the default title "New Chat"
- **THEN** the session title is updated to the first 30 characters of the message content (truncated with "..." if longer)

#### Scenario: Delete session
- **WHEN** user deletes a session from the sidebar
- **THEN** the session and all its messages are removed from the database (cascading delete)

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

#### Scenario: Schema version mismatch
- **WHEN** the app launches and the database file has a different `user_version` pragma than expected
- **THEN** for known migration paths (e.g., v1→v2), a non-destructive migration is applied (e.g., ALTER TABLE ADD COLUMN) to preserve existing data; for unrecognized version gaps, the database is dropped and recreated with the current schema

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

### Requirement: Stable seq column
The messages table SHALL include a monotonic `seq` integer column (autoincrement) with a (session_id, seq) index, providing a stable total order even for messages inserted in the same millisecond. `seq` is used as the stable ordering key for compaction tree spans and for reconstructing the message sequence; the existing UI list load continues to order by `created_at` for display.

#### Scenario: seq present
- **WHEN** a message is inserted
- **THEN** it receives a strictly increasing seq

#### Scenario: seq indexed for spans
- **WHEN** the compaction tree records a node span
- **THEN** it uses (session_id, start_seq, end_seq), and the (session_id, seq) index supports span queries

### Requirement: Summary nodes table
The system SHALL persist the compaction tree in a `summary_nodes` table keyed by (session_id, level, start_seq, end_seq), storing summary_json (role blocks), token_cost, summary_prompt_version, model, parent_id, and covered_min/max_seq, with a leaf_owner index and a dense non-overlap constraint.

#### Scenario: Summary node persisted
- **WHEN** a fold completes
- **THEN** a row is inserted into summary_nodes with its seq span and metadata

#### Scenario: Non-overlapping coverage
- **WHEN** multiple nodes cover a session
- **THEN** their covered_seq ranges are dense and non-overlapping

### Requirement: token_count write
The `token_count` column SHALL be written with the measured provider usage at message persist time, rather than remaining unwritten.

#### Scenario: token_count populated
- **WHEN** a message is persisted after a completed request
- **THEN** its token_count equals the measured usage from the provider

### Requirement: Schema migration v3 to v4
The system SHALL migrate schema version 3 to 4 by adding the `seq` column (backfilled best-effort by created_at, rowid), creating the `summary_nodes` table, and adding a per-session `tree_version`; it SHALL NOT pre-build rollup rows for legacy data (legacy messages remain uncompressed leaves, built lazily forward). The schema SHALL be mirrored in both `_init` and `openAt`.

#### Scenario: Migration from v3
- **WHEN** the database is opened with schema version 3 and the app expects version 4
- **THEN** `ALTER TABLE messages ADD COLUMN seq INTEGER` is executed (backfilled best-effort by created_at, rowid), the `summary_nodes` table is created, and a per-session `tree_version` is added; existing data is preserved

#### Scenario: Fresh install at v4
- **WHEN** the database is created from scratch at schema version 4
- **THEN** the messages table includes the `seq` column, the `summary_nodes` table exists, and sessions carry `tree_version`

#### Scenario: No rollup pre-built for legacy
- **WHEN** old messages are migrated to v4
- **THEN** no rollup/summary rows are pre-built for them; they remain uncompressed leaves, built lazily forward