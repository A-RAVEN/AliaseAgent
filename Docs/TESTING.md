# 测试流程与规范（Testing Guide）

> 本文档是 AliasAgent 测试的**权威约定**。写一个新功能时，先读本文档确定该功能该放哪层、怎么测、规范是什么，别漏掉测试用例维护，也别写错测试。
> 相关文档：`DEBUGGING.md`（崩溃/日志/ASan）、`CLAUDE.md`（测试可观测性规则）。

---

## 1. 测试分层：先决定"为哪个测试"

| 层 | 目录 | 工具/形态 | 测什么 | 是否联网/真实模型 |
|----|------|-----------|--------|------------------|
| **单元测试**（Dart） | `test/unit/` | 纯 `test()` | 纯逻辑：registry / config_service / tool_call_activity 模型 | 否 |
| **Widget 测试** | `test/widget/` + `helpers/` | `testWidgets()` | 叶子组件 + ChatScreen 注入 fake 依赖的 UI 交互链 | 否（hermetic） |
| **Integration（headless）** | `test/integration/` + `helpers/` | `testWidgets()`（FakeSidecar 驱动）+ 真 DLL `test()` | 端到端消息流 / 工具调用 / 错误流 / 流式状态 / 会话持久化 | 否（真 DLL bridge 测试需 DLL，不联网） |
| **Live（窗口真模型）** | `integration_test/` | `@Tags(['live'])` + `-d windows` | **真实模型**驱动真实 sidecar，在真实桌面窗口跑 | **是**（真 API） |
| **C++ Sidecar 测试** | `sidecar/test/` | Catch2 v3 + CMake/CTest | 全部 C++ 层：SSE 解析 / HTTP / 工具执行 / 搜索 provider / 子进程 / FFI 追踪 | 实时路径可选（`[live]` 标签） |
| **冒烟 + 视觉回归** | `test/smoke/` + `integration_test/screenshot_test.dart` | bash 脚本 + Flutter | 构建 / analyze / checkpoint / 启动验证 / 视觉像素比对 | 本地 |

**决策口诀**：能纯逻辑 → `test/unit/`;要渲染/交互 → `test/widget/`;要假 sidecar 端到端 → `test/integration/`;要真模型端到端 → `integration_test/`(+`--tags live`);要 C++ → `sidecar/test/`;要不要整套冒烟 → `test/smoke/run_all.sh`。

> ⚠️ **Live 测试的正确形态是"窗口真模型"**(`integration_test/` 下 `-d windows`)。早期曾用 headless `test/integration/live_file_tools_test.dart` 做 live，被认定不符合规范且已删除。非 live 的 integration 仍在 `test/integration/` 用 `fake_sidecar.dart`。

---

## 2. 各层怎么写

### 2.1 单元测试（`test/unit/`）
- `test()` + `group('Name', ...)`。纯内存，无 I/O（config_service 用真实临时文件）。
- **唯一不 hermetic 的**：`test/unit/sidecar_bridge_test.dart` 是真冒烟——`DynamicLibrary.open('sidecar.dll')`，验符号解析、ping、setWorkspace、readFile/listDir、**web_fetch SSRF 预拦截**(`192.168.1.1`/`127.0.0.1`/`file://`/`localhost`)。要求 DLL 在盘上。
- 运行：`flutter test test/unit/`。

### 2.2 Widget 测试（`test/widget/`）
- `testWidgets()`;树**通常**用 `MaterialApp(home: Scaffold(body: <Widget>))` 包裹，**绝不 pump `MyApp`**(`test/` 下 grep `MyApp(` 零命中)。例外：`app_shell_test.dart` 用 `MaterialApp(home: AppShell(...))`(无 Scaffold body 包裹)。`ChatScreen` 用注入依赖：`ChatScreen(config, sessionRepo:, msgRepo:, sidecar:)`。
- **sidecar 用 `FakeSidecar`**(`test/integration/helpers/fake_sidecar.dart`，实现 `ISidecar`);`SidecarBridge.instance` 注入 fake 时不被碰。
- **无真实 DB/SharedPreferences**——持久化用 `FakeSessionRepository` / `FakeMessageRepository`（`test/widget/helpers/fakes.dart`），数据工厂在 `test_utils.dart`。
- **视口约定**：`tester.view.physicalSize = Size(1280,720); devicePixelRatio = 1.0;`（老的 `binding.window.physicalSizeTestValue` 只 auto_scroll_test 用，且必须 tearDown 清）。
- **必须 tearDown 清全局**：`registry.clear(); resolver = null;`（`lib/main.dart` 的模块级单例）。
- **禁止 `pumpAndSettle`**（`_StreamingDots`/动画不 settle）→ 用 `tester.pump(const Duration(...))`(200/300/400ms)。
- 无 crash 断言：`expect(tester.takeException(), isNull)`。
- 运行：`flutter test test/widget/`（单文件 `flutter test test/widget/<file>.dart`）。

