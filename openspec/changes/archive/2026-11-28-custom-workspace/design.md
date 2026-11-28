## Context

工作区在代码里是**上下文级**属性：`sidecar.ensureContext(handle, defaultWorkspace)` 新建上下文时写入（`Agent.ensureContext`、`GroupService.ensureGroupContext`），`sidecar.getWorkspace(handle)` 只读读回，C++ 侧 `set_workspace` 拒绝空串 / 非法路径 / 非目录，并用 `GetFullPathNameA` 规范化。文件工具的边界判定（`tools::is_within_workspace`）与 `run_command` 的缺省工作目录都读这个值；**工作区为空串时 `is_within_workspace` 返回 true（等于不设界）**，所以「设工作区失败」不能当无事发生。

现状（本 change 的起点）：

- `sessions` 表没有 workspace 列；`group.create` 收 `workspace` 但只作用于 sidecar 内存，**核心重启后组上下文按缺省 `ConfigService.homeDir` 重建**（`group-chat-layout` design D13 记录为已知限制）。
- `SidecarBridge.ensureContext` 在 `created == true` 时调用 `setWorkspace`，但**忽略它的返回值**；路径不可用时上下文留在空工作区（文件工具对绝对路径不设界）。
- `Agent.send` 每轮装配系统提示词的段落是：模板提示 → 群成员名单（组）→ `guard.inject()` → 技能段 → 日期 → 反应提示（组），**没有工作区**，模型不知道自己在哪个目录干活。
- web 端没有任何工作路径入口；`session.list` / `group.list` 不返回工作区；单聊工作区只为 Flutter 测试保留了一个直写 sidecar 的入口。
- 用户实际使用的界面是 web 客户端（桌面壳内嵌 WebView2）；Flutter 界面里群聊只有「请在 web 组视图打开」的占位。用户明令「群聊界面右侧上方加栏、单聊工作路径放在标题附近」，落点就是 web 的单聊主区头部与群视图右栏。
- 产品是**零审批、全权限**设计（`Docs/rejected-approaches.md` 24、25）：工作区是「默认根 + 软围栏」，**不是沙箱**；`run_command` 仍以用户权限执行、不可撤销。

约束：

- 数据库演进只允许「只加列不改行」的迁移，`_onCreate` 与 `openAt` 两条建库路径必须镜像同一份 schema。
- 用户文档与守卫测试（`test/unit/group_docs_test.dart`、`test/unit/web_core_docs_test.dart`、`test/unit/user_docs_test.dart`）当前把「工作区就是用户主目录」「重启后工作区回落缺省」当锚点，改行为必须同 change 改文档与锚点。
- 禁发明上下限魔数（本 change 不需要任何新数字）；禁写死行号；`tasks.md` 序号即执行顺序。

## Goals / Non-Goals

**Goals:**

1. 单聊每个会话一个工作区、每个群一个共享工作区（成员继承），**单一工作区**，不做多工作区。
2. 工作路径持久化到 `sessions.workspace`，非破坏升级（v11 → v12），核心重启后**保留**自定义路径（修掉 D13）。
3. 提供可校验的写入面：`session.create` 可选 workspace、`session.setWorkspace`、`group.setWorkspace`；非法路径给可归因错误且不改任何状态；列表接口返回 workspace。
4. 每轮把**当前实际工作区**注入系统提示词，模型知道自己在哪个目录、相对路径按谁解析；切换后下一轮生效。
5. 群切换**真的传播**到在册成员实例的上下文，并加一道「成员轮开始对齐」的保险。
6. web 界面：群聊右栏顶部「群工作路径」栏（显示 + 切换）、单聊头部标题旁显示 + 切换；长路径截断、悬停 / 点开看全文；失败就地可归因。
7. 同 change 更新用户文档、守卫锚点与 live 验收，并留下能变红的测试。

**Non-Goals:**

- 不做多工作区 / 工作区列表 / 最近使用目录；一个会话（或一个群）只有一个工作区。
- **不引入沙箱、审批、危险命令拦截，也不把「没有沙箱」写成缺陷**（台账 24、25 已否决；`run_command` 的权限与不可撤销性只如实告知）。
- 不改 `ConfigService.homeDir` 的缺省口径（缺省仍是应用主目录；用户没要求改）。
- 不改 C++ sidecar：`set_workspace` / `get_workspace` / 工具边界 / 命令执行都不动，故不新增 `sidecar/test` 用例。
- 不做「真·群公告」（公告正文、编辑、历史、未读）；那个栏只装工作路径这一件事。
- 不新增 Flutter 界面入口（Flutter 侧只把路径不可用变成可归因错误，不崩、不静默回落）。
- 不做系统文件夹对话框（原因见 D10）；不做工作区切换的历史记录或撤销。
- 不新增 `config.json` 键、不新增依赖、不适用任何上下限数字。

