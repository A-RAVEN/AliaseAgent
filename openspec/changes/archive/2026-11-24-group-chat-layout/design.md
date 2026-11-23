## Context

现状的装配（`web/src/App.tsx`）：

- 会话状态与全部群数据都在应用入口持有；渲染时按 `currentSessionKind === 'group'` **整屏**选择 `GroupView`，否则渲染 `ChatScreen`。
- 会话列表组件其实已经拆出来了（`web/src/components/SessionList.tsx`），但它的宿主是 `ChatScreen`：`ChatScreen` 内部渲染左列 `<aside class="w-56">` 与列表。于是 `GroupView` 整屏替换 `ChatScreen` 时，列表跟着一起消失。
- `GroupView` 是三段竖排：头部（标题 + 反应开关/上限/取消）、中间「左侧成员（`w-72`）+ 右侧公开时间线与发送区」、底部「成员私有分栏」（`max-h-72`，横向网格排列每个成员的私有行、真实上下文与占用环）。
- 管理面板（Provider / 模板）在应用入口以 `absolute inset-0 z-20` 盖住**整个应用**。
- 群加载没有请求代次守卫：快速切群 A→B 时，A 的晚到响应可能把 A 的摘要/消息/快照挂到 B 的标题下。
- 成员快照用 `SnapshotEventData | null` 表示，取回失败与“本次运行内没发过言”都落成 `null`，界面无法区分；成员私有的「真实上下文」需要先展开、且只在底部分栏里。
- 会话行操作没有按 `kind` 分流：删除一律 `session.delete`，模板下拉对群聊也可选，重命名群聊不会同步群主区标题。

用户要的微信心智模型是：**会话列表常驻左侧，单聊与群聊混排，点哪个开哪个**；群聊是普通会话，不应整屏替换；成员名单在右；成员的私有上下文应是一个独立可查看的视图，而不是压在聊天下面的分栏。数据层已经是会话制（`sessions.kind`、`session.list` 同时返回两种会话、`group.list` 返回成员与链状态），因此本 change 只动 web 的布局装配与它必须补的加载/状态正确性，不动数据、RPC 与调度。

约束：

- 设计 token 的数值事实源是 `web/src/tokens.ts` 与 `index.css` 的 `@theme`；组件不写裸十六进制/任意间距。`tokens.test.ts` 的扫描范围要补上 `src/group/**` 与 `src/layout/**`。
- 既有测试形态：纯逻辑用 vitest（`web/src/**/*.test.ts`），真实渲染用 puppeteer（`web/e2e/layout.mjs` 走测试挂架，`web/e2e/group.mjs` 走真实 `web/dist` 与假核心）。
- 禁止新造上下限魔数；布局尺寸优先复用产品里已经存在的值。

## Goals / Non-Goals

**Goals:**

- 会话列表在应用层常驻左侧：打开群聊、切换单聊、打开管理面板时列表都**恰好存在一个节点**且不消失；单聊与群聊同列混排且可按 `kind` 区分；滚动位置与选中态跨主区切换保持。
- 群聊只占「列表右边的主区」：应用按选中会话的 `kind` 切换主区，不再整屏替换；空选中是空聊天屏；群聊数据未就绪时显示加载占位；快速切群的过期响应被丢弃。
- 群聊主区是 `[群聊 | 成员视图]` 双标签。群聊标签 = 公开时间线 + 发送区（中）+ 成员名单（右）；成员视图标签 = 成员选择器 + 该成员私有过程行 + 真实上下文 + 占用环（分母是该成员自己的窗口）。
- 删除底部「成员私有分栏」；公开时间线拿回完整的垂直空间。
- 群会话行操作按 `kind` 分流：删除走 `group.delete`，模板下拉禁用并说明由成员决定，重命名同步群主区标题。
- 成员快照区分 `loading / ok / empty / error`，错误显示可重试提示，不伪装成“没发过言”；成员视图的私有行保留范围说明与「加载更早的消息」入口。
- 窄屏下成员名单降级为右侧抽屉，双标签与发送区仍可用，页面不横向溢出；抽屉关闭时头部仍能看到正在流式的成员名。
- 保留 `group-reactive-mode` 的全部状态机：自发反应开关、轮数上限、链活动指示、取消按钮（断线重连后仍可用）、`round_cap` / `forced_pass` 提示、按 `memberId` 归位的事件与流式指示；成员视图激活时链终态提示有可见的未读标记。
- 不改数据模型、RPC、投影、压缩与 Flutter 界面。

**Non-Goals:**

- 不做移动端专用的第二套页面；窄屏只做抽屉降级。
- 不做可拖拽分栏、可折叠会话列表、群成员排序/搜索（列表与成员顺序仍由核心返回顺序决定）。
- 不把管理面板的入口加到群聊头部（现状群聊头部没有 Provider/模板按钮，本 change 不新增入口，只改面板的位置与关闭时机）。
- 不新增 `config.json` 键、不新增第三方依赖、不改 `web/src/tokens.ts` 的既有数字。
- 不把 `SessionList` 的交互重写一遍；只上提宿主、补群聊类型标记与群行操作分流。

## Decisions

### D1 壳层归属：新增 `ChatShell`，由应用入口渲染常驻列表

新增 `web/src/components/ChatShell.tsx`，只做布局，不持有数据：

```tsx
<ChatShell
  sidebar={<SessionList ... />}
  overlay={panel === 'providers' ? <ProvidersPage ... /> : panel === 'templates' ? <TemplatesPage ... /> : null}
>
  {主区：群聊主区或单聊主区}
</ChatShell>
```

`ChatShell` 渲染：

```
<div class="flex h-full min-h-0">
  <aside data-testid="session-sidebar" class="flex w-56 shrink-0 flex-col border-r border-line bg-surface">
    {sidebar}
  </aside>
  <main data-testid="main-area" class="relative flex min-w-0 flex-1 flex-col">
    {children}
    {overlay ? <div class="absolute inset-0 z-20 bg-bg">{overlay}</div> : null}
  </main>
</div>
```

理由：

- **列表的宿主必须是应用入口层级**，而不是聊天屏。把「左列 + 主区插槽」做成一个壳，应用的渲染路径里就不存在「群聊替换整个屏幕」这种分支，结构上保证列表不会被卸载。
- **测试挂架复用同一个壳**：`web/test/harness/main.tsx` 现在直接挂 `ChatScreen`；改造后挂 `ChatShell + SessionList + ChatScreen`，既有的会话列表虚拟滚动/侧栏交互断言仍然量的是真实组件，而不是测试里另写一份侧栏。
- **管理面板收进主区插槽**：`overlay` 绝对定位只覆盖 `main-area`，左列仍在。选会话 / 新建会话 / 新建群聊时把 `panel` 置空，避免「点了会话但管理页还盖着主区」。
- **提示条仍在主区组件里**：`ChatScreen` 继续接收并渲染 `error` / `notice` / `skillFailures` 三个属性，`ChatShell` 不接管它们；这样单聊的提示条位置与叠放顺序不变，群聊的 `error` 横幅仍由 `GroupView` 自己渲染。
- **页面唯一主地标**：`ChatShell` 用 `<main data-testid="main-area">` 作为唯一主地标；`ChatScreen` 与 `GroupView` 内部原先的 `<main>` 改为 `<section>`/`<div>`，`GroupLoading` 也在该 main 内。这样单聊、群聊、群加载、成员视图四个状态下页面都恰好有一个可见 `main`，不会出现「成员视图把唯一 main 藏起来后 0 个」。Wizard 态在壳外渲染，main 数为 0，D1 的「唯一 main」只承诺四态，不写“始终”。
- 否决「把列表直接内联在应用入口的 JSX 里」：测试挂架要么复制一份侧栏（与产品漂移），要么只能挂整个应用入口（需要真实 WS 与数据库）。壳组件是唯一能让两边共用同一布局的落点。

