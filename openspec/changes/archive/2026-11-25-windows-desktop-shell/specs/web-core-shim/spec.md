## MODIFIED Requirements

### Requirement: 无头核心进程独立启动并回显访问地址

系统 SHALL 提供一个不依赖 Flutter 渲染的无头 Dart 核心入口，复用现有业务 services 与 dart:ffi 加载的 C++ sidecar。核心 SHALL 仅绑定回环地址。

监听端口 SHALL 按以下优先级决定：显式 `--port <n>` > 配置项 `core.port` > 具名默认常量（出厂 16705，登记在用户文档的配置键表）。`--port 0` SHALL 保留「交回 OS 分配」的调试与测试形态。端口值 MUST NOT 以裸数字出现在代码里，SHALL 来自配置项默认值或具名常量。合法范围 SHALL 是 1–65535（TCP 端口域）。`<1024` 的低端口 MUST NOT 被描述成「需要管理员权限」——Windows 上没有 Unix 式特权端口（对抗审查实测非提权绑定 80 与 1023 均成功），它只是容易与系统服务相撞，文档 SHALL 写「不推荐」而不是「需要提权」。配置项 `core.port` 缺席、不是整数或越界时 SHALL 回落默认常量并留一行日志（回落可见，不静默），MUST NOT 因此拒绝启动；`--port` 是显式输入，非法时 SHALL 报错退出（不猜用户意图）。

启动输出 SHALL 回显实际可访问的 `http://127.0.0.1:<port>` 地址。端口被占用导致绑定失败时，核心 SHALL 抛可归因的启动失败（消息含端口号与「改 `core.port` 或用 `--port` 指定另一个端口」），MUST NOT 静默改用其它端口。**配置文件不存在时 SHALL 以空配置启动并 serve 首启向导**（web-management-ui 引入，修改原 notFound 拒启动门），使 web 端能独立完成首启；配置 malformed 仍 SHALL 可归因失败。

#### Scenario: 启动无头核心

- **WHEN** 以无头入口启动核心进程
- **THEN** 进程不依赖 Flutter 引擎即可运行，加载 sidecar 成功，并在输出中回显一个实际可访问的回环 URL（端口与进程实际监听端口一致）

#### Scenario: 固定端口取自配置

- **WHEN** 配置文件里写 `core.port` = 9000，且启动时没有传 `--port`
- **THEN** 核心监听 9000，回显的 URL 端口是 9000（不再是 OS 随机分配的端口）

#### Scenario: 显式参数覆盖配置

- **WHEN** 配置里写 `core.port` = 9000，启动时传 `--port 9100`
- **THEN** 核心监听 9100，配置里的值不生效且配置文件不被改写

#### Scenario: 显式 0 交回 OS 分配

- **WHEN** 启动时传 `--port 0`
- **THEN** 核心回到旧形态：由 OS 分配端口并回显实际端口（测试与调试依赖这条形态）

#### Scenario: 配置项非法时回落默认并留日志

- **WHEN** 配置里 `core.port` 是字符串、0、负数或大于 65535
- **THEN** 核心仍启动并绑定默认端口的同值端口，输出一行说明「取值非法已回落默认」；MUST NOT 静默无声

#### Scenario: 端口被占用可归因

- **WHEN** 目标端口已被另一个进程占用
- **THEN** 核心以可归因的启动失败退出，消息里点名端口并给出「改 `core.port` 或 `--port`」的出路；MUST NOT 换一个端口偷偷启动

#### Scenario: 低端口不被说成需要提权

- **WHEN** 用户文档与错误提示提到 `<1024` 的端口
- **THEN** 措辞是「容易与系统服务相撞、不推荐」，MUST NOT 出现「需要管理员权限」这类与 Windows 事实不符的说法

#### Scenario: 空配置启动供向导

- **WHEN** 配置文件不存在时启动无头核心
- **THEN** 核心以空配置启动并 serve 首启向导（而非拒启动退出），web 可打开完成首启配置

#### Scenario: 坏配置仍可归因失败

- **WHEN** 配置文件存在但 malformed
- **THEN** 核心可归因失败（指明配置损坏），不静默以空配置覆盖