## Decisions

### D1 粒度：每个单聊一个工作区、每个群一个共享工作区；单一工作区

工作区是「相对路径默认根 + 命令默认 cwd」，天然是**一个目录**：多工作区需要模型自己选根、需要第二套路径解析与优先级规则，而跨目录协作已经由绝对路径 / 命令本身覆盖。所以不做多工作区。组沿用既有「成员继承组工作区、成员没有私有工作区」的语义（`agent-group-chat` 的「共享工作区继承」），本 change 只把它持久化并把切换做成可传播的动作。

### D2 存储：`sessions.workspace TEXT`（可空），v11 → v12

- 一列同时服务单聊与群（组的工作区就是组行的那一列），不新建表、不建第二份映射。
- `NULL` 的语义是**未设置**，恢复时用既有缺省 `ConfigService.homeDir`；不把缺省值写进库（避免把「缺省」冻成一个用户没选过的路径）。
- 迁移只 `ALTER TABLE sessions ADD COLUMN workspace TEXT`；既有行保持 NULL。**不回填**：回填 homeDir 会让「缺省」变成「用户显式选过主目录」，而且 `homeDir` 可能因用户环境变化而与旧值不同。
- `Session.fromRow` / `toRow` 用同一列名 `workspace`；`SessionRepository.create` 接受可选 `workspace`；`SessionRepository.updateWorkspace(id, value)` 返回受影响行数，调用方必须核对**恰好一行**（0 行 = 会话不存在 / 已删 ⇒ 显式失败，不假成功）。
- 备选「放进 `config.json` 按会话 id 存一份」被否：会话是数据库对象，配置与库会分叉；备选「按群单独建表」被否：单聊也需要同一列，两张表只会让恢复路径写两遍。

### D3 恢复应用点：只传「缺省」，不覆盖同进程已有工作区

- 单聊：`AgentFactory.create` 里把 `child?.workspace ?? session.workspace` 传给 `agent.ensureContext(defaultWorkspace: ...)`（`child` 是一次性子运行，仍优先父上下文实际工作区）。`null` ⇒ 不传，由 `Agent.ensureContext` 沿用 `ConfigService.homeDir`（缺省不变）。
- 群：`GroupService.ensureMemberAgent` 调 `ensureGroupContext(group.id, workspace: group.workspace)`；`group.create` 落库后也走同一入口。`ensureGroupContext` 保持既有语义：`created:false`（同进程上下文仍在）**不覆盖**已有值；核心重启必然 `created:true` ⇒ 用持久化值重注册。
- 由此修掉 D13：重启后组 / 单聊都落在用户设置的目录，不再回落缺省。
- 备选「每次取工作区前都 `set_workspace` 强制对齐持久化值」被否：会把 live 测试与 Flutter 测试入口直接设进上下文的值盖掉，且把「只读读取」变成写操作；显式切换有独立入口（D6），不靠恢复路径顺手改。

### D4 路径校验与规范化；落库值 ≠ 生效值但指向同一目录

新增 `lib/services/workspace.dart`（纯 Dart，两个后端共用）：

- `stripWorkspaceInput(raw)`：去首尾空白；**去掉一对匹配的双引号**（Explorer「复制为路径」会带引号）；再 `p.normalize` 折叠 `..` 与重复分隔符（保留用户的分隔符风格）。
- `workspaceProblem(path)`：空串 / 非绝对路径 / 不存在 / 不是目录，各返回一句可归因原因；合法返回 `null`。**先校验再写入**，所以非法输入不会留下半状态。
- **口径**：`sessions.workspace` 存的是「设置值」（规范化后的输入）；上下文里的是「生效值」（C++ `GetFullPathNameA` 规范化、正斜杠）。两者指向同一目录，显示与断言用 `package:path` 的 `p.equals` 比较。UI 显示设置值；系统提示注入生效值（D5）。这条差异只出现在分隔符 / 大小写上，不隐藏任何东西。
- 校验点：`session.create`（有 workspace 时，在插行之前）、`session.setWorkspace`、`group.setWorkspace`、`group.create`（有 workspace 时）、`Agent.ensureContext`（带 defaultWorkspace 时，在调用 sidecar 之前）、`GroupService.ensureGroupContext`。全部用同一函数，不写第二套规则。
- **空值的两种入口语义**：`session.create` / `group.create` 的 `workspace` 省略或只有空白 ⇒ 视为**未设置**（写 NULL、用缺省，与变更前一致）；显式非空但不合法 ⇒ 可归因错误。`session.setWorkspace` / `group.setWorkspace` 是显式动作，空串 / 只有空白 ⇒ 错误（本 change 不做「恢复缺省」的清除语义；要回主目录就把主目录设进去）。

