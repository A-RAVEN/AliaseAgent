## MODIFIED Requirements

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

## ADDED Requirements

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
