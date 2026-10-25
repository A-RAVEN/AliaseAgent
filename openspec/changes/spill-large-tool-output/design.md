## Context

工具输出现在由各工具各自截断，最典型的是 `run_command`：工具说明原文写着 *"Long output is truncated to its tail and the full output is written to a temp file whose path is reported."* 三个后果：只留尾部（构建的第一条 error 在头部，必被砍）、临时文件无保留策略、占位不带量。另有 `kToolResultElisionThreshold`（8000 字符，砍工具结果中段）与命令输出的 `maxLen = 2000`（Dart 侧二次截断）。

相关既有设施：`ConfigService.attachmentsDir`（`~/.aliasagent/attachments/`，图片落盘就在用这套习惯）；`sidecar/src/tools.cpp` 的工作区沙箱（`Access denied: path outside workspace`）；`sidecar_api.cpp` 每个导出函数共用一块 `static std::string g_*_result`。

## Goals / Non-Goals

**Goals**

- 任何工具输出都先完整落盘，再从盘上的全文派生"给模型看的那份"。
- 超限时头尾各留 1000 字符、中间省略，并给出可取回的引用与省略量。
- 引用能按偏移精确读回，且与文件逐字节一致。
- 写盘失败时行为可见（小输出退回内联、大输出明确报错）。

**Non-Goals**

- 不做命令审批、沙箱、回退（见 `CLAUDE.md` 的零审批立场与台账第 24、25 条）。
- 不改上下文压缩的阈值与层级规则。
- 不把 spill 做进工作区（会污染仓库、会被 git 带进去）。
- 本期不做跨进程/多 agent 的隔离（见 `Docs/RoadMap.md` 阶段 2/5）。

## Decisions

### D1 一律先落盘，再决定交付方式

**选择**：每次产生文本输出的工具调用，先把**完整输出**写到 spill 文件；写完再比长度。

**理由**：只有落盘才能保证"省略的内容可恢复"；也只有落盘之后，"内联多少"才是一个纯粹的展示决定，不影响内容完整性。

**代价与收法**：每个调用都会产生一个文件。两条可选收法，本期采用后者：
- （未采用）只对超过某小阈值的才落盘 —— 会破坏"一律落盘"的简单性，且小输出同样可能被后续需要；
- **（采用）全部落盘 + 随会话删除**：清理责任挂在会话生命周期上，不设时间上限，也就不需要发明一个"保留几天"的数。

### D2 头尾各 1000 字符，按 UTF-8 字符切

**选择**：超限时内联"头部前 1000 个字符"与"尾部后 1000 个字符"，中间用一句省略说明连接。

**依据**：`1000` 是用户 2026-10-25 的决定（原话「4000字听起来也好多，改成1000字吧」）。**按字符而不是按字节切**，否则中文会被切成半个字、产生非法 UTF-8。切分必须在字符边界上做（C++ 侧用 UTF-8 码点边界扫描，不用 `substr` 硬切）。

### D3 只用一个配置项 `spill.preview_chars`（默认 1000），判定阈值是它的 2 倍

**选择**：配置项 `spill.preview_chars`（默认 1000）既是头预览长度也是尾预览长度；**是否内联全文的阈值 = `2 × preview_chars`**。写进 `Docs/user-guide/configuration.md` 的配置键表。

**理由**：初稿把 1000 同时当"内联上限"与"每侧长度"，于是 1001–2000 字符的输出会"超限"却把全文塞回去（头 1000 + 尾 1000 覆盖全部，还重复计 500 字符），"省略量"会是 0 或负数 —— 判据无法判定。改成"阈值 = 2×每侧"后只用到一个用户给过的数，`×2` 是算术不是魔数。

**旧稿的 `spill.inline_chars` 作废**：它同时承担两个语义，是本轮对抗验证发现的真缺陷。

### D4 `read_spill` 的 offset/limit 用**字节**，不用字符

**选择**：`read_spill(ref, offset, limit)` 里的偏移与长度都是字节。

**理由**：验收要求"与文件逐字节一致"。用字符偏移会让"第 N 个字符"与"第 N 个字节"产生歧义，多字节内容上必错。字符级的便利可以在上层封装，不在契约层混用。

### D5 存放位置与会话绑定

**选择**：`~/.aliasagent/spill/<会话 id>/<调用序号>.txt`；引用就是这个路径（或路径的相对形式）。

**理由**：与 `attachments` 同源，用户能在同一个目录下找到自己的东西；按会话分目录使"删会话 ⇒ 删目录"成为一条机械操作。

**为什么不放工作区**：放工作区会被 git 追踪、会出现在 `git status` 里，污染用户仓库。

### D6 写盘用原子写

**选择**：先写 `*.tmp` 再 rename 到目标名，失败时删临时文件。

**理由**：读回契约建立在"文件要么完整存在、要么不存在"之上；半截文件会让 `read_spill` 返回错误内容而不报错。

