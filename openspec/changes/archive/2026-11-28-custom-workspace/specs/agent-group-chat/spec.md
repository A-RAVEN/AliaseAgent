## MODIFIED Requirements

### Requirement: 共享工作区继承

成员上下文 SHALL 用**组上下文当前工作区**初始化：取工作区前先经统一入口 `ensureGroupContext(groupId)` 按需重注册（核心重启后存量群上下文丢失时重注册，避免 `unknown_context`），再 `sidecar.getWorkspace(groupId)` 只读读取作为成员上下文默认工作区。该工作区由 `group.create` 建立并可经 `group.setWorkspace` 切换（见「组工作路径切换」）；组的工作区 SHALL 持久化在 `sessions.workspace`，核心重启后组上下文按**持久化值**重建（见「群上下文跨核心重启存活」）。系统 SHALL NOT 给成员单独的私有工作区；成员写入的文件对全组可见（同一目录）。

**切换要真的传播**：`group.setWorkspace` 成功后 SHALL 把新工作区写进该组**所有在册成员实例**的 sidecar 上下文（成员不是只换显示）。**成员轮开始对齐**：每个成员轮装配前 SHALL 读组上下文当前工作区并与该成员上下文的工作区比较，不一致就设为组值并留一行日志（即时传播失败时下一轮仍收敛）；组工作区读不到 / 为空串 SHALL 按可归因错误处理（`workspace_unavailable`），MUST NOT 让成员在空工作区或别的目录里干活。

成员实例 SHALL 是持久实例：SHALL NOT 建立 `parent_session_id` 子运行记录，SHALL NOT 在回合结束时销毁上下文。

#### Scenario: 成员工作区等于组工作区

- **WHEN** 组成员实例被创建，且组上下文工作区为自定义目录（同进程未重启）
- **THEN** 它的上下文工作区与组上下文当前工作区逐字相等（自定义时不是默认主目录）

#### Scenario: 甲写的文件乙能读

- **WHEN** 成员「甲」在共享工作区写入一个文件
- **THEN** 随后发言的成员「乙」在读该路径时读到同一份内容

#### Scenario: 成员不是子运行

- **WHEN** 成员完成一轮
- **THEN** 数据库里没有指向该成员的 `parent_session_id` 子运行记录，且该成员实例与上下文仍可用（下一轮可直接发言）

#### Scenario: 切组工作区后成员实例跟着换

- **WHEN** 一个含「甲」「乙」两个在册成员的组调用 `group.setWorkspace {workspace: <新目录>}`
- **THEN** 组上下文与「甲」「乙」两个实例的上下文工作区都变成新目录（分别 `get_workspace` 读回），不需要重建成员实例；随后任一成员读相对路径落在新目录

#### Scenario: 即时传播失败时下一轮对齐（回归守卫）

- **WHEN** 某成员实例的上下文工作区与组上下文不一致（模拟传播失败 / 上下文被别处改过），该成员开始一轮
- **THEN** 该轮装配前成员上下文被设为组当前工作区（并留一行日志），该轮相对路径落在组目录；MUST NOT 沿旧目录干活

#### Scenario: 组目录被删时可归因

- **WHEN** 组持久化的工作目录在磁盘上被删除，**核心重启后**（组上下文需要按持久化值重建）要创建成员或跑成员轮
- **THEN** 重注册前的工作区校验失败，返回可归因的 `workspace_unavailable`（点名该路径），MUST NOT 用空工作区（等于不设界）或别的目录顶替；把工作区切到有效目录后恢复

### Requirement: 群上下文跨核心重启存活

群的工作区上下文 SHALL 在核心重启后对**存量群**仍然可用：成员反应轮取工作区前 SHALL 先按需重注册群上下文（`ensureContext`，统一入口 `ensureGroupContext`），不得因 sidecar 内存上下文随重启丢失而对存量群报 `unknown_context`。`ensureContext` 异常 SHALL 包成 `GroupException`；`getWorkspace` 返回 ok 但工作区为空串 SHALL 按可归因错误处理，MUST NOT 静默以空工作区建成员。**自定义工作区持久化**：组行在 `sessions.workspace` 里保存设置值；重启后上下文新建（`created:true`）SHALL 以**持久化值**作为缺省工作区重注册（无设置时仍用缺省 `ConfigService.homeDir`），成员随之继承同一目录。幂等仍指**同进程上下文仍在**（`created:false`）时不覆盖已有工作区；升级前创建的旧组（`workspace` 为 `NULL`）行为等同变更前。新建群与单会话的既有行为不变。

#### Scenario: 重启后存量群成员轮可反应

