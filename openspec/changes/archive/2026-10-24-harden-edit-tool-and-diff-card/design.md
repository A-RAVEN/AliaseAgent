## Context

`edit_file` 现在的实现（`sidecar/src/tools.cpp` 的 `edit_file`）分五步：解析 `edits` → 读整份文件到内存 → 三级匹配（精确 / 空白归一化 / 诊断）并校验全部命中 → 按字节偏移倒序替换 → `std::ofstream(resolved, trunc)` 覆写。`write_file` 用同一种覆写方式。

这条链路缺三样东西，而它们互相关联：

- 覆写不是原子的：`trunc` 已经清空原文件，后续写入失败或进程被杀，用户就只剩半截文件。
- 进程里没有任何"我见过这个文件哪一版"的记忆：`edit_file` 只在**当下磁盘内容**上匹配，匹配成功就写。用户在编辑器里同时修改，或者模型拿着旧读到的原文去改，只要原文还在，就静默叠加。
- 结果只有 `{"ok":true,"replacements":N}`：卡片（`lib/ui/tool_call_card.dart`）只显示一句 `Edited <路径> (N replacements)`，用户无法核对具体改了哪几行。

Dart 侧的执行是串行的（`lib/main.dart` 的 `for (final tc in turnToolCalls)` 里逐个 `await _executeTool(tc)`），所以不存在同一进程内两个编辑并发写同一文件的问题——按文件加锁不在本次范围内。

## Goals / Non-Goals

**Goals:**

- 落盘要么完整成功、要么原文件保持原样（崩溃中断也不留半截）。
- `edit_file` 只允许改"本进程已经观测过、且磁盘版本没变"的文件；两种情况分别给出可分辨的失败原因。
- 成功结果带足够信息，让卡片能画出"哪几行、旧的是什么、新的什么"，且这些信息能随会话持久化并在重开后重现。
- 用户能在卡片上直接看出这次改动，不用打开文件对比。

**Non-Goals:**

- 不给 `write_file` 出 diff 卡片（用户在本次对话中决定，2026-10-18）。
- 不给 `write_file` 加版本守卫（覆盖一个大文件时"必须先读"的成本高于收益；本次只改 `edit_file`）。
- 不加按文件加锁（工具串行执行，没有并发写者）。
- 不显示"准备阶段的内容体积"（Anthropic 的 `tool_use` 参数是一次性到齐的，没有半截参数可显示）。
- 不改三级匹配、诊断信息、批量上限、1MB 上限、二进制判定——这些现有行为全部保留。

## Decisions

### D1. 原子写：同目录临时文件 + 改名覆盖

新增内部函数 `write_atomically(resolved_path, content)`，供 `write_file` 与 `edit_file` 共用：

1. 在**目标同目录**生成临时文件名（`<目标文件名>.tmp-<进程号>-<递增序号>`）。必须同目录，否则跨卷改名不是原子操作。
2. 写入全部内容并刷盘。
3. Windows：`MoveFileExW(temp, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`；其它平台：`rename(temp, target)`。
4. 任一步失败：删除临时文件，返回错误，目标文件未被动过。

**错误文案钉死**（否则"改回直接覆写时用例会变红"这条判据写不出来）：

| 情形 | 返回的 `error` |
|---|---|
| 临时文件建不出来 | `Cannot stage file: <路径>` |
| 改名覆盖失败（含目标只读） | `Cannot replace file: <路径> (rename failed, error <系统错误码>)` |

两条都不沿用现有的 `Cannot write file: <路径>`，这样"直接覆写"的实现永远给不出第一句，用例能真正区分。

**临时文件残留**：进程被杀或断电时 `rename` 前的临时文件会留在用户目录里，而且 `list_dir`/`glob_file`/`grep_file` 不认这个前缀，会把它当普通文件列进模型上下文。因此每次 `write_atomically` 开始前，先清理同目录下同一目标的旧临时文件（`<目标文件名>.tmp-*`）。清理失败不影响本次写入。

