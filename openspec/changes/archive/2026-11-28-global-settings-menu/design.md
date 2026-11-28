## Context

web 客户端的管理入口目前长在**单聊聊天屏的头部**：`ChatScreen` 的头部渲染 `open-providers` 与 `open-templates` 两个小按钮，`App` 通过 `onOpenProviders` / `onOpenTemplates` 回调把 `panel` 置成 `'providers'` / `'templates'`，再由 `ChatShell` 的 `overlay` 槽把 `ProvidersPage` / `TemplatesPage` 挂在**主区**里（覆盖层只盖主区，左栏保持可点）。`GroupView` 分支没有拿到这两个回调，所以群视图里没有任何管理入口；空选中时虽然仍渲染 `ChatScreen`（`workspaceMode` 的 `empty` 态）而保留头部按钮，但入口本质仍挂在主区组件上，不是用户要的「全局」入口。

左栏是常驻的：`ChatShell` 的 `sidebarFooter` 槽当前只放用户头像块（`UserAvatarBlock`），它不随单聊 / 群聊切换，也不随 `panel` 打开而消失（`overlay` 在 `<main>` 内，`sidebarFooter` 在 `<aside>` 内）。用户要求照 DSH 的做法，在**左栏底部**加一个全局设置按钮，点开向上浮出一张圆角菜单，每项「图标 + 文字」，菜单里**恰好两项**：Provider 配置、模板配置；不要用户资料 / 关于 / 反馈 / 登录等任何其它项。管理页复用现有实现，不新写管理屏。用户已明令「我说了要哪些就是哪些，不要自己加料」，本设计把「恰好两项」当硬约束。

现有约束：组件样式必须取自 `web/src/tokens.ts` 与 `index.css` 的 `@theme`（裸 hex / Tailwind 任意值会被 `src/tokens.test.ts` 抓红）；图标只用既有 `lucide-react`；用户文档与它的守卫测试（`test/unit/web_management_docs_test.dart`、`test/unit/web_core_docs_test.dart`）当前把「管理入口在单聊顶栏」当布局锚点，入口搬家后必须同 change 改口径；界面交互的验收层是 puppeteer e2e（`web/e2e/`，真实 `web/dist` + 假核心）。

## Goals / Non-Goals

**Goals:**

1. 在常驻左栏底部（用户头像块之上）提供唯一的全局设置入口，单聊 / 群聊 / 空选中三种状态下都可见可用。
2. 点击在按钮**上方**浮出圆角菜单，每项「图标 + 文字」；菜单**恰好两项**，分别打开现有 `ProvidersPage` 与 `TemplatesPage` 覆盖层。
3. 群视图与单聊共用这一个入口（修复「群视图没有管理入口」）。
4. 撤掉单聊头部旧的两个按钮，管理入口只留一处。
5. 同一个 change 内更新用户文档、文档守卫与 e2e，并留下能变红的验收。

**Non-Goals:**

- 不新建管理屏、不改 `ProvidersPage` / `TemplatesPage` 的内部行为，也不新增管理 RPC / 配置键 / 数据库结构。
- 不加第三项或任何其它菜单项（用户资料 / 关于 / 反馈 / 登录一律不做）。
- 不改管理面板「只覆盖主区」、点会话 / 新建 / 删除当前会话时关闭面板等既有语义。
- 不改 Flutter 桌面端的侧栏入口（那是 Flutter 界面，不属本 change）。
- 不引入新设计令牌、新图标库或新的可配参数；不发明任何上下限 / 超时数字。
- 不改 `web/test/harness` 的职责边界（它是聊天屏布局挂架，不负责管理入口；菜单由真实 App 的 e2e 覆盖）。

## Decisions

### D1 宿主：复用 `ChatShell` 的 `sidebarFooter`，不新增壳层 prop

`App` 在 `sidebarFooter` 槽里渲染 `<> <GlobalSettingsMenu … /> <UserAvatarBlock … /> </>`，菜单在用户头像块之上。理由：`sidebarFooter` 已经是「左栏底部、常驻、不随主区切换」的既有槽位，语义与用户要的位置完全一致；新增 `sidebarSettings` 之类的 prop 只会多一层 API 而没有行为差异。`ChatShell.tsx` 本 change 不改。

### D2 组件：新增 `web/src/components/GlobalSettingsMenu.tsx`，只做展示与开合

组件是纯展示容器：props 为 `onOpenProviders(): void` 与 `onOpenTemplates(): void`，自己不连 WS、不持 `client`、不发 RPC；菜单开合状态由组件内的 `useState` 持有。理由：与既有 `ChatScreen` / `UserAvatarBlock` 的「App 算数据、组件渲染」分工一致；放 `components/` 下也自动被 `tokens.test.ts` 的裸值守卫扫到。备选「直接写进 `App.tsx`」被否：`App.tsx` 已经承载全部接线，内联会让入口逻辑和 RPC 装配混在一起，且无法单独在组件层讨论。