- **WHEN** 建群（reactionsEnabled 开启）并加成员、发一条消息确认能反应；随后**同一数据库**重建 sidecar / 核心实例（模拟重启，内存上下文丢失），对同一存量群再发一条消息
- **THEN** 成员轮成功反应：链 `status=='completed'` 且步 `replied`/`publicSeq` 非空（不以「非 steps=0」判——失败步也让 steps>0），不报 `unknown_context`

#### Scenario: 同进程幂等重注册不覆盖已有工作区（回归守卫）

- **WHEN** 群上下文仍在（同进程，未重启），再次触发 `ensureGroupContext`
- **THEN** `created:false`，该群已有工作区不被覆盖（读 `getWorkspace` 验证）

#### Scenario: 重启后自定义工作区保留

- **WHEN** 某群经 `group.create` / `group.setWorkspace` 设了自定义工作区，核心重启后触发该群成员轮
- **THEN** 组上下文的工作区等于该持久化目录（读 `getWorkspace`，不是 `ConfigService.homeDir`），成员轮仍可反应、不报 `unknown_context`；成员继承到同一目录

#### Scenario: 新建群与单会话不受影响（回归守卫）

- **WHEN** 重启后新建群发消息，或打开存量单会话
- **THEN** 新建群正常反应（创建时已注册，未设工作区时用缺省）；单会话恢复时若有持久化工作区则用它、`NULL` 时用缺省，行为不变

### Requirement: 群聊 RPC 面

核心 SHALL 提供 `group.create` / `group.update` / `group.chain` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（发言者可选）/ `group.view`（带成员 id）/ `group.setWorkspace`（切换共享工作路径）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员/原因），MUST NOT 静默失败或崩溃。

`group.create` SHALL 接受可选的 `workspace`（工作路径；省略 / 空白 = 未设置、用缺省，见 `web-core-shim` 的「工作路径 RPC」）、`reactionsEnabled`（布尔；省略 = 新建组默认开启）与 `maxRounds`（整数 1..50；省略 / null = 用产品默认）。

`group.update` SHALL 接受 `{groupId, reactionsEnabled?, maxRounds?}`，至少给一个字段；`reactionsEnabled` 必须布尔；`maxRounds` 必须是 1..50 的整数或显式 `null`（显式 null = 恢复默认，**与字段缺席不同**：缺席 = 不改）。类型不对 / 越界 / 一个字段都没给 SHALL 返回可归因错误（`-32602`）；反应链运行中 SHALL 返回可归因 busy（不排队）。它仍只做组设置，不扩成通用 update。

`group.list` SHALL 返回每个组的 id、标题、`workspace`（字符串或 null）、`reactionsEnabled`、`maxRounds`（整数或 null）、**`busy`（布尔）与 `runningMemberId`（字符串或 null）** 与成员清单：每个成员带成员 id、显示名、模板名、**已移除标记 `removedAt`**、`overrides`（工具子集 / 提示词追加 / 思考强度）与 `effective`（生效工具清单、生效思考模式与强度），供界面渲染**成员视图与成员名单**、选发言人与展示覆盖层效果；不额外增加“列成员”的方法。`busy` / `runningMemberId` 是只读状态，使 web 在断线重连后仍知道链在跑、该显示/取消谁。

`group.member.update` SHALL 原地更新成员（显示名 / 模板 / 覆盖层）并保持成员 id 不变；更新后 SHALL 重建该成员实例（先退役/销毁旧实例，再按新配置创建），使新的工具子集与提示词追加生效。

