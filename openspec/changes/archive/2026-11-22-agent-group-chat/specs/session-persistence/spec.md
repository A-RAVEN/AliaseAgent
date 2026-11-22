## MODIFIED Requirements

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

## ADDED Requirements

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

`sessions` 表 SHALL 增加 `kind TEXT NOT NULL DEFAULT 'single'`（取值 `single` / `group`）与 `overrides_json TEXT`（单 agent 会话的覆盖层，可空）。组会话 SHALL 在新建的 `group_members` 表中持有成员：成员 id（主键）、`group_session_id`（外键 REFERENCES sessions(id) ON DELETE CASCADE）、组内唯一的显示名、模板名、`overrides_json TEXT`（该成员的覆盖层，可空）、`removed_at INTEGER`（可空的软删标记）、加入时间。`(group_session_id, name)` SHALL 只在未移除成员之间唯一。

**成员移除是软删**：写 `removed_at`、行保留，该成员的消息与摘要一律不删；移除后同名重建 SHALL 生成新的成员 id。`Session` 模型与 `SessionRepository.create` SHALL 读写 `kind`；未提供 kind 的既有创建路径 SHALL 继续创建 `single` 会话。组会话行的模板选择语义 SHALL NOT 被使用（见「Session storage」）。删除组会话时，其成员行 SHALL 随外键级联删除；验收 SHALL 用真实 SQLite 行数证明删除发生，不能只检查外键声明。

两处覆盖层列 SHALL 由同一个解析器读写（格式一致，见 `agent-instance-overrides`）。

#### Scenario: 新建组会话

- **WHEN** 用户创建一个组会话
- **THEN** sessions 里该行 kind = group，且没有套用任何模板

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
