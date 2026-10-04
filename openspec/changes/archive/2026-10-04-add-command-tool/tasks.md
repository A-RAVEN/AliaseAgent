## 1. 前置修复 A：subprocess 的 Windows 启动改走宽字符接口（design 决策 6）

- [x] 1.1 开工第一件事：不改任何代码，先跑一次 C++ 单测并存下改动前的读数 —— `cmake --build sidecar/build/windows --config Debug` 然后 `ctest --test-dir sidecar/build/windows -C Debug`，把用例总数与通过数贴进交付说明；这就是 1.6 要比对的对照（本机实测的对照读数是 **237 例 / 236 过 / 1 失败**，失败项是既有的网络用例 `ZhipuAI live: Web Search API`）
- [x] 1.1b 建 goal 之后、动上面那一步之前：`todo_write` 建一张表，把本文件里**每一条**任务逐条映射成一个 todo 项（条数与任务数一致，不许按组压缩），文本里带编号；此后每做完一条，**同一个动作里**先勾本文件的框、紧接着把该条 todo 置为 `completed`；轮末贴表本身与 remaining 数，两者条数不一致即本轮违规（依据：2026-10-03 用户要求「以后apply change时除了开goal，也要开todo，把每个task记成todo……每完成一个task要同时把todo和tasks文档里的勾都勾上 保证进度的实时性」，规则已写进 `CLAUDE.md` 的 goal 循环第 8 条与全局 `AGENTS.md` 第 3 节）
- [x] 1.2 先取证再动手，写一个探针把三件事一次核清（探针与临时产物放 `%TEMP%`，用完立刻删）：①以单个反斜杠结尾的参数、②连续反斜杠的参数、③含中文的参数，各自经 argv 传到子进程后是否逐字节一致（让子进程以**十六进制**写出收到的参数，不要让它按自己的默认编码打印，否则测的是它的输出编码而不是参数本身）
  **实测结论（2026-10-03，探针跑在 `sidecar_tests` 里，跑完已删）**：①尾反斜杠 `C:\dir\` 期望 `433a5c6469725c` = 实测，一致；②连续反斜杠 `a\\b` 期望 `615c5c62` = 实测，一致；③**中文参数不一致** —— 期望 `e4b8ade69687e58f82e695b0`，实测 `c3a4c2b8c2adc3a6e28093e280a1c3a5c28fe2809ac3a6e280a2c2b0`，正是"UTF-8 字节被按 CP1252 解释后再编码一次"的形态，与本机 `ACP=1252` 吻合。这条把 1.4 的必要性从推断变成了实测。
- [x] 1.3 把命令字符串整段递到 `-Command` 之后，**PowerShell 实际收到的字符串**是探针的第三件事：用带空格、带单引号、带双引号、以反斜杠结尾四种命令各跑一次，让命令把收到的内容原样输出并与期望逐字符比对。**argv 形状的断言只能证明我们递出去是什么形状，证明不了对方收到什么**，所以这一条必须实测，结论写进 `sidecar/src/subprocess.h` 的注释
  **实测结论（2026-10-03，同上探针）**：让 PowerShell 打印自己的完整命令行（UTF-16 转十六进制），三种命令的**原文都逐字符出现在 `-Command` 参数里**（例：`Write-Output 'a b | c > d'` 与 `Write-Output 'C:\dir\'` 的字节序列都能在命令行里原样找到），说明"命令整段作为一个 argv 元素"这条成立、外层没有二次拆分；`build_command_line` 给第 6 个元素加的那一对定界引号被 `CommandLineToArgvW` 正常去掉。这条结论要写进 `subprocess.h` 的注释。
- [x] 1.4 把 `sidecar/src/subprocess.cpp` 的 Windows 分支从 `CreateProcessA` 改成 `CreateProcessW`：命令行按 UTF-8 → UTF-16 转换后用宽字符命令行启动，工作目录同样用宽字符版本；字节层面的引号规则逻辑保持不变，另写一个宽字符版本，并保证宽字符路径与字节路径对同一组 argv 产生**一致的分段**
- [x] 1.5 在 `sidecar/test/subprocess_test.cpp` 里新增用例：①`cwd` 指向一个名字含非 ASCII 字符的临时目录，子进程报告当前目录，断言等于该目录；②把 1.2 测出来的非 ASCII 参数结果固化成用例 —— **1.2 说能一致就断言逐字节相等，说不能一致就如实断言实测结果并在用例注释里写明这是已知限制**（不许为了让用例变绿而改写断言口径）；③1.2 里反斜杠两问的结论也补成断言
  **实测结果（2026-10-04）**：`sidecar_tests.exe "[subprocess]"` = `All tests passed (39 assertions in 14 test cases)`。四条新用例：宽窄命令行分段一致（6 组 argv 逐组比对）；非 ASCII 工作目录被采用（改之前这条起不来，`GetLastError=267`）；非 ASCII 参数逐字节到达（改之前是 `c3a4c2b8…` 那种乱码）；尾反斜杠与连续反斜杠逐字节到达。
  **过程中改正的两处自己的错**：①建这个临时目录必须先做 UTF-8 → UTF-16 转换，我第一版手写的解码器是错的（`GetFileAttributesW` 直接说不存在），换成系统的 `MultiByteToWideChar` 才对；②`TempDir::path()` 给的是正斜杠，`CreateProcess` 的工作目录参数要原生反斜杠形式，用例里统一转换后再传。
- [x] 1.6 重跑 C++ 单测：`cmake --build sidecar/build/windows --config Debug` 然后 `ctest --test-dir sidecar/build/windows -C Debug`，把用例总数与通过数与 1.1 的对照贴出来 —— 既有的行为断言必须全绿，且总数按 1.5 新增的用例增加；再用构建目录下的完整路径跑一次这一组（`sidecar_tests.exe` 不在裸名能解析到的位置，要用 `sidecar\build\windows\Debug\sidecar_tests.exe "[subprocess]"`，标签按文件里实际的写），贴出实际输出。**收尾必须做一步反查**：用 `sidecar_tests.exe --list-tests` 确认探针那类临时用例已经从二进制里消失（今天踩过：把源文件从 CMakeLists 去掉、但没重新构建，二进制里还留着它，白多出一条失败）
  **实测对照（2026-10-04）**：
  - 改前：`test cases: 237 | 236 passed | 1 failed`，`assertions: 3783 | 3782 passed | 1 failed`
  - 改后：`test cases: 241 | 240 passed | 1 failed`，`assertions: 3801 | 3800 passed | 1 failed`
  - 用例 +4（1.5 的四条），断言 +18；唯一的失败仍是既有的网络用例 `Rate guard: rapid-fire 5 consecutive ZhipuAI searches`（现场是 `ZhipuAI: connection error — Could not connect to server` 五连，与本变更无关）
  - 分组输出：`sidecar\build\windows\Debug\sidecar_tests.exe "[subprocess]"` = `All tests passed (39 assertions in 14 test cases)`
  - 反查：`--list-tests | Select-String 'probe:'` 为空，探针用例确已从二进制消失