**非 ASCII 路径**：现有路径工具全是 A 系（`GetFullPathNameA`、`GetFileAttributesA`），`std::string` 里是 ANSI 码页字节。转宽串必须用 `CP_ACP`（与产字节的 API 同码页），用 `CP_UTF8` 会把中文目录名转错成另一条路径。

**长路径**：`canonical()` 把路径卡在 `MAX_PATH` 以内，临时名再拼一截可能越过 260；越界时改名失败会以"无法替换"报出来，属已知限制，写进文档。

**为什么不写"临时文件 → 备份原文件 → 替换"三步**：多一步就多一个能停在中间的状态。改名覆盖在新旧文件之间是原子的，原文件要么还是旧的、要么已经是新的。

**为什么不重试**：重试次数会变成一个没有出处的常数；失败时如实报错并让用户重试，比悄悄重试更诚实。

### D2. 观测表的键与值：进程级、规范化绝对路径 →（修改时间, 大小）

```cpp
struct FileVersion { long long mtime_ticks; long long size; };
// 进程级，编辑工具内部持有
std::unordered_map<std::string, FileVersion> g_observed;
```

- **键**：`check_path` 解析出的规范化绝对路径（与现有沙箱校验同一个值），这样 `a/../b.txt` 与 `b.txt` 指向同一条记录。
- **值**：文件的修改时间（Windows 用 `GetFileTime` / `GetFileAttributesEx` 的 100 纳秒粒度，POSIX 用 `st_mtim`）与字节大小。两者都不需要打开文件、不需要句柄。
- **写记录**：`read_file` 的三个成功出口（空文件、`offset` 超过总行数、正常读取——三者都返回 `ok:true`）、`write_file` 成功之后、`edit_file` 成功之后，各记一次（`write_file` 记录的是写完后的版本，因此"新建/覆盖后接着 edit"不会误报未读过）。
- **读记录 / 比对**：`edit_file` 只比对元数据，位置在读取内容**之前**，并且在存在性/目录/大小/二进制这些现有保护**之后**（见 D3 的顺序表）。

**为什么是进程级而不是按会话隔离**：C++ 侧不知道会话 ID，而 Dart 侧一次会话的工具调用与其它会话共用同一个 sidecar 进程。真正防"静默覆盖"的是版本比对（D2 的值），读前校验只是防止模型凭空改没看过的文件；同一台机器、同一个用户下按进程共享，误放行的后果远小于改动面（要串会话 ID 得改 FFI 接口与所有调用点）。这条限制写进设计，不假装它是按会话精确的。

**为什么不用文件句柄/文件 ID 做版本**：Windows 上要拿稳定文件 ID 得先开句柄，会把"只读元数据"变成"持有句柄"，与沙箱和只读文件场景冲突；修改时间 + 大小已足以发现"改过"，且 `GetFileAttributesEx` 是最便宜的一次调用。

**测试与现有用例的影响**：观测表是进程级的。新增一个只在测试里调用的清空函数（`tools::reset_observation_state_for_tests()`），理由是让"未读过 → 拒绝"这类用例不依赖同进程里先跑过哪个用例（单条 `--test-case` 运行与整体运行给出同一结果）。现有一批 `edit_file` 用例是"建文本文件 → 立刻编辑"，在新守卫下会变成 `not_observed`；它们要改成先 `read_file`。**以二进制文件、超大文件、目录为目标的用例不受影响**——守卫排在那些保护之后，它们仍按原错误返回。

### D3. 版本守卫在匹配之前，失败分两个码

`edit_file` 新增两种失败，结果里带一个 `code` 字段便于 Dart 分辨（其余错误保持现有文本不变）：

| 情形 | `code` | sidecar 返回的 `error` 文本（Dart 原样透传给模型，不改写） |
|---|---|---|
| 该路径从来没有被观测过 | `not_observed` | `cannot edit "<路径>": read the file first` |
| 观测过，但磁盘上的修改时间或大小变了 | `stale` | `cannot edit "<路径>": file changed since it was read; read it again before editing` |

`edit_file` 的检查顺序固定为：

