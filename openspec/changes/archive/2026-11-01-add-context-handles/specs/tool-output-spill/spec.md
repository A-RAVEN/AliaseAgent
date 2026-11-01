## MODIFIED Requirements

### Requirement: 工具输出先落盘（本期适用范围：`run_command`）

`run_command` 的**每条流**在产生文本输出时 SHALL 先把**完整输出**写到一个 spill 文件，写成功之后才决定怎么交付给模型。**写盘失败时的交付方式见「写盘失败必须可见」那条**（输出不超过预览阈值 ⇒ 仍然直接内联全文），本句不覆盖那条豁免。

> **适用范围**：本能力目前只在 `run_command` 上实现（全仓 `spill::write` 只有 `sidecar/src/command_tool.cpp` 一个调用点）。`web_fetch` / `grep_file` / `read_file` 的迁移**不在本期**、另开 change，它们现在仍按旧路径交付 —— 这不是"已统一"，是"迁移到一半"（初稿把本条写成"每一次会产生文本输出的工具调用"，与实现不符，已收窄）。

- 路径 SHALL 落在 `~/.aliasagent/spill/` 下，**按上下文句柄**分目录（键就是句柄，不是会话 id）。目录名 SHALL 由句柄**无损编码**得到：`[a-z0-9_-]` 原样保留，其余字节（含 A–Z 与 `.`）写成 `%XX`（大写十六进制）；因此两个不同的非空名字 SHALL NOT 落到同一个目录，目录名 SHALL 能唯一还原成原始名字，且 `..` / `.` 这类名字 SHALL NOT 让目录跑出 spill 根目录；
- 文件名 SHALL 含调用序号与流名（`<6 位序号>-<流>.txt`，每条流一个文件），序号 SHALL 在**该上下文内**自增；上下文创建时 SHALL 扫描本目录已有文件的最大序号并从其后继续，进程重启后 SHALL NOT 从 1 重来覆盖旧文件；
- 写入 SHALL NOT 截断、SHALL NOT 改变字节（含末尾换行：写入什么就是什么）；
- **规范化只允许发生在"内联预览"这一步，且必须写进用户文档**：C++ 侧拼给模型的 `stdout` / `stderr` 会把 CRLF 归一成 LF、把非法 UTF-8 字节换成 U+FFFD（`command_tool.cpp` 的 `sanitize_utf8`），而 spill 文件里写的是原始字节。这条转换 SHALL 在 `Docs/user-guide/tools-command.md` 里写明（否则就是静默改动内容），且该文档里写的编码规则与样例 SHALL 与实现一致（由一条用例比对，不是靠人看）；
- 上下文销毁时（`dispose_context`），SHALL 先等待在途调用结束，再清理该上下文的 spill 目录 —— 创建与清理用同一个键（句柄），否则按会话 id 清理会找不到按句柄建的目录；**对应不到上下文的无主目录**（`no-session/`，只可能是旧版本遗留）SHALL 在应用启动时清掉，且 SHALL 在用户文档里写明。

#### Scenario: 小输出也先写盘
- **WHEN** 调用 `run_command` 执行一条输出只有 `ok` 的命令
- **THEN** spill 目录里 SHALL 出现一个文件，其字节与命令 stdout 完全相同（不做换行规范化）

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
- **WHEN** 两个线程在同一句柄上同时执行两条都会产生 spill 的命令
- **THEN** 两次分配到的序号 SHALL 不同，两份文件 SHALL 分别等于对应命令的完整输出；不得因原子替换而把后一份盖到前一份上

### Requirement: 引用必须能读回，且只能读 spill 目录里的文件

系统 SHALL 提供 `read_spill` 工具：首参为上下文句柄，入参 `{"ref": "<引用>", "offset": <字节偏移>, "limit": <字节数>}`，返回该区间的原文。

- 读回的内容 SHALL 与 spill 文件里对应区间**逐字节相同**（多字节字符被切半时，SHALL 明确报错而不是返回半个字符）；
- **`ref` SHALL 先按平台规范化（POSIX 用 `realpath`，Windows 用 `GetFullPathName`），再判断是否落在该句柄对应的本上下文 spill 目录之内**；不能只落在整个 spill 根内，也不能只做未规范化的字符串前缀比较。读取其它上下文的引用（含 `<乙>/../<甲>/文件`）SHALL 返回 `ok:false`，理由 SHALL 说明引用不属于本上下文；
- 解析到 spill 根目录之外（例如 `~/.aliasagent/config.json`）SHALL 返回 `ok:false`，理由 SHALL 说明"引用不在 spill 根目录内"；
- 越界、引用不存在、根目录不可读时 SHALL 分别返回可区分的错误，SHALL NOT 返回空内容冒充成功。

#### Scenario: 取回中段
- **WHEN** 对一份 200000 字节的 spill 引用调用 `read_spill`（offset=50000, limit=1000）
- **THEN** 返回的 1000 字节 SHALL 与 `spill 文件[50000, 51000)` 逐字节相同

#### Scenario: 目录外的引用被拒
- **WHEN** `ref` 指向 `~/.aliasagent/config.json`
- **THEN** 返回 SHALL 是 `ok:false`，且错误文本 SHALL 说明引用不在 spill 根目录内

#### Scenario: 其它上下文的引用被拒
- **WHEN** 用乙的句柄读取甲目录下一份合法 spill 文件的绝对路径引用
- **THEN** 返回 SHALL 是 `ok:false`，且 SHALL NOT 返回甲文件内容

#### Scenario: 引用不存在
- **WHEN** 用一个不存在的引用调用 `read_spill`
- **THEN** 返回 SHALL 是 `ok:false` 且带错误原因
