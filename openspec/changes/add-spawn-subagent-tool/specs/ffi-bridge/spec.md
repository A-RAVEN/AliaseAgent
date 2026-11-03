## ADDED Requirements

### Requirement: get_workspace 通过 FFI 暴露给 Agent 创建路径

动态库 SHALL 导出 `get_workspace(const char* handle)`。Dart 桥 SHALL 在启动时解析该符号，在 `ISidecar` 与 `SidecarBridge` 提供签名一致的只读方法，并立即把 C 字符串复制为 Dart 字符串后解析 JSON。

成功时 Dart 调用方 SHALL 得到 `ok:true` 与 `workspace`；失败时 SHALL 得到可区分的 `unknown_context` 或 JSON 解析错误。缺失导出符号 SHALL 形成点名 `get_workspace` 的启动错误，不得静默改用主目录或伪造空工作区。该方法 SHALL NOT 读取界面当前会话，也 SHALL NOT 隐式调用 `ensureContext`。

#### Scenario: 桥返回父上下文实际工作区

- **WHEN** 父上下文已通过 `set_workspace` 设置工作区，子运行创建路径通过 `ISidecar` 查询父句柄
- **THEN** 返回值等于该父上下文的实际工作区，且不使用当前界面会话或应用主目录顶替

#### Scenario: 未知句柄错误保留

- **WHEN** Dart 桥用未知句柄调用 `get_workspace`
- **THEN** 调用方收到 `ok:false` 和 `unknown_context`，没有创建上下文或返回成功空串

#### Scenario: 假 sidecar 与真实桥接口一致

- **WHEN** 测试注入实现 `ISidecar` 的假 sidecar 并运行子 Agent 创建路径
- **THEN** 假 sidecar 能记录被查询的父句柄并提供工作区，Dart 静态分析不报告缺少接口实现