## ADDED Requirements

### Requirement: 核心优雅停机

核心 SHALL 暴露 JSON-RPC 方法 `core.shutdown`（无参数）。**时序 SHALL 是「先回包、再停机」**：handler 只返回 `{"ok": true}`（并登记「响应已刷出」回调），WebSocket 侧先把响应写出、再关闭该连接（Dart 的 `WebSocket.close()` 会先发完排队消息），然后才触发停机。MUST NOT 先停机再回包——那样连接会被提前关掉，响应留在队列里，调用方看到的是「调了但没回」。

核心 SHALL 提供**入口与测试共用的**停机等待点 `serveUntilShutdown()`：等待「`core.shutdown` 的响应已刷出」或 SIGINT，随后执行停机并返回停机报告。测试 MUST NOT 自拼一套停机序列（否则验的是测试自己）。

停机顺序 SHALL 是：对所有运行中的 Agent 调 `cancel()` → **等待在途整轮收尾**（`Agent.waitForRounds()` 等价的等待点；`cancel()` 只是同步置取消标志、不等待整轮结束，少了这一步「收尾事件在通道关闭前到达」在实现上不成立）→ 断开 WebSocket 客户端 → 关闭 HTTP 服务器 → 销毁 Agent → 关闭数据库 → 释放单实例锁，随后进程退出。**停机异常 SHALL 可见**：`stop()` 期间 `disposeAll` / 数据库关闭的失败 MUST NOT 被吞成一行日志——每一项 SHALL 进停机报告的告警清单并写入核心日志；有告警时进程退出码 SHALL 非 0（`kExitCodeShutdownWithWarnings`，与既有的 1=启动失败、2=参数错误区分）。

该方法名 SHALL 出现在 `kCoreRpcMethodNames` 里、与 `_registerMethods` 的实现一致（漏注册即抛错），并 SHALL 出现在用户文档里：`web-core-shim.md` 的 RPC 表补齐它单独一行（该守卫按 RPC 表首列逐行核对）；管理屏 `web-management.md` 的管理 RPC 表也补一行（**该守卫只是整篇子串检查** `text.contains`，不是按表行——本 change 如实写明这条强度差异，不把两者说成一样强）。

调用之后 MUST NOT 遗留服务器监听或锁占用：同一端口与同一锁文件上的下一次核心启动 SHALL 成功。`core.shutdown` 落在「本机回环、无鉴权」的服务面上——任何本机进程（包括本机网页）都能关掉核心——这两条边界 SHALL 写进用户文档的已知限制。

#### Scenario: 调用后先回包再停机且锁释放

- **WHEN** 客户端经 WebSocket 调用 `core.shutdown`
- **THEN** 客户端收到 `{"ok": true}` 响应（不是连接被直接掐断），随后核心停止服务、释放单实例锁并以 0 退出；用同一锁路径再启动一个核心 SHALL 成功

#### Scenario: 方法与清单、两处文档一致

- **WHEN** 核心启动并注册方法
- **THEN** `core.shutdown` 可被调用，`kCoreRpcMethodNames` 与实现一致，`Docs/user-guide/web-core-shim.md` 的 RPC 表与 `Docs/user-guide/web-management.md` 的管理 RPC 表里都有它单独一行

#### Scenario: 停机有告警时退出码非 0

- **WHEN** 停机过程中销毁 Agent 或关闭数据库抛错
- **THEN** 停机报告带上告警、日志里逐条写明，进程以非 0 码退出（不是假装成功）；壳侧把它记成「停机有告警」而不是崩溃

#### Scenario: 停机不破坏数据

- **WHEN** 在有会话数据的情况下调用 `core.shutdown` 后重新启动核心
- **THEN** 会话与消息仍可读（正常关库路径，不是被强杀后的残留状态）

#### Scenario: 在途发送被取消而不是被强杀

- **WHEN** 调用 `core.shutdown` 时某会话正在流式回复
- **THEN** 该 Agent 先被取消（在途发送收到取消）、在途整轮被等待收尾，通道关闭前客户端收到收尾事件，随后才关服务器与数据库；MUST NOT 只置取消标志就关通道
