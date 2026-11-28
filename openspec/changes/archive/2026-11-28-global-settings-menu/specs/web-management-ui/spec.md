## ADDED Requirements

### Requirement: 全局设置菜单（左栏底部唯一管理入口）

web 客户端 SHALL 在**常驻左栏的底部**（用户头像块之上、同一 footer 区）提供全局设置按钮（图标 + 「设置」文字），单聊、群聊与无选中会话三种状态下 SHALL 都可见且可用；管理入口 MUST NOT 依赖主区类型。点击按钮 SHALL 在其**上方**浮出一张圆角菜单（浮层，不挤动会话列表），每项 SHALL 由**图标 + 文字**组成。

菜单 SHALL **恰好两项**：「Provider 配置」打开既有 `ProvidersPage` 覆盖层；「模板配置」打开既有 `TemplatesPage` 覆盖层。MUST NOT 出现第三项，MUST NOT 加入用户资料 / 关于 / 反馈 / 登录等任何其它入口（用户 2026-11-25 明令「我说了要哪些就是哪些」）。两项 SHALL 复用现有管理页与 `App` 的 `panel` 状态（`setPanel('providers' | 'templates')`），MUST NOT 新写管理屏或第二条管理路由；管理页 SHALL 只覆盖主区，左栏保持可见可点（沿用「会话列表常驻左侧与主区切换」）。点菜单项后菜单 SHALL 关闭并打开对应管理页；菜单打开时点菜单外或按 `Escape` SHALL 关闭菜单并把焦点还给按钮；菜单已打开时再次点按钮 SHALL 关闭菜单。

按钮 SHALL 是真实 `button`，带 `aria-haspopup="menu"` 与反映开合态的 `aria-expanded`；菜单 SHALL 带 `role="menu"`，两项 SHALL 是 `role="menuitem"` 的可聚焦控件。管理入口 SHALL 全页唯一：不得在其它界面另设 Providers / 模板入口（旧入口的撤除见 `web-chat-screen` 的「单聊头部不承载管理入口」）。

#### Scenario: 群聊下打开模板配置

- **WHEN** 当前会话是群聊，用户点左栏底部的「设置」再点「模板配置」
- **THEN** `TemplatesPage` 覆盖层打开且只盖住主区，左栏仍可见、仍可点；菜单已关闭；群视图不因打开管理页而卸载或重置

#### Scenario: 单聊下打开 Provider 配置

- **WHEN** 当前会话是单聊，用户点左栏底部的「设置」再点「Provider 配置」
- **THEN** `ProvidersPage` 覆盖层打开；关闭后回到打开前的会话，标题与消息不变

#### Scenario: 菜单恰好两项且没有别的入口

- **WHEN** 用户点开全局设置菜单
- **THEN** 菜单项恰好 2 项，文字逐字为「Provider 配置」「模板配置」，每项带图标；菜单里没有用户资料 / 关于 / 反馈 / 登录或任何第三项

#### Scenario: 没有选中会话时入口仍在

- **WHEN** 用户删掉最后一条会话、主区是空聊天屏
- **THEN** 左栏底部「设置」按钮仍可见可用，点开仍是两项；打开 / 关闭管理页不报错

#### Scenario: 菜单开合与键盘

- **WHEN** 菜单打开时按 `Escape`，或点菜单外区域；或用户连续点两次设置按钮
- **THEN** 菜单关闭（`Escape` 后焦点回到设置按钮；第二次点按钮也是关闭），页面不留下不可关闭的浮层

#### Scenario: 单聊与群聊切换入口不消失

- **WHEN** 用户在单聊与群聊之间来回点选
- **THEN** 设置按钮始终在左栏底部（用户头像块上方）、位置与可用性不变，两个菜单项仍都能打开对应管理页

## MODIFIED Requirements

### Requirement: 管理屏视觉验收
管理屏与全局设置菜单属用户可见界面，验收 SHALL 含真实打开界面后的截图 + 主 agent read_image 核对画面内容（控件/渲染与要求一致）。自动化测试全绿 MUST NOT 替代视觉验收；缺截图与视觉验收视作不通过。

#### Scenario: 管理屏真实打开截图核对
- **WHEN** 验收会话侧栏/provider 页/模板页/向导/占用环/全局设置菜单
- **THEN** 真实打开各屏（含点左栏底部「设置」后向上浮出的菜单）并截图，主 agent read_image 核对控件与渲染正确（非错误页/空窗），测试绿不能替代
