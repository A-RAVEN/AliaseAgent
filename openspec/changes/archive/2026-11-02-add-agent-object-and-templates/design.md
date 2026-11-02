## Context

`AgentTypeConfig` 已包含 provider、model、systemPrompt、tools、thinkingEffort、maxContextTokens 等字段，`Session` 也已保存 `agent_type`。但当前执行路径仍在 `lib/main.dart` 固定 `registry.lookup('general')`，模板字段没有形成独立实例；配置只在启动时读取，文档也明确“没有图形化设置界面”。

`add-context-handles` 已让底层工作区、模型请求、浏览器和输出文件按句柄隔离。下一步缺少的不是另一份配置 JSON，而是三层明确分工：**可复用模板、某实例不可变的生效配置、独立运行的 Agent 对象**。

## Goals / Non-Goals

**Goals:**

- 当前聊天由真正的主 Agent 运行：句柄、配置、消息历史、模型—工具循环、取消、计量与销毁都有明确实例归属。
- 新建和恢复会话都按 `Session.agentType` 解析模板；不同实例可使用不同模型、推理强度与工具集合。
- 模板菜单支持列表、添加和修改，保存到现有 `config.json` 并更新模板注册表。
- 当前 Session 可以直接切换 Agent 模板；切换后持久化 `agent_type`，旧 Agent 对象安全退役并保留同 Session 的上下文，新实例读取同一消息历史并真正使用新配置。
- 模板修改不影响已经运行的实例；provider 密钥不进入编辑界面、日志或上下文快照。
- 配置、运行隔离、会话恢复和界面操作都有能失败的测试与同步用户文档。

**Non-Goals:**

- 不实现 `spawn_subagent`、多会话同时发送或进程隔离。
- 不支持删除模板、编辑 provider 密钥或任意实例字段覆盖。
- 不改变 C++ 导出、模型 HTTP 请求格式、消息数据库表结构或既有配置键名。
- 不把 `AgentTypeRegistry` 同时用作运行实例注册表，不把 `Agent` 做成只有名称和配置的包装壳。

## Decisions

### 决策 1 —— 沿用现有模板，新增不可变的实例生效配置

继续用 `AgentTypeConfig` 表示可复用模板，保留 `agent_types` 配置格式。新增 `ResolvedAgentConfig` 与 `AgentConfigResolver`：输入模板和 provider 引用，输出某个实例本次创建时不可变的生效值。

生效配置包含模型、推理模式与强度、系统提示词、工具清单、上下文窗口及既有压缩参数，也包含 `inputModalities`、`commandTimeoutMs`、`commandMaxTimeoutMs` 与 `standingRequirements`，使图片输入、命令超时和不可压缩要求同样不再从模板注册表现读。`thinking_effort` 的合法集合沿用当前执行路径的 `low / medium / high / xhigh / max`：合法值解析为 `adaptive`，缺失或非法值解析为 `disabled`，不再由 `lib/main.dart` 临时推导。

每次创建 Agent 和保存模板都必须校验 `maxContextTokens` 为正整数；配置缺失、为零或为负时创建失败并显示模板名，不得按 0 继续、静默关闭压缩或整段发送。编辑模型时，编辑器要求用户当场确认新模型的窗口值，解析器则对每次创建独立校验，不依赖“上一次模型”这个不存在的输入。压缩阈值仍由窗口乘百分比实时计算，禁止引入绝对 token 阈值。

provider 的 `api_key` 与 `base_url` 不写入 `ResolvedAgentConfig` 的可序列化快照。Agent 创建时单独取得 provider 执行依赖，发送时使用，日志、模板菜单与 `ContextSnapshot` 不展示密钥；真实创建与发送路径必须用带密钥的夹具捕获并断言输出不含密钥，不能只断言模板对象没有该字段。

**备选**：新建一份与 `AgentTypeConfig` 字段重复的 `AgentConfig`。这会产生两个配置真相，不采用。

### 决策 2 —— Agent 是实际执行对象，不是配置包装壳

