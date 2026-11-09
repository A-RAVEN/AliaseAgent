# tool-output-spill 能力（delta）

## MODIFIED Requirements

### Requirement: 工具输出先落盘（适用范围：`run_command` 与 `web_fetch`）

`run_command` 的**每条流**、`web_fetch` 的**正文**与 `load_skill` 的**文件内容**在产生文本输出时 SHALL 先把**完整输出**写到一个 spill 文件，写成功之后才决定怎么交付给模型。**写盘失败时的交付方式见「写盘失败必须可见」那条**（输出不超过预览阈值 ⇒ 仍然直接内联全文），本句不覆盖那条豁免。

> **适用范围**：本能力在 `run_command`、`web_fetch` 与 `load_skill` 上实现。"落盘 + 拼形状"的统一入口是 `spill::shape_stream`（内部调 `spill::write_for_context` 落盘），三个工具共读这一份实现；落盘调用点分别在 `sidecar/src/command_tool.cpp`、`sidecar/src/web_fetch.cpp`（web_fetch 侧的形状集中在包装函数 `web_fetch_shape_success_result` 内、由两个成功出口各调一次，见 `web-fetch` 能力与下方"交付形状实现只此一份"）与 `sidecar/src/skill_tool.cpp`。`grep_file` / `read_file` 的迁移**不在本期**、另行立项，它们现在仍按旧路径交付。`web_fetch` 的流名（tag）SHALL 为 `content`，文件形如 `<6 位序号>-content.txt`；`run_command` 的两条流名 `stdout` / `stderr` 不变；`load_skill` 的流名 SHALL 为 `skill`，文件形如 `<6 位序号>-skill.txt`。
>
> （本条**标题**里的工具列举需同步为三工具，属归档同步时对标题的更新；delta 阶段标题保持与既有主 spec 逐字一致以保证匹配，执行顺序见本 change 的 tasks。）

- 路径 SHALL 落在 `~/.aliasagent/spill/` 下，**按上下文句柄**分目录（键就是句柄，不是会话 id）。目录名 SHALL 由句柄**无损编码**得到：`[a-z0-9_-]` 原样保留，其余字节（含 A–Z 与 `.`）写成 `%XX`（大写十六进制）；因此两个不同的非空名字 SHALL NOT 落到同一个目录，目录名 SHALL 能唯一还原成原始名字，且 `..` / `.` 这类名字 SHALL NOT 让目录跑出 spill 根目录；
- 文件名 SHALL 含调用序号与流名（`<6 位序号>-<流>.txt`，每条流一个文件），序号 SHALL 在**该上下文内**自增；上下文创建时 SHALL 扫描本目录已有文件的最大序号并从其后继续，进程重启后 SHALL NOT 从 1 重来覆盖旧文件；
- 写入 SHALL NOT 截断、SHALL NOT 改变字节（含末尾换行：写入什么就是什么）；
- **规范化只允许发生在"内联预览"这一步，且必须写进用户文档**：C++ 侧拼给模型的正文会把 CRLF 归一成 LF、把非法 UTF-8 字节换成 U+FFFD（`sanitize_utf8`），而 spill 文件里写的是原始字节。这条转换 SHALL 在 `Docs/user-guide/tools-command.md`、`Docs/user-guide/tools-web.md` 与 `Docs/user-guide/skills.md` 里写明（否则就是静默改动内容），且该文档里写的编码规则与样例 SHALL 与实现一致（由一条用例比对，不是靠人看）；
- 上下文销毁时（`dispose_context`），SHALL 先等待在途调用结束，再清理该上下文的 spill 目录 —— 创建与清理用同一个键（句柄），否则按会话 id 清理会找不到按句柄建的目录；**对应不到上下文的无主目录**（`no-session/`，只可能是旧版本遗留）SHALL 在应用启动时清掉，且 SHALL 在用户文档里写明。

#### Scenario: 小输出也先写盘
- **WHEN** 调用 `run_command` 执行一条输出只有 `ok` 的命令
- **THEN** spill 目录里 SHALL 出现一个文件，其字节与命令 stdout 完全相同（不做换行规范化）

#### Scenario: web_fetch 抓到的正文也先写盘
- **WHEN** 调用 `web_fetch` 抓回一段正文（无论长短）
- **THEN** 本上下文的 spill 目录里 SHALL 出现一个 `<序号>-content.txt`，其字节与抓取返回的完整正文一致（不做换行规范化），且模型可见正文短于阈值时 SHALL 就是这段全文

#### Scenario: load_skill 返回的文件内容也先写盘
- **WHEN** 调用 `load_skill` 加载一段内容（无论长短）
- **THEN** 本上下文的 spill 目录里 SHALL 出现一个 `<序号>-skill.txt`，其字节与切除 frontmatter 后的正文（或附属文件全文）逐字节一致，短内容时模型可见文本 SHALL 就是全文

