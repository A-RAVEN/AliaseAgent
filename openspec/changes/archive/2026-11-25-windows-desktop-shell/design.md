## Context

**现状**（本 change 之前）：

- 界面有两条路：Flutter 应用（`flutter run` / `run.bat` 第 5 步）与「无头 Dart 核心 + 浏览器」。两条都要人手动起。
- 无头核心的端口**每次由 OS 分配**：`lib/core/headless_core.dart` 用 `HttpServer.bind(loopbackIPv4, 0)`，`kCoreUrlTemplate` 是 `http://127.0.0.1:<port>`，用户文档明说「`<port>` 是 OS 实际分配给这次进程的端口，不是配置值」。于是「把这个界面做成快捷方式/书签」在物理上不成立。
- 核心的单实例锁（`CoreInstanceLock`，`~/.aliasagent/core.lock`）只保证不双开，不提供任何「把已有实例叫出来」的能力。
- 关掉终端 = 关掉核心 = 关掉界面；没有「后台常驻」这一形态。

**用户目标**：双击即得窗口、关窗退到托盘、托盘菜单「退出」才真退。方向 B（桌面套壳）已由用户拍板。

**约束**：

- 禁开窗规则（`CLAUDE.md`）：本 change 的工件**不预写任何豁免句**；需要窗口的验收写成「用户当场许可后由主循环自己跑」。
- 魔数四类来源（`CLAUDE.md`）：本设计每一个数字都在文末「数字与出处」表里点名来源；写不出处的数字不进设计。
- 文档同 change 同步、任务点名测试层、先红后绿、测试输出可观察。
- 壳是**新语言、新工具链**：仓库此前没有 C# 代码。选型必须给可核的环境事实，不能凭印象说「装了」。

**本轮实读的环境事实**（是取舍依据，不是设计取值）：

| 事实 | 读法 | 结果 |
|---|---|---|
| .NET SDK | `dotnet --version` / `dotnet --list-sdks` | `11.0.100`、`9.0.310`（**没有 10.x SDK**） |
| 桌面运行时 | `dotnet --list-runtimes` | `Microsoft.WindowsDesktop.App` 有 8.0.34 / 9.0.23 / 10.0.15 / 11.0.0 |
| 目标框架引用包 | `C:\Program Files\dotnet\packs\Microsoft.(WindowsDesktop\|NETCore).App.Ref` | 有 `10.0.15`（因此 net10 目标可在本机构建） |
| 自包含运行时包 | `~/.nuget/packages\Microsoft.*.App.Runtime.win-x64` | **没有缓存** → 首次自包含发布要下载（上百 MB，需网络） |
| WebView2 运行时 | 注册表 `…\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` 的 `pv` | `157.0.4341.60` |
| WebView2 程序包 | `~/.nuget/packages\microsoft.web.webview2` | 已缓存 `1.0.4370.26`（只有一个版本） |
| xunit 三条包 | `~/.nuget/packages` 下 | **都没有缓存** → 首次还原需网络；版本按包源索引实查（见 D6 表） |
| `dart` 在 PATH 上的形态 | `Get-Command dart`、`where dart` | `E:\Flutter\flutter\bin\dart.bat`（**只有 .bat**，`where dart.exe` 无命中；真实可执行在 `bin\cache\dart-sdk\bin\dart.exe`） |
| Node | `node --version` | `v22.20.0` |
| 低端口是否需管理员 | 对抗审查本轮实测（非提权绑定 80 与 1023 均成功） | **Windows 没有 Unix 式特权端口**；`<1024` 只是容易撞系统服务，不是权限边界 |

`dart` 只有 `.bat` 这一条对壳有实际影响：`CreateProcess` 不能直接执行批处理，壳必须显式经 `cmd.exe /C` 启动，或落到 `dart-sdk` 里的 `dart.exe`（见 D3）。低端口那条影响的是文档口径：不许再写「需要管理员权限」（那是 Unix 事实，不是 Windows 事实）。

## Goals / Non-Goals

**Goals:**

- 双击一次拿到窗口：壳解析仓库根与端口 → 预检 → 起核心 → `core.ping` 通 → 开 WebView2 窗口加载固定地址。
- 端口固定且可配：`core.port` 配置项 + `--port` 覆盖，壳与核心取同一个值；被占用时显式失败并点名改法。
- 关窗 ≠ 退出：关窗隐藏、核心常驻、托盘图标在、双击托盘或菜单「打开窗口」回来；只有菜单「退出」才停核心并退出。
- 单实例：第二次双击唤起已有窗口后自己退出。
- 核心崩溃可归因：托盘气泡 + 日志 + 菜单「重启核心」；不做静默重启循环。
- 壳的**纯逻辑**（端口解析、仓库根定位、命令构造、就绪探测、单实例、关窗策略、状态机、菜单模型）能 `dotnet test` 覆盖；**链路**（起核心→就绪→静态页→停机）能用无窗口的 `--selftest` 自动跑。
- 文档与守卫同 change 落地：端口值、配置键、托盘文案、启动命令、构建脚本名都有能失败的守卫。

**Non-Goals:**

- 不做安装包、自动更新、开机自启、代码签名。
- 不做身份鉴权、不改「本机回环无鉴权」这条已知限制（只在文档里把「已知端口」的新风险写清）。
- 不改 Flutter 界面、不改 web 客户端、不改数据模型与数据库结构、不改既有 RPC 语义。
- 不接管「别人手工启动的核心」（壳发现锁被占用就报错退出，见开放问题）。
- 不把壳塞进 `run.bat` 的五个步骤（那五步里有起窗步骤）。
- 不做托盘图标美术资源、不做多窗口、不做窗口位置记忆落盘。
- 不做核心的编译产物分发（仍用 `dart run`，见开放问题）。
- 不改 `CLAUDE.md` 的冒烟五步枚举（那是需用户单独授权的规则改动；本 change 只在自己的文档里写清 06 步与它的关系）。

## Decisions

### D1 壳技术选型：C#（WinForms + WebView2 + NotifyIcon），目标 `net10.0-windows`

| 维度 | ① C# WinForms + WebView2 + NotifyIcon | ② Node/TS + `webview` + `systray` | ③ PowerShell + .NET WinForms 程序集 |
|---|---|---|---|
| 托盘 / 窗口 | `NotifyIcon` / `Form` 都是基础类库内建 | 两个原生依赖：窗口一个、托盘一个 | 与 ① 同一批程序集，但要靠脚本加载 |
| 工具链成本 | 本机已有 SDK 与桌面运行时（上表实读）；只需一次 NuGet 还原 | Node 已在，但 `webview` / `systray` 是原生扩展，要么预编译二进制对版本、要么本机 MSVC 编译 | 零新增工具链 |
| 与终态（C+++TS）的关系 | 过渡壳。产品契约是「固定地址 + 子进程生命周期」，换壳不动核心 | 过渡壳，语言更接近终态 | 过渡壳 |
| 可测试性 | 纯逻辑抽类 → xunit（`dotnet test`），不需要窗口 | 纯逻辑可 vitest，但托盘/窗口只能冒烟 | 脚本断言弱，无单测生态；窗口行为只能靠开窗看 |
| 分发 | `dotnet publish --self-contained` → 目录即产物，双击 exe | 需要 Node 运行时或单文件打包，原生扩展打包更脆 | 需要 `.ps1` + 执行策略，双击体验差 |
| 主要风险 | 新工具链（但环境已具备）；WebView2 依赖；首次运行时包下载 | 原生扩展与 Node 版本耦合；打包失败面大 | 脚本窗口程序的稳定性/启动延迟/退出语义都难保证 |

**选 ①**，理由三条：