### D7 迁移顺序：先 `run_command`，再其余；并处理三类"已有取回办法"的差异

**选择**：本期只把 `run_command` 的交付改成 spill 信封；`web_fetch` / `grep_file` / `read_file` 的迁移放到后续任务。

**核实过的事实（决定谁该改）**：
- `run_command`：完整输出写**系统临时目录**，随时可能被清掉 —— 取回没有保障，必须改；
- `web_fetch`：正文中段被 `substring(0, 2000)` 硬切、只留 `...`，没有任何取回指针 —— 必须改（`CLAUDE.md` 已把它列为既有缺陷实例）；
- `glob_file` / `grep_file` / `read_file`：结果里已经写着取回办法（"call glob_file again with max_results=2N"、"use offset/limit to read more"），属于**可恢复**，优先级最低。

**注意**：`lib/main.dart` 里并没有 `const maxLen = 2000`（初稿与 design 初版都把它当"要删的二次截断"，核实后该常量不存在；相关逻辑是 `search_text_assembly.dart` 的 `maxLen = budget ?? searchTextElisionThreshold` 与 `web_fetch` 分支里的 2000 硬切）。

### D8 `read_spill` 必须是新工具，不能靠 `read_file`

**证据**：`read_file` 走工作区沙箱（`sidecar/src/tools.cpp` 返回 `Access denied: path outside workspace`），而 spill 目录在 `~/.aliasagent/` 下、在工作区之外。

**结论**：新增 `read_spill` 导出 + 工具定义；**不要**为了让它能读而给 `read_file` 开沙箱例外（那会让"工作区限制"这条规范出现洞）。

## Risks / Trade-offs

- **[磁盘增长]** → 随会话删除；内联上限可配；spill 文件是纯文本，压缩后体积可控。
- **[UTF-8 切分错误]** → 用码点边界扫描；新增用例断言切出来的头尾都是合法 UTF-8，且拼接后仍是原文件的一个子序列。
- **[引用被外部删除或篡改]** → `read_spill` 读前校验长度与存在性，失败时返回可见错误（不返回空内容冒充成功）。
- **[旧用例按旧行为写的]** → `command-tool` 的 MODIFIED delta 已整条改写，`sidecar/test/command_tool_test.cpp` 里三条旧断言（`HEAD-MARKER` 必须不存在、`full_output_paths` 存在、未超限时无临时文件）在 tasks 第 6 组里先改红再改绿。
- **[通用截断掐掉引用]** → `_elideOversizedToolResult` 的阈值是 8000 字符而 `preview_chars` 可配。若用户把 `preview_chars` 调到 4000，头尾合计 8000 就会顶到阈值，引用段可能被掐。tasks 3.2 用"把 `preview_chars` 配到 4000 仍能看到 `ref`"这条用例守着。
- **[`read_spill` 变成任意文件读取器]** → 契约要求 `ref` 解析后必须落在 spill 根目录内；tasks 2.6 用"拿 `~/.aliasagent/config.json` 当 ref"这条用例守着。
- **[与压缩的交互]** → spill 只改变"单条工具结果"的体积，不改变压缩阈值；压缩仍按窗口比例触发。

## Migration Plan

1. C++：加 spill 写入（原子写）与 UTF-8 安全切分；`run_command` 改用新信封；导出 `read_spill`。
2. Dart：`_toolDefs` 加 `read_spill` 并在 `_executeTool` 的 `switch` 里加分支；确认 `run_command` 的新信封不会被 `_elideOversizedToolResult`（8000 字符）掐掉引用段；配置读取 `spill.preview_chars`。
3. 测试：先写/改用例到红，再改实现到绿（`tool-execution-tests` 与 `ffi-bridge` 的 delta 已给出判据）。
4. 文档：`Docs/user-guide/tools-command.md` 补"输出怎么交付、怎么读回"；`configuration.md` 补 `spill.preview_chars` 并把两个旧命令键标废弃。
5. 回滚：删掉 spill 目录不影响历史（历史里只存消息文本，不存 spill 引用）；工具结果退回旧信封即可。

## Open Questions

1. **引用形式**：go 绝对路径（`~/.aliasagent/spill/<会话>/<n>.txt`）—— 用户能直接打开查看；同时由 `read_spill` 做"必须在 spill 根目录内"的校验（见 D8 与 tasks 2.6）。逻辑引用（会话 id + 序号）留作以后若要把 spill 搬进别处时的选择。
2. **`limit` 省略时的默认值**：取 `preview_chars × 2`（与内联阈值同源，不新增数）。本稿已把它写进 `ffi-bridge` 的 delta。
3. ~~`web_fetch` 的正文中段省略标记里要不要再给路径~~ → 已定：迁移到 spill 时一并解决（D7 已把它列为"必须改"的第二条）。
