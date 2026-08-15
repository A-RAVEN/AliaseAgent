## Context

当前文件工具面：`read_file`（行号/offset/limit/2000 行 cap）、`write_file`（覆盖写+自动建目录）、`edit_file`（单替换，三层匹配：exact → whitespace-normalized → Levenshtein 诊断）、`list_dir`（单层列举）。与主流 agent（Claude Code）对比的差距：无内容搜索（grep）、无模式匹配（glob）、`edit_file` 一次只能改一处（无批量）。仓库规模实测 ~1.1 万文件，决定了搜索工具必须有性能与结果上限约束。

项目现状：C++17；`web_fetch` 已有完整的子进程骨架（Windows `CreateProcessA` + Job Object + 管道轮询 + 超时终止；POSIX `fork`/`select`）；工具均走 workspace 沙箱（`check_path`）。

**外部真实性依据**：本 design 依赖的 ripgrep 行为全部以 `Docs/ripgrepDoc.md`（2026-08-10 从官方 man page 抓取，ripgrep 15.2.0）为唯一依据；该文档未记载者在本 design 中明确标注"未验证"。

## Goals / Non-Goals

**Goals:**
- `edit_file` 改为 `edits` 数组批量接口（1..N 替换对），保留三层匹配能力，任一失败整体回滚
- 新增 `glob_file`（模式查找）与 `grep_file`（正则内容搜索），基于 ripgrep 子进程
- 全部工具保持在 workspace 沙箱内；搜索有结果上限与超时保护
- 复用 `web_fetch` 子进程骨架，不新造进程管理

**Non-Goals:**
- 不建文件索引数据库（一致性维护复杂、FTS 词法索引不适合代码符号；rg 实时扫描 1 万文件亚秒级——性能断言为描述性表述，未做基准验证，不作为验收依据）
- 不做 rg 缺失时的原生 fallback（第一版报明确错误，验证成功后再议）
- 不改 `read_file`/`write_file`/`list_dir` 行为
- 不做任意命令执行（Bash）——安全边界有意保留
- 不做数据库历史 tool_use 块的迁移（历史块不重新执行，仅显示）

## Decisions

### D1: edit_file 批量接口（edits 数组，无兼容层）

**Choice**: 顶层 `old_text`/`new_text`/`replace_all` 移除，改为必填 `edits` 数组：

```json
{"path": "lib/main.dart", "edits": [
  {"old_text": "...", "new_text": "..."},
  {"old_text": "...", "new_text": "...", "replace_all": true}
]}
```

- 每个替换对：`old_text`/`new_text` 必填，`replace_all` 可选（per-edit）
- `edits` 数组长度 1..N，空数组报错；长度上限 100（超出返回错误，防超大请求体）
- 本项目无外部用户、无历史格式依赖（新项目），不保留旧字段（用户明确要求无兼容包袱）
- **空 `old_text` 立即拒绝**：逐对校验，空串返回 `{"ok":false,"error":"old_text must not be empty"}`——保留现有主 spec 的 "Empty old_text SHALL be rejected immediately"（主 spec L42）与现有实现 guard（tools.cpp L736-738），防止 `find()` 空串每位置命中导致的死循环（防死循环机理：L797/L826 的循环以 `pos += old_text.size()` 前进，空串时前进量为 0）

**语义**:
1. **逐对校验**：空 old_text 拒绝；然后所有替换对先在**原始内容**上定位；任一 `old_text` 不存在、或非 `replace_all` 且匹配多处 → 整个请求失败，**零改动**（错误信息指出失败的对序号与原因）
2. **重叠检测**：两个替换对的命中区间（原始内容字节区间）重叠 → 拒绝（"edits overlap"）
3. **应用**：全部验证通过后**按每个命中位置（per-hit）的原始内容字节偏移全局倒序**写回——不是"按对排序"也不是"按数组顺序"。粒度必须是 per-hit 而非 per-pair：`replace_all` 对可能命中多处，若按"该对最后一个命中位置"排序，当该对某次命中位于另一对命中区间之后时，先写回会移动字节偏移、破坏另一对的写入位置（写错文件）。per-hit 倒序保证每次写回只影响该位置之后的字节，之前的位置全部不变（第二轮审查 F9 修正）。验证阶段已保证区间不重叠，per-hit 倒序下每个写回互不影响
4. **per-edit replace_all**：该替换对的所有出现全部替换（验证阶段允许其匹配多处）
5. **行尾/缩进**：三层匹配逻辑（exact → normalized → diagnostic）逐对复用；CRLF 检测保持；**命中区间坐标始终基于原始内容计算**，normalized 匹配（Tier 2）命中后按原始内容中对应区间定位——验证与应用的区间都以原始内容为准
6. **既有保护保留**：整个请求级别——非文本（前 512 字节含 NUL）拒绝、>1MB 拒绝、目录拒绝（错误文案与现有实现一致）

