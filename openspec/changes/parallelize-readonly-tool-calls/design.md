# Design: 只读工具并行执行

## Context

**现状（全部读代码核实）**：

- 工具循环在 `lib/services/agent.dart`：`for (final tc in turnToolCalls) { if (!_isActive(epoch)) break; final result = await _executeTool(tc); … toolResults.add(...); … }`，一轮内逐个串行。
- `_executeTool` 的调用形态分两类：
  - **同步 FFI、跑在主 isolate**：`read_file`、`write_file`、`edit_file`、`list_dir`、`glob_file`、`grep_file`、`read_spill`、`read_image`（`lib/services/sidecar_bridge.dart` 注释自述 "tools (run on main isolate — they're fast, local calls)"）。这类调用在单个 `Future` 里并发启动等于假并行——主 isolate 一次只能跑一个同步 FFI。
  - **worker isolate、真异步**：`web_search`、`web_fetch`、`browser_*` 四件、`run_command`（`_workerTool` 每次 `Isolate.spawn(_webWorkerMain, …)`）。
  - 另有 `get_current_time`（纯 Dart）与 `spawn_subagent`（走 `subagent_runner`）。
- 工具全集：`ToolCatalog.kBaseToolNames` 11 项 + 条件注册 `web_search` / `web_fetch` + 浏览器四件套，共 17 个名字。
- C++ 侧并发前提（上下文句柄化已落地）：`sidecar/src/sidecar_api.cpp` 注释——返回字符串由"每个入口专用的 thread_local 槽"持有；`sidecar/include/context.h` 的 `std::atomic<unsigned> spill_seq_`（`Context::next_spill_seq()` 是原子自增）；`sidecar/src/context.cpp` 的 `Registry` 全部方法在 `std::mutex` 下；`tools.cpp` 的暂存计数器 `g_staging_counter` 是 `std::atomic`；浏览器操作在上下文的 `browser_mutex_` 下排队。
- 接口与测试替身：`ISidecar`（`lib/services/sidecar_bridge.dart`）与 `FakeSidecar`（`test/integration/helpers/fake_sidecar.dart`）已存在，端到端假 sidecar 测试直接可用。
- **两处现状与"前提已建好"不符（对抗验证 2026-11-04 实测，本 change 必须一并处理）**：
  - `sidecar/src/web_fetch.cpp` 的 `static bool g_python_available` / `g_python_checked`（L76-77）被 `detect_python()`（L84 起）**无锁**读写（`if (g_python_checked) return; g_python_checked = true;` 再逐分支探测后置 `g_python_available`）。它不在上下文句柄化（`add-context-handles`）阶段 2 清单覆盖的四项全局状态里；本 change 把 `web_fetch` 放进并发段后，同一轮多路 `web_fetch` 首次并发时两个线程可同时进探测——数据竞争，且第二个线程可能读到"已置 checked 但未置 available"的中间态而误判 Python 不可用。⇒ 新增最小修复任务（D9）。
  - `sidecar/src/search_provider.cpp` 的 `dispatch_web_search`（L366 起）一进函数就取进程级 `static std::mutex g_dispatch_mutex`（L370-371，注释自述 provider 实例、凭据、限流计数与探测结果都是应用级共享状态，"两个上下文同时搜索会并发改写它们。串行执行"）。同一轮多个 `web_search` 在 Dart 层并发启动后仍会在 sidecar 内排队，**时间收益只在 `web_fetch` 与其它工具上兑现**；既有 Catch2 用例"两个上下文并发 web_search 时假 provider 一次只看到一个在跑"（`sidecar/test/context_ownership_test.cpp`）把这条串行钉成了受保护行为。⇒ Dart 层照常并发启动（不违反本设计），该串行的上下文归属改造属后续 change，本 change 记一条 `Docs/known-bugs.md` 并在用户文档如实披露。
- 界面工具卡时机（对抗验证更正本设计早期版本的错误陈述）：`lib/services/agent.dart` 的 `onToolCall` 在模型**流式发出 `tool_use` 时**就构造 `ToolCallActivity`（默认 `status = executing`）并经 `callbacks.onToolCall` 交付；`lib/main.dart` 插入卡片；结果就绪时 `callbacks.onToolResult` 的接收方按 `id` **原位更新**同一张卡（`lib/main.dart` 的 `onToolResult` 分支在 `_chatItems` 里找同 id 项替换）。并发段因此天然呈现"多张执行中卡片、按发出顺序逐个落结果"。