1. **Windows 原生契合度**：托盘、窗口生命周期、命名互斥体、进程树终止、Job Object 全是系统与基础类库能力，不引入任何原生扩展；②③ 在这一层要么加原生依赖（②），要么把稳定性压在脚本宿主上（③）。
2. **成本可核**：本机 SDK、桌面运行时、net10 引用包都在（上表实读）；③ 省工具链但把「关窗隐藏 / 单实例 / 崩溃处理」这些**必须准确**的行为放进了最难测试的形态里。
3. **可测试性与可观察性**：壳的逻辑都是可以被 xunit 直接调的类；③ 没有等价物，② 的托盘部分同样不可测。本仓库的验收纪律是「能失败、能观察」，这一点权重高于「语言贴近终态」。

**目标框架改为 `net10.0-windows`（.NET 10 是长期支持版）**：原先写的 `net9.0-windows` 是标准支持版，2026-05 已停止支持，用它当新项目的目标框架等于一落地就欠一次迁移；本机已有 net10 引用包（`10.0.15`）与运行时（`10.0.15`），切过去没有额外成本。**注意**：本机没有 10.x SDK，构建用 SDK `11.0.100`（新 SDK 可以构建旧目标框架），这一点在仓库根 `global.json` 里钉住（见 D6）。

**被否方案**：

- **② Node/TS**：语言上最接近终态，但托盘与窗口各一个原生扩展，打包（Node 运行时或单文件）与原生二进制版本耦合会让「双击即用」变成最脆的一环；壳是过渡层，为过渡层引入这类脆弱性不值。
- **③ PowerShell + 程序集**：零新增工具链，但窗口程序的稳定性、启动延迟、退出语义都靠脚本兜；且没有任何单测形态能覆盖「关窗隐藏 / 单实例唤醒」。
- **④ Tauri（Rust）**：不在候选里也一并否掉——终态是 C++ + TS，Rust 不在其中；为一个过渡壳引入 Rust 工具链的构建成本最高。

**终态迁移说明**：壳只承诺「固定地址 + 起停核心 + 托盘」。等核心迁到 TS（路线 C 第四阶段），壳可以被任意技术重写而不动核心侧契约；本 change 的 `core.port` / `core.shutdown` 是**核心契约**，不是壳的实现细节。

**发布形态**：`dotnet publish -c Release -r win-x64 --self-contained true`。选自包含而不是框架依赖，是因为「双击即用」不该附带「先装桌面运行时」这一步；代价是产物体积与首次运行时包下载（见 D6 与风险表）。

### D2 固定端口：配置项 `core.port` + 具名常量，冲突显式失败

**取值链**（三处声明必须同源，由守卫绑定）：

```jsonc
// ~/.aliasagent/config.json
{ "version": 1, "core": { "port": 16705 }, ... }
```

| 位置 | 形态 | 作用 |
|---|---|---|
| `lib/models/app_config.dart` | `static const int kDefaultCorePort = 16705;` + `corePort` 字段 | Dart 侧默认值；`config.save` 写回时保留（见下） |
| `shell/AliasAgent.Desktop/DesktopOptions.cs` | `public const int DefaultCorePort = 16705;` | 壳在配置缺键时的默认值 |
| `Docs/user-guide/configuration.md` | 配置键表的 `core.port` 行（默认 16705、范围 1–65535） | 人读的登记处 |

`test/unit/desktop_shell_docs_test.dart` 同时读这三处并断言相等；**同时禁止第三份字面量**：扫描 `lib/**/*.dart` 与 `shell/**/*.cs`，`16705` 只允许出现在上述两处常量声明里（出现在别处即红）——只查「三处声明一致」会漏掉「有人在解析层又写了一个 16705」。

**优先级**：

```
--port <n>       （显式；核心：0 = 交回 OS 分配，调试用；壳：拒绝 0，见下）
core.port        （配置文件；core 块缺席/缺键/非法 → 落默认值）
kDefaultCorePort （出厂默认 16705）
```

- 核心入口：`resolveCorePort()` 按上表算出值后**显式**传给 `HeadlessCoreRunner.start(port: …)`。`HeadlessCoreRunner.start` 的既有默认值 `port = 0` **保持不变**——它是测试用的「OS 分配」形态，改动它会波及大量以随机端口并跑的既有集成测试。
- 壳：自己按同一张表算（`CorePortResolver`），再**显式**把 `--port <n>` 传给核心。壳是决策者，核心只执行；两边因此不可能各说各话。
- **壳拒绝 `--port 0`**：壳的全部意义是导航到 `http://127.0.0.1:<port>/`，端口为 0 时这个地址没有意义（只会得到一个空窗口）。`0` 只保留给核心侧调试与测试；壳收到 `--port 0` 时 SHALL 报错退出并说明「0 仅核心调试可用」。
- 非法值口径与产品既有先例一致（`AppConfig._parseToolParallelMax`）：`core.port` 不是「1–65535 的整数」时回落默认值并**打一行日志**（不静默、也不阻塞启动）；`--port` 是显式输入，非法即报错退出（不猜用户意图）。

**默认值 16705 的出处**（不是魔数，文末附录逐项核对）：

1. 它是**配置项默认值 + 具名常量**（`CLAUDE.md`「上下限四类来源」的第 4 类与第 2 类），登记在 `Docs/user-guide/configuration.md` 配置键表；
2. 数字本身取 `0x4141` = 16705（产品名缩写 AA 的 ASCII 十六进制），念得出来源，不是随手敲的；
3. 落在 IANA / RFC 6335 的**用户端口区 1024–49151**，避开 49152–65535 的动态区（那是 OS 分出向连接临时端口的区间，固定占用会跟出向连接抢）；
4. 避开产品里已经在用的回环地址：`3425`（magpie 网关默认**连出去**的地址，见 `lib/ui/providers_page.dart` 的 hintText 与 `lib/models/provider_config.dart` 注释；它不是本产品的监听端口）、`7890`（本机代理示例，见 `scripts/setup_searxng.bat` / `.sh` 的排错提示）、`8080`。
5. **明说边界**：这是产品自选值，不是任何平台硬限；用户可以改（`core.port` 或 `--port`）。所以设计不声称它「有外部标准依据」，只声称「来源链可核」。

**低端口的真实口径**：`<1024` **不是**权限边界——Windows 没有 Unix 式特权端口，对抗审查本轮实测非提权绑定 80 与 1023 都成功。所以设计、规范、用户文档一律只写「低端口容易与系统服务相撞，不推荐」，**不许**再写「需要管理员权限」。

**冲突行为**：端口被占用 ⇒ 核心把 `HttpServer.bind` 的失败包装成可归因启动异常（消息含端口号与「改 `core.port` 或用 `--port`」），壳把这条消息弹成对话框并退出。**不静默换端口**：固定端口的全部价值就是地址稳定，偷偷换端口等于把「快捷方式」变回随机。

**写回形态**：`AppConfig.toJson` 与 `spill` / `tool` 两个块同一口径——**总是写回** `core` 块。原因是 `ConfigService.save` 整份覆盖写盘，不写回就会在用户「保存一次 provider」之后丢掉这个键（`profile` 块踩过同一类问题的降级边界，文档里已有先例写法）。旧版本不认 `core` 块，用旧版本保存一次会丢它——这条降级边界写进 `Docs/user-guide/configuration.md`。

**安全取舍（明确披露）**：核心是「只绑回环、无鉴权」的服务。端口从随机变成已知，本机恶意网页更容易命中它，**而且 `core.shutdown` 让任何本机进程都能关掉核心**。本 change **不改**鉴权口径（那是一个独立 change），但把这两条写进用户文档的已知限制与本文风险表。

### D3 核心子进程：谁起、怎么起、怎么等、怎么停、崩了怎么办

**壳不做核心能做的事**：仓库根发现、端口解析、预检全在壳侧；核心只接受 `--port` / `--config` / `--web-root`。

