## Why

用户要求把「工作路径」变成会话 / 群可看见、可切换的东西：群聊界面右侧上方显示这个群的工作路径并支持切换，单聊的工作路径放在标题附近；用户原话「工作区作用主要体现在上下文和工具调用」。现状有三处缺口：

1. **不持久化**：工作区是 sidecar **上下文**里的内存属性，`sessions` 表没有 workspace 列 ⇒ 自定义路径核心一重启就丢（`group-chat-layout` design D13 记录的已知限制：重启后回落 `ConfigService.homeDir`）。
2. **web 端没有入口**：`group.create` 虽收 `workspace`，但界面从不传、也没有切换控件；单聊完全没有设置路径的入口（只有 Flutter 测试用的 `setCurrentWorkspace`）。
3. **模型不知道自己在哪里**：系统提示词组装（`Agent.send` 的每轮装配）没有工作区段，模型只能靠工具报错反推当前目录；用户切了路径，模型也无从得知。

本 change 一次补齐「持久化 + 重启恢复」「RPC 读写与校验」「上下文注入」「单聊 / 群的切换入口」，并修掉创建上下文时设置工作区失败被静默吞掉的分支（失败后上下文工作区为空 = 文件工具对绝对路径不再设界）。

## What Changes

- **数据库**：`sessions` 增加可空 `workspace TEXT`（NULL = 未设置，沿用既有缺省 `ConfigService.homeDir`）。schema **v11 → v12**，只 `ALTER TABLE ... ADD COLUMN`，不回填、不删行；`_onCreate` 与 `openAt` 两条建库路径同步。`Session` 模型与 `SessionRepository` 读写该列，新增原地写入口并核对「恰好一行」。
- **恢复**：单聊恢复时把持久化工作区作为上下文缺省传给 `ensureContext`；组恢复时 `ensureMemberAgent` / `ensureGroupContext` 用组行的工作区（不再固定缺省）。重启后自定义路径**保留**（修掉 D13）。
- **校验**：新增路径校验/规范化入口（绝对路径、去成对引号、折叠 `..`、存在、是目录）；不合法 ⇒ 可归因错误、**任何状态都不改**。`ensureContext` 在带 defaultWorkspace 时先校验；`SidecarBridge.ensureContext` 设置工作区失败不再静默（新建的上下文也会被清掉，不留 allow-all 上下文）。
- **RPC**：`session.create` 增可选 `workspace`；新增 `session.setWorkspace`（单聊）与 `group.setWorkspace`（组，切换要**传播到成员实例的上下文**）；新增 `workspace.listDirs`（文件夹选择框的列目录：只列子目录、省略 `path` 从应用主目录开始、非法路径 `-32602`）；`session.list` / `group.list` 每项序列化 `workspace`；三个新方法名同步进 `kCoreRpcMethodNames` 与用户文档 RPC 表。非法路径 / kind 不匹配 / 会话不存在 ⇒ `-32602`；生成中 / 链运行中 / 切换删除中 ⇒ 可归因 busy（不排队、不改值）。
- **上下文注入**：每轮装配时读取该实例上下文**当前**工作区，把「当前工作区（工作路径）+ 相对路径规则 + 命令工具没有沙箱」写进系统提示词的稳定段落；切换在下一轮生效；读不到 / 为空时写明「当前没有可用工作区」并留一行日志（不静默省略、不伪装成某个目录）。
- **群成员继承**：`group.setWorkspace` 成功即更新组上下文、`sessions.workspace` 与**所有在册成员实例的上下文**；成员轮开始时再核对一次并自动对齐（某成员即时更新失败时，下一轮仍会收敛）。成员仍然没有私有工作区。
- **界面（web，用户实际使用的界面）**：群聊右栏**顶部（成员名单之上）**一个「群工作路径」栏、单聊头部**标题旁**显示当前路径（缺省时写明「缺省（应用主目录）」），长路径截断 + 悬停看全文；两处点「切换」都弹**文件夹选择框**（应用内的浏览框：子文件夹列表 +「上级」/ 面包屑 +「选择此目录」+「取消」，目录列表由核心的 `workspace.listDirs` 提供），单聊确认走 `session.setWorkspace`、群确认走 `group.setWorkspace`。失败在框内就地显示可归因错误、框不关闭、已保存路径不变。浏览器不能给出本机绝对路径的**系统**「文件夹对话框」，所以这是应用内的选择框 —— **用户只点选、不手输**（2026-11-27 用户明令：手输路径会打错）。
- **文档**：同一 change 更新 `Docs/user-guide/group-chat.md`、`web-core-shim.md`、`tools-file.md`、`troubleshooting.md` 与 `README.md` 里「工作区就是用户主目录」的旧口径，并同步两份文档守卫锚点。

## Capabilities

### New Capabilities

（无：工作路径复用既有的「上下文工作区」能力，本 change 只把它的持久化、RPC 与界面补齐，不引入新能力域。）

### Modified Capabilities

