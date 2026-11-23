## MODIFIED Requirements

### Requirement: 共享工作区继承

成员上下文 SHALL 用**组上下文当前工作区**初始化：取工作区前先经统一入口 `ensureGroupContext(groupId)` 按需重注册（核心重启后存量群上下文丢失时重注册，避免 `unknown_context`），再 `sidecar.getWorkspace(groupId)` 只读读取作为成员上下文默认工作区。该工作区由 `group.create` 建立（见「组会话与成员」）；**自定义工作区不持久化，核心重启后组工作区回落缺省 `ConfigService.homeDir`，成员随之继承缺省（已知限制；持久化另立）**。系统 SHALL NOT 给成员单独的私有工作区；成员写入的文件对全组可见（同一目录）。

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

### Requirement: web 组视图

web 客户端 SHALL 在**真实应用**里提供可达的组视图（不是只在测试挂架里存在的组件）。群聊 SHALL 作为**普通会话**打开：会话列表由应用壳常驻左侧，主区按选中会话的 `kind` 路由（列表常驻、主区切换与过期群响应丢弃的行为见 `web-chat-screen` 的「会话列表常驻左侧与主区切换」）；打开或切换群聊 MUST NOT 整屏替换单聊聊天屏、MUST NOT 卸载或隐藏会话列表。群聊数据未就绪时主区 SHALL 显示加载占位，MUST NOT 把上一个群的成员或消息挂到新会话标题下。

群聊主区 SHALL 提供 `[群聊 | 成员视图]` 双标签；切换标签 MUST NOT 改变会话列表，也 MUST NOT 重拉或修改数据。群聊 SHALL 包含：

1. **「群聊」标签**：
   - 公开时间线（按 `seq` 排列，每条带作者归属），位于**中间主列**；
   - 发送区（发言人选择、文本输入、发送按钮、链的一次性提示）位于主列时间线下方；
   - 成员名单位于时间线**右侧**（`id="group-members"`，供 `aria-controls` 引用），包含成员卡片、加入成员、覆盖层编辑与移除入口；成员名单 SHALL 显示正在流式的成员（「正在反应…」）；
   - 头部链活动指示 SHALL 追加正在流式的成员名（`streamingMembers`，链在成员间隙时用 `runningMemberId` 回退），使窄屏成员名单抽屉关闭时仍能看见“哪个成员在流式”；
   - 底部的「成员私有分栏」MUST NOT 存在；公开时间线 MUST NOT 被成员私有内容挤占垂直空间。
2. **「成员视图」标签**：
   - 成员选择器，列出全部成员（含已移除成员，标「（已移除）」）。已选成员只要仍在成员表里（包括 `removedAt` 非空的软删成员）SHALL 保持选中，使历史私有行可查；只有成员 id 从成员表消失时才回退到第一个未移除成员，没有未移除成员时选第一个成员，没有成员时显示空态；
   - 选中成员的私有过程行（栏头口径「仅该成员可见」；已移除成员的历史私有行仍有去处）；私有行为空时 SHALL 显示「本次已加载页里没有私有行」并给出「加载更早的消息」入口（有更早页时），MUST NOT 让用户误以为该成员从未有过私有过程；
   - 不在成员表里的作者（脏数据）SHALL 以只读「未知作者（数据异常）」横幅列出其私有行与行数，MUST NOT 静默丢行；
   - 选中成员的真实上下文状态 SHALL 区分 `loading` / `ok` / `empty` / `error`：`error` 显示可重试提示（重试只重拉该成员），MUST NOT 复用「本次运行内没发过言」的文案；`empty` 才显示没发过言的占位；`ok` 显示 `group.view` 返回的 `system` / `messages` / `tools` 原始 JSON（复用既有真实上下文视图组件）；
   - 选中成员的占用环（按该成员视图的 breakdown 与**该成员自己的窗口**，复用既有环组件与三瓣口径）；没有 breakdown 时 SHALL 显式说明、不画空环。