**启动命令形状**：

```
<dart 可执行> run bin/alias_agent_core.dart --port <p> [--config <path>]
工作目录 = 仓库根（sidecar 以裸名字 DynamicLibrary.open('sidecar.dll') 加载）
```

**`dart` 解析顺序**（本机实读决定了必须写这一层）：

1. 环境变量 `ALIASAGENT_DART`（显式覆盖；测试与多 SDK 机器用）；
2. PATH 上的 `dart.exe`；
3. PATH 上的 `dart.bat` / `dart.cmd` → 经 `cmd.exe /C` 启动（本机就是这一条：`Get-Command dart` 指向 `E:\Flutter\flutter\bin\dart.bat`）；
4. 都没有 ⇒ 预检失败，对话框给「装 Flutter SDK 或把 dart 放进 PATH，或用 `ALIASAGENT_DART` 指定」。

**参数与引号规则**（`cmd.exe /C` 会把后整段再解析一次，这是唯一容易静默出错的地方）：

- 直启分支（`dart.exe`）：用 `ProcessStartInfo.ArgumentList` 逐个加参，由运行时负责引号；
- `cmd.exe /C` 分支：命令写成 `cmd.exe /C ""<dart.bat 绝对路径>" run bin/alias_agent_core.dart --port <p> --config "<path>""` ——**外层再多一层引号**（`/C` 的特例规则），含空格的路径各自加引号；
- 我们传给核心的路径（仓库根、配置文件、日志）在拼接前先断言**不含双引号**，出现即报错退出（宁可可归因失败，也不要拼出一条没被验证过的命令行）；
- 日志里记录**实际命令行**（只记录、不执行，便于事后核对引号是否如预期）。

**输出与日志**：标准输出/标准错误都重定向，**显式按 UTF-8 解码**（Dart 侧写 UTF-8；Windows 控制台默认代码页会把中文打成乱码，那就等于日志不可观察），逐行写入 `%USERPROFILE%\.aliasagent\logs\desktop-shell.log`（与 `sidecar.log` 同目录，产品既有约定），行首带 `[core]` 前缀。`cmd.exe` 自己的本地化错误行是 GBK：解码用 `allowMalformed` 兜底并在该行标注「解码失败已替换」，**不许静默丢行**。首版不做日志轮转（写进已知限制）。

**就绪探测**：`ClientWebSocket` 连 `ws://127.0.0.1:<p>/ws` 发 JSON-RPC `core.ping`，收到 `result.ok = true` 才算通。重试间隔 1000 毫秒、单次等待上限 5000 毫秒、总预算 30000 毫秒（出处见附录；这三个是**壳自己的**等待参数，数值借自 `web/src/tokens.ts`，语义不同——见附录第 5 条）。探测与「子进程已退出」**同时监听**，先到者决定结果：

- 就绪前子进程退出 ⇒ 判定启动失败，对话框给退出码、日志路径与**最后一行输出**（一行，不是阈值）；
- 预算耗尽 ⇒ 停止核心，对话框给「核心在 30000 毫秒内没有响应 core.ping」+ 日志路径。

**30000 毫秒是不是够**：首次 `dart run` 需要编译内核，冷启动可能接近预算。本 change **不**假设它够：6.3 有一条实测任务记录首次启动到 `core.ping` 通的耗时；若接近或超过预算，按实测提返工（把预算做成配置项），**不许**偷偷放宽断言或改测试。

**停止（礼停 + 兜底 + 防孤儿）**：

1. 置 `exitRequested`（之后的 `Exited` 不算崩溃）；
2. 经 WS 发 `core.shutdown`，等核心自己走完停机（见下「停机时序」）并退出，最多 5000 毫秒；
3. 未退出则 `Kill(entireProcessTree: true)`（`Process.Kill` 的进程树形态），再等 5000 毫秒确认；
4. 仍未退出（极端异常，例如句柄被占用且终止被拒）⇒ **写日志点名 pid 与超时，托盘气泡在释放图标之前发**，壳照常退出。这是**异常兜底**，不是正常路径；「正常退出必须停掉核心」这条不放宽（规范里同时写普通条款与兜底例外）。
5. **防孤儿**：壳在启动核心后把该子进程加入一个 Job Object，并设置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`。壳进程无论正常退出还是崩溃，最后一个 Job 句柄一关，内核直接终止核心进程树——避免「壳崩了，核心成孤儿继续占着端口」。Job 句柄与互斥体一样作为字段持有（防 GC 提前回收）。已知限制：若将来给核心进程设置 breakaway 就会脱离这个 Job，本 change 不设。

**停机时序（`core.shutdown` 必须先回包、再停机）**：

WS 响应是排队的；如果 handler 先触发 `stop()`，`stop()` 会把客户端连接以 going-away 关掉，而响应还排在队列里 → 壳拿不到 `{ok:true}`，看起来像「调了但没回」。因此：

1. handler 只返回 `{ok: true}` 并登记「响应刷出后」回调；
2. WS 侧对这条响应先 `socket.add(...)`，再 `await socket.close(...)`（Dart 的 `WebSocket.close()` 会先把排队消息发完再关连接），然后才 complete 停机信号；
3. 等待方（入口与测试共用的 `serveUntilShutdown()`，见下）收到信号后执行 `stop()`。

**`serveUntilShutdown()`：入口与测试共用的停机等待点**。`HeadlessCore` 提供 `Future<ShutdownReport> serveUntilShutdown()`：内部等「`core.shutdown` 的响应已刷出」或 SIGINT，然后调 `stop()` 并返回停机报告。入口（`bin/alias_agent_core.dart`）与集成测试用**同一个方法**——测试不许自己拼一套停机序列，否则测试验的是测试自己。

**停机异常必须可见**：`stop()` 现在把 `agents.disposeAll` / `DatabaseService.close` 的异常吞成一句 `debugPrint`。本 change 改为收集进 `ShutdownReport.warnings`：每条 warning 写进核心日志，且**有 warning 时进程退出码非 0**（`kExitCodeShutdownWithWarnings = 3`，与既有的 1=启动失败、2=参数错误区分）。壳侧对应处理：停机是自己要求的（`exitRequested`），退出码 3 记成「核心停机有告警」而不是崩溃，但同时写日志，不静默当成功。

**停机与在途发送的顺序**：`Agent.cancel()` 是同步 `void`（只置取消标志、不等待整轮结束），所以「收尾事件在通道关闭前到达」这件事**必须有显式等待点**，否则实现上不成立。`stop()` 的顺序因此是：① 对所有运行中的 Agent 调 `cancel()`；② `await` 每个实例的 `waitForRounds()`（`lib/services/agent.dart` 里既有方法，`Agent.dispose()` 内部也用它）——在途整轮收尾、事件仍可经 WS 发出；③ 关 WS；④ 关服务器；⑤ `disposeAll()`（幂等）；⑥ 关数据库；⑦ 放锁。少了第 ② 步就只剩「置了标志就关通道」，客户端收不到收尾事件。

**崩溃**：运行中 `Exited` 且不是我们要求的退出 ⇒ 状态转 `CoreCrashed`：托盘气泡（退出码 + 日志路径）、托盘菜单出现「重启核心」、窗口若可见则用 WebView2 的 `NavigateToString` 就地显示可归因错误页（不弹一堆对话框）。**不自动重启**：没有可核的重试上限来源，自动重启会把「为什么崩」掩盖成「一直闪」；重启是用户的一次显式点击。重启 = 重新走 `StartingCore`，成功后重新导航窗口。

进程状态机：

```
Resolving ──失败──> FatalDialog ──> Exit(非零)
   │
   └─> StartingCore（此时托盘图标已建） ──进程提前退出──> StartFailedDialog ──> Exit(非零)
          │
          └─> WaitingReady ──预算耗尽──> StopCore ──> StartFailedDialog ──> Exit(非零)
                 │
                 └─ Ready ──> WindowShown ⇄ HiddenToTray
                                   │              │
                                   └── 非预期退出 ─┴──> CoreCrashed
                                                          ├─ 菜单「重启核心」──> StartingCore
                                                          └─ 菜单「退出」 ──> Stopping ──> Exit(0)
