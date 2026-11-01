## MODIFIED Requirements

### Requirement: 输出有界、只保留尾部、截断可见

每条流的**完整输出** SHALL 先写入 spill 文件（位置见 `tool-output-spill` 能力：`~/.aliasagent/spill/<上下文句柄的无损编码>/<6 位序号>-<流>.txt`，**每条流一个文件**，原子写），写成功之后才决定返回什么。写盘失败时按 `tool-output-spill` 的「写盘失败必须可见」处理：不超过预览阈值的小输出仍 SHALL 直接内联全文。`run_command` 的 spill 键 SHALL 来自首参上下文句柄，不再来自请求里的 `spill_session` 字段。

- 全文长度 ≤ `preview_chars × 2` ⇒ 返回里 SHALL 内联**全文**；
- 全文长度 > `preview_chars × 2` ⇒ 返回里 SHALL 内联**头部前 `preview_chars` 个字符**与**尾部后 `preview_chars` 个字符**，中间段省略，并 SHALL 给出 spill 引用、总字节数、省略字节数。

`preview_chars` 默认 1000（用户 2026-10-25 决定），配置键为 `spill.preview_chars`。

**截断 SHALL NOT 静默发生**：返回里的截断字段 SHALL 标明哪条流被省略、原有字节数、省略了多少、以及引用。

`kToolResultElisionThreshold`（8000 字符）是通用截断的**触发阈值**，不是「任何配置下整段都装得下」的承诺。当 `preview_chars × 2` 小于该阈值时，拼好的正文 SHALL 不超过阈值；当它不小于阈值时，通用截断必然生效，此时 SHALL 只要求**引用与省略量出现在被保留下来的尾部区域**，不得落在被砍掉的中段。

引用行后面最多还会追加 `[timed out …]` 与 `[exit code: …]` 两类短标记，因此规范不写「引用是最后一行」，而写「引用位于尾部区域且通用截断后仍可见」。

> **2026-10-25 修改**：本条由 `spill-large-tool-output` 改写 —— 完整输出不再写系统临时目录，内存里保留的也不再只是尾部。以下是改写后的完整条文。本次仅把 spill 的归属键从会话改为上下文句柄。

#### Scenario: 超长输出头尾都保留并标出省略

- **WHEN** 一条命令写出的标准输出明显超过预览阈值，且开头标记与结尾标记可以区分
- **THEN** 返回的 `stdout` SHALL 同时含开头标记与结尾标记、SHALL NOT 含中间部分，截断字段 SHALL 给出原有字节数、省略字节数与 spill 引用

#### Scenario: 未超限时也落盘但内联全文

- **WHEN** 命令的输出不超过预览阈值
- **THEN** 截断字段 SHALL 为假、返回里 SHALL 内联全文，且该次调用 SHALL 仍然在 spill 目录里留下一个文件（写盘不因"输出小"而跳过）；系统临时目录下 SHALL NOT 新增文件

#### Scenario: 未触发通用截断时整段不超阈值

- **WHEN** `preview_chars × 2` 小于 `kToolResultElisionThreshold`，而命令同时写出远超预览阈值的标准输出与标准错误
- **THEN** 渲染给模型的整段结果 SHALL 不超过 `kToolResultElisionThreshold`，且 spill 引用与省略量 SHALL 留在结果里

#### Scenario: 触发通用截断后引用仍在尾部

- **WHEN** `preview_chars` 配成 4000，使拼好的正文超过 8000 字符并被通用截断
- **THEN** 允许整段超过 8000，但截断后的尾部 SHALL 含 spill 引用与省略量；其后即使再有 `[timed out …]` / `[exit code: …]` 行，也不得把它们连同引用一起砍掉

#### Scenario: spill 写不进去时如实说明

- **WHEN** spill 目录不可写、而命令输出超过预览阈值
- **THEN** 返回 SHALL 是 `ok:false` 并写明写盘失败原因，SHALL NOT 只返回尾部一段内容冒充完整结果

#### Scenario: 同一上下文并发也不覆盖 spill 文件

- **WHEN** 两个线程在同一句柄上同时执行两条都会产生长输出的命令
- **THEN** 两次调用 SHALL 使用不同序号、不同 spill 文件，且每个引用读回的内容 SHALL 与对应命令的完整输出一致

#### Scenario: 旧的两个配置键被废弃

- **WHEN** 用户的配置里仍写着 `command_max_output_chars` 或 `command_output_full_chars`
- **THEN** 产品 SHALL 读入这两个键并打一行"已废弃，改用 `spill.preview_chars`"的告警，SHALL NOT 静默忽略；行为 SHALL 以 `spill.preview_chars` 为准
