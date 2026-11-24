# agent-template-management Specification

## Purpose

规定 Agent 模板菜单的行为：在会话侧栏展示模板列表，支持添加与修改模板的 provider、模型、推理强度、系统提示词、工具集合、上下文窗口与**头像（可选上传覆盖，缺省画身份图案）**，保存前校验字段并完整写回 `~/.aliasagent/config.json`。模板修改只对之后创建或恢复的 Agent 实例生效（头像除外：它不进模型请求，保存后界面重拉即更新，且新增模板不继承既有头像）；模板删除自 `web-management-ui` 起开放（带引用守卫：被既有会话 `agent_type` 引用或 `general` 不可删），修改模板名与实例字段覆盖入口仍不提供，避免既有会话的 `agent_type` 引用悬空与撞名覆盖。

## Requirements

### Requirement: 模板菜单支持列表、添加与修改

应用 SHALL 在会话侧栏提供 `Agents` 入口，展示模板名称、模型与推理强度，并支持添加新模板和修改既有模板。编辑字段 SHALL 包含 provider、模型、推理强度、系统提示词、工具集合、上下文窗口**与头像**；模板名只在添加时填写，创建后不可修改。provider 选项 SHALL 来自已配置供应商的**全部键名**，工具选项 SHALL 来自统一 `ToolCatalog`，界面 SHALL NOT 显示 provider 密钥。模型字段 SHALL 为可从所选 provider 目录中选择的输入：目录非空时下拉列出目录条目（显示 `display_name`，值为 `id`）并保留手输任意模型名的入口（目录可能陈旧或网关不支持探测）；目录为空或未探测时输入框照旧手填。用户从目录选定某模型后，系统 SHALL 以该目录条目回填三个输入框的默认值：`max_context_tokens` 取 `context_window`（目录标"窗口未知"则留空并显示"目录未提供窗口，请手填（压缩阈值依赖它）"）、`input_modalities` 取 `modalities.input` 与 `text`/`image` 的交集（交集为空回落 `text` 并打日志点名略去了什么，目录原值仍在）、`thinking_effort` 的选项来自目录 `supported_reasoning_levels[].effort` 与既有执行层合法集合（`low`/`medium`/`high`/`xhigh`/`max`）的交集，目录中的 `none` 档位 SHALL 映射为"留空"（既有语义：absent = 不思考），交集之外的目录档位名 MUST NOT 静默消失——编辑器 SHALL 显示一行"目录档位 X 暂不被执行层支持，未列入"；产品不内置自建词表（实测三家网关词表不同），目录标"无已知档位"时保留手填、保存校验仍按既有合法集合执行。回填只发生在编辑器动作时：目录后续刷新 MUST NOT 回改已保存模板的字段。

**模板头像（本变更新增）**：模板 SHALL 有一个可选头像——上传了就显示上传图，没上传就显示由实体 id 生成的身份图案（默认图案的生成规则见 `web-chat-screen` 与 `agent-group-chat` 的对应要求，本能力只规定"头像字段怎么存、怎么校验、怎么随模板保存"）。头像 SHALL 以配置键 `avatar_path` 存在 `agent_types.<模板名>` 下，值是一个图片文件的绝对路径；图片本身 SHALL 经既有 `attachment.upload` 上传（同一套大小上限与文件头魔数判定），本能力 MUST NOT 另建上传通道或第二个头像目录。编辑器 SHALL 支持选择图片、预览当前头像、清除头像（清除 = 写回空值并回到身份图案）。头像字段在 `template.save` 参数里的语义 SHALL 是四态，MUST NOT 与"配置读取"混用：**省略或显式 `null` = 不改**（既有模板沿用原值）；**`''` = 清除**；**非空字符串 = 设为该路径**；**其它类型（数字/对象/数组）= `-32602` 拒绝**（写明字段名）。**新增模板**时省略头像 SHALL 得到"没有头像"，MUST NOT 沿用 `general` 或任何既有模板的头像——`AgentTemplateController` 的"新模板从 base 继承缺省字段"路径必须把头像排除在外。旧模板没有这个键 SHALL 正常加载并按身份图案显示，MUST NOT 让模板加载失败。头像缺失或文件已被移走时界面 SHALL 回落身份图案，MUST NOT 阻断模板列表、成员卡片或消息渲染。

**模板删除（web-management-ui 开放）**：应用 SHALL 提供删除模板入口（web 模板页 + `template.delete` RPC，新增 `AgentTypeRegistry.remove`）。删除 SHALL 带引用守卫：**被既有会话 `agent_type` 引用的模板 SHALL 拒删**并显示引用会话名单（防悬空引用）；**`general` 模板 MUST NOT 可删**（可归因拒绝，SessionRepository.create 默认 general）；删除 SHALL 写回 config 并触发组合根配置同步。模板名创建后仍不可修改；本能力开放的是模板删除（带守卫），Provider 的删除与改名见 provider-model-discovery。

