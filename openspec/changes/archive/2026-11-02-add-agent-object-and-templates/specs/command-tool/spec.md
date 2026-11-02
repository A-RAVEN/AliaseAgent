## MODIFIED Requirements

### Requirement: 四个配置项与缺省值，每次调用随请求带到执行侧

命令工具 SHALL 只由**三个**配置值决定交付形状：缺省超时毫秒数 `command_timeout_ms`（缺省 120000）、超时上限 `command_max_timeout_ms`（缺省 600000），以及头尾预览长度 `spill.preview_chars`（顶层 `spill` 块下，缺省 1000，见 `tool-output-spill` 能力）。

> **2026-10-25 修改**：本条由 `spill-large-tool-output` 改写。标题沿用原句是因为解析器要求 MODIFIED 的标题与主规范**逐字一致**；正文已从"四个配置项"变成三个 —— 两个输出上限键废弃，改由 `spill.preview_chars` 一项决定头尾预览。

- `command_max_output_chars` 与 `command_output_full_chars` SHALL 视为**已废弃**：读到它们 SHALL 打一行告警并忽略，行为 SHALL NOT 受其影响（它们原本描述的是"只留尾部 + 写系统临时文件"，那条交付方式已被 `tool-output-spill` 取代）。
- 这三个值 SHALL 由发起调用的 Agent 的实例生效配置在每次调用时随请求一起交给执行侧（执行侧不读配置文件，也不读取随后可能修改的模板）；请求里缺失或非法的字段 SHALL 在两侧得到同一套缺省值（`preview_chars` 为非正值时回落到 1000）。
- 命令工具是否可用 SHALL NOT 依赖搜索服务或浏览器栈；当 Agent 的实例生效配置包含 `run_command` 时，工具 SHALL 出现在该 Agent 的请求工具定义里，模板明确未包含时 SHALL 不出现在该 Agent 的请求里。

#### Scenario: 没有配置项时用缺省值

- **WHEN** 配置里既没有 `command_timeout_ms` / `command_max_timeout_ms`，也没有 `spill.preview_chars`
- **THEN** 工具 SHALL 用 120000 / 600000 / 1000 三个缺省值工作

#### Scenario: 非法值回落到缺省值

- **WHEN** 某个键写成零、负数或文字（例如把 `spill.preview_chars` 配成 0）
- **THEN** 非法值 SHALL 回落到各自的缺省值（`preview_chars` 回落到 1000），工具 SHALL 仍能执行命令

#### Scenario: 配置的值真的生效（`preview_chars` 改小 → 预览跟着变短）

- **WHEN** 把 `spill.preview_chars` 配成 4000 再执行一条输出明显超过它的命令
- **THEN** 返回的 `head` / `tail` SHALL 各为 4000 字符那一档，省略量随之变小 —— 差别证明这个值真的走到了执行侧，而不是只被解析出来又丢掉
- **AND** 这条场景 **不** 要求整段结果仍不超过 8000 字符：头尾各 4000 已经正好 8000，撞上通用截断是预期行为；此时 SHALL 只要求 spill 引用仍留在结果里（见 `输出有界、只保留尾部、截断可见` 那条的说明）

#### Scenario: 两个废弃键不再影响行为

- **WHEN** 用户在 `agent_types.general` 段里仍写着 `command_max_output_chars` / `command_output_full_chars`
- **THEN** 解析 SHALL 给出各自的缺省值并打一行废弃告警，实际交付形状 SHALL 与不写这两个键时完全相同

#### Scenario: 超时上限参与计算（单测层判定，不靠真等十分钟）

- **WHEN** 分别给一个小于上限的调用超时与一个大于上限的调用超时
- **THEN** 生效的超时 SHALL 分别等于前者与上限值 —— 这条在单测层断言"生效值怎么算出来的"，SHALL NOT 以"真的等到超时"作为判据（缺省上限是 10 分钟，那样跑不起）

#### Scenario: 模板未允许时不发送

- **WHEN** 一个 Agent 的实例生效配置不含 `run_command`
- **THEN** 该 Agent 的请求工具定义不包含 `run_command`，但其它包含它的 Agent 仍可使用该工具

#### Scenario: 模板允许时不依赖搜索或浏览器

- **WHEN** 搜索服务与浏览器栈不可用，而 Agent 的实例生效配置包含 `run_command`
- **THEN** 该 Agent 的请求工具定义仍包含 `run_command`