### D5 上下文注入：每轮读、下一轮生效、读不到要写明

- 新增代码常量（`lib/services/workspace.dart`）：`kWorkspacePromptHeading` 标题、`workspacePromptSection(path)` 正常段、`workspaceUnavailablePromptSection(reason)` 不可用段。段内容说明三件事：相对路径以它为根、文件工具越界会被拒绝、`run_command` 的缺省工作目录是它且**命令本身没有沙箱、以用户权限执行、不可撤销**（如实告知，不是缺陷声明）。再加一句「工作路径可能被切换，每轮以此处为准」。
- 读取时机：`Agent.send` 在**一轮开始时**读一次 `sidecar.getWorkspace(handle)` 并拼进本轮的每个模型请求（工具循环的后续请求沿用同一个值），所以切换在**下一轮**生效、在途轮不中途换根。备选「每个模型请求各读一次」被否：会让同一轮里前后两个请求看到不同工作区，工具边界在同一轮内跳变无法解释。
- 位置：`config.systemPrompt` → （组）成员名单 → `guard.inject()` → **工作区段** → 技能段 → 日期 → （组）反应提示。只追加，不替换模板提示词 / 角色说明 / 反应提示；摘要请求的系统文本不含该段（摘要不是 Agent 轮）。
- 读失败（`get_workspace` 返回 `ok:false`）或读到空串：**不省略整段**，注入「当前没有可用工作区（原因：…）」的显式说明并留一行日志；该轮继续（不因读取失败丢弃整轮）。这样既不把缺省伪装成某个目录，也不让模型以为「没有限制」。组的分界：成员轮的组工作区读取失败由 D7 的对齐步骤在装配前以 `workspace_unavailable` 拒绝，不走这条「不可用段」分支。
- `ContextSnapshot.systemPrompt` 因此包含该段 ⇒ 「真实上下文」屏与 `group.view` 天然可观察（测试与 live 都断言实际发出的文本，不读内部变量）。

### D6 RPC 面与错误语义

| 方法 | 参数 | 行为 / 返回 |
|---|---|---|
| `session.create` | `title?` / `agentType?` / `workspace?` | 有 workspace 时先校验，再插行；返回 `{session}`（含 workspace） |
| `session.setWorkspace` | `sessionId` / `workspace` | 单聊专用；校验 → 若有在册实例则 `sidecar.setWorkspace`（失败即中止）→ 落库（核对一行）→ 重读返回 `{session}` |
| `group.setWorkspace` | `groupId` / `workspace` | 组专用；校验 → `ensureGroupContext` + `sidecar.setWorkspace(groupId)`（读回确认为非空）→ 落库（设置值）→ 传播到在册成员（D7）→ 返回 `{group}` |

- **kind 不匹配显式拒绝**：`session.setWorkspace` 遇组会话、`group.setWorkspace` 遇单聊 ⇒ `-32602` 并指明该用哪个方法。
- **非法路径**（空、非绝对、不存在、非目录）⇒ `-32602`，消息含路径与原因；**数据库与运行上下文都不改**（先校验再动手）。
- **busy 不排队、不改值**：单聊在该实例正在生成 / 模板切换中 / 删除中；组在反应链或任一成员运行中（复用 `GroupService.isGroupBusy`）。与 `group.update` 的 busy 口径一致。
- 成功路径的顺序固定为「先让上下文生效、再落库、再重读」，任一步失败都返回可归因错误；落库前失败即什么都没变，落库失败则报「上下文已切换但未持久化」并把实际值写进消息（不假装成功）。
- `session.list` / `group.list` 每项新增 `workspace`（字符串或 null）；`group.create` 有 workspace 时落库（重启 / 切走再切回都还在）。
- 两个方法名同步进 `kCoreRpcMethodNames`；用户文档 RPC 表逐行补上（`test/unit/web_core_docs_test.dart` 按表行解析，缺行即红）；群文档的 RPC 表也补 `group.setWorkspace`（`test/unit/group_docs_test.dart` 按 `group.*` 第一列校验，且它把群聊方法数写死为 10 ⇒ 同批改成 11）；主 spec 的「群聊 RPC 面」也按 MODIFIED delta 补进方法清单、`group.list` 的 `workspace` 与「十一个群聊方法」场景。
- 备选「复用一个通用 `session.update`」被否：现有 `session.*` 没有通用 update，`group.update` 明确「只做组设置、不扩成通用 update」；新增具名方法让 busy 语义与 kind 守卫各自明确。