`ChatScreen` 因此变成纯主区：删掉 `sessions` / `currentSessionId` / 选中/新建/重命名/删除/模板切换相关的属性，只保留 `status`、`sessionTitle`、`sessionSelected`、消息视图、快照、计量、发送、提示条与管理页入口。标题仍显示在聊天屏头部，但由应用入口传入。

### D2 主区切换、群加载正确性、激活重置与群行操作

新增 `web/src/layout/model.ts`（纯函数，vitest）：

```ts
export type WorkspaceMode = 'group' | 'chat' | 'empty';
export function workspaceMode(session: Pick<Session, 'kind'> | null | undefined): WorkspaceMode;
export function sessionKindLabel(session: Pick<Session, 'kind'>): '群聊' | '单聊';
export function sessionKindBadge(session: Pick<Session, 'kind'>): '群' | null;
```

- `workspaceMode(null)` → `empty`；`kind === 'group'` → `group`；其余 → `chat`（运行时脏值按单聊处理的防御分支）。
- **空主区的口径**：`empty` 仍渲染 `ChatScreen`，但必须是**空聊天屏**——标题「（未选择会话）」、输入禁用、`view.messages` 为空、快照/计量/提示条都不残留。`workspaceMode` 只决定主区类型，不制造第三种空页面。
- `sessionKindLabel` 给行标题/无障碍文案提供完整类型名；`sessionKindBadge` 只给群聊行返回可见的「群」小标记（单聊返回 `null`），避免在 224px 的行里塞下「群聊」两个字。

**激活会话的统一重置清单**（`activateSession(session)`，选中、首屏自动选中、删除当前后都用它）：

1. 同步写 `currentSessionIdRef.current = session.id`，再 `setCurrentSessionId`（避免守卫读到旧 id）。
2. 清聊天侧：`setView(emptyChatView)`、`setEarlierCursor(null)`、`setSnapshot(null)`、`setSkillFailures([])`、`setMetering(null)`、`setError(null)`、`setNotice(null)`。
3. 清群侧：`setGroupStreamingMembers([])`、`setGroupChain(null)`、`setGroupSummary(null)`、`setGroupMessages([])`、`setGroupEarlierCursor(null)`、`setGroupLoadingEarlier(false)`、`setGroupSnapshots({})`、`setGroupFirstPageReady(false)`。
4. 不重置 `groupChainCompletedTick`（它必须单调，否则组视图的一次性提示游标会卡住）。
5. 按 `kind` 分支：单聊 `loadLatestPage`；群聊 `loadGroup`。禁止「按第一条的类型猜」。

**群加载的请求代次与提交纪律**（`loadGroup(sessionId)`）：

- **入口先判归属，再自增代次**：进入函数先 `if (currentSessionIdRef.current !== sessionId) return;`，然后才 `const generation = ++loadGenerationRef.current`。旧群 `onReload` 的续体（`GroupView` 里 7 处 `await onReload()`）不得把新群在途加载的代次顶掉，否则新群会永久停在占位且没有重试。
- 每个 await 之后核对 `generation === loadGenerationRef.current && currentSessionIdRef.current === sessionId`；不成立就**直接丢弃**本次结果（不 setState、不 setError）。
- 五类异步点全部要核对：`group.list`、首屏 `message.query`、逐成员 `group.view`、`group.chain`、以及错误分支。
- **分段提交**：`group.list` 与首屏 `message.query` 成功后，先把 `summary` / `messages` / `cursor` 与**全部成员的 `loading` 快照状态**一次性提交，并置 `groupFirstPageReady = true`；随后逐成员 `group.view` 成功/失败再各自守卫提交该成员的状态；`group.chain` 最后提交。每个提交点都先核对代次与当前 `sessionId`，过期结果丢弃。这样既不会把 A 的整页数据挂到 B，也允许成员快照在成员视图里显示 `loading`。
- **占位与失败分流**：首屏首次加载失败（当前群还没有已加载内容）时清空 `summary` / `messages` / `cursor` / `snapshots` / `firstPageReady`，主区显示 `group-loading` + 错误。**重载失败**（已有首屏内容，7 处 `onReload` 与消息事件共用 `loadGroup`）MUST NOT 清空已加载的时间线/成员/游标/快照；只 `setError`、清 `groupChain` 与 `groupStreamingMembers`（防止旧链让取消按钮误启用、假「正在反应」），保留页面内容供用户继续看。`loadGroup` 返回 `boolean`（成功/失败），供 tick bump 判断；不能自己吞掉失败还让调用方以为成功。
- 逐成员 `group.view` 失败不阻断首屏：该成员的快照状态记为 `error`（见 D4），其余成员照常提交。
- `group.chain` 只影响链状态，取不到时记 `null`，不阻断群加载。

**单聊加载错误与操作错误分离**：`loadLatestPage` 自己 try/catch，失败且仍是当前会话时 `setError('加载会话失败：…')` 并保留空主区，MUST NOT 产生 unhandled rejection；`activateSession` 调用加载函数但**不向调用方抛错**（`void createSession/deleteSession/selectSession` 不会冒 unhandled）。`createSession` / `deleteSession` 的操作 try 只包**操作 RPC**（`session.create` / `session.delete` / `group.delete`）；`reloadSessions` 单独 try/catch 成「列表刷新失败：…」；`activateSession` 在操作成功后调用。这样「删除成功但加载失败」只显示加载错误，MUST NOT 误报成「删除会话失败 / 新建会话失败」，列表刷新失败也不会混成删除失败。`refreshAfterReconnect` 单聊 catch 的会话守卫是 HEAD 遗留，另立 change，不在 R.1 假装修全。

**删除后按类型激活**（删除分流见 D8）：

- 当前选中的是单聊、删除后下一条是群聊 ⇒ 按 `group` 加载；当前选中的是群聊、下一条是单聊 ⇒ 按单聊加载。两个方向都按 `activateSession` 的 `kind` 分支，避免用上一条会话的类型猜。
- 删除当前群时走 `group.delete`（核心负责停链、销毁成员实例、级联删数据）；删除单聊走 `session.delete`。删除后 `reloadSessions` + `activateSession(next)`；没有下一条则清空主区为空聊天屏。
- 删除非当前会话只刷新列表与选中态，不动主区。

**重命名同步**：`renameSession(sessionId, title)` 更新 `sessions`；若被改名的是当前群（`groupSummary?.id === sessionId`），同步 `setGroupSummary({...groupSummary, title})`。`session.title` 事件到达时同样同时更新 `sessions` 与当前 `groupSummary`（群的第一条用户消息自动命名也走这条），使群主区标题不停旧值。

**群加载失败**：首屏首次失败清空并显示 `group-loading` + 错误；重载失败保留已加载内容、只显示错误并清链/流式状态（N2）；不回退到聊天屏、不显示上一条会话的快照或计量。

### D3 群聊主区：两行头部 + 双标签 + 右侧成员名单

`GroupView` 结构改为：

```
<div data-testid="group-view" data-active-tab="chat|members" class="relative flex h-full min-h-0 flex-col">
  <header>
    第一行：标题/说明（左） + 取消按钮 / kind / 窄屏「成员」按钮（右）
    第二行：标签组 [群聊 | 成员视图]（左） + 自发反应开关 / 轮数上限 / 链活动指示（右，可换行）
  </header>
  {error 横幅}
  <div data-testid="group-chat-panel" class="relative flex min-h-0 flex-1" 非激活时 hidden>
    <section>公开时间线（flex-1）+ 链提示 + 发送区</section>
    <aside id="group-members" data-testid="group-members">成员名单（右）</aside>
    <抽屉背景 + 窄屏关闭按钮（仅 < xl 且打开时）</aside>
  </div>
  <div data-testid="member-view" class="..." 非激活时 hidden>成员视图</div>
</div>
```

