## Why

现在每次要看界面都得由助手手动起核心、手动开浏览器：核心跑在终端里，地址是 OS 每次随机分配的，终端一关界面就没了。用户要的是「双击一下、界面上来、关掉窗口它还在」。

Windows 桌面壳把这条链路收成一次双击：壳起 Dart 无头核心（**固定端口**）→ 等 `core.ping` 通 → 在自己的窗口（WebView2）里加载 `http://127.0.0.1:<port>`；关窗口只是隐藏到右下角通知区域的托盘，托盘菜单「退出」才真退并停掉核心子进程。

## What Changes

**A. 新桌面壳（新目录 `shell/`）**
- 技术选型：**C# WinForms + WebView2 + NotifyIcon**，目标 `net10.0-windows`（长期支持版；原先考虑的 9 是标准支持版且已停止支持），自包含发布到 `shell/dist/`；双击 `AliasAgent.Desktop.exe` 即启动（选型权衡与被否方案见设计文档 D1）。
- 启动序列：解析仓库根与端口 → 预检（`web/dist`、`dart`、仓库根）→ **先建托盘图标**（冷启动期间也看得见壳在跑）→ 起核心子进程（工作目录 = 仓库根，sidecar 以裸名字加载）→ 轮询 `core.ping` → 开窗并导航到固定地址。
- 关窗 = 隐藏：`FormClosing` 取消并 `Hide()`，核心继续常驻；托盘双击或菜单「打开窗口」重新显示。
- 托盘菜单：「打开窗口」与「退出」；核心崩溃时多出「重启核心」。点「退出」才真退：先发 `core.shutdown` 礼停，超时再杀进程树；礼停与杀树都失败的极端情况会先弹气泡点名 pid 再退出（异常兜底，不是正常路径）。
- 单实例：命名互斥体；第二次双击用 `AllowSetForegroundWindow` 把「打开窗口」请求转给已在运行的实例，然后自己退出（窗口还没就绪时请求记为待处理，不丢）。
- 启动失败一律回收资源：WebView2 初始化失败（运行时缺失、用户数据目录不可写）也先停核心、释放单实例锁再退出，不留占着端口的孤儿核心。
- 防孤儿：核心子进程加入 Job Object（`KILL_ON_JOB_CLOSE`），壳崩溃时由内核终止核心树。
- 无窗口自检模式 `--selftest`：**不取壳互斥体**、不读用户配置、临时目录承载配置/锁/日志、当场取空闲端口 → 起核心 → `core.ping` → `HTTP GET /` 断言 `id="root"` → `core.shutdown` → 断言进程退出且锁可再取；供自动化冒烟使用，可与用户正在运行的壳并存（壳的窗口与托盘外观仍走视觉验收）。

**B. 固定端口成为配置项**
- `config.json` 新增顶层块 `core`，键 `core.port`（整数，1–65535），默认值由具名常量 `kDefaultCorePort` 给出（= 16705，出处见设计文档 D2）。
- 核心入口新增 `--port <n>`，取值优先级：`--port` > `core.port` > `kDefaultCorePort`（16705）；`--port 0` 只保留给**核心**侧调试与测试（交回 OS 分配）。
- **壳拒绝 `--port 0`**：壳必须导航到固定地址，0 端口只会得到一个空窗口。
- 端口被占用时**显式失败**并点名端口与改法（改 `core.port` 或 `--port`），**不静默换端口**——固定端口的全部价值在于这个地址是稳定的。
- 低端口（`<1024`）只说「容易撞系统服务、不推荐」：Windows 没有 Unix 式特权端口，对抗审查实测非提权绑定 80 / 1023 均成功，文档不再写「需要管理员权限」。

**C. 核心优雅停机 RPC**
- 新增 `core.shutdown`：**先回 `{ok: true}` 并把响应刷出**，再关通道、关服务器、销毁 Agent、关数据库、释放单实例锁，进程正常退出。先停机再回包会把响应吞掉，所以时序写死为「先回包、后停机」。
- 核心提供入口与测试共用的 `serveUntilShutdown()`；停机期间 `disposeAll` / 关库的异常进停机报告并写日志，有告警时退出码非 0（不静默当成功）。

**D. 构建与分发**
- 新增 `scripts/build_desktop_shell.ps1`：还原依赖 + 自包含发布到 `shell/dist/`（`AliasAgent.Desktop.exe` 双击即用）。
- **版本全部钉死**（漏写版本会被 NuGet 以 `NU1015` 拒还原）：`Microsoft.Web.WebView2` 1.0.4370.26（本机缓存）、`xunit` 2.9.3、`xunit.runner.visualstudio` 2.8.2、`Microsoft.NET.Test.Sdk` 18.12.0（包源索引 2026-11-24 实查）；测试工程必须同时有后两条，否则 `dotnet test` 发现不了用例。
- `global.json` 放在**仓库根**并钉住实际 SDK（11.0.100）——`dotnet` 只从当前目录向上找 `global.json`，放仓库根才能让 `dotnet publish` 与 `dotnet test shell/AliasAgent.Desktop.sln` 在仓库根直接跑就吃到同一个 SDK；测试命令是 `dotnet test shell/AliasAgent.Desktop.sln`。
- 依赖：自包含发布首次要下载 net10 的两个运行时包（`Microsoft.NETCore.App.Runtime.win-x64`、`Microsoft.WindowsDesktop.App.Runtime.win-x64`，上百 MB，需网络）；运行期要 WebView2 Evergreen 运行时（Windows 11 自带；本机实读注册表 `pv=157.0.4341.60`）与 PATH 上的 `dart`（本机 `Get-Command dart` 指向 `E:\Flutter\flutter\bin\dart.bat`）。
- `run.bat` 的五步**不动**：壳构建是独立脚本，不进 `run.bat`（那五步里有起窗步骤，受禁开窗规则管辖）。