**约束**：本产品零审批全权限（不加任何确认）；禁止发明数量上下限魔数（AGENTS.md 第 9 节）；压缩阈值规则不动；文档随功能同 change 更新。

## Goals / Non-Goals

**Goals:**

- 一轮内连续的只读工具调用真正并发执行，总等待从"各调用耗时之和"降为"最慢一个的耗时"量级。
- 模型请求体、界面工具卡、`toolCallsJson` 落库三处的结果顺序与串行版完全一致（可确定性测试）。
- 单个只读工具的场景时序零回归。
- 写类/有状态工具与只读工具之间的原始先后顺序永不交换。

**Non-Goals:**

- 不给 `run_command` 推断"这条命令是否只读"。
- 不做相同调用的去重或缓存。
- 不改界面工具卡的呈现机制（现状：`tool_use` 流式到达即插入"执行中"卡片，结果就绪时按 `id` 原位更新——见 Context 末条；本 change 沿用该机制，不新增"段内已完成 n/m"这类进度展示）。
- 不给任何工具新增超时数值（现有超时值原样保留）；并发上限做成配置项（D6），默认不设上限。
- 除 D9 的 `web_fetch` 探测状态最小修复外，不改 C++ 导出与实现（其余并发前提已由上下文句柄化落地，本 change 加压力用例钉住它）。

## Decisions

### D1 执行分组：连续只读段并发，其余逐个

把 `turnToolCalls` 按原顺序切成最小数量的段：**连续**的只读调用合并为一个并发段；非只读调用每个单独成段。段与段之间仍按原顺序执行（上一段全部结果收完才开始下一段）。

- **只读段**（9 个名字）：`read_file`、`list_dir`、`glob_file`、`grep_file`、`read_spill`、`read_image`、`get_current_time`、`web_search`、`web_fetch`。
- **串行段**（8 个名字）：`write_file`、`edit_file`、`run_command`、`browser_navigate`、`browser_click`、`browser_type`、`browser_snapshot`、`spawn_subagent`。
- 分类表是产品代码里一处常量集合，**默认串行**：目录里出现但不在只读集合里的名字一律串行（新工具默认落在安全侧）。守卫用例断言"只读集合 ∪ 显式串行集合 = ToolCatalog 全部已知名字"，未来加工具没归类时测试变红。
- 为什么是"连续段"而不是"整轮所有只读一起并发"：模型发出 `[grep, write, read]` 时，`read` 想读的正是 `write` 刚写的内容；跨过写类并行会读到过期数据，把正确性交给模型运气。连续段方案保留全部原始顺序依赖，只消除段内互不相关的等待。
- 浏览器四件套里有"读"性质的 `browser_snapshot`，但浏览器会话是有状态单资源（一个 worker 一条 stdin/stdout 帧通道），段内并发只会互相排队还打乱"每步重读实时快照"的语义，故整类串行。
- 备选（放弃）：读写全并行 + 依赖调用完成序——破坏结果确定性，测试与请求体顺序都无法锚定。

### D2 只读段的启动方式：段长 1 走原路，段长 ≥2 同步工具进 worker isolate

- **段长 1**：完全走现有 `_executeTool` 代码路径（同步工具仍主 isolate 同步调用）。单工具时序零回归。
- **段长 ≥2**：段内每个成员并发启动；其中同步 FFI 六件改经 `ISidecar` 新增的通用入口 `Future<String> callToolOnWorker(String toolName, String handle, String requestJson)` 执行——即复用 `_webWorkerMain` 的 isolate 模式，worker 分派表从（web/browser/run_command/dispose/browser_available）扩展到也认这六个只读名字；`get_current_time` 直接在主 isolate 完成；`web_search` / `web_fetch` 用现有异步方法原样启动。每个 isolate 调用打开的 `sidecar.dll` 是同一模块，并发落到不同 C++ 线程，返回各走 thread_local 槽。
- 为什么不全量统一走 isolate：`Isolate.spawn` 每次要新建 isolate 并在其中重新打开 `sidecar.dll`、重新 `lookupFunction`（`_webWorkerMain` 的既有形态），这是 Dart isolate 机制自身的固定开销，非零（平台行为，不在此赋予具体毫秒数——没有合法出处就不写数）。`read_file`/`grep_file` 等单工具调用是当前产品最高频、走同步返回的路径，段长 1 也走 isolate 等于给每一次单读都新增一层从未有过的异步间接——"段长 1 走原路"把它排除在外，单工具场景时序与现状逐字节一致。
- 备选（放弃）：Dart `compute`/常驻 isolate 池——池引入生命周期与上下文释放的耦合，现模式（一次调用一个短命 isolate）与既有 `_workerTool` 一致，可核对性最好。