#### Scenario: 销毁上下文时清理
- **WHEN** 一个产生过 3 次工具输出的上下文被 `dispose_context`
- **THEN** 该上下文的 spill 目录 SHALL 不存在了，别的上下文的 spill 目录 SHALL 不受影响

#### Scenario: 两个名字只在非保留字符上不同时不共用目录
- **WHEN** 两个上下文分别叫 `会话甲` 与 `会话乙`
- **THEN** 它们各自的 spill 目录 SHALL 是两个不同的目录，且目录名能唯一还原成原始名字

#### Scenario: 只差大小写的两个名字不共用目录
- **WHEN** 两个上下文分别叫 `Agent-7` 与 `agent-7`
- **THEN** 它们各自的 spill 目录 SHALL 是两个不同的目录（Windows 文件系统不区分大小写，所以大写字母必须被编码掉）

#### Scenario: 名字里的 `..` 不会跑出根目录
- **WHEN** 上下文名字是 `..`
- **THEN** 它的 spill 目录 SHALL 仍在 spill 根目录之内，`read_spill` 能正常读回它的文件

#### Scenario: 序号按上下文自增
- **WHEN** 上下文 `甲` 先跑一次 `run_command`，上下文 `乙` 再跑一次
- **THEN** 两个上下文各自的第一条输出 SHALL 都叫 `000001-…`（各自的目录里从 1 开始），互不影响

#### Scenario: 同一上下文并发也不会撞序号
- **WHEN** 两个线程在同一句柄上同时执行两条都会产生 spill 的输出（两条 `run_command`，或 `run_command` 与 `web_fetch` 各一）
- **THEN** 两次分配到的序号 SHALL 不同，两份文件 SHALL 分别等于对应的完整输出；不得因原子替换而把后一份盖到前一份上

### Requirement: 按长度决定内联全文还是只给头尾预览

交付规则 SHALL 只用一个数字 `preview_chars`（默认 1000，配置项 `spill.preview_chars`；由 Dart 读配置后随请求传入，C++ 侧缺省兜底常量 `spill::kDefaultPreviewChars = 1000`——随形状实现提升到 `spill.h`，三个工具共读这一份），对 `run_command` 的每条流、`web_fetch` 的正文与 `load_skill` 的文件内容判定如下：

- 全文长度 ≤ `preview_chars × 2` ⇒ SHALL 内联**全文**，且 SHALL NOT 出现"省略"字样（否则省略量会是 0 或负数）；
- 全文长度 > `preview_chars × 2` ⇒ SHALL 只内联**头部前 `preview_chars` 个字符**与**尾部后 `preview_chars` 个字符**，两者 SHALL NOT 重叠，中间段 SHALL 被省略并计入省略量。

`1000` 的来源是用户 2026-10-25 的决定（原话「4000字听起来也好多，改成1000字吧」）；`× 2` 是算术推论，不是另一个魔数。**旧稿把同一个 1000 同时当作"内联上限"与"每侧长度"，导致 1001–2000 字符的输出既算超限又把全文塞回去 —— 已消除这个自相矛盾。**

#### Scenario: 短输出直接内联
- **WHEN** 一条命令输出 1500 字符（≤ 1000×2）
- **THEN** 结果里的文本 SHALL 等于完整输出，且 SHALL NOT 出现省略量字段以外的任何"省略"提示

#### Scenario: 长输出头尾各留 1000 字符
- **WHEN** 一条命令输出 200000 字节，第 1 行是一条 `error C2065`
- **THEN** 结果里 SHALL 包含头部前 1000 字符（因此第 1 行可见）、SHALL 包含尾部后 1000 字符、SHALL NOT 包含中间部分，且 SHALL 给出引用与省略量

#### Scenario: web_fetch 长正文头尾各留 preview_chars 字符
- **WHEN** `web_fetch` 抓回一段长度超过 `preview_chars × 2` 的正文
- **THEN** 模型可见正文 SHALL 含头 `preview_chars` 与尾 `preview_chars` 两段、SHALL NOT 含中间段，并 SHALL 给出引用与省略字节数；模型可见正文 SHALL NOT 再受任何独立的固定字符数硬切（旧的 Dart 侧 2000 硬切废除）

#### Scenario: load_skill 长正文同样只给头尾
- **WHEN** 某技能正文长度超过 `preview_chars × 2`
- **THEN** 模型可见文本 SHALL 含头尾各 `preview_chars` 字符、SHALL NOT 含中间段，并 SHALL 给出引用与省略量

### Requirement: 结果信封必须带量，且量与输入对得上

超过预览阈值时，结果 SHALL 是一份结构化信封，至少含：总字节数、被省略的字节数、头预览、尾预览、spill 引用。`run_command`、`web_fetch` 与 `load_skill` 都 SHALL 在成功结果里带该信封（`web_fetch` 的键为 `content` 流，`load_skill` 为 `skill` 流）。SHALL NOT 只给一句"输出被截断"。