3. **自发反应开关与轮数上限**：显示并切换该组的 `reactionsEnabled`（新建组默认开启）；旁边显示「反应轮数上限」输入框（当前 `maxRounds`，为 null 时以默认值占位，范围 1..50，留空 = 恢复默认）；两项切换/保存 SHALL 走 `group.update`，链运行中 SHALL 禁用。
4. **操作面**：建组、加成员、编辑成员覆盖层（工具子集 / 提示词追加 / 思考强度）、选发言人并发送（`group.send` 的 `speaker`；开关开启时发言人 SHALL 可选，空 = 纯触发；**发送按钮 SHALL 永远可用，链运行中也能发**）、取消正在运行的反应链（**断线重连后仍可用**：用 `group.chain` 的 `running` / `group.list` 的 `busy` / `runningMemberId` 恢复判断，不只依赖本地发送状态）。
5. **响应式**：宽度低于产品既有的 `xl` 断点时，成员名单 SHALL 收起为可由头部「成员」按钮开合的抽屉；双标签与发送区 MUST 保持可用；群聊主区 MUST NOT 出现横向溢出。抽屉 MUST NOT 覆盖会话列表；`xl` 及以上 SHALL 以静态右列显示成员名单。跨断点时（窄屏打开抽屉后拉宽到 `xl`）抽屉 SHALL 被关闭或转为静态列，MUST NOT 留下无法关闭的浮层；「成员」按钮 SHALL 只在「群聊」标签渲染/可用，切到「成员视图」时 SHALL 关闭抽屉，`aria-expanded` MUST NOT 与实际可见状态不符。抽屉背景 MUST NOT 盖住头部标签（否则点头部标签会命中背景）；抽屉 SHALL 支持 Escape 关闭，并带 `role="dialog"` / `aria-modal` 与打开/关闭焦点处理。双标签 SHALL 用 `role="tablist"` / `role="tab"` / `role="tabpanel"` 并以 `aria-controls` 关联。
6. **滚动位置**：公开时间线、成员视图、成员名单三个滚动容器 SHALL 各自保存位置，并在切标签、开合抽屉后恢复（恢复必须发生在容器可见后）；只保存时间线不算完成。切换成员不会隐藏成员视图容器，不能拿它当滚动存档判据。
7. **提示游标**：换群 MUST NOT 依靠重建组件把链提示游标归零；旧群的链提示在切走再切回时 MUST NOT 重放；当前群视图挂载后新的链结束 SHALL 出提示（不承诺离开期间结束的链在回来时补提示）。

**异步发送**：`group.send` 返回 `started` 后界面 SHALL 立即解除“发送中”，但链可能仍在跑；**不存在“发送未开始/链忙不能发”的分支**，链运行中再发也照常接受（新用户消息写入、执行器吸收/排队）。链活动指示与取消按钮 SHALL 由 `started` 响应、`agent.streaming` / `assistant.message` 事件、`group.chain` 与 `group.chain.completed` 共同驱动。链终态为 `round_cap` 时 SHALL 显示「已达轮数上限（反应已停止；可继续点名，或调大该组的反应轮数上限）」；`all_passed` 不提示。链进行中页面 SHALL 显示活动指示（哪个成员正在流式）。

**提示可见性**：`forced_pass` / `forced_empty` / `round_cap` 的一次性提示仍在群聊标签发送区上方；当提示产生时用户正在「成员视图」标签，群聊标签 SHALL 显示未读标记（`data-unread="true"` 与可见小点），切回群聊后显示提示并清除标记，MUST NOT 让提示只在隐藏面板里静默存在。

反应链 SHALL 在界面上**逐步展开**：每位成员的公开回复落库后时间线新增一条，其私有工具过程落进该成员的成员视图数据；事件路由 SHALL 以 payload 为准：`group.send` 的参数带 `speaker`（可空）；**成员运行**产生的 `agent.event` 带 `groupId` / `memberId`，私有内容 SHALL 按这两个字段归位；**组服务自己写入的** `user.message` 只带 `groupId`（没有成员可归），落到公开时间线。e2e 验收 SHALL 以 payload 为判据（DOM 选中值只作辅助，不能作为唯一证据）。

**关闭态的发送例外**：开关关闭时，文本里含 `@` 允许空发言人（`@` 是否有效由核心裁决，前端 SHALL NOT 复制 mention 解析规则）；文本不含 `@` 且没有 speaker 时前端 SHALL 拒绝并给出可归因提示（旧本地校验），最终以核心错误为准。`forced_pass` / `forced_empty` 的提示 SHALL 在链结束后从 `group.chain` 的 `steps` 读取，**刷新后不再显示**（没有对应公开行）；文档写明这个已知限制。