### D3 执行并发、交付按序

段内用并发启动、**按段内原始顺序收集**（`Future.wait` 的结果天然按启动序返回）；随后按这个顺序逐条走现有的 UI 回调（`callbacks.onToolResult`）、`toolResults` 追加、`turnToolCalls` 富化（`toolCallsJson` 落库）逻辑。发给模型的 `tool_result` 块顺序 = 模型发出 `tool_use` 的顺序，与串行版逐字节同形。

### D4 取消语义（含可见性）

- 每段**启动前**检查 `_isActive(epoch)`：已取消则整组不启动、跳出循环（与现状"每个工具前检查"在段边界等价；不启动就不会有悬挂 isolate）。
- 段执行途中收到取消：等该段全部成员自然结束（保证 `ReceivePort` 关闭、isolate 退出、资源不泄漏），丢弃结果，不再追加 `tool_result`，跳出循环发下一轮请求的路径维持现状。
- **丢弃必须可见、可见必须可恢复**（AGENTS.md 第 9 节）：被丢弃成员已经以"执行中"卡片出现在界面上（Context 末条），所以取消收尾时 SHALL 把这些卡片置为终态（`ToolCallStatus.error` 形态，结果文本写明"本轮被取消，该工具结果未取回"），并在其 `toolCallsJson` 富化同一条说明——否则历史重放（`lib/services/agent.dart` 组装 `apiMessages` 处，`tc['result']` 为空即合成空 `tool_result`）会让模型把"因取消没有结果"读成"工具返回了空"。串行段中途已执行完但未交付的成员同样按本条收尾（该路径的取消语义由本 change 统一定义）。

### D5 失败隔离（错误文本必须带原因）

段内每个成员独立 try/catch：单成员抛错转成现有错误形态 `{"ok":false,"error":…}` 的解析结果，不影响同段其它成员；`error` 文本 SHALL 包含工具名与实际失败原因（异常原文或超时说明），SHALL NOT 用不含原因的通用文案顶替——既有 `_executeTool` 尾部就有把解析异常统一写成 `'Failed to parse tool result'`（不带工具名）的先例，本 change 的新路径不沿用该缺陷形态。超时分支沿用各 worker 现有的超时注入文案（不新增数值）。`_executeTool` 的结果后处理（`_formatSearchResultForDisplay`、`composeCommandResultText`、截断标记等）逐成员保留原样。

### D6 并发上限 = 配置项 `tool.parallel_max`（默认 0 = 不设上限）

段大小默认 = 模型在一轮里连续发出的只读调用数，不加硬编码上限——"最多 N 个"的 N 拿不出四类合法来源。本地 API 文档记录的是：Anthropic 端 `tool_choice.disable_parallel_tool_use` 默认 `false`（`Docs/AnthropicAPIDoc.md` §3.6，即默认可一次输出多个 `tool_use`），DeepSeek 端该开关被忽略（`Docs/DeepSeekAPIDoc.md` §7"无法通过该开关禁止并行工具调用"）——**没有任何已记载的单轮工具数上限**，所以"不封顶"的风险必须由产品自己可收窄，而不是推给"API 会约束"。
落成配置项（AGENTS.md 第 9 节第 ④ 类来源）：`tool.parallel_max`，默认 0 = 不设上限；正整数 = 单个并发组一次最多同时启动的成员数，超出部分按原顺序在其后的子段中执行（交付顺序仍不变）。默认值与取值范围写进 `Docs/user-guide/configuration.md` 配置键表。
**已知代价**：默认形态下模型一轮发多个 `web_fetch` 会同时启动多个 Python 抓取子进程，内存峰值上升 → 写进用户文档限制节，用户可用 `tool.parallel_max` 自行收窄。

