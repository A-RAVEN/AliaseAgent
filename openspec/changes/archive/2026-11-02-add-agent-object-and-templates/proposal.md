## Why

上下文句柄化已经隔离了执行状态，但当前应用仍没有独立的 Agent 运行对象：`lib/main.dart` 固定读取 `general` 模板，配置只在启动时加载，模板也无法在界面里添加或修改。现在需要先建立可配置、可创建、可销毁的 Agent 概念，否则后续 `spawn_subagent` 没有可复用的实体与配置边界。

## What Changes

- 新增 Agent 运行对象与统一管理设施：每个实例持有上下文句柄、不可变的实例生效配置、独立消息历史、模型—工具循环、取消、计量与销毁生命周期。当前聊天迁移为主 Agent，界面只负责展示与交互，不再直接持有模型执行逻辑。
- 新增实例生效配置的解析：按会话的 `agent_type` 选择模板并解析对应 provider，不再固定读取 `general`；集中校验模型、推理强度和上下文窗口，推导 `thinkingMode`，运行中不读取会被其它实例修改的全局配置。
- 按模板的工具清单过滤实际发送的工具定义，修正当前忽略清单的行为；首启默认工具清单同步覆盖现有基础能力，旧版两项默认清单通过可见迁移提示升级，自定义清单不变，未知工具名显式报错而不静默丢弃。
- 新增 Agent 模板菜单：显示模板列表，支持添加与修改模板；可配置 provider、模型、推理强度、系统提示词、工具集合与上下文窗口。模板名只在添加时填写，创建后不可改，避免既有会话引用悬空。保存后更新 `~/.aliasagent/config.json` 与模板注册表。
- 模板修改只影响之后创建或恢复的 Agent 实例；已经运行的实例继续使用自己的生效配置。配置中的非法窗口、模板或 provider 必须显式失败，不得静默关闭压缩或改用其它模板。首启补问改为合并必要字段，不覆盖既有配置。
- **返工补齐 Session 中的 Agent 切换**：当前会话提供模板选择入口；切换时先校验候选模板，等待旧实例整轮结束后退役旧 Agent 对象，保留同 Session 的上下文句柄、工作区、消息历史与工具输出溢出文件，再持久化新的 `agent_type` 并创建新实例。下一次请求实际使用新模板的模型、推理配置和工具；失败必须可见，不得静默退回 `general`。
- 第一版不支持删除模板、不编辑 provider 密钥、不做任意实例字段覆盖。补齐配置解析、运行隔离、会话恢复、模板添加/修改和 Session 切换的单元、界面与集成测试，并同步用户文档和配置说明。

## Capabilities

### New Capabilities

- `agent-runtime`: Agent 运行对象、实例生效配置、创建与注册、独立消息历史、模型执行、取消、计量和销毁生命周期。
- `agent-template-management`: 模板列表、添加与修改、字段校验、配置持久化，以及修改何时对新实例生效的规则。

### Modified Capabilities

- `agent-config`: 模板注册表增加添加与更新路径；模板与运行实例注册分离，按会话模板名查找，不再只服务于 `general`。
- `session-persistence`: 会话保存的 `agent_type` 从仅落库字段改为创建和恢复 Agent 时实际选择模板的依据；缺失模板必须显式报错，不得静默改用其它模板。
- `command-tool`: 命令工具从无条件发送改为在基础设施可用的前提下按 Agent 模板工具清单发送；命令超时归入实例生效配置。
- `file-edit-tools`: `write_file` / `edit_file` 从无条件注册改为不依赖搜索配置、但受 Agent 模板工具清单约束。
- `file-search`: `glob_file` / `grep_file` 从无条件注册改为不依赖搜索配置、但受 Agent 模板工具清单约束。
- `context-occupancy-ring`: 占用环的窗口分母与是否渲染改用当前 Agent 的实例生效配置，不再读取可能已修改的模板值。

## Impact

- **配置与运行模型**：`lib/models/agent_type_config.dart`、`app_config.dart`、`session.dart`；新增实例生效配置与 Agent 运行对象、工厂和实例注册表。
- **执行与状态**：`lib/main.dart` 的模型执行与摘要调用迁入 Agent；`lib/services/sidecar_bridge.dart` 继续负责 FFI，不改变既有 C++ 导出或请求格式。
- **模板管理**：`lib/services/config_service.dart`、`agent_type_registry.dart`，新增模板保存与编辑协调代码。
- **界面**：`lib/ui/session_sidebar.dart` 增加模板入口，新增模板列表与编辑对话框；当前会话工具栏新增 Agent 切换控件。新增 `AgentSessionController` 协调候选校验、旧 Agent 对象退役、`Session.agentType` 持久化与新实例创建；切换保留同 Session 的上下文句柄、工作区、消息历史与工具输出溢出文件，只有删除 Session 等真正销毁上下文的路径才删除这些文件。
- **测试与文档**：`test/unit/`、`test/widget/`、`test/integration/`；新增 `Docs/user-guide/agent-templates.md`，更新 `configuration.md` 与 `README.md` 索引。
- **明确不做**：`spawn_subagent`、模板删除、provider 密钥编辑、任意实例覆盖、进程隔离与多会话同时发送的界面改造。