1. 参数结构（`edits` 非空、不超 100 条、`old_text` 非空）——与现状一致，最先返回；
2. `check_path`（工作区/沙箱校验）；
3. 目标不存在、目标是目录；
4. 文件大于 1MB；
5. 前 512 字节含 NUL（二进制）；
6. 未观测 → `not_observed`；
7. 修改时间/大小不符 → `stale`；
8. 读内容 → 匹配 → 写入。

**为什么守卫排在 3~5 之后**：这三种目标的错误结论是确定的（根本改不了），而 `not_observed` 提示"先去读"对二进制/目录是错误建议——去读了也读不成。排在后面同时保住了现有 spec 与现有用例对这些错误文案的断言。

**已知被守卫盖住的一条**：文件存在但打不开时，现状报 `Cannot open file: <路径>`；守卫插在其前，所以"存在但打不开、且没读过"会先报 `not_observed`。这是可接受的（读也打不开），但没有用例断言，写在这里备案。

**为什么守卫排在 8 之前**：内容已变时，匹配面对的是新内容，报"old_text not found"会误导模型去改原文，而真实原因是它该重读。

### D4. 结果结构：`hunks` 而不是整份 before/after

`edit_file` 成功结果新增：

```json
{"ok": true, "replacements": 2, "matched_with": "...",
 "hunks": [{"start_line": 12, "old_text": "旧内容", "new_text": "新内容"}]}
```

- **一个元素 = 一处实际被替换的位置**（`replace_all` 命中 N 次就是 N 个元素），按文件内起始偏移升序。
- `start_line` 是该处替换**在原文件中**起点所在的 1 起行号。
- `old_text` / `new_text` 是磁盘上**真实被替换的字节**与写进去的新内容——不是模型参数里的 `old_text`：空白归一化命中时两者可能不同，卡片必须显示真实的那一份。
- **为什么不返回整份 before/after**：上限 1MB 的文件会变成两趟大字符串穿过 FFI 再落进会话数据库；卡片只需要改动片段。
- **为什么由 C++ 算而不是 Dart 算**：C++ 手里已经有每一处命中的字节区间，直接切出来比事后对两份全文做 diff 更准，也不用给 Dart 引入 diff 依赖。
- **为什么不带上下文行**：上下文行数是一个没有出处的常数（用户只定了显示 12 行）；行号 + 改动本身已经足够定位，需要上下文就点开文件。
- **体积封顶**：`replace_all` 的命中数不受 100 限制（100 只限 `edits` 的条数），一个单字符替换在 1MB 文件里可能命中几十万次，`hunks` 的体积会反过来超过被否决的 before/after。因此约定：`hunks` 序列化后的字节数超过 **1MB**（复用 `edit_file` 现有的那条上限判据 `if (sz > 1024 * 1024)`，不新造数字）时，响应**不携带** `hunks`，改为携带 `"hunks_omitted": "too large"`，`replacements` 照常返回。这样既不静默（调用方能看到为什么没有 diff），也不会把几十万条记录塞进会话库。

### D5. 卡片的 diff 展示

`ToolCallActivity` 新增可空字段 `List<EditHunk>? hunks`：