### 2.3 Integration（headless，`test/integration/`）
- 文件清单：`message_flow_test` / `error_flow_test` / `auto_title_test` / `streaming_state_test` / `search_e2e_test` / `tool_persistence_test` / `tool_call_test`(以上都是 FakeSidecar 驱动)、`real_sidecar_test` 与 `bridge_realtime_test`(真 DLL)、`thinking_integration_test`(真 sqlite)。helpers 下含 `fake_sidecar.dart` + `screenshot_utils.dart`。
- Web-to-UI via `FakeSidecar` 事件驱动：`..queueChunk('text')..queueToolCall(json)..queueThinking(json)..queueDone({code,error,stopReason})`;sendMessage 按 FIFO 回放到第一个 `done`;`gateNextSend()/releaseGate()` 做中途换会话;`cancelCount`/`hasQueuedEvents` 控制面。`search_e2e_test` 验证搜索工具(需要 `search` 配置);`auto_title_test` 验证会话自动标题;`tool_persistence_test` 验证工具卡在存储消息里的 toolCallsJson 形状。
- **真 DLL 测试分两类**：`real_sidecar_test.dart` 直接经 `SidecarBridge.instance` 对 DLL 做**真实文件 I/O**(readFile/listDir/writeFile/editFile,不联网、无 SSE mock);`bridge_realtime_test.dart` 起本地 SSE mock server(`_SseServer`,`ServerSocket.bind(InternetAddress.loopbackIPv4,0)`)+ `Future.timeout(10s)` 测流式回调时序。**只有 `bridge_realtime` 的 `_SseServer.close()` 必须同时 cancel writer + close client socket**，否则 C++ `execute()` 阻塞且 `request_mutex` 死锁。DLL 测试需 `sidecar.dll` 在盘上，否则 setUp 即失败。
- `thinking_integration_test.dart`：纯 `test()`，必须 `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;` + 每 case 临时目录 `DatabaseService.openAt(tempDir.path)`。
- 运行：`flutter test test/integration/`（含真 DLL 测试，需 DLL）。
- **截屏 helper**：`test/integration/helpers/screenshot_utils.dart` 是 `captureWidgetAsPng`/`captureAndCompare` 的实现(解析 RenderRepaintBoundary→`toImage(pixelRatio:1.0)`→PNG 写盘)，被 `integration_test/live_observability.dart` 的 `captureLiveShot` 与 `integration_test/screenshot_test.dart` 的 `captureAndCompare` 复用——扩视觉/截屏路径时改这里。

### 2.4 Live（窗口真模型，`integration_test/`）
- 文件头：`@Tags(['live'])` + `library;`。默认被 `dart_test.yaml` 的 `tags.live.skip` 跳过，显式跑：
  ```bash
  flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows
  # real_api_test.dart 同样（--tags live --run-skipped ... -d windows）
  ```
- 每个 case 用 `RepaintBoundary(key: captureKey, child: const MyApp())` + `await tester.pump(2s)`;每 case `timeout: Timeout(Duration(seconds:300))`;内层 helper wait 默认 `timeoutSec=150`。
- **截图在 `try/finally` 里，绝不放 `addTearDown`**（teardown 在 tree reset 后才跑，boundary 已 unmount → pass 路径断裂）。`captureLiveShot(tester, captureKey, '<name>')` 写 `test/live_visual/<name>.png`，非致命，失败 delete-on-fail。
- **配置门**：`live_file_tools_test` 用严格 `hasCompleteConfig`(api_key + base_url + model 全非空)，绝不用 fallback 默认端点(空 base_url 会落到 `https://api.anthropic.com`——错端点)。
- **额外前提**：glob_file/grep_file 在 Windows 需要 `tools/rg.exe`(缺 → 相应测试自跳/报 rg not found);真 config 需 `agent_types.general.thinking_effort`(如 `'max'`)才触发思考。缺 config → 每 case `markTestSkipped`；mid-run API 故障 → 首 case 捕到 "Error:" 回复后 skip，后续 case 跳过。
- `setUpAll(clearLiveVisualDir)` 清旧截图;`setUp` 临时库 `DatabaseService.openAt(tempDir.path)`;tearDown close + 删临时目录(吞 Windows 文件锁)。
- 假工具隔离:`live_file_tools` 在 pump 后 `expect(SidecarBridge.instance.setWorkspace(ws.path), isNull)`(非 null 意味着模型会碰用户 homeDir)。
- 运行命令合计见 §4.