- **头部两行是固定的，不为宽屏再写一套**：第一行只放身份与全局动作，第二行放标签与组设置；窄屏自然换行（`flex-wrap`）。既有 `data-testid`（`reactions-toggle`、`group-round-cap`、`reaction-active`、`group-cancel`、`group-kind`）全部保留，e2e 与文档守卫不需要换选择器。
- **背景层不得盖住头部（N1）**：`group-members-backdrop` 的包含块必须是 `relative` 的 `group-chat-panel`，只能盖时间线/发送区；不得以 group-view 根为包含块盖住头部标签。否则 720px 开抽屉后点头部「成员视图」会命中背景，标签不切。头部可再加 `relative z-30` 作双保险。
- **双标签**用 `role="tablist"` / `role="tab"` / `aria-selected`；按钮 `data-testid="group-tab-chat"` / `group-tab-members`，文案逐字为「群聊」「成员视图」；每个 tab 用 `aria-controls` 指向对应 `role="tabpanel"` 的面板。切换只改本地状态，不重拉数据、不发 RPC。
- **两个面板都保持挂载**，非激活面板用 `hidden` 工具类隐藏（`display:none`；不要用 `hidden` HTML 属性配 `flex` 类，后者会覆盖前者）。这样切回群聊时时间线滚动位置、输入草稿、发言人选择都还在。根节点的 `data-active-tab` 供 e2e 判断当前激活面板；隐藏面板加 `aria-hidden="true"`，`display:none` 本身已把它移出键盘顺序。
- **成员名单右置**：`<aside id="group-members" data-testid="group-members">` 放在时间线与发送区之后。宽度沿用现状成员左栏的 `w-72`（288px），不改值。成员卡片、加入成员、覆盖层编辑器、移除按钮的 `data-testid`（`member-name-*`、`member-edit-*`、`member-remove-*`、`override-editor-*`、`member-add` 等）原样保留。`id` 供 `aria-controls` 使用，`data-testid` 保持不变。
- **流式成员名**：头部 `reaction-active` 的文案在已知流式成员时追加名字，例如「反应链进行中…（正在反应：甲、乙）」；没有流式成员但链在跑时保留「反应链进行中…（可取消）」。名字来源是 `streamingMembers`，链在成员间隙时用 `group.runningMemberId` 回退；这样 `< xl` 抽屉关闭时也能看到“哪个成员在流式”。
- **链提示的未读标记**：`forced-notice` / `round-cap-notice` 仍在发送区上方。当提示产生时用户正在「成员视图」标签，给 `group-tab-chat` 加 `data-unread="true"` 与一个可见小点（`data-testid="group-tab-unread"`），切回群聊后清除；这样提示不会在隐藏面板里静默丢失。
- **成员按钮只在群聊标签有意义**：`group-members-toggle` 只在 `tab === 'chat'` 时渲染/可用；切到「成员视图」时 `switchTab` SHALL 关闭抽屉（`membersOpen = false`），避免「按钮可见但成员名单在隐藏面板里、aria-expanded 说谎」。`aria-expanded` 的值只反映实际可见的抽屉。R.3 修好背景层级后，e2e 必须用真实 `page.click` 点头部标签，不能用 `element.click` 绕过命中层。
- **滚动位置存档**：时间线已有存档；成员视图与成员名单的滚动容器也要各存一份（标签切换、抽屉开合前保存，`useEffect([tab, membersOpen])` 在**可见后**恢复；同 tick 写入会被 `display:none` 清掉）。夹具必须真的可滚（成员视图 25 条私有行、名单 20 人，先断言 `scrollHeight > clientHeight` 且 `scrollTop > 0`）；「切成员」不隐藏成员视图容器，不作为滚动存档的判据。
- 群聊头部**不加** Provider/模板按钮（现状没有，不在本 change 扩入口）。
- 页面主地标由 `ChatShell` 的 `<main>` 提供；`GroupView` 内部不再写 `<main>`（时间线列用 `<section>`/`<div>`），成员视图同样不用 `<main>`。

### D4 成员视图标签：选择器 + 私有行 + 真实上下文 + 占用环

新增 `web/src/group/panel.ts`（纯函数，vitest）：

```ts
export type GroupTab = 'chat' | 'members';
export interface GroupPanelState { tab: GroupTab; memberId: string | null; }
export function initialGroupPanelState(): GroupPanelState; // { tab: 'chat', memberId: null }
export function resolveSelectedMemberId(members, selectedId): string | null;
export function switchGroupTab(state, tab, members): GroupPanelState;
export function selectGroupMember(state, memberId, members): GroupPanelState;
```

选择规则（`resolveSelectedMemberId`）：

1. `selectedId` 仍在**成员表**里（含 `removedAt !== null` 的软删成员）⇒ 保持它。软删成员的历史私有行仍要可查，不能因为 `removedAt` 非空就自动跳走。
2. 否则（成员 id 已从成员表消失）⇒ 取第一个**未移除**成员。
3. 没有未移除成员 ⇒ 取第一个成员（已移除成员仍可查看历史私有行与占位）。
4. 没有成员 ⇒ `null`。

**换群重挂的真实来源是首屏门，不是 key**：`activateSession` 会把 `groupFirstPageReady` 置假并清摘要，主区先渲染 `GroupLoading`，所以换群时 `GroupView` 本来就会卸载重挂；`key={groupSummary.id}` 是冗余的，删掉它不会改变换群行为，`useEffect([group.id])` 也不是修复依据。真正的重放修复是：`lastCompletedTick` 用挂载时的 `chainCompletedTick` 作基线（不是 0），并让 `loadGroup` catch 清 `groupChain` / `groupStreamingMembers`；详见 D12 / R.8。进入「成员视图」时把 `null` 解析成默认成员；切换标签不丢已选成员。

**成员快照状态**（替代 `SnapshotEventData | null`）：

```ts
export type MemberSnapshotState =
  | { status: 'loading'; snapshot: null; error: null }
  | { status: 'empty'; snapshot: null; error: null }
  | { status: 'ok'; snapshot: SnapshotEventData; error: null }
  | { status: 'error'; snapshot: null; error: string };
```

`GroupView` 的 `snapshots` 属性改为 `Record<string, MemberSnapshotState>`；App 在 `loadGroup` 时为每个成员初始化 `loading`，逐成员 `group.view` 成功且 `snapshot !== null` → `ok`，成功但 `snapshot === null` → `empty`，抛错 → `error`。**错误与“没发过言”必须分开**：`error` 显示 `member-snapshot-error` 与「重试」按钮（`onReloadMemberSnapshot(memberId)`，App 重新只拉该成员，不重载整条时间线）；`loading` 显示 `member-snapshot-loading`；`empty` 才显示 `member-no-snapshot`。

成员视图内容（单列滚动，不需要第二组宽度常量）：

```
<div data-testid="member-view" class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
  <div role="group" aria-label="选择成员" class="flex flex-wrap gap-2">
    {每个成员一个按钮 data-testid="member-select-<id>" aria-pressed=...}
      显示名 + （已移除）+ 正在反应…
  </div>
  {没有成员时的空态 data-testid="member-view-empty"}
  {未知作者（不在成员表的 lane）只读横幅 data-testid="member-unknown-authors"}
  {选中成员时：
    <section data-testid="member-context-section">
      <h2>真实上下文与占用</h2>
      {snapshot 状态 loading → <p data-testid="member-snapshot-loading">正在加载该成员的上下文…</p>}
      {snapshot 状态 error → <p data-testid="member-snapshot-error">读取失败：…</p> + <button data-testid="member-snapshot-retry">重试</button>}
      {snapshot 状态 empty → <p data-testid="member-no-snapshot">本次运行内没发过言（重启后为空是既定语义）。</p>}
      {snapshot 状态 ok → 窗口 {ringDenominator(snapshot)}；breakdown 存在则 <ContextRing/>，缺失则
        <p data-testid="member-no-breakdown">没有占用拆分数据：不渲染环（不静默当成 0）。</p>；
        <RealContextView snapshot={snapshot}/>}
    </section>
    <section data-testid="member-private-section">
      <h2>私有过程（仅该成员可见）</h2>
      <ul data-testid="member-private-rows">每行 data-testid="member-private-row"</ul>
      {lane 为空 → <p data-testid="member-private-empty">本次已加载页里没有私有行</p>}
      {hasEarlier → <button data-testid="member-load-earlier" onClick={onLoadEarlier}>加载更早的消息</button>}
    </section>
  }
</div>
```