- [x] 1.7 记录宽字符改动带来的一处行为变化：路径不在当前码页时 `CreateProcessW` 能起来而 `CreateProcessA` 起不来 —— 写进 `sidecar/src/subprocess.h` 的头注释；同时把"起进程失败时只返回一个不说明原因的空结果"这个既有问题**如实记进 `Docs/known-bugs.md`**（只记不改，改它会让本变更的验收范围扩成"执行器的错误报告"，是另一件事）
  **实测结果（2026-10-04）**：头注释已补（`Result run(...)` 上方写明宽字符启动的理由、实测的乱码字节形态、以及"命令整段到达 PowerShell"的实测结论）。`Docs/known-bugs.md` 追加两条：①`subprocess: 起进程失败时只回一个不说明原因的空结果`（现场是 `GetLastError=267` 只有插桩才看得到）；②`sidecar_test: TempDir 清理在含非 ASCII 名的目录上失效`（本任务执行期间实测留下的 10 个 `st_*.tmp` 空壳就是这条的症状，已手工清掉）。第二条虽不在任务原话里，但它是同一次实测冒出来的、且属于"只记不改"的既有问题，一并记账并写明不在本变更范围内。

## 2. 前置修复 B：执行器补上毫秒超时与额外环境变量（design 决策 3、5）

- [x] 2.1 在 `sidecar/src/subprocess.h` 的 `Options` 上加两个选填字段：毫秒级超时、要额外注入的环境变量（键值对）；并写明"不填时行为与今天完全一致"
- [x] 2.2 在 `sidecar/src/subprocess.cpp` 里实现这两项：Windows 分支把父进程环境块取出、并入注入项后传给 `CreateProcessW`，超时按毫秒比较；POSIX 分支同样合并环境。既有的整秒超时字段保留可用
- [x] 2.3 在 `sidecar/test/subprocess_test.cpp` 里为这两项各加用例：①注入 `NO_COLOR=1` 之类的变量后子进程能读到它，**且父进程的完整环境仍在**（至少断言三项：父进程里临时设的一个变量还能读到、`PATH` 仍然非空且长度与父进程同量级、`PATH` 里能按名字解析到 `git` 或 `python` 这类真命令 —— 只断言"注入的那项在"是不够的，把环境整个替换掉也会让它过）；②毫秒超时：给一个小的毫秒数让命令跑得比它久，断言被终止且实测耗时与给的毫秒数同量级（把毫秒截断成整秒会让它失败）；③不填这两个字段时行为不变（既有用例已经在守，确认它们仍绿）
  **实测结果（2026-10-04）**：`sidecar_tests.exe "[subprocess]"` = `All tests passed (57 assertions in 17 test cases)`。三条新用例：注入环境是并入而不是替换（注入项看到、父进程自设变量还在、`PATH` 非空、`shutil.which('python')` 为真）；毫秒超时按毫秒判定（`timeout_ms=500` 对上 5 秒睡眠，断言 `timed_out` 且有耗时上下界，同时故意把 `timeout_seconds` 设成 30 证明毫秒字段优先）；不填两个新字段时行为不变。
  **过程中排掉的一个真坑（值得记住）**：注入环境时 `CreateProcessW` 一律 `ERROR_INVALID_PARAMETER(87)`。逐步体检后定位：**自己拼的宽字符环境块必须同时带上 `CREATE_UNICODE_ENVIRONMENT`**，不带这个标志时那个块会被当成 ANSI 解释、校验不过（实测：最小块 `A=1` 不带标志 err=87，带上 err=0）。这条已写进 `subprocess.cpp` 的注释。
- [x] 2.4 重跑 `ctest --test-dir sidecar/build/windows -C Debug`，把总数与通过数贴出来，与 1.6 的读数对照
  **实测对照（2026-10-04）**：1.6 时是 `241 例 / 240 过 / 1 失败`、`3801 断言`；本组做完是 **`244 例 / 243 过 / 1 失败`、`3822 断言`**（+3 例、+21 断言，正是 2.3 的三条）。唯一失败仍是既有的网络用例 `Rate guard: rapid-fire 5 consecutive ZhipuAI searches`。

## 3. 命令工具本体（C++，design 决策 1/2/3/4/5/7）

- [x] 3.1 新增 `sidecar/src/command_tool.cpp` 与 `command_tool.h`：实现"把命令交给 PowerShell 执行"的编排 —— 拼出 argv（可执行文件、`-NoLogo`、`-NoProfile`、`-NonInteractive`、`-Command`、编码前缀 + 命令）、解析 `workdir`（相对当前工作区解析，越界拒绝）、按 `subprocess::run` 执行、把结果转成返回结构
- [x] 3.2 在同一个文件里实现可执行文件解析：按 `%ProgramFiles%\PowerShell\7\pwsh.exe`、`%ProgramFiles(x86)%\PowerShell\7\pwsh.exe`、`PATH` 下的 `pwsh.exe`、`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` 的顺序找；四处都没有时返回失败说明并列出找过的位置（**不许**换成 `cmd` 或 `bash`）
- [x] 3.3 在同一个文件里实现输出的取舍：每条流分别收集；超过内存上限时保留尾部并记下原有字节数与保留字节数；被截断的流把完整内容写入系统临时目录下的文件（超过写文件上限则不写并在说明里写明），返回里带上该文件路径
- [x] 3.4 在同一个文件里实现返回 JSON 的组装：`ok`、`exit_code`、`stdout`、`stderr`、`timed_out`、`duration_ms`、截断字段、完整输出文件路径；**非零退出码不改变 `ok`**；工具自身的失败用中文可读说明；标准输出与标准错误**分开**返回不合并；四个配置值从**请求 JSON 的字段**里取（缺失或非法就用与 Dart 侧一致的缺省值兜底），C++ 侧不读配置文件
  **实测（2026-10-04）**：`sidecar_tests.exe "[command_tool]"` = **`All tests passed (72 assertions in 13 test cases)`**。3.1~3.4 的判据都在这 13 条里：argv 形状（6 项、前缀在两段赋值都在、命令原文在尾部、引号竖线未被动）、前缀不改变报错行号（`At line:2`）、解释器落到本机真实存在的 PowerShell、超长输出保留尾部并落全文文件、未超限不留文件、超写文件上限不落文件、字符上限被抬到下限、生效超时的三种情形、workdir 生效、越界 workdir 拒绝且命令未执行、非零退出码仍 `ok` 且两条流分开、非法 UTF-8 不崩、出错路径给中文说明。
  **过程中修掉的三个自己的错（都记在代码注释里）**：①`tail_chars` 在"输出比上限短"时返回空串（症状：命令有输出但 `stdout` 是空的）；②合并环境块时漏了 `CREATE_UNICODE_ENVIRONMENT`（见 2.3）；③测试里建中文目录时把每个字节直接当码元塞进 `std::wstring`，建出来的是另一个名字，导致后面找不到（改用 `subprocess::utf8_to_wide`）。
  **另有一处必须记下来**：我用 PowerShell 的 `-replace` 做了批量文本替换（就为了把两处 `utf8_to_wide` 改成 `to_wide`），把 `command_tool.cpp` 的中文注释整片变成了乱码并加了 BOM；已按规则用编辑工具**整文件重写**恢复（BOM 检查：首三字节 `23 69 6e`）。**这类批量文本替换以后一次都不许再做**，哪怕只改两个标识符。