**Rationale**: 与 Claude Code MultiEdit 语义对齐（描述性对照，Claude Code 工具行为无本地文档记载、未验证，不构成验收依据，仅作设计参考）。单替换场景（1 个 edits 元素）行为与旧版一致，只是 schema 形态变化。

### D2: 搜索工具基于 ripgrep 子进程

**Choice**: `glob_file`/`grep_file` 在 C++ 侧 spawn `rg` 子进程，不自己写遍历+匹配。

- **为什么不是原生实现**：`std::filesystem` 递归 + `std::regex` 逐行匹配在 1.1 万文件规模下数秒~数十秒（std::regex 回溯慢，性能差异为经验判断、未基准验证）；rg 成熟引擎（SIMD/并行/亚秒级为描述性表述，未验证）全盘扫描快。Claude Code 即用 rg（描述性对照，未验证）。
- **为什么不建索引**：文件变更后索引过期 → agent 搜到过期结果（一致性问题对 agent 致命）；Windows 文件监视增量更新复杂度高；FTS 词法索引不适合代码符号（驼峰/下划线/符号分词困难）。rg 实时扫描已够快，索引收益不足以支付一致性风险。

**rg 定位**: 复用 `web_fetch.cpp::resolve_script_path()` 的查找模式（候选路径探测：DLL 相对位置 + CWD 相对位置——注意 resolve_script_path 实际含 CWD 候选，非纯 DLL 相对；且该函数本身无 PATH 兜底）。候选：`../tools/rg.exe`、`./tools/rg.exe`、`../share/aliasagent/tools/rg.exe`（Windows）；Linux/macOS 追加 PATH 探测 `rg`。全部候选未命中时返回错误 `"rg not found — install ripgrep or place rg.exe in tools/"`。**不自动下载**（用户需求只要求缺失给安装指引）。

**执行骨架**: 从 `web_fetch.cpp` 抽提通用子进程执行函数（CreateProcess + Job Object + 管道 + 100ms 轮询 + 超时终止 / POSIX fork+select），rg 与 crawl4ai 共用。超时 30s（与 web_fetch 的 SUBPROCESS_TIMEOUT_SEC 一致或独立常量）。

**安全（关键差异）**: crawl4ai 通过 stdin 传 JSON（无注入面）；rg 是 CLI 参数——pattern 来自模型（不信任输入）：
- 命令构造用 `rg --json -n --no-require-git --glob <our_glob> -- <pattern> <root>`：`--` 分隔符使 pattern 不会被解析为 flag（ripgrepDoc 第 7 节已验证："use the special `--` delimiter to indicate that no more flags will be provided"）；pattern 以 `-` 开头时仍安全；`--no-require-git` 与 D4 决策及 spec/tasks 命令形态一致（非 git 仓库下 .gitignore 仍生效）
- `CreateProcessA` 不走 shell（无 cmd.exe 解析），注入风险低于 `popen`；引号/空格按 CreateProcess 命令行转义规则处理
- glob 参数由我方构造并做字符集校验：允许 `A-Za-z0-9*?.,_/-[]{}!`（含 `,`——rg alternatives 语法 `{a,b}` 需逗号分隔，见 ripgrepDoc 第 2 节；`!` 取反同节已验证），**拒绝 `..` 路径段（目录穿越）与绝对路径**（`/` 开头或 `X:` 盘符）——注意按"路径段"判断而非子串包含：文件名内的 `..`（如 `a..b.txt`）合法，不得误拒（收尾轮 F10 修正）；`..` 作为独立路径段才拒绝——字符集仅保证传递安全（单一 argv 元素、不经 shell），不代表所有字符都有已验证语义：`!` 取反与 `{a,b}` alternatives 有 ripgrepDoc 原文；`*`/`?`/`**`/`[]` 的精确匹配规则在 ripgrepDoc 中未记载（"match .gitignore globs" 为推论），实现后以实测为准——spec 承诺**支持**这些语法（透传给 rg），但不承诺**精确匹配规则**（未验证部分以实测回填）
- 模型传入的 pattern 仅经 `--` 隔离 + 转义，不做字符集限制（正则语法本就自由）