用户消息与全部成员的公开回复 SHALL 可见并带归属。Flutter 侧本期 SHALL NOT 被要求提供组界面：组会话在 Flutter 的会话列表里可见，但打开时 SHALL 显示「请在 web 组视图打开」的占位，不进入单 Agent 对话界面。

#### Scenario: 会话列表按 kind 分流且不消失

- **WHEN** 用户在 web 端打开一个组会话
- **THEN** 主区进入组视图（公开时间线 + 右侧成员名单），而左侧会话列表仍然可见、仍可点击其它会话，不会因为打开群聊而消失

#### Scenario: 打开群聊看到时间线与右侧成员名单

- **WHEN** 用户打开一个含两个成员的组
- **THEN** 「群聊」标签显示公开时间线，成员「甲」「乙」的名单位于时间线右侧；页面底部不再有「成员私有分栏」，时间线垂直空间不被它挤占

#### Scenario: 已移除成员仍可在成员视图查看且保持选中

- **WHEN** 一个组里有已移除的成员「甲」，用户在成员视图选中它后又触发一次成员表刷新
- **THEN** 成员选择器仍列出「甲（已移除）」，且「甲」仍是当前选中项；选中它能看到它的历史私有行，不丢行也不因为 `removedAt` 非空自动跳走

#### Scenario: 成员视图标签展示选中成员的上下文与占用环

- **WHEN** 用户在「成员视图」标签选择成员「甲」
- **THEN** 页面显示「甲」的私有过程行、`group.view(甲)` 的 `system` / `messages` / `tools` 原始 JSON（可滚可复制）与占用环；环的分母是「甲」自己实例的窗口，不是共享分母或别的成员的窗口

#### Scenario: 快照读取失败不伪装成没发过言

- **WHEN** 成员「甲」有真实发言，但 `group.view(甲)` 本次请求抛错
- **THEN** 成员视图显示 `member-snapshot-error` 与可点击的「重试」；MUST NOT 显示「本次运行内没发过言」，也 MUST NOT 画空环

#### Scenario: 快照空态与加载态可区分

- **WHEN** 成员「乙」本次运行内确实没发过言，或该成员快照仍在加载
- **THEN** 没发过言时显示 `member-no-snapshot` 占位；加载中显示 `member-snapshot-loading`；两者都不显示成对方的文案

#### Scenario: 没发过言的成员显示占位

- **WHEN** 某个成员还没发过言（或应用重启后），用户在该成员视图里选中它
- **THEN** 真实上下文区域显示显式占位、环不渲染（与既有“没有快照不画环”一致），不把空数据画成 0

#### Scenario: 底部分栏不再挤占主聊天

- **WHEN** 用户打开一个有多个成员的群聊
- **THEN** 页面不存在底部「成员私有分栏」容器；公开时间线一直延伸到发送区上方，成员私有内容只在「成员视图」标签内出现

#### Scenario: 双标签切换不改会话列表与状态

- **WHEN** 用户在「群聊」与「成员视图」之间来回切换
- **THEN** 主区显示对应标签的内容，左侧会话列表与当前选中的群会话保持不变，不重新拉取会话列表、不丢失标签页外的链状态、草稿与时间线滚动位置

#### Scenario: 私有行空态与加载更早

- **WHEN** 选中成员的私有行只存在于更早的消息页，当前页没有
- **THEN** 成员视图显示「本次已加载页里没有私有行」与「加载更早的消息」；点击后取回更早页，该成员的私有行出现在成员视图里

#### Scenario: 未知作者私有行有去处

- **WHEN** 当前页出现一条 `visibility = private-to-author`、但 `author` 不在 `group.list` 成员表里的行
- **THEN** 成员视图的「未知作者（数据异常）」只读横幅列出该行（或至少它的行数），该行不被静默丢弃，也不被伪造成一个正常成员

#### Scenario: breakdown 缺失不画空环

- **WHEN** 某个成员有快照但 `breakdown` 为 `null`
- **THEN** 成员视图显示 `member-no-breakdown` 的显式说明，且不渲染 `context-ring`，不把缺失数据画成 0