```

### D4 窗口与托盘生命周期

- **启动期就要有可见反馈**：托盘图标在 `StartingCore`（拉起核心之前）就创建，提示文字「AliasAgent 正在启动核心」；此阶段的菜单只有「退出」（「打开窗口」禁用或显示「正在启动」）。这样「冷启动最多 30000 毫秒」不会变成「什么都没有发生」。
- **窗口**：`Form` 承载 `WebView2` 控件；标题 `AliasAgent`；首次打开即最大化（`WindowState.Maximized` + 居中起始位置）——**不引入「屏宽百分之多少」这种新数字**。同一进程内关窗再打开，保持上次的窗口状态（内存态，不落盘）。
- **WebView2 初始化**：先用 `CoreWebView2Environment.CreateAsync(browserExecutableFolder: null, userDataFolder: <用户数据目录>, options: null)` 建环境，再把该环境传给 `EnsureCoreWebView2Async(env)`。用户数据目录用 `%LOCALAPPDATA%\AliasAgent\WebView2`（放本机应用数据目录，不放 `~/.aliasagent`，避免把浏览器缓存与配置/数据库混放，也便于整目录删除）。之后 `Navigate("http://127.0.0.1:<p>/")`。
- **WebView2 初始化失败要回收资源**：运行时缺失、用户数据目录不可写等导致 `CreateAsync` / `EnsureCoreWebView2Async` 抛错时，壳 SHALL 先停核心、释放单实例锁，再弹可归因对话框并退出（非零）。**不许**留下一个占着固定端口、没人管的孤儿核心——那会让下次启动报「已有核心在运行」，看起来像壳坏了。对话框文案：缺运行时说「缺 WebView2 运行时（Windows 11 自带，缺失需安装 Evergreen 版）」；目录不可写就说目录与原因。本 design **不写死下载链接**（避免把未经核对的网址写进工件，见开放问题）。
- **导航失败**：`NavigationCompleted` 失败 ⇒ 就地上错误页（`NavigateToString`，写清状态码/原因与「从托盘关掉窗口再打开可重试」）；重新打开窗口时若上次是错误页则重新导航一次。
- **关窗**：`FormClosing` 若用户点的是关闭按钮（且不是 `exitRequested`）⇒ `e.Cancel = true` + `Hide()`；**第一次**隐藏后弹一次托盘气泡「AliasAgent 仍在后台运行：双击托盘图标可重新打开，右键菜单可退出」。这条提示是防「幽灵进程」困惑的唯一可见信号。
- **托盘**：`NotifyIcon`（首版用 `SystemIcons.Application`，没有专属图标）+ `ContextMenuStrip`：
  - 「打开窗口」（默认项）→ `Show()` + `WindowState` 还原 + 激活；
  - 「退出」→ 停核心 → 隐藏并 `Dispose` 托盘图标 → `Application.Exit()`；
  - 仅 `CoreCrashed` 态插入「重启核心」；
  - 双击托盘 = 「打开窗口」。
  - 气泡统一走 `ShowBalloonTip(kBalloonTipTimeoutMs)`：这个 API **必须传超时**（没有无参重载），Vista 之后实际显示时长由系统控制，所以这个值只是满足签名的占位（出处见附录），不是我们定义的行为参数。
- **前台激活（Windows 前台锁）**：第二个实例被前台启动时，光给第一个实例发事件还不够——第一个实例调 `SetForegroundWindow` 会被前台锁拦住。**pid 从哪来**：互斥体与命名事件都不携带数据，所以第一个实例启动时把**自己的 pid 写进命名共享内存**（`Local\AliasAgent.Desktop.State`，`MemoryMappedFile` 里 4 字节 pid；只放内存，不落临时文件，避免权限与清理问题）。第二个实例的顺序是：读共享内存拿 pid → `AllowSetForegroundWindow(该 pid)` → 置命名事件；若共享内存读不到（旧版本残留、映射被占用），退化为 `AllowSetForegroundWindow(ASFW_ANY)` 并在日志里写明「退化为 ASFW_ANY」——`ASFW_ANY` 的权限面更宽，只作兜底、不作默认。第一个实例收到事件后 `Show()` + `SetForegroundWindow(Handle)`。若第一个实例**窗口还没就绪**（仍在起核心），把这次请求记成 pending，等就绪开窗时直接显示，而不是丢弃。

窗口/托盘状态机（与 D3 的进程态同表驱动，抽成可单测的策略类）：

| 当前态 | 事件 | 新态 | 可见效果 |
|---|---|---|---|
| StartingCore | 启动中 | StartingCore | 托盘图标已在，菜单只有「退出」 |
| WindowShown | 用户点关闭 | HiddenToTray | 窗口隐藏；首次弹一次托盘气泡 |
| HiddenToTray | 托盘双击 / 「打开窗口」 | WindowShown | 窗口显示并激活（`SetForegroundWindow`） |
| 任何态（窗口未就绪） | 第二实例请求打开 | 记 pendingOpen | 就绪开窗时直接显示 |
| WindowShown | 「退出」 | Stopping | 先 `core.shutdown`，再退出 |
| HiddenToTray | 「退出」 | Stopping | 同上 |
| WindowShown / HiddenToTray | 核心非预期退出 | CoreCrashed | 气泡 + 菜单加「重启核心」+ 窗口显示错误页 |
| CoreCrashed | 「重启核心」 | StartingCore | 重新起核心，成功则回 WindowShown |
| StartingCore / WaitingReady / WindowShown | 重启失败 | CoreCrashed | 本轮起的核心被回收；气泡 + 错误页 + 日志点名原因与日志路径；壳不退出、菜单仍含「重启核心」 |

**重启失败与首次启动失败分流**（任务 6.1e）：首次启动失败仍是「停核心 + 放锁 + 非零退出」（spec「启动失败的资源回收」）；崩溃后的显式重启失败**不许**把壳带走——只回收本次起的核心与 Job 句柄（**不释放托盘图标、不释放壳单实例锁**），迁回 `CoreCrashed` 并给出可归因提示，保持「重启核心」可用（spec「核心崩溃可归因且可显式重启」正文与 Scenario「显式重启恢复」）。

### D5 单实例与跨会话/跨用户

- `Mutex(initiallyOwned: true, name: @"Local\AliasAgent.Desktop.SingleInstance", out createdNew)`；`createdNew == false` ⇒ 这是第二个实例：从命名共享内存 `Local\AliasAgent.Desktop.State` 读出第一个实例的 pid（第一个实例启动时写入）→ `AllowSetForegroundWindow(该 pid)` → `EventWaitHandle.Set()` 通知第一个实例「打开窗口」→ 自己以 0 退出。三个命名对象（互斥体、事件、共享内存）统一用 `Local\` 前缀，作用域一致，都只在本登录会话内有效。
- 第一个实例在后台线程 `WaitOne()` 等这个事件，收到后切到界面线程 `Show()`（或记 pendingOpen）。
- 互斥体与事件句柄都作为字段持有（**不要只放在局部变量里**——句柄被 GC 提前回收会让单实例守卫时有时无）。
- 用 `Local\` 而不是 `Global\`：这两个对象的作用域是**当前登录会话**，与「每用户一份配置与数据库」的口径一致。
- **跨会话/跨用户是另一种冲突，壳的互斥体管不了**：回环端口是**机器级**资源。两个 Windows 登录会话各自起壳时，各自都通过 `Local\` 互斥体（互不冲突），但都会去绑同一个默认端口 16705 → 第二个壳拉起的核心 bind 失败，走「端口被占可归因」路径。**这是已知限制**：同一台机器多用户/多会话要同时用，得给其中一个改 `core.port`。文档写清。
- 与核心的单实例锁**是两把不同的锁**：壳的互斥体挡双开壳；核心的锁文件挡双开核心。文档必须把这两件事分开写。

### D6 构建与分发

- **包版本必须钉死**（不写版本 ⇒ NuGet 报 `NU1015`，还原直接失败）。版本事实源与取值：

| 包 | 版本 | 出处 |
|---|---|---|
| `Microsoft.Web.WebView2` | `1.0.4370.26` | 本机 NuGet 缓存实读（`~/.nuget/packages/microsoft.web.webview2`） |
| `xunit` | `2.9.3` | 包源索引实查（`https://nuget.azure.cn/v3-flatcontainer/xunit/index.json`，2026-11-24） |
| `xunit.runner.visualstudio` | `2.8.2` | 同上（`…/xunit.runner.visualstudio/index.json`；2.x 末版，配 xunit 2.x） |
| `Microsoft.NET.Test.Sdk` | `18.12.0` | 同上（`…/microsoft.net.test.sdk/index.json`） |