#### Scenario: 打开模板列表

- **WHEN** 用户点击会话侧栏的 `Agents`
- **THEN** 界面列出每个模板的名称、模型与推理强度，并提供添加和修改入口

#### Scenario: 添加模板

- **WHEN** 用户填写合法的新模板字段并保存
- **THEN** 新模板出现在列表和模板注册表中，可用于之后创建或恢复的 Agent

#### Scenario: 修改模板

- **WHEN** 用户修改一个既有模板的模型、推理强度、系统提示词、工具或上下文窗口并保存
- **THEN** 列表显示修改后的值，配置文件同步更新，且未开放编辑的既有字段保持不变

#### Scenario: provider 下拉来自全部已配置供应商

- **WHEN** 配置里存在两个 Provider，用户打开模板编辑器
- **THEN** provider 下拉同时列出两个名字，选中其一后模型下拉切换到该 Provider 的目录

#### Scenario: 从目录选模型触发回填

- **WHEN** 用户在非空目录中选定 `deepseek/deepseek-flash`（目录窗口 1048576、输入模态 text+image）
- **THEN** 上下文窗口输入框预填 1048576、模态勾选 text 与 image、推理强度下拉选项变为该条目 `supported_reasoning_levels` 的档位；用户改动后保存以用户输入为准

#### Scenario: 目录陈旧不影响手输

- **WHEN** 网关已下架某模型而本地目录未刷新，用户手输该模型名并保存
- **THEN** 保存成功（模型字段不因"不在目录内"被拒绝），界面可显示"不在最近一次目录中"的中性提示但 MUST NOT 阻断

#### Scenario: 模板头像上传后写回并可再读出

- **WHEN** 用户在模板编辑器为模板「甲」选择一张图片并保存
- **THEN** 保存走 `attachment.upload` 拿到路径、`template.save` 的 payload 带该 `avatarPath`，重新打开编辑器时预览是这张图，`agent_types.甲.avatar_path` 出现在 `~/.aliasagent/config.json` 里

#### Scenario: 清除模板头像回到身份图案

- **WHEN** 用户清除一个已有头像的模板的头像并保存
- **THEN** 写回的配置里该模板不再带 `avatar_path`（或为空串被规范成缺键），该模板的成员与会话显示身份图案

#### Scenario: 没有头像字段的旧模板正常加载

- **WHEN** 读取一份由旧版本写出的、任何模板都没有 `avatar_path` 的配置
- **THEN** 全部模板正常加载，编辑器的头像预览是身份图案，界面上任何位置都不报错

#### Scenario: 删除被会话引用的模板拒绝

- **WHEN** 用户删除被既有会话 agent_type 引用的模板
- **THEN** 拒绝并显示引用会话名单，不产生悬空引用

#### Scenario: general 模板不可删

- **WHEN** 用户尝试删除 general 模板
- **THEN** 可归因拒绝，general 保留

#### Scenario: 删除无引用模板成功

- **WHEN** 用户删除一个未被任何会话引用、且非 general 的模板并确认
- **THEN** 模板从注册表与配置移除，组合根同步，此后该模板名不可用于新会话

### Requirement: 模板字段在保存前校验

保存模板时，系统 SHALL 校验模板名非空且添加时不重复、provider 已定义、模型非空、推理强度属于既有合法集合、上下文窗口为正整数、工具名已注册；`input_modalities` 的校验仍按既有规范只放行 `text`/`image`（目录里的 `video` 等取值 MUST NOT 因回填进入模板字段）。**头像 `avatarPath` 的校验**：省略或 `null` 合法（= 不改）、`''` 合法（= 清除）、其它非字符串类型拒绝；非空时 SHALL 是一个落在产品附件目录（`attachmentsDir`）内、且**确实是文件**的路径——判定 SHALL 复用 `attachment.read` 的同一套写法（`p.normalize(p.absolute(...))` 后比较是否在目录内，即 `p.isWithin` 语义；**MUST NOT 用字符串前缀比较**，否则 `…\att` 会误容 `…\attacker`），并用"是文件而不是目录"的判定挡住把目录当头像；越出附件目录、文件不存在、或指向目录，SHALL 被拒绝并指出是头像字段与出问题的路径，MUST NOT 静默清空既有头像、也 MUST NOT 把任意路径写进配置。校验失败 SHALL 指出具体字段并保留用户输入，不得写入无效配置或清空其它配置段。

#### Scenario: 空模板名或空模型

- **WHEN** 用户把模板名或模型留空并尝试保存
- **THEN** 保存被拒绝并指出具体空字段，不创建或修改任何配置

