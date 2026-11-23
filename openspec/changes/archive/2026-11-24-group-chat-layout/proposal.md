## Why

群聊现在不像一个普通会话：打开群聊时，整个聊天屏被组视图**整屏替换**，而会话列表长在聊天屏内部，于是左侧列表随打开群聊一起消失。这违背微信式心智模型——**列表常驻、点哪个开哪个**，单聊与群聊只是同一张列表里的两种会话。数据层已经是会话制（`sessions.kind`、`session.list` 同时返回两种会话），缺的只是界面装配。

## What Changes

**A. 会话列表抬到应用层，常驻左侧**
- 新增一个只负责布局的壳组件（暂名 `ChatShell`）：左列固定放着会话列表，右列是主区插槽。列表不再由聊天屏渲染，也不再随主区切换被卸载。
- `SessionList` 组件本身已经存在（`web/src/components/SessionList.tsx`，含新建会话 / 新建群聊 / 选中 / 重命名 / 删除 / 切换模板）；本 change 只把它从聊天屏内部**上提**到壳组件，不重写它的交互。
- 列表里单聊与群聊混排，群聊行带可见的「群」标记与 `data-kind` 属性，便于区分。
- 管理面板（Provider / 模板）从「盖住整个应用」改为**只盖主区**：打开管理面板时会话列表仍在左侧可见、可点。

**B. 群聊作为普通会话打开**
- 应用入口按当前会话的 `kind` 切换主区内容：`group` → 群聊主区，`single` → 单聊主区；左侧列表完全不动。
- 群聊主区在数据未就绪时显示加载占位（不渲染上一个群的成员与消息），并按群 id 重置标签页与成员选择。
- 修一个现有会话切换缺陷：删除当前会话后若下一条是群聊，原逻辑总是按单聊加载；改为按 `kind` 激活。

**C. 群成员名单移到右边**
- 统一后的群聊主区采用「中：公开时间线与输入框；右：成员名单」两列。成员名单沿用现有内容（成员卡片、加入成员、覆盖层编辑、移除），只把位置从左列挪到右列。
- 在窄屏（小于现有 `xl` 断点）成员名单收起为右侧抽屉，由群聊头部的「成员」按钮开合；公开时间线与输入框不被横向挤扁。

**D. 成员视图独立成标签页（方案 A）**
- 群聊主区顶部改为双标签：**[群聊 | 成员视图]**。
- 「群聊」标签 = 公开时间线（中）+ 发送区（中）+ 成员名单（右）。
- 「成员视图」标签 = 成员选择器（甲/乙/丙，含已移除成员）+ 该成员的私有过程行 + 该成员的真实上下文（复用 `RealContextView`）+ 占用环（复用 `ContextRing`，分母取该成员自己的窗口）。
- **删除底部挤占主聊天的「成员私有分栏」**，其每成员内容整体搬进「成员视图」标签；时间线因此获得完整的垂直空间。

**E. 窄屏降级**
- 双标签在窄屏仍然可用；成员名单变为抽屉；不出现横向滚动。
- 不引入第二套移动端专用布局。

**F. 明确不改**
- 不改数据模型、SQLite schema、投影 / 压缩 / 调度语义；群聊 RPC 面仅 `group.chain` 增 `error` 字段（见 G），其余方法与行为不变。
- 不新增 `config.json` 键，不新增第三方依赖。
- 不改 Flutter 侧（群聊仍只在 web 有完整界面）。
- 不改「自发反应」开关、轮数上限、取消、链状态与事件归位的**行为**；只改它们所在的布局位置与可见性。

**G. 群上下文跨核心重启存活 + 失败可归因（核心 dart，用户明令并入返工）**
- 修一个 HEAD 就有的核心缺陷：群工作区上下文只在 `group.create` 时登记进 sidecar 内存，核心重启后存量群无重注册，`ensureMemberAgent` 直接 `getWorkspace` 报 `unknown_context`，反应链在调模型前 `failed`/`steps=0`（新建群与单会话不受影响）。改为统一入口 `ensureGroupContext` 按需幂等重注册（异常包成 GroupException、空工作区可归因）。**自定义工作区不持久化**：重启后回落缺省 `ConfigService.homeDir`（已知限制，web UI 不发自定义 workspace；持久化与 `group.delete` 上下文清理留 `agent-group-chat-residuals`）；幂等仅指同进程上下文仍在时不覆盖。
- `group.chain` 增 `error` 字段：链 `failed` 时返回可归因真因，界面不再只见「failed」不知为何。
- 此条非本 change 的 web 布局引入，是诊断查实的存量核心 bug，按用户指令并入本 change 返工。