测试工程**必须同时**引用 `Microsoft.NET.Test.Sdk` 与 `xunit.runner.visualstudio`，否则 `dotnet test` 根本发现不了用例（呈现为“跑过了、0 个测试”这种更糟的假绿）。工程里对这三条 + WebView2 全部写死版本号，不许用 `*` 或浮动版本。**兼容性兜底**：若 `18.12.0` 与本机 `dotnet test` 的 VSTest 路径不兼容，允许钉回同源索引里同样存在的 `17.14.2` 并在 change 报告里写明原因——版本可以改，但必须**写死且记录**，不许换回浮动版本。

- **SDK 钉住**：`global.json` 放在**仓库根**（不是 `shell/`），钉本机实际 SDK `11.0.100`（`rollForward: latestPatch`）。原因是 `dotnet` 只从**当前工作目录**向上找 `global.json`：放仓库根以后，`dotnet publish`、`dotnet test shell/AliasAgent.Desktop.sln`、`dotnet build` 从仓库根直接跑都能读到同一个钉住的 SDK；放 `shell/` 则三个命令都要先 `Push-Location shell` 才读得到，谁也记不住。本仓库只有壳用 .NET，放根上不影响 Flutter/Dart 流程。
- **自包含发布要下载运行时包**：`--self-contained true -r win-x64` 需要 `Microsoft.NETCore.App.Runtime.win-x64` 与 `Microsoft.WindowsDesktop.App.Runtime.win-x64` 两个运行时包，**本机 NuGet 缓存里都没有** → 首次发布会下载上百 MB。这一步离线必失败，脚本要把它归类成「网络/包源原因」，而不是含糊的「构建失败」。
- 脚本 `scripts/build_desktop_shell.ps1`（从仓库根执行，因此读得到仓库根 `global.json`）：
  1. 检查 `dotnet --version`（缺失给可归因错误），并打印实际 SDK 版本（与 `global.json` 对照）；
  2. `dotnet publish shell/AliasAgent.Desktop/AliasAgent.Desktop.csproj -c Release -r win-x64 --self-contained true -o shell/dist`；
  3. 校验产物：`shell/dist/AliasAgent.Desktop.exe` 与 `WebView2Loader.dll` 都在，缺任一即失败退出（不产出半份）；
  4. 打印产物路径与「双击哪个文件」。
- **C# 测试命令**：`dotnet test shell/AliasAgent.Desktop.sln`（从仓库根跑；测试工程在 `shell/test/AliasAgent.Desktop.Tests/`，解决方案在 `shell/` 顶层——直接给测试工程目录路径会找不到工程文件）。
- 失败即中止并打印真实错误（与 `run.bat` 的 `abort on critical command` 同一纪律）。
- `.gitignore` 增 `shell/dist/`、`shell/**/bin/`、`shell/**/obj/`（自包含产物上百兆，绝不入库；写法与仓库既有的 `**/` 风格一致）。
- 与 `run.bat` 的关系：**互不影响**。`run.bat` 仍是 Flutter 应用的五步流程，第 5 步起窗受禁开窗规则管辖；壳构建是单独的脚本，不进那五步，也不在任何测试入口里被隐式触发。

### D7 可观察性与无窗口自检模式

- 日志：`%USERPROFILE%\.aliasagent\logs\desktop-shell.log`，事件按行写（解析到的仓库根/端口/配置、**实际命令行**、就绪探测每次尝试与结果、停机与退出码、崩溃原因、Job Object 关联结果）。对话框只给**退出码 + 日志路径 + 最后一行输出**，细节进日志。
- `--selftest`（无窗口）必须与「用户此刻正开着壳」并存，因此四件事一起做：
  1. **不获取壳的命名互斥体**：`--selftest` 在取互斥体**之前**分流，直接走自检，不参与单实例守卫；
  2. **临时 `--config`**：显式传 `--config <临时目录>\config.json`（空配置启动即可），不读用户真实配置；
  3. **临时数据与锁**：子进程环境里 `USERPROFILE` 指向临时目录（`ConfigService` / 数据库 / 附件 / spill / 日志全在 `%USERPROFILE%\.aliasagent` 下），并再显式传 `--lock <临时目录>\core.lock`；壳自己的自检日志也写临时目录（`desktop-shell-selftest.log`），不污染用户 `logs/`；
  4. **端口当场取空闲的**：先 `TcpListener` 绑 0 拿到一个空闲端口、立刻释放、再把该端口显式传给核心。
- **端口竞态如实记**：从「释放端口」到「核心 bind」之间理论上有被抢的窗口（TOCTOU），自检因此**不是**确定成功；被抢时会得到可归因的 bind 失败（不是假绿）。不做「换端口重试」——那会把真实占用掩盖成偶发。
- 自检步骤与判据：`web/dist/index.html` 存在 → 起核心（第 1 个）→ `core.ping` → `HTTP GET http://127.0.0.1:<p>/` 断言 200 且正文含 `<div id="root">` → `core.shutdown` → 断言第 1 个进程 0 退出 → 用同一把锁**再启动一次**（第 2 个）断言成功（证明锁确实释放）→ **对第 2 个也发 `core.shutdown` 并等它退出**（自检不许以「只验锁释放」为由留一个孤儿核心；Job Object 只是兜底，不是收尾手段）→ 退出码 0。每步打印 `[SELFTEST] <步骤> <结果>`，失败打印原因并非零退出。
- **「不取互斥体」必须有失败用例**：另起一个进程先占住 `Local\AliasAgent.Desktop.SingleInstance`（`powershell -NoProfile` 里 `new Mutex($true, 'Local\\AliasAgent.Desktop.SingleInstance')` 并保持存活），再跑 `--selftest`——必须照样跑完全部步骤且绿、不弹窗；若自检真的去取互斥体，它会把自己判成「第二个实例」直接退出（`[SELFTEST]` 步骤行缺失），这条用例就会红。
- 自检**不开窗口、不建托盘图标**：它验的是「起核心→就绪→静态页→停机」这条链路，窗口与托盘外观属于视觉验收。

### D8 测试策略（每条都能失败）

