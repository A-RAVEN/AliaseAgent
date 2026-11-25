## ADDED Requirements

### Requirement: 桌面壳的构建脚本与产物校验

桌面壳 SHALL 由独立脚本构建（`scripts/build_desktop_shell.ps1`），产出可直接双击的产物目录，并在成功之前校验产物齐备：壳可执行文件与 WebView2 加载器（`WebView2Loader.dll`）都必须在产物目录里，缺任一即判定失败。发布形态 SHALL 是自包含的（用户不需要另外安装 .NET 桌面运行时）；首次构建需要还原依赖，这一步的失败 SHALL 被分类成网络/依赖还原原因而不是含糊的「构建失败」。

构建命令 SHALL 遵循既有构建流程的「关键命令失败即中止」纪律：任一关键步骤非零退出即停止并以非零码退出，MUST NOT 继续后续步骤、MUST NOT 产出半份后宣称成功。成功后脚本 SHALL 打印产物路径与「双击哪个文件」。

#### Scenario: 构建成功产出可双击目录

- **WHEN** 用户在装好 .NET SDK、可访问依赖源的机器上运行壳构建脚本
- **THEN** 产物目录里同时存在壳可执行文件与 `WebView2Loader.dll`，脚本以 0 退出并打印双击哪个文件

#### Scenario: 产物缺失即失败

- **WHEN** 发布命令返回 0，但产物目录缺少壳可执行文件或 `WebView2Loader.dll`
- **THEN** 脚本点明缺的是哪一个并以非零码退出，MUST NOT 打印成功

#### Scenario: 依赖还原失败按网络原因归类

- **WHEN** 依赖还原失败（离线、源不可达、超时）
- **THEN** 脚本给出可归因提示并说明这是网络/依赖源原因（不是代码错误），以非零码退出

### Requirement: 依赖版本钉死与构建入口可复现

壳与测试工程的包引用 SHALL 全部写死版本号，MUST NOT 使用浮动版本（`*`、版本区间）——不写版本会让 NuGet 以 `NU1015` 直接拒绝还原。测试工程 SHALL 同时引用 `Microsoft.NET.Test.Sdk` 与 `xunit.runner.visualstudio`，缺任一条时 `dotnet test` 发现不了用例（会呈现为「0 个测试也退出 0」的假绿）。版本取值 SHALL 有可核出处（本机缓存实读或包源索引实查并注明日期）。

构建入口 SHALL 可复现：仓库 SHALL 用**仓库根**的 `global.json` 钉住构建壳所用的 .NET SDK 版本（`dotnet` 只从当前工作目录向上找 `global.json`；放仓库根才能让 `dotnet publish` 与 `dotnet test shell/AliasAgent.Desktop.sln` 都从仓库根直接跑就吃到同一个钉住的 SDK，放 `shell/` 则两条命令都要先切目录）。构建脚本 SHALL 从仓库根执行发布命令，并 SHALL 打印实际使用的 SDK 版本以便与 `global.json` 对照。自包含发布需要下载 `Microsoft.NETCore.App.Runtime.win-x64` 与 `Microsoft.WindowsDesktop.App.Runtime.win-x64` 两个运行时包（首次上百 MB），这一步的网络失败 SHALL 与代码错误区分开。

#### Scenario: 缺版本号时还原被拒

- **WHEN** 某个包引用没有写版本号
- **THEN** 还原以 `NU1015` 失败，脚本以非零码中止并点名缺版本的那个包，MUST NOT 打印「构建成功」

#### Scenario: 测试工程能被 `dotnet test` 发现

- **WHEN** 从仓库根执行 `dotnet test shell/AliasAgent.Desktop.sln`
- **THEN** 测试工程被发现并至少执行一条用例（输出里有用例计数），不是「0 个测试、退出 0」

#### Scenario: 运行时包下载失败按网络归类

- **WHEN** 自包含发布需要下载的运行时包因离线或源不可达而失败
- **THEN** 脚本提示这是网络/包源原因并说明首次发布需要下载运行时包（上百 MB），以非零码退出

#### Scenario: 构建与测试都用钉住的 SDK

- **WHEN** 用户运行壳构建脚本，或从仓库根执行 `dotnet test shell/AliasAgent.Desktop.sln`
- **THEN** 两条命令都在仓库根执行、都读到仓库根 `global.json` 钉住的同一个 SDK 版本；构建脚本打印的实际 SDK 版本与 `global.json` 一致

### Requirement: 壳构建与既有构建流程互不影响

壳的构建与运行 MUST NOT 改变既有桌面构建流程的行为：`run.bat` 的五步（构建、产物校验、刷新 DLL、单元冒烟、启动）保持原样，壳构建 SHALL NOT 被塞进这五步中的任何一步；两者互不依赖——不构建壳也能照常跑 `run.bat`，不跑 `run.bat` 也能独立构建壳。任何自动化入口（冒烟脚本、测试）SHALL NOT 因为构建壳而触发起应用窗口。

壳的产物目录 SHALL 被版本控制忽略（自包含产物体积上百兆，MUST NOT 入库）；构建过程产生的中间目录同样不入库。

#### Scenario: 不构建壳不影响既有流程

- **WHEN** 用户只跑 `run.bat`、从未构建壳
- **THEN** `run.bat` 的五步行为与引入壳之前逐字一致；壳的缺失不导致任何一步失败

#### Scenario: 壳构建不起窗口

- **WHEN** 用户运行壳构建脚本，或自动化冒烟里跑壳的自检模式
- **THEN** 不出现应用窗口；脚本与自检只做构建、进程、HTTP 与协议层面的检查

#### Scenario: 产物不入库

- **WHEN** 检查版本控制状态
- **THEN** 壳的产物目录与中间目录都被忽略，`git status` 里不出现上百兆的构建输出
