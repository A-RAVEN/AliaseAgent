## ADDED Requirements

### Requirement: 单聊头部不承载管理入口

web 单聊聊天屏（`ChatScreen`）的头部 SHALL 只承载身份与状态信息（标题、token 计量、连接状态），MUST NOT 渲染 Provider / 模板等管理入口按钮。管理入口 SHALL 由应用壳层左栏底部的全局设置菜单提供（见 `web-management-ui` 的「全局设置菜单（左栏底部唯一管理入口）」），单聊与群聊共用同一个入口。

#### Scenario: 单聊头部不出现管理按钮

- **WHEN** 用户打开任意单聊
- **THEN** 头部不出现 `Providers` / 「模板」按钮（`data-testid="open-providers"` 与 `open-templates` 在页面上不存在），标题、token 计量与连接状态照常渲染；单聊主区（含头部）没有其它打开 Provider / 模板管理页的控件，管理页仍可从左栏底部「设置」菜单打开
