## ADDED Requirements

### Requirement: 系统提示词注入当前工作区

Agent SHALL 在一轮开始时读取**该实例上下文当前保存的工作区**（`get_workspace`），并把工作路径注入该轮系统提示词的一个稳定段落（标题与正文取自代码常量：`kWorkspacePromptHeading` / `workspacePromptSection(path)`）。段落 SHALL 说明：这是工作路径；相对路径以它为根；文件工具越出该目录会被拒绝；`run_command` 的缺省工作目录是它，且**命令本身没有沙箱、以用户自己的权限执行、运行后不可撤销**；用户可能切换工作路径，每轮以此处给出的值为准。

同一轮内的所有模型请求 SHALL 使用同一个工作区值（在途轮不中途换根）；用户在轮间切换工作路径后，**下一轮**装配 SHALL 使用新值。该段 SHALL 是**追加**：与既有动态段（`guard.inject()` / 技能段 / 日期段）同一口径，在实例生效配置的系统提示词之后追加；MUST NOT 替换模板系统提示词、组角色说明、成员身份锚或反应提示词，MUST NOT 因此从模板或全局配置重新读取系统提示词；摘要请求的系统文本 SHALL NOT 含该段（摘要不是 Agent 轮）。注入内容 MUST NOT 把工作区描述成沙箱或安全边界。

读不到工作区（`get_workspace` 返回 `ok:false`）或读到空串时，系统提示 SHALL 写明「当前没有可用的工作区（原因）」并以 `workspaceUnavailablePromptSection` 常量给出该形态，MUST NOT 省略整段、MUST NOT 把某个目录伪装成实际工作区；同时 SHALL 留一行日志点名句柄与原因，该轮 SHALL 继续完成（不因读取失败丢弃整轮）。段落内容 SHALL 来自代码常量并包含实际路径的原文，使「请求实际发出的系统提示词」可被逐字断言。**组的分界**：组成员轮在装配前先按 `agent-group-chat` 的「成员轮开始对齐」把成员上下文对齐到组工作区，组工作区读不到 / 为空时由那一步以 `workspace_unavailable` 拒绝（不会进入本条的「不可用段」分支）；本条覆盖单聊，以及对齐完成后成员自身上下文仍读不到的场景。

#### Scenario: 单聊整轮系统提示词含工作路径

- **WHEN** 一个单聊会话的工作区是 `<临时目录>`，用户发一条消息并捕获实际发给模型的 `systemPrompt`
- **THEN** 其中包含 `kWorkspacePromptHeading` 与 `workspacePromptSection(<该目录的实际生效值>)` 的全文（路径逐字出现）；模板提示词仍在（是追加，不是替换）

#### Scenario: 组成员整轮继承组工作路径

- **WHEN** 组的共享工作区是 `<临时目录>`，用户点名一个成员发言并捕获该成员这一轮实际发出的 `systemPrompt`
- **THEN** 其中包含该目录与工作区段标题，且成员身份锚、组角色说明、反应提示词同时仍在

#### Scenario: 切换在下一轮生效

- **WHEN** 同一会话先以目录 A 发一轮（捕获第一轮请求），切换到目录 B 后再发一轮（捕获第二轮请求）
- **THEN** 第一轮请求含 A 且不含 B，第二轮请求含 B 且不含 A；单轮内的多个模型请求（工具循环）工作区值不变

#### Scenario: 读不到工作区时写明不可用

- **WHEN** `get_workspace` 对该实例返回 `ok:false`（或成功但工作区为空串），一轮被装配
- **THEN** 实际请求的 `systemPrompt` 含「当前没有可用的工作区」与原因文本（`workspaceUnavailablePromptSection` 全文），MUST NOT 含任何伪造的目录；该轮仍正常完成（有回复 / 可归因的模型结果），并有一行日志点名句柄与原因

#### Scenario: 快照与成员视图可观察该段

- **WHEN** 一轮完成后读取 `ContextSnapshot.systemPrompt`（或组的 `group.view` 返回的成员快照 `system.systemPrompt`）
- **THEN** 其中含工作区段与路径，界面「真实上下文」不必另开通道就能核对模型看到的工作目录

#### Scenario: 摘要请求不含工作区段

- **WHEN** 一轮触发摘要（折叠）请求，检查摘要请求的系统文本
- **THEN** 其中不含 `kWorkspacePromptHeading` 或 `workspacePromptSection` 的内容（工作区只属于 Agent 轮）

#### Scenario: 不承诺沙箱

- **WHEN** 检查工作区段常量全文与一轮实际发出的系统提示词
- **THEN** 其中写明 `run_command` 没有沙箱、以用户权限执行、不可撤销；MUST NOT 出现「沙箱」「只能访问该目录」这类与实际权限不符的承诺
