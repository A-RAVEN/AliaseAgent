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

每条流在内存中保留的**字符数** SHALL 有上限；超过上限时 SHALL **保留尾部**并丢弃开头的多余部分。被截断的流 SHALL 把完整内容写入系统临时目录下的一个文件（写入上限另有一个可配置值），返回里 SHALL 给出该文件路径；超过写入上限时 SHALL NOT 写文件，并 SHALL 在截断说明里写明"没有留下完整输出文件"。截断 SHALL NOT 静默发生：返回里的截断字段 SHALL 标明哪条流被截断、原有多少字符、保留了多少字符。

**上限的缺省值 SHALL 与产品代码里既有的工具结果截断阈值对齐（该阈值是 `lib/main.dart` 的 `kToolResultElisionThreshold`，8000 字符）**：发给模型之前还有一道通用的截断，超过该阈值的结果会被掐掉中间只留头尾。工具侧的上限若大于它，工具精心拼好的"截断了、全文在哪"那句话很可能正好落在被掐掉的中间，模型只看到一句"结果被省略"而不知道去哪找全文。因此工具 SHALL 在上限之内就把结果剪好，使发给模型的整段结果不超过该阈值。

#### Scenario: 超长输出保留尾部且标出截断

- **WHEN** 一条命令写出的标准输出明显超过内存上限，且开头的字符与结尾的字符可以区分
- **THEN** 返回的 `stdout` SHALL 含结尾部分、SHALL NOT 含开头部分，截断字段 SHALL 为真并给出原有字符数与保留字符数，返回里 SHALL 给出完整输出文件的路径

#### Scenario: 未超限时不写文件也不标截断

- **WHEN** 命令的输出小于内存上限
- **THEN** 截断字段 SHALL 为假，返回里 SHALL NOT 给出完整输出文件路径，临时目录下 SHALL NOT 新增文件

#### Scenario: 整段结果不超过既有阈值，全文路径一定看得见

- **WHEN** 一条命令同时写出远超上限的标准输出与标准错误，上限取缺省值
- **THEN** 渲染给模型的整段结果 SHALL 不超过 `kToolResultElisionThreshold`，且"完整输出文件在哪"这条信息 SHALL 留在结果里（不得因超长而被通用截断掐掉中间）

#### Scenario: 超过写文件上限时不落文件并如实说明

- **WHEN** 命令输出超过写文件的字节上限
- **THEN** 临时目录下 SHALL NOT 留下该次调用的完整输出文件，返回 SHALL 含截断说明并写明没有完整输出文件

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

命令工具的缺省超时毫秒数、超时上限、每条流在内存里保留的字符上限、写完整输出的字符上限 SHALL 各由一个配置项决定，配置项依次为 `command_timeout_ms`（缺省 120000）、`command_max_timeout_ms`（缺省 600000）、`command_max_output_chars`（缺省 8000，与 `lib/main.dart` 的 `kToolResultElisionThreshold` 对齐）、`command_output_full_chars`（缺省 2000000），写在 `~/.aliasagent/config.json` 的 `agent_types.<名字>` 段。缺失、非数字或非正值 SHALL 回落到缺省值，SHALL NOT 报错、SHALL NOT 让工具不可用；字符上限另有一个下限（1000），配得比它小一律按该下限执行，否则结果里连"截断了、全文在哪"这句话都放不下。

这四个值 SHALL 由发起调用的那一侧在每次调用时随请求一起交给执行侧（执行侧不读配置文件）；请求里缺失或非法的字段 SHALL 在两侧得到同一套缺省值。工具 SHALL 无条件出现在发给模型的工具定义里，SHALL NOT 依赖搜索服务或浏览器栈的可用性。

#### Scenario: 没有配置项时用缺省值

- **WHEN** `agent_types.general` 段里没有这四个键
- **THEN** 工具 SHALL 用 120000 / 600000 / 8000 / 2000000 四个缺省值工作

#### Scenario: 非法值回落到缺省值，过小的字符上限被抬到下限

- **WHEN** 某个键写成零、负数或文字，或把字符上限配成 200（小于下限 1000）
- **THEN** 非法值 SHALL 回落到各自的缺省值，200 这一个 SHALL 按 1000 执行（SHALL NOT 因为配得太小而丢掉截断说明与全文路径），工具 SHALL 仍能执行命令

#### Scenario: 配置的值真的生效（配置改小 → 实际输出跟着变短）

- **WHEN** 把每条流的内存上限配成一个明显更小的值，再执行一条输出超过它的命令
- **THEN** 返回的 `stdout` 长度 SHALL 不超过该配置值，且截断字段为真；把配置留在缺省值时同一条命令 SHALL 不被截断 —— 两次结果的差别证明这个值真的走到了执行侧，而不是只被解析出来又丢掉

#### Scenario: 超时上限参与计算（单测层判定，不靠真等十分钟）

- **WHEN** 分别给一个小于上限的调用超时与一个大于上限的调用超时
- **THEN** 生效的超时 SHALL 分别等于前者与上限值 —— 这条在单测层断言"生效值怎么算出来的"，SHALL NOT 以"真的等到超时"作为判据（缺省上限是 10 分钟，那样跑不起）