新增 `Agent` 运行对象，持有：会话句柄、`ResolvedAgentConfig`、独立消息历史、模型—工具循环、取消与请求状态、计量和销毁状态。`lib/main.dart` 中模型执行、工具调用、摘要调用及这些调用产生的数据库写入迁入 Agent；`ChatScreen` 只保留会话列表、输入、展示和删除等界面职责，通过事件或回调呈现 Agent 状态。

Agent 在创建时调用既有 `ensureContext`。销毁前先停止新调用，并等待本 Agent 的整轮 Future（模型循环、工具、`insert` / `touch` / `updateToolCalls` 与后台压缩写库）全部结束，再调用既有 `disposeContext` 排空桥内队列和 C++ 在途调用；不得把 `disposeContext` 单独当成已经覆盖整轮写库。取消、超时和摘要请求都显式使用本实例句柄，不读取 `_currentId` 顶替。恢复会话时按会话 id 加载消息，两个实例的消息历史不共用可变列表。

新增 `AgentFactory` 统一创建实例，`AgentRegistry` 按句柄管理运行实例。现有 `AgentTypeRegistry` 只管理模板，避免“模板”和“运行对象”两个概念再次混用。

**备选**：只在 `ChatScreen` 里把 `general` 换成会话模板名。改动较小，但仍然没有可独立创建和销毁的 Agent，不采用。

### 决策 3 —— 会话选择模板，缺失时明确失败

新建会话仍默认使用 `general`；已有会话继续保存 `agent_type`，不新增数据库列。AgentFactory 创建或恢复实例时读取 `Session.agentType`，解析该名字的模板与 provider，不再固定读取 `general`。

模板不存在或 provider 未定义时，返回包含模板名与 provider 名的可区分错误，不静默退回 `general`。历史会话没有 `agent_type` 时仍按现有缺省 `general` 处理。模板名是持久化引用键，只允许在添加时确定，创建后不可修改；因此正常界面不会产生改名导致的悬空引用或撞名覆盖。

**备选**：缺失模板时退回 `general`。这会让界面显示的会话归属与实际请求不一致，不采用。

### 决策 4 —— 模板编辑产生新配置，运行实例不热更新

模板菜单保存时，`AgentTemplateController` 校验字段、更新 `AppConfig.agentTypes`、调用 `ConfigService.save` 写回完整配置，再更新 `AgentTypeRegistry`。providers、search、spill 以及模板里未开放编辑的**当前受支持字段**必须原样保留，尤其 `input_modalities`、命令超时、`standing_requirements` 与压缩参数；已明确废弃的键仍按既有规则告警并忽略，不承诺原样写回任意无法建模的键。首启或补问 `SetupDialog` 也必须从现有 `AppConfig` 合并必要字段，不得用一份全新缺省配置覆盖用户已有 providers、search、spill 与模板。

每个 Agent 在创建时取得不可变 `ResolvedAgentConfig`，所以修改模板只影响之后创建或恢复的实例；已经运行的实例继续使用原配置。用户文档明确：要让既有会话使用修改后的模板，需要重新创建该实例或重启应用，不能把“保存成功”写成“当前请求已经切换”。

**备选**：保存后立即替换所有实例配置。这会改变在途请求、压缩窗口和取消归属，不采用。

### 决策 5 —— 菜单只开放基础字段，错误在保存前可见

`SessionSidebar` 增加 `Agents` 入口，打开 `AgentTemplateMenu` 显示模板及其模型与推理强度；`AgentTemplateEditor` 同时支持添加与修改。

字段为：模板名（只在添加时填写，修改时只读）、provider 下拉选择、模型文本输入、推理强度下拉选择（禁用及现有合法档位）、系统提示词、工具集合和正整数上下文窗口。provider 选项来自 `AppConfig.providers`，不展示 provider 密钥。

新增 `ToolCatalog` 作为工具定义的唯一只读目录，由现有 `_toolDefs` 初始化与条件注册路径维护，菜单和 Agent 都从该目录读取，不再把 `ChatScreen` 的私有字段或测试专用 `currentToolNames()` 当作注册表。工具选项来自 `ToolCatalog`，未知工具名在读取配置或保存模板时显式报错并列出名字，不得静默过滤。

保存前校验：模板名与模型非空、添加时不重复、provider 必须已定义、推理强度属于现有集合、上下文窗口为正整数、工具名必须已注册。失败时保留用户输入并指出具体字段，不写坏配置。第一版没有删除按钮，也不允许修改模板名，因此不需要处理改名后的会话引用迁移或撞名覆盖。

