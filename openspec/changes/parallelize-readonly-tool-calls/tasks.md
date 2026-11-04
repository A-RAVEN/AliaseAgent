# Tasks: 只读工具并行执行

## 1. 留档与前提核对（先立可对照的事实，再动任何东西）

- [ ] 1.1 开工留档（供第 9 节对照，全部落到 `%TEMP%\parallel_tools_baseline_*.log`）：`git rev-parse HEAD` 记下开工提交号；`flutter analyze *> %TEMP%\parallel_tools_baseline_analyze.log` 记下问题总数；先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 再 `flutter test *> %TEMP%\parallel_tools_baseline_test.log` 记下通过数；`ctest --test-dir sidecar/build/windows -C Debug *> %TEMP%\parallel_tools_baseline_ctest.log` 记下载入数。9.1/9.2 的对照一律指向这几份日志与该提交号，不许裸说"基线"。
- [ ] 1.2 静态状态全链路清点（design Context 已实测两处，本任务核完九个只读名字）：逐个读 `read_file` / `list_dir` / `glob_file` / `grep_file` / `read_spill` / `read_image`（`context_api.cpp` → `tools.cpp`/`spill.cpp`/`image` 相关实现）与 `web_search`（`search_provider.cpp`，已知 `dispatch_web_search` 进程级 `g_dispatch_mutex` 串行，确认锁语义即可）/ `web_fetch`（`web_fetch.cpp`，已知 `g_python_checked`/`g_python_available` 无锁）/ `get_current_time`（纯 Dart）的调用链，列出链上所有静态可变状态与保护方式（`std::atomic` / `thread_local` / mutex / const 均算），产出"符号 → 保护方式"清单贴进报告。**除 design D9 已列明的 web_fetch 两处（由 2.1 修）外再发现未加锁的静态可变状态：停工上报**，不许绕过、不许当场扩大修复面。
- [ ] 1.3 向 `Docs/known-bugs.md` 追加一条：`web_search` 在 sidecar 现有实现里被 `dispatch_web_search` 的进程级互斥锁整体串行（引用注释原文"两个上下文同时搜索会并发改写它们。串行执行"），后果是同一轮多个 `web_search` 无时间收益；期望方向：provider 实例/凭据/限流状态下沉到上下文；重新考虑时机：另立 change。本 change 只披露不改锁（`sidecar/test/context_ownership_test.cpp` 既有用例把该串行钉为受保护行为）。

## 2. C++ 最小修复（D9，web_fetch 首次并发探测）

- [ ] 2.1 `sidecar/src/web_fetch.cpp`：`detect_python()` 的探测体包进 `std::call_once`（新增 `static std::once_flag`），`g_python_available`/`g_python_checked` 改为函数内 `std::atomic<bool>`（或 call_once 完成后单点读取），消除"已置 checked 未置 available"的中间态。验收：`cmake --build sidecar/build/windows --config Debug` 成功 + 2.2 用例绿 + 全量 ctest 与 1.1 留档对照无新增失败。
- [ ] 2.2 新建 `sidecar/test/context_concurrency_test.cpp` 并加入 `sidecar/CMakeLists.txt` 的 `sidecar_tests` 源列表，全部用例带 Catch2 标签 `[context-concurrency]`：① 同一上下文 8 个 `std::thread` 并发经业务入口调 `read_file`（各线程不同路径、内容互异），断言每个线程拿回自己请求的内容（thread_local 返回槽在本 change 新调用形态下不串）；② 同一上下文 8 线程并发触发写 spill，断言 8 个文件名序号两两不同；③ 多线程同时首次进入 Python 探测入口，断言所有线程得到一致的探测结果（覆盖 2.1 修复）。验收命令：`sidecar/build/windows/Debug/sidecar_tests.exe "[context-concurrency]"` 全绿（注意 `ctest -R` 不可用——CTest 只注册了 `sidecar_tests` 一个测试名，`-R context_concurrency` 恒零命中；`ctest --test-dir sidecar/build/windows -C Debug` 全量仍须绿）。
- [ ] 2.3 可失败性证明（由监督者做，涉及对产品代码的临时变异，子 agent 不碰）：临时把 2.1 的 call_once 还原为无锁形态并把 `spill_seq_` 退回裸 `unsigned`，跑 2.2 贴出变红输出，再逐字还原并 `git diff sidecar/` 证明回到修复后状态。

## 3. 分组纯函数与配置项（test/unit 层）