### D7 群切换传播 + 成员轮对齐（双保险）

1. `group.setWorkspace` 成功时，遍历 `GroupService` 里该组的**在册成员实例**（`agents.lookup(GroupMember.memberHandle(groupId, memberId))`，用与 `GroupMemberContext.handle` 同一个静态生成函数，不手拼字符串），对每个实例：`ensureContext(defaultWorkspace: <设置值>)`（上下文丢失时直接建对）+ `sidecar.setWorkspace(handle, <设置值>)`（各自由 sidecar 规范化）；失败则收集并在错误消息里点名成员（此时组与库已切换，成员下一轮会对齐，不静默）。
2. **成员轮开始对齐**：`_runMemberRound` 在装配前读组上下文当前工作区（必要时先 `ensureGroupContext`），与成员上下文的工作区比较；不一致就 `set_workspace` 到组值并留一行日志；读不到 / 为空 ⇒ `GroupException('workspace_unavailable')`（沿用既有「空工作区不建成员」的口径）。这让「成员继承组工作区」成为每轮成立的不变量，而不只依赖切换那一刻的传播。
- 备选「切换时销毁并重建全部成员实例」被否：重建会丢成员视图 / 缓存 / 在途状态，代价远大于两次 FFI 调用；备选「只改显示、下轮再说」被否：那就不是继承，只是界面撒谎。

### D8 单聊界面：标题旁的工作路径（web）

- `ChatScreen` 是**纯展示容器**（不持 client）：新增可选 props `workspace: string | null` 与 `onSetWorkspace?: (path: string) => Promise<string | null>`（返回 `null` = 成功，字符串 = 可显示的失败原因）。不传回调时不渲染该控件 ⇒ 现有测试挂架与注入屏不受影响。
- 标题列（`current-session-title` 那块）下方一行：`工作路径` 标签 + 路径文本（`data-testid="workspace-path"`，`truncate` + `title` 给全文；null 时显示「缺省（应用主目录）」）+「切换」按钮（`data-testid="workspace-edit"`）。
- 点「切换」展开就地编辑器：`input`（预填当前设置值，全文可见）+「保存」/「取消」；保存调 `onSetWorkspace`。失败时把错误显示在 `data-testid="workspace-error"`（就地、不关编辑器、不改已保存路径）。成功关编辑器。**⚠ 这一条已被 D15 取代**（返工：用户明令不要手输，改成文件夹选择对话框）；`workspace` / `onSetWorkspace` 两个注入与失败语义不变，另加 `onListWorkspaceDirs`。
- `App` 负责 RPC：`session.setWorkspace {sessionId, workspace}` → 用返回的 `{session}` 替换列表里那一行（不动选中态、消息、滚动、快照）；失败把错误文本交回组件。
- 协议类型：`Session.workspace: string | null` 是**必填**（核心每次序列化都写，`null` = 未设置）；`web/test/harness` 与 `protocol.test.ts` 里的 `Session` / `GroupSummary` 字面量同步补 `workspace: null`，由 `npm run build` 的 `tsc --noEmit` 逐个核对。
- 空选中（`sessionSelected == false`）不渲染该控件；群聊主区不渲染它（群有自己的栏）。

### D9 群界面：右栏顶部「群工作路径」栏（web）

- 位置：`GroupView` 右侧 `<aside id="group-members">` 的**最顶部**，在「成员」标题与成员名单**之上**（用户要求「右侧上方加栏，下面指明工作路径」）。`<aside>` 是群聊标签右栏；窄屏（< `xl`）它整体变成抽屉，栏随成员名单进抽屉——不另做一套浮层。
- 结构：`data-testid="group-workspace"` 卡片，标题「群工作路径」+「切换」按钮 + 路径文本（`data-testid="group-workspace-path"`，`truncate` + `title`；null 显示「缺省（应用主目录）」）；展开后就地编辑（`group-workspace-input` / `-save` / `-cancel` / `-error`），保存走 `group.setWorkspace`，成功后 `onReload()`。**⚠ 就地编辑已被 D15 取代**：现在点「切换」弹文件夹选择框，卡片里只剩「切换」按钮与路径文本。
- 链运行中禁用「切换」（核心也会 busy 拒绝；界面先禁用并给可读原因，避免点了才知道）。已移除成员、成员卡片、齿轮面板、双标签、抽屉与滚动行为一律不动。
- **这个栏只装工作路径**：不写公告正文、不加编辑公告 / 历史 / 未读；`data-testid` 也不叫 announcement。用户诉求里的「群公告栏」按用户自己闭合的口径在这里就是工作路径栏，不再扩成真·公告功能。