- **复用而不是复制**：`ContextRing` 与 `RealContextView` 原样复用；窗口分母用 `group/model.ts` 的 `ringDenominator(snapshot)` 显示，环内部仍按 `breakdown.windowTokens` 绘制（核心按该成员实例的生效窗口给出，和现有口径一致）。
- **不再有「真实上下文」展开按钮**：成员视图就是查看视图，快照存在时直接显示原始 JSON；快照缺失时显示显式占位，不画空环。
- **私有行顺序按 `lane.messages`**（已按 `seq` 来自原文分页），每行带 `data-author={message.author}`（不能写 `lane.memberId`，否则作者负控恒真自证），供 e2e 与独立 oracle 对账；空内容显示「（私有过程：思考 / 工具调用）」，与旧分栏文案一致。空态必须写明范围「本次已加载页里」，并提供 `member-load-earlier`（复用同一 `onLoadEarlier`）把更早页的私有行取回当前视图；否则用户会误以为该成员从未有过私有过程。
- **未知作者 lane**：`splitGroupMessages` 对不在成员表里的 author 会生成一条「未知作者」lane。成员选择器只列 `group.list` 的成员（不把脏数据伪造成成员），但成员视图 SHALL 用一个只读横幅 `member-unknown-authors` 列出这些 lane 的名字与行数，使脏数据私有行有去处；MUST NOT 静默丢行。该分支只用于防御，不进入正常产品路径。
- **删除底部分栏**：`GroupView` 底部的 `<section class="max-h-72 ...">` 整体删除，`lanes` 只服务成员视图选中的那一栏与未知作者横幅。群里没有成员时，群聊标签仍可看到「还没有公开消息」，成员视图显示空态。
- 选择器按钮沿用既有控件高度（`min-h-6`）、圆角与边框 token；不新造尺寸。

### D5 窄屏降级：成员名单抽屉，标签保留

- 断点复用 `xl`（Tailwind 默认 1280px；`GroupView` 现有 `xl:grid-cols-3` 已经用它，不发明新断点）。
- `xl` 及以上：成员名单是群聊面板里的静态右列（`w-72`）。
- 小于 `xl`：成员名单默认隐藏，头部出现「成员」按钮（`data-testid="group-members-toggle"`，`aria-expanded`、`aria-controls="group-members"`）。打开时**同一个成员名单元素**改为绝对定位抽屉（`absolute inset-y-0 right-0 z-20 w-72`）并出现半透明背景；背景点击与抽屉内「关闭」按钮都能关。
- **跨断点必须能收**：打开态类串也必须带 `xl:static xl:flex`（不能只有关闭态带 `xl:`），否则在 `< xl` 打开抽屉后拉宽到 `xl`，它会以 absolute 浮层残留，而关闭按钮/切换按钮/背景都在 `xl` 隐藏，用户无法关闭。再加一个 `matchMedia('(min-width: 80rem)')` 监听（Tailwind v4 的 `xl` 是 80rem；JS 里 1280px 只在根字号 16px 时等价），跨到 `xl` 时 `setMembersOpen(false)`，缩回窄屏时抽屉保持关闭；监听器必须在卸载时 `removeEventListener`，避免换群重挂/StrictMode 双挂累积。抽屉加 `role="dialog"` / `aria-modal="true"`，Escape 可关，打开时焦点进入、关闭时回到触发按钮。
- **只渲染一份成员名单**：不用「桌面一份 + 抽屉一份」的两份 JSX，否则覆盖层编辑草稿、`data-testid` 与本地状态会分叉。用响应式类在同一元素上切换 `hidden / absolute / xl:static`。
- **抽屉关闭时的可见性**：流式成员名在头部 `reaction-active` 里可见（D3），所以 `< xl` 抽屉关着也不会丢掉“谁在流式”。
- **高度检查**：720px 的布局用例若要量成员控件，必须先用 `group-members-toggle` 打开抽屉再量（隐藏元素高度为 0，量它会假红）；1280px 保持静态右列量法。这是测试方法，不是产品尺寸。
- 双标签在窄屏不折叠、不换成下拉；两行头部允许换行。720px 宽时左列 224px、主区 496px，标签与发送区仍可操作，页面不得横向溢出。
- 抽屉不覆盖左侧会话列表（它定位在群聊根节点内），点会话列表仍可切会话。

### D6 布局尺寸与断点出处（不发明数字）

| 值 | 用途 | 出处 |
|---|---|---|
| 224px（`w-56`） | 左侧常驻会话列表宽度 | 现状 `ChatScreen` 内会话栏的 `w-56`，原值搬进 `ChatShell` |
| 288px（`w-72`） | 右侧成员名单 / 窄屏抽屉宽度 | 现状 `GroupView` 成员左栏的 `w-72`，原值搬到右侧 |
| 1280px（`xl`） | 成员名单静态右列与抽屉的切换断点 | Tailwind 默认断点；`GroupView` 现有 `md:grid-cols-2 xl:grid-cols-3` 已在用 `xl` |
| 36px（`ROW_HEIGHT`） | 会话行高（虚拟滚动） | `SessionList.tsx` 现有常量，不改 |
| 24px / 28px（`min-h-6` / `h-7`） | 既有控件高度（标签、输入、按钮） | 现状组件已用；不新增更小的可点尺寸 |
| 4/8/12/16/24px | 内边距与间距 | `tokens.ts` 的 `spacingScale` |

`web/src/tokens.ts` **不新增数字**；上述宽度通过既有 Tailwind 工具类表达。e2e 用 `getBoundingClientRect()` 实测左列 224、右列 288，防止实现时手滑改成别的数。`tokens.test.ts` 的扫描范围要从 `src/components/**` + `App.tsx` 扩到 `src/group/**` 与 `src/layout/**`，否则 `GroupView` 的裸值不会被守卫抓到。

### D7 与 `group-reactive-mode` 的状态如何保留

| 状态 / 行为 | 新布局里的位置 | 保留方式 |
|---|---|---|
| `reactionsEnabled` 开关 | 头部第二行 | DOM 与 `data-testid="reactions-toggle"` 不变；链运行中禁用的判据不变 |
| `maxRounds` 输入与保存 | 头部第二行 | `data-testid="group-round-cap"`、留空恢复默认、越界不静默改正全部不变 |
| 链活动指示 | 头部第二行 + 成员卡片 / 成员选择器 | `reaction-active` 保留并追加流式成员名；成员卡片与选择器上的「正在反应…」补上底部分栏删掉后的可见性 |
| 取消按钮 | 头部第一行右侧 | `group-cancel` 与 `chainIsRunning` 判据不变；断线重连后仍由 `group.chain` / `busy` 恢复可用 |
| 发送与异步解除 | 群聊标签的发送区 | `sending`、`started` 即解除、链中仍可发的逻辑不变 |
| `round_cap` / `forced_*` 提示 | 群聊标签发送区上方 + 群聊标签未读点 | 状态与一次性显示逻辑不变；成员视图激活时置 `data-unread`，切回群聊可见提示 |
| 事件按 `memberId` 归位 | 时间线 / 成员视图 | App 的重拉与 `streamingMembers` 逻辑不变；成员视图按选中 id 取私有行与快照状态 |
| 上翻分页 | 群聊标签时间线与成员视图 | `group-load-earlier` 与同一份 `groupMessages` 不变；成员视图新增自己的 `member-load-earlier` 复用同一回调 |
| 滚动位置 | 时间线 / 成员视图 / 成员名单 | 三个滚动容器各自存档并在切标签、切成员、开合抽屉后恢复；只保时间线不够 |
| 链提示游标 | 成员视图 / 群聊标签 | `lastCompletedTick` 以挂载时的 `chainCompletedTick` 为基线，不因换群重挂归零；App 只在 `loadGroup` 仍为当前群且成功后 bump |
| 快照状态 | 成员视图 | `loading / ok / empty / error` 四态；错误可重试，不伪装成没发过言 |
| 激活会话 | 主区 | `activateSession` 清空 snapshot / metering / skillFailures / notice / error / 群流式 / 群链 / 群摘要，保留单调的 `groupChainCompletedTick` |

