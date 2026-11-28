## ADDED Requirements

### Requirement: 工作路径 RPC（创建时指定、切换与校验）

核心 SHALL 提供工作路径的读写面，参数名为 `workspace`（与既有 `group.create` 一致）。工作路径是**上下文的工作目录**：相对路径按它解析、文件工具以它为根、`run_command` 以它为缺省工作目录。它是「默认根 + 软围栏」，**不是沙箱**：本能力 MUST NOT 引入沙箱、审批、危险命令拦截，也 MUST NOT 把「没有沙箱」描述成缺陷。

- `session.create` SHALL 接受可选 `workspace`（非空字符串）。给了 workspace 时 SHALL 在插入会话行**之前**校验（绝对路径、存在、是目录）；不合法 ⇒ 返回 `-32602`（消息含路径与原因）且**不创建会话行**。合法 ⇒ 写入该行并返回 `{session}`（含 `workspace`）。只有空白字符的 `workspace` SHALL 视为省略（写 `NULL`、用缺省）；`group.create` 的 `workspace` SHALL 遵循同一口径（省略 / 空白 = `NULL`，非空不合法 ⇒ `-32602` 且不建组行）。
- `session.setWorkspace {sessionId, workspace}` SHALL 只用于单聊会话：校验通过后，若该会话已有在册实例 SHALL 更新其实例上下文的工作区，再写 `sessions.workspace`（核对恰好一行）并重读返回 `{session}`。会话不存在 / 参数非法 ⇒ `-32602`；会话是 `kind = group` ⇒ `-32602` 并指明改用 `group.setWorkspace`；该实例正在生成、或该会话正在切换模板 / 删除 ⇒ 返回可归因 busy，**不排队、不改任何值**。
- `group.setWorkspace {groupId, workspace}` SHALL 只用于组会话：校验通过后 SHALL 更新组上下文的工作区、写 `sessions.workspace`（核对恰好一行），并把新工作区**传播到该组所有在册成员实例的上下文**（成员继承组工作区，见 `agent-group-chat` 的「共享工作区继承」），返回 `{group}`。组不存在 / 参数非法 / kind 不匹配 ⇒ `-32602`；反应链或任一成员运行中 ⇒ 可归因 busy（不排队）。成员实例即时更新失败 ⇒ 返回可归因错误并点名成员（组与库已切换，成员轮开始会对齐；MUST NOT 静默）。
- `workspace.listDirs {path?}` SHALL 作为**文件夹选择对话框**的数据源：`path` 省略 / 只有空白 ⇒ 起点取核心的主目录（与缺省工作区同一口径），否则取该路径；返回 `{path, parent, directories:[{name, path}], exists, isDirectory}`。它 SHALL 只列**子目录**（MUST NOT 列文件）并按名字排序；`parent` SHALL 是上级绝对路径，文件系统根时为 `null`（Windows 盘符根除外，见下条）。路径不存在 / 不是目录 / 读不到 ⇒ `-32602`（消息含该路径与原因），MUST NOT 静默返回空列表。该能力 MUST NOT 依赖 C++ 侧新增接口（Dart 侧列目录即可）。
- `workspace.listDirs` SHALL 支持 Windows 的「此电脑」虚拟根（返工 12.11）：`path == "@drives"` 时返回本机逻辑盘作为 `directories`（每项 `name` 如 `C:`、`path` 如 `C:\`，按名字排序），`parent = null`、`isDirectory = false`（它不是真实目录，不能被选成工作路径）；Windows 盘符根（`C:\`）的 `parent` SHALL 是 `"@drives"`，从而「上级」可从盘符根回到「此电脑」并切换其它盘；POSIX 根 `/` 与 UNC 共享根的 `parent` 仍是 `null`，POSIX 调 `"@drives"` ⇒ 可归因 `-32602`（消息含「此电脑」）。盘符枚举 MUST 只用 Dart 标准库（如遍历盘符 + `Directory.existsSync`），MUST NOT 引入新依赖或起外部进程。
- 三个新方法名（`session.setWorkspace` / `group.setWorkspace` / `workspace.listDirs`）SHALL 出现在 `kCoreRpcMethodNames` 里、与 `_registerMethods` 的实现一致（漏注册抛 `StateError`），并 SHALL 在 `Docs/user-guide/web-core-shim.md` 的 RPC 表里各占独立一行（守护测试按第一列逐行核对）。
- `session.list` 与 `group.list` 的每一项 SHALL 序列化 `workspace`（字符串或 `null`；`null` = 未设置 / 用缺省），MUST NOT 静默丢弃该字段。
- `agent.send` 在恢复实例时发现持久化工作区不可用（不存在 / 不是目录）SHALL 返回可归因 `-32602`（消息含该路径与「切换到已存在的目录」的出路），MUST NOT 静默回落到缺省目录开始干活，MUST NOT 在空工作区上下文里发请求（文件工具会变成无边界）。
- 路径校验失败时 MUST NOT 改变任何状态：数据库不变、运行中的上下文不变、界面读回值不变。

#### Scenario: 创建会话时指定工作路径

- **WHEN** 客户端调用 `session.create {workspace: <一个已存在的绝对目录>}`
- **THEN** 新会话行的 `workspace` 等于该路径，`session.list` 读回同一个值；该会话首次发送时上下文以它为工作区（`get_workspace` 读回同一目录）

#### Scenario: 非法路径不建会话

- **WHEN** 客户端调用 `session.create {workspace: <不存在 / 相对路径 / 指向文件>}`
- **THEN** 返回 `-32602`，消息含该路径与原因；会话列表不新增任何行

#### Scenario: 切换单聊工作路径

- **WHEN** 客户端对一个已发送过消息的单聊调用 `session.setWorkspace {sessionId, workspace: <另一个已存在目录>}`
- **THEN** 返回重新读取的会话（`workspace` 为新值），库中该列已更新；该实例上下文的工作区同步切到新目录（`get_workspace` 读回），下一轮请求在新区目录里干活

#### Scenario: 切换失败不改任何状态

- **WHEN** 客户端调用 `session.setWorkspace` 且路径不存在 / 是文件 / 是空串 / 不是绝对路径
- **THEN** 返回 `-32602`（含路径与原因）；`sessions.workspace` 保持原值，运行中上下文的工作区保持原值，随后一次发送仍用原目录

#### Scenario: 方法用错对象被拒

- **WHEN** 客户端对组会话调用 `session.setWorkspace`，或对单聊会话调用 `group.setWorkspace`
- **THEN** 返回 `-32602` 并指明该用哪个方法；两边的库值与上下文工作区都不变

#### Scenario: 生成中与链运行中的切换被拒

- **WHEN** 单聊实例正在流式生成，或组内反应链 / 某成员正在运行，客户端调用对应的 setWorkspace
- **THEN** 返回可归因 busy（不排队、不中途改根），值不变；该轮 / 该链结束后再调用可成功

#### Scenario: 组的切换传播到成员

- **WHEN** 一个含两个成员实例的组调用 `group.setWorkspace {groupId, workspace: <新目录>}`
- **THEN** 组上下文、两个成员实例的上下文都切到新目录（分别 `get_workspace` 读回），库中组行 `workspace` 为新值；下一次成员轮在该目录里干活

#### Scenario: 列表返回工作路径

- **WHEN** 客户端调用 `session.list` 与 `group.list`，库里有设置过与未设置工作区的会话
- **THEN** 每一项都带 `workspace` 字段：设置过的为非空字符串，未设置的为 `null`（不是空串、不是缺字段）

#### Scenario: 方法清单与文档表一致

- **WHEN** 核心启动注册 RPC，并对照 `Docs/user-guide/web-core-shim.md` 的 RPC 表
- **THEN** `session.setWorkspace`、`group.setWorkspace` 与 `workspace.listDirs` 都能被调用，`kCoreRpcMethodNames` 与实现一致（漏注册抛错），且三处文档表各有一行（第一列是方法名）

#### Scenario: 列目录供文件夹选择

- **WHEN** 客户端调用 `workspace.listDirs`：一次省略 `path`，一次给一个同时含子目录与文件的目录，一次给一个不存在的路径
- **THEN** 省略时返回的 `path` 是核心主目录；给目录时 `directories` 只含子目录（不含文件、按名字排序），每项 `{name, path}` 的 `path` 是绝对路径，`parent` 是上级绝对路径（POSIX 根 / UNC 共享根为 `null`）；给不存在的路径 ⇒ `-32602` 且消息含该路径与原因（MUST NOT 静默返回空列表）

#### Scenario: 「此电脑」虚拟根与多盘切换

- **WHEN** Windows 上客户端调用 `workspace.listDirs {path: "@drives"}`，再对盘符根 `C:\` 调用一次
- **THEN** drives 根回包的 `directories` 含本机逻辑盘（每项 `name` 如 `C:`、`path` 如 `C:\`），`parent` 为 `null` 且 `isDirectory` 为 `false`；`C:\` 的 `parent` 是 `"@drives"`（「上级」可回到「此电脑」并切换其它盘）。POSIX 上 drives 根 ⇒ `-32602` 且消息含「此电脑」；POSIX 根 `/` 的 `parent` 仍是 `null`

#### Scenario: 持久化路径失效时拒绝发送

- **WHEN** 某单聊持久化的工作目录在磁盘上已被删除，**核心重启后**（该会话的运行实例需要重建）客户端调用 `agent.send`
- **THEN** 返回可归因 `-32602`，消息含该路径与「改到一个已存在的目录」的出路；MUST NOT 静默改用缺省主目录、MUST NOT 在空工作区上下文里发出请求（不产生 `tool.call`）