### D10 为什么不是系统文件夹对话框（浏览器限制）— 结论已由 D15 改写

浏览器拿不到本机绝对路径：`<input type="file" webkitdirectory>` 只给相对文件名，`showDirectoryPicker()` 只给目录句柄与名字，都不构成 sidecar 要的绝对路径；核心是无头进程、没有 UI 线程去开系统对话框（从核心弹窗还会脱离 WebView2 的父窗口）。所以「切换」**不能**是系统文件夹对话框。本 change 最初的落点是「路径输入 + 核心校验」；**2026-11-27 用户明令不要手输**（会打错字），改为 D15 的**应用内文件夹选择框**（目录列表由核心的 `workspace.listDirs` 提供）：浏览器限制仍然成立，只是不再让用户敲路径。

### D11 桥层静默失败的修法

`SidecarBridge.ensureContext` 在 `created && defaultWorkspace != null` 时若 `setWorkspace` 返回错误：**先 `disposeContext` 清掉刚建的空工作区上下文，再抛 `StateError('set_workspace failed: …')`**。理由：留在空工作区的上下文一旦被后续 `ensure` 复用，文件工具对绝对路径就不设界（静默 allow-all 正是本 change 要消灭的形态）。`Agent.ensureContext` / `GroupService.ensureGroupContext` 在调用桥之前先用 D4 校验，把绝大多数失败拦在「不产生任何上下文」之前；桥里的处置只兜竞态（目录在校验后被删）。这条失败路径由真实 DLL 的 `test/unit/sidecar_bridge_test.dart` 覆盖；`FakeSidecar` 只保留既有的调用记录（`setWorkspaceCalls` / `ensureContextDefaultWorkspaces` / `stubWorkspace`），不模拟桥的处置。

### D12 测试策略（便宜层够用就不往贵层堆）