#### Scenario: 窄屏成员名单收起为抽屉且流式成员名可见

- **WHEN** 浏览器宽度低于既有 `xl` 断点，用户打开一个群聊，且链正在让「甲」流式
- **THEN** 成员名单默认收起，头部出现「成员」按钮；`reaction-active` 文案包含正在流式的成员名「甲」；点开「成员」后成员名单以右侧抽屉出现，关闭后消失；双标签与发送区仍可用，页面没有横向溢出，会话列表仍可见

#### Scenario: 抽屉背景不盖住头部标签

- **WHEN** 720px 打开成员抽屉，然后点头部「成员视图」标签
- **THEN** 点击按真实命中生效（不是落到背景），标签切到「成员视图」、抽屉关闭；再点「群聊」时抽屉仍关闭

#### Scenario: 抽屉跨断点可收

- **WHEN** 用户在 720px 打开成员抽屉，然后把视口拉宽到 1280px，再缩回 720px
- **THEN** 拉宽后成员名单变为静态右列，背景/关闭按钮/「成员」切换按钮不可见，不残留 absolute 浮层；缩回窄屏时抽屉保持关闭

#### Scenario: 抽屉可访问

- **WHEN** 用户打开成员抽屉后按 Escape，或检查抽屉语义
- **THEN** Escape 关闭抽屉，焦点回到「成员」按钮；抽屉有 `role="dialog"` 与 `aria-modal`，监听器在卸载/换群后不累积

#### Scenario: 成员视图标签下成员按钮不空转

- **WHEN** 用户切到「成员视图」标签
- **THEN** 群聊头部的「成员」切换按钮不存在或不可用，`aria-expanded` 不谎报抽屉已开；再切回「群聊」时抽屉是关闭的

#### Scenario: 成员视图与名单滚动位置恢复

- **WHEN** 用户把成员视图或成员名单滚到中段（容器确实可滚，`scrollHeight > clientHeight` 且 `scrollTop > 0`），然后切标签或开关抽屉再回来
- **THEN** 对应容器的 `scrollTop` 恢复到离开时的位置，不被重置到顶部；切换成员不作为该判据

#### Scenario: 换群不重放旧链提示

- **WHEN** A 组链结束并显示过提示，用户切到 B 组再切回 A 组；等 A 的 `group.chain` 响应与两帧渲染后再断言
- **THEN** A 的旧提示不再重放；A 组视图挂载后新的链结束仍显示提示；不承诺离开期间结束的链在回来时补提示，换群也不依赖 `key` 重建

#### Scenario: 群聊数据未就绪显示占位

- **WHEN** 用户从一个群聊切到另一个群聊，新群的 `group.list` / 消息尚未返回
- **THEN** 主区显示群聊加载占位，不显示上一个群的标题、成员或消息；数据到达后再显示新群内容

#### Scenario: 群聊重载失败保留已加载内容

- **WHEN** 群聊已成功显示时间线与成员，随后一次 `onReload`（例如切开关后的重拉）的 `group.list` / `message.query` 失败
- **THEN** 时间线、成员、游标与快照仍保留，页面显示错误条，不退回 `group-loading`；链状态与流式成员清空，取消按钮不被旧链误启用；只有首屏首次失败才占位

#### Scenario: 成员视图里链结束的提示有未读标记

- **WHEN** 用户停留在「成员视图」标签，链以 `round_cap` 或 `forced_pass` / `forced_empty` 结束
- **THEN** 「群聊」标签显示未读点（`data-unread="true"`）；切回群聊后看到对应提示，提示不再隐藏在隐藏面板里

#### Scenario: 建组/加成员/编辑覆盖层/点名发送都可在界面上完成

- **WHEN** 用户从组视图建组、加两个成员、把其中一个的工具子集收紧、点名该成员发言
- **THEN** 四件事都经 `group.*` RPC 完成，界面显示该成员的生效工具清单与已发出的发言

#### Scenario: 新建组默认开启自发反应

- **WHEN** 用户新建一个组并进入组视图
- **THEN** 「自发反应」开关显示为开启，且 `group.list` 返回的 `reactionsEnabled` 为 `true`

#### Scenario: 切换自发反应开关