**已验证的 rg 外部事实**（ripgrepDoc 第 9 节）：`--json`（JSON Lines，5 消息类型 begin/end/match/context/summary）、`--files`、`-g/--glob`（gitignore 风格 + `!` 取反 + alternatives）、`-i`、`-m/--max-count`、`--`、退出码 0/1/2、`-e/--regexp`、`--no-require-git`。
**未验证（不得作为验收依据）**：`--json` match 消息字段名 schema（`path.text`/`line_number`/`lines.text`）、无斜杠 pattern 的任意深度语义、`*`/`?`/`**`/`[]` 精确 glob 匹配规则、**二进制文件跳过行为**、".git 自动跳过"、单文件 ~2MB、性能断言。（第三轮 F25 修正：二进制跳过与 `?` 语义补入未验证清单，与 spec 的 UNVERIFIED 标注对齐）

### D3: 输出格式

**grep_file**: `rg --json -n` 输出 JSON Lines 流（消息类型与 text/bytes 编码见 ripgrepDoc 第 1 节）。C++ 解析 `match` 消息提取路径/行号/文本——**注意字段名 schema 未验证，解析器必须宽容（同时接受 `path.text` 与 `path.bytes`、行号缺失时降级为无行号输出）**，截断到 `max_results`（默认 100），截断时响应含 `"truncated":true`。**截断判定（第三轮 F14 + 收尾轮 F6 修正）**：`--json` 流**不会以 EOF 结束于 max_results+1 边界**——它总是以 `summary` 消息收尾（ripgrepDoc 第 1 节），因此"多读一条看 EOF"的朴素做法对 JSON Lines 不可行。正确判定：收集满 max_results 条 `match` 消息后**继续读取并按消息类型判别**——下一条是 `match` → 还有更多 → `truncated:true` 并终止子进程；下一条是 `summary` → 总量恰为 max_results → 不截断（`truncated` 缺省）。**退出码语义（收尾轮 F4 补充）**：grep 与 glob 都按 ripgrepDoc 第 4 节处理退出码——退出 0（有匹配）与退出 1（无匹配，正常空结果）均为成功；退出 2 为错误（stderr 判别）。web_fetch 骨架的"非 0 退出即失败"语义**不得复用**于搜索工具（那是 crawl4ai 的约定，rg 的 0/1/2 三态语义不同——收尾轮 F4 明确）。**退出码 2 的错误处理（第三轮 F6/F7 修正）**：rg 退出码 2 是"发生错误"（含正则错误与软错误如无法读取文件，ripgrepDoc 第 4 节原文），不能无条件映射为 invalid regex——实现 SHALL 读取子进程 stderr：stderr 含正则错误特征（如 "regex parse error"）→ `{"ok":false,"error":"invalid regex: ..."}`；其他错误 → `{"ok":false,"error":"search failed: <stderr>"}`。**`--json` 与 `--files` 组合是错误**（ripgrepDoc 第 1 节已验证），故 grep 与 glob 使用不同命令形态，互不混用。

**glob_file**: `rg --files --no-require-git -g <pattern> <root>` 纯路径列表，透传（截断到 `max_results`，默认 200，截断含 `"truncated":true`）。路径输出**相对搜索根**（root = workspace 根时即相对 workspace；"直接透传"是指不经二次转换，透传前需将绝对路径去根化为相对路径）。