| 层 | 位置 | 验什么 | 失败判据（坏了会红的行为） |
|---|---|---|---|
| 单元（Dart） | `test/unit/core_cli_args_test.dart` | `--port` 解析/校验、优先级 `--port` > `core.port` > 默认、`--port 0` 保留 OS 分配、帮助文案含 `--port` | 端口优先级算错、非法端口被接受、帮助里没有 `--port` |
| 单元（Dart） | `test/unit/app_config_core_port_test.dart` | `core.port` 解析（缺块/缺键/非整数/越界回落默认并**留一行日志**）、写回保留、`copyWith` 保留 | 缺键时不是默认值、非法值抛异常或无日志、保存一次就丢键 |
| 单元（Dart） | `test/unit/desktop_shell_docs_test.dart` | 三处默认端口一致 + `16705` 无第三份字面量 + `resolveCorePort` 实际返回值 == 常量；配置键表有 `core.port` 行且含范围与回落说明；用户文档含托盘文案/`--selftest`/构建脚本名/README 索引 | 改一处常量或文案而文档没跟；有人在别处又写了 16705 |
| 集成（Dart，进程内） | `test/integration/web_core_fixed_port_test.dart` | 由配置算出端口后核心真的绑在它上面并可 `core.ping`；`--port` 覆盖配置；端口被占时抛可归因异常（消息含端口与 `core.port`） | 核心绑到别的端口、覆盖不生效、占用时抛裸 `SocketException` |
| 集成（Dart，**子进程端到端**） | 同上文件后半 | 经 `cmd /c dart run bin/alias_agent_core.dart` 起真进程（临时 `USERPROFILE` / `--config` / `--lock` / 临时库），断言启动输出里的端口 == 配置值、`--port` 覆盖生效、端口被占时进程以可归因消息退出 | 只测「进程内传端口」会漏掉「入口根本没接线」——`--port` 没接进 `bin` 时这条必须红 |
| 集成（Dart） | `test/integration/web_core_shutdown_test.dart` | `core.shutdown` 在清单里、调用返回 `ok`；`serveUntilShutdown()` 完成后服务器关闭、锁释放；停机前建一条会话，重启后仍可读（数据完整性） | 方法未注册、调用后不停机、锁没放、或走了强杀导致数据不可读 |
| 单元（C#） | `shell/test/AliasAgent.Desktop.Tests/` | 选项解析（含拒绝 `--port 0`）、端口解析、仓库根定位、`dart` 解析（注入环境/PATH）、命令形状与引号规则、就绪探测（进程内假 WebSocket）、单实例、关窗策略、托盘菜单模型（含启动期与崩溃态）、崩溃状态机、WebView2 失败映射（注入工厂抛错断言「停核心+放锁」决定） | 任一纯逻辑行为偏离设计（每条用例对照 D2–D5 的一条断言） |
| 冒烟 | `test/smoke/06_desktop_shell.sh`（单独跑，不挂 `run_all.sh` 聚合） | 脚本**自己**检查 `dotnet` 是否存在（**不进 `utils.sh` 的 `check_deps`**——那里加依赖会让没装 dotnet 的机器上既有 01–05 提前失败）；缺 `web/dist` 时先构建；跑 `dotnet test shell/AliasAgent.Desktop.sln`；构建壳；跑 `--selftest`；再在「有人占住壳互斥体」的条件下跑一次自检 | 自检任一步失败、产物缺失、脚本触发起窗步骤、或把 `dotnet` 检查塞进 `check_deps` 连累既有流程 |
| 实测 | 6.3 | 首次 `dart run` 冷启动到 `core.ping` 通的耗时 | 不记录、或超过预算却偷偷放宽断言 |
| 视觉验收 | 壳窗口 + 托盘（**需用户当场许可开窗**） | 见 6.2 的八项判读 | 截图里看不到界面/托盘图标/菜单项，或关窗后进程消失 |

**C# 侧的接缝要求**（否则「纯逻辑可测」是空话）：命令构造、环境变量、时钟/超时、日志落点、WebSocket 服务端、WebView2 环境工厂一律**构造函数注入**；测试里用假 WebSocket（`TcpListener` + 手写升级握手 + `WebSocket.CreateFromStream(..., isServer: true, ...)`，避开 `HttpListener` 的 URL ACL 前置）、假时钟、内存日志；失败时用 xunit 的 `ITestOutputHelper` 打印实际观察值（命令串、超时次数、菜单项集合），不许只输出「断言失败」。

**测试层登记**：`shell/test`（`dotnet test`）是仓库此前没有的层，本 change 在 `Docs/TESTING.md` 里登记它的位置、跑法与它能测/不能测什么（窗口与托盘外观不可自动测，靠视觉验收兜底）。

### D9 文档同步与守卫

| 文档 | 改什么 | 守卫 |
|---|---|---|
| `Docs/user-guide/desktop-shell.md`（新建） | 构建、双击启动、托盘、退出、固定端口怎么改、出错会看到什么、已知限制、测试命令；**两把锁的区别**（壳互斥体 vs 核心锁文件） | `test/unit/desktop_shell_docs_test.dart` 断言文案锚点与代码常量一致 |
| `Docs/user-guide/configuration.md` | `core` / `core.port` 行（默认 16705、范围、非法回落、旧版本会丢键的降级边界）；**完整 JSON 示例里加上 `core` 块** | 同上（读配置键表行断言 `core.port` 与默认值） |
| `Docs/user-guide/web-core-shim.md` | 端口口径改写（固定端口 + 优先级 + `--port 0` 解释 + 低端口只是不推荐）；**删掉/改写**「不使用任何默认端口（端口是 OS 分配的，写死默认值就是魔数）」这类与新行为冲突的句子；**保留** `http://127.0.0.1:<port>` 锚点（既有守卫读 `kCoreUrlTemplate`）；`core.shutdown` 表行；已知限制补「已知端口 + 无鉴权 + 本机网页可关停核心」 | 既有 `test/unit/web_core_docs_test.dart` 会自动变红（`kCoreRpcMethodNames` 加了方法），补文档表行转绿 |
| `Docs/user-guide/web-management.md` | 管理 RPC 表补 `core.shutdown` 行（补它是为了让读文档的人能在表里找到，不是为了满足逐行检查） | 既有 `test/unit/web_management_docs_test.dart`——**它只是整篇子串检查**（`text.contains(method)`），不是按表行；`web_core_docs_test` 才是「按 RPC 表首列逐行核对」。本 change 如实写明这条强度差异，不假装两处守卫一样强；要让管理文档也按表行校验，须先把它的 RPC 表补全所有方法（那是另一个 change 的范围） |
| `README.md` | 功能文档索引加壳文档 | 同上守卫（索引里必须出现该路径） |
| `Docs/TESTING.md` | 壳测试层与 06 自检步骤 | 不做机器守卫（分层文档靠人读），但在任务里点名 |

**与 `CLAUDE.md` 五步枚举的漂移**：加 06 会让「整套冒烟」在 `CLAUDE.md` 里仍写着五步，这是**记录漂移**。改 `CLAUDE.md` 需要用户单独授权，本 change **不擅自改**，只在 `Docs/TESTING.md` 写清「06 是新增的无窗口步骤，不等于 CLAUDE 五步中的 04/05」，并在 change 报告里点名这条漂移等用户决定。

### D10 明确不做（边界）

- 不做「接管已运行核心」（adopt）——见开放问题。
- 不做核心编译产物（`dart compile exe`）分发——见开放问题。
- 不做托盘图标资源、窗口位置落盘、多窗口、开机自启、安装包、自动更新、鉴权。
- 不改 `run.bat` 与 `test/smoke/run_all.sh` 里既有的起窗步骤（也不把它们当成本 change 的验证手段）。

## Risks / Trade-offs

