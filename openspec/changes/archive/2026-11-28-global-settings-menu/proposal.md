## Why

web 客户端当前唯一的管理入口是**单聊头部的 `Providers` 与「模板」两个小按钮**：群视图里这两个按钮不存在，用户想改 provider 或模板必须先切回一个单聊（或先新建 / 选一个会话）。用户要求照 DSH 的做法，在**常驻左栏底部**放一个全局设置按钮，点开向上浮出菜单，把 provider 配置与模板配置作为子项收进去；菜单里只要这两项，不要加用户资料 / 关于 / 反馈 / 登录等任何其它入口。

## What Changes

- 新增 `web/src/components/GlobalSettingsMenu.tsx`：左栏底部（用户头像块之上）一个「设置」按钮，点击在按钮**上方**浮出圆角菜单，每项「图标 + 文字」。
- 菜单条目**恰好两项**：「Provider 配置」打开现有 `ProvidersPage` 覆盖层；「模板配置」打开现有 `TemplatesPage` 覆盖层。复用 `App` 的 `panel` 状态与 `setPanel('providers' | 'templates')`，**不新建管理屏**、不加第三项。
- `web/src/App.tsx` 在 `ChatShell` 的 `sidebarFooter` 槽里渲染该菜单（`UserAvatarBlock` 之上）；左栏在单聊 / 群聊 / 空选中下都常驻，因此三种状态都能打开管理页（修复群视图无入口）。
- **BREAKING（界面入口变更）**：移除 `web/src/components/ChatScreen.tsx` 头部的 `open-providers` / `open-templates` 两个按钮及对应 props，管理入口收归全局菜单单一入口；`App.tsx` 不再向 `ChatScreen` 传这两个回调。
- 同 change 同步测试与文档：更新 `web/e2e/group.mjs`（新增全局设置菜单用例；4 处旧 `open-providers` 点击改走新菜单；加截图钩子）、`test/unit/web_management_docs_test.dart` 与 `test/unit/web_core_docs_test.dart` 的布局锚点、`Docs/user-guide/web-management.md` 与 `Docs/user-guide/web-core-shim.md` 的入口位置说明。

## Capabilities

### New Capabilities

（无：本变更不引入新能力，只改现有 web 管理入口的位置与形态。）

### Modified Capabilities

- `web-management-ui`: 新增「全局设置菜单（左栏底部唯一管理入口）」要求（位置、恰好两项、复用现有管理页、单聊 / 群聊 / 空选中都可达、开合与可访问性、单一入口），并把全局设置菜单补进「管理屏视觉验收」的核对范围。
- `web-chat-screen`: 新增「单聊头部不承载管理入口」要求（头部只剩标题、token 计量与连接状态；管理入口由壳层左栏底部提供）。

## Impact

- 代码：`web/src/components/GlobalSettingsMenu.tsx`（新增）、`web/src/App.tsx`、`web/src/components/ChatScreen.tsx`；`web/src/components/ChatShell.tsx` 不改（复用现有 `sidebarFooter` 槽）。
- 测试：`web/e2e/group.mjs`（真实 `web/dist` + 假核心，新增用例并改 4 处旧入口点击）；`test/unit/web_management_docs_test.dart` 与 `test/unit/web_core_docs_test.dart`（布局锚点跟文档一起改）；`web/src/tokens.test.ts` 自动扫到新组件（禁裸值），`web/e2e/layout.mjs` 只做回归（harness 不渲染该菜单）。
- 文档：`Docs/user-guide/web-management.md`、`Docs/user-guide/web-core-shim.md`；`README.md` 的 web 管理屏索引条目没有写入口位置，不改。
- 无 RPC / 配置键 / 数据库 / C++ / Flutter 界面改动；无新依赖（图标复用既有 `lucide-react`）。