- [ ] 3.1 新建 `lib/services/tool_group_planner.dart`：纯函数 `planToolGroups(List<String> names, {int maxParallel = 0})` 输出按原顺序的最小分段计划（每段：成员下标区间 + 是否并发段）。规则按 design D1/D6：连续只读合并；段长 1 为逐个段；`maxParallel` 为 0 时并发段整体一组，为正整数时按该值顺次切成多个子并发段（交付顺序不变）。只读集合 = spec 点名的 9 个名字（`read_file`、`list_dir`、`glob_file`、`grep_file`、`read_spill`、`read_image`、`get_current_time`、`web_search`、`web_fetch`）；不在集合内一律逐个段。
- [ ] 3.2 新建 `test/unit/tool_group_planner_test.dart`：① `[grep_file, grep_file, grep_file]` → 一个并发段含 3 项；② `[read_file, read_file, read_file]`（用户判据点名的 3 个 `read_file`）→ 同一并发段；③ `[grep_file, write_file, read_file]` → 三个逐个段；④ `[write_file, write_file]` → 各自单独逐个段；⑤ 未知名 `future_tool` → 逐个段且不与相邻只读合并；⑥ 单个 `[read_file]` → 逐个段；⑦ `[read_file, read_file, read_file, read_file]` + `maxParallel: 2` → 两个并发段各 2 项、顺序保留；⑧ `maxParallel: 0` → 4 项一段；⑨ 空列表 → 空计划。验收：`flutter test test/unit/tool_group_planner_test.dart` 全绿。
- [ ] 3.3 在同一个文件加守卫用例（集合**相等**断言，不只是并集覆盖）：只读集合恰好等于 9 个点名名字（多一个/少一个/把 8 个逐个名挪进只读集，任何变化都红）；逐个名集合恰好等于 `write_file`、`edit_file`、`run_command`、`browser_navigate`、`browser_click`、`browser_type`、`browser_snapshot`、`spawn_subagent` 8 项；两集合交集为空；并集覆盖 `ToolCatalog.kBaseToolNames` 加 `lib/main.dart` 条件注册的 `web_search`/`web_fetch`/浏览器四件（共 17 名）。手工把 `run_command` 挪进只读集合跑一次贴红、还原贴绿。
- [ ] 3.4 `lib/models/app_config.dart`（及 `fromJson`/`toJson` 解析路径）新增 `tool.parallel_max`：默认 0（键缺失、非整数、负数一律回落 0 并打印一次提示——沿用 `compaction_threshold_percent` 的缺省回落形态）；正整数生效。验收：`test/unit` 新增/扩展配置用例覆盖 有值/缺键/0/负数/字符串 五种输入的结果（落点与既有 app_config 测试同文件），`flutter test` 该文件绿。

## 4. sidecar 桥的 worker 入口与测试替身记录机制

- [ ] 4.1 `lib/services/sidecar_bridge.dart`：`ISidecar` 新增 `Future<String> callToolOnWorker(String toolName, String handle, String requestJson)`；真实实现走既有 `Isolate.spawn(_webWorkerMain, …)` 模式；`_webWorkerMain` 分派表扩展六个只读名字（`read_file`、`list_dir`、`glob_file`、`grep_file`、`read_spill`、`read_image`；`list_dir` 的裸路径入参按现有 `listDir` 形态在组装 JSON 后转调）。分派表收到不在表里的名字时返回带名字的显式错误 JSON（不静默当别的工具执行）。
- [ ] 4.2 `test/integration/helpers/fake_sidecar.dart`：实现 `callToolOnWorker`；并把**所有**工具入口（六个同步方法 + `callToolOnWorker` + `webSearch`/`webFetch`/`runCommand` 等异步方法）统一记录：调用名、所经入口（同步/worker/异步）、开始与结束时刻、可注册延迟与抛错（延迟毫秒数为测试构造值、不是产品限制，注释写明）。既有 `FakeSidecar` 消费者不破坏（记录为增量字段）。

## 5. 集成用例先行（此时产品循环未改，并发类断言必须为红）