| 风险 | 缓解 / 披露 |
|---|---|
| **新工具链**（仓库首次引入 C# / .NET / WebView2） | 环境事实先实测再选型（上表）；构建脚本失败即中止并分类网络/环境原因；产物不进仓库；`dotnet test` 只覆盖纯逻辑，链路靠 `--selftest`，外观靠视觉验收——三层各管一段，不假装其中一层能顶另一层 |
| **首次发布会下载运行时包**（两个 `*.App.Runtime.win-x64`，本机无缓存，上百 MB） | 写进 D6 与构建提示；离线失败归类成网络/包源原因；不把「网络慢」报成代码错误 |
| **WebView2 运行时缺失** | Win11 自带（本机实读 `pv=157.0.4341.60`）；缺失时初始化抛错 → **先停核心、放锁**再弹可归因对话框；写进用户文档「出错时会看到什么」 |
| **WebView2 初始化失败留下孤儿核心** | 初始化失败路径显式 `StopCore` + 释放互斥体（D4）；外加 Job Object 兜底（壳崩了内核杀核心树） |
| **壳崩溃导致核心成孤儿** | Job Object + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`（D3）；Job 句柄字段持有防 GC |
| **固定端口被占** | 核心把绑定失败包装成可归因异常（点名端口 + 改法），壳弹窗退出；不静默换端口 |
| **固定端口 + 无鉴权 = 已知地址，且 `core.shutdown` 可被任何本机进程调用** | 明确披露：写进用户文档已知限制与本文风险表；本 change 不改鉴权口径；需要时另立 change |
| **跨用户/跨会话撞端口** | 回环端口是机器级资源，`Local\` 互斥体只管壳；第二个会话会得到可归因的「端口被占」。已知限制，文档写清「多用户同机需给其中一个改 `core.port`」 |
| **核心崩溃** | 不自动重启（避免掩盖崩溃原因）；托盘气泡 + 日志 + 「重启核心」菜单；窗口就地显示错误页 |
| **幽灵进程困惑**（关窗后以为退了） | 第一次隐藏时弹一次托盘气泡；托盘图标常驻；文档写清「关窗 ≠ 退出」 |
| **冷启动可能接近 30000 毫秒预算** | 6.3 实测并记录；超预算按实测提返工（做成配置项），不许偷偷放宽断言 |
| **自检的端口 TOCTOU** | 如实记录为「非确定成功」：被抢会得到可归因失败，不做换端口重试掩盖 |
| **`cmd.exe /C` 引号与 GBK 错误行** | D3 规定外层引号、路径断言不含引号、日志记实际命令行；解码 `allowMalformed` 并标注替换，不静默丢行 |
| **托盘/窗口外观无自动测试** | 如实登记为覆盖缺口：策略类用 xunit、链路用自检、外观只能视觉验收（需用户当场许可开窗）；不把「策略类过了」说成「界面没问题」 |
| **首版无日志轮转** | 写进已知限制；日志路径与「体积会增长」都明说 |

## Migration Plan

1. **不启动壳、不跑新测试时**：Flutter 应用与「手工起核心 + 浏览器」两种用法都仍在，配置与数据库结构不变（`core` 块是新增可缺省块）。但**不完全是零变化**——见第 2 条。
2. **核心端口默认值变化（有意的）**：以前不带参数启动核心拿到的是随机端口；本 change 起默认绑定配置值/默认 16705。三条影响要说清：① 若默认端口已被别的程序占用，手工启动从「总能起来」变成「可归因失败」（用 `--port 0` 或改 `core.port` 解除）；② 手工启动的核心与壳、或两份手工核心会互相拒绝（同一固定端口 + 同一把锁），这正是「同一时刻只跑一个核心」的约定；③ 旧文档里「端口随机、不写死」的说法必须同步改。旧的随机形态仍可用 `--port 0` 显式取得（测试与调试依赖它）。
3. **首次构建壳**：`powershell -NoProfile -File scripts\build_desktop_shell.ps1`（从仓库根执行、读仓库根 `global.json` 钉的 SDK；首次需网络还原 WebView2 程序包与 net10 运行时包，后者上百 MB）；之后双击 `shell/dist/AliasAgent.Desktop.exe`。
4. **配置降级边界**：旧版本不认识 `core` 块，用旧版本保存一次配置会丢掉它（退回默认 16705）。要回退版本前先备份 `~/.aliasagent/config.json`——与 `profile` 块同一条边界。
5. **回滚**：不启动壳即回到现状；删除 `shell/`、构建脚本与 `.gitignore` 里的三行即可（核心与 web 客户端不受影响，`core.shutdown` 是新增方法，不调用就无影响）。**注意**：删掉 `shell/` 之后 `test/unit/desktop_shell_docs_test.dart` 会因为没有 C# 常量而红——回滚必须把这条守卫与壳一起删（或一起留），不许只删一边让它长期红着。

## Open Questions

1. **是否接管已运行的核心**：用户若手工起过核心，壳现在是「报已有核心在运行并退出」。要不要改成「探测到 `core.ping` 通就直接开窗、退出时不停别人的核心」？涉及「谁拥有这个进程」的语义，本 change 不做。
2. **核心是否改为编译产物**：`dart compile exe` 能去掉运行期的 PATH 依赖并缩短启动时间，但要新增一份构建产物与「DLL 从哪加载」的约定；留后续 change。它同时能消掉本 change 里 `cmd.exe /C` 的引号分支。
3. **WebView2 运行时缺失时的下载引导**：要不要在对话框/文档里给官方分发页链接（需核对网址，本轮不写，避免把未核对的链接写进工件）。
4. **窗口位置与大小是否落盘**：首版只在内存里保留本次运行的状态。
5. **托盘图标**：首版用系统默认图标；要不要做专属 `.ico`。
6. **鉴权**：固定端口把「无鉴权回环服务」变成已知地址，且 `core.shutdown` 允许本机进程关停核心，是否需要一次性令牌（另一个 change）。
7. **net10 的首次还原体积与耗时**：本 change 接受「首次发布下载上百 MB、耗时较久」，若实测不可接受，可退回框架依赖发布（本机已装 net10 桌面运行时），那是另一个决定。
8. **30000 毫秒预算是否够**：6.3 实测后定；不够就把预算做成配置项（另立返工任务），不偷偷放宽断言。

## 附 A：本轮对抗审查裁决的落点（逐条对照）

| # | 裁决 | 落点 |
|---|---|---|
| 1 | NuGet 钉版本 + 测试工程必备两条包 | D6 版本表；tasks 3.1 |
| 2 | `core.shutdown` 先回包刷出再停机；`serveUntilShutdown()` 共用；停机异常可见 | D3「停机时序」「停机异常必须可见」；spec `core.shutdown`；tasks 2.1/2.2；0.4 加数据完整性 |
| 3 | 「壳 MUST NOT 核心仍活时退出」与兜底矛盾 | spec `desktop-shell` 退出要求加兜底例外；D3 第 4 步；托盘气泡在释放图标之前发 |
| 4 | `<1024` 不是特权端口 | D2「低端口的真实口径」；spec 与 tasks 5.2；附录 #2 |
| 5 | 自检不取互斥体、临时 config/lock/log、空闲端口与 TOCTOU | D7；spec `desktop-shell` 自检要求；tasks 4.4/4.5 |
| 6 | 壳拒绝 `--port 0` | D2；spec `desktop-shell` 端口要求；tasks 3.2 |
| 7 | WebView2 初始化失败先停核心放锁；`CreateAsync` 传用户数据目录 | D4；tasks 4.1/3.10（失败映射单测） |
| 8 | `global.json` 位置与 SDK 记录；评估 net10 | D1 目标框架段；D6 SDK 段；tasks 3.1 |
| 9 | C# 测试命令改成解决方案 | D6；tasks 3.1/3.2/6.1 |
| 10 | 6.1 不走 `run_all.sh` 聚合；4.3 用 `TcpListener` 占端口验隔离 | tasks 6.1；4.5 |
| 11 | 固定端口加子进程端到端 | D8 表「子进程端到端」行；tasks 0.3 |
| 12 | 漏报 `web_management_docs_test` | D9 文档表；tasks 2.2（红集写全）/5.3 |
| 13 | 壳运行时行为验收 (e)–(h)、WebView2 失败映射单测、关窗后 HTTP 200 | tasks 6.2；3.10 |
| 14 | 启动期可见性（托盘先建）、第二实例未就绪语义 | D4；状态机；tasks 3.10/4.2 |
| 15 | 前台激活 `AllowSetForegroundWindow` | D4「前台激活」；D5；tasks 3.10/4.2 |
| 16 | 测试隔离（0.3 先取空闲端口、0.4 全临时） | tasks 0.3/0.4；D8 |
| 17 | C# 接缝（注入命令/环境/时钟/日志/假 WS）+ `ITestOutputHelper` + tokens 守卫 | D8「C# 侧的接缝要求」；tasks 3.5–3.8 |
| 18 | `app_config` 日志 once 标志与捕获方式 | tasks 0.2（reset hook 或每次打日志 + 重赋 `debugPrint`） |
| 19 | 06 检查/构建 `web/dist` + 跑 `dotnet test`；`utils.sh` 加 `dotnet`；构建任务前移 | tasks 4.3→4.4→4.5；4.6；`test/smoke/utils.sh` |
| 20 | 守卫范围（`CorePortResolver`/`resolveCorePort`、禁第二份 16705、范围/回落锚点、回滚列守卫） | D2 守卫段；D8 表；tasks 0.5/5.5；Migration 第 5 条 |
| 21 | 探测参数语义独立 + 30000 冷启动实测 | D3「30000 毫秒是不是够」；D8；附录 #5；tasks 6.3 |
| 22 | `ShowBalloonTip` 必传超时 | D4；附录 #6 |
| 23 | 5.3 文档（删冲突句、保留锚点、`--port 0`、关停风险、JSON 示例） | D9 表；tasks 5.2/5.3 |
| 24 | proposal 优先级与 Migration 矛盾 | proposal B；D2；Migration 第 1/2 条 |
| 25 | 跨会话端口冲突 | D5；风险表；tasks 5.1 |
| 26 | 壳强杀孤儿 → Job Object 或已知限制 | D3 第 5 步（选 Job Object）；风险表 |
| 27 | `cmd` 引号与 GBK 兜底 | D3「参数与引号规则」；风险表 |
| 28 | 自包含运行时包与网络失败分类 | D6；风险表 |
| 29 | 低优先级并入任务文本（7890 出处、3425 口径、互斥体引用、停机与在途顺序、自检日志、注释更新、两把锁、`.gitignore` 写法、`ITestOutputHelper`、CLAUDE 漂移不改） | D2 第 4 条；D3 停机顺序；D5 引用；D7 日志；tasks 1.2/1.3/5.1/5.4 |

## 附 B：数字与出处

| 数字 | 用在哪 | 出处（可核） |
|---|---|---|
| `16705` | `core.port` 默认值 | 配置项默认值 + 具名常量（`kDefaultCorePort` / `DefaultCorePort`），登记在 `Docs/user-guide/configuration.md` 配置键表；数字取 `0x4141`（产品名缩写 AA 的 ASCII 十六进制）；避开产品里已在用的回环地址 `3425`（magpie 网关默认**连出去**的地址，见 `lib/ui/providers_page.dart` hintText、`lib/models/provider_config.dart` 注释）、`7890`（`scripts/setup_searxng.bat` / `.sh` 的代理排错示例）、`8080` |
| `1`–`65535` | 端口合法范围 | 平台硬限（TCP 端口域） |
| `<1024` | 低端口 | **不是权限边界**：Windows 没有 Unix 式特权端口（对抗审查本轮实测非提权绑定 80 / 1023 均成功）；只是容易撞系统服务，文档写「不推荐」 |
| `1024`–`49151` | 选默认值时的落点区间 | IANA / RFC 6335 的 User Ports 区间 |
| `49152`–`65535` | 排除区间 | IANA / RFC 6335 的动态（私有/临时）端口区间，OS 会分出向连接用 |
| `1000` 毫秒 | 就绪探测重试间隔 | **壳自己的等待参数**，数值取 `web/src/tokens.ts` 的 `kDefaultReconnectBaseMs = 1000`；语义不同（那个是重连退避基数，不是探测间隔），为避免「产品里出现第二套等待数量级」才取同值，C# 侧副本由 tasks 3.8 的守卫解析这几个 `kDefault*Ms` 常量并比对（**不是**比 `VITE_*` 环境变量名） |
| `5000` 毫秒 | 单次探测等待、停机礼停等待、HTTP 自检等待 | 同上，取 `kDefaultHeartbeatTimeoutMs = 5000`；语义同为「等一个回包的上限」 |
| `30000` 毫秒 | 就绪总预算 | 取 `kDefaultReconnectCapMs = 30000`；**语义不同**（那个是重连退避上限，不是启动总预算），本 change 只承诺「不新增第二个数量级」，是否够用由 tasks 6.3 实测 |
| `5000` 毫秒 | 托盘气泡的 `ShowBalloonTip(timeout)` 实参 | API 必填、无参重载不存在；Vista 之后实际时长由系统控制，这里只是满足签名的占位值，复用上面同一个 5000，不新造数字 |
| `0` | `--port 0` = 交回 OS 分配 | 既有行为（`HttpServer.bind(..., 0)`），本 change 保留给核心测试与调试；**壳拒绝 0** |
| `2` / `1` / `3` | 进程退出码：参数错误 / 启动失败 / 停机有告警 | `1` 与 `2` 是 `bin` 既有约定（启动失败、参数错误）；`3` 是本次新增的 `kExitCodeShutdownWithWarnings`，取「与既有 1、2 不冲突的最小未用码」 |
| 无 | 窗口初始尺寸 | 首次即最大化（`WindowState.Maximized`），不发明「屏宽百分之多少」 |
| 无 | 托盘气泡实际显示时长 | 由系统控制（`ShowBalloonTip` 的超时在 Vista 之后被忽略） |
| 一行 | 对话框里显示的核心输出 | 是「最后一行」，不是阈值 |

## 附 C：第二轮残余裁决的落点（8 条）

| # | 残余裁决 | 落点 |
|---|---|---|
| 1 | 自检第二次启动验证后必须停掉第二个核心，否则退出留孤儿 | D7「自检步骤与判据」；spec `desktop-shell` 自检要求；tasks 4.4 / 0.4（d） |
| 2 | 「不取壳互斥体」要有失败用例（先占住互斥体再跑自检） | D7 新增「『不取互斥体』必须有失败用例」；spec 自检场景；tasks 4.5 |
| 3 | `AllowSetForegroundWindow` 的 pid 从哪来 | D4「前台激活」与 D5（命名共享内存 `Local\AliasAgent.Desktop.State` 写 4 字节 pid；读不到时退化为 `ASFW_ANY` 并记日志，说明权限面更宽只作兜底）；tasks 3.9 / 4.2 |
| 4 | 「两处既有守卫都逐行核对」不实（管理文档是整篇子串） | D9 文档表如实写明强度差异；spec `core.shutdown` 措辞；tasks 5.3 |
| 5 | `dotnet test` 从仓库根跑读不到 `shell/global.json`（同 publish 问题） | D6「SDK 钉住」改为 `global.json` 放**仓库根**；tasks 3.1 / 3.2 / 6.1 |
| 6 | 停机收尾要等（`Agent.cancel()` 是同步 void） | D3 停机顺序新增 `await waitForRounds()` 等待点；spec `core.shutdown`；tasks 2.1 / 2.3 |
| 7 | `dotnet` 检查不能塞进 `utils.sh check_deps` | D8 冒烟行；tasks 4.6 |
| 8 | tokens 守卫应解析 `kDefault*Ms` 常量而非 `VITE_*` 环境变量名 | 附录 B 三行出处；tasks 3.8 |
