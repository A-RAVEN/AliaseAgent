# command-tool Specification

## Purpose
TBD - created by archiving change add-command-tool. Update Purpose after archive.
## Requirements
### Requirement: 命令以参数数组递进操作系统，外层不做第二层解析

工具 SHALL 把命令字符串作为 PowerShell `-Command` 的**单个**参数交给操作系统，起进程时的 argv 为 `[<PowerShell 可执行文件>, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", <编码前缀> + <命令字符串>]`，其中**第 6 个元素是一整个字符串**，SHALL NOT 被拆成多个参数。argv 转成命令行字符串 SHALL 由 `subprocess` 的命令行拼装函数完成（本次改造后它按宽字符命令行启动；无论字节版还是宽字符版，对同一组 argv 的分段结果 SHALL 一致）；SHALL NOT 在 PowerShell 之外再套一层 `cmd /c`，也 SHALL NOT 由工具自己去给命令字符串额外加一层引号。命令的引号、管道、重定向 SHALL 只在 PowerShell 这一层被解析一次。

#### Scenario: 命令字符串整段到达 PowerShell，不被外层拆开

- **WHEN** 工具收到命令字符串 `Write-Output 'a b | c > d'`
- **THEN** PowerShell 收到的 `-Command` 参数就是这一整段（含其中的空格、竖线与大于号），实际输出为 `a b | c > d`；若外层存在第二层解析，竖线与大于号会先被解释成管道与重定向，输出不可能等于这一整段

#### Scenario: 起进程的 argv 形状可核

- **WHEN** 检查工具起进程时构造的 argv
- **THEN** 它的前五项 SHALL 依次为 PowerShell 可执行文件、`-NoLogo`、`-NoProfile`、`-NonInteractive`、`-Command`，第六项 SHALL 是"编码前缀 + 命令字符串"拼成的**单个**字符串，数组长度 SHALL 为 6

#### Scenario: 命令字符串里带引号与结尾反斜杠时不改变命令

- **WHEN** 命令字符串本身含单引号、双引号或以反斜杠结尾的片段
- **THEN** 真正被 PowerShell 执行的命令 SHALL 与调用方给的字符串逐字符相同（argv 形状的断言只能证明我们递出去的形状，因此这一条 SHALL 靠"命令的实际效果"来判定，例如让命令把收到的内容原样输出并与期望逐字符比对）

### Requirement: 方言固定为 PowerShell，可执行文件按固定顺序解析

工具 SHALL 只执行 PowerShell 方言的命令，SHALL NOT 提供 bash 或 cmd 方言，SHALL NOT 做方言翻译，SHALL NOT 让调用方选择解释器。可执行文件 SHALL 按固定顺序解析：① `%ProgramFiles%\PowerShell\7\pwsh.exe`；② `%ProgramFiles(x86)%\PowerShell\7\pwsh.exe`；③ 环境变量 `PATH` 里能找到的 `pwsh.exe`；④ `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`。四处都不可用时 SHALL 返回可读的失败说明，SHALL NOT 静默换成别的解释器。工具说明文字 SHALL 写明：路径用 Windows 原生形式、环境变量用 `$env:NAME` 读取。

#### Scenario: 本机没有 PowerShell 7 时落到 5.1

