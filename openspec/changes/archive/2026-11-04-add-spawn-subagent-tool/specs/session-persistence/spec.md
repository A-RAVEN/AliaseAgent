## ADDED Requirements

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

## MODIFIED Requirements

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
