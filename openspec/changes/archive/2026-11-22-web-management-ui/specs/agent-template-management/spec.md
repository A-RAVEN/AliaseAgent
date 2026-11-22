## MODIFIED Requirements

### Requirement: 模板菜单支持列表、添加与修改

应用 SHALL 在会话侧栏提供 `Agents` 入口，展示模板名称、模型与推理强度，并支持添加新模板和修改既有模板。编辑字段 SHALL 包含 provider、模型、推理强度、系统提示词、工具集合与上下文窗口；模板名只在添加时填写，创建后不可修改。provider 选项 SHALL 来自已配置供应商的**全部键名**，工具选项 SHALL 来自统一 `ToolCatalog`，界面 SHALL NOT 显示 provider 密钥。模型字段 SHALL 为可从所选 provider 目录中选择的输入：目录非空时下拉列出目录条目（显示 `display_name`，值为 `id`）并保留手输任意模型名的入口（目录可能陈旧或网关不支持探测）；目录为空或未探测时输入框照旧手填。用户从目录选定某模型后，系统 SHALL 以该目录条目回填三个输入框的默认值：`max_context_tokens` 取 `context_window`（目录标"窗口未知"则留空并显示"目录未提供窗口，请手填（压缩阈值依赖它）"）、`input_modalities` 取 `modalities.input` 与 `text`/`image` 的交集（交集为空回落 `text` 并打日志点名略去了什么，目录原值仍在）、`thinking_effort` 的选项来自目录 `supported_reasoning_levels[].effort` 与既有执行层合法集合（`low`/`medium`/`high`/`xhigh`/`max`）的交集，目录中的 `none` 档位 SHALL 映射为"留空"（既有语义：absent = 不思考），交集之外的目录档位名 MUST NOT 静默消失——编辑器 SHALL 显示一行"目录档位 X 暂不被执行层支持，未列入"；产品不内置自建词表（实测三家网关词表不同），目录标"无已知档位"时保留手填、保存校验仍按既有合法集合执行。回填只发生在编辑器动作时：目录后续刷新 MUST NOT 回改已保存模板的字段。

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

#### Scenario: 删除被会话引用的模板拒绝

- **WHEN** 用户删除被既有会话 agent_type 引用的模板
- **THEN** 拒绝并显示引用会话名单，不产生悬空引用

#### Scenario: general 模板不可删

- **WHEN** 用户尝试删除 general 模板
- **THEN** 可归因拒绝，general 保留

#### Scenario: 删除无引用模板成功

- **WHEN** 用户删除一个未被任何会话引用、且非 general 的模板并确认
- **THEN** 模板从注册表与配置移除，组合根同步，此后该模板名不可用于新会话