标签切换不重建 `GroupView`，所以链/流式/草稿等本地状态不因切标签丢失；换群由 `groupFirstPageReady` 门经 `GroupLoading` 重挂，本地状态随重挂重置，`key` 是冗余的；旧链提示的重放由 `lastCompletedTick` 挂载基线 + catch 清链修复（D12 / R.8）。

### D8 会话列表：类型标记、群行操作与模板下拉

- `SessionList` 的虚拟滚动、行高、删除确认浮层、内联改名保持；`onDelete` 的参数从 `sessionId` 改为 `Session`（或增加按 `kind` 分流的回调），使确认浮层能按类型发不同 RPC。
- **删除分流**：群行 `onDelete` → `group.delete {groupId}`（核心负责停链、销毁成员实例、级联删除）；单聊行 → `session.delete {sessionId}`。确认浮层文案按 `kind` 显示「删除群聊…成员、消息与摘要都会删除」/「删除会话…运行实例与数据库记录都会被删除」。删除后由应用入口 `reloadSessions + activateSession(next)`。删除当前会话时 SHALL 在**删除成功分支** `setPanel(null)`（失败不关，避免掩盖错误）；本次「面板只盖主区」让侧栏删除按钮新可达，必须一并关面板。
- **模板下拉**：当前会话 `kind === 'group'` 时，模板选择器 SHALL 禁用或隐藏，并显示「群聊模板由各成员决定」的说明（`data-testid="group-template-note"`）；`session.switchTemplate` 对群必拒，界面不得让用户以为可以切。单聊行为不变。
- **重命名同步**：群行重命名除了更新 `sessions`，还要更新当前 `groupSummary.title`；`session.title` 事件同样同时更新两处，群主区标题不停旧值。
- 行元素加 `data-kind={session.kind}`；群聊行在标题前显示一个小「群」标记（由 `sessionKindBadge` 派生，单聊不显示标记），行标题/无障碍文案用 `sessionKindLabel` 的「群聊」/「单聊」，避免列表与详情各写一套字符串。
- 行 `title` 仍带完整标题与模板名；已有的「改名」「删除」按钮不因标记挤压而消失——小标记用 `shrink-0 text-xs`，标题列 `min-w-0 truncate`。
- 群聊与单聊由核心 `session.list` 的排序返回（最近更新倒序），前端**不重排**，避免与 Flutter 的列表顺序分叉。
- 列表节点必须全页唯一：`document.querySelectorAll('[data-testid="session-list"]').length === 1` 且其祖先链含 `session-sidebar`；打开管理面板时列表仍在，`elementFromPoint` 能命中列表而不是覆盖层。

### D9 测试策略

**纯逻辑（vitest，`web/src/**/*.test.ts`）**

- `web/src/layout/model.test.ts`：`workspaceMode` 的 `null` / `single` / `group` / 运行时脏值；`sessionKindLabel` 的两种文案；`sessionKindBadge` 的「群」/`null`。
- `web/src/group/panel.test.ts`：初始标签为群聊；进入成员视图自动选第一个未移除成员；**软删的已选成员保持选中**（`removedAt` 非空但仍在成员表）；成员 id 从成员表消失才回退；只有已移除成员时选第一个；没有成员时为 `null`；切回群聊不丢选择。
- `web/src/tokens.test.ts`：扫描列表加入 `src/group/**` 与 `src/layout/**`（至少 `GroupView.tsx`），裸 hex / 任意值 / 非 spacing scale 的间距仍会红。

**真实渲染（puppeteer）**

- `web/e2e/layout.mjs`（测试挂架）：测试挂架改挂 `ChatShell` 后，既有会话虚拟滚动/侧栏交互用例继续通过；新增：
  - 全页 `session-list` 唯一且祖先为 `session-sidebar`；左列 224px、主区在右；
  - 列表滚到中段 → 切会话 → `scrollTop` 不变；
  - `elementFromPoint` 命中列表而不是主区覆盖层；
  - 单聊态 `main` 是 `main-area`（`layout.mjs` 只挂 ChatShell+SessionList+ChatScreen，没有 GroupView/GroupLoading；四态主地标断言放 `group.mjs`，且单聊态修复前已有 1 个 main，不算红靶）；
  - 测试挂架注入 `error` / `notice` / `skillFailures` 时三条提示仍渲染（ChatScreen 未被壳吞掉）；
  - 720/1280 无横向溢出。
- `web/e2e/group.mjs`（真实 `web/dist` + 假核心）：
  - 8.3 建组/刷新/点组：补「组视图打开时唯一 `session-list` 仍在、且仍能点回单聊」。
  - 列表常驻：群/单/群来回切后列表节点仍唯一、滚动位置不变、选中态跟随；打开 Provider 页后列表仍可点，点会话面板关闭。
  - 群加载：延迟 A 的 `group.list` / `message.query` 后点 B，断言 B 标题下无 A 的成员/消息/快照，过期响应不提交；让 `message.query` 失败时 `group-loading` 仍在、错误可见、无 `timeline-empty`。
  - 快照状态：`group.view` 失败 → `member-snapshot-error` + 重试，不显示 `member-no-snapshot`；`loading` / `empty` 各自可见。
  - 成员视图：选择软删成员仍保持选中；私有行为空时显示「本次已加载页里没有私有行」+ `member-load-earlier`，点后更早页私有行出现；未知作者横幅存在；`breakdown: null` 的成员显示 `member-no-breakdown` 且无 `context-ring`；甲/乙窗口 1000000/200000 两环都在且分母各自正确。
  - 8.7 布局几何：时间线与右侧成员名单不重叠、成员名单在时间线右边、无横向溢出；底部分栏用 `[data-testid^="lane-"]` 计数 0（删前计数 >0）证明真的移除；发送区底边贴近视口底（`viewportBottom - composer.bottom <= 24`）证明底部分栏不再挤占。
  - 双标签：`data-active-tab` 与可见面板正确；切标签前后 `group.*` / `session.list` 的 RPC 计数不变；`group-input` 草稿与 `group-timeline.scrollTop` 切后不变；链运行中切标签 `reaction-active` 与 `group-cancel` 仍在。
  - 反应状态：720px 抽屉关闭时 `reaction-active` 含流式成员名；成员视图激活时链以 `round_cap` / `forced_*` 结束，`group-tab-chat[data-unread="true"]` 出现，切回群聊看到提示。
  - 群行操作：删除群行发 `group.delete`（payload 判据），单聊删除发 `session.delete`；删除单聊后下一条群聊按群加载，反向也按 kind；群模板下拉禁用且显示「群聊模板由各成员决定」；重命名群行后主区标题同步。
  - 8.7 高度：720px 先打开抽屉再量 `member-add`，1280px 保持原检查；`group-members` 有 `id="group-members"`，toggle 的 `aria-controls` / `aria-expanded` 正确。
  - 假核心扩夹具：单聊 + 群聊 + 快照状态（ok/empty/error/loading 可控）+ 1M/200K 窗口 + `breakdown: null` 成员 + 未知作者私有行 + 只在更早页出现的私有行；`group.delete` 实现；`group.view` 可延迟/失败。
  - `GROUP_DEFAULT=1` 的审计种子仍保留，用来给 `design_audit` 一个直接落在群聊主区的页面。