- [x] 3.5 断言输出必须能被 JSON 序列化：把含非法 UTF-8 字节的命令输出（例如用 PowerShell 写出 `0x80` 这样的单字节）做成一个单测用例，断言工具**不崩**且返回结构合法 —— 现场打印实际返回
  **实测**：用例名 `run_command: 输出含非法 UTF-8 字节时不崩、返回结构合法`，命令从一个脚本文件里写出 `0x41 0x80 0x42`，断言 `ok=true`、`exit_code=0`、输出含 `A`/`B`、坏字节被换成替换字符 `EF BF BD`。**注意别把坏字节直接塞进命令行**：那样会被 PowerShell 的恶意脚本检测（AMSI）拦下并报 `contains malicious content`，测到的是检测器不是我们的解码路径。
- [x] 3.6 把 `src/command_tool.cpp` 同时加进 `sidecar/CMakeLists.txt` 的**两份源码列表**：`sidecar.dll` 目标（与 `src/tools.cpp`、`src/browser.cpp` 并列）**和** `sidecar_tests` 目标（与 `src/subprocess.cpp` 并列）。只加前者会让第 5 组的用例因符号缺失链接失败，这一点要在构建后确认两份都真的编到了
  **实测**：两份列表都已加；测试用例 `command_tool_test.cpp` 也进了 `sidecar_tests` 的列表。构建通过、13 条用例全部链接成功并跑通，证明两份列表都真的编到了。

## 4. FFI 入口（C++ → Dart）

- [x] 4.1 在 `sidecar/src/sidecar_api.cpp` 里加导出的 FFI 入口 `run_command`：镜像 `browser_snapshot` 的写法（静态结果字符串暂存、`try/catch` 兜住所有异常、异常时返回中文说明），并在 `sidecar/include/sidecar_api.h` 里加上声明
  **实测（2026-10-04）**：`cmake --build sidecar/build/windows --config Debug --target sidecar` 通过；`dumpbin /exports sidecar\build\windows\Debug\sidecar.dll` 里能看到 `run_command = @ILT+24305(run_command)`（与既有的 `browser_snapshot` 并列），确认它真的导出到了 DLL 上，而不只是编进了静态目标。
- [x] 4.2 在 `lib/services/sidecar_bridge.dart` 里接上：新增原生函数类型与函数指针、新增 `Future<String> runCommand(String requestJson)`、登记到 worker isolate 的 `_webWorkerMain` 分支（与 `web_fetch` 同一个通道，但等待时长按"命令超时 + 缓冲"给，避免界面卡住）
  **实测（2026-10-04）**：`typedef RunCommandDart`、`_webWorkerMain` 的 `case 'run_command'`、`runCommand` 三个都加了；等待时长给 11 分钟（命令缺省上限 10 分钟 + 缓冲），并在注释里写明"真正的超时判定在 sidecar 里，这一层只是兜底，免得它抢先掐断把'超时'变成'没结果'"。`flutter analyze` 在改动前后都是 **171 条**。
- [x] 4.3 **接口与测试替身一起改**（最容易漏的一处）：在 `lib/services/sidecar_bridge.dart` 的 `ISidecar` 抽象接口里加上 `runCommand`，并让两个实现都跟上 —— `SidecarBridge` 本体，以及 `test/integration/helpers/fake_sidecar.dart` 里的 `FakeSidecar`（给它一个可被用例设定的返回值）。漏掉假 sidecar 会让所有用它的用例编译不过，改完立刻 `flutter analyze` 确认没有"缺实现"的报错
  **实测**：`ISidecar` 加了 `runCommand`；`SidecarBridge` 与 `FakeSidecar` 都实现（假 sidecar 另带 `stubRunCommand` 与 `lastRunCommandRequest`，供 5.4/6.2/6.3 用）。中途 analyzer 多出一条 `annotate_overrides`（172 条），补上 `@override` 后回到 **171 条**（与改动前一致）。
- [x] 4.4 打开工作区之外的 `workdir` 必须被拒绝，且命令**不执行**：用一个一旦执行就会留下痕迹的命令（写文件）验证，断言该文件不存在；这条做成集成用例并写明它覆盖"越界拒绝 + 命令未执行"两件事
  **实测（2026-10-04）**：`test/integration/command_tool_test.dart` 六条用例 **`All tests passed!`**（经仓库根真实 `sidecar.dll` 跑真命令），覆盖 4.4 的判据读数：`ok=false error=工作目录不允许在工作区之外：C:\Users\76956\AppData\Local\Temp\cmd_tool_it_5d53ad72 留痕文件存在=false`。同一条文件里还顺带跑通了另外七件事（非零退出码、两条流分开、中文往返、超时带回已收集输出、workdir 生效、cd 不跨调用、配置改小后输出真的变短），实测读数分别是 `exit=3 stdout长度=9 stderr长度=9`、`stdout="中文测试输出\n"`、`timed_out=true duration_ms=825 stdout="BEFORE-TIMEOUT\n"`、`stdout="…\sub工作目录\n"`、`小上限长度=1000 截断=true | 缺省长度=8000 截断=true`。

## 5. 接入界面（工具定义 + 执行分支 + 配置项与它们的传递）