### 2.5 C++ Sidecar 测试（`sidecar/test/`）
- **Catch2 v3**;`test_main.cpp` 自建 runner(`CATCH_CONFIG_RUNNER` + main 里 `WSAStartup` + `curl_global_init`)。**链接 11 个生产源文件，不链接 `sidecar.dll`**（避免 `__declspec(dllimport)` 冲突，`sidecar_api.cpp` 不参与 → `send_message` 层面不在范围内）。
- 命名 `TEST_CASE("Area: behavior", "[tag]")`;标签如 `[sse_parser]`/`[http_client]`/`[tool_execution]`/`[web_fetch]`/`[ssrf]`/`[subprocess]`/`[ffi_tracing]`/`[live]`/`[zhipuai][rate-guard]`/`[searxng][mock]`/`[searxng][live]` 等。**注意**：`ctest -R` 按**测试名**过滤(Catch2 tag 不是 ctest 名;只注册了 1 个 `sidecar_tests`),要跑单个 suite 得**直接调二进制 + tag 参数**(见下)。
- 工具结果解析 `parse_result()` → 断言 `j["ok"]`/`j["error"]`/`j["diagnosis"]`...;**精确错误串断言**(如 `old_text not found in file`、`Workspace path is empty`、`path traversal not allowed (..)`)。
- `mock_server.h` 内嵌 TCP mock(回放假 SSE fixture)+ `temp_dir.h` RAII `TempDir`/`WorkspaceGuard`;fixture 在 `sidecar/test/fixtures/sse/`(22 个);`test_utils/` 下有 `api_key_loader.h`(读 `~/.aliasagent/config.json` 的 search key)+ `searxng_harness.h`(live SearXNG 测试)。
- **环境缺失自动自跳(SUCCEED+WARN)而非失败**：`is_rg_missing`(glob/grep 无 rg)、`is_configured()`(live，如 zhipuai/kimi/SearXNG 无 key)、SearXNG 不可达。
- 构建/运行（**构建目录在 `sidecar/build/windows`，不是项目根 `build/windows`**）：
  ```bash
  cmake -B sidecar/build/windows -S sidecar
  cmake --build sidecar/build/windows --target sidecar_tests
  ctest --test-dir sidecar/build/windows -C Debug          # 全量(multi-config 必须 -C Debug)
  ./sidecar/build/windows/Debug/sidecar_tests.exe --list-tests   # 当前 228 个
  ./sidecar/build/windows/Debug/sidecar_tests.exe "[sse_parser]"  # 跑单个 Catch2 suite(按 tag)
  ```

### 2.6 冒烟 + 视觉回归（`test/smoke/` + `integration_test/screenshot_test.dart`）
 ```bash
 bash test/smoke/run_all.sh
 # = 01_build → 02_analyze → 03_checkpoints → 04_launch_and_verify → 05_visual_regression
 ```
- 视觉回归：`05_visual_regression.sh` 跑 `flutter test integration_test/screenshot_test.dart --reporter compact`;compare `test/smoke/output/<name>.png` vs `test/smoke/references/<name>.png`(1% 像素容差,首跑自动建 baseline)。
- `03_checkpoints.sh` 跑 `dart run test/checkpoint_*_verify.dart`（`test/` 根，非 flutter test）。
- **前置依赖**(`check_deps`)：需要 flutter / dart / sqlite3 / powershell,缺任一整套冒烟会直接退出。
- **Windows 一键入口 `run.bat`**(仓库根,与 bash `run_all.sh` 并列)：`flutter build windows --debug` → 构建 Release sidecar 并拷 DLL → 跑**单元冒烟** `flutter test test\unit\sidecar_bridge_test.dart` → 启动 app。这是 Windows 上最省事的冒烟入口(不跑窗口 live/视觉,只跑 unit 冒烟)。

---

## 3. 实现规范（硬要求）