- **纯逻辑 / 常量** → `test/unit/workspace_paths_test.dart`：去引号与 normalize、四类不合法、提示段全文（含「没有沙箱」与「工作路径」）、缺省路径时段的形态。
- **桥层（真实 DLL）** → `test/unit/sidecar_bridge_test.dart`：`ensureContext` 带不存在的 defaultWorkspace 必须抛错且**不留空工作区上下文**（`getWorkspace` 变 `unknown_context`），合法目录 `created:true` 且读回同一目录；这条是 D11 的红靶（改前静默成功）。
- **测试夹具（编译面）** → 三个 `implements SessionRepository` 的夹具（`test/widget/helpers/fakes.dart` 的 `FakeSessionRepository`、`delete_session_round_test.dart` 的 `_RecordingSessionRepo`、`agent_session_restore_test.dart` 的 `_FakeCreateSessionRepository`）随 `create(workspace:)` 与 `updateWorkspace` 的接口变更同步补齐；这是接口变更的编译面，不是产品行为。
- **数据库 / 迁移 / 持久化** → `test/integration/schema_migration_test.dart`（新增 v11 夹具 + v12 升级：只加列、行数不变、workspace 为 NULL、新建库含列）与 `test/integration/workspace_persistence_test.dart`（模型 / 仓储往返、`updateWorkspace` 核对一行、重启恢复单聊用持久化值、旧行 NULL 用缺省、`ensureContext` 缺目录抛可归因错误且**没有**调用 sidecar / 没留下空工作区上下文）。
- **组行为** → `test/integration/group_workspace_test.dart`（`group.create` 落库/缺省、成员继承、`group.setWorkspace` 更新组上下文 + 落库 + 传播到两个成员 handle、链运行中 busy、非法路径不改任何状态、成员轮对齐（把某成员上下文改歪后跑一轮会回正））与 `test/integration/group_context_restore_test.dart`（**改**既有「重启回落缺省」用例为「重启保留」；同进程幂等不覆盖；`ensureMemberAgent` 传给统一入口的是组行的工作区，不再是 homeDir；重启后目录已被删 ⇒ 重注册时可归因）。
- **RPC** → `test/integration/web_core_rpc_test.dart`（`session.create` 带 workspace / 非法路径不建行、`session.setWorkspace` 的 kind / busy / 失败不动库、`session.list` 与 `group.list` 序列化 workspace、方法清单与实现一致）；组 RPC 的成员传播与 busy 放 `group_workspace_test.dart`（走 `GroupCoreHarness` 的真 WS）。既有 `test/integration/group_reaction_rpc_test.dart` 里的群聊方法清单与计数（现在写死 10）随新增方法改成 11，否则它会红——这是方法清单的同步，不是放宽断言。
- **上下文注入** → `test/integration/workspace_prompt_test.dart`：断言 FakeSidecar 记录的**实际请求** `systemPrompt` 含标题常量与路径（单聊与群成员各一条）；切换后再发一轮 ⇒ 第二轮含新路径、第一轮不含；`get_workspace` 失败 / 空串 ⇒ 请求里是「不可用」段且整轮仍完成；模板提示词与反应提示仍在（追加不替换）。红靶打输入通道（请求里的 systemPrompt），不打模型输出。
- **web 纯逻辑** → `web/src/workspace/model.test.ts`（`workspaceLabel(null)` 的缺省文案、`workspaceLabel(path)`、`isWorkspaceSubmissionValid` 空输入判定）与 `web/src/workspace/picker.test.ts`（D15：对话框起点 / 上级 / 面包屑 / 请求参数是否省略 `path`），`npm test` 顺带跑 `tokens.test.ts`（新组件禁裸值）。
- **web 渲染 / 交互** → `web/e2e/group.mjs`（puppeteer + 假核心）：群的栏在成员名单**之上**、路径显示与 `title` 全文、点「切换」→ 文件夹选择框 → 点进子目录 /「上级」→「选择此目录」的 `group.setWorkspace` payload 逐字（`groupId` / `workspace`）、成功后路径更新、框内就地报错且路径不变、框的层级盖住群顶栏、用户不需要手输（框内 `input` / `textarea` 数为 0）、链运行中禁用、窄屏在抽屉内；单聊头部路径显示与 `session.setWorkspace` payload、未设置时的起点 = 核心主目录且请求不带 `path`、切会话后显示新会话路径、空选中不渲染。
- **真模型 live** → `integration_test/web_workspace_live_support.dart` + `integration_test/web_workspace_live_test.dart` + 无窗口镜像 `test/live/web_workspace_live_test.dart`：临时库 + 真实配置，经 `session.create {workspace}` / `session.setWorkspace` 建两个不同夹具目录，各发一条真模型消息（复用 `web/e2e/smoke.mjs` 驱动无头 Edge），断言 `context.snapshot` 的 `system` **含该轮生效路径与标题常量**、切到第二个目录后第二轮含新路径且不含旧路径，并留两张截图做视觉验收。路径断言按规范化比较（sidecar 读回是正斜杠形式），不拿盘符原串直接 `contains`。
- **不适用层**：`sidecar/test`（不改 C++）、`test/widget`（不改 Flutter 控件）、`test/smoke`（无构建/启动改动）。四个文档守卫（`web_core_docs_test` / `web_management_docs_test` / `group_docs_test` / `user_docs_test`）与文档同批改锚点 / 清单，只改过时锚点与新增方法清单，不放宽其它断言。

### D13 文档同步与守卫