### D7 子 Agent 自动复用

`spawn_subagent` 创建的子运行与主 Agent 共用 `Agent` 循环代码，分组规则在循环内部，子 Agent 无需任何单独实现；规范以一条场景钉住"子 Agent 同样按本规则执行"。

### D8 C++ 压力用例补缺口面

既有 Catch2 用例已覆盖一部分并发前提（`context_test.cpp` 的"result_buffer 的槽按调用线程各存一份 / 另一线程完成调用后先拿到的返回内容仍是自己的"、`context_ownership_test.cpp` 的"两个线程直接调内部 spill 写入入口，序号不同且文件不互相覆盖 / 同一句柄并发 run_command 经业务入口也得到不同 spill 文件"）。本 change 新增的调用形态是**同一上下文并发读业务入口**（多个 worker isolate 同时 `read_file`/`grep_file` 同一句柄）——既有用例没测这一形态，在 `sidecar/test` 新增 Catch2 用例文件，用例带标签 `[context-concurrency]`：① 同一上下文 8 个 `std::thread` 并发经业务入口调 `read_file`（各线程不同路径），断言各线程拿回自己请求的内容；② 同一上下文并发触发写 spill，断言文件名序号两两不同。

### D9 `web_fetch` Python 探测去竞争（最小 C++ 修复）

Context 实测节已写明：`web_fetch.cpp` 的 `detect_python()` 对 `static bool g_python_checked / g_python_available` 无锁读写，并发首探测会数据竞争且可能误判"Python 不可用"。修复：探测体包进 `std::call_once(g_python_once, …)`，结果读回用 `std::atomic<bool>`（先写 available 再置 checked 的发布顺序问题由 call_once 消除）。验收：`sidecar/test` 新增 `[context-concurrency]` 用例——多个 `std::thread` 同时首次调用 web_fetch 的探测入口，断言所有线程得到一致的探测结果；全量 ctest 绿。`web_search` 的 `g_dispatch_mutex` **不改**：它是受既有测试保护的既有行为，上下文化另立 change，本 change 只做文档披露与 known-bugs 记录。

## Risks / Trade-offs

- **同步工具首次面临多线程调用面** → D8 的 C++ 压力用例 + Dart 集成用例（FakeSidecar 并发）双层次兜底；调用链上已逐处核对的并发安全点（thread_local 槽、atomic 序号、Registry 锁、浏览器上下文锁）记入 Context 节，tasks 1.1 再按 9 个只读名字全链路清点；发现未加锁的静态可变状态（`web_fetch` 已发现一处，由 D9 处理）：其余一律作为阻塞性缺陷上报，不许绕过。
- **`web_fetch` 并发放大子进程成本**（每路 worker isolate 都会经 `run_crawl4ai_subprocess` 起一个 Python 抓取进程）→ 默认接受、文档写明、`tool.parallel_max` 可收窄；收益侧正是子进程与网络等待重叠。
- **isolate 启动开销进入只读段**（`Isolate.spawn` + worker 内重新开库是每次的固定成本，平台行为）→ 只在段长 ≥2 时支付；段长 1 走原路。并发省掉的是"被串行化的成员间互等"，两笔账都真实存在，净收益由 5.1 的确定性延迟用例与 3.3 的真 DLL 计时用例证明，不靠形容词。
- **UI 观感变化**：卡片在 `tool_use` 到达时已各自显示"执行中"（现状），并发化后同组多张卡片会同时"执行中"、按发出顺序逐个落结果 → 这正是并发的可见形态；不做"段内 n/m"进度展示（Non-Goal），用户文档写明。

## Migration Plan

无数据迁移；Dart 行为变更全部在 `lib/services/agent.dart` 循环、`lib/services/tool_group_planner.dart`（新文件）、`lib/services/sidecar_bridge.dart` 分派表与 `lib/models/app_config.dart`（新配置键）内，C++ 仅 D9 一处；回滚即恢复原串行循环。DB schema 与模型请求体形状不变；`tool.parallel_max` 缺省（键不存在）= 0 = 不设上限，老配置无感。

## Open Questions

（无。工具归类清单、启动方式、取消与失败语义、并发上限的可配形态都已定死；`web_search` 的进程级锁上下文化明确划入后续 change。）