### 3.1 测试输出可观测性（CLAUDE.md，权威）
> "任何测试的输出都必须让运行者/审查者**知道测试实际做了什么**，禁止只输出 OK/断言失败而看不到测试内容。"

- **模型驱动测试（live / integration_test）**：在**断言前**输出实际**工具调用**（toolName、完整 input、result/status）与**文件最终状态**。
- **失败必须可归因**：有该轮实际行为 + 文件内容 dump；"失败但日志无现场" = 规范缺陷。
- **观察通道随形态**：headless harness 直接持工具调用记录；窗口版经 UI 卡片(`ToolCallCard.activity`)读出；**无论哪种形态内容必须可观察**，拿不到即违规。
- **live/模型驱动测试必须留截图 + 走视觉验收（硬要求，非可选）**：每个 live 用例在 `try/finally` 里 `captureLiveShot` 留一张 `test/live_visual/<name>.png`，主循环用 `Read` 原生读图做**判断式视觉验收**（回答气泡完整 / 工具卡 done / 布局无 overflow），`[SHOT]` 记录。**无截图 → 不得判通过**；读图分不清（黑帧/空白/裁切/截图失败）→ 如实记"截图无效/异常"，也不得计为通过。**通道区分**：`captureLiveShot` 截的是 **Flutter 场景渲染**（`RepaintBoundary.toImage(pixelRatio:1.0)`，无 OS 标题栏/边框）；若缺陷在 **OS 级窗口**（如浏览器工具弹出的独立 Edge 窗口），Flutter toImage 捕获不到，须用 **OS 全屏截图（PowerShell `CopyFromScreen`）** 补获"用户所见的窗口"。
- **实现**：`integration_test/live_observability.dart` 里 `dumpToolCards(tester,{phase})` / `dumpFile(path,{label})` / `dumpNoTool(tester, phase)` / `readFinalAssistantReply(tester)` / `captureLiveShot(...)` / `clearLiveVisualDir()`。每个 dump 是**纯 `debugPrint` 增量，绝不 assert、绝不改 expect/fail/markTestSkipped 行为**（零验收风险，不弱化断言）。
- **每次断言前 & 每条失败路径**先 dump：`on TimeoutException` / 错误状态检测点，都在 `fail(...)`/`markTestSkipped(...)` **之前** `dumpToolCards`(+ 有文件就 `dumpFile`)。

### 3.2 报错处理
- **`markTestSkipped` 只用于外部/不可用**：config 缺失、`!apiAvailable`、无 search provider、无 thinking_effort agent、以及 assistant 回复以 `"Error:"` 开头(模型/API 错误)。
- **`fail` 只用于内部可归因 bug**：ToolCallCard 到 `ToolCallStatus.error`、silent-completion(无最终回复)、真 150s hang(TimeoutException)、fixture 写失败。
- **⚠️ 例外(软记录)**：`live_file_tools_test` **Test 3**(unique-match rejection/self-heal)**故意**把 error-status 卡当**软记录**(`_scanErrorCardsWithScroll(tester)` + `debugPrint('[TEST 3] error-status tool cards observed: N')`),不 fail——因为模型走上 self-heal 合法路径。所以"error-status→fail"不是无条件真理,要在**有 rejection/self-heal 语义的场景**区分;其余场景 error-status→fail 成立。**dump 规则也非"每条 fail/skip 前都 dump"**——顶层给过 gate(config 缺失/!apiAvailable/无 provider/无 thinking_effort)在**任何工具调用前**就 `markTestSkipped`(无可观察内容),不算违规;dump 只用于"已发生工具调用/文件活动"后的失败路径。
- 「内部 vs 外部错误分类」如需加强，**另立 change**，不得顺手改。

### 3.3 Log / 截屏 / dmp 输出
- **log**：`[OBS]`(可观测)、`[TEST]`(pass 行，如 `[TEST 3] OK — ...`)、`[SHOT]`(截图)。sidecar 日志级别见 §4.1。
- **截屏**：`captureLiveShot` → `test/live_visual/<name>.png`，字节下限 `_kMinShotBytes=2048`(仅拒零长/损坏，非 blank 检测器);`setUpAll(clearLiveVisualDir)` 清旧；失败 delete-on-fail 非致命。截屏放在 try/finally，不放 addTearDown。
- **dmp**：崩溃自动生成 `%USERPROFILE%\.aliasagent\crashes\sidecar_crash_*.dmp`(`MiniDumpNormal`，无堆、无 API key)+ `crash.log` + `crash_backtrace_*.log`。**读法见 §4.2——用工具自读，别再让人工开 WinDbg**。