### 决策 6 —— 工具清单过滤实际请求，首启默认保持现有体验

Agent 按生效配置的工具清单过滤 `ToolCatalog` 中的工具定义，不再无条件发送全部工具。未配置的工具不进入请求；既有配置出现目录中没有的名字时创建失败并列出未知工具，不能悄悄少给。

这会修正当前“配置写了允许清单但执行忽略清单”的行为。首启 `SetupDialog` 生成的默认工具清单同步覆盖当前默认可用的基础工具。对旧版首启已经写出的两项默认清单（`read_file`、`list_dir`），启动时给出可见迁移提示并升级为当前基础工具；用户自定义的其它清单原样保留。兼容判断必须针对旧默认形状并有日志，不给 `general` 留静默绕过规则。

### 决策 7 —— 分层迁移并用行为测试防回归

迁移顺序固定为：

1. 引入 `ResolvedAgentConfig`、解析器与模板保存路径，先用单元测试固定模型、推理强度、工具与上下文窗口规则。
2. 引入 Agent、工厂和实例注册表，把当前模型—工具循环与数据库写入迁出 `ChatScreen`；用现有集成测试和新增双实例测试证明消息、配置、取消与销毁隔离。
3. 接通新建和恢复会话的模板选择，再接入模板菜单；用真实 `SidecarBridge` 与本地 SSE 检查实际请求中的模型和推理配置，界面测试覆盖添加、修改与失败提示。
4. 更新用户文档后跑静态检查、同步 DLL 和完整 Dart 测试。每一步保持可编译，禁止先写实现后补任务或文档。

### 决策 8 —— 占用环读取实例窗口，不追随模板热改

`ContextSnapshot` 继续记录本次实际请求的窗口，占用环与该窗口所属的 Agent 实例生效配置保持一致，不在绘制时重新读取 `agent_types.<名字>.max_context_tokens`。模板窗口修改只影响之后创建或恢复的实例，所以旧实例的环不会突然换分母；非法窗口按决策 1 在创建时失败，不再以“窗口为 0 就不渲染”掩盖配置错误。同步 MODIFIED 主规范 `context-occupancy-ring` 的「环的几何」与「不渲染环的两种情形」，避免一份规范要求实例快照、另一份仍读配置文件。

### 决策 9 —— 返工补齐 Session 中的 Agent 切换

当前实现只提供模板管理，没有给用户修改 `Session.agentType` 的入口；而且 `AgentFactory.ensure` 在注册表已有实例时直接复用，仅改数据库字段会继续使用旧模板。因此本次返工不能只加一个下拉框，必须把界面、持久化和运行实例替换连成一条路径。

在 `lib/main.dart` 当前会话工具栏加入 `SessionAgentSwitcher`，列出模板注册表中的名字并标记当前 `Session.agentType`。新增 `AgentSessionController.switchTemplate` 统一处理切换，调用时显式传入 `_callbacksFor(session.id)`，新实例不能使用默认空回调。`AgentFactory` 提供与创建路径共用解析逻辑的 `validateCandidate`，避免预检和真正创建各写一套规则。工具目录尚未就绪、正在切换或没有当前会话时只禁用选择控件；没有当前会话时直接发送仍按既有行为自动创建 `general` Session，不得切断首条消息或删光会话后的发送路径。

切换顺序固定为：①候选名与当前相同则无需操作；②预检候选模板、provider、正整数窗口和工具目录，预检失败时旧实例、数据库与界面选择均不变；③登记该 Session 的切换 Future，在 `_submitInput` 与 `_sendMessage` 两层拒绝新发送，重复切换与“删除进行中切换”显式拒绝，“切换进行中删除”等待切换结束再重新读取并删除 Session；④退役旧 Agent 对象，随后持久化并重新读取更新后的 Session；⑤用更新后的 Session 与对应界面回调立即创建并注册新实例，重新加载同一消息历史。切换成功后，后续请求使用新实例配置，其它 Session 的实例和消息不受影响。