- [x] 5.1 在 `lib/main.dart` 的工具定义区（`final base = <String, Map<String, dynamic>>{` 与 `_toolDefs = base;` 之间）加入 `run_command`：参数为 `command`（必填）、`timeout_ms`（可选）、`workdir`（可选）。**不加 `description` 参数** —— 参考实现有它，但本仓库的既有工具没有一个让模型填说明，工具卡是按工具名与入参通用渲染的，加它只会多一个必填项。说明文字写明"真实执行、会改动工作区、PowerShell 方言、路径用原生形式、环境变量用 `$env:NAME`、换目录用 `workdir` 而不是 `cd`、非零退出码不是工具失败、输出过长只留尾部"
  **实测（2026-10-04）**：定义加在 `final base = <String, Map<String, dynamic>>{` 与 `_toolDefs = base;` 之间的无条件区（用 `test/unit/user_docs_test.dart` 的抽取正则能核到：它的 `_registeredToolNames()` 认的就是这段里的 `'name': 'x'`）。三个参数与说明文字都在；没有 `description` 参数。**中途踩了一脚**：说明文字里的 `$env:NAME` 在 Dart 单引号串里会被当插值，`flutter analyze` 直接报 `Undefined name 'env'` 与 `non_constant_map_value` 两条 error —— 改成 `\$env:NAME` 后清零。
- [x] 5.2 在 `lib/main.dart` 的 `_executeTool` 里加 `run_command` 分支：把参数交给 `_sidecar.runCommand`，返回给模型时按规范渲染成文本（正文 + 可选的 `[stderr]` + `[exit code: N]` / `[timed out after <N>ms]` / `[output truncated; full output: <路径>]`，空输出渲染成 `(no output)`）
  **实测**：分支加了（`case 'run_command':`），渲染加了（`} else if (name == 'run_command') {`）。标记顺序按规范：正文 → `[stderr]` → 截断与全文路径 → 超时 → 退出码；空输出渲染 `(no output)`。**这条判据的端到端证明在 6.3**（假 sidecar 走完"工具执行 → 渲染"那条快用例），这里只做到"代码在位、analyze 不炸"。
- [x] 5.3 在 `lib/models/agent_type_config.dart` 里加四个配置项与缺省值：`command_timeout_ms`（120000）、`command_max_timeout_ms`（600000）、`command_max_output_chars`（8000）、`command_output_full_chars`（2000000）；字符上限另有 1000 的下限（配得更小按 1000 算）；缺失 / 非数字 / 非正值一律回落缺省，写法与既有的 `compaction_threshold_percent` 一致；并在 `toJson` 里写回，让这四个键在配置文件里看得见
  **实测**：四个字段 + 四个缺省常量 + `kMinCommandMaxOutputChars = 1000` 都加了；解析用 `_parsePositiveInt`（缺失 / 非数字 / 0 / 负数回落缺省并打印一行）；字符上限解析后再夹一层下限；四个键在 `toJson` 里**始终写回**（与 `compaction_threshold_percent` 同样的做法）。
- [x] 5.4 **把四个配置值接进请求**（不写这条就会出现"配了没反应"）：`run_command` 分支组装请求时带上这四个值（与 `grep_file` 分支把 `max_results` 拼进请求同一个套路），缺省时也显式传下去
  **实测**：`_executeTool` 的 `run_command` 分支里显式写了 `timeout_ms` / `max_timeout_ms` / `max_output_chars` / `full_output_chars` 四项（前三项里 `timeout_ms` 优先取工具入参、缺省时取配置）。"这四个值真的到了执行侧"的端到端证明在 6.2 的"配置改小后输出真的变短"（实测 `小上限长度=1000 截断=true | 缺省长度=8000 截断=true`），以及 7.6 的变异验证。
- [x] 5.5 用一条命令核对配置的双向一致：拿一份缺这四个键的配置与一份把它们写成非法值的配置，经 `AgentTypeConfig.fromJson` 解析后打印实际取到的值，断言等于缺省值；把这条读数贴进交付说明
  **实测**：新增 `test/unit/agent_type_config_command_test.dart`，**`All tests passed!`（5 条）**，读数：缺省 `timeout=120000 maxTimeout=600000 maxOutputChars=8000 fullOutputChars=2000000`；非法值回落同上；`200 被抬到: 1000`；按配置 `timeout=5000 maxTimeout=20000 maxOutputChars=1234 fullOutputChars=50000`；写回的四个键与配置一致。
- [x] 5.6 `flutter analyze` 必须零新增问题：改动前先跑一次记下问题总数（本机实测的对照读数是 **171 条**），改完再跑一次对照（拿总数说话，不凭感觉）。**注意 `flutter analyze` 不受动态库新鲜度守卫影响，可以先跑**；受它影响的是 `flutter test`（见 6.4）
  **实测对照**：改动前 **171** → 改动后 **171**（`flutter analyze lib test integration_test`）。中途出现过 172（`fake_sidecar` 少了 `@override`）与两条 error（`$env:NAME` 被当插值），都当场修掉。剩下的 `lib/main.dart` 那条 `nsCount 未使用` **不是本次引入的**：`git diff -U0 lib/main.dart` 里没有这一行，`git show HEAD:lib/main.dart` 里已经有 `var nsCount = 0;`。

## 6. 测试（本组是全部判据；每条判据跑法都写在这里）

- [x] 6.1 C++ 单测 `sidecar/test/command_tool_test.cpp`，逐条覆盖：argv 形状（前四项开关 + 第一项是可执行文件 + 第六项是一整个字符串 + 数组长度为 6）；编码前缀的**位置与完整内容**（在开头且与命令同一行；三行命令第二行写错时报错行号仍是第 2 行；两段编码赋值都在）；环境变量注入（三项都在且父进程原变量仍可见）；输出截断保留尾部并给出字节数；**未超限时不写文件也不标截断**；**超过写文件上限时不落文件并如实说明**；超时按毫秒判定；**生效超时的算法**（给的值小于上限就用给的值、大于上限就用上限、不填就用配置缺省值，三条一起断言）；`workdir` 真的成为本次命令的工作目录；可执行文件解析顺序。把这些用例加进 `sidecar/CMakeLists.txt` 的 `sidecar_tests` 源码列表（与 `test/subprocess_test.cpp` 并列）
  **实测（2026-10-04）**：`src/command_tool.cpp` 进了**两份**源码列表（`sidecar.dll` 那份在 `src/browser.cpp` 之后、`sidecar_tests` 那份在 `src/kimi_search.cpp` 之后），`test/command_tool_test.cpp` 进了测试清单；`--list-tests` 里 `run_command:` 开头共 **13 条**、`subprocess:` 17 条，与读数对得上；`sidecar_tests.exe "[command_tool]"` = `All tests passed (72 assertions in 13 test cases)`。
  **一处与原话的差异要说清**：原话写"argv…数组长度为 6"，实现里工具层确实是 **6 项**（可执行文件 + `-NoLogo`/`-NoProfile`/`-NonInteractive`/`-Command` + 载荷），到 `subprocess` 层才拼成命令行 —— 断言写的就是 6 项，与规范里的 argv 场景一致，不是放松判据。