- [ ] 5.1 新建 `test/integration/tool_parallelism_test.dart`（用 4.2 的记录与 5.x 场景数据）覆盖 delta spec 全部可自动化场景：① 一轮 3 个 `read_file` 各延迟 200ms，断言三个时间窗两两重叠且该段总耗时 < 400ms（串行形态必为 ≥600ms）；② `[grep_file(200ms), write_file(150ms), read_file(100ms)]`（毫秒数为测试构造值）断言 `write_file` 开始 ≥ `grep_file` 结束、`read_file` 开始 ≥ `write_file` 结束（跨段提前启动必红）；③ 并发段成员延迟 300/50/100ms 倒序完成，断言请求体 `tool_result` 顺序、UI 回调顺序、`toolCallsJson` 顺序都等于发出顺序；④ 段内一个 `web_fetch` 注入抛错、两个成功，断言三个结果按序齐发、失败者错误文本含工具名与注入的原因串、下一轮请求照常组装；⑤ 单只读一轮断言 FakeSidecar 记录到同步入口被调用且 `callToolOnWorker` 零调用；⑥ 连续两个 `write_file` 断言两者都走逐个入口执行且时间窗不重叠；⑦ `tool.parallel_max=2` + 4 个只读，断言分 2+2 两批（第二批最早开始 ≥ 第一批最晚结束）且交付按发出顺序；⑧ 并发段启动前取消，断言 FakeSidecar 零调用记录；⑨ 段执行中取消（成员延迟未结束触发取消），断言所有已启动成员都有结束记录（自然结束、无半途泄漏）、本轮请求体不追加该组 `tool_result`、被丢弃成员卡片回调终态且文本含"因取消未取回结果"、其 `toolCallsJson` 富化同一说明；⑩ 取消后同会话再发一条消息，断言重放历史里该轮 `tool_result` 内容为取消说明而非空串。⑪ fake 模型让子 Agent 一轮发 2 个连续只读（沿用 `test/integration/subagent_tool_test.dart` 的子运行搭建方式），断言时间窗重叠。
- [ ] 5.2 跑 `flutter test test/integration/tool_parallelism_test.dart`：在 5.3/6.x 完成前，并发类断言（①②③⑦⑨⑪）**必须为红**并把红输出贴进报告——贴不出红就证明不了这些用例会在功能坏掉时变红（CLAUDE.md 工作记录规范第 3 条）；此时单工具回归类（⑤⑥⑧⑩④）可为绿或按实现进度部分红。

## 6. Agent 工具循环改造（验收 = 第 5 节用例转绿）

- [ ] 6.1 `lib/services/agent.dart` 工具循环按 `planToolGroups` 重写段执行：逐个段成员完全走现有 `_executeTool`（时序与现状一致）；并发段成员并发启动——同步 FFI 六类经 `sidecar.callToolOnWorker`，`web_search`/`web_fetch` 用现有异步方法，`get_current_time` 主 isolate 直接完成；`maxParallel` 从 `AppConfig` 读入传给 planner。每个成员独立 try/catch，异常转成 `{"ok":false,"error":"<工具名>: <异常原文>"}` 形态（design D5：不得丢原因）。
- [ ] 6.2 并发段按段内原始顺序收集：结果就绪后逐条走现有 UI 回调（`callbacks.onToolResult`，按 id 原位更新卡片）、`toolResults` 追加、`turnToolCalls` 富化逻辑；三段产物顺序与串行版逐位一致。
- [ ] 6.3 取消收尾按 design D4：段启动前 `_isActive(epoch)` 检查；并发段执行中取消 → 等成员自然结束 → 丢弃、卡片置终态（含取消说明文本）、`toolCallsJson` 富化同一说明、不追加该轮 `tool_result`；串行段成员同规则。
- [ ] 6.4 `flutter test test/integration/tool_parallelism_test.dart` 全绿（①–⑪）；`flutter analyze` 对改动文件零新增问题。

## 7. 真 DLL 并发与计时（test/integration 层，非 fake）

- [ ] 7.1 新建 `test/integration/sidecar_worker_test.dart`（真 `sidecar.dll`、无窗口、无模型请求）：同一上下文并发发起 3 个 `callToolOnWorker('grep_file', …)`（pattern 各不相同扫 `lib/`），断言三份结果两两不同、各自只含自己 pattern 的命中（thread_local 返回槽真并发不串）；再串行跑同样 3 个调用，断言每项与并发版逐字节一致；**计时断言**：并发总耗时 < 串行总耗时的 60%（同机同内容两次测量比值，真本地 I/O + ripgrep 子进程；断在 60% 是给调度抖动留量——若实测波动导致不稳，改判据为"并发 < 串行"的严格小于比较并贴两组读数，不许放宽成恒真）。
- [ ] 7.2 该用例先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 再 `flutter test test/integration/sidecar_worker_test.dart` 全绿；把实现仍为串行时该计时断言必红的证据（6.x 完成前跑一次的输出，或在 6.4 之后以代码走查说明"并发启动路径即 callToolOnWorker 同时挂起 3 个 isolate"）贴进报告。