- 截图：`GROUP_SHOT` 保持群聊标签，用来核对「双标签、成员右置、无底部分栏」；新增 `GROUP_SHOT_MEMBERS` 先切成员视图再截图，用来核对「成员选择器、私有行、真实上下文、占用环」。两张都输出真实群聊主区画面供目视。
- `web/e2e/group_reactions.mjs`（真实核心的视觉驱动脚本）同步改为在成员视图里统计 `member-private-row`，不再依赖已删除的 `lane-item` / `lane-*`；**脚本内加硬断言**：切成员视图并选中一个成员后 `member-private-row > 0`，否则抛错。否则 live 视觉批次会在选择器上空转。

**返工红靶（R 节，先红后绿）**

- R.1 单聊加载失败（部分引入）：假核心 `messageQueryFailKind='single'` / `failNextSingleQuery` 对非首位单聊失败；点会话后出现 `error-banner` 的「加载会话失败：…」，页面无 unhandled `pageerror`，主区不被 silent 清空；create/delete 成功后加载失败、`reloadSessions` 失败各自显示「加载会话失败」/「列表刷新失败」，不误报操作失败；延迟+失败+立刻切走验证 catch 的 session 守卫。`refreshAfterReconnect` 单聊 catch 守卫是 HEAD 遗留，另立 change。
- R.2 群加载入口代次：假核心 `groupUpdateDelayMs` 卡 A 的 `onReload` 续体，同一 `page.evaluate` 先点 A 的 `reactions-toggle` 再点 B；`rpcLog` 记录 `group.update`→切 B→`loadGroup(A)` 顺序；B 不永久占位；另测 `refreshAfterReconnect` 旧 session 的 `loadGroup` 不顶新群；`waitForFunction` 非 `sleep`。
- R.3 背景层（N1）：720 开抽屉后**真实 `page.click`** 头部「成员视图」标签，标签切换、抽屉关闭；切回群聊抽屉仍关；背景若盖头部会命中背景而红。
- R.4 重载失败（N2）：先成功加载 A，再让 `onReload` 的 `group.list` / `message.query` 失败；时间线/成员保留、错误可见、不退 `group-loading`；首屏失败仍占位。失败时清 `groupChain` / `groupStreamingMembers`。
- R.5 抽屉跨断点/可访问性：720 开→1280 静态/无残留→720 关闭；`matchMedia('(min-width: 80rem)')` + 卸载 `removeEventListener`；Escape 可关、`role="dialog"` / `aria-modal` / 焦点返回。
- R.6 主地标/标签 a11y：四态全部在 `group.mjs`；`main` 唯一且 `main-area` 且可见，Wizard 0；`layout.mjs` 单聊态修复前已有 1 个 main，不算红靶；tab 有 `aria-controls` 指向 `role="tabpanel"`。
- R.7 成员按钮：720 固定、真实 `page.click`、`aria-expanded` 与实际 aside 可见性一致；不用「group-members 宽 0」证明关闭。
- R.8 换群提示（部分引入）：真实重放路径是 `loadGroup` catch 不清 `groupChain` + 旧终态链在挂载时 ≥ tick；修 `lastCompletedTick = useRef(chainCompletedTick)` 挂载基线、catch 清 chain/streaming、`loadGroup` 返回 boolean + 仅当前群成功后 bump；key 冗余（GroupLoading 门换群必重挂），去 key / `useEffect([group.id])` 不是修复依据；切回 A 等 `group.chain` + 2 个 rAF 再断言，只等 `group-view` 会假绿；不承诺离开时的链结束也提示。
- R.9 滚动存档：夹具甲 25 条私有行、名单 20 人；先断言 `scrollHeight > clientHeight` 且 `scrollTop > 0`；恢复用 `useEffect([tab, membersOpen])` 可见后写回；删「切成员」空靶。
- R.10 删除关面板（新暴露）：成功分支 `setPanel(null)`，失败分支保留面板并显错；删除当前会话后 `panel-overlay` 消失。
- R.11 测试质量/M3：`run` 内统一 `pageerror` 收集（`Promise.reject` 探针）、`rpcLog` 禁止清单（删群不得出现 `session.delete`，放行 `core.ping`）、不清 `responseLog`、flag 每用例 `finally` reset；`group-loading-error` 与 `group-view-error` 拆开，防四态互相冒充；群删除真 App 断言已由 1.4 覆盖。
- R.12 选择夹具/变异证据：首成员软删夹具；临时变异 `members[0]` 证明会红，失败输出落盘 `openspec/changes/group-chat-layout/evidence/r10-mutation.txt`。
- R.13 作者负控：`data-author = message.author`（不用 lane.memberId），真实脚本用 `Rpc` 查 `message.query` 按作者计数做独立 oracle；甲乙切换随选择变；同一断言复制到假核心 e2e 并进 `test:all`。

**视觉验收**：`design_audit` 对 `GROUP_KEEP=1` 的假核心页面在 1280 与 720 两个宽度各跑一次；新增标签/按钮不得低于 24px 命中高度，文本尺寸与颜色数不得因新布局失控；残留项逐条记录并说明是否刻意保留。

**文档守卫**：`flutter test test/unit/group_docs_test.dart`（`界面文案（web）：` 行必须在 `GroupView.tsx` 逐字存在；新增标签文案会作为新行加入）、`test/unit/web_chat_docs_test.dart`（参数表不动）、`test/unit/web_management_docs_test.dart` / `web_core_docs_test.dart`（RPC 表不动，但文档改错会红）；`flutter test test/unit/openspec_proposal_test.dart` 作为提案守卫。

### D10 文档同步

- `Docs/user-guide/group-chat.md`：把「在 web 哪里」「组视图包含」改写为常驻列表 + 双标签 + 成员右置 + 成员视图；删除「底部成员私有分栏」的旧描述；写明窄屏「成员」抽屉（含跨断点自动收起）、成员视图的空态/加载更早/未知作者、群行删除走 `group.delete`、群模板由成员决定、空主区口径、成员视图/名单滚动恢复、换群不重放旧提示；保留所有反应/上限/取消/已知限制段落与锚点。
- `Docs/user-guide/web-core-shim.md`：「打开聊天屏」「完整聊天屏怎么用」补会话列表常驻与「群聊是会话、点开只换主区」；写明管理入口在单聊顶栏，群聊打开时需先点回单聊；补单聊加载失败的错误横幅与「操作成功但加载失败不误报」；参数表与 RPC 表不动。
- `Docs/user-guide/web-management.md`：会话管理一节写明列表在群聊打开时仍可见；管理页只盖主区、点会话会关闭管理页；删除当前会话也会关闭管理页；管理入口在单聊顶栏；群行删除与模板下拉的限制。
- 三份文档的界面文案（「群聊」「成员视图」「成员」「正在反应…」等）必须与 `GroupView.tsx` 逐字一致；窄屏「成员」按钮的文本必须恰为「成员」（用 testid 邻域正则断言，不拿通用子串冒充）。由 `group_docs_test` 的 `界面文案（web）：` 机制与新增的文档 grep 任务共同守住。旧句（例如「公开时间线与成员私有分栏会一起补更早的一页」「每个成员一栏」）必须用 `isNot(contains(...))` 做负向断言。
- **归档同步**：`openspec/specs/agent-group-chat/spec.md` 的 Purpose 改为「公开时间线 + 右侧成员名单 + `[群聊 | 成员视图]` 双标签；真实上下文与占用环在成员视图内」，删掉「每成员私有分栏」；`openspec/specs/web-chat-screen/spec.md` 的 Purpose 补「应用壳层常驻左侧会话列表与主区按 kind 切换」。归档后 grep 旧短语必须为 0，并跑 `openspec validate --specs`。

### D11 明确不改的既有能力（核过主 spec 原文）