### D3 弹出层几何：按钮上方 `absolute bottom-full`，全部取值走既有令牌

- footer 里的这一行包在 `relative` 容器里：`border-t border-line p-2`。
- 按钮：真实 `<button>`，`flex min-h-6 w-full items-center gap-2 rounded-card px-2 py-1 text-sm text-muted hover:bg-surface-2 hover:text-fg`（可点面积沿用 `UserAvatarBlock` 按钮的 `min-h-6` + `px-2 py-1` 先例）；图标 `Settings`（`size={16}`，与 `SessionList` 的 `Plus` / `MessageList` 的 `ChevronDown` 同尺寸惯例，`aria-hidden`），文字「设置」。
- 菜单：`absolute bottom-full left-2 right-2 z-30 mb-1 rounded-panel border border-line bg-surface p-1 shadow-e2`；每项 `flex w-full items-center gap-2 rounded-card px-2 py-1 text-left text-sm text-fg hover:bg-surface-2`，图标分别为 `Server`（Provider 配置）与 `FileText`（模板配置），同样 `size={16}` + `aria-hidden`。
- 取值来源：`left-2` / `right-2` / `p-2` / `p-1` / `mb-1` / `gap-2` / `px-2` / `py-1` 都落在 `spacingScale`（4/8/12/16/24/32/48/64）上；`rounded-panel` = `radii.panel` 12px，`rounded-card` = `radii.card` 8px；`shadow-e2` = `elevation.e2`；颜色全部是 `palette` 生成的类名，不写裸值。`z-30` 与既有 `ContextRing` 的悬浮详情层同值（该处先例）。
- 备选「用 portal 挂到 body」被否：左栏没有 `overflow: hidden`，菜单宽 224px 列内即可容纳，portal 只会带来定位与层级的新麻烦。

### D4 菜单条目：写死两项，不做配置化

组件内一个 `as const` 的两项数组（`id: 'providers' | 'templates'`、`label`、`icon`、`testId`）映射到两个回调，标签逐字为「Provider 配置」「模板配置」，`testId` 固定为 `global-settings-item-providers` / `global-settings-item-templates`（菜单容器 `global-settings-menu`、按钮 `global-settings-button`）。不做"从配置读菜单项"或通用注册表——那会给"悄悄多一项"留入口。e2e 以 `role="menuitem"` 数量恰好 2 + 两个标签逐字匹配来钉住这条约束。

### D5 面板接线：沿用 `App` 的 `panel` 与 `setPanel`

两个回调就是 `setPanel('providers')` / `setPanel('templates')`；`overlay` 渲染分支、`onClose`、`onChanged`、选择会话 / 新建 / 删除当前会话时 `setPanel(null)` 全部不动。群视图能打开管理页不是靠给 `GroupView` 加回调，而是因为菜单在 `<aside>` 里、`overlay` 在 `<main>` 内——与主区是什么类型无关。

### D6 单一入口：删掉 `ChatScreen` 的两个按钮与 props

删除 `ChatScreen` 的 `onOpenProviders` / `onOpenTemplates` props、两个 `<button>`（`open-providers` / `open-templates`）与头部注释里「保留 Provider / 模板入口」的说法；`App` 不再传这两个回调。备选「新旧入口并存」被否：用户要求参考 DSH、入口收归全局，双入口正是本次要消除的分叉。

### D7 开合与可访问性

- 点按钮开 / 再点关；点菜单项时先关菜单再调回调（避免管理页打开后菜单还浮着）；点菜单外（`pointerdown` 不在组件容器内）关闭；按 `Escape` 关闭并把焦点还给按钮。
- 按钮：`aria-haspopup="menu"`、`aria-expanded={open}`、可见文字「设置」。
- 菜单：`role="menu"`、`aria-label="全局设置"`；两项是真实 `<button role="menuitem">`。不做焦点陷阱（非模态菜单，Tab 可继续走到用户头像块），也不做方向键漫游——两个条目的规模下，原生 Tab/Enter/Space 已足够，额外键盘模型属于加料。

### D8 状态边界：菜单开合留在组件内，`panel` 留在 `App`

两者不共享状态、不新建 context / 全局 store。菜单不会因为 `panel` 变化而失去同步（打开管理页的唯一路径是先点菜单项，而点菜单项必然先关菜单）。若将来有别的入口直接 `setPanel`，再考虑把 `open` 提升为受控——本 change 不做。

### D9 测试策略（便宜层够用就不往贵层堆）

