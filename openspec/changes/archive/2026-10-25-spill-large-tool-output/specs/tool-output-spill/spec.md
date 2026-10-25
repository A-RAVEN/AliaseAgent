## ADDED Requirements

### Requirement: 工具输出先落盘（本期适用范围：`run_command`）

`run_command` 的**每条流**在产生文本输出时 SHALL 先把**完整输出**写到一个 spill 文件，写成功之后才决定怎么交付给模型。

> **适用范围**：本能力目前只在 `run_command` 上实现（全仓 `spill::write` 只有 `sidecar/src/command_tool.cpp` 一个调用点）。`web_fetch` / `grep_file` / `read_file` 的迁移**不在本期**、另开 change，它们现在仍按旧路径交付 —— 这不是"已统一"，是"迁移到一半"（初稿把本条写成"每一次会产生文本输出的工具调用"，与实现不符，已收窄）。

- 路径 SHALL 落在 `~/.aliasagent/spill/` 下，按会话分目录，文件名含调用序号与流名（`<6 位序号>-<流>.txt`，每条流一个文件）；
- 写入 SHALL NOT 截断、SHALL NOT 改变字节（含末尾换行：写入什么就是什么）；
- **规范化只允许发生在"内联预览"这一步，且必须写进用户文档**：C++ 侧拼给模型的 `stdout` / `stderr` 会把 CRLF 归一成 LF、把非法 UTF-8 字节换成 U+FFFD（`command_tool.cpp` 的 `sanitize_utf8`），而 spill 文件里写的是原始字节。这条转换 SHALL 在 `Docs/user-guide/tools-command.md` 里写明（否则就是静默改动内容）；
- 会话被删除时，该会话的 spill 目录 SHALL 一并清理；**对应不到会话的无主目录**（会话 id 为空时落进去的 `no-session/`）SHALL 在应用启动时清掉，且 SHALL 在用户文档里写明。

#### Scenario: 小输出也先写盘
- **WHEN** 调用 `run_command` 执行一条输出只有 `ok` 的命令
- **THEN** spill 目录里 SHALL 出现一个文件，其字节与命令 stdout 完全相同（不做换行规范化）

#### Scenario: 会话删除时清理
- **WHEN** 删除一个产生过 3 次工具输出的会话
- **THEN** 该会话的 spill 目录 SHALL 不存在了，别的会话的 spill 目录 SHALL 不受影响

### Requirement: 按长度决定内联全文还是只给头尾预览

交付规则 SHALL 只用一个数字 `preview_chars`（默认 1000，配置项），判定如下：

- 全文长度 ≤ `preview_chars × 2` ⇒ SHALL 内联**全文**，且 SHALL NOT 出现"省略"字样（否则省略量会是 0 或负数）；
- 全文长度 > `preview_chars × 2` ⇒ SHALL 只内联**头部前 `preview_chars` 个字符**与**尾部后 `preview_chars` 个字符**，两者 SHALL NOT 重叠，中间段 SHALL 被省略并计入省略量。

`1000` 的来源是用户 2026-10-25 的决定（原话「4000字听起来也好多，改成1000字吧」）；`× 2` 是算术推论，不是另一个魔数。**旧稿把同一个 1000 同时当作"内联上限"与"每侧长度"，导致 1001–2000 字符的输出既算超限又把全文塞回去 —— 本稿已消除这个自相矛盾。**

#### Scenario: 短输出直接内联
- **WHEN** 一条命令输出 1500 字符（≤ 1000×2）
- **THEN** 结果里的文本 SHALL 等于完整输出，且 SHALL NOT 出现省略量字段以外的任何"省略"提示

#### Scenario: 长输出头尾各留 1000 字符
- **WHEN** 一条命令输出 200000 字节，第 1 行是一条 `error C2065`
- **THEN** 结果里 SHALL 包含头部前 1000 字符（因此第 1 行可见）、SHALL 包含尾部后 1000 字符、SHALL NOT 包含中间部分，且 SHALL 给出引用与省略量

### Requirement: 结果信封必须带量，且量与输入对得上

超过预览阈值时，结果 SHALL 是一份结构化信封，至少含：总字节数、被省略的字节数、头预览、尾预览、spill 引用。
SHALL NOT 只给一句"输出被截断"。

**判据必须与外部真值对照**：省略量与总字节数的关系 SHALL 用"命令实际输出长度"或"spill 文件实际大小"来核对，SHALL NOT 只让信封自己内部的三个数自洽（那样任何实现都能通过）。

#### Scenario: 信封与文件大小对得上
- **WHEN** 一条命令输出 200000 字节
- **THEN** 信封里的总字节数 SHALL 等于 spill 文件的实际大小，且"省略字节数 + 内联字节数" SHALL 等于该值；伪造一个小一点的总字节数时这条必须红

### Requirement: 引用必须能读回，且只能读 spill 目录里的文件

系统 SHALL 提供 `read_spill` 工具：入参 `{"ref": "<引用>", "offset": <字节偏移>, "limit": <字节数>}`，返回该区间的原文。

- 读回的内容 SHALL 与 spill 文件里对应区间**逐字节相同**（多字节字符被切半时，SHALL 明确报错而不是返回半个字符）；
- **`ref` 解析后 SHALL 落在 spill 根目录之内**；解析到目录之外（例如 `~/.aliasagent/config.json`）SHALL 返回 `ok:false`，理由 SHALL 说明"引用不在 spill 根目录内"；
- 越界、引用不存在、根目录不可读时 SHALL 分别返回可区分的错误，SHALL NOT 返回空内容冒充成功。

#### Scenario: 取回中段
- **WHEN** 对一份 200000 字节的 spill 引用调用 `read_spill`（offset=50000, limit=1000）
- **THEN** 返回的 1000 字节 SHALL 与 `spill 文件[50000, 51000)` 逐字节相同

#### Scenario: 目录外的引用被拒
- **WHEN** `ref` 指向 `~/.aliasagent/config.json`
- **THEN** 返回 SHALL 是 `ok:false`，且错误文本 SHALL 说明引用不在 spill 根目录内

#### Scenario: 引用不存在
- **WHEN** 用一个不存在的引用调用 `read_spill`
- **THEN** 返回 SHALL 是 `ok:false` 且带错误原因

### Requirement: 写盘失败必须可见

写盘失败（磁盘满、无权限）时系统 SHALL 区分两种情况处理：

- 输出本身不超过预览阈值 ⇒ SHALL 直接内联全文（此时不丢内容）；
- 输出超过预览阈值 ⇒ SHALL 返回明确的错误，说明写盘失败的原因，SHALL NOT 静默只给一部分。

#### Scenario: 磁盘不可写且输出超限
- **WHEN** spill 目录不可写、而命令输出超过预览阈值
- **THEN** 结果 SHALL 是 `ok:false` 并含写盘失败原因，SHALL NOT 只返回尾部一段内容冒充完整结果