### 3.4 禁止改验收标准 / 诚实报告
- **禁止修改验收标准**：不得为通过而改测试代码 / tasks.md / spec / design，含隐藏用例、删失败测试、**批量打勾**、降断言标准、改 spec 使代码"符合"。
- **诚实报告**：不得 `[.]` 隐藏、删失败用例、批量勾选不逐条核、报"X/Y 通过"而藏掉没过的。
- **范围纪律**：只改本 change 文件;新代码破坏既有文件 → 停下报告，不擅自修(除非批准)。

### 3.5 禁"手动验证 / 用户参与"任务（硬规则）
- 任何任务都不能是"需要用户跑/用户来"。**任何"手动验证"形式本身禁止**，必须改成"主循环跑 <具体命令/测试>"(单测/集成测/构建+跑命令)。
- 写任何任务前自问："这条我能不能用自己工具跑掉？"能→写自测;不能→如实报环境阻断 + 需要什么，绝不写成人肉任务。

---

## 4. 怎么看调试数据

### 4.1 sidecar 日志
- 路径：Windows `%USERPROFILE%\.aliasagent\logs\sidecar.log`；POSIX `~/.aliasagent/logs/sidecar.log`。**自己读，别叫用户看**(CLAUDE.md)。
- 级别：`TRACE=0 / INFO=1(默认) / WARN=2 / ERROR=3`。**无 DEBUG 级**。`ERROR` 输出为字符串 `"ERROR"`。行格式 `<时间> [LEVEL] <msg>`。
- 开 TRACE(看 FFI 边界 / SSE 线 / Dart→C 入口，敏感数据已红act `api_key=<REDACTED>`)：
  ```bash
  # cmd
  set ALIASAGENT_LOG_LEVEL=trace
  # pwsh
  $env:ALIASAGENT_LOG_LEVEL="trace"
  # unix
  ALIASAGENT_LOG_LEVEL=trace flutter run -d linux
  ```
  > `ALIASAGENT_LOG_LEVEL` 在 DLL 加载前读一次;不识别的值静默回 `INFO`。`auth` header 永不入日志;HTTP≥400 记录状态码 + 响应体前 2048 字节。
- 轮转(`logger.cpp rotate_logs()`，启动时若 `sidecar.log` >10MB)：`remove .2.log` → `rename .1.log → .2.log` → `rename sidecar.log → .1.log`。**实际最多保留 2 个历史**(`.1.log`/`.2.log`);源代码里的 `.3.log` 是**死代码**(从未创建/删除)。注：DEBUGGING.md 写的 "delete .3.log / max 3 historical" 是遗留注释,与实际实现不符,以 `logger.cpp` 为准。

### 4.2 崩溃数据（crash artifacts）
`~/.aliasagent/crashes/`：
- `sidecar_crash_*.dmp`：`MiniDumpNormal`(调用栈 + 寄存器 + 模块，~1-5MB，**无堆内存→无 API key**)。需要 PDB(`sidecar\build\windows\Debug\sidecar.pdb`)做符号;最多保留 10 个。
- `crash.log`(可重入 `crash_log()` 写)：Windows 崩溃行 `Unhandled exception: code=0x%08lX addr=%p thread=%lu` / `std::terminate called`;然后是 **FFI 环形缓冲 dump**(最后 256 次 C→Dart 回调，`  [<ts>] <chunk|tool_call|thinking|done> payload=<size>`)，后接 `Minidump written: <path>`。Linux/macOS 加 `Signal %d (%s) at address=%p` + `Backtrace written: <path>`。
- `crash_backtrace_*.log`(Linux/macOS)：`backtrace()/backtrace_symbols()` 文本栈；`c++filt < crash_backtrace_*.log` 反解。
- **读取方式(自己来)**：崩溃验证 = 触发崩溃(测试构建里 null-deref / `raise(SIGSEGV)`)→ **断言 `.dmp` 生成 + 非零大小 + `crash.log` 有该次崩溃记录 + FFI 环形缓冲 / backtrace 文本**。不要再写"人工开 WinDbg 看 `.dmp`"之类的手动任务。若要反解 Windows `.dmp` 符号，Load PDB + `.sympath+ <project>\sidecar\build\windows\Debug` + `.reload /f` + `k`(DEBUGGING.md 57-67)；但**验收**用上面的断言即可。