## Capabilities

### New Capabilities

（无。本 change 是既有 web 界面的布局重构，不引入新能力。）

### Modified Capabilities

- `agent-group-chat`：`web 组视图` MODIFIED——会话列表常驻时群聊只占主区；成员名单右置；`[群聊 | 成员视图]` 双标签；成员私有分栏从底部移除并迁入成员视图；成员快照区分加载/成功/空/错误；窄屏抽屉降级。`群聊 RPC 面` MODIFIED——「供界面渲染分栏」改成「供界面渲染成员视图与成员名单」，`group.chain` 增 `error` 字段（失败可归因），其余 RPC 方法与行为不变。ADDED `群上下文跨核心重启存活`（存量群重启后成员轮可反应、ensureContext 幂等不覆盖工作区）与 `群链失败可归因`（group.chain 带 error）。保留既有反应开关、轮数上限、取消、链活动、发送、事件归位等全部行为与场景。
- `web-chat-screen`：ADDED `会话列表常驻左侧与主区切换`——会话列表在应用层渲染并常驻，单聊 / 群聊混排且可按 `kind` 区分；主区（单聊 / 群聊 / 管理面板）切换不卸载列表；管理面板只占主区。该能力原本只规定聊天屏内部的会话列表虚拟滚动，没有规定列表的归属层级，因此新增需求而不是改写旧需求。

## Impact

- **web 源码**：`web/src/App.tsx`（常驻列表、按 `kind` 切主区、群加载代次守卫与占位、删除后按 `kind` 激活、群行删除分流、重命名同步、管理面板收进主区并随选会话关闭）、`web/src/components/ChatScreen.tsx`（去掉会话列表与管理侧栏属性，只保留主区与 `error` / `notice` / `skillFailures` 提示）、`web/src/components/SessionList.tsx`（群聊行标记与 `data-kind`、群行删除分流、群聊模板下拉禁用）、新增 `web/src/components/ChatShell.tsx`（左列 + `main-area` 插槽 + 主区覆盖层）、新增 `web/src/layout/model.ts`（`workspaceMode` / 会话类型文案）、`web/src/group/GroupView.tsx`（双标签、成员右置、成员视图四态、私有行空态/加载更早、未知作者横幅、抽屉、移除底部分栏、未读提示）、新增 `web/src/group/panel.ts`（标签与成员选择的可测状态迁移）。
- **测试**：`web/src/layout/model.test.ts` 与 `web/src/group/panel.test.ts`（vitest 纯逻辑）；`web/src/tokens.test.ts`（扫描补 `src/group/**` 与 `src/layout/**`）；`web/test/harness/main.tsx`（改为挂 `ChatShell` + `SessionList` + `ChatScreen`，现有布局断言仍有真实对象）；`web/e2e/layout.mjs`（侧栏唯一/滚动/可点、主地标与提示条）；`web/e2e/group.mjs`（真实应用里的群聊开合、乱序响应、成员右置、双标签、成员视图四态、群行删除分流、管理面板只盖主区）；`web/e2e/group_reactions.mjs`（真实核心驱动，成员视图私有行硬断言）。
- **文档**：`Docs/user-guide/group-chat.md`（界面布局、双标签、成员右置、窄屏抽屉、移除底部分栏）、`Docs/user-guide/web-core-shim.md`（聊天屏布局与「群聊是会话」）、`Docs/user-guide/web-management.md`（管理面板只占主区、会话列表常驻）。三份文档都要与界面文案一致，并由可失败断言守住。
- **核心 dart（G 返工）**：`lib/services/group_service.dart`（抽 `ensureGroupContext(groupId,{workspace})` 统一入口、`ensureMemberAgent` 取工作区前按需重注册、`GroupChainSnapshot` 加 `error` + `toJson`/`snapshot()`；`_handleGroupChain` 只是 `chainOf().toJson()` 无需改）、`web/src/protocol.ts`（`GroupChainResult` 加 `error?: string | null`）、`web/src/group/GroupView.tsx`（`group-chain-error` 显示真因）；`test/integration/group_context_restore_test.dart`（同库重启反应 + 幂等 + 回落缺省）与 `group_reaction_rpc_test.dart`（group.chain error），含 harness/fake sidecar 扩基建。
- **不受影响**：C++ sidecar、SQLite schema、群聊其余 RPC 行为、`web/src/tokens.ts` 的数字、Flutter 界面、`config.json`、投影/压缩/调度语义。
