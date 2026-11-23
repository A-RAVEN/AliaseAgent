# Session Persistence — Spec

## Purpose

规定会话与消息怎么落库、以及库结构怎么演进。核心约束：消息可带附件列（只存路径的 JSON 数组，不存字节）；升级走"只加列不改行"的迁移；读到时把 `NULL`、坏 JSON、非数组一律当成"没有附件"，并留一行日志；任何历史数据都不许因为新列而读失败。

## Requirements

### Requirement: Session storage
The system SHALL persist chat sessions to a local SQLite database, with each session having an ID, title, agent type, creation timestamp, and last update timestamp. The stored agent type SHALL be used as the template selector when an Agent is created or restored for that session; it SHALL NOT be treated as display-only metadata. The current session UI SHALL allow the user to switch its Agent template, persist the new `agent_type`, and use that template for the replacement Agent and subsequent requests. The update path SHALL confirm that exactly one existing session row was updated, re-read that row before creating the replacement Agent, and make the UI selection reflect the actually persisted value after any failure. A missing stored template SHALL produce a distinguishable error rather than silently selecting another template. Existing rows without an agent type SHALL continue to use the existing `general` default. Template names SHALL be immutable after creation so the template management UI does not create dangling `agent_type` references or name-collision overwrites.

**Group exception (kind = `group`).** For a group session the stored `agent_type` SHALL NOT be used as a template selector: the system SHALL NOT create or restore a single Agent for a group session (a group has no template of its own — each member's template comes from its member row). Every single-Agent entry point — startup restore, sending a message, switching the template — SHALL detect `kind = group` and either refuse with an attributable error naming the session, or route to the group surface; it MUST NOT build a single-Agent context over the group's transcript. Group sessions SHALL still appear in the top-level session list.

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

#### Scenario: 组会话不创建单 Agent
- **WHEN** 启动恢复或任一单 Agent 入口遇到 `kind = group` 的会话
- **THEN** 不为它解析模板、不创建/恢复单 Agent 实例；入口返回可归因错误或路由到组视图，且没有任何单 Agent 请求使用该组的原文

#### Scenario: 组会话切换模板被拒
- **WHEN** 客户端对一个 `kind = group` 的会话调用切换模板
- **THEN** 请求被可归因拒绝（指明组会话没有自己的模板），组会话的 `agent_type` 与成员配置都不变

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
The messages table SHALL include a monotonic `seq` integer column (autoincrement) with a (session_id, seq) index, providing a stable total order even for messages inserted in the same millisecond. `seq` is used as the stable ordering key for compaction tree spans and for reconstructing the message sequence; the existing UI list load continues to order by `created_at` for display. The compaction tree span key SHALL include the member scope — (session_id, member_id, start_seq, end_seq) — with the member scope empty for single-agent sessions (see `context-compaction`).

#### Scenario: seq present
- **WHEN** a message is inserted
- **THEN** it receives a strictly increasing seq

#### Scenario: seq indexed for spans
- **WHEN** the compaction tree records a node span
- **THEN** it uses (session_id, member_id, start_seq, end_seq), and the (session_id, seq) index supports span queries

#### Scenario: 组会话仍只有一条 seq 序列

- **WHEN** 组会话里多个成员先后写入消息
- **THEN** 所有行共用该会话的 (session_id, seq) 序列，不存在按成员切分的第二套序号

### Requirement: Summary nodes table
The system SHALL persist the compaction tree in a `summary_nodes` table keyed by (session_id, member_id, level, start_seq, end_seq), storing summary_json (role blocks), token_cost, summary_prompt_version, model, parent_id, and covered_min/max_seq, with a leaf_owner index and a dense non-overlap constraint. The member scope SHALL be NULL for single-agent sessions (which keep the previous (session_id, level, start_seq, end_seq) semantics) and SHALL name the owning member for group sessions, whose summaries are per member's projected view. The `leaf_owner` index SHALL include the member scope — (session_id, member_id, covered_min_seq, covered_max_seq) — and every lookup and every delete-before-insert on covered ranges SHALL match the member scope with `member_id IS NULL` for a single-agent session (an `= NULL` comparison matches nothing, so the empty scope SHALL be matched as `IS NULL`). Dense non-overlap SHALL hold per (session_id, member_id) scope: two members' nodes may cover the same seq span, one member's nodes may not; and the delete-before-insert that enforces it SHALL be scoped the same way, so materializing one member's node never deletes another member's node.

#### Scenario: Summary node persisted
- **WHEN** a fold completes
- **THEN** a row is inserted into summary_nodes with its seq span, its member scope, and metadata

#### Scenario: Non-overlapping coverage
- **WHEN** multiple nodes cover the same session and member scope
- **THEN** their covered_seq ranges are dense and non-overlapping

#### Scenario: 两个成员的同一 span 互不挤压

- **WHEN** 组里两个成员的视图各自折叠同一段 seq 区间
- **THEN** 两行同时存在（member_id 不同），后写入的一行不会删除先写入的另一成员的行

#### Scenario: 单 agent 会话按 IS NULL 匹配

- **WHEN** 单 agent 会话写入或查询摘要节点（member_id 为 NULL）
- **THEN** 覆盖范围查询与 delete-before-insert 都按 `member_id IS NULL` 命中；若把空作用域写成 `= NULL`，这条用例必须变红（匹配不到、重复行随之出现）

#### Scenario: 单 agent 会话的键不变

- **WHEN** 单 agent 会话写入摘要节点
- **THEN** member_id 为 NULL，(session_id, level, start_seq, end_seq) 的查询路径与变更前一致

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

### Requirement: 消息作者与可见性列

`messages` 表 SHALL 增加两列：`author TEXT`（可空；**稳定成员 id**，用户消息为 NULL）与 `visibility TEXT NOT NULL DEFAULT 'public'`（取值 `public` / `private-to-author`）。`Message` 模型 SHALL 完整读写这两列（`fromRow` / `toRow` 用同一组列名），`MessageRepository.insert` SHALL 接受可选的作者与可见性参数（缺省为 NULL / `public`，即变更前的行为）。显示名 SHALL NOT 写进 `author`（改名不得改变历史归属）。

旧行 SHALL 按「公开、无作者」解释（`visibility` 默认 `public`、`author` 为 NULL），读取 MUST NOT 因新列而失败。这两列**不改变存储形态**：组会话的原文仍是一份、仍是同一条 (session_id, seq) 序列。

#### Scenario: 写入带作者与可见性

- **WHEN** 组成员写入一条私有工具轮与一条公开回复
- **THEN** 前者 author 为该成员的 id、visibility 为 private-to-author；后者 author 为该成员的 id、visibility 为 public

#### Scenario: 作者是 id 不是显示名

- **WHEN** 成员改名后读取它此前的消息行
- **THEN** `author` 仍是同一个成员 id（显示名只在渲染时解析），行内容不变

#### Scenario: 用户消息无作者

- **WHEN** 用户消息写入组会话
- **THEN** author 为 NULL、visibility 为 public

#### Scenario: 旧行按默认语义读出

- **WHEN** 一个变更前创建的数据库升级后读出旧消息
- **THEN** 旧行 author 为 NULL、visibility 为 public，消息内容与附件不变

#### Scenario: 读取路径返回两列

- **WHEN** 按会话查询消息
- **THEN** 返回的每条消息都带 author 与 visibility（序列化里不静默丢弃）

### Requirement: 组会话、成员表与覆盖层列

`sessions` 表 SHALL 增加 `kind TEXT NOT NULL DEFAULT 'single'`（取值 `single` / `group`）、`overrides_json TEXT`（单 agent 会话的覆盖层，可空）、`reactions_enabled INTEGER NOT NULL DEFAULT 1`（组的自发反应开关：1 = 开启，0 = 关闭）与 `max_reaction_rounds INTEGER`（可空；组的反应轮数上限，`NULL` = 用产品默认值；不是 `config.json` 键）。组会话 SHALL 在新建的 `group_members` 表中持有成员：成员 id（主键）、`group_session_id`（外键 REFERENCES sessions(id) ON DELETE CASCADE）、组内唯一的显示名、模板名、`overrides_json TEXT`（该成员的覆盖层，可空）、`removed_at INTEGER`（可空的软删标记）、加入时间。`(group_session_id, name)` SHALL 只在未移除成员之间唯一。

**成员移除是软删**：写 `removed_at`、行保留，该成员的消息与摘要一律不删；移除后同名重建 SHALL 生成新的成员 id。`Session` 模型与 `SessionRepository.create` SHALL 读写 `kind`、`reactionsEnabled` 与 `maxRounds`（可空；`NULL` = 产品默认）；未提供 kind 的既有创建路径 SHALL 继续创建 `single` 会话。`Session` 构造函数 SHALL 把 `reactionsEnabled` 缺省为 `true`、`maxRounds` 缺省为 `null`；`SessionRepository.create` SHALL 接受可选的 `reactionsEnabled` 与 `maxRounds` 并原样写入；`Session` 的 `toRow` SHALL 写出两列，`fromRow` 对 `reactions_enabled` 的缺列或 null SHALL 按 `false` 解释（未迁移的旧库 / 手工夹具 = 旧点名行为），对 `max_reaction_rounds` 的缺列或 null SHALL 读成 `null`（= 用默认）。系统 SHALL 提供按组 id 原地更新 `reactions_enabled` 与 `max_reaction_rounds` 的方法（供 `group.update`；`maxRounds` 显式 null = 恢复默认）。单会话行也带这两列，但其值 SHALL NOT 影响单 Agent 的任何行为。这两列 SHALL NOT 是 `config.json` 键。组会话行的模板选择语义 SHALL NOT 被使用（见「Session storage」）。删除组会话时，其成员行 SHALL 随外键级联删除；验收 SHALL 用真实 SQLite 行数证明删除发生，不能只检查外键声明。

两处覆盖层列 SHALL 由同一个解析器读写（格式一致，见 `agent-instance-overrides`）。

#### Scenario: 新建组会话

- **WHEN** 用户创建一个组会话
- **THEN** sessions 里该行 kind = group、reactions_enabled = 1、max_reaction_rounds 为 NULL，且没有套用任何模板

#### Scenario: 组上限可设置与恢复默认

- **WHEN** 把某组的 `maxRounds` 更新为 6，随后又显式更新为 `null`
- **THEN** 第一次读回 `maxRounds = 6`、库里 `max_reaction_rounds = 6`；第二次读回 `maxRounds = null`、库里为 NULL（= 用产品默认 8）

#### Scenario: 成员名唯一

- **WHEN** 同一组内加入两个同名（均未移除）成员
- **THEN** 第二次写入被唯一约束拒绝（应用层先给出可归因错误，不留半行数据）

#### Scenario: 软删保留行

- **WHEN** 移除一个成员
- **THEN** 该成员行仍在 `group_members` 里且 `removed_at` 非空，其消息与摘要行数不变

#### Scenario: 同名可在移除后重建

- **WHEN** 移除「甲」后再加入同名「甲」
- **THEN** 新行使用新的成员 id（旧行的成员 id 不变），两条 id 不同

#### Scenario: 删除组级联删成员

- **WHEN** 删除一个含成员的组会话
- **THEN** 该组的 group_members 行数为 0，其它组与会话不受影响

#### Scenario: 旧会话 kind 为 single 且没有覆盖层

- **WHEN** 变更前的数据库升级后读出旧会话
- **THEN** 它们的 kind 为 single、overrides_json 为 NULL（等价于无覆盖），行为与变更前一致

#### Scenario: 两处覆盖层用同一个解析器

- **WHEN** 分别给单 agent 会话与组成员写同一份覆盖层内容
- **THEN** 读回来的生效配置相同（同一解析器、同一格式，不存在两套字段名）

#### Scenario: 新建组自发反应默认开启

- **WHEN** 从空库新建一个组并读回该会话
- **THEN** `reactionsEnabled = true`、库里 `reactions_enabled = 1`

#### Scenario: 关闭开关被持久化

- **WHEN** 把某组的 `reactionsEnabled` 更新为 `false` 后重新打开数据库读取
- **THEN** 该行 `reactions_enabled = 0`，读回 `reactionsEnabled = false`

#### Scenario: 旧组升级后默认关闭

- **WHEN** 一个 v9 数据库里的既有组行升级到 v11 后读出
- **THEN** 该行 `reactions_enabled = 0`、`max_reaction_rounds` 为 NULL（用产品默认上限），旧点名行为不变

#### Scenario: 单会话行的组设置不改变行为

- **WHEN** 单会话行的 `reactions_enabled` 为 0 或 1、`max_reaction_rounds` 为任意值或 NULL
- **THEN** 单 Agent 的发送、恢复、压缩与界面行为完全一致（这两列只对组有意义）

### Requirement: Schema migration v8 to v9

数据库版本 SHALL 从 8 升到 9。升级 SHALL 只做非破坏改动：`ALTER TABLE messages ADD COLUMN author TEXT`、`ALTER TABLE messages ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'`、`ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'single'`、`ALTER TABLE sessions ADD COLUMN overrides_json TEXT`、`ALTER TABLE summary_nodes ADD COLUMN member_id TEXT`、创建 `group_members` 表（含 `removed_at`、`overrides_json`）、创建含 member_id 的摘要 span 索引与 leaf_owner 索引。既有会话、消息、摘要、模板选择与附件 SHALL 原样保留。

新建数据库（`_onCreate`）与 `openAt` 测试路径 SHALL 镜像同一份 schema（既有规范要求）。升级路径 SHALL 用具体版本判断，MUST NOT 用会吞掉数据的 else 分支。

#### Scenario: 版本 8 数据库无损升级

- **WHEN** 一个已有会话、消息、摘要与附件的版本 8 数据库升级到版本 9
- **THEN** 既有数据全部可读，消息数、摘要数、会话 agent_type 不变；旧消息 author 为 NULL、visibility 为 public、旧会话 kind 为 single 且 overrides_json 为 NULL、旧摘要 member_id 为 NULL

#### Scenario: 升级产物与全新建库结构一致

- **WHEN** 比较「版本 8 库升级后的结构」与「全新建库的 `_onCreate` 结构」
- **THEN** 对 messages / sessions / summary_nodes / group_members 分别取 `PRAGMA table_info` 与 `PRAGMA index_list`，两边逐项一致（列名、类型、默认值、索引名与索引列）

#### Scenario: 新建数据库直接含新列新表

- **WHEN** 从空目录创建版本 9 数据库
- **THEN** messages 含 author/visibility、sessions 含 kind 与 overrides_json、summary_nodes 含 member_id、group_members 存在（含 overrides_json 与 removed_at）

#### Scenario: 迁移不删行

- **WHEN** 升级完成
- **THEN** 迁移前后的 messages / sessions / summary_nodes 行数完全一致（验收读真实行数）

### Requirement: Schema migration v9 to v11

数据库版本 SHALL 从 9 升到 11。升级 SHALL 只做非破坏改动，并分成两个按版本判断的分支：

- `oldV <= 9`：`ALTER TABLE sessions ADD COLUMN reactions_enabled INTEGER NOT NULL DEFAULT 1`，并把既有组行的 `reactions_enabled` 回填为 `0`（`UPDATE sessions SET reactions_enabled = 0 WHERE kind = 'group'`；**既有单会话行保持列默认 `1`**，对行为无意义但必须可断言）；
- `oldV <= 10`：`ALTER TABLE sessions ADD COLUMN max_reaction_rounds INTEGER`（可空）。这一段同时覆盖**上一轮同步实现已经升到 v10、但缺上限列**的真实用户库——v10 库从 `oldV = 10` 进来，只补上限列，既有 `reactions_enabled` 与回填值保持不动。

既有行的 `max_reaction_rounds` SHALL 保持 `NULL`（= 用产品默认）。既有会话、消息、摘要、成员、模板选择与附件 SHALL 原样保留。

新建数据库（`_onCreate`，v11）与 `openAt` 测试路径 SHALL 镜像同一份 schema（既有规范要求）。升级路径 SHALL 用具体版本判断（`oldV <= 9` 与 `oldV <= 10` 两段），MUST NOT 用会吞掉数据的 else 分支；**不得把 `max_reaction_rounds` 放进 `oldV <= 9` 分支**（v10 库不会进那个分支，会永远缺列）。

#### Scenario: 版本 9 数据库无损升级到 11

- **WHEN** 一个已有组、单会话、消息、摘要与成员的版本 9 数据库升级到版本 11
- **THEN** 既有数据全部可读，消息数、摘要数、成员数、会话 agent_type 不变；旧组行 `reactions_enabled = 0`、`max_reaction_rounds` 为 NULL，**旧单会话行 `reactions_enabled = 1`**（DB 行与 `fromRow` 各断言一次），旧单会话的 kind/overrides 等字段不变

#### Scenario: 版本 10 缺上限列的库补列

- **WHEN** 一个由上一轮同步实现升到 v10、已有 `reactions_enabled`、但 `sessions` 缺 `max_reaction_rounds` 的数据库升级到 v11
- **THEN** 只补上可空的 `max_reaction_rounds` 列；旧组行 `reactions_enabled = 0` 保持不变，旧单会话行 `reactions_enabled = 1` 保持不变，所有既有行数不变；升级后 `INSERT` 组设置不再报「no column named max_reaction_rounds」

#### Scenario: 升级产物与全新建库结构一致

- **WHEN** 比较「版本 9 库升级后的结构」「版本 10 缺列库升级后的结构」与「全新建库的 `_onCreate`（v11）结构」
- **THEN** 对 sessions / messages / summary_nodes / group_members 分别取 `PRAGMA table_info` 与 `PRAGMA index_list`，两边逐项一致（列名、类型、非空、默认值、索引名与索引列）

#### Scenario: 新建数据库直接含新列

- **WHEN** 从空目录创建版本 11 数据库
- **THEN** sessions 含 `reactions_enabled INTEGER NOT NULL DEFAULT 1` 与 `max_reaction_rounds INTEGER`（可空），新建组行读出 `reactionsEnabled = true`、`maxRounds = null`

#### Scenario: 迁移不删行

- **WHEN** 升级完成
- **THEN** 迁移前后的 messages / sessions / summary_nodes / group_members 行数完全一致（验收读真实行数）
