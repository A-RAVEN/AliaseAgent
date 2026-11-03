# Session Persistence — Spec

## Purpose

规定会话与消息怎么落库、以及库结构怎么演进。核心约束：消息可带附件列（只存路径的 JSON 数组，不存字节）；升级走"只加列不改行"的迁移；读到时把 `NULL`、坏 JSON、非数组一律当成"没有附件"，并留一行日志；任何历史数据都不许因为新列而读失败。

## Requirements

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
The system SHALL query and return only top-level sessions whose `parent_session_id` is `NULL`, ordered by `updated_at` descending for display in the sidebar. Child Agent run records SHALL remain queryable through the dedicated parent-id query path, but SHALL NOT appear in the ordinary sidebar list or be automatically restored as independent Agents during application startup.

#### Scenario: List sessions
- **WHEN** the app loads sessions after both top-level sessions and child Agent run records have been persisted
- **THEN** only top-level sessions are returned, sorted by most recently updated first, and every child record remains retrievable by its parent session id

#### Scenario: Empty state
- **WHEN** no top-level sessions exist in the database, including when only orphaned child run records remain
- **THEN** an empty top-level list is returned and the UI shows a "No conversations yet" placeholder

#### Scenario: Startup does not restore child runs
- **WHEN** the application restarts with a persisted child run record and its parent session
- **THEN** the parent session is restored through its stored Agent template, while the child run is neither shown as a separate chat nor used to create a running Agent automatically

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
### Requirement: Attachments column and v6 to v7 migration

The `messages` table SHALL gain a nullable `attachments TEXT` column holding a JSON array of attachment records. Each record SHALL contain only `path` (an absolute file path); image bytes, base64 data, dimensions, and media types MUST NOT be stored in the database.

The schema version SHALL move from 6 to 7. Upgrading an existing database SHALL execute `ALTER TABLE messages ADD COLUMN attachments TEXT` and SHALL preserve every existing row (old rows keep `NULL`, which means "no attachments"). Creating a database from scratch at version 7 SHALL include the column in the `CREATE TABLE messages` statement.

Deserialization SHALL treat `NULL`, malformed JSON, or a non-array value as an empty attachment list, print one log line for the malformed cases, and MUST NOT throw.

#### Scenario: Existing database upgrades
- **WHEN** a version-6 database is opened by code expecting version 7
- **THEN** `ALTER TABLE messages ADD COLUMN attachments TEXT` is executed; every pre-existing message still loads, with an empty attachment list

#### Scenario: Fresh database at version 7
- **WHEN** the database is created from scratch
- **THEN** `CREATE TABLE messages` includes the `attachments` column and the version is 7

#### Scenario: A persisted message round-trips its paths
- **WHEN** a user message with one attached image path is persisted and then reloaded
- **THEN** the reloaded `Message.attachments` equals `[<that path>]` and the row's `attachments` column contains a JSON array whose only element keys come from the set `{path}`

#### Scenario: Malformed column does not crash
- **WHEN** a row's `attachments` column contains `"{not json"`
- **THEN** the message loads with an empty attachment list and one log line is printed

### Requirement: 子运行记录关联父会话并非破坏性迁移

`sessions` SHALL 增加可空 `parent_session_id`，普通顶层会话保存 `NULL`，一次性子 Agent 记录保存父会话 id。`Session` 模型与 `SessionRepository.create` SHALL 完整读写该字段；未提供父 id 的既有创建路径 SHALL 继续创建普通 `general` 会话。

数据库版本 SHALL 从现有 7 升到 8。新建数据库与版本 7 升级路径 SHALL 都包含该列，升级只新增列，既有会话、消息、摘要、模板选择和附件 SHALL 原样保留，既有行的 `parent_session_id` 为 `NULL`。

系统 SHALL 提供按父会话 id 查询子记录的只读入口。删除父会话时，其子记录及各自消息、摘要 SHALL 确实删除；验收 SHALL 使用真实 SQLite 行数证明删除发生，不能只检查外键声明。

#### Scenario: 版本 7 数据库无损升级

- **WHEN** 一个已有顶层会话、消息、摘要和附件的版本 7 数据库升级到版本 8
- **THEN** 既有数据全部可读，`parent_session_id` 为 `NULL`，消息数量、摘要数量和会话 `agent_type` 不变

#### Scenario: 新建数据库直接包含父子字段

- **WHEN** 从空目录创建版本 8 数据库并建立普通会话与子运行记录
- **THEN** 普通会话的 `parent_session_id` 为 `NULL`，子记录准确保存父会话 id

#### Scenario: 删除父会话清理子记录

- **WHEN** 父会话具有带消息和摘要的子运行记录，用户删除该父会话
- **THEN** 数据库中父会话、子记录以及两者的消息和摘要均不存在，其它顶层会话及其子记录不受影响