## 8. live 真实模型链路（integration_test 层）

- [ ] 8.1 新建 `integration_test/tool_parallelism_live_test.dart`（`@Tags(['live'])`，真实模型 + 真 DLL）：职责边界（对抗验证 0009 裁定）——**时间收益判据由 7.1（真 DLL 计时）与 5.1①（确定性延迟）承担，本用例不重复计时断言**；本用例验真实链路端到端：提示词明确要求模型"在同一轮里对 `lib/` 与 `sidecar/` 各发出一次 `grep_file`"，断言单个 assistant 轮含 ≥2 个只读 `tool_use`、两个结果都按序交付且内容与实际目录相符、下一轮请求组装成功；断言前打印每个调用的名称、完整 input、开始/结束时刻与重叠观测（TESTING.md §3.1 可观测性）；模型未按形态发出时判失败并打印现场（不静默跳过、不自造重试次数，沿用既有 live 用例同类处置）。跑完 `captureLiveShot` 留图，主循环 `read_image` 做视觉验收。验收：`flutter test --tags live --run-skipped integration_test/tool_parallelism_live_test.dart -d windows` 非跳过通过 + 截图目视验收。

## 9. 用户文档与守卫（与代码同一 change）

- [ ] 9.1 `Docs/user-guide/tools-file.md` 新增一节"只读工具的并行执行"：9 个只读名并行、8 个逐个名、结果按发出顺序交付、卡片先"执行中"后按序落结果、取消时卡片置终态并写明未取回、`tool.parallel_max` 收窄办法（指向 configuration.md）。`Docs/user-guide/tools-web.md` 补一小节：同一轮多个 `web_search`/`web_fetch` 会被并发启动，但 `web_search` 因 sidecar 现有实现串行执行（当前并行收益只在 `web_fetch` 侧），`web_fetch` 每路各起一个抓取子进程、同时多路内存峰值上升、可用 `tool.parallel_max` 收窄。
- [ ] 9.2 `Docs/user-guide/configuration.md` 配置键表新增一行 `tool.parallel_max`（默认 0 = 不设上限；正整数 = 单个并发组一次最多同时启动的成员数；作用与生效时机）。
- [ ] 9.3 新建 `test/unit/parallel_tools_docs_test.dart` 守卫：从 `tool_group_planner.dart` 读只读集合常量、从文档正文解析名字清单，断言 9 个只读名逐个出现在 `tools-file.md` 该节、8 个逐个名逐个出现、`configuration.md` 含 `tool.parallel_max` 行且默认值文字与代码缺省一致。验收：全绿后手工从文档删一个名字跑一次贴红、恢复贴绿。

## 10. 收尾全量验证（监督者执行，对照 1.1 留档）

- [ ] 10.1 `flutter analyze *> %TEMP%\parallel_tools_after_analyze.log`：问题总数与提交号对照 1.1 的 `parallel_tools_baseline_analyze.log`，改动文件零新增（新增即逐条归因修复）。
- [ ] 10.2 先 `sync_sidecar_dll.ps1` 再 `flutter test *> %TEMP%\parallel_tools_after_test.log`：与 1.1 的 `parallel_tools_baseline_test.log` 对照，通过数只增不减**且第 5/7 节新用例以 `-n` 计数逐一确认为通过而非跳过**（贴两组用例名与计数）。
- [ ] 10.3 `cmake --build sidecar/build/windows --config Debug` + `ctest --test-dir sidecar/build/windows -C Debug *> %TEMP%\parallel_tools_after_ctest.log`：与 1.1 留档对照全量绿（含 2.2 新用例）。
- [ ] 10.4 `test/smoke/run_all.sh`（Windows 用 `run.bat`；其中 launch_and_verify 步骤自带的短暂窗口属测试行为）通过，补齐 CLAUDE.md 验证清单第 5 层。
- [ ] 10.5 8.1 的 live 非跳过通过 + `read_image` 截图目视验收；5.2、7.2、2.3、9.3 的"变红证据"齐全可读。
- [ ] 10.6 `openspec validate parallelize-readonly-tool-calls` 通过；本文件无 `- [ ]` 残留。