- `session-persistence`: 新增「会话工作区列与 v11→v12 迁移」要求 —— `sessions.workspace` 可空、`Session` / `SessionRepository` 读写、升级只加列、`updateWorkspace` 必须确认恰好一行、旧行 NULL = 用缺省。
- `web-core-shim`: 新增「工作路径 RPC（创建时指定、切换与校验）」要求 —— `session.create` 的 `workspace`、`session.setWorkspace`、`group.setWorkspace`、`workspace.listDirs`（文件夹选择框的列目录）、`session.list` / `group.list` 的 `workspace` 序列化、`-32602` / busy 语义、方法清单与文档表一致；并明确工作路径**不是**沙箱。
- `agent-group-chat`: 修改「共享工作区继承」（持久化、切换传播到成员、成员轮对齐、目录失效可归因、删掉「重启回落缺省」的已知限制）、「群上下文跨核心重启存活」（重启用持久化工作区重注册）与「群聊 RPC 面」（方法清单补 `group.setWorkspace`、`group.list` 补 `workspace`、方法计数场景改 11）；新增「组工作路径切换」与「web 组视图的群工作路径栏」。
- `agent-runtime`: 新增「系统提示词注入当前工作区」要求 —— 每轮读取、下一轮生效、读不到时写明不可用、如实告知命令工具没有沙箱、段落来自代码常量且不替换模板提示词。
- `web-chat-screen`: 新增「单聊头部工作路径与切换」要求 —— 标题旁显示（缺省文案 / 截断 + `title` 全文）、点「切换」弹**文件夹选择框**（点选目录，不手输）、`session.setWorkspace` payload、失败在框内可归因且不关框、空选中不渲染。
- `user-documentation`: 修改「文件工具工作区边界」的文档口径 —— 工作区是相对路径的根、越界被拒；**缺省**是用户主目录，但单聊 / 群可以改到指定目录；不再断言「工作区就是用户主目录」。

## Impact

- **数据库**：`sessions` 加一列 `workspace TEXT`（可空），schema v11→v12；不新增表、不删行、不回填；旧库升级后行数不变。工作路径**不是** `config.json` 键，不新增配置项、不新增依赖。
- **代码（Dart）**：`lib/models/session.dart`、`lib/services/session_repository.dart`、`lib/services/database_service.dart`、新增 `lib/services/workspace.dart`（校验 / 规范化 / 系统提示段常量）、`lib/services/agent.dart`（`ensureContext` 校验、`setWorkspace`、每轮注入）、`lib/services/agent_factory.dart`（恢复时用持久化工作区）、`lib/services/sidecar_bridge.dart`（设置失败不再静默）、`lib/services/group_service.dart`（落库、切换传播、成员轮对齐）、`lib/core/headless_core.dart`（RPC 与序列化、方法清单）、`lib/main.dart`（Flutter 侧可归因错误出口）。
- **代码（web）**：`web/src/protocol.ts`（`Session.workspace`）、`web/src/App.tsx`（单聊切换接线 + `workspace.listDirs` 数据源）、`web/src/components/ChatScreen.tsx`（标题旁路径 + 打开选择框）、新增 `web/src/components/FolderPickerDialog.tsx`（文件夹选择框）、`web/src/group/GroupView.tsx`（右栏顶部「群工作路径」+ 同一个选择框）、新增 `web/src/workspace/model.ts`（显示文案）与 `web/src/workspace/picker.ts`（选择框纯逻辑：起点 / 上级 / 面包屑 / 请求参数）。
- **测试**：`test/unit/workspace_paths_test.dart`（新）、`test/integration/schema_migration_test.dart`、`test/integration/workspace_persistence_test.dart`（新）、`test/integration/workspace_prompt_test.dart`（新）、`test/integration/web_core_rpc_test.dart`（含 `workspace.listDirs`）、`test/integration/group_workspace_test.dart`、`test/integration/group_context_restore_test.dart`、`test/unit/group_docs_test.dart`、`test/unit/user_docs_test.dart`、`web/src/workspace/model.test.ts`（新）、`web/src/workspace/picker.test.ts`（新）、`web/e2e/group.mjs`、`integration_test/web_workspace_live_support.dart` 与两个入口（新）。
- **文档**：`Docs/user-guide/group-chat.md`、`Docs/user-guide/web-core-shim.md`、`Docs/user-guide/web-management.md`（一句话指路：工作路径切换不在管理页）、`Docs/user-guide/tools-file.md`、`Docs/user-guide/troubleshooting.md`、`README.md`，以及四个文档守卫的过时锚点 / 方法清单。
- **明确不改**：C++ sidecar（`set_workspace` / `get_workspace` 已存在，不改工具边界与命令执行，故不动 `sidecar/test`）；`ConfigService.homeDir` 的缺省口径；Flutter 桌面界面（用户实际界面是 web 客户端：单聊、群聊、管理页都在 web）；任何沙箱 / 审批 / 危险命令拦截（`Docs/rejected-approaches.md` 24、25 已否决，本 change 不重提，也不把「没有沙箱」写成缺陷）。
