## MODIFIED Requirements

### Requirement: 输出有界、只保留尾部、截断可见

每条流的**完整输出** SHALL 先写入 spill 文件（位置见 `tool-output-spill` 能力：`~/.aliasagent/spill/<会话>/<6 位序号>-<流>.txt`，**每条流一个文件**，原子写），写成功之后才决定返回什么。

> **2026-10-25 修改**：本条由 `spill-large-tool-output` 改写 —— 完整输出不再写系统临时目录，内存里保留的也不再只是尾部。以下是改写后的完整条文。

- 全文长度 ≤ `preview_chars × 2` ⇒ 返回里 SHALL 内联全文；
- 全文长度 > `preview_chars × 2` ⇒ 返回里 SHALL 内联**头部前 `preview_chars` 个字符**与**尾部后 `preview_chars` 个字符**，中间段省略，并 SHALL 给出 spill 引用、总字节数、省略字节数。

`preview_chars` 默认 1000（用户 2026-10-25 决定），配置键为 `spill.preview_chars`。

**截断 SHALL NOT 静默发生**：返回里的截断字段 SHALL 标明哪条流被省略、原有字节数、省略了多少、以及引用。

渲染给模型的整段结果 SHALL 不超过既有阈值（`kToolResultElisionThreshold`，8000 字符）：信封本身要足够短，引用与省略量这两项 SHALL 落在结果的头尾可见区域内，SHALL NOT 因通用截断被掐掉中间。

**这条 8000 字符是"通用截断的触发阈值"，不是"任何配置下都装得下"的承诺**：`preview_chars` 配到 4000 时，头 + 尾就已经是 8000 字符，整段结果必然超过阈值、必然被通用截断（初稿把这两条写成"既不超过 8000、又要头尾各 4000"，自相矛盾）。所以要求落在**引用与省略量必须出现在被保留下来的那一侧**（代码里它们固定在正文最后一行），而不是"整段不许超 8000"。

#### Scenario: 超长输出头尾都保留并标出省略

- **WHEN** 一条命令写出的标准输出明显超过预览阈值，且开头标记与结尾标记可以区分
- **THEN** 返回的 `stdout` SHALL 同时含开头标记与结尾标记、SHALL NOT 含中间部分，截断字段 SHALL 给出原有字节数、省略字节数与 spill 引用

#### Scenario: 未超限时也落盘但内联全文

- **WHEN** 命令的输出不超过预览阈值
- **THEN** 截断字段 SHALL 为假、返回里 SHALL 内联全文，且该次调用 SHALL 仍然在 spill 目录里留下一个文件（写盘不因"输出小"而跳过）；系统临时目录下 SHALL NOT 新增文件

#### Scenario: 整段结果不超过既有阈值，引用一定看得见

- **WHEN** 一条命令同时写出远超预览阈值的标准输出与标准错误
- **THEN** 渲染给模型的整段结果 SHALL 不超过 `kToolResultElisionThreshold`，且 spill 引用与省略量 SHALL 留在结果里（不得因超长而被通用截断掐掉中间）

#### Scenario: spill 写不进去时如实说明

- **WHEN** spill 目录不可写、而命令输出超过预览阈值
- **THEN** 返回 SHALL 是 `ok:false` 并写明写盘失败原因，SHALL NOT 只返回尾部一段内容冒充完整结果

#### Scenario: 旧的两个配置键被废弃

- **WHEN** 用户的配置里仍写着 `command_max_output_chars` 或 `command_output_full_chars`
- **THEN** 产品 SHALL 读入这两个键并打一行"已废弃，改用 `spill.preview_chars`"的告警，SHALL NOT 静默忽略；行为 SHALL 以 `spill.preview_chars` 为准

### Requirement: 四个配置项与缺省值，每次调用随请求带到执行侧

命令工具 SHALL 只由**三个**配置值决定交付形状：缺省超时毫秒数 `command_timeout_ms`（缺省 120000）、超时上限 `command_max_timeout_ms`（缺省 600000），以及头尾预览长度 `spill.preview_chars`（顶层 `spill` 块下，缺省 1000，见 `tool-output-spill` 能力）。

> **2026-10-25 修改**：本条由 `spill-large-tool-output` 改写。标题沿用原句是因为解析器要求 MODIFIED 的标题与主规范**逐字一致**；正文已从"四个配置项"变成三个 —— 两个输出上限键废弃，改由 `spill.preview_chars` 一项决定头尾预览。

- `command_max_output_chars` 与 `command_output_full_chars` SHALL 视为**已废弃**：读到它们 SHALL 打一行告警并忽略，行为 SHALL NOT 受其影响（它们原本描述的是"只留尾部 + 写系统临时文件"，那条交付方式已被 `tool-output-spill` 取代）。
- 这三个值 SHALL 由发起调用的那一侧在每次调用时随请求一起交给执行侧（执行侧不读配置文件）；请求里缺失或非法的字段 SHALL 在两侧得到同一套缺省值（`preview_chars` 为非正值时回落到 1000）。
- 工具 SHALL 无条件出现在发给模型的工具定义里，SHALL NOT 依赖搜索服务或浏览器栈的可用性。

#### Scenario: 没有配置项时用缺省值

- **WHEN** 配置里既没有 `command_timeout_ms` / `command_max_timeout_ms`，也没有 `spill.preview_chars`
- **THEN** 工具 SHALL 用 120000 / 600000 / 1000 三个缺省值工作

#### Scenario: 非法值回落到缺省值

- **WHEN** 某个键写成零、负数或文字（例如把 `spill.preview_chars` 配成 0）
- **THEN** 非法值 SHALL 回落到各自的缺省值（`preview_chars` 回落到 1000），工具 SHALL 仍能执行命令

#### Scenario: 配置的值真的生效（`preview_chars` 改小 → 预览跟着变短）

- **WHEN** 把 `spill.preview_chars` 配成 4000 再执行一条输出明显超过它的命令
- **THEN** 返回的 `head` / `tail` SHALL 各为 4000 字符那一档，省略量随之变小 —— 差别证明这个值真的走到了执行侧，而不是只被解析出来又丢掉
- **AND** 这条场景 **不** 要求整段结果仍不超过 8000 字符：头尾各 4000 已经正好 8000，撞上通用截断是预期行为；此时 SHALL 只要求 spill 引用仍留在结果里（见上一条的说明）

#### Scenario: 两个废弃键不再影响行为

- **WHEN** 用户在 `agent_types.general` 段里仍写着 `command_max_output_chars` / `command_output_full_chars`
- **THEN** 解析 SHALL 给出各自的缺省值并打一行废弃告警，实际交付形状 SHALL 与不写这两个键时完全相同

#### Scenario: 超时上限参与计算（单测层判定，不靠真等十分钟）

- **WHEN** 分别给一个小于上限的调用超时与一个大于上限的调用超时
- **THEN** 生效的超时 SHALL 分别等于前者与上限值 —— 这条在单测层断言"生效值怎么算出来的"，SHALL NOT 以"真的等到超时"作为判据（缺省上限是 10 分钟，那样跑不起）

