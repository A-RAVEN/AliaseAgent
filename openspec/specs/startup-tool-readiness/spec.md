# startup-tool-readiness Specification

## Purpose
TBD - created by archiving change fix-silent-truncation. Update Purpose after archive.
## Requirements
### Requirement: 工具清单未就绪时不许发起请求
界面 SHALL 在"完整工具清单（本地工具 + 按可用性动态加入的 `web_search` / `web_fetch` / 浏览器四件套）装好"之前，阻止发起一轮会话请求。阻止方式 SHALL 对用户可见：发送入口处于禁用状态，并给出可读原因。SHALL NOT 在未就绪时先发一轮"缺动态工具"的请求。

#### Scenario: 启动后立刻发送

- **WHEN** 应用刚启动、动态工具仍在准备（例如浏览器可用性探测还没返回），用户输入内容并按下发送
- **THEN** 那一轮请求 SHALL NOT 发出；界面 SHALL 让用户看到"正在准备工具"这一状态

#### Scenario: 就绪后恢复正常

- **WHEN** 完整工具清单装好
- **THEN** 发送入口 SHALL 恢复可用，且此后每一轮请求里的工具清单 SHALL 与装好的清单一致

#### Scenario: 缺的是动态那批，不是整个清单

- **WHEN** 检查未就绪那一刻界面持有的工具清单
- **THEN** 它 SHALL 含那 8 个本地工具、SHALL NOT 含动态加入的那批 —— 这条场景的作用是钉住症状描述，防止把"缺动态工具"误写成"清单为空"

#### Scenario: 这一条要能被断言

- **WHEN** 运行对应的窗口用例（假 sidecar 把浏览器探测的返回拖后）
- **THEN** 用例 SHALL 能断言"清单装好之前发送被挡住、且没有发出任何请求"与"装好之后那一轮请求里的工具名集合完整（含 `web_search`）"；把这条保护删掉 SHALL 让该用例失败