`group.send` 的 `speaker` SHALL 可选：带发言者 = 定向该成员（开启态强制必应；关闭态纯 speaker 仍是旧普通轮）；不带 = 开关开启时纯触发（写用户消息并起链），开关关闭时按用户消息里的 `@mention` 定向、没有 `@mention` 则拒绝。**发送 SHALL 异步且永不 busy**：完成同步前置校验与用户消息写入后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`（带文本时 `triggerSeq` 为用户消息 seq；speaker-only 时为 null，由链状态更新）；链执行器在跑时新请求入队/被吸收，不返回 busy 拒绝。发送结果 SHALL NOT 携带 `steps` / `rounds` / `finalText` / `memberId`，SHALL NOT 等待链结束。

**`group.chain`**：`{groupId}` SHALL 返回当前 / 最近一条链的状态 `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps, error}`。`status ∈ {idle, running, completed, cancelled, failed}`；`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`（运行中为 null）；`error` 为字符串或 null——链 `failed` 时 SHALL 非空且含可归因文本（如 `unknown_context` / 成员轮异常原因），使界面与测试能知道失败真因，MUST NOT 只返回 `failed` 而吞掉原因；`rounds` 只计反应轮；`steps` 是 0..N 条，封闭取值是：
- `source ∈ { speaker, mention, reaction }`；
- `status ∈ { replied, passed, forced_pass, forced_empty, empty, failed, cancelled }`；
- 另有 `memberId` / `triggerSeq` / `publicSeq` / `finalText` / `error`。

`group.chain` 在核心重启后为 `idle`（本进程内语义）。链进入终态时 SHALL 通过 `agent.event` 发一条 `group.chain.completed`（`type` 为该值，携带 `groupId` / `sessionId` / `status` / `stopReason` / `rounds` / `triggerSeq`）；这是群聊反应链引入的唯一新增事件类型，本 change 不新增事件类型；其余仍复用既有事件类型。链的 `steps` 只用于观察与测试，SHALL NOT 成为消息的第二份存储。

`group.view` SHALL 返回该成员**本次运行内最近一次真实发出**的上下文快照（`system` / `messages` / `tools` + 窗口与 breakdown）；该成员本次运行内从未发言时 SHALL 返回空（界面显示占位），SHALL NOT 用历史拼一份“没发过的上下文”。重启后视图为空属既定语义（与真实上下文视图的“自本次启动以来”先例一致）。请求失败 SHALL 返回可归因错误，使界面能区分“读取失败”与“从未发言”。

#### Scenario: 十一个群聊方法可调用

- **WHEN** 客户端依次调用建组、改组、查链、列组、加成员、改成员、发消息、取成员视图、移除成员、删组、切换工作路径
- **THEN** 每个方法返回结构化结果或可归因错误，通道不崩溃

#### Scenario: 列组带成员、组设置与覆盖层可观察字段

- **WHEN** 成员设置了工具子集与追加提示词后客户端调用 `group.list`
- **THEN** 该组项返回 `reactionsEnabled`、`maxRounds`、`busy`、`runningMemberId`，该成员项同时返回 `overrides` 与 `effective`（生效工具清单、生效思考强度）

#### Scenario: 改组开关

- **WHEN** 客户端调用 `group.update` 把 `reactionsEnabled` 改为 `false`
- **THEN** 返回更新后的会话（`reactionsEnabled = false`），再次 `group.list` 读到同一个值

#### Scenario: 改组上限与恢复默认

- **WHEN** 客户端调用 `group.update` 传 `maxRounds = 6`，再传 `maxRounds = null`
- **THEN** 第一次读回 6；第二次读回 null（= 用产品默认），`group.list` 与 `session.list` 都一致

#### Scenario: 改组参数非法或组不存在

- **WHEN** 客户端调用 `group.update` 时一个字段都没给、`reactionsEnabled` 非布尔、`maxRounds` 非整数/越界（0、51、负数）、或 `groupId` 不存在
- **THEN** 前三类返回 `-32602`（指明字段），组不存在返回带 `groupId` 的可归因错误；组设置不被改动

#### Scenario: 组项带忙碌状态

- **WHEN** 一条反应链正在跑时客户端调用 `group.list`
- **THEN** 该组项 `busy = true`，`runningMemberId` 是当前正在运行的成员 id（链在成员间隙时可为 null）；链结束后 `busy = false`

#### Scenario: 改成员重建实例

- **WHEN** 客户端用 `group.member.update` 修改某成员的工具子集
- **THEN** 成员 id 不变，其旧实例被销毁、按新配置重建，下一次发言的请求使用新工具清单

#### Scenario: 方法清单同步

- **WHEN** 核心启动注册群聊 RPC
- **THEN** `kCoreRpcMethodNames` 与实现一致（漏注册抛错），且网页文档的 RPC 表列出全部群聊方法（含 `group.chain` / `group.setWorkspace`）

#### Scenario: 查链：空闲、运行中与终态

- **WHEN** 依次在没有链、链运行中、链结束后调用 `group.chain`
- **THEN** 分别返回 `status = idle`（steps 空、rounds 0）；`status = running`（stopReason null，steps 累积）；终态 `status` 与 `stopReason` 合法，steps 完整

#### Scenario: 发送在链结束前返回

- **WHEN** 客户端发一条会触发多轮反应的消息
- **THEN** `group.send` 在第一次模型调用完成前就返回 `status = started` 与 `triggerSeq`；此时 `group.chain` 为 `running`；链结束后才有 `stopReason`

#### Scenario: 省略发言者触发反应链

- **WHEN** 组的自发反应开启，客户端调用 `group.send` 时省略 `speaker`、只带文本
- **THEN** 调用立即返回 `started`；随后 `group.chain` 显示链在跑，公开时间线按反应展开，终态 `stopReason` 合法

#### Scenario: 没有可反应成员时链直接结束

- **WHEN** 组的自发反应开启、组里没有任何可反应成员，客户端带文本发送
- **THEN** 用户消息照常写入一条，`group.send` 返回 `started`；`group.chain` 很快进入 `completed`，`steps = []`、`rounds = 0`、`stopReason = no_members`，不返回错误、不写占位消息

#### Scenario: 取成员视图返回本次运行内最后一次真实发出的上下文

- **WHEN** 成员「甲」本次运行内发过一轮，客户端调用 `group.view(甲)`
- **THEN** 返回的快照 `messages` 与该轮实际发出的投影逐字一致（含归属前缀），`windowTokens` 是「甲」自己实例的窗口

#### Scenario: 没发过的成员返回空

- **WHEN** 成员「乙」加入后还没发过言（或应用已重启），客户端调用 `group.view(乙)`
- **THEN** 返回空结果，界面显示占位，而不是一份用历史拼出来的上下文

#### Scenario: 取成员视图失败可归因

- **WHEN** 客户端对某成员调用 `group.view` 且读取失败
- **THEN** 返回带成员 id 与原因的错误；界面据此显示“读取失败 + 重试”，不得把失败当成空快照

#### Scenario: 失败可归因

- **WHEN** 客户端对不存在的组或成员调用群聊方法
- **THEN** 返回带原因与对象 id 的 JSON-RPC 错误

## ADDED Requirements

### Requirement: 组工作路径切换

核心 SHALL 提供 `group.setWorkspace {groupId, workspace}`（契约形状见 `web-core-shim` 的「工作路径 RPC」）。该方法 SHALL：校验路径（绝对、存在、是目录）→ 确保组上下文存在并 `set_workspace` → 写 `sessions.workspace`（核对恰好一行）→ 传播到所有在册成员实例的上下文 → 返回重读的组会话。反应链或任一成员运行中 SHALL 返回可归因 busy（不排队、不中途换根）；路径非法 SHALL 返回可归因错误且**组上下文、成员上下文与库值都不变**；kind 不是组 SHALL 拒绝并指向 `session.setWorkspace`。

`group.create` 带 `workspace` 时 SHALL 把设置值落库（不再只存在内存里）；省略时写 `NULL`（缺省口径不变）。`workspace` 只有空白字符 SHALL 视为省略（写 `NULL`、用缺省）；显式非空但不合法（非绝对、不存在、不是目录）SHALL 返回可归因错误且**不创建组会话行**。

#### Scenario: 建组带工作区会落库

- **WHEN** 客户端调用 `group.create {workspace: <已存在目录>}`
- **THEN** 返回的组带该 `workspace`，`group.list` / `session.list` 读回同一值；核心重启后该组仍在该目录（见「群上下文跨核心重启存活」）

#### Scenario: 切组工作区写库并传播

- **WHEN** 客户端对一个有两个成员的组调用 `group.setWorkspace` 指向另一个已存在目录
- **THEN** 返回的组 `workspace` 为新值、库中该列已更新；组与两个成员的上下文都切到新目录；下一次成员轮在该目录里读相对路径

#### Scenario: 非法路径与忙状态不改任何状态

- **WHEN** 客户端调用 `group.setWorkspace` 传不存在 / 非绝对 / 指向文件的路径，或该组正有反应链 / 成员在运行
- **THEN** 分别返回可归因错误 / 可归因 busy；组上下文、成员上下文与 `sessions.workspace` 都保持原值，随后一次成员轮仍在原目录

#### Scenario: 传播失败可归因且下一轮收敛

- **WHEN** 切换时某个成员实例的上下文更新失败（例如上下文已失效）
- **THEN** 返回可归因错误并点名该成员；组与库已切换到新目录，该成员下一轮开始对齐到新目录（不退化为静默失败）

### Requirement: web 组视图的群工作路径栏

web 群视图的右栏（`id="group-members"` 的 `<aside>`）SHALL 在最顶部、**成员名单之上**提供「群工作路径」栏：显示该组的 `workspace`（非空时逐字显示；`null` 时显示「缺省（应用主目录）」），长路径 SHALL 单行截断且可用悬停（`title`）看全文，点「切换」SHALL 打开**文件夹选择对话框**（应用内的浏览框，数据源为核心 `workspace.listDirs`；点文件夹进入下一层、「上级」/ 面包屑回退、「选择此目录」确认、「取消」不发写请求；框内 SHALL 有可编辑的路径地址栏，值与当前文件夹双向同步，Enter / 「跳转」把路径交给 `workspace.listDirs` 校验：合法导航、非法就地报错且不跳、不发写请求；浏览（点选）仍是主交互，MUST NOT 只剩文本输入），确认后走 `group.setWorkspace` 并在成功后重拉组数据。对话框高度 SHALL 固定为视口约 70%（`dvh` 视口占比，MUST NOT 随子文件夹数量变化、换文件夹 MUST NOT 跳变；子文件夹多时列表在框内滚动，MUST NOT 撑满屏幕）；面包屑顶层 SHALL 是「此电脑」（Windows），盘符根的「上级」可回「此电脑」并切换其它盘，停在「此电脑」时「选择此目录」MUST 禁用（它不是真实目录）。对话框层级 SHALL 高于群视图顶栏与主区覆盖层（MUST NOT 被顶栏画在上面）。

该栏 SHALL 只装工作路径：MUST NOT 扩成「群公告」功能（无公告正文输入、无历史、无未读、无公告编辑入口）。链运行中（`busy` / 链 `running` / 有成员在流式）SHALL 禁用「切换」并给出可读原因，MUST NOT 只在点击后才报错。保存失败 SHALL 在对话框内就地显示可归因错误文本、保持对话框打开、已保存路径的显示不变。窄屏（低于产品既有 `xl` 断点）时该栏随成员名单一起收进右侧抽屉，MUST NOT 另做一套浮层，MUST NOT 覆盖会话列表。

#### Scenario: 栏在成员名单之上

- **WHEN** 用户打开一个群聊（`xl` 及以上，成员名单是静态右列）
- **THEN** 页面存在 `group-workspace` 栏，其纵向位置在成员名单（`group-members-list` / 「成员」标题）之上，显示该组当前工作路径；成员卡片、齿轮面板、双标签都不受影响

#### Scenario: 长路径截断且可看全文

- **WHEN** 组的 `workspace` 是一个很长的路径
- **THEN** 栏内路径单行截断、右栏不出现横向溢出，该元素的 `title` 是完整路径；打开的选择框以该完整路径为起点（框内地址栏逐字显示，可编辑）

#### Scenario: 地址栏可编辑且与文件夹同步

- **WHEN** 用户在群文件夹选择框的地址栏输入一个已存在目录并按 Enter（或点「跳转」）
- **THEN** 客户端用该路径调 `workspace.listDirs`，成功后列表 / 面包屑 / 地址栏都切换到该目录，地址栏值始终等于当前文件夹；输入非法路径时框内就地显示含路径与原因的错误、列表与地址栏仍停在原目录、不发任何 `group.setWorkspace`

#### Scenario: 在栏里切换成功

- **WHEN** 用户在栏里点「切换」，在文件夹选择框里点进一个子目录并点「选择此目录」
- **THEN** 客户端发出 `group.setWorkspace {groupId, workspace: <该子目录绝对路径>}`（payload 逐字可断言），成功后栏显示新路径、成员名单与时间线不丢；MUST NOT 发出 `session.setWorkspace`

#### Scenario: 保存失败就地可归因

- **WHEN** 用户在框里选中一个核心拒绝的目录并点「选择此目录」，核心返回可归因错误
- **THEN** 对话框内就地显示该错误（含路径 / 原因），对话框保持打开，栏里仍显示原来的已保存路径；页面无未捕获异常

#### Scenario: 选择框盖住群视图顶栏

- **WHEN** 用户点「切换」打开文件夹选择框
- **THEN** 群视图顶栏中心位置的命中元素属于该对话框（层级高于顶栏与主区覆盖层），顶栏按钮不可被误点

#### Scenario: 链运行中不能切

- **WHEN** 该组正有反应链 / 成员在流式
- **THEN** 「切换」按钮禁用并给出可读原因（悬停 / 文本可读），点击不发任何写请求；链结束后可切换

#### Scenario: 窄屏收进成员抽屉

- **WHEN** 浏览器宽度低于既有 `xl` 断点，用户打开群聊
- **THEN** 右栏默认收起；打开「成员」抽屉后能在抽屉顶部看到「群工作路径」栏并操作；页面没有横向溢出，会话列表仍可见、不被覆盖

#### Scenario: 不是群公告功能

- **WHEN** 检查该栏的界面元素
- **THEN** 只有工作路径的显示 / 「切换」控件，没有公告正文输入框、公告历史或未读标记；不发任何公告类 RPC