退役不调用 `disposeContext`：新增独立的退役状态阻止 `Agent.send` 等新调用，但不提前设置会中断当前轮的 `_disposed` / `_cancelledEpoch`，也不调用 `cancelRequest`；旧实例的模型循环、工具、消息写库与后台压缩写库自然结束后，才标记旧 Agent 对象释放并从运行注册表移除。新实例沿用同一 Session 句柄，`ensureContext` 返回 `created:false`，所以工作区、浏览器上下文、工具输出溢出目录及其序号都继续保留。只有删除 Session、关闭应用等真正销毁上下文的路径才调用 `disposeContext`。这样切换不会让历史 `read_spill` 引用失效，也不会让新输出覆盖旧引用。

`SessionRepository.updateAgentType` 必须确认实际更新了一行；未找到 Session 时显式失败。持久化后重新读取 Session 再创建实例，防止为已删除或仍是旧模板名的 Session 注册新 Agent。普通 `AgentFactory.ensure` 发现已注册实例的模板名与 Session 不一致、或实例正在退役时也必须显式报错，正常切换只能走上述专用路径。

预检之后的退役、写库或创建失败必须显示具体阶段与候选模板名，不得宣称切换成功或静默退回 `general`。界面在失败后重新读取 Session，使选择框与数据库实际保存的 `agent_type` 一致；若新实例尚未创建成功，必须继续显示错误，不能只靠选择框文字假装它已经运行。

切换保留同一 Session 的消息、工具记录、摘要数据、工作区和工具输出溢出文件，不删除或重建会话。由于旧 `ContextSnapshot` 属于旧实例，切换时清除当前占用环快照，直到新实例完成下一次真实请求；聊天记录本身继续展示。模板编辑仍不热更新运行实例，显式切换则通过“退役旧 Agent 对象并创建新实例”生效，两者不矛盾。

**备选一**：只修改 `Session.agentType`，让下次发送自动复用实例。现有 `ensure` 会返回旧 Agent，界面显示与实际模型会不一致，不采用。

**备选二**：切换时完整调用 `disposeContext` 后重建同名上下文。`sidecar/src/context_api.cpp` 的销毁路径会删除该 Session 的工具输出溢出目录，历史引用因此失效，不采用。

## Risks / Trade-offs

- **`ChatScreen` 执行逻辑迁移面较大，容易漏掉摘要或工具后的写库** → 以现有集成测试为行为对照，新增消息顺序、摘要句柄、取消和销毁测试；只有整轮行为一致才进入模板菜单阶段。
- **模板编辑后用户误以为当前实例已切换** → 采用创建时快照，界面和文档明确生效时机，不提供运行中热更新。
- **工具过滤改变既有实际行为** → 同步修正首启默认清单并用请求级测试列出实际发送的工具，禁止为 `general` 留隐式例外。
- **provider 密钥经新对象或快照泄漏** → 密钥只作为创建时的私有执行依赖，菜单不显示，序列化与日志断言不包含密钥。
- **历史会话引用不存在模板** → 显示模板名并停止创建，不静默换模板；第一版既不支持删除，也不允许修改模板名，因此正常界面不会产生改名或删除造成的悬空引用。
- **首启补问覆盖既有配置** → `SetupDialog` 必须合并到现有 `AppConfig`，用包含其它 provider、search、spill 与自定义模板的用例证明不会清空。
- **只换界面文字或数据库字段，实际仍由旧实例发送** → 用同一 Session 在两个模板之间往返切换并核对真实请求模型、推理配置与工具；另测退役顺序、界面回调、历史与溢出文件保留、失败一致性、切换/发送/删除互斥和其它 Session 不受影响。

## Migration Plan

先加配置解析和测试，再迁移执行对象，然后接通模板菜单。每一步都运行该层能失败的测试，最后更新文档并跑全量。若迁移中发现 Agent 不能独立拥有某段执行状态，先在本 change 的 design/spec/tasks 中修正归属，不用 `ChatScreen` 的可变全局状态临时顶替。

## Open Questions

- 模板列表后续是否需要复制模板或删除模板：待第一版验证引用与销毁规则后另开 change。
- 实例级覆盖是否必要：第一版只允许选择模板；若真实使用证明需要，再设计覆盖字段、持久化与继承顺序。
