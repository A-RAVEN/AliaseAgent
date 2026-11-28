## ADDED Requirements

### Requirement: 会话工作区列与 v11→v12 迁移

`sessions` 表 SHALL 增加可空 `workspace TEXT` 列，存放该会话的工作路径设置值（单聊会话的工作区、组会话的**共享**工作区）。`NULL` 的语义 SHALL 是「未设置」：恢复时沿用产品既有缺省 `ConfigService.homeDir`，MUST NOT 把缺省值写进库（不把缺省冻成用户没选过的路径）。

`Session` 模型 SHALL 完整读写该字段（`fromRow` / `toRow` 用同一列名 `workspace`）；`SessionRepository.create` SHALL 接受可选的 `workspace` 并原样写入；未提供该参数的既有创建路径 SHALL 继续写 `NULL`。系统 SHALL 提供原地写该列的入口 `SessionRepository.updateWorkspace(id, value)`，并由调用方核对**恰好一行**被更新：0 行（会话不存在 / 已被删除）SHALL 显式失败，MUST NOT 静默 no-op 或假报成功。

数据库版本 SHALL 从 11 升到 12。升级 SHALL 只做非破坏改动：`ALTER TABLE sessions ADD COLUMN workspace TEXT`；既有行保持 `NULL`，既有会话、消息、摘要、成员、模板选择与附件 SHALL 原样保留，**不回填**缺省路径。新建数据库（`_onCreate`）与 `openAt` 测试路径 SHALL 镜像同一份 schema（含该列），既有规范要求不变。

#### Scenario: 版本 11 数据库无损升级

- **WHEN** 一个已有会话、消息、摘要、成员与附件的版本 11 数据库被期望版本 12 的代码打开
- **THEN** 执行 `ALTER TABLE sessions ADD COLUMN workspace TEXT`；既有数据全部可读，messages / sessions / summary_nodes / group_members 行数与升级前完全一致（验收读真实行数），所有既有会话的 `workspace` 为 `NULL`（= 用缺省，行为与变更前一致）

#### Scenario: 新建数据库直接含工作区列

- **WHEN** 从空目录创建版本 12 数据库
- **THEN** `CREATE TABLE sessions` 含 `workspace` 列，新建会话行的 `workspace` 为 `NULL`；升级后的结构与全新建库结构逐项一致（`PRAGMA table_info(sessions)`）

#### Scenario: 带工作区的会话往返

- **WHEN** 用一个已存在的目录调用 `SessionRepository.create(workspace: <路径>)`，随后按 id 读回该会话
- **THEN** 读回的 `Session.workspace` 与写入值逐字相等（库里该列的文本也相同）；不传该参数的会话读回 `NULL`

#### Scenario: 原地写工作区必须确认唯一行

- **WHEN** 对一个存在的会话调用 `updateWorkspace`，随后再对一个不存在的会话 id 调用同一个方法
- **THEN** 第一次更新恰好 1 行并读回新值；第二次显式失败并说明「没有更新到唯一既有行」，数据库不变（不产生半行、不伪造成功）

#### Scenario: 旧行的缺省语义

- **WHEN** 升级一个变更前创建的数据库后读出旧会话
- **THEN** 每条旧会话的 `workspace` 为 `NULL`，其消息、摘要、成员与模板选择不受影响；恢复路径据此使用既有缺省工作区，不报错