- [x] 6.2 Dart 集成测试 `test/integration/command_tool_test.dart`（经仓库根的真实 `sidecar.dll` 跑真命令）。**写法照 `test/integration/real_sidecar_test.dart`**：`setUpAll` 里取 `SidecarBridge.instance`、先 `setWorkspace('.')`，调完把返回的 JSON 串自己 `jsonDecode` 后断言（`test/integration` 下真正用真库的就是这个文件与 `bridge_realtime_test.dart`；`compaction_projection_test.dart` 是纯假 sidecar 的，别照它写）。逐条覆盖：非零退出码仍 `ok` 为真且退出码原样带回；标准输出与标准错误分开；中文逐字往返；超时被终止且返回已收集的输出；越界 `workdir` 被拒绝且命令未执行；`workdir` 生效（`Get-Location` 报告的是给的那个子目录）与"`cd` 不跨调用"；**把每条流的上限按一个明显更小的值组装进请求后，同一条长输出命令的返回长度真的变短、截断字段为真**（这条穿过 5.4 的组装路径）。**断言前先打印**本次实际执行的命令与实测读数（退出码、输出长度、是否截断、耗时），并写明本用例覆盖哪几件事
  **实测**：按 `real_sidecar_test.dart` 的写法建（`SidecarBridge.instance` + `setUpAll` 里 `setWorkspace('.')` + 自己 `jsonDecode`），六条用例 **`All tests passed!`**；每条都在断言前打印了实际命令与实测读数（逐条读数记在 4.4 那一条里）。
- [x] 6.3 假 sidecar 那条快用例：让 `FakeSidecar.runCommand` 返回一份成功结果，走完"工具执行 → 渲染"这条路，断言模型看到的那段文本含命令输出与（非零退出时的）退出码标记；这条不依赖真实动态库，是日常回归里跑得最快的一条。**写法照 `test/integration/tool_call_test.dart` 里 `grep_file tool call completes without error` 那条 widget 级用例**（给假 sidecar 设返回值 → 断言界面上找得到那段文本）
  **实测（2026-10-04）**：在 `test/integration/tool_call_test.dart` 里加了两条 widget 级用例，整个文件 **`All tests passed!`（10 条）**：
  - `run_command 的成功结果与四个配置值都到位` —— **这条同时是"配置值有没有传下去"的唯一判据**，所以它把配置里的 `command_max_output_chars` 设成 `1234`（非缺省、可区分），断言组装出的请求里带着它。现场打印：`{"command":"echo hi","timeout_ms":120000,"max_timeout_ms":600000,"max_output_chars":1234,"full_output_chars":2000000}`；同时断言界面上找得到 `COMMAND-OK`。**这条断言是变异验证逼出来的**：原先它断言的是缺省值 `8000`，与"配置没传下去"时的结果一模一样，等于没测（详见 7.6）；
  - `run_command 的非零退出码与 stderr 都渲染出来` —— 断言界面上同时看得到 `BUILD-FAILED`、`boom: detail` 与 `[exit code: 7]`。
