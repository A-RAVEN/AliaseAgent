# Desktop Build — Spec

## Purpose

约束桌面端构建：失败能自愈重试，产物路径与命令可核。

## Requirements

### Requirement: Build failure self-heal
When `run.bat` triggers a `flutter build windows --debug` that fails, the launcher SHALL clean the stale native-assets incremental build cache under `.dart_tool\flutter_build` AND the native-assets hook cache under `.dart_tool\hooks_runner` (which holds the persisted `output.json` manifest that re-points at a removed native asset), then retry once before giving up, so a transient cache-driven failure recovers without requiring the user to run `flutter clean` manually. The self-heal SHALL NOT run a full `flutter clean` and SHALL NOT delete the `build\` output — the incremental compile artifacts remain, so the retry is an incremental rebuild. Clearing the hook cache forces the native-assets hook to re-download the sqlite3 native asset into a fresh per-process random-hash directory (the previously-downloaded native assets under `.dart_tool\hooks_runner` are discarded; this re-download is inherent churn). Recovery presupposes network access to re-download the sqlite3 native asset; when offline, the retry fails at the asset download and is surfaced as a network cause rather than recovering.

Note: `run.bat` SHALL abort on any critical command (cache clear, `flutter pub get`, sidecar/dependency copy, smoke test) failing with a non-zero code rather than silently continuing. The Flutter build is NOT an abort-on-failure command: its first failure SHALL trigger the self-heal (clear caches + retry) and a retry failure SHALL surface+classify (see the Build-failure-self-heal and Real-build-error-surfaced requirements), rather than a bare stop.

#### Scenario: Transient cache failure recovers
- **WHEN** the first Flutter build fails because the incremental cache references an already-removed native-asset source file
- **THEN** `run.bat` clears the `.dart_tool\flutter_build` incremental cache and the `.dart_tool\hooks_runner` native-assets hook cache, runs `flutter pub get`, retries the build, and the retried build succeeds — this recovery presupposes network access to re-download the sqlite3 native asset; if offline, the retry fails at the download step and is classified as a network cause (see the Retry-still-fails and Network-cause-classified scenarios)

#### Scenario: Targeted clear preserves build output
- **WHEN** the self-heal clears the incremental build cache and the native-assets hook cache
- **THEN** the `build\` output is not deleted, a full `flutter clean` is not executed, and the native-assets hook cache is rebuilt by re-downloading the sqlite3 native asset on the retry (the `download-*` directories under `.dart_tool\hooks_runner` are regenerated from the re-download rather than preserved)

#### Scenario: Critical command failure aborts
- **WHEN** a critical command (cache clear, `flutter pub get`, sidecar/dependency copy, or smoke test) exits with a non-zero code
- **THEN** `run.bat` stops with an error rather than silently continuing to the next step; the Flutter build is handled separately by the self-heal / surface-and-classify branches rather than a bare abort

#### Scenario: Retry success is non-silent
- **WHEN** the first build fails but the retried build succeeds
- **THEN** `run.bat` prints a notice that the first build failed and was automatically retried, rather than silently proceeding

#### Scenario: Retry still fails, falls through to surface and classify the cause
- **WHEN** the retried build still fails
- **THEN** `run.bat` proceeds to surface and classify the real error instead of showing only a build-failure shell

### Requirement: Real build error surfaced and classified
When a build fails after the self-heal retry, the launcher SHALL capture a verbose build log and classify the cause into network/environment, code error, or unknown (undetermined) using narrowly-scoped signatures, guiding the user rather than showing only a wrapped build-failure message (such as `MSB8066`). Classification SHALL be applied in priority order: code-error signatures first, then network signatures; when both are present the cause SHALL be reported as a code error (so an intermittent network word does not hide a real code bug). When the cause is undetermined, the launcher SHALL guide the user to open the log and read the first `Error:`/`fatal error` line as a fallback.

#### Scenario: Code cause classified (priority over network)
- **WHEN** the verbose build log matches compiler-error signatures (e.g. `fatal error C`, `error C`, `error LNK`, `unresolved external`), even if it also mentions download/network phrases
- **THEN** `run.bat` reports a real code error and points the user to the log

#### Scenario: Network cause classified
- **WHEN** the verbose build log matches network/download signatures (e.g. `Could not download`, `Trying to retrieve`, `HandshakeException`, `timed out`, `network is unreachable`, `resolve host`, pub get download failure) and does not match any compiler-error signature
- **THEN** `run.bat` reports a network/environment cause and states the app code is likely not at fault

#### Scenario: Indeterminate cause guided
- **WHEN** the verbose build log matches neither a compiler-error signature nor a network signature
- **THEN** `run.bat` reports the cause as undetermined and guides the user to open `%TEMP%\aliasagent_build.log` and read the first `Error:`/`fatal error` line, rather than asserting a network-or-code cause

### Requirement: Consistent sidecar build (no cross-configuration overwrite)
The launched app SHALL use a sidecar library built in the same configuration as the Flutter build, and the launcher SHALL NOT overwrite the run directory's sidecar with a different-configuration (Release) build.

#### Scenario: No cross-configuration overwrite
- **WHEN** `run.bat` builds and launches the app
- **THEN** the `sidecar.dll` in the run directory is the Debug-configuration build matching the app, and is not replaced by a Release-configuration build

#### Scenario: Sidecar built by the Flutter build
- **WHEN** `flutter build windows --debug` succeeds
- **THEN** the C++ sidecar library and its dependencies are built and installed into the run directory in the same (Debug) configuration

### Requirement: Build output verification before launch
Before launching, the launcher SHALL verify the app executable and the sidecar library exist, and SHALL report an explicit actionable error (including a possible missing vcpkg toolchain) if either is missing, rather than launching an app that is missing its library.

#### Scenario: App executable missing
- **WHEN** `alias_agent.exe` is absent after the build
- **THEN** `run.bat` reports the missing executable and does not launch

#### Scenario: Sidecar library missing
- **WHEN** `sidecar.dll` is absent after the build
- **THEN** `run.bat` reports the missing sidecar (including a likely vcpkg-not-found cause) and does not launch

### Requirement: Smoke test exercises the freshly built library
The launcher SHALL ensure the smoke test loads the sidecar library built by the current build (same configuration) with its matching runtime dependency DLLs, rather than a stale copy from a prior build. To that end it SHALL refresh the project-root `sidecar.dll` and its runtime dependency DLLs (`libcurl*.dll`, `zlib*.dll`) from the run-directory build, and SHALL fail with an explicit error rather than swallowing the copy result if any of them cannot be refreshed. The Debug-configuration guarantee strictly applies to `sidecar.dll` and its `-d`-flavored dependencies (Debug-to-Debug); the `libcurl*.dll` / `zlib*.dll` wildcards also carry release-named files (`libcurl.dll`/`zlib1.dll`), which are harmless redundancy and are intentionally kept (no no-mixing claim is made for libcurl/zlib — see the change design).

#### Scenario: Smoke test validates the current build
- **WHEN** `run.bat` refreshes the project-root `sidecar.dll` (Debug) and matching `libcurl*.dll` / `zlib*.dll` from the run-directory build, and each copy succeeds
- **THEN** the smoke test validates the freshly built library (Debug-configuration `sidecar.dll` with its `-d` dependencies) with its current dependencies

#### Scenario: Dependency refresh failure aborts
- **WHEN** any of the dependency refreshes (sidecar or libcurl/zlib) fails with a non-zero code
- **THEN** `run.bat` stops with an explicit error rather than launching or running the smoke test against a stale library

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