- `agent-group-chat` 的存储、投影、摘要私有性、隐私硬边界、规模前置、调度（含异步发送、结构化 PASS、上限、取消）全部不改；RPC 面除「供界面渲染分栏」这一句描述外不改。
- `web-core-shim` 的 RPC 面、事件类型与序列化不改；`session.list` 的 `kind`、`group.view` 的 `snapshot` / `breakdown` 形状早已存在，本 change 不改协议。
- `web-chat-screen` 的消息渲染、折叠、贴底、分页、重连与 token 约束不改；本 change 只新增一条「会话列表常驻」需求。
- `web-management-ui` 的会话管理 RPC 与侧栏交互不改；只改面板挂载位置（在应用入口的壳里）与群行删除/模板/重命名的界面分流，不改管理页内部。
- 布局尺寸全部溯源（224 / 288 / 1280 / 36 / 24 / 28 / spacing），不新增移动端专用布局、不给群聊加 Provider/模板入口、不新增配置项；`breakdown: null` 继续不画空环（`member-no-breakdown` + `ring-unavailable` 已有）。

### D12 返工：只修本次引入的缺陷

R 节任务只覆盖**本次布局重构引入或新暴露**的缺陷，按高→中→低排序：

1. **R.1 部分引入**：单聊加载无错误出口、`activateSession` 不接错误、create 成功但加载失败被误报是本次；delete 成功但加载失败被误报为「删除失败」在 HEAD 已有（HEAD 的 `deleteSession` 也把 `loadLatestPage` 包在操作 try 里），R.1 只保证不扩大并补齐加载错误/列表刷新错误出口。`reloadSessions` 单独 catch 成「列表刷新失败」；`refreshAfterReconnect` 单聊 catch 缺 session 守卫是 HEAD 遗留，不在 R.1 假装修全。
2. **R.2 引入**：`loadGroup` 入口先自增代次再判归属，旧群 `onReload` 续体可让新群在途加载过期；`group.list` 无参，红靶用 `groupUpdateDelayMs` 卡旧群续体，另测 `refreshAfterReconnect` 旧 session 路径。
3. **R.3 引入（N1）**：抽屉背景以 group-view 根为包含块，`absolute inset-0` 盖住头部；720 开抽屉后点头部标签会命中背景。修：背景收进 relative 的群聊面板，或头部 `relative z-30`。
4. **R.4 引入（N2）**：`loadGroup` catch 无条件清空首屏内容，而它同时是 7 处 `onReload` 与消息事件重载入口；瞬时失败整页打回 GroupLoading。修：首屏失败才清，重载失败保留内容并清 chain/streaming。
5. **R.5 引入**：窄屏抽屉打开态缺 `xl:` 覆写，跨断点无法关闭；`matchMedia('(min-width: 80rem)')` + `removeEventListener`；抽屉 `role=dialog`/Escape/aria-modal。
6. **R.6 引入**：主地标 `ChatShell` 是 div、`GroupLoading` 是 div、`GroupView` 唯一 `<main>` 在成员标签下被隐藏；四态 e2e 放 `group.mjs`，`layout.mjs` 单聊态不算红靶；补 tab/tabpanel a11y。
7. **R.7 引入**：成员视图标签下「成员」按钮空转、`aria-expanded` 说谎；背景层级修好后用真实 `page.click` 验证。
8. **R.8 部分引入**：tick bump 不守卫是 HEAD 既有，但本次新增的「换群必重挂」放大重放；key 不是唯一重挂源（`groupFirstPageReady` 门已保证换群重挂），去 key / `useEffect([group.id])` 不是修复依据。真正修复：`lastCompletedTick = useRef(chainCompletedTick)` 挂载基线；`loadGroup` catch 清 `groupChain` + `groupStreamingMembers`；`loadGroup` 返回 boolean，App 仅当前群且成功后 bump。不承诺离开时的链结束也提示。
9. **R.9 引入**：成员视图 / 成员名单滚动位置未存档（只存了时间线）；夹具必须真可滚（甲 25 条/名单 20 人），恢复用 `useEffect([tab, membersOpen])` 可见后写回，「切成员」不是有效判据。
10. **R.10 新暴露**：`deleteSession` 缺 `setPanel(null)` 在 HEAD 也有，但 HEAD 覆盖层全屏时侧栏删除不可达；本次面板只盖主区后才可达。修：成功分支关面板，失败不关。

另补三项**测试质量**（不是产品缺陷，但 R 节必做）：`pageerror` 统一收集与 `Promise.reject` 探针、`rpcLog` 禁止清单（删群不得出现 `session.delete`，放行 `core.ping`，不清 `responseLog`）、每个用例 `finally` 重置新增 flag；`group-loading-error` 与 `group-view-error` 拆开（M3）；`resolveSelectedMemberId` 的首成员软删夹具 + 变异证据落盘 + `group_reactions.mjs` 的 `data-author = message.author` 独立 oracle 负控。

**不在本 change 的既有缺陷**（HEAD 已存在；按能力另立 change，禁止混入 R 节）：

- `web-chat-screen-residuals`：群分页被事件重拉顶掉丢页（HEAD `loadGroup` 同样整表替换、`onEvent` 同样重拉、`loadGroupEarlier` 无守卫）；单聊互切草稿/待发图片串台（HEAD ChatScreen 无 key、Composer 本地草稿）；空聊天屏文案与禁用矛盾（HEAD 同文案）；`session.title` 全局守卫丢弃非当前会话标题；`loadEarlier` catch 无 session 守卫。
- `web-management-ui-residuals`：管理覆盖层无 inert/aria-hidden/focus trap（HEAD 同一覆盖层；本 change 只缩到主区）；`switchFailure` 残留（HEAD selectSession 同样没清）。
- `agent-group-chat-residuals`：覆盖层「关闭思考」空值三态被吞、`turn.failed` 群分支被吞、`private-to-author` 且 `author=null` 的脏数据方向、软删发言人仍可发送报错。`ringDenominator` 在成员视图是**新调用点沿用既有函数**，不是新缺陷；`ringDenominator` 与 `ContextRing` 的不可达互斥也只记录，不并入本 change。
- 「全局加载器无最新请求胜出」经 grep 核不实（找不到对应实现），从既有清单删除，除非后续能落到具体函数名。

### D13 返工：群上下文跨核心重启存活 + 失败可归因（核心 dart，主循环诊断查实）

**根因（证据确凿，临时诊断打印抓到后已逐字节还原）**：核心重启后任何**存量群**的成员反应轮第一步失败，链 `failed`/`rounds=1`/`steps=0`，一个 agent 都反应不了；新建群正常。真因 `读取组工作区失败（unknown_context）：unknown context: <groupId>`。机制：群工作区上下文只在 `group.create` 时经 `sidecar.ensureContext(session.id,…)` 登记进 sidecar **内存**；核心重启 → sidecar DLL 全新 → 上下文全丢，存量群无重注册。`ensureMemberAgent` 直接 `sidecar.getWorkspace(group.id)` **不先 ensureContext** → `unknown_context` → 抛 `workspace_unavailable` → 反应链在调模型前失败（sidecar 无 POST）。对照单会话：首次 send 经 `AgentFactory.ensure`→`existing.ensureContext()`/create→`Agent.ensureContext(homeDir)` 懒注册（`main.dart` 启动恢复显式跳过组会话），故单会话不报 unknown_context。新鲜满工具群实测 `all_passed` → 排除工具/余额，确证重启丢上下文。

**修复（R.14）与 workspace 持久化决定**：抽 `ensureGroupContext(groupId, {String? workspace})` 统一入口（**createGroup 传其 resolvedWorkspace、ensureMemberAgent 传缺省 homeDir**，不可无条件 homeDir 否则破坏 `group.create.workspace`），`ensureMemberAgent` 在 `requireGroup` 之后、`getWorkspace` 之前先按需重注册；`ensureContext` 抛的 `StateError` 包成 `GroupException`；`getWorkspace` ok 但空串按可归因错误处理（不静默以空工作区建成员）。**决定：不持久化自定义工作区**——`sessions` 表无 workspace 列，重启后上下文是新建（`created:true`）必 `setWorkspace(homeDir)`，故自定义工作区重启后**回落缺省**（已知限制；web UI 从不发 `group.create.workspace`，仅 RPC 可达；持久化留 `agent-group-chat-residuals`）。**幂等只在同进程成立**：`created:false` 不覆盖已有工作区是「上下文仍在」时的回归守卫，**不是重启保留**（旧稿把同进程幂等误推成重启不丢，已纠正）。选「按需」而非「启动遍历」的调用图证据：全仓库只有 `ensureMemberAgent` 读 `getWorkspace(group.id)`，`group.list`/`group.view`/`group.chain`/`group.update`/`agent.cancel` 都不碰 sidecar 工作区，故启动遍历非必需；抽统一入口防以后新增读取点复发。