**grep_file 路径去根化**（第二轮 F13 + 第三轮 F8/F23 修正）：rg 输出路径的形态（绝对或相对 root）本地文档未记载（`--json` schema 未验证）——解析后统一做**去根化**处理，算法规定如下：
1. 若输出路径为绝对路径且以 root（规范化后）为前缀（含路径分隔符边界检查，避免 `/root2` 误匹配 `/root`），剥离 root 前缀
2. 剥离后以 `/` 或 `\` 开头则去掉该分隔符，得到相对路径
3. 若输出已是相对路径则直接使用（去根化幂等）
4. 路径比较在 Windows 下大小写不敏感（`_stricmp`）、POSIX 下敏感
5. 若输出为绝对路径但**不在 root 下**（异常情况，如 rg 输出外部路径），保留原样并记录日志——此时不违反沙箱（root 由我方硬编码），但 spec 的 relative SHALL 以第 1-3 条为准
与 glob_file 的承诺一致（"workspace-relative paths"）。

**参数**:
- `grep_file`: `{pattern, glob?, ignore_case?, max_results?}`——无 root 参数（root 恒为 workspace 根）
- `glob_file`: `{pattern, max_results?}`——无 root 参数（root 恒为 workspace 根）

### D4: 沙箱与结果上限

- 搜索 root 恒为 workspace 根（`check_path` 限定）；rg 的 `-g` 无法绕过 root 限定（rg 只搜给定 root 下——rg 行为未在 ripgrepDoc 记载，属于实现预期，沙箱正确性由"root 由我方硬编码为 workspace 根、模型无法传入路径"保证，不依赖 rg 行为）
- `max_results` 到达即终止：grep 用 `-m`（每文件行数上限，ripgrepDoc 第 6 节已验证）+ 流式读取达到全局上限后**按消息类型确认**（见 D3 截断判定——下一条 match 才截断并终止，summary 则不截断）；glob 同理（读满后多读一条确认，无 `--json` 的 summary 消息时以 EOF 为准）
- **`-m` 取值与截断偏置**（第二轮 F14 + 第三轮 F10 修正）：`-m` 不能直接映射为 `max_results`——若首个文件匹配数 ≥ max_results，`-m N` 会让该文件独占全部结果、后续文件完全不参与。设计决策：`-m` 取 `max_results` 的放宽值 `4 * max_results`（常量，实现时定义为 `MAX_COUNT_MULTIPLIER`），全局截断由流式读取到 max_results 后按 D3 判定。不再提供回退选项
- **gitignore 处理**（ripgrepDoc 第 8 节已验证）：rg 默认**只在检测到 git 仓库内**才尊重 .gitignore（`--no-require-git` 可放宽）；`.ignore`/`.rgignore` 始终生效。workspace 可能不是 git 仓库 → 搜索命令加 `--no-require-git`（设计决策：加，保证 .gitignore 始终生效）。**`-g`/`--glob` 与 ignore 的交互（第三轮 F9 修正）**：ripgrepDoc 第 2 节记载 "-g ... always overrides any other ignore logic"——显式 glob 过滤的文件会绕过 ignore 规则。含义：grep 的 glob 参数存在时，匹配该 glob 的文件即使被 .gitignore 排除也会被搜索（rg 行为，第 2 节已验证）；glob 为空时 ignore 规则完整生效。此行为如实写入工具描述（tasks 5.3 tool def 描述任务锚点——收尾轮 F14）；spec 的 gitignore 承诺相应限定（见 spec grep requirement）。".git 自动跳过"未验证，不作为承诺

## Risks / Trade-offs

- **[rg 缺失]** → 明确错误信息（含安装指引）；不做 fallback（保持第一版简单）。风险：用户体验依赖一次手动安装。
- **[子进程资源]** → 超时 30s + Job Object 进程树终止（复用 web_fetch 已验证模式）。
- **[pattern 注入]** → `--` 隔离 + CreateProcess 不经 shell + glob 字符集校验（禁 `..`/绝对路径）。残余风险：rg 对畸形正则报退出码 2 而非崩溃（已验证）。
- **[rg --json schema 未验证]** → 解析器宽容降级（path.bytes/缺失行号），spec 不承诺字段名；实现后以实测为准并回填文档（主循环维护职责，规则 8）。
- **[edit 批量语义回归]** → 现有 C++ 测试与 Dart 测试全部更新到新 schema；三层匹配逐对复用；空 old_text 拒绝保留（防死循环）。
- **[大目录输出爆炸]** → max_results 截断（按 D3 消息类型判定后终止子进程）+ 超时兜底；tool def 描述明示上限。
- **[rg 版本差异]** → 只依赖 ripgrepDoc 已验证的基础 flags；命令形态与 man page 15.2.0 一致；"1.x 全版本支持"未验证，不作为承诺。
- **[MODIFIED 按名替换]** → delta spec 的 requirement 名称保持与主 spec 完全一致（`edit_file with exact string matching`），避免合并后新旧 requirement 并存矛盾。

## Migration Plan

1. 本 change 合并后 `edit_file` 新 schema 即刻生效（新项目无存量调用方）
2. 数据库旧会话 tool_use 块含旧字段 `old_text`——只作历史显示，不重新执行，无需迁移（D1 已确认）
3. rg 分发：Windows 放置 `tools/rg.exe`（用户手动下载或包管理器）；Linux/macOS 由系统包管理器安装（apt/dnf/brew install ripgrep）。不提供自动下载脚本。

## Open Questions

- rg `--json` match 消息字段名 schema：实现后实测并回填 `Docs/ripgrepDoc.md`（已列为 D3 宽容降级 + 文档维护任务）
- glob `[]` 字符类与无斜杠 pattern 深度语义：ripgrepDoc 未记载，实现后实测确认，spec 不承诺
- `.gitignore` 尊重策略：`--no-require-git` 决策已定（保证始终生效），实现时验证 `rg --files -g` 下无 git 仓库时行为符合预期