- **WHEN** 用户在组视图里关闭「自发反应」开关
- **THEN** 界面发出 `group.update`（参数 `reactionsEnabled` 为 `false`），重拉后开关显示关闭

#### Scenario: 修改轮数上限

- **WHEN** 用户在「反应轮数上限」输入框里填 6 并保存，随后清空再保存
- **THEN** 第一次 `group.update` 的 payload 带 `maxRounds = 6`；第二次带 `maxRounds = null`（恢复默认）；重拉后输入框分别显示 6 与默认值占位

#### Scenario: 开关开启时不选发言人即可发送

- **WHEN** 自发反应开启，用户不选发言人、只输入一条消息并发送
- **THEN** `group.send` 的 payload 里没有 `speaker`（或为空）；界面在收到 `started` 后立即解除“发送中”，时间线随后逐个出现成员的公开回复

#### Scenario: 发送态在 started 后解除

- **WHEN** 客户端发一条会触发多轮反应的消息，链尚未结束
- **THEN** 收到 `status = started` 后界面不再显示“发送中”；链活动指示与取消按钮仍可用（由 `group.chain` / 事件 / `busy` 驱动）

#### Scenario: 链运行中发送按钮仍可用

- **WHEN** 链正在跑，用户输入一条新消息并点发送
- **THEN** 发送按钮不因链在跑被禁用/拦截；`group.send` 返回 `started`，新用户消息写入并出现在时间线，执行器吸收它

#### Scenario: 不再有发送未开始的 busy 提示

- **WHEN** 客户端在链运行中发送
- **THEN** 界面不显示「发送未开始 / 组忙」之类的拒绝提示；只有参数/上下文错误（如关闭态无 speaker 且无 @）才显示可归因错误

#### Scenario: 反应链逐步展开

- **WHEN** 一条用户消息触发反应链，成员依次公开回复并分别调用工具
- **THEN** 时间线逐条新增公开回复，每个成员的私有工具行在其成员视图数据里可见；链进行中页面显示活动指示与正在流式的成员名（成员名单上有「正在反应…」，头部也有名字）

#### Scenario: 达到轮数上限的提示

- **WHEN** 链以 `stopReason = round_cap` 结束
- **THEN** 页面显示「已达轮数上限」提示；链状态与 `group.chain` 一致，后续点名仍可发送

#### Scenario: 取消停链

- **WHEN** 反应链进行中用户点「取消」
- **THEN** 界面发出 `agent.cancel`（组会话 id），链停止，不再出现新的公开回复

#### Scenario: 断线重连后仍能取消

- **WHEN** 反应链进行中 WS 断线重连，本地发送状态已丢失
- **THEN** 重拉 `group.chain` 得到 `status = running`（或 `group.list` 的 `busy = true`），「取消」按钮仍可用；点击发出 `agent.cancel` 并停链

#### Scenario: 关闭态含 @ 时空发言人可发送

- **WHEN** 自发反应关闭，用户不选发言人、输入一条含 `@乙` 的文本并发送
- **THEN** 前端放行该发送（不因缺 speaker 本地拦截），核心按 `@mention` 只跑「乙」；若核心判定 `@` 无效则返回可归因错误

#### Scenario: 被点名者不回应只提示本次结果

- **WHEN** 链结束后 `group.chain` 的 `steps` 里有 `forced_pass` / `forced_empty`
- **THEN** 页面显示可归因提示，且不新增任何公开行；刷新页面后该提示不再出现（历史里没有它）

#### Scenario: 每成员占用环各用自己窗口

- **WHEN** 「甲」与「乙」的模型窗口分别是 1000000 与 200000
- **THEN** 在成员视图分别选中两人时，两个环的分母分别是各自实例的窗口（`member-window` 分别显示 1000000 / 200000），各按自己的 breakdown 绘制，不共用一个分母

#### Scenario: 事件按 payload 归位

- **WHEN** 两个成员先后发言
- **THEN** 每个成员的流式/工具/消息事件按 `memberId` 落到该成员的成员视图数据，公开回复按 `groupId` 落到时间线（e2e 断言 payload 字段，不只看 DOM 选中的成员）

#### Scenario: 加载页内的行都有归属去处