### 4.3 FFI / 性能
- **FFI 追踪**：`[ffi_tracing]` 测试覆盖;`crash.log` 的环形缓冲记录**元数据(type/payload 大小/时间戳)，不含回调参数内容**——它证明回调发生过、大小多少，不能还原参数字符串。
- **ASan**：只用于 `sidecar_tests`，绝不用于 `sidecar.dll`(Dart VM 保留内存区与 ASan shadow 冲突)。构建：`scripts\rebuild_sidecar.bat Debug --asan`(需 vcpkg triplet `x64-windows-asan-static`)。ASan 构建落在**独立的 `sidecar/build/asan/`** 树,运行 `ctest --test-dir sidecar/build/asan -C Debug`(别指向 `sidecar/build/windows`,那是非 ASan 树)。

### 4.4 截图 / 视觉验收（硬要求）
- **每个 live 用例必须留一张 `test/live_visual/<name>.png` 截图并通过主循环视觉验收**（`Read` 读图：回复气泡完整、工具卡 Done、布局无 overflow）。截图放 `try/finally`，非 `addTearDown`（teardown 在 tree reset 后才跑，boundary 已 unmount → pass 路径断裂）；失败 `delete-on-fail` + `[SHOT]` 记录。`setUpAll(clearLiveVisualDir)` 清旧图防 stale。字节下限 `_kMinShotBytes=2048`（仅拒零长/损坏，非 blank 检测器）。
- **诚实三态**：图可读且正常 → 通过；图异常（黑帧/空白/裁切/overlay 溢出）→ 记"此图异常+原因"；图失败/看不清 → 记"截图无效"，**不算通过**。
- **通道区分**：`captureLiveShot` 捕获 **Flutter 场景渲染**（非 OS 窗口，无标题栏/边框，HiDPI 为逻辑像素）。缺陷若在 **OS 级窗口**（如浏览器工具弹出的独立 Edge 窗口），Flutter toImage 捕获不到，须补 **OS 全屏截图**（PowerShell `CopyFromScreen`，参考 `test/smoke/utils.sh` 的 `capture_screenshot()`）核对"用户所见的窗口"。判断式验收 vs 像素回归：本通道是**判断式**，像素回归归 `visual-regression` spec + `test/smoke/references/`(tracked) / `test/smoke/output/`(gitignore)。

### 4.5 冒烟/集成日志
- 冒烟：`test/smoke/output/run.log` + 最终 `SMOKE TEST REPORT`(每步 PASS/FAIL、Total、ALL_PASS vs FAILURES DETECTED)。`verify_logs` 在 `sidecar.log` 里 grep `ERROR|unrecognized`(用 `LOG_START_LINE` 切片忽略历史)。`verify_db` 用 sqlite3 查 `sessions`/`messages` 表。

---

## 5. 权威规则速查（写新功能前）

1. **先定层**(§1)再写：纯逻辑/test/unit、渲染/test/widget、假 sidecar 端到端/test/integration、真模型/`integration_test`+`--tags live`、C++/`sidecar/test`、整套/`test/smoke/run_all.sh`。
2. **可观测性**(§3.1)：live 类必须"断言前"dump 工具调用 + 文件状态;失败必须有现场。
3. **禁手写 artifacts**：OpenSpec change 用 `/opsx:propose` 一次生成全套;`/opsx:apply` 执行时连续跑完。
4. **禁止改验收标准 / 批量打勾 / 隐藏失败**。
5. **禁"手动/用户参与"任务**——转成主循环能跑的自测。
6. **步骤回读规范**：referenced `DEBUGGING.md`(崩溃/日志/ASan)。
7. **分层策略**(点参考，按当前代码为准)：Tier1 叶子组件 / Tier2 widget+注入 / Tier3 集成;live 用窗口真模型形态。
8. **新功能必须带测试**：新增逻辑/UI/工具/错误路径，应配套对应层的测试用例 + 更新对应 `openspec/specs/<capability>/spec.md`，并在 tasks.md 里落到可自测的验证任务。
9. **live 测试必须带截图 + 视觉验收**（§3.1 硬要求）：每用例 `captureLiveShot` 留 `test/live_visual/<name>.png`，主循环 `Read` 读图判断式验收；无截图/截图无效 ≠ 通过。涉 OS 级窗口（如浏览器工具）另补 OS 全屏截图。