- **WHEN** 三个 `pwsh.exe` 候选位置都不存在，而 `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 存在
- **THEN** 工具 SHALL 用该 5.1 可执行文件执行命令并返回其输出；调用方看到的是一份可用的结果，不是"解释器缺失"

#### Scenario: 四处都不可用时报错而不是换解释器

- **WHEN** 四个候选位置都不存在
- **THEN** 工具 SHALL 返回失败说明，指明找不到 PowerShell 以及找过哪些位置；SHALL NOT 改用 `cmd.exe`、`bash` 或其它解释器执行这条命令

### Requirement: 文本输出钉成 UTF-8，颜色与翻页器被禁掉

交给 `-Command` 的字符串 SHALL 以固定前缀开头，前缀为 `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [System.Text.UTF8Encoding]::new($false); `，且 SHALL 以 `; ` 与调用方的命令接续在同一行，使 PowerShell 报错时报告的行号仍对应调用方命令的行号。前缀与命令之间 SHALL NOT 插入换行。子进程环境 SHALL 注入 `NO_COLOR=1`、`PAGER=cat`、`GIT_PAGER=cat`，并 SHALL 保留调用方进程已有的**全部**环境变量（注入是**并入**，SHALL NOT 用一个只含注入项的环境块替换掉继承来的那一份）。变量名 SHALL 按 Windows 的规则做大小写不敏感的覆盖，同名变量 SHALL NOT 在同一个环境块里出现两次。

#### Scenario: 中文输出不变成乱码

- **WHEN** 命令为 `Write-Output '中文测试'`
- **THEN** 返回的 `stdout` SHALL 含有 `中文测试`；字节序列被按 UTF-8 解码后 SHALL 等于这五个汉字，SHALL NOT 出现替换字符或问号

#### Scenario: 前缀不改变报错行号

- **WHEN** 命令为三行，第二行故意写错
- **THEN** PowerShell 报告的出错行号 SHALL 仍是第 2 行（前缀接在第一行之后、不占独立行）

#### Scenario: 颜色与翻页器被禁掉

- **WHEN** 命令把 `NO_COLOR`、`PAGER`、`GIT_PAGER` 各打印一次
- **THEN** 三者 SHALL 分别等于 `1` / `cat` / `cat`

#### Scenario: 注入这三项不会把继承来的环境弄丢

- **WHEN** 命令报告自己的环境里是否有 `PATH`，以及能否按名字找到 `git` 或 `python` 这类真实命令
- **THEN** `PATH` SHALL 仍然存在（与调用方进程的 `PATH` 同量级），且这些命令 SHALL 仍能按名字解析到 —— 注入实现若把整个环境块替换成"只有注入项的一块"，这一条 SHALL 失败

### Requirement: 一次调用一个进程、不保留状态，工作目录由参数决定

每次调用 SHALL 起一个全新的 PowerShell 进程；工作目录、变量、函数 SHALL NOT 跨调用保留。工作目录 SHALL 由本次调用的 `workdir` 参数决定，缺省为当前工作区；相对路径 SHALL 相对当前工作区解析；指向工作区之外时 SHALL 拒绝并返回可读的失败说明，SHALL NOT 默默改用工作区。**拒绝越界是"参数填写规范"的一致性要求，不是安全边界**：命令本身仍可访问工作区之外的路径（本工具没有权限模型）；这道检查只为与既有文件工具的口径一致，并让填错的目录当场得到明确报错。工具说明文字 SHALL 写明"要换目录请用 `workdir`，不要用 `cd`"。

#### Scenario: cd 不跨调用生效

- **WHEN** 先执行 `cd C:\`，再在下一次调用里执行 `Get-Location`
- **THEN** 第二次调用报告的当前目录 SHALL 仍是工作区（不是 `C:\`），证明两次调用之间没有共享状态

#### Scenario: workdir 决定本次的工作目录

- **WHEN** 调用时给出 `workdir` 指向工作区内的一个子目录，命令为 `Get-Location`
- **THEN** 报告的当前目录 SHALL 是该子目录；若实现忽略了 `workdir`、或无论传什么都拒绝，这一条 SHALL 失败

#### Scenario: 工作区之外的工作目录被拒绝

- **WHEN** `workdir` 解析后落在当前工作区之外
- **THEN** 工具 SHALL 返回失败说明，指明该目录不被允许，且 SHALL NOT 执行这条命令

### Requirement: 返回结构与退出码

成功执行（无论命令自身是否以非零码结束）时，工具 SHALL 返回 `ok` 为真，并包含：`exit_code`（命令的退出码）、`stdout`、`stderr`、`timed_out`（本次是否因超时被终止）、`duration_ms`（实测耗时），以及截断字段。**非零退出码 SHALL NOT 被当作工具失败**：命令跑了、跑完了、退出码是几，都算工具成功执行。只有工具自身无法执行时才返回 `ok` 为假，错误文本 SHALL 是中文可读说明，SHALL NOT 是内部错误码或英文堆栈。标准输出与标准错误 SHALL 分开收集、分开返回，SHALL NOT 合并成一条。

#### Scenario: 非零退出码仍是成功执行

- **WHEN** 命令为 `exit 3`
- **THEN** 返回的 `ok` SHALL 为真、`exit_code` SHALL 为 3、`timed_out` SHALL 为假

#### Scenario: 标准输出与标准错误分开

- **WHEN** 命令为 `[Console]::Out.Write('o'); [Console]::Error.Write('e')`
- **THEN** 返回的 `stdout` SHALL 含 `o` 且不含 `e`，`stderr` SHALL 含 `e` 且不含 `o`

#### Scenario: 无法执行时返回可读的中文说明

- **WHEN** 工具自身无法起进程（例如解释器缺失）
- **THEN** 返回的 `ok` SHALL 为假，`error` SHALL 是中文可读说明；SHALL NOT 返回英文异常文本或内部编号

### Requirement: 输出有界、只保留尾部、截断可见

每条流的**完整输出** SHALL 先写入 spill 文件（位置见 `tool-output-spill` 能力：`~/.aliasagent/spill/<会话>/<6 位序号>-<流>.txt`，**每条流一个文件**，原子写），写成功之后才决定返回什么。

- 全文长度 ≤ `preview_chars × 2` ⇒ 返回里 SHALL 内联全文；
- 全文长度 > `preview_chars × 2` ⇒ 返回里 SHALL 内联**头部前 `preview_chars` 个字符**与**尾部后 `preview_chars` 个字符**，中间段省略，并 SHALL 给出 spill 引用、总字节数、省略字节数。

`preview_chars` 默认 1000（用户 2026-10-25 决定），配置键为 `spill.preview_chars`。

**截断 SHALL NOT 静默发生**：返回里的截断字段 SHALL 标明哪条流被省略、原有字节数、省略了多少、以及引用。

渲染给模型的整段结果 SHALL 不超过既有阈值（`kToolResultElisionThreshold`，8000 字符）：信封本身要足够短，引用与省略量这两项 SHALL 落在结果的头尾可见区域内，SHALL NOT 因通用截断被掐掉中间。

**这条 8000 字符是"通用截断的触发阈值"，不是"任何配置下都装得下"的承诺**：`preview_chars` 配到 4000 时，头 + 尾就已经是 8000 字符，整段结果必然超过阈值、必然被通用截断（初稿把这两条写成"既不超过 8000、又要头尾各 4000"，自相矛盾）。所以要求落在**引用与省略量必须出现在被保留下来的那一侧**（代码里它们固定在正文最后一行），而不是"整段不许超 8000"。

> **2026-10-25 修改**：本条由 `spill-large-tool-output` 改写 —— 完整输出不再写系统临时目录，内存里保留的也不再只是尾部。以下是改写后的完整条文。

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

### Requirement: 超时按毫秒计、有上限、终止整棵进程树

工具 SHALL 接受可选的超时毫秒数；未给出时 SHALL 取配置项 `command_timeout_ms`；给出的值非数字或不为正时 SHALL 按缺省值处理；超过 `command_max_timeout_ms` 时 SHALL 按该上限执行。**超时的判定精度 SHALL 是毫秒**：给出 500 毫秒时 SHALL 按 500 毫秒判定，SHALL NOT 因为下游只支持整秒而被截断成 0 或 1 秒。到点后 SHALL 终止该进程**以及它拉起的全部子进程**，并在返回里把 `timed_out` 标为真。超时终止的调用 SHALL 仍返回已经收集到的输出，SHALL NOT 丢掉现场。

#### Scenario: 超时被终止且子进程不残留

- **WHEN** 命令启动一个长于超时的子进程（例如再起一个 PowerShell 睡很久），超时设为较短的毫秒数
- **THEN** 调用 SHALL 在超时附近返回、`timed_out` SHALL 为真，且该子进程在调用返回后 SHALL 不复存在（按进程标识核对，不残留）

#### Scenario: 亚秒级超时按毫秒判定

- **WHEN** 超时给成 500 毫秒，命令是一条必然跑得比它久的命令
- **THEN** 返回的 `timed_out` SHALL 为真，且实测耗时 SHALL 落在秒级以下的量级（证明这个数没有被截断成 0 而立即触发、也没有被抬成整秒）

#### Scenario: 非法超时值按缺省值处理

- **WHEN** 超时给成零、负数或非数字
- **THEN** 工具 SHALL 不报错，按配置的缺省值执行

#### Scenario: 超时后仍带出已收集的输出

- **WHEN** 命令先写出一段可识别的文本、随后陷入长时间等待而被超时终止
- **THEN** 返回的 `stdout` SHALL 含那段文本，`timed_out` SHALL 为真

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
- **AND** 这条场景 **不** 要求整段结果仍不超过 8000 字符：头尾各 4000 已经正好 8000，撞上通用截断是预期行为；此时 SHALL 只要求 spill 引用仍留在结果里（见 `输出有界、只保留尾部、截断可见` 那条的说明）

#### Scenario: 两个废弃键不再影响行为

- **WHEN** 用户在 `agent_types.general` 段里仍写着 `command_max_output_chars` / `command_output_full_chars`
- **THEN** 解析 SHALL 给出各自的缺省值并打一行废弃告警，实际交付形状 SHALL 与不写这两个键时完全相同

#### Scenario: 超时上限参与计算（单测层判定，不靠真等十分钟）

- **WHEN** 分别给一个小于上限的调用超时与一个大于上限的调用超时
- **THEN** 生效的超时 SHALL 分别等于前者与上限值 —— 这条在单测层断言"生效值怎么算出来的"，SHALL NOT 以"真的等到超时"作为判据（缺省上限是 10 分钟，那样跑不起）