- [x] 6.4 全量 VM 测试：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 把新构建的动态库刷到仓库根（否则会看到两个问题：一是 15 个 `Failed to lookup symbol`，二是 `test/unit/sidecar_dll_freshness_test.dart` 直接判红 —— 它按"仓库根那份与最新构建的那份逐字节相同"判定），再 `flutter test`，把总数与改动前的总数对照贴出
  **实测（2026-10-04）**：先刷库（`SYNC-OK: sidecar.dll already current`），再跑全量。第一遍读数 `01:46 +320 -4`。四条失败逐条归因：
  ①`command_tool_test.dart 超时被终止且带回已收集的输出（覆盖 4）` —— **真缺陷（我的用例写脆了）**：超时给 800 毫秒，整机负载高时 PowerShell 的启动开销都没跑完就被杀了，`stdout` 是空的。已改成"脚本文件先输出、停 500 毫秒、再长睡 10000 毫秒，超时给 2500 毫秒"，**单跑连测三次稳过**：`timed_out=true duration_ms=2530 / 2525 / 2522 stdout="BEFORE-TIMEOUT\n"`。
  ②③④ `user_docs_test.dart` 三条 —— **我边跑边改文档造成的现场不一致**（那次跑的窗口里我正好在写 `tools-command.md` 与 README 索引）：它报"`tools-command.md` 没进索引""四个配置键没写进文档""`cd` 在代码里找不到"。前两条是我当时还没写完；第三条是真的，已按既有机制处理（配置键改成文档里带 ```` ```json ```` 代码块、`cd` 加进 `_otherCodeNames` 并注明它在 `lib/main.dart` 的哪里）。
  修完重跑：`flutter test test/unit/user_docs_test.dart` = **`All tests passed!`（5 条）**；全量复跑（后台作业 183）读数 **`01:20 +322 -2`**，两条失败仍然是当时的 `user_docs_test` 那两条（复跑启动时我还没把文档那两处改完），而 `command_tool_test.dart` 那一条已经转绿。
  **最终读数（2026-10-04，后台作业 184，文档与用例都改完之后）**：**`01:20 +324: All tests passed!`，失败 0 条**。与改动前的对照：改动前是 `+311`（本会话开始时记录的全量读数），本次新增 7 条（`command_tool_test.dart` 6 条 + `agent_type_config_command_test.dart` 5 条 = 11 条新增，但计数的"+N"是**文件级**通过数，`tool_call_test.dart` 里新加的两条与其它文件的重排会让总数与文件数不严格相加），因此只按"全绿、0 失败"这条判据收口，不拿算术差当证据。

## 7. 让判据当场失败一次（证明它们真的能红）

- [x] 7.1 把命令字符串拆成多个 argv 元素（模拟"外层二次解析"），确认 6.1 的 argv 形状用例变红；**改回来**，确认重新全绿
  **实测（2026-10-04）**：把 `build_invocation` 改成把前缀与命令分成两个元素 → `[command_tool]` = `13 例 | 12 过 | 1 失败`、`68 断言 | 67 过 | 1 失败`，红的正是 `run_command: argv 形状与编码前缀` 里的 `REQUIRE( argv.size() == 6 )`。改回后 `All tests passed (72 assertions in 13 test cases)`。
- [x] 7.2 把编码前缀挪到单独一行，确认"报错行号仍是第 2 行"的用例变红；再把前缀里的 `$OutputEncoding` 那半句删掉，确认"前缀内容完整"的用例变红；两次都**改回来**，确认重新全绿
  **实测（2026-10-04）**：
  - **挪到单独一行**（前缀结尾由 `" "` 改成 `"\n"`）→ **两条一起红**：`13 例 | 11 过 | 2 失败`；一条是 `REQUIRE( r["stderr"]…find("At line:2") )`，现场输出 `At line:3 char:1`（命令被推到第 3 行，前缀实占一行）；另一条是前缀内容断言也顺带红了。
  - **删掉 `$OutputEncoding` 那半句** → **只红内容那一条**：`13 例 | 12 过 | 1 失败`，红的正是 `REQUIRE( argv[5].find("$OutputEncoding = [System.Text.UTF8Encoding]::new($false); ") != std::string::npos )`。这条专门补的断言确实在起作用 —— 没有它，删掉这半句不会有任何检查发现。
  - 两次都改回后 `All tests passed (72 assertions in 13 test cases)`。
- [x] 7.3 截断时改成保留头部，确认 6.1 的截断方向用例变红；再改成"未超限也照写一份完整输出文件"，确认"不该写文件"的用例变红；两次都**改回来**，确认重新全绿
  **实测（2026-10-04）**：
  - **改成保留头部**（`tail_chars` 里 `s.substr(i)` → `s.substr(0, max_chars)`）→ `13 例 | 12 过 | 1 失败`，红的正是 `REQUIRE( out.find("TAIL-MARKER") != std::string::npos )`（尾部标记没了）。
  - **未超限也照写文件**（`shape_stream` 去掉 `r.truncated &&` 这个条件）→ `13 例 | 10 过 | 3 失败`：`REQUIRE( full_output_files() == before + 1 )`（多写了文件）与两条 `REQUIRE( r.contains("full_output_paths") == false )`（未超限时不该给全文路径）。
  - 两次都改回后 `All tests passed (72 assertions in 13 test cases)`。
- [x] 7.4 只杀直接子进程、不杀它拉起的孙进程，确认 6.1 的"子进程不残留"用例变红；**改回来**，确认重新全绿
  **实测（2026-10-04）——这条要先补一条判据，过程值得记下来**：
  - **原先没有"子进程不残留"这条用例**（任务 6.1 的原话点了它，但我实现时漏了）。补了一条：让命令用 `Start-Process` 拉起一个跑 60 秒的 `cmd.exe`（`ping -n 60`）并打印它的 PID，超时 3 秒之后用 `tasklist /FI "PID eq <那个 PID>"` 查它还在不在，断言**不在**。补完后 `[command_tool]` = `All tests passed (76 assertions in 14 test cases)`。
  - **第一次变异（只把超时那一处改成 `TerminateProcess`）没能变红** —— 用例通过。追下去才明白：`TerminateProcess` 之后我们 `CloseHandle(pi.hProcess)` 与 job 句柄，`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 一关就把整棵树带走了，所以"只杀直接子进程"这个改法在**有 job** 的前提下不成立。
  - **真正能验证这条判据的变异**：不把子进程放进 Job（`in_job = false;`，同时超时分支退化成 `TerminateProcess`）→ **变红**：`14 例 | 13 过 | 1 失败`，红的是 `REQUIRE( listing.find(pid) == std::string::npos )`，即那个孙进程确实残留了。这说明"超时杀掉整棵树"**真的靠 Job Object**，不是靠杀直接子进程。
  - 两处都改回后 `All tests passed (76 assertions in 14 test cases)`，源码里 `MUTATION` 零命中。
- [x] 7.5 把毫秒超时截断成整秒（例如 500 毫秒变成 0 或 1 秒），确认 6.1 的毫秒超时用例变红；**改回来**，确认重新全绿
  **实测（2026-10-04）**：把 `effective_timeout_ms` 改成 `(opts.timeout_ms / 1000) * 1000` → **变红**：`14 例 | 13 过 | 1 失败`、断言数从 76 掉到 74（红的用例提前中止，后面两条没跑到）。红的是 `run_command: 超长输出保留尾部且标出截断` 里的 `REQUIRE( full_output_files() == before + 1 )` —— 原因很直接：毫秒被截成 0 之后进程"瞬间超时"，什么输出都没有，自然也没有截断、没有落文件。改回后 `All tests passed (76 assertions in 14 test cases)`。
- [x] 7.6 把 5.4 里那四个配置值从请求里去掉（模拟"配置只在 Dart 侧解析、不往下传"），确认 6.2 的"配置改小后输出变短"用例变红；**改回来**，确认重新全绿
  **实测（2026-10-04）——这条暴露了我判据设计上的一处不足，已经补掉**：
  - 按原话做（删掉 `_executeTool` 里 `max_timeout_ms` / `max_output_chars` / `full_output_chars` 三行）后，**6.2 那条"配置改小后输出变短"并没有红** —— 它靠的是**工具入参** `max_output_chars: 1000`，与配置无关。也就是说原话点名的这条用例根本管不到"配置值有没有传下去"。
  - **真正会红的是 6.3 那条假 sidecar 用例**：现场打印的请求变成 `{"command":"echo hi","timeout_ms":120000}`，断言 `contains('"max_output_chars":8000')` 失败，`00:00 +0 -1: Some tests failed`。
  - **补了一条真判据**（写在 6.3 那条用例所在的文件里，本来想放集成测试，但 `_executeTool` 是私有的、只有经界面才穿得到，所以放在假 sidecar 那条 widget 用例里更合适）：把 Agent 配置里的 `command_max_output_chars` 设成 `1234`（非缺省、可区分），走"界面上发一条消息 → 工具调用"这条路，断言组装出的请求里带 `"max_output_chars":1234`。**变异下它红了**（复验：现场请求只剩 `{"command":"echo hi","timeout_ms":120000}`，断言在 `contains('"max_timeout_ms":600000')` 就断掉），改回后全绿：现场请求 `{"command":"echo hi","timeout_ms":120000,"max_timeout_ms":600000,"max_output_chars":1234,"full_output_chars":2000000}`，`tool_call_test.dart` 10 条 `All tests passed!`。
  - 过程中还纠正了一个错：我先写的是直接调 `bridge.runCommand` 的集成用例，它**永远拿不到配置值**（组装请求的是 `_executeTool`，`SidecarBridge.runCommand` 只是把请求原样递给 C++），所以它在变异下也不红 —— 已删掉，换成上面那条穿过界面的。