#### Scenario: 未知工具名

- **WHEN** 待保存模板含 `ToolCatalog` 中不存在的工具名
- **THEN** 保存被拒绝并列出未知工具，不得静默删除后继续

#### Scenario: 重复模板名

- **WHEN** 用户添加一个与既有模板同名的模板
- **THEN** 保存被拒绝并指出模板名重复，既有同名模板不变

#### Scenario: 未定义 provider

- **WHEN** 一个待保存模板引用了 `providers` 中不存在的 provider
- **THEN** 保存被拒绝并指出 provider 未定义，不创建该模板

#### Scenario: 非法上下文窗口

- **WHEN** 用户输入零、负数或非整数的上下文窗口
- **THEN** 保存被拒绝并指出必须填写正整数，用户此前输入的其它字段仍保留

#### Scenario: 目录模态含 video 时模板仍只收 text/image

- **WHEN** 用户从含 `modalities.input = [text,image,video]` 的目录条目回填后保存
- **THEN** 写回的 `input_modalities` 至多为 `text`/`image` 的子集，不含 `video`，日志有一行点名略去的取值

#### Scenario: 头像路径越出附件目录或文件不存在

- **WHEN** 保存请求带的 `avatarPath` 指向附件目录之外的路径，或指向附件目录内一个已被删除的文件
- **THEN** 保存被拒绝、错误文本点名头像字段与出问题的路径，配置不变，既有头像保持原值

#### Scenario: 头像路径指向目录

- **WHEN** 保存请求带的 `avatarPath` 指向附件目录内的一个子目录
- **THEN** 保存被拒绝并点名该路径不是文件，配置不变

#### Scenario: 头像参数类型错拒绝

- **WHEN** `template.save` 的 `avatarPath` 是数字、对象或数组
- **THEN** 返回 `-32602` 并点名 `avatarPath` 字段，模板与配置都不改动

#### Scenario: 省略或 null 不改既有头像

- **WHEN** 修改一个已有头像的模板，请求里省略 `avatarPath` 或显式传 `null`
- **THEN** 写回后该模板的 `avatar_path` 保持原值，MUST NOT 被清空

#### Scenario: 新增模板不继承既有头像

- **WHEN** 用户新增一个模板并保存，请求里省略 `avatarPath`
- **THEN** 新模板没有 `avatar_path`（即使 `general` 或别的模板有头像也不沿用），模板页预览是身份图案

### Requirement: 模板保存保持配置完整并明确生效时机

模板保存 SHALL 写回完整的 `~/.aliasagent/config.json` 并更新内存模板注册表，providers、search、spill 和模板中未开放编辑的当前受支持字段 SHALL 原样保留，包括图片输入模态、命令超时、不可压缩要求与压缩参数；已明确废弃的键仍按既有规则告警并忽略，不承诺写回任意无法建模的键。首启或补问配置 SHALL 合并到现有配置，不得用全新缺省配置覆盖这些段。**生效时机分两类**：推理强度（`thinking_effort`）的修改 SHALL 对已在运行的 Agent 从**下一消息**生效（每轮装配时按最新模板与目录重新解析思考模式）；其余字段（上下文窗口、工具清单、模型、系统提示词等）修改 SHALL 只作用于之后创建或恢复的 Agent，已运行实例继续使用创建时的生效配置。界面与文档 SHALL 明确这一生效时机。（`general.max_context_tokens` 缺失不再是补问触发条件——缺席是合法状态、窗口取目录值，见 `agent-config` 的「生效上下文窗口的解析顺序」。）

#### Scenario: 保存后其它配置不丢

- **WHEN** 原配置包含多个 provider、搜索配置、spill 配置和一个带图片输入模态、命令超时、不可压缩要求与压缩参数的模板，用户修改该模板并保存
- **THEN** 重新读取配置文件后，上述其它配置和模板内未编辑字段均保持原值，只有被编辑字段发生变化

#### Scenario: 首启补问不清空已有配置

- **WHEN** 已有配置包含自定义模板、多个 provider、search 与 spill，而缺密钥（或 Provider 配置不完整）触发补问
- **THEN** 补问保存只合并必要字段，所有既有模板、provider、search 与 spill 均可读回，不得整份覆盖为缺省配置

#### Scenario: 推理强度修改下一轮装配生效

- **WHEN** 一个 Agent 正在运行，用户修改并保存其来源模板的 `thinking_effort`（如从 low 改为 high）
- **THEN** 该 Agent 从**下一条消息起的装配**使用新思考模式；若保存发生在某轮工具循环进行中，该轮已发出的请求保持原参数、该轮后续模型请求仍用旧档；其余字段（窗口、工具、模型、系统提示词）的修改对该实例仍然不生效

