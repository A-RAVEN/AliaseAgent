## ADDED Requirements

### Requirement: spawn_subagent 按模板提供并校验调用

系统 SHALL 在统一 `ToolCatalog` 注册同步工具 `spawn_subagent`，输入包含必填字符串 `task` 与可选字符串 `agent_type`。只有 Agent 生效配置包含该工具时，工具定义 SHALL 进入该 Agent 的模型请求；未配置的 Agent SHALL NOT 通过其它全局清单取得该能力。

`task` 去除首尾空白后为空、类型不是字符串，或 `agent_type` 不是非空字符串时，工具 SHALL 返回 `ok:false` 和可区分错误，不得创建子会话或子上下文。省略 `agent_type` 时 SHALL 使用父 Agent 创建时的模板名；显式指定时 SHALL 通过与普通创建相同的候选解析和校验，不得静默退回 `general`。

#### Scenario: 未配置工具的 Agent 看不到定义

- **WHEN** 一个模板的工具清单不含 `spawn_subagent`，使用该模板的 Agent 发起模型请求
- **THEN** 请求的工具定义不含 `spawn_subagent`，其它已配置工具保持不变

#### Scenario: 空任务没有副作用

- **WHEN** 模型以空字符串、纯空白或缺失的 `task` 调用 `spawn_subagent`
- **THEN** 返回 `ok:false` 和 `invalid_task`，不创建子会话、子上下文或模型请求

#### Scenario: 缺省继承父模板

- **WHEN** 父 Agent 使用非 `general` 模板，调用省略 `agent_type` 的 `spawn_subagent`
- **THEN** 子 Agent 使用父 Agent 的模板名解析配置，不读取界面当前模板，也不固定改用 `general`

#### Scenario: 显式模板校验失败

- **WHEN** 调用指定不存在模板、缺失 provider、非法上下文窗口或含未知工具的模板
- **THEN** 返回带候选模板名的可区分错误，不创建子会话、子上下文或运行实例

### Requirement: 子 Agent 使用独立配置、历史和工作区

子 Agent SHALL 在当前 Flutter 进程内通过统一 Agent 工厂创建，持有自己的上下文句柄、消息历史、不可变生效配置、模型—工具循环、取消状态和计量。子 Agent 的初始消息历史 SHALL 只包含本次任务产生的消息，不得复制父对话消息；子 Agent SHALL NOT 使用父界面的流式回调。

子 Agent SHALL 继承父上下文在调用时实际保存的工作区。系统 SHALL 从父句柄读取该值并用于子上下文初始化，不得假定等于应用主目录或读取界面当前会话。父工作区读取失败时 SHALL 返回错误且不创建子运行。

子配置 SHALL 附加一次性子 Agent 角色说明，要求最终回复自包含；子配置的实际工具清单 SHALL 排除 `spawn_subagent`，使第一版子 Agent 不能继续创建下一层。该排除 SHALL 只作用于子实例的配置副本，父实例和可复用模板 SHALL 保持不变。

#### Scenario: 子历史不包含父消息

- **WHEN** 父会话已有用户消息、助手消息和工具轮，随后创建子 Agent 并发送任务
- **THEN** 子 Agent 首次模型请求只含子系统提示与本次任务，不含父会话的历史消息或工具结果

#### Scenario: 工作区按父句柄继承

- **WHEN** 父上下文工作区已设为不同于应用主目录的目录，子 Agent 被创建
- **THEN** 子上下文初始化为同一工作区，父子工具随后仍使用各自上下文句柄

#### Scenario: 子实例使用冻结的独立配置

- **WHEN** 子 Agent 使用指定模板创建后，该模板或父 Agent 的模型、推理强度和工具配置随后被修改
- **THEN** 已创建子 Agent 的后续请求仍使用创建时快照，父子计量与请求参数互不覆盖

#### Scenario: 子 Agent 不能嵌套创建

- **WHEN** 父模板允许 `spawn_subagent`，系统创建子 Agent
- **THEN** 子 Agent 实际模型请求的工具定义不含 `spawn_subagent`，父 Agent 后续请求和保存的模板仍含该工具

### Requirement: Agent 发送路径提供可信的结构化运行结果

`Agent.send` SHALL 返回不可变结构化结果，至少区分完成、失败、取消和实例忙，并携带最终文本、错误与本实例计量快照。现有界面调用方 SHALL 能忽略该返回值而保持原有消息、流式事件和错误展示行为。

最终文本 SHALL 来自没有工具调用的最终模型轮，不得从子历史中任意挑选最后一条消息，也不得把已存储的错误消息当成成功结论。未预期异常 SHALL 形成失败结果；同一错误 SHALL NOT 因界面和子运行两条路径重复写库。

#### Scenario: 最终回复与中间工具轮可区分

- **WHEN** 子 Agent 先产生带工具调用的中间助手消息，再产生无工具调用的最终回复
- **THEN** 结构化结果的最终文本等于最后一轮回复，不等于中间消息或工具输出

#### Scenario: 模型失败不是空成功

- **WHEN** 子 Agent 的模型请求返回错误
- **THEN** 结构化结果为失败并带原始错误，`spawn_subagent` 返回 `ok:false`，不得返回 `ok:true` 和空 `content`