## 8. 用户文档、索引与既有缺陷记账

- [x] 8.1 新增 `Docs/user-guide/tools-command.md`（中文，写给没读过代码的人）：这是什么、谁调用它（模型替你调用，你不直接调）、怎么触发、参数怎么填、四个配置键怎么写、出错时会看到什么、有哪些已知限制；必须写明"命令是在本机用你自己的权限真实执行的、能改动工作区里的文件、没有沙箱、跑起来之后不能事后批准或撤销"；`workdir` 那道边界检查要照 design 的口径写成"参数填写规范"，不得写成安全承诺；**中文参数支持与否按 1.2/1.3 的实测结论写**，测不出来就不许写成支持
  **实测（2026-10-04）**：文件已写。开头就写明"模型调用的工具、不是界面按钮"；"它在本机的什么位置执行"一节写明用你自己的账户权限、真的会改磁盘、不能事后撤销、解释器固定 PowerShell；`workdir` 一节明写"这是参数填写规范，不是安全边界"；差错原文按产品代码里的实际文案列出；已知限制里写明中文参数"命令与工作目录里的中文已能正确传进去（有测试守着），但被执行的程序自己怎么读命令行不由本工具决定"。
- [x] 8.2 在 `README.md` 的功能文档索引里加上这份文档与一行说明（`test/unit/user_docs_test.dart` 会双向核对索引与目录）
  **实测**：README 索引里加了一行 `[命令行工具](Docs/user-guide/tools-command.md) | 在你自己的电脑上真的执行 PowerShell 命令；没有沙箱、不能事后撤销`。`flutter test test/unit/user_docs_test.dart` = **`All tests passed!`**，现场读数 `[文档] Docs/user-guide 下共 9 份` 与 `[索引] 链了 9 份`（两边一致）。
- [x] 8.3 文档里给出的每一条示例命令都必须能真的跑通：至少挑一条（例如 `flutter test test/unit/summary_reference_test.dart`）实际执行一次并把输出贴进交付说明；同时核对文档里出现的工具名、参数名、配置键与代码里的一字不差
  **实测（2026-10-04）**：
  - 示例实跑：`flutter test test/unit/summary_reference_test.dart` → 末行 **`All tests passed!`**（这一条已写进文档的"可以直接抄的几条"表里，与它并列的其它四条都是本会话里真的跑过的命令）。
  - 名字逐字核对（用命令数出来的）：工具名 `run_command` 文档 2 处 / 代码定义 1 处；参数 `command`、`workdir`、`timeout_ms` 文档各有、代码定义各有；四个配置键在文档里各出现 2~3 处、在 `lib/models/agent_type_config.dart` 的解析路径里各 3 处（字段声明 + 解析 + 写回）。`flutter test test/unit/user_docs_test.dart` 已经把"文档里的名字必须能在代码里核到"这条做成了自动检查，**`All tests passed!`**。
- [x] 8.4 文档改完后跑这两条判据并把输出贴出来：①`flutter test test/unit/user_docs_test.dart`（确认新工具名与四个配置键在"文档 ↔ 代码"两个方向上核到）；②`flutter test test/unit/openspec_proposal_test.dart`（确认本 change 的任务清单仍满足"必须点名测试层路径"这条既有守卫）
  **实测（2026-10-04）**：两条一起跑 **`All tests passed!`（7 条）**；现场读数：`[测试层路径] add-command-tool：命中 21 处`、`[反例] 假 change 命中测试层路径 0 处（期望 0）`。
- [x] 8.5 记账两处**本变更不修**的既有缺陷，写进 `Docs/known-bugs.md`（只记不改）：①配置里的 `agent_types.<名>.tools` 白名单被解析但从未用于过滤工具定义；②`sidecar/src/browser.cpp` 的 `start_worker()` 自己另起一套进程创建（另一处按 ANSI 码页解释的接口），因此浏览器工作进程在路径含非 ASCII 字符时仍会坏
  **实测（2026-10-04）**：两条都在 `Docs/known-bugs.md` 里了 —— ②在 1.7 就写进去了（`## sidecar_test: TempDir 清理在含非 ASCII 名的目录上失效` 那条的末尾也点了 `browser.cpp` 的 `start_worker`），①这次补上（`## agent-config: tools 白名单被解析但从未用于过滤工具定义`，含核实方式与"为什么不在本变更里顺手改"）。两条都写明"只记不改"的理由。
- [x] 8.6 把文档里的工具名改错一个字（例如 `run_comand`），确认 8.4 的文档一致性检查变红；**改回来**，确认重新全绿 —— 证明这条守卫真的在守
  **实测（2026-10-04）**：改错**两处**（标题与开头那句里的 `run_command` → `run_comand`）后 —— **只改一处不会红**，因为文档别处还写着正确的名字，`_backtickedCodeNames` 仍然抽得到它，这一点值得记住。两处都改错后检查变红，现场输出：`Actual: ['run_comand']`、`这些名字在文档里当成代码名写，但代码里找不到：[run_comand]`（同时打印了 `[代码] 注册的工具（14 个）`与 `[代码] 工具定义里出现的名字（54 个）`，说明抽取本身没坏）。改回后 **`All tests passed!`（5 条）**，全仓 `run_comand` 零命中。

## 9. 真实环境验收

- [x] 9.1 先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 同步动态库，再 `flutter test test/integration/command_tool_test.dart`，贴出实际输出
  **实测（2026-10-04）**：先重建两份产物（`cmake --build sidecar/build/windows --config Debug`，退出码 0），再刷库（`SYNCED: sidecar\build\windows\Debug\sidecar.dll -> E:\Projects\AliasAgent\sidecar.dll`，`built 2026/10/4 19:52:20`）。集成测试 **`All tests passed!`（6 条）**，逐条读数与 4.4 记录的一致：`exit=3 stdout长度=9 stderr长度=9`、`stdout="中文测试输出\n"`、`timed_out=true duration_ms=2526 stdout="BEFORE-TIMEOUT\n"`、越界 `ok=false … 留痕文件存在=false`、`workdir` 生效 `stdout="…\sub工作目录\n"`、`cd` 不跨调用、配置生效 `小上限长度=1000 截断=true | 缺省长度=8000 截断=true`。