- `Docs/user-guide/group-chat.md`：建组小节改成「工作路径可设、会持久化、重启仍生效」；新增「群工作路径」栏的操作说明（含窄屏在抽屉里、文件夹选择框的确认失败文案、链运行中不能切）；删除「重启后工作区回落缺省」的已知限制段；RPC 表补 `group.setWorkspace`；补 `界面文案（web）：` 行（`群工作路径` / `切换` / `缺省（应用主目录）`），`test/unit/group_docs_test.dart` 会把它们逐字对到 `GroupView.tsx`（框内文案在共享组件里，不挂这条标记）。
- `Docs/user-guide/web-core-shim.md`：RPC 表补 `session.setWorkspace` / `group.setWorkspace` / `workspace.listDirs`（返工 D15），并更新 `session.create` / `session.list` / `group.create` / `group.list` 行的参数与返回；新增「工作路径（单聊 / 群）」操作段（位置、**文件夹选择框**的点选手势、报错、浏览器不能给系统文件夹对话框的限制）；已知限制写明「工作路径是默认根 + 软围栏，命令工具没有沙箱」。
- `Docs/user-guide/tools-file.md`、`troubleshooting.md`、`README.md`：把「工作区就是你的用户主目录」改成「**缺省**是用户主目录；单聊 / 群可以改到指定目录」，越界拒绝的表述与示例保持；README 的群聊条目与「两条最容易踩的前提」同步。
- `Docs/user-guide/web-management.md`：补一句「工作路径切换不在管理页」并写出三个方法名（`session.setWorkspace` / `group.setWorkspace` / `workspace.listDirs`）——`test/unit/web_management_docs_test.dart` 对 `kCoreRpcMethodNames` 做整篇子串核对，新方法名不在该文档里会红。
- `test/unit/user_docs_test.dart`：把新文档里用反引号写出的 `workspace` 登记进 `_otherCodeNames`（指向 `lib/models/session.dart`，那里确实有该字段）；返工 D15 再补 `parent` / `directories` / `exists` 三个回包字段（指向 `lib/services/workspace.dart`），其余断言不动。
- `test/unit/group_docs_test.dart`：⑨ 的锚点 `重启后工作区回落缺省` 换成新文档里的实际句子（`重启后工作区保留`）；① 里 `kCoreRpcMethodNames.where((m) => m.startsWith('group.')).length` 的硬编码期望 10 改成 11（`group.setWorkspace` 是新增的群聊方法，用例标题与 reason 文字同步），只改这两处。
- `test/unit/web_core_docs_test.dart` 不改代码：它按 RPC 表首列核对 `kCoreRpcMethodNames`，新方法进常量后必须进文档表，自动变红/变绿。

### D14 不发明数字、不做沙箱

本 change 不引入任何新的上下限 / 超时 / 重试 / 批次数：路径校验只有布尔判断，界面没有分页与截断阈值（截断用 CSS 的 `truncate` + `title`），busy 判定复用既有状态。工作区**不是安全边界**：文件工具越界拒绝是既有行为（`Access denied: path outside workspace`），`run_command` 的 `workdir` 越界拒绝也是既有行为，但命令本身仍以用户权限执行、可访问别处、不可撤销——系统提示与用户文档都如实这么写，不承诺沙箱。

### D15 返工：工作路径改成「文件夹选择对话框」（2026-11-27 用户明令）

用户原话：「我不喜欢手动输入路径，手动输入可能会输入错，帮我加返工任务改成弹个路径选择框」。手输是错误来源，所以交互从「输入框」改成「点选目录」；本设计 D8 / D9 的「就地编辑器」与 D10 的「路径输入」结论**被本节取代**（D10 的浏览器限制仍然成立）。

1. **核心新增 `workspace.listDirs {path?}`**（进 `kCoreRpcMethodNames` 与文档 RPC 表）：省略 / 只有空白的 `path` ⇒ 起点取应用主目录（`HeadlessCore.homeDir` 可注入，缺省 `ConfigService.homeDir`；测试注入临时目录，**不列举用户真实主目录**）；返回 `{path, parent, directories:[{name, path}], exists, isDirectory}`。只列**子目录**（用户选的是工作目录，文件不列）、按名字排序；`parent` 用 `p.dirname` 算且在文件系统根为 `null`；路径不存在 / 不是目录 / 读不到 ⇒ `-32602`（消息含路径与原因），**不静默返回空列表**。**不改 C++**：Dart 侧 `Directory.listSync` 够用（`sidecar/` 一行不动）。
2. **web 新增 `FolderPickerDialog`**（`web/src/components/FolderPickerDialog.tsx`）：模态框，`z-50`（必须盖住群视图顶栏 `z-30` 与 `panel-overlay` 的 `z-40`）；内容 = 标题 + 面包屑 + 只读当前路径（`truncate` + `title`）+ 子文件夹列表 +「上级」+「选择此目录」+「取消」。打开时列举起点；进子目录 / 点面包屑 /「上级」都重新列举（请求带序号，晚到的旧回包被丢弃）；**框内没有任何文本输入**。确认失败 ⇒ 错误就地显示、框不关、已保存路径不变；「取消」/ Escape 不发写请求。纯逻辑（起点、上级、面包屑、请求参数）在 `web/src/workspace/picker.ts`，由 `picker.test.ts` 钉住。
3. **接线**：单聊「切换」→ 框 → `session.setWorkspace`（App 仍用返回的 `{session}` 替换列表那一行，不动选中 / 消息 / 快照）；群「切换」→ 同一个框 → `group.setWorkspace` → `onReload()`；群链运行中按钮仍禁用。原「就地编辑器」节点（`workspace-input` / `workspace-save` / `workspace-cancel`、`group-workspace-input` / `-save` / `-cancel`）**删除**，e2e 断言这些节点数为 0。
4. **测试**：核心 RPC 在 `test/integration/web_core_rpc_test.dart`（临时目录夹具 + `homeDir` 注入：省略 `path` 时的起点、只列子目录 / 排序、parent 链、根为 null、四类非法路径、方法清单）；web 纯逻辑 `picker.test.ts`（`npm test`）；交互在 `web/e2e/group.mjs` 的 WS.*（点「切换」→ 框出现 → 列子目录 → 进入 → 上级 → 选择 → payload 逐字 / 失败态 / 层级盖住顶栏 / 取消不发写 / 未设置时请求不带 `path` / 群 busy 禁用）。C++ 与 Flutter 控件仍不涉及。

