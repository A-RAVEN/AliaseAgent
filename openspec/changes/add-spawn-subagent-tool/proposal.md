## Why

主 Agent 目前只能把检索、阅读和命令输出全部放进自己的消息历史，大范围调查会持续占用主对话上下文。Agent 对象、独立上下文和模板切换已经具备，下一步需要把这些能力暴露成 `spawn_subagent`，让主 Agent 创建一次性子 Agent 执行窄任务并只取回最终结论。

## What Changes

- 新增同步工具 `spawn_subagent`：输入任务和可选模板名；缺省继承父 Agent 的模板，显式指定时使用对应模板创建子 Agent。
- 子 Agent 在当前 Flutter 进程内使用独立上下文句柄、消息历史、模型—工具循环和计量；继承父 Agent 当前工作区，不复制父对话消息。
- 父 Agent 等待子 Agent 完整结束后取得结构化结果；成功时只把子 Agent 的最终回复作为工具结果送回父对话，不把子 Agent 的中间消息、思考或工具轮拼入父对话。
- 子 Agent 的运行记录通过 `parent_session_id` 关联父会话并保留在数据库，普通会话列表和启动恢复只处理顶层会话，避免一次性运行混入聊天列表。
- 父 Agent 取消、销毁或所属顶层会话删除时，正在运行的子 Agent 必须同步取消并完成资源清理；子 Agent 的失败、取消和空最终回复均返回可区分错误，不伪装成功。
- 第一版不允许子 Agent 继续创建下一层子 Agent，不提供并行调度、异步消息、长期驻留或独立子 Agent 界面。
- `spawn_subagent` 加入首启基础工具目录；既有模板不自动添加该工具，包括与上一版默认清单完全相同的模板，避免把用户主动移除的工具重新加回。旧两项首启清单仍按既有迁移规则升级，用户可在模板编辑器中自行添加或移除该工具。
- 增加单元、集成和界面测试，并同步用户文档与 README 功能索引。

## Capabilities

### New Capabilities

- `subagent-tool`: 规定一次性子 Agent 的工具输入、模板解析、上下文与历史隔离、工作区继承、结果回传、取消、清理和第一版范围。

### Modified Capabilities

- `session-persistence`: 会话增加可选 `parent_session_id`；子 Agent 记录随父会话删除，普通列表与启动恢复排除子运行记录。
- `context-handle`: 增加按句柄读取当前工作区的接口，供创建子 Agent 时继承父工作区。
- `ffi-bridge`: Dart 桥解析并暴露工作区查询接口，未知句柄继续显式失败。
- `agent-template-management`: 首启基础工具加入 `spawn_subagent`，既有模板不自动添加；用户显式添加或移除后必须保持选择。

## Impact

- Agent 执行：`lib/services/agent.dart` 增加结构化运行结果与 `spawn_subagent` 分发；`lib/models/tool_call_activity.dart` 保存不含密钥的子运行元数据；`lib/services/tool_result_text.dart` 保持通用截断规则，同时由 Agent 在历史重放时完整保留子 Agent 结论；新增子 Agent 创建、运行关系与清理服务。
- 创建与配置：`lib/services/agent_factory.dart`、`lib/models/resolved_agent_config.dart`、`lib/services/tool_catalog.dart` 和 `lib/main.dart`。
- 持久化：`lib/models/session.dart`、`lib/services/session_repository.dart`、`lib/services/database_service.dart` 增加非破坏性数据库迁移。
- 工作区接口：`lib/services/sidecar_bridge.dart`、`sidecar/include/sidecar_api.h`、`sidecar/src/sidecar_api.cpp`、`sidecar/src/context_api.cpp` 及相关头文件。
- 测试与文档：`test/unit/`、`test/integration/`、`test/widget/`、`sidecar/test/`、`Docs/user-guide/` 与 `README.md`。
- 不引入新进程、命令行程序、外部依赖或模型服务新接口；provider 密钥继续只作为 Agent 私有执行依赖。