**失败可归因（R.15）**：`GroupChainSnapshot.toJson` 当前不含 `error`。加 `error` 字段 + `toJson` + `snapshot()` 传 `chain.error`；`_handleGroupChain` 只是 `chainOf().toJson()`，**无需改 headless_core**。**现状纠正**：组链 failed 时界面**什么都不显示**（`turn.failed` 群分支被吞，属 `agent-group-chat-residuals`；steps=0 无 step 无事件），不是「只显示通用失败文案」。`protocol.ts` `GroupChainResult` 加 `error?`；`GroupView` 新增独立 testid `group-chain-error` 显示真因（一过性，下次 send 清，不复用 `group-view-error`/`group-loading-error`）；web e2e 假核心造 failed+error 断言该 testid。

**范围说明**：本条是 HEAD 就有的核心缺陷（非本 change 的 web 布局引入），用户明令并入本 change 返工。涉及 `lib/services/group_service.dart`、`web/src/protocol.ts`、`web/src/group/GroupView.tsx`、`test/integration`（含 harness/fake sidecar 扩基建）与 web e2e；不改布局。`group.delete` 不清理组上下文（`disposeContext(groupId)` 缺失）属预存缺陷，归 `agent-group-chat-residuals`，不并入本条。



## Risks / Trade-offs

- **[单聊加载失败静默 / 操作误报]** → 加载函数无错误出口时，断线/会话被删点会话会 unhandled rejection 且无横幅；加载失败被包进操作 try 还会误报「新建/删除失败」。缓解：加载函数自己 catch + `setError`，操作函数只把操作本身包进 try；e2e 让 `message.query` 失败并断言错误条与文案。
- **[跨断点抽屉关不掉]** → 打开态缺 `xl:` 覆写时拉宽到桌面会留下无法关闭的浮层。缓解：打开态也带 `xl:static xl:flex`，并用 `matchMedia('(min-width: 80rem)')` 在跨到 `xl` 时关抽屉（卸载时移除监听）。
- **[主地标在成员视图/加载态消失]** → `main` 被藏在 hidden 面板里。缓解：主地标上提到 `ChatShell`，内部不再写 `main`；e2e 四状态断言唯一且可见。
- **[成员按钮在成员视图空转]** → 抽屉在隐藏的群聊面板里，按钮仍切换状态；背景还可能先接住点击。缓解：成员视图不渲染/禁用切换按钮，切标签关抽屉；背景收进群聊面板；e2e 用真实 `page.click`。
- **[换群重放旧链提示]** → 真实路径不是单一 key：`loadGroup` catch 不清 `groupChain`，旧终态链在重挂时 ≥ tick；`groupFirstPageReady` 门又保证换群必重挂。缓解：`lastCompletedTick` 用挂载时 tick 作基线、catch 清 `groupChain` 与 `groupStreamingMembers`、`loadGroup` 返回 boolean 且仅当前群成功后 bump；不承诺离开时的链结束也提示。
- **[背景层盖住头部]** → 抽屉背景以 group-view 根为包含块时会盖住标签，720 点标签命中背景。缓解：背景收进 relative 的群聊面板，头部可加 `relative z-30`；e2e 用真实 `page.click`。
- **[重载失败打回空加载]** → `loadGroup` catch 无条件清首屏内容，7 处 onReload 的一次抖动会整页打回 GroupLoading。缓解：首屏失败才清，重载失败保留时间线/成员/游标/快照并清 chain/streaming；e2e 覆盖。
- **[成员视图/名单滚动丢失]** → 只存了时间线。缓解：成员视图与名单各自存档，`useEffect([tab, membersOpen])` 可见后恢复；夹具必须先证明可滚。
- **[删除后管理面板残留]** → 侧栏删除在面板打开时新可达。缓解：成功分支 `setPanel(null)`，失败保留面板；e2e 覆盖。
- **[乱序响应与旧群残留]** → 快速切群时 A 的晚到响应可能覆盖 B。缓解：请求代次 + `currentSessionIdRef` 双重核对，过期响应全部丢弃；e2e 延迟 A 后点 B 做红靶。
- **[重载失败与占位混淆]** → 首次失败应占位，重载失败应保留内容；两者混用会静默丢页。缓解：首屏/重载分支明确 + catch 清 chain；e2e 断言首次失败有 `group-loading`、重载失败时间线仍在。
- **[快照错误伪装成没发过言]** → `null` 同时表示失败与空。缓解：四态 `MemberSnapshotState`，错误显示重试；e2e 让 `group.view` 失败。
- **[群行删除走错 RPC]** → 用 `session.delete` 删群会绕过停链/成员实例清理。缓解：`SessionList` 按 `kind` 分流，e2e 以 `group.delete` payload 为判据。
- **[标签页隐藏面板仍挂载]** → `display:none` 保留滚动与草稿，但两个面板的 DOM 都存在（成员视图含原始 JSON）。缓解：成员视图只在有快照时渲染 `RealContextView`；隐藏面板加 `aria-hidden`；数据量本来就只有该成员一份快照。
- **[窄屏抽屉与桌面静态列共用一份 DOM]** → 响应式类切换时若状态处理不当，抽屉可能挡住时间线。缓解：`xl` 及以上强制静态列且隐藏背景/关闭按钮；抽屉打开只在 `< xl` 生效；e2e 在 720 与 1280 各测一次；720 量成员控件前先开抽屉。
- **[提示在成员视图丢失]** → `round_cap` / `forced_*` 提示在群聊面板，切到成员视图后隐藏。缓解：群聊标签未读点 + 切回可见提示；e2e 在成员视图跑完链后断言。
- **[底部分栏断言空转]** → 用不存在的 `group-private-lanes` 做空断言会永远通过。缓解：用 `[data-testid^="lane-"]` 计数 0（删前 >0 会红）+ 发送区贴近视口的几何；不再用不存在的 testid 作为唯一判据。
- **[会话行加类型标记挤压标题]** → 224px 宽度里标题变短。缓解：标记只对群聊显示、`shrink-0 text-xs`，标题列 `min-w-0 truncate`；行仍保持 36px 高，虚拟滚动不受影响。
- **[尺寸漂移]** → 左右列宽是两个既有值，但实现时容易被改成别的像素。缓解：e2e 实测 224/288；设计记录出处；不往 `tokens.ts` 加新数字；`tokens.test.ts` 扫描范围补 `src/group/**` 与 `src/layout/**`。
- **[既有 e2e 大面积改选择器]** → 底部 `lane-*` 的断言必须迁移到成员视图。缓解：保留 `member-*` / `group-*` 的既有 testid；新增 `member-view` / `member-select-*` / `member-private-row`；逐条把 8.5/8.6/8.8 的断言改到新位置，不删断言、不降标准。

## Migration Plan

- 无数据库、无配置、无 RPC 迁移；这是纯 web 构建产物变化。
- 部署：`cd web; npm run build` 后由无头核心 serve 新 `dist`。回滚：回退本次提交并重新构建；不触碰数据。
- 与 Flutter 共存不变：数据库与配置仍共用，Flutter 侧群聊占位行为不变。

## Open Questions

（无。布局尺寸、断点、成员选择规则、群行操作分流与面板归属均已按现有产品值与用户已敲定的方案 A 决定。）