**E. 文档同步（同一个 change 内）**
- 新建 `Docs/user-guide/desktop-shell.md`：怎么构建、怎么双击启动、托盘怎么用、怎么退出、固定端口怎么改、出错会看到什么、已知限制（含两把锁的区别、多用户撞端口、已知端口 + 无鉴权 + 本机网页可关停核心、自检端口竞态）、回滚注意。
- `Docs/user-guide/configuration.md` 配置键表加 `core` / `core.port` 行（默认值、范围、非法回落、降级边界），完整 JSON 示例补 `core` 块。
- `Docs/user-guide/web-core-shim.md` 改端口口径（删掉「写死默认值就是魔数」这类与新行为冲突的句子、保留 `http://127.0.0.1:<port>` 锚点、解释 `--port 0`）+ `core.shutdown` 表行；`Docs/user-guide/web-management.md` 的管理 RPC 表也补 `core.shutdown` 行。**两处守卫强度不同**：`web_core_docs_test` 按 RPC 表首列逐行核对，`web_management_docs_test` 只是整篇子串（`text.contains`）——后者补行是为了人读，不假装它按行校验。
- `README.md` 功能文档索引加壳文档；`Docs/TESTING.md` 增壳的测试层（`shell/test`，`dotnet test`）与 06 自检冒烟步骤（说明它不在 `run_all.sh` 聚合链里）。

**F. 明确不改**
- 不改 Flutter 界面、不改 web 客户端、不改数据模型与数据库结构、不改任何既有 RPC 的语义（`core.port` 只是新增块，`core.shutdown` 只是新增方法）。
- 不动 `TODO.md` 与 `Docs/RoadMap.md`（那是主循环的载体，本 change 不碰）；**不改 `CLAUDE.md` 的冒烟五步枚举**（改规则文件需要用户单独授权；本 change 只在 `Docs/TESTING.md` 里注明这条漂移，等用户决定）。
- 不接管「别人手工启动的核心」：壳发现锁被占用就报「已有核心在运行」并退出（见设计文档的开放问题）。
- 不引入鉴权、不做安装包、不做开机自启、不做托盘图标美术资源（首版用系统默认图标）。

## Capabilities

### New Capabilities
- `desktop-shell`: Windows 桌面壳的完整行为契约——双击启动（含启动失败资源回收）、固定端口、WebView2 窗口、启动期可见反馈、托盘后台常驻、单实例与前台激活、就绪探测、退出停核心（含极端兜底）、核心崩溃处理、无窗口自检模式。

### Modified Capabilities
- `web-core-shim`: 端口来源从「唯一由 OS 分配」改为「配置项 `core.port` + `--port` 覆盖 + 冲突可归因」，低端口口径改为「不推荐」；新增 `core.shutdown` 优雅停机（先回包再停机、停机告警可见）。
- `desktop-build`: 新增壳的构建产物与前置依赖约束（构建脚本、产物校验、依赖版本钉死、SDK 钉住与构建入口、自包含运行时包、与 `run.bat` 五步互不影响）。

## Impact

- 代码：`bin/alias_agent_core.dart`、新增 `lib/core/core_cli.dart`、`lib/core/headless_core.dart`（停机等待点 + 停机报告 + 端口绑定错误包装）、`lib/models/app_config.dart`（`core` 块）、新增 `shell/`（C# 壳与 xunit 测试工程）、仓库根 `global.json`（钉 SDK）、新增 `scripts/build_desktop_shell.ps1`、`.gitignore`（`shell/dist`、`bin`/`obj`）。
- 测试：`test/unit`（端口解析、`core.port` 解析、文档守卫）、`test/integration`（固定端口含子进程端到端、停机与数据完整性）、`shell/test`（壳纯逻辑，新层）、`test/smoke/06_desktop_shell.sh`（自检冒烟，不进聚合链）。
- 依赖与外部：.NET SDK 11.0.100（构建期）、net10 运行时包（首次自包含发布要下载）、WebView2 Evergreen 运行时（运行期，Windows 11 自带）、PATH 上的 `dart`（运行期，仓库既有前置）；NuGet 包全部钉版本。
- 安全面：固定端口把「无鉴权回环服务」从随机地址变成**已知地址**，且 `core.shutdown` 允许任何本机进程（含本机网页）关停核心；这是本 change 接受并**明确披露**的取舍（见设计文档风险表与用户文档已知限制）。