- [x] 9.2 构建并启动应用，真实观察一次：让模型执行一条会输出中文的命令，确认界面上的工具卡显示这条命令与输出、中文不乱码；用 OS 全屏截图留档（`& "$env:USERPROFILE\.dsh\skills\desktop-screenshot\capture.ps1" -Mode full`）后用 `read_image` 实际看
  **实测（2026-10-04）**：**跑法做了一处偏离，理由与替代物如下**。本机屏幕当时正被用户自己的会话占着（全屏截图确认过：前台是另一个程序），手动抢焦点去点本应用的输入框会打断他；所以改成**让本应用在真实窗口里、用真实动态库、由真实模型驱动跑一次**，观察对象与本应用自己的渲染是同一个：
  - 新建 `integration_test/live_command_tool_test.dart`（`@Tags(['live'])`，走 `MyApp()` 全应用 + 真实 `sidecar.dll` + 真实模型），断言：`run_command` 卡必须走到 `done`、结果里必须逐字含「中文测试」、不得出现替换字符。跑法 `flutter test --tags live --run-skipped integration_test/live_command_tool_test.dart -d windows`。
  - **实测输出**：`All tests passed!`；现场日志 `[命令工具 live] 工具=run_command 状态=done 入参={command: Write-Output "中文测试"} 结果=中文测试`、`结果长度=4`（正是四个汉字，没有乱码、没有引号残留）；工具卡出现时四条配置缺省提示各打印一次（`command_timeout_ms=null … using the default 120000` 等），顺带印证了"配置缺失回落缺省"这条。
  - **截图 + 目视验收**：`[SHOT] captured test/live_visual/livecmd_t1.png (38981 bytes)`，用读图工具看过 —— 画面里用户气泡是那条中文请求，下面是 `run_command(command=Write-Output "中文测试")` 的工具卡（右上 `✓ Done`，展开的结果区显示「中文测试」），再下面是模型的回答「命令已执行，打印出来的内容是：中文测试」。**中文全程无乱码**，工具卡把命令与输出都显示出来了。
  - 另：我先前手动启动过一份应用实例用于观察，为避免它和 live 用例抢数据库已把它关掉（`Get-Process alias_agent | Stop-Process`，之后进程数为 0）。
- [x] 9.3 整套冒烟：`"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`（从 PowerShell 直接 `bash` 会落到 WSL 并因 `USERPROFILE` 未定义中断），把通过 / 失败数与改动前的读数对照贴出，失败项要逐条说明是不是本次引入
  **实测（2026-10-04）**：`Total: 2 passed, 3 failed`，逐项：
  - `Build — PASS`
  - `Analyze — FAIL`：冒烟脚本把 analyze 的**任何**输出都当失败，而它的失败明细就是既有那批（`main.dart:2983` 的 `nsCount` 未使用、`sidecar_bridge.dart` 那几个"字段未使用"），**与改动前的 171 条一致**，本次没有新增（5.6 已按"171 → 171"核过）。
  - `Checkpoints — FAIL`：`4 passed, 3 failed`，失败的是 `checkpoint_4/5/6_verify.dart` —— 这三个文件在 `flutter analyze` 里一直报 `NativeCallable` 类型错误（本会话第一次跑 analyze 时就看到了），属于既有脚本年久失修。
  - `Launch & Verify — PASS`
  - `Visual Regression — FAIL`：既有（改动前的冒烟读数就是 `2 passed, 3 failed`，且这次失败项与那时同类）。
  结论：**这次的 2/3 与改动前的 2/3 是同一读数、同一批失败项**，没有一条能归到本次改动上。
- [x] 9.4 收尾核对：全仓库 grep 变异标记（统一用 `MUTATION-` 前缀），确认零残留；把六次变红的真实输出贴进交付说明；确认工作区里没有留下探针脚本、临时日志、临时输出文件（临时产物只允许在 `%TEMP%` 下且用完即删）
  **实测（2026-10-04）**：
  - **变异标记零残留**：`Get-ChildItem lib,test,integration_test,sidecar\src,sidecar\test -Include *.dart,*.cpp,*.h | Select-String 'MUTATION-\d|MUTATION-PROBE'` → **0**。（顺带核过：全仓另有 14 处含英文 "mutation" 的注释，是既有的"叶子节点变更"等无关代码，不是我的标记。）
  - **六次变红的真实输出**（逐条记在 7.1~7.6 那六条里，这里只列关键行）：`argv.size() == 6` / `At line:3 char:1` 与 `$OutputEncoding …` / `out.find("TAIL-MARKER")` 与两条 `full_output_paths` / `listing.find(pid) == std::string::npos` / `full_output_files() == before + 1` / `contains('"max_timeout_ms":600000')`（实际只剩 `{"command":"echo hi","timeout_ms":120000}`）。
  - **无临时产物**：仓库里搜 `zz_probe*` / `*.tmp` / `*_debug.txt` / `ct_*.txt` / `diag*.txt` / `*.bak` / `*.orig`（排除 `node_modules`、`build`、`.dart_tool`）**零命中**；我建的诊断文件都在 `%TEMP%` 且已删；`test/smoke/output/run.log` 是冒烟脚本自己的产物目录（gitignore）。
  - **改动清单（`git status --short`）**：15 个已跟踪文件被改（`CLAUDE.md`、`Docs/known-bugs.md`、`README.md`、`lib/main.dart`、`lib/models/agent_type_config.dart`、`lib/services/sidecar_bridge.dart`、`sidecar/CMakeLists.txt`、`sidecar/include/sidecar_api.h`、`sidecar/src/sidecar_api.cpp`、`sidecar/src/subprocess.cpp`、`sidecar/src/subprocess.h`、`sidecar/test/subprocess_test.cpp`、`test/integration/helpers/fake_sidecar.dart`、`test/integration/tool_call_test.dart`、`test/unit/user_docs_test.dart`），8 个新文件（`sidecar/src/command_tool.cpp/.h`、`sidecar/test/command_tool_test.cpp`、`test/integration/command_tool_test.dart`、`test/unit/agent_type_config_command_test.dart`、`integration_test/live_command_tool_test.dart`、`Docs/user-guide/tools-command.md`、以及本 change 的工件目录）。仓库根那个来历不明的 0 字节文件 `d` **不是我建的**，我按规矩没动它。
  - **最终稳定读数**：C++ `[command_tool]` = `All tests passed (76 assertions in 14 test cases)`；Dart 集成 6 条、假 sidecar 10 条、配置解析 5 条、文档一致性 5 条 + 提案守卫 2 条，全绿；全量 `flutter test` = `01:20 +324: All tests passed!`；`flutter analyze` 171（与改动前同数）；live 用例 `All tests passed!` + 截图目视通过；冒烟 `2 passed, 3 failed`（与改动前同一读数、同一批既有失败）。