- **WHEN** 客户端加载一页消息
- **THEN** 每条行都能按 `author` / `visibility` 落到公开时间线或某个成员的成员视图数据（含已移除成员）；不在成员表的私有行落到只读「未知作者」横幅，不丢行、不重复显示

### Requirement: 群聊 RPC 面

核心 SHALL 提供 `group.create` / `group.update` / `group.chain` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（发言者可选）/ `group.view`（带成员 id）。这些方法名 SHALL 全部同步进 `kCoreRpcMethodNames`。失败 SHALL 返回可归因的 JSON-RPC 错误（指明组/成员/原因），MUST NOT 静默失败或崩溃。

`group.create` SHALL 接受可选的 `reactionsEnabled`（布尔；省略 = 新建组默认开启）与 `maxRounds`（整数 1..50；省略 / null = 用产品默认）。

`group.update` SHALL 接受 `{groupId, reactionsEnabled?, maxRounds?}`，至少给一个字段；`reactionsEnabled` 必须布尔；`maxRounds` 必须是 1..50 的整数或显式 `null`（显式 null = 恢复默认，**与字段缺席不同**：缺席 = 不改）。类型不对 / 越界 / 一个字段都没给 SHALL 返回可归因错误（`-32602`）；反应链运行中 SHALL 返回可归因 busy（不排队）。它仍只做组设置，不扩成通用 update。

`group.list` SHALL 返回每个组的 id、标题、`reactionsEnabled`、`maxRounds`（整数或 null）、**`busy`（布尔）与 `runningMemberId`（字符串或 null）** 与成员清单：每个成员带成员 id、显示名、模板名、**已移除标记 `removedAt`**、`overrides`（工具子集 / 提示词追加 / 思考强度）与 `effective`（生效工具清单、生效思考模式与强度），供界面渲染**成员视图与成员名单**、选发言人与展示覆盖层效果；不额外增加“列成员”的方法。`busy` / `runningMemberId` 是只读状态，使 web 在断线重连后仍知道链在跑、该显示/取消谁。

`group.member.update` SHALL 原地更新成员（显示名 / 模板 / 覆盖层）并保持成员 id 不变；更新后 SHALL 重建该成员实例（先退役/销毁旧实例，再按新配置创建），使新的工具子集与提示词追加生效。

`group.send` 的 `speaker` SHALL 可选：带发言者 = 定向该成员（开启态强制必应；关闭态纯 speaker 仍是旧普通轮）；不带 = 开关开启时纯触发（写用户消息并起链），开关关闭时按用户消息里的 `@mention` 定向、没有 `@mention` 则拒绝。**发送 SHALL 异步且永不 busy**：完成同步前置校验与用户消息写入后立即返回 `{groupId, sessionId, status: 'started', triggerSeq}`（带文本时 `triggerSeq` 为用户消息 seq；speaker-only 时为 null，由链状态更新）；链执行器在跑时新请求入队/被吸收，不返回 busy 拒绝。发送结果 SHALL NOT 携带 `steps` / `rounds` / `finalText` / `memberId`，SHALL NOT 等待链结束。

**`group.chain`**：`{groupId}` SHALL 返回当前 / 最近一条链的状态 `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps, error}`。`status ∈ {idle, running, completed, cancelled, failed}`；`stopReason ∈ {all_passed, round_cap, cancelled, failed, no_members}`（运行中为 null）；`error` 为字符串或 null——链 `failed` 时 SHALL 非空且含可归因文本（如 `unknown_context` / 成员轮异常原因），使界面与测试能知道失败真因，MUST NOT 只返回 `failed` 而吞掉原因；`rounds` 只计反应轮；`steps` 是 0..N 条，封闭取值是：
- `source ∈ { speaker, mention, reaction }`；
- `status ∈ { replied, passed, forced_pass, forced_empty, empty, failed, cancelled }`；
- 另有 `memberId` / `triggerSeq` / `publicSeq` / `finalText` / `error`。

`group.chain` 在核心重启后为 `idle`（本进程内语义）。链进入终态时 SHALL 通过 `agent.event` 发一条 `group.chain.completed`（`type` 为该值，携带 `groupId` / `sessionId` / `status` / `stopReason` / `rounds` / `triggerSeq`）；这是群聊反应链引入的唯一新增事件类型，本 change 不新增事件类型；其余仍复用既有事件类型。链的 `steps` 只用于观察与测试，SHALL NOT 成为消息的第二份存储。

