# startup-tool-readiness Specification

## Purpose

界面从启动到"可以发消息"之间的就绪条件：**发给模型的工具清单必须已经装好，包括按可用性动态加入的那批**。

真机实测（`add-deepseek-web-search` 的 7.1）暴露过一例：启动后立刻发送，那一轮模型一个工具都没调、整轮空转。当时的处置只在真机用例里加等待，产品代码没动 —— 本规范把这件事变成产品行为。

**症状要说准**（第一轮对抗验证后更正）：不是"工具清单是空的"。`lib/main.dart` 的 `_initSearchAndTools()` 里，`_toolDefs = base` 在 `await _sidecar.browserAvailable()` **之前**同步执行，而 `base` 无条件含 8 个本地工具（`read_file` / `write_file` / `edit_file` / `list_dir` / `get_current_time` / `glob_file` / `grep_file` / `run_command`）。所以启动窗口期那一轮的清单**非空**，缺的是**动态加入的那批**：`web_search` / `web_fetch` / 浏览器四件套。后果是模型拿不到搜索能力（那次它一个工具都没调）。

## ADDED Requirements

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