- **真实 App e2e（`web/e2e/group.mjs`，puppeteer headless Edge + 假核心）**：新增一条「全局设置菜单」用例，覆盖——①按钮在 `session-sidebar` 内、在 `user-avatar-block` 上方；②点开菜单后 `role="menuitem"` 恰好 2 项、标签逐字、每项含 `<svg>` 图标；③菜单几何向上（`menuRect.bottom <= buttonRect.top + 1`）且在左栏宽度内；④点「Provider 配置」打开 `providers-page`、菜单消失，关闭后回到原会话（标题不变、消息条数不变）；⑤切到群视图后按钮仍在，点「模板配置」打开 `templates-page`（本 change 的核心修复），关闭后群视图仍在、时间线行数不变；⑥`Escape` 与点菜单外都能关，`Escape` 后焦点回按钮；连点两次按钮是开 → 关；⑦页面不存在 `open-providers` / `open-templates` 与「关于 / 反馈 / 登录」类菜单项；⑧`SETTINGS_SHOT` / `SETTINGS_SHOT_GROUP` 两个环境变量分别截「单聊菜单打开」「群聊菜单打开」的图。同时把该文件现有 4 处 `open-providers` 点击改走一个小 helper（`openProvidersPage`：点设置按钮 → 点 Provider 配置），否则撤掉旧按钮后既有用例必红。
- **回归**：`cd web && npm test`（`tokens.test.ts` 自动扫到新组件，裸 hex / 任意间距会红）；`npm run build:harness && node e2e/layout.mjs`（挂架不变，验证没有碰坏聊天屏布局）。
- **Dart 文档守卫（`test/unit/`）**：`web_management_docs_test.dart` 的布局锚点与 `web_core_docs_test.dart` 的布局锚点要跟着文档从「管理入口在单聊顶栏」改成新口径；`flutter test test/unit/web_management_docs_test.dart test/unit/web_core_docs_test.dart` 见绿。**不改其它断言、不放宽判据**。
- **不适用层**：`test/widget` / `test/integration` / `sidecar/test` / `integration_test --tags live`（不改 Flutter 控件、不改 RPC、不改 C++、不改模型装配）。`web/test/harness` 不加菜单：它只承载聊天屏布局用例，菜单由真实 App 的 e2e 覆盖。

### D10 文档同步

`Docs/user-guide/web-management.md` 与 `Docs/user-guide/web-core-shim.md` 里所有「顶栏 `Providers` / 顶栏「模板」/ 管理入口在单聊顶栏」的说法改成「左栏底部的「设置」→「Provider 配置 / 模板配置」」，并写明单聊 / 群聊 / 空选中都能打开。`README.md` 不改：它的「配置」段落讲的是 Flutter 桌面应用（`首次启动应用会弹出一个两步向导`）的侧栏入口，web 管理屏索引条目（`Docs/user-guide/web-management.md` 那一行）没有写入口位置。改文档的同一个 change 里改两份文档守卫，避免"文档已改、守卫还按旧口径"的中间态留到归档。

### D11 不发明数字

本 change 不引入任何上下限 / 超时 / 重试 / 批次数值：菜单只有两项、没有分页与截断；间距与圆角用既有 token；e2e 的等待沿用该文件既有的 `15000ms` 模式（既有代码先例，不是新设计参数）；图标尺寸 16 沿用既有图标调用惯例。

## Risks / Trade-offs

- [菜单被裁切或被覆盖层挡住] → 菜单挂在 footer 的 `relative` 容器内向上展开，左栏祖先链没有 `overflow: hidden`，`overlay` 只在 `<main>` 内（z-20）；e2e 用按钮 / 菜单的 bounding rect 断言「菜单在按钮上方且不超出左栏」。
- [撤掉头部按钮导致既有 e2e 变红] → 同一 change 内先把 `web/e2e/group.mjs` 的 4 处 `open-providers` 点击改成新 helper，再删按钮；收尾用 grep 确认 `web/src` 里不再有 `open-providers` / `open-templates`，`web/e2e` 里不再有直接点它们的语句。
- [文档守卫与文档不同步] → 两份守卫与两份文档在同一组任务里改，验收跑 `flutter test test/unit/web_management_docs_test.dart test/unit/web_core_docs_test.dart`；不许删用例或换成只查「设置」两字的弱断言。
- [以后有人悄悄加第三项] → 菜单项写死两项 + e2e 断言 `role="menuitem"` 数量恰好 2、标签逐字匹配；spec 里 MUST NOT 出现第三项或其它入口。
- [群视图打开管理页时群状态被重置] → 菜单只改 `panel`，不触碰 `loadGroup` / 代次守卫；e2e 在群视图打开模板页后关闭，断言群视图仍可用。
- [无障碍退化] → 真实 `button` + `aria-haspopup` / `aria-expanded` / `role="menu"` / `role="menuitem"`；`Escape` 还焦点；颜色与字阶来自 token，`design_audit` 不新增低对比。

## Migration Plan

- 无数据 / 配置 / RPC 迁移；发布方式就是重新构建 web 产物（`cd web && npm run build`）。
- 回滚：回退本 change 的提交即可回到「单聊头部两个按钮」的旧入口；文档与测试同批回退，不留旧锚点。

## Open Questions

无。用户已把设计闭合：位置（左栏底部）、形态（按钮 + 向上浮出菜单）、条目（恰好两项：Provider 配置 / 模板配置）、入口收归（撤掉单聊头部旧按钮）都已定，不需要在实现阶段再拍板。