#### Scenario: 非推理字段仍创建时生效

- **WHEN** 一个 Agent 正在运行，用户修改并保存其来源模板的窗口或工具清单
- **THEN** 当前 Agent 的请求参数不变，之后创建或恢复的 Agent 才读到修改后的模板

### Requirement: 旧默认工具清单迁移必须可见

首启默认工具清单 SHALL 覆盖当前基础工具。对旧版首启已经写出的 `read_file`、`list_dir` 两项默认清单，系统 SHALL 给出可见迁移提示并升级为当前基础工具；用户自定义的其它工具清单 SHALL 原样保留。未知工具名不得借迁移之名静默删除。

#### Scenario: 旧默认清单升级

- **WHEN** 读取到由旧版首启生成的两项默认工具清单
- **THEN** 用户能看到迁移提示，升级后的清单包含当前基础工具，而不是静默只剩文件读取与目录工具

#### Scenario: 自定义清单不迁移

- **WHEN** 一个模板具有用户自行收窄或扩展的工具清单
- **THEN** 该清单不因默认迁移被改写，未知名字仍按显式错误处理

### Requirement: 首启默认包含子 Agent 工具且既有模板选择不被覆盖

当前基础工具清单 SHALL 包含 `spawn_subagent`，新首启配置 SHALL 使用该当前清单；旧版两项首启默认清单仍 SHALL 按既有可见迁移规则升级到当前清单。其它既有模板 SHALL NOT 因本 change 被自动添加 `spawn_subagent`，包括工具清单恰好等于上一版完整基础工具默认形状的模板。

上一版十项默认形状与“用户从当前清单主动移除 `spawn_subagent`”在磁盘上相同，系统 SHALL NOT 仅凭该形状推断用户希望自动升级。用户 SHALL 能在模板编辑器中显式添加或移除该工具；保存并再次加载后 SHALL 保持用户选择，已运行实例继续遵循创建时快照。任何迁移 SHALL NOT 静默删除未知工具、修改 provider 或模型字段，也 SHALL NOT 在提示或日志中暴露 provider 密钥。

#### Scenario: 既有十项模板不自动添加

- **WHEN** 读取到工具清单恰好等于上一版完整基础工具默认形状的既有模板
- **THEN** 加载后清单保持不含 `spawn_subagent`，使用该模板的 Agent 请求也不含其定义，其它配置段不变

#### Scenario: 用户删除后再次加载仍保持删除

- **WHEN** 用户从包含当前基础工具的模板中显式移除 `spawn_subagent`，保存并重新加载配置
- **THEN** 清单仍不含该工具，不因它与上一版默认形状相同而被自动加回

#### Scenario: 用户显式添加后新实例生效

- **WHEN** 用户在模板编辑器中添加 `spawn_subagent` 并保存，随后创建新的 Agent
- **THEN** 完整配置写回后包含该工具，新实例的模型请求包含其定义，已运行实例不热更新

#### Scenario: 旧两项首启清单仍迁移

- **WHEN** 读取到仅含 `read_file` 与 `list_dir` 的旧首启默认清单
- **THEN** 既有可见迁移升级到包含 `spawn_subagent` 的当前基础清单，未知工具和自定义清单仍按原规则处理

### Requirement: 目录中不存在的模型名可见提示

模板编辑器的模型行 SHALL 把"已保存的模型名不在该 Provider 当前目录里"变成可见状态，且 SHALL NOT 自动改写用户配置（「目录刷新不回改已保存模板」的既有条文不变）。提示 SHALL 按**编辑器打开那一刻的目录快照**计算（产品没有实时通道：关闭编辑器 → 在 Providers 页手动刷新 → 重开编辑器时按新目录重算）。两种情形 SHALL 用可区分的文案与视觉权重：该 Provider 有 `discovered_at`（已探测）但目录不含该 id（警示，意为"当前目录没有这个模型，发送会失败"）；从未探测（中性信息色，意为"还没有目录可查，不等于不存在"）——判定 SHALL 以 `discovered_at` 为准，SHALL NOT 用"目录是否为空"代替。手动刷新目录后提示 SHALL 按最新目录即时更新（重开编辑器时）。

#### Scenario: 已探测且不含该模型
- **WHEN** 模板的 Provider 已探测成功，保存的模型名不在目录中（如目录更新后旧模型被下架）
- **THEN** 模型行出现警示文案点名该模型名，配置不被改写

#### Scenario: 尚未探测
- **WHEN** 该 Provider 从未探测过（无目录）
- **THEN** 模型行出现中性文案说明"目录未探测"，不声称模型不存在

#### Scenario: 刷新后提示随目录更新
- **WHEN** 警示出现之后用户手动刷新目录，且新目录包含了该模型
- **THEN** 警示消失，不留残留