`group.view` SHALL 返回该成员**本次运行内最近一次真实发出**的上下文快照（`system` / `messages` / `tools` + 窗口与 breakdown）；该成员本次运行内从未发言时 SHALL 返回空（界面显示占位），SHALL NOT 用历史拼一份“没发过的上下文”。重启后视图为空属既定语义（与真实上下文视图的“自本次启动以来”先例一致）。请求失败 SHALL 返回可归因错误，使界面能区分“读取失败”与“从未发言”。

#### Scenario: 十个群聊方法可调用

- **WHEN** 客户端依次调用建组、改组、查链、列组、加成员、改成员、发消息、取成员视图、移除成员、删组
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
- **THEN** `kCoreRpcMethodNames` 与实现一致（漏注册抛错），且网页文档的 RPC 表列出全部群聊方法（含 `group.chain`）

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

### Requirement: 群上下文跨核心重启存活

群的工作区上下文 SHALL 在核心重启后对**存量群**仍然可用：成员反应轮取工作区前 SHALL 先按需重注册群上下文（`ensureContext`，统一入口 `ensureGroupContext`），不得因 sidecar 内存上下文随重启丢失而对存量群报 `unknown_context`。`ensureContext` 异常 SHALL 包成 `GroupException`；`getWorkspace` 返回 ok 但工作区为空串 SHALL 按可归因错误处理，MUST NOT 静默以空工作区建成员。**自定义工作区不持久化**：`sessions` 无 workspace 列，重启后上下文新建（`created:true`）SHALL 回落缺省 `ConfigService.homeDir`（已知限制；持久化另立）；幂等仅指**同进程上下文仍在**（`created:false`）时不覆盖已有工作区，不是重启保留。新建群与单会话的既有行为不变。

#### Scenario: 重启后存量群成员轮可反应

- **WHEN** 建群（reactionsEnabled 开启）并加成员、发一条消息确认能反应；随后**同一数据库**重建 sidecar / 核心实例（模拟重启，内存上下文丢失），对同一存量群再发一条消息
- **THEN** 成员轮成功反应：链 `status=='completed'` 且步 `replied`/`publicSeq` 非空（不以「非 steps=0」判——失败步也让 steps>0），不报 `unknown_context`

#### Scenario: 同进程幂等重注册不覆盖已有工作区（回归守卫）

- **WHEN** 群上下文仍在（同进程，未重启），再次触发 `ensureGroupContext`
- **THEN** `created:false`，该群已有工作区不被覆盖（读 `getWorkspace` 验证）

#### Scenario: 重启后自定义工作区回落缺省（已知限制）

- **WHEN** 某群经 RPC 设了自定义工作区，核心重启后触发该群成员轮
- **THEN** 工作区回落缺省 `ConfigService.homeDir`（workspace 未持久化）；成员轮仍可反应，不报 `unknown_context`

#### Scenario: 新建群与单会话不受影响（回归守卫）

- **WHEN** 重启后新建群发消息，或打开存量单会话
- **THEN** 新建群正常反应（创建时已注册）；单会话沿用其懒注册，行为不变

### Requirement: 群链失败可归因

链 `failed` 时 SHALL 有可归因真因并经 `group.chain` 的 `error` 字段返回（字段形状见 MODIFIED「群聊 RPC 面」）；界面 SHALL 以独立提示（`group-chain-error`，不复用加载/视图错误提示）显示该真因，一过性（下次发送清除）。**现状纠正**：组链 failed 时界面此前什么都不显示（`turn.failed` 群分支被吞属 residuals），本需求新增真因显示。`completed`/`cancelled` 时 `error` SHALL 为 null，不显示旧错。

#### Scenario: 失败链返回真因并显示

- **WHEN** 一条链因成员轮异常（如 `unknown_context` 或 provider 错误）进入 `failed`
- **THEN** `group.chain` 回包含非空 `error` 且含该原因文本；界面 `group-chain-error` 显示该真因

#### Scenario: 非失败链不带旧错（回归守卫）

- **WHEN** 链 `completed` 或 `cancelled`
- **THEN** `group.chain` 的 `error` 为 null；界面不显示 `group-chain-error`