## Risks / Trade-offs

- [持久化路径的目录被删 / 改名] → 分两种时态，行为都说清楚：**重启后**（上下文需要重建）校验失败，会话 / 成员轮以可归因错误拒绝（不静默回落主目录，也不留空工作区），界面上的路径栏仍显示设置值，用户切到有效目录即恢复（`setWorkspace` 不依赖旧路径存在）；**同进程运行中**目录被删，不额外做每轮存在性预检（会给所有测试与调用方引入路径必须真实的硬依赖），此时工具会按既有口径如实报「文件不存在 / 工作目录不存在」，不伪装成功。用例覆盖前一种时态。
- [群切换时某个成员实例即时更新失败] → 组与库已切换，错误消息点名失败成员；下一轮成员轮对齐（D7）会收敛；用例用「把成员上下文改歪后跑一轮」验证收敛，而不是靠一次成功传播。
- [落库值（用户输入风格）与生效值（sidecar 规范化）分隔符不同，看起来像两回事] → 同一目录，`p.equals` 可判等；文档与设计写明「设置值 / 生效值」两个词，界面显示设置值、模型看生效值；不为统一字符串再写一套 C++ 规范化。
- [系统提示多一段 ⇒ 固定开销变大、占用环数字变化] → 固定开销本来就按系统提示词估算（`ContextEstimator`），环会如实反映；不调整任何阈值公式。既有快照断言用 `contains`，不做整串相等比较。
- [模型把「工作区」误解成沙箱] → 提示段与文档逐字写明 `run_command` 没有沙箱、以用户权限执行、不可撤销；spec 明确禁止把「没有沙箱」写成缺陷。
- [浏览器拿不到绝对路径，用户预期是系统文件夹对话框] → D10 说明为什么不能是系统对话框，D15 用**应用内文件夹选择框**（核心 `workspace.listDirs` 列目录）让用户点选而不是手输；文档如实说明这是浏览器限制。
- [文档守卫与文档不同步] → 文档与四个守卫在同一组任务里改，验收跑 `flutter test test/unit/group_docs_test.dart test/unit/user_docs_test.dart test/unit/web_core_docs_test.dart test/unit/web_management_docs_test.dart`；不许删用例或换成弱断言。
- [改动碰到既有恢复用例] → `group_context_restore_test.dart` 的「回落缺省」用例是**行为变更**的靶子，按新行为改写并保留同强度的断言（读 `getWorkspace` 而不是读夹具的 map）；同进程幂等用例继续保留。

## Migration Plan

- 数据库：v11 → v12 只加 `workspace` 列；旧库打开即升级，既有会话 / 消息 / 摘要 / 成员 / 模板 / 附件原样保留，workspace 为 NULL（= 用缺省，行为等同变更前）。无回填、无数据搬迁。
- 运行形态：单实例核心 + 桌面壳，升级后重启一次即生效（`get_workspace` 已存在，无需换 DLL；**sidecar 不需要重新构建**）。
- 回滚：回退本 change 的提交即可回到「工作区只在内存、web 无入口」的旧行为；数据库多出的 `workspace` 列对旧代码无影响（旧代码不查该列；SQLite 加列不破坏读取）。文档与守卫同批回退，不留旧锚点。

## Open Questions

无。粒度（单聊一个 / 群一个共享）、缺省（不改 `homeDir`）、持久化与重启恢复、注入点（系统提示）、RPC 形状（两个具名方法 + `session.create` 可选参 + `workspace.listDirs`）、群切换传播到成员、界面位置（群右栏顶部 / 单聊标题旁）与「不是沙箱」都已在设计与用户诉求中闭合；D10 的浏览器限制是实现事实，**切换交互按用户 2026-11-27 的明令取 D15 的文件夹选择框**，不是待拍板项。
