## ADDED Requirements

### Requirement: 工具输出一律先落盘

每一次会产生文本输出的工具调用 SHALL 先把**完整输出**写到一个 spill 文件，写成功之后才决定怎么交付给模型。

- 路径 SHALL 落在 `~/.aliasagent/spill/` 下，按会话分目录，文件名含调用序号；
- 写入 SHALL NOT 截断、SHALL NOT 转义丢失字节；
- 会话被删除时，该会话的 spill 目录 SHALL 一并清理。

#### Scenario: 小输出也先写盘
- **WHEN** 调用 `run_command` 执行一条输出只有 "ok" 的命令
- **THEN** spill 目录里 SHALL 出现一个文件，内容恰为 "ok"（允许末尾换行的规范化，须在实现里定死并写进文档）

#### Scenario: 会话删除时清理
- **WHEN** 删除一个产生过 3 次工具输出的会话
- **THEN** 该会话的 spill 目录 SHALL 不存在了，别的水话的 spill 目录 SHALL 不受影响

### Requirement: 按体积决定内联还是引用

写盘成功后，系统 SHALL 比较完整输出的长度与内联上限：

- 不超过上限 ⇒ 结果里 SHALL 直接内联全文；
- 超过上限 ⇒ 结果里 SHALL 只内联**头尾各 1000 字符**，其余不内联。

`1000` 这个数字的来源是用户 2026-10-25 的决定（原话：「4000字听起来也好多，改成1000字吧」）。内联上限本身 SHALL 是配置项，默认值与可配范围写进 `Docs/user-guide/configuration.md` 的配置键表。

#### Scenario: 短输出直接内联
- **WHEN** 一条命令的输出短于内联上限
- **THEN** 结果里的文本 SHALL 等于完整输出，且 SHALL NOT 出现"被省略"的提示

#### Scenario: 长输出头尾各留 1000 字符
- **WHEN** 一条命令输出 200000 字节，头部第 3 行是一条错误
- **THEN** 结果里 SHALL 包含头部前 1000 字符（因此那条错误可见）、SHALL 包含尾部后 1000 字符、SHALL NOT 包含中间部分，且 SHALL 给出引用

### Requirement: 结果信封必须带量

超过内联上限时，结果 SHALL 是一份结构化信封，至少含：总字节数、被省略的字节数、头预览、尾预览、spill 引用、保留期说明。
SHALL NOT 只给一句"输出被截断"。

#### Scenario: 信封字段齐全
- **WHEN** 一条命令输出超过内联上限
- **THEN** 结果 JSON 里 SHALL 能读到总字节数、省略字节数、引用三样，且省略字节数 + 内联字节数与总字节数自洽

### Requirement: 引用必须能读回

系统 SHALL 提供 `read_spill` 工具：入参 `{"ref": "<引用>", "offset": <字节偏移>, "limit": <字节数>}`，返回该区间的原文。

- 读回的内容 SHALL 与 spill 文件里对应区间**逐字节相同**；
- 越界或引用不存在时 SHALL 返回可见错误，SHALL NOT 返回空内容冒充成功。

#### Scenario: 取回中段
- **WHEN** 对一份 200000 字节的 spill 引用调用 `read_spill`（offset=50000, limit=1000）
- **THEN** 返回的 1000 字节 SHALL 与 `spill 文件[50000, 51000)` 逐字节相同

#### Scenario: 引用不存在
- **WHEN** 用一个不存在的引用调用 `read_spill`
- **THEN** 返回 SHALL 是 `ok:false` 且带错误原因

### Requirement: 写盘失败必须可见

写盘失败（磁盘满、无权限）时系统 SHALL 区分两种情况处理：

- 输出本身不超过内联上限 ⇒ SHALL 直接内联全文（此时不丢内容）；
- 输出超过内联上限 ⇒ SHALL 返回明确的错误，说明写盘失败的原因，SHALL NOT 静默只给一部分。

#### Scenario: 磁盘不可写且输出超限
- **WHEN** spill 目录不可写、而命令输出超过内联上限
- **THEN** 结果 SHALL 是 `ok:false` 并含写盘失败原因，SHALL NOT 只返回尾部一段内容冒充完整结果