- `toJson` 只在非空时写出；`fromJson` 缺省为 null —— 老会话的记录里没有这个键，必须照常显示原来的文本结果。
- **折叠态不动**：卡片默认是折叠的（`lib/ui/tool_call_card.dart` 的 `_expanded = false`），折叠时仍按现有行为显示一句话结果（`resultPreview`），**不**渲染 diff —— 这样不触碰既有 spec「无结构化数据的卡片折叠时显示 resultPreview」那条场景。
- **展开态渲染 diff**：展开结果区后，若 `hunks` 非空，渲染 diff 区块：每处先一行行号（`第 12 行`），再按行拆 `old_text`（红色、前缀 `-`）与 `new_text`（绿色、前缀 `+`）。
- **显示上限 12 行**（用户在本次对话中选定，2026-10-18）：把展开态里全部 hunk 的行按顺序摊平，只显示前 12 行，其余折叠；折叠处写明确切数量：`还有 N 行未显示，点击展开`，点开后显示全部。不静默截断。行号行不计入这 12 行。
- **标题行**：`edit_file` 与 `write_file` 卡片只显示 `工具名(路径)`，不再把完整参数拼进标题；`edit_file` 在标题尾部加 `+N/−M`（N/M 由 `hunks` 的新增行数与删除行数相加得出）。`+N/−M` 在折叠态也显示，这样不展开也知道改动规模；`hunks` 缺失时不显示。
- **省略必须看得见**：`hunks` 因为超过 1MB 被省略时，卡片正文要显示一句 `diff 未显示：改动过大（N 处改动）`（N 取现有的 `replacements`），而不是看起来和"这次没有改动"一样。为此 `ToolCallActivity` 要同时带上一个可空字段 `hunksOmitted`（取响应里 `hunks_omitted` 的值），否则这个信息到 Dart 就断了。

### D6. 模型可见内容带上行号（只动成功文案，不改错误文案）

`lib/main.dart` 里 `edit_file` 的模型可见文本按顺序拼装：`Edited <路径> (N replacements)` + （`matched_with` 存在时）` — matched with <matched_with>` + （`hunks` 可用时）` — 第 X、Y 行`。行号取自 `hunks` 的 `start_line`（升序去重）；`hunks` 缺失或 `hunks_omitted` 时整句与改动前逐字一致（含 `matched_with` 后缀）。

**行号清单必须有长度上限**：`replace_all` 可以命中一两万处，把行号全列出来会有十几万字符，既进首轮请求也进后续轮次的工具结果。规则：行号文本超过 **8000 字符**（复用仓库已有的 `kToolResultElisionThreshold`，不新造数字）时，只列前若干个行号，并写明 `共 N 处改动，其余行号见卡片`——数量与去向都写清，不静默截断。

**错误文本一律不改写**：`not_observed` / `stale` 的 `error` 是 sidecar 给的英文句子，Dart 原样透传给模型，与现有所有工具错误的形态一致（`File not found: …`、`old_text must not be empty` 都是英文）。`code` 只存在于 sidecar 响应与 C++ 用例里，Dart 不据它改变任何可见行为（卡片状态本来就按 `ok` 判定）。

**与既有 spec 的关系**：本 change 的两份 delta 只加要求、不改既有条目，因此在新要求里写明了优先级——`stale` 优先于既有的"匹配失败给诊断对象"那条；差异展示只作用于带 `hunks` 的 `edit_file`，既有的"非搜索工具折叠时回退字符串显示"对其它工具照旧。

### D7. `hunks` 既不进请求体，也不进任何 token 估算

`hunks` 会随 `ToolCallActivity.toJson()` 进入消息的 `toolCallsJson`（`lib/main.dart` 的 `tc.addAll(ci.activity.toJson())` → `_msgRepo.updateToolCalls`），这是它持久化、重开会话还能画出 diff 的唯一来源。问题在于同一批 Map 有两处消费者：

1. **实时请求体**：`assistantBlocks.addAll(turnToolCalls)` 放进去的是**同一批 Map 的引用**，随后 `tc.addAll(...)` 会把 `hunks`、`result`、`resultPreview` 一并写进去；下一发请求 `jsonEncode(apiMessages)` 时它们就在 tool_use 块里被真的发出去。重放路径 `_buildApiMessages` 只取 `type/id/name/input`，两条路径因此不一致。
2. **token 估算**：`ContextEstimator.estimateMessage` 按 `toolCallsJson` 的字符数 ÷ 4 计数；占用环的 `ContextBreakdown.fromTimeline` 又对原文段 `jsonEncode` 后的整段计数。

处理：