**判据必须与外部真值对照**：省略量与总字节数的关系 SHALL 用"命令实际输出长度"或"spill 文件实际大小"来核对，SHALL NOT 只让信封自己内部的三个数自洽（那样任何实现都能通过）。

#### Scenario: 信封与文件大小对得上
- **WHEN** 一条命令输出 200000 字节
- **THEN** 信封里的总字节数 SHALL 等于 spill 文件的实际大小，且"省略字节数 + 头尾两段的**原始切片**字节数（`|head| + |tail|`，以 spill 文件字节计，不是消毒后内联文本的字节数）" SHALL 等于该值；伪造一个小一点的总字节数时这条必须红

#### Scenario: web_fetch 信封与落盘文件对得上
- **WHEN** `web_fetch` 抓回一段长正文并落了盘
- **THEN** 信封的总字节数 SHALL 等于该 spill 文件的实际大小，省略量 + 头尾两段的原始切片字节数（`|head| + |tail|`，同上一条口径）SHALL 等于总量；把内联文本改成更短而不改信封时这条必须红

#### Scenario: load_skill 信封与落盘文件对得上
- **WHEN** `load_skill` 返回的长内容落了盘
- **THEN** 信封总字节数 SHALL 等于该 `<序号>-skill.txt` 的实际大小，省略量 + 头尾原始切片字节数（同口径）SHALL 等于总量

### Requirement: 写盘失败必须可见

写盘失败（磁盘满、无权限）时系统 SHALL 区分两种情况处理（对 `run_command` 每条流、`web_fetch` 正文与 `load_skill` 文件内容同样适用）：

- 输出本身不超过预览阈值 ⇒ SHALL 直接内联全文（此时不丢内容）；
- 输出超过预览阈值 ⇒ SHALL 返回明确的错误，说明写盘失败的原因，SHALL NOT 静默只给一部分。

#### Scenario: 磁盘不可写且输出超限
- **WHEN** spill 目录不可写、而命令输出超过预览阈值
- **THEN** 结果 SHALL 是 `ok:false` 并含写盘失败原因，SHALL NOT 只返回尾部一段内容冒充完整结果

#### Scenario: 磁盘不可写且 web_fetch 正文超限
- **WHEN** spill 目录不可写、而 `web_fetch` 抓回的正文超过预览阈值
- **THEN** 结果 SHALL 是 `ok:false` 并含写盘失败原因（目录与系统报错），SHALL NOT 只给头尾预览冒充完整正文

#### Scenario: 磁盘不可写且 load_skill 内容超限
- **WHEN** spill 目录不可写、而 `load_skill` 要返回的内容超过预览阈值
- **THEN** 结果 SHALL 是 `ok:false` 并含写盘失败原因，SHALL NOT 只给头尾预览冒充完整内容

### Requirement: 交付形状实现只此一份

`落盘 → 按 `preview_chars` 决定内联全文或头尾预览 → 拼省略说明` 这段形状 SHALL 是一份共享实现（提升自 `run_command` 私有的 `shape_stream`，落位 `spill.h`/`spill.cpp`），`run_command`、`web_fetch` 与 `load_skill` SHALL 调同一份；SHALL NOT 出现第二份复制该形状的实现。形状三条不变量 SHALL 对该共享实现的每个调用方同时成立：①头/尾是 spill 文件里原始字节的码点边界切片，`|head| + |tail| + omitted_bytes == total_bytes` 恒成立；②给模型的内联文本只对头尾做 `sanitize_utf8`（换行归一、坏字节替换），不落到文件；③引用绝对路径可被 `read_spill` 按字节读回中间段。

#### Scenario: 三个工具共用同一形状
- **WHEN** 检索共享实现（头尾切片 + 省略说明拼装）的调用点
- **THEN** 该实现 SHALL 只在 `sidecar/src/spill.cpp` 定义一处；`shape_stream` 的调用点 SHALL 恰四处——`command_tool.cpp` 两处（stdout/stderr）、`web_fetch.cpp` 的形状包装函数（`web_fetch_shape_success_result`）内一处、`skill_tool.cpp` 内一处；`web_fetch_impl` 的两个成功出口（crawl4ai 的 `return parsed.dump()` 前与 curl 的 `return result.dump()` 前）SHALL 各调一次该包装（包装调用点恰两处）；SHALL NOT 有第二份复制体，漏接任何一个出口 SHALL 被上述计数抓住

#### Scenario: 搬运不改变 run_command 行为
- **WHEN** `shape_stream` 被提升为共享实现后运行 `run_command` 的既有 spill 测试（tag `[spill]`）
- **THEN** 这些用例 SHALL 全绿；任何一条红都说明搬运改变了既有语义