#### Scenario: 完成但没有最终文本

- **WHEN** 子 Agent 的模型循环完成但没有产生最终文本
- **THEN** `spawn_subagent` 返回 `empty_final_response`，不得把空内容作为成功结论

#### Scenario: 已有界面发送行为保持

- **WHEN** 普通会话通过既有界面发送路径调用已改为返回结构化结果的 `Agent.send`
- **THEN** 用户消息、助手消息、流式事件、错误消息和取消展示与既有行为一致，不新增重复消息

### Requirement: 父 Agent 同步等待并只接收最终结论

`spawn_subagent` SHALL 等待子 Agent 整轮结束后再返回。成功结果 SHALL 包含 `ok:true`、完整最终回复 `content`、`child_session_id`、实际模板、实际模型和子 Agent 计量；这些不含密钥的元数据 SHALL 随父工具调用活动与 `toolCallsJson` 保存，但 SHALL NOT 进入父模型可见的 `tool_result.content`。父 Agent 的后续模型请求 SHALL 只增加这次工具调用及其最终结果，不得拼接子 Agent 的中间消息、思考或工具轮。

最终回复 SHALL 在当轮工具结果和之后的历史重建中完整保留，不得按本 change 新增的字符数、token 数或时长界限截断，也不得为缩短结论额外调用摘要模型。`Agent._buildApiMessages` 重放 `spawn_subagent` 结果时 SHALL 使用保存的完整 `result`，不得套用通用 `elideOversizedToolResult`；其它工具的既有规则不变。子 Agent 的 token 和请求计量 SHALL 保持独立，不得加进父 Agent 的实例计量。

#### Scenario: 父上下文只增加结论

- **WHEN** 子 Agent 经历多轮工具调用后返回最终结论，父 Agent 继续下一次模型请求
- **THEN** 父请求包含 `spawn_subagent` 工具调用和完整最终结论，不包含子 Agent 的中间助手文本、思考、工具输入或工具输出

#### Scenario: 长结论在当轮与历史重放中都不截断

- **WHEN** 子 Agent 返回一份超过通用工具结果省略阈值的最终回复，父 Agent 随后再次发送并从持久化历史重新恢复
- **THEN** 即时工具结果、后续请求与恢复后重建请求中的结论都与原回复逐字相同，不出现通用省略标记或不可恢复引用，其它工具结果仍按原规则处理

#### Scenario: 子运行元数据持久化且父子计量各自归属

- **WHEN** 子 Agent 完成多次模型与工具请求，父 Agent 的工具调用记录写库并重新读取
- **THEN** 记录中的 `child_session_id`、实际模板、模型和计量等于子运行真实值，父模型可见内容仍只有最终结论，父 Agent 的实例计量不合并子计量

### Requirement: 取消、退役和销毁都有明确子运行边界

系统 SHALL 登记父会话与活动子运行的关系。单独取消子运行 SHALL 只取消子 Agent，父 Agent 收到取消结果后可继续处理；父 Agent `cancel` 或 `dispose` SHALL 先取消其活动子 Agent，再取消父请求并等待相关整轮与清理结束。其它 Agent 的上下文、请求和消息 SHALL NOT 受影响。

模板切换使用的父 Agent `retire` SHALL 继续让在途子调用与父整轮自然结束，不得为切换额外调用取消。子 Agent 无论成功、失败或取消，运行器 SHALL 在 `finally` 路径等待其整轮、销毁子上下文、移除运行实例并解除活动关系；子会话数据库记录 SHALL 保留。清理失败 SHALL 返回可区分错误，不得假装全部资源已释放。

子上下文销毁 SHALL 遵守既有资源契约，只清理子上下文自己的浏览器与 spill；父上下文的 spill 文件、序号和浏览器状态 SHALL 保持可用。

#### Scenario: 单独取消子运行

- **WHEN** 父 Agent 正等待子 Agent，调用方只取消该子运行
- **THEN** 子请求以取消结束，父请求未被直接取消，父 Agent 收到 `ok:false` 的取消结果

#### Scenario: 父取消不留活动子运行

- **WHEN** 父 Agent 正等待子 Agent，用户取消父轮次或销毁父 Agent
- **THEN** 子 Agent 先收到取消，相关整轮与上下文清理完成后父销毁才结束，活动关系中不再有该子运行

#### Scenario: 模板切换不额外取消子运行

- **WHEN** 父 Agent 正等待子 Agent，用户切换父会话模板
- **THEN** 退役路径不调用子取消或父取消，子调用和父整轮自然结束后旧父实例才完成退役

#### Scenario: 子销毁不破坏父 spill

- **WHEN** 父上下文已产生可读取的 spill 文件，子 Agent 也产生 spill 后结束并销毁子上下文
- **THEN** 子上下文自己的 spill 按既有契约清理，父引用仍可读取且父后续序号不覆盖旧文件

#### Scenario: 清理失败可见

- **WHEN** 子 Agent 已结束但子上下文销毁无法证明排空
- **THEN** 工具返回带 `child_session_id` 的清理错误，不返回表示资源已正常释放的成功结果