- **请求体**：实时路径改成和重放路径一致——放进 `assistantBlocks` 的是只含 `type/id/name/input` 的浅拷贝，不持有活动对象的引用。`hunks` 于是永不进入任何请求体，`result`/`resultPreview` 顺带也不再被重复发送（这是本次收敛的副作用，写在这里备案）。
- **估算**：估算 `toolCallsJson` 前剔除 `hunks` 与省略标记字段；`ContextBreakdown.fromTimeline` 累加原文段时同样剔除。验收判据是"同一份消息，带与不带 `hunks` 时估算相同、占用率读数相同"。

这两条必须一起做：只做估算剔除，真实请求仍会带着最多 1MB 的 `hunks` 发出去，读数比真实请求小，方向正是要防的那种偏差。

## Risks / Trade-offs

- **只读目标文件**：改名覆盖会失败，报错且原文件不动。→ 错误文本写清"目标文件可能是只读"，用户能给文件去掉只读或换路径。
- **杀毒/索引程序短暂占用目标文件**：改名偶发失败。→ 如实报错，不做自动重试（不引入无出处的重试次数）。
- **外部工具改写了内容但修改时间没变**（手工 `SetFileTime` 等）：检测不到。→ 属已知边界，写进文档的限制一节；大小变化仍能兜住一部分。
- **用户误以为 `write_file` 也有守卫**：`write_file` 这次不在守卫范围。→ 文档明确写"只有 `edit_file` 有这层保护"。
- **观测表只增不减**：一个进程内按文件条目线性增长，量级是本次运行接触过的文件数，可接受；不设条数上限（避免又发明一个魔数）。
- **现有一批 C++ 用例会因为新守卫变红**：目标为文本文件、建好就改的那些用例会变成 `not_observed`。→ 这不是回归，是守卫生效；改成先 `read_file`，三级匹配、批量、重叠等原有断言保持不变。目标为二进制、超大文件、目录的用例不需要改（守卫排在它们之后）。
- **`hunks` 体积**：常规编辑很小；`replace_all` 在 1MB 文件里可能有几十万次命中。→ 超过 1MB 就不附带 `hunks` 并写省略标记，卡片显示一句"diff 未显示：改动过大"，不静默。
- **估算曾经算进 `hunks`**：D7 的排除规则若被后来的重构丢掉，会出现"改一次大文件，占用环跳一下"。→ 用 `test/unit` 里"带与不带 hunks 估算相同、原文段统计相同"的断言钉住。
- **展开态渲染量**：12 行只约束默认显示，用户点开后会把全部 hunk 行画出来；`hunks` 上限 1MB 时最多约两万行，展开会卡。→ 接受（用户主动操作）；折叠标记先给出精确剩余行数，用户能判断要不要展开。
- **"读过"不等于"看完"**：`read_file` 一次最多 2000 行，但观测记的是整份文件的版本，因此读过前 2000 行就允许改第 5000 行（只要文件没变）。→ 这是本次刻意选的边界（按路径观测，不按区间），写进用户文档的限制一节。
- **临时文件残留**：进程被杀时 `<目标>.tmp-*` 会留在用户目录。→ 每次写入前清理同目标的历史临时文件；文档里说明这类文件可删。
- **与进行中的 `add-context-occupancy-ring` 改动面重叠**：两边都改 `lib/main.dart`（本 change 在 `_executeTool` 与执行循环、对方在发前快照与环），也都会动 `lib/models/context_breakdown.dart`（本 change 只加剔除）。→ 不并行 apply；开工前先确认这两个文件里没有别人未提交的改动，收尾的全量测试判据按"相对开工基线没有新增失败"来写。

## Migration Plan

- 无数据迁移：`hunks` 缺失的记录按老路径显示；工具行为变化只影响新调用。
- 回退：删掉 `hunks` 的消费分支即可退回文本显示；C++ 侧改动独立，回退到上一版 sidecar.dll 即可恢复旧行为。

## Open Questions

- 12 行是用户在本次对话的提问选项中选定的（8 / 12 / 16 / 不设上限 四选一），不是仓库里的既有数字。未来若要可调，需要新增一个配置项并写进 `Docs/user-guide/configuration.md` 的配置键表——本次不做。
- `write_file` 是否也纳入版本守卫，留待后续单独评估（本次明确不做）。
