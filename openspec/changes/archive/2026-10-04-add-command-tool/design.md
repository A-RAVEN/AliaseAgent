## Context

助手现在有 7 个无条件可用的工具（`read_file`、`write_file`、`edit_file`、`list_dir`、`get_current_time`、`glob_file`、`grep_file`）外加两组按条件注册的工具（搜索 provider 可用时的 `web_search` **与 `web_fetch`** —— 这两个同在一个条件块里；浏览器栈可用时的 4 个 `browser_*`）。**其中没有一个是"把命令跑起来"** —— 能读能写，不能验证。

要接的执行器已经存在：`sidecar/src/subprocess.cpp` 的 `subprocess::run(argv, opts)`，支持工作目录、超时、超时后杀整棵进程树（Job Object）、stderr 单独收集、stdout 可选流式。`glob_file` / `grep_file`（ripgrep）、`web_fetch`（python 工作进程）、`browser_available`（一次性探针）都走它。

参考实现是本机已安装的 DeepSeek Harness，包的根目录是 `C:\Users\76956\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\`（注意 `@deepseek-ai` 出现了两次：外层是 dsh 这个包自己，内层才是各个能力包）。它把这个能力拆成两个工具包 `dsh-tool-pwsh` 与 `dsh-tool-bash`，执行器分别在 `dsh-pwsh-local` 与 `dsh-bash-local` 里。本设计里凡是"照 DSH 的做法"的论断，依据是这几处的源码与中文文档，不是回忆：

- `dsh-bash-local\lib\index.js` 的 `run(spec)`：`return this.runArgv(spec, ["bash","-c",spec.command])` —— 命令字符串作为**一个** argv 元素。**注意归错包是常见错**：`dsh-tool-bash` 只是工具外壳，它走的是 `ctx.shell.run(...)`，真正的 argv 构造在 `dsh-bash-local` 里。
- `dsh-pwsh-local\lib\index.js` 的 `argv(spec)`：`[pwshPath, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", ENCODING_PREAMBLE + spec.command]`。
- 同文件 `ENCODING_PREAMBLE` 的注释原文说明：收集端按 UTF-8 解码输出字节，而 Windows PowerShell 5.1（最后的兜底可执行文件）默认按控制台/OEM 码页写出，会弄乱非 ASCII 输出；pwsh 7 默认 UTF-8 不受影响；前缀用 `; ` 接在第一行之后，好让 PowerShell 的报错行号保持准确。
- `dsh-subprocess-local\README.zh.md`：收集模式在内存里只保留一条流的最后 `maxBytes`（"错误与最终结果通常聚集在末尾"），超出部分可写 spill 文件，读取越过保留尾部时标记为有损并指向 spill 文件。
- `dsh-pwsh-local` 的 `ENV_OVERRIDES`：`NO_COLOR=1`、`PAGER=cat`、`GIT_PAGER=cat`。

**本机事实（已实测，两处数字不一样，别混）**：
- `pwsh`（PowerShell 7）**没有安装** —— `C:\Program Files\PowerShell\7\pwsh.exe`、`C:\Program Files (x86)\PowerShell\7\pwsh.exe`、`%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe` 三处都不存在，`where pwsh` 无输出；可用的是 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`（5.1.26100.9444）。因此编码前缀不是可选的美化，而是**实际生效路径上的必需项**。
- **控制台码页与 ANSI 码页不是一回事**：`chcp` 报 `65001`，但注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage` 的 `ACP` 是 **1252**、`OEMCP` 是 437，Windows PowerShell 5.1 里 `[System.Text.Encoding]::Default.CodePage` 也是 **1252**。`CreateProcessA` 解释命令行用的正是 ANSI 码页（不是控制台码页），而 `sidecar/src/subprocess.cpp` 目前就是把 UTF-8 字节直接喂给 `CreateProcessA` —— 也就是说，**非 ASCII 的命令行与工作目录在本机今天就是坏的**（传到子进程里会变成 `?` 或乱码），不需要等到换一台 936 的机器。这一条把下面 D6 的性质从"预防将来"改成"修当前的缺陷"。

## Goals / Non-Goals

**Goals**

- 模型能执行一条命令，拿到退出码、标准输出、标准错误，并据此判断自己刚才的改动对不对。
- 命令怎么递进操作系统这件事是**确定的、可复核的**：外层不做二次解析，不在三种 shell 的引号规则之间猜。
- 中文输出、中文路径不乱码。
- 输出有上限且截断可见；命令卡住能被终止，且连同它拉起的子进程一起终止。

**Non-Goals**

- 不做常驻交互式会话（每次调用一个新进程，没有跨调用的 cwd 与变量）。参考实现里这是另一个包（`dsh-tool-pwsh-persistent`），本变更不做。
- 不做后台任务（`run_in_background` 那一套要配一个任务运行时与三个控制工具，本变更不做）。
- 不做权限分层与确认弹窗（本仓库当前没有权限模型；见 D9）。
- 不做 bash / cmd 方言，不做方言翻译，不让调用方选 shell。
- 不合并标准输出与标准错误（两条流分开收集、分开返回）。
- 不做输出的流式进度显示（命令跑完才返回；长命令的输出要等结束）。

## Decisions

### D1 一种方言一个工具：`run_command` 固定为 PowerShell

**决定**：只做一个工具，名字 `run_command`，执行的是 PowerShell 命令；工具说明文字里明确写"这是 PowerShell 方言：路径写 `C:\...`，环境变量读 `$env:NAME`"。不做 `cmd`、不做 bash、不做方言翻译。

**为什么不做"通用命令工具"**：一条命令字符串必须由某一层来解析。若工具自称通用，模型就可能写出 `dir /b` 这类 cmd 写法或 `ls -la` 这类 bash 写法，而实际解析它的是 PowerShell —— 失败方式会是"命令语法错"这种看上去像模型写错、实际是层与层对不上的问题。给工具一个明确方言，等于把这一层的不确定性消掉。

**依据**：参考实现正是这么分的（`dsh-tool-pwsh` 与 `dsh-tool-bash` 两个包，各自 README 明写"两者之间没有翻译"）。本仓库的宿主平台是 Windows（`CLAUDE.md` 开头即 Flutter Windows 桌面应用），所以只需要 PowerShell 那一个。

**被否决的替代方案**：`cmd /c` 当默认（引号规则最脆，且能力弱于 PowerShell）；`bash` 当默认（本机 `bash` 这个名字指向 WSL 的启动器 —— 已实测 `C:\Windows\System32\bash.exe` 的文件描述是 "Microsoft Bash Launcher"，而项目自己的 `test/smoke/*.sh` 会因 WSL 里没有 `sqlite3` / `powershell` 而直接中断，真实的处置记录在 `openspec/changes/archive/2026-10-03-add-compaction-status-indicator/tasks.md`；拿 `bash` 当默认会把用户带进一个错的 Unix 环境）。

### D2 命令字符串作为**单个** argv 元素交给 `-Command`，外层不套第二层解析

**决定**：最终起进程的 argv 是

```
["C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
 "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "<编码前缀><模型给的命令>"]
```

命令字符串整体是 `-Command` 后面的那**一个**参数，由 `sidecar` 现有的 `build_command_line` 按引号规则拼好；**不额外套 `cmd /c`**。

**为什么**：`CreateProcess` 的命令行是一个字符串，必须有人把 argv 拼成它。拼装这一层无法避免，但可以做到**只有一层**：`-Command` 收到的字符串由 PowerShell 自己解析，模型写的引号、管道、重定向都只在这一层起作用，不会先被别的解析器吃掉一次。一次可直接复核的对照（2026-10-03 在本机实跑）：同一串 `a b | c > d`，按参数数组传给 `cmd /c` 时原样到达（python 打印出 `'a b | c > d'`），而把它拼进命令行再让 `cmd` 解析时被当成管道（报 `'c' is not recognized as an internal or external command`）。

**「按数组传」到底指什么，别混**：指的是**我们的 C++ 代码到操作系统**这一段用 argv 数组（`subprocess::run` 的入参就是 `std::vector<std::string>`），而不是"模型传数组"。模型传的是命令字符串，这是参考实现的做法，也是本设计的做法。

### D3 编码前缀 + 环境变量：钉住 UTF-8，禁掉颜色与翻页器

**决定**：真正交给 `-Command` 的字符串 = 固定前缀 + 模型的命令，前缀为：

```
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [System.Text.UTF8Encoding]::new($false); 
```

同时给子进程注入 `NO_COLOR=1`、`PAGER=cat`、`GIT_PAGER=cat`。

**这三条环境变量要动执行器的接口，这是本变更里第二处改既有代码**：`sidecar/src/subprocess.h` 的 `Options` 目前只有 `stdin_data` / `cwd` / `timeout_seconds` / `on_stdout_chunk` 四个字段，`CreateProcessA` 的 `lpEnvironment` 传的是 `nullptr`（即继承父进程环境），**没有注入环境变量的入口**。做法是在 `Options` 上加一个"额外的环境变量"字段（键值对），实现时在 Windows 上把父进程环境块取出、并入这几项后传给 `CreateProcessW`；POSIX 分支同理合并进 `execv` 的环境。既有调用方不传这个字段时行为与今天完全一致（这一条要有用例守住）。

**为什么不用 PowerShell 命令里的 `$env:NO_COLOR = '1'` 代替**：那只能影响 PowerShell 自己与被它启动的子进程，且要插在命令前面、与调用方的命令抢同一行、影响行号；而 `git log` 这类命令是 PowerShell 启动的外部程序，环境变量从进程环境继承最直接。参考实现也是走执行器的环境覆盖，不是在命令里赋值。

**"完整继承系统环境变量"这件事现在就成立，别把它做成需要额外努力的目标（已实测）**：Windows 上 `CreateProcess` 的 `lpEnvironment` 传 `nullptr` 时，新进程拿到的是**调用方进程的完整环境块**，而应用进程的环境又继承自启动它的进程（通常是资源管理器）——那里面已经包含系统级变量（`SystemRoot`、`windir`、`ComSpec`、`PATHEXT`…）与用户级变量（`PATH`、`TEMP`、`USERPROFILE`…）。`sidecar/src/subprocess.cpp` 现在传的正是 `nullptr`，所以"完整继承"不是要争取的东西，而是现状。

实测证据（2026-10-03，用 `sidecar_tests` 起一个子进程读自己的环境）：父进程里临时设的变量在子进程里读到了；`PATH` 长度 1513 字符且头部是 `C:\VulkanSDK\…` 这类系统内容；`SystemRoot` 为 `C:\Windows`。另外确认父进程的 `PATH` 里 `flutter` / `dart` / `git` / `python` / `cmake` 都能按名字解析到 —— 这正是命令工具要的东西。

**因此实现上要守住的只有两条**：
1. **注入 = 并入，不是替换**。要加 `NO_COLOR` 这类变量时，先取父进程的环境块（`GetEnvironmentStringsW`），把要注入的键值**并入**，再把合并后的块传给 `CreateProcessW`。把"只有这三项的块"传下去会把 `PATH` 一起抹掉 —— 那样 `flutter`、`git`、`python` 全都找不到，是这套设计里最容易犯且最难查的错。
2. **键名按 Windows 的规则比较**：环境变量名大小写不敏感（`Path` 与 `PATH` 是同一个变量）。并入时要做大小写不敏感的去重与覆盖，不能既留旧的又加新的 —— 同一个块里出现两个同名变量时，新进程那边取哪个是未定义行为。

**不注入的时候仍然传 `nullptr`**（最干净的继承路径），只在确实要注入时才自己拼块。另外**不读注册表去"重新取一遍全局变量"**：那是与所有正常 Windows 程序都不一样的做法，还会漏掉启动后变更与登录会话相关的东西；继承父进程就是标准做法。

**为什么**：本机实际用的可执行文件是 Windows PowerShell 5.1，它默认按控制台/OEM 码页写输出，而收集端按 UTF-8 解码字节 —— 不钉就会乱码。这条不是推测，参考实现的源码注释就是为这件事写的（`dsh-pwsh-local\lib\index.js` 里 `ENCODING_PREAMBLE` 上方那段，原意：收集端按 UTF-8 解码，而 Windows PowerShell 5.1 默认写控制台/OEM 码页，会弄乱非 ASCII 输出）。前缀用 `; ` 接续在第一行之后，是为了不改变 PowerShell 报错时的行号。`PAGER=cat` 防的是 `git log` 这类命令调起翻页器把进程挂住，`NO_COLOR=1` 防的是颜色转义码污染返回给模型的文本。

**前缀是给 PowerShell 用的，不是给被执行的程序用的**：它只影响 PowerShell 自己写出的文本流。被执行的程序（`flutter`、`ctest`）自己的输出编码由它自己决定，本变更不改这一点。

### D4 输出只保留尾部，超出上限写进系统临时目录并告知路径

**决定**：标准输出与标准错误**分别**收集。每一条流在内存里保留的**字符**上限缺省 8000（可配置，另有 1000 的下限）；超出时**保留尾部**并把该流的完整内容写进系统临时目录下的一个文件，返回里带上该文件路径。截断与路径都写进返回给模型的文本里，格式为 `[output truncated; full output: <路径>]`；某条流为空则渲染 `(no output)`。

**为什么留尾部不留头部**：编译器与测试框架的结论（`error: ...`、`N tests failed`、汇总行）几乎都堆在末尾；留头部会把结论丢掉。参考实现的收集端也是这么做的（`dsh-subprocess-local\README.zh.md`：在内存里保留最后 `maxBytes`，"错误与最终结果通常聚集在末尾"）。

**为什么还留全文**：只留尾部会让"到底哪一行开始错的"变成不可查。写临时文件比丢内容好，且不往仓库里落任何东西（仓库规则要求临时产物不许留在仓库）。

**为什么上限取 8000 而不是更大（这一条是把首次评估发现的冲突改掉的结果）**：发给模型之前，`lib/main.dart` 里还有一道通用截断 `_elideOversizedToolResult`，阈值是 `kToolResultElisionThreshold = 8000` 字符，做法是**掐掉中间、只留头尾**。若工具侧的上限大于它（原先写的是 100000 字节），一条长输出会在工具里先被剪成"尾部 + 全文路径"，紧接着又被那道通用截断剪一次 —— 而"全文在哪"这句话正好处在会被掐掉的中间，模型最后看到的可能只剩一句"结果被省略"，既没看到结论也不知道去哪找全文。上限取 8000 之后，整段结果落在那道阈值之内，剪裁只发生一次、由工具自己做，通知完整可见。**测得到**：规范里那一条"整段结果不超过既有阈值、全文路径一定看得见"的场景就是为它写的。

### D5 超时用毫秒、有默认值与上限，到点杀整棵进程树

**决定**：参数 `timeout_ms` 可选，缺省取配置项 `command_timeout_ms`，超过上限 `command_max_timeout_ms` 时按上限截断；到点后终止该进程**及其拉起的全部子进程**。返回里带 `timed_out` 标记，渲染成 `[timed out after <N>ms]`。

**执行器要从整秒改成毫秒**：`subprocess.h` 的 `Options` 现在是 `int timeout_seconds = 30`，`subprocess.cpp` 用整秒比较 elapsed。一条命令的超时是模型给的毫秒数（规范里有"较短的毫秒数"这类场景），整秒装不下它 —— 传 500 毫秒会被截断成 0 而立刻触发超时。所以 `Options` 增加一个毫秒字段，既有调用方不传时仍按原来的整秒语义工作（有既有用例守着）。参考实现也是毫秒入口（`timeoutMs`），并在执行器里有自己的缺省值与上限。

**为什么杀整棵树**：`flutter test`、`cmake --build` 都会再拉起子进程；只杀直接子进程会留下孤儿继续占着文件锁（本仓库的浏览器工作进程就踩过这一类问题）。执行器已经用 Job Object 做到这一点（`subprocess.cpp` 里 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 与 `AssignProcessToJobObject`），并且对"宿主本身已在某个 job 里"这种失败情况有 `TerminateProcess` 兜底。

### D6 `subprocess` 的 Windows 启动改走宽字符接口（本变更的前置修复）

**决定**：把 `sidecar/src/subprocess.cpp` 的 Windows 启动从 `CreateProcessA` 改成 `CreateProcessW`：命令行按 UTF-8 → UTF-16 转换后用宽字符命令行启动，工作目录同样用宽字符版本。字节层面的引号规则（`quote_arg` / `build_command_line`）逻辑不变，只是加一个宽字符版本。

**为什么必须做**：`CreateProcessA` 使用**进程当前的 ANSI 码页**解释命令行与 `lpCurrentDirectory`。本机的 ANSI 码页实测是 **1252**（注册表 `ACP`，`[System.Text.Encoding]::Default.CodePage` 同值），而 `subprocess.cpp` 把 UTF-8 字节直接交给它 —— **非 ASCII 的命令行与工作目录在今天这台机器上就是坏的**，不用等换成 936 的机器。失败形态还特别难查：「命令跑了但文件找不到」「参数里多出问号」。工作目录参数尤甚：模型完全可能把工作目录指到一个含中文的路径。

**为什么不选"限制命令必须是 ASCII"**：那是把缺陷改写成使用限制。中文路径在本仓库是常见情况（用户目录、项目路径都可能含中文），工具在这种地方不能用等于没做。

**一处必须先取证的边界**：`build_command_line` 按 `CommandLineToArgvW` 的规则拼引号，其中结尾反斜杠那一条已经有用例（`subprocess_test.cpp` 里名为 `subprocess: trailing backslash inside a quoted arg is doubled` 的用例），但它**只断言拼出来的字符串**，没有核对 `CommandLineToArgvW` 的真实解释；**连续反斜杠**与**中文参数**两处则没有任何用例。宽字符改造会把同一套规则用在更长的命令上，所以先写探针，把三件事一次核清：①以单个反斜杠结尾的参数、②连续反斜杠的参数、③含中文的参数，各自经 argv 传到子进程后是否逐字节一致。**③ 的结果必须如实记录**：如果非 ASCII 参数在修好宽字符启动之后仍然不能原样到达（例如子进程本身按 ANSI 读命令行），那工具对中文参数的支持程度就要按实测写进用户文档的已知限制，而不是在规范里先假定它能用。实测结论写进 `sidecar/test/subprocess_test.cpp` 的注释与用例；若与现有写法不一致，先修引号规则（属于本次前置修复的范围），不许带着未核实的假设继续。

**影响面与不变量**：`subprocess::run` 的改动只落在 Windows 启动那一处；调用方（`web_fetch`、`glob_file`、`grep_file`、浏览器探针）的入参与返回都不变，`subprocess_test.cpp` 里既有的行为断言必须继续全绿。这条同时修好了走 `subprocess::run` 的既有调用方在 ANSI 码页下传中文参数的问题。

**一处不修但必须记账的地方**：`sidecar/src/browser.cpp` 里的 `start_worker()` **自己另起了一套进程创建**（另一处 `CreateProcessA`，不走 `subprocess::run`），所以浏览器工作进程的命令行与工作目录不受本次改造保护。本变更不改它（改它要把那一段也搬到宽字符接口上，属于浏览器工具的范围），但要在设计里写明、并记进 `Docs/known-bugs.md`：如果哪天 Playwright 或工作脚本的路径含非 ASCII 字符，那里仍然会坏。

### D7 五个配置项，走既有的 `agent_types` 解析路径

**决定**：在 `agent_types.<名字>` 段新增四个可选项，缺省值如下：

| 配置键 | 默认值 | 含义 |
| --- | --- | --- |
| `command_timeout_ms` | 120000 | 命令缺省超时毫秒数 |
| `command_max_timeout_ms` | 600000 | 命令超时的上限；给得比它大就按它执行 |
| `command_max_output_chars` | 8000 | 每条流在内存里保留的字符上限（下限 1000，与 `lib/main.dart` 的 `kToolResultElisionThreshold` 对齐） |
| `command_output_full_chars` | 2000000 | 写临时文件的完整输出上限，超过则不写文件、只标截断 |

缺省值必须经产品代码的解析路径（`lib/models/agent_type_config.dart`，与 `compaction_threshold_percent` 同样的读取与回落方式），非法值回落到缺省。用户文档里出现这四个键时，`test/unit/user_docs_test.dart` 会去解析路径里核对它们确实存在。

**这四条判据测得到哪里、测不到哪里，如实写明**：`command_max_output_chars` 与 `command_output_full_chars` 有"配置改小 → 实际输出变短"这种直接可观察的判据；`command_timeout_ms` 与 `command_max_timeout_ms` 没有同等强度的判据 —— 要让"超时上限真的生效"可观察，得让一条命令真的跑过上限（缺省上限是 10 分钟），代价太大。所以这两个键的判据退到**单测层**：断言"解析出的值真的被用来算生效超时"（给一个明确小于上限的调用值，断言生效值等于它；给一个大于上限的值，断言生效值被压到上限），而不是靠跑一条 10 分钟的命令。这一点要在交付说明里如实标注，不许说成"已在真实环境验证"。

**这四个值怎么到达真正执行命令的 C++ 层**（这一条不写清就会出现"配了没反应"）：`run_command` 的请求 JSON 由 Dart 侧组装，四个值作为请求字段随每次调用一起传下去（与 `grep_file` 分支把 `max_results` 拼进请求同一个套路）。C++ 侧**不读配置文件**（sidecar 里本来就没有读 `config.json` 的代码），只认请求里的字段；字段缺失或非法时用与 Dart 侧一致的缺省值兜底。这样"配置改了真的生效"有一条完整的、可以被集成测试穿过的路径。

### D8 前台执行，放在 worker isolate 里，界面不卡

**决定**：`run_command` 在 Dart 侧走 `sidecar_bridge.dart` 里既有的 worker isolate 通道（`web_fetch` / `browser_*` 用的同一个），不新增机制。isolate 侧的等待时长按"命令超时 + 缓冲"给，真正的超时判定仍在 sidecar 里（由执行器杀进程树）。

**为什么**：`_executeTool` 里的其他工具是同步 FFI 调用（"run on main isolate — they're fast, local calls"），一条能跑几分钟的构建命令若照此办理会把界面冻住。既有通道已经把这件事解决过了，照用即可。

**这一条不写进规范**：它是实现方式，不是可观察的行为要求；"界面不卡"没有一条便宜且稳定的自动断言（widget 测试里跑真命令既慢又脆）。规范的验收对象是"命令跑了、结果对了"，界面响应性靠真实环境验收那一步（第 8 组的人工观察）兜底，如实标注为人工检查，不假装它被自动化覆盖了。

### D9 不做确认弹窗与权限分层（明写的取舍）

**决定**：模型调用即执行，不加确认步骤。

**为什么**：本仓库当前没有权限模型，也没有任何既有工具（包括 `write_file`、`edit_file`）在改动磁盘前征求确认；只对这一个工具加一道确认，既与现状不一致，也会把"跑一次测试"变成每次都要点一下的负担。代价是明写的：**模型可以在工作目录下执行任意命令**，命令的来源是用户的对话与配置里给定的模型。工具的说明文字里写清这一点，让模型知道自己在真实执行。

### D10 工具无条件可用（如实照现状写）

**决定**：`run_command` 与 `read_file`、`glob_file`、`grep_file` 一样，无条件出现在工具定义里，不挂在搜索 provider 或浏览器栈的可用性判断下。

**已核实的既有缺陷（不在本变更修，但要在本变更里记账）**：配置里的 `agent_types.<名>.tools` 列表被解析、被序列化，但**全 `lib/` 范围内没有一处读它来过滤工具定义**（搜 `\.tools\b` 只命中 `agent_type_config.dart` 自己的字段定义与 `toJson`；`grep_file` 分支里那些 `toolsJson` 是另一回事）。因此"配了 tools 白名单"目前不产生任何效果。这是既有行为缺陷，与本工具无关；本变更把它记进 `Docs/known-bugs.md`（**这是一条任务，写在第 7 组**），不在这里顺手改（改了会让本变更的验收标准从"工具能跑命令"扩成"白名单生效"，两件事的可核判据不同，混在一起审不清）。

## Risks / Trade-offs

- **中文命令与中文路径**：靠 D3 的编码前缀（文本输出方向）与 D6 的宽字符启动（命令行与工作目录方向）覆盖。若 D6 在 apply 期间被实测证明不可行，处置是**停并如实报告**，不是把工具限制成只能跑 ASCII 命令。
- **命令里的中文参数是否真能原样到达，目前是未验证项**：宽字符启动解决的是"我们这一侧不把字节弄坏"，但子进程（PowerShell 及其启动的程序）按什么编码读自己的命令行并不由我们决定。第 1 组的探针必须先测出结论，再决定用户文档里写"支持中文路径与参数"还是写一条已知限制。**不许**在没测过的情况下把"支持中文"写成承诺。
- **命令字符串如果被多包一层引号会不会改变命令，要在实现时实测**：`build_command_line` 对含空格的参数会加引号，命令字符串几乎总含空格，所以它必然被包进一对引号里。按 `CommandLineToArgvW` 的规则，PowerShell 应当把这对引号当成定界符去掉。这是"应当"，不是"已实测"——第 1 组的探针要顺带把命令带空格、带引号、带结尾反斜杠三种情形各跑一次，把"PowerShell 实际收到的字符串"记下来。argv 形状的断言只能证明我们递出去的形状，证明不了对方收到的是什么，这一点要在任务里写明，不许拿形状断言冒充端到端结论。
- **PowerShell 5.1 与 pwsh 7 的行为差异**：本机只有 5.1。命令集的差异（例如某些 7 才有的参数）会让同一个命令在不同机器上表现不同。本变更不试图抹平这个差异，只规定"先找 7、找不到用 5.1"，并在用户文档里写清本机用的是哪一个、怎么看。
- **模型用错方言**：方言固定为 PowerShell 之后，模型仍可能写出 cmd 或 bash 写法。这类错误的形态是 PowerShell 自己报的语法错，模型能从返回文本里看出来并自行改正 —— 这是可接受的失败方式（返回里带原文报错），不额外做检测。
- **一次调用就是一个新进程**：`cd` 不跨调用生效。工具说明文字里明写"请用 `workdir` 参数，不要用 `cd`"。
- **工作目录参数会做工作区边界检查，这不是安全边界，只为与既有工具保持一致**：`workdir` 解析后落在工作区之外就拒绝。**说清它挡不住什么**：命令本身仍然可以 `cd C:\` 或访问任何路径（D9 已经明写没有权限模型），这道检查只是让"路径类参数不许越界"这条既有约定在所有工具上一致（`read_file` / `write_file` / `list_dir` 都这样，用户文档里也这么写），并且让模型的错填当场得到明确报错，而不是"命令莫名其妙跑错目录"。它**不是**"本变更引入的门禁"，也不构成任何安全承诺，用户文档里要照这个口径写。
- **临时文件会累积**：截断时写的完整输出文件放在系统临时目录，本变更不做清理（谁来清、按什么策略清，是另一件事，不在本变更范围）。

## Migration Plan

本变更是纯新增 + 两处既有代码的内部修复，无数据迁移：配置里没有这四个键时按缺省值工作（`compaction_threshold_percent` 的既有做法）；不写配置也能直接用工具。回退方式是按文件回退 —— 新增文件删掉、`sidecar_api.h` / `sidecar_api.cpp` / `sidecar_bridge.dart`（含接口与测试替身两个实现）/ `main.dart` / `agent_type_config.dart` / `CMakeLists.txt` 的增量撤销即可；`subprocess.cpp` / `subprocess.h` 的宽字符、毫秒超时、环境变量三项改动可单独保留（它们自身不依赖本工具，且各自都有既有用例守着"不传新字段时行为不变"）。

## Open Questions

- 无。三个悬而未决的点（常驻会话、后台任务、权限分层）都已在 Non-Goals 与 D9 里明确排除，不是待议项。
