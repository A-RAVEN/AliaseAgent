# Proposal: 只读工具并行执行

## Why

模型在一轮里经常连续发出多个互不依赖的只读调用（例如同时发 3 个 `grep_file` 找不同符号、或同时抓两个网页），而当前工具循环是逐个串行：`lib/services/agent.dart` 的 `for (final tc in turnToolCalls) { … await _executeTool(tc); … }`，总等待等于每个调用耗时之和。`grep_file` 每路要派生一个 ripgrep 子进程扫描工作区（`sidecar/src/tools.cpp` 的 grep_file 实现路径），`web_fetch` 每路要派生一个 Python 抓取子进程再走完整网络往返（`sidecar/src/web_fetch.cpp` 的 `run_crawl4ai_subprocess`）——串行时这些子进程与网络等待完全不重叠。上下文句柄化（`add-context-handles`，2026-11-01 归档）已经把 sidecar 的执行状态改成"每上下文一份、返回槽 thread_local、序号原子自增"，并发安全的前提大部分建好（对抗验证实测出 `web_fetch` 的 Python 探测静态量与 `web_search` 的进程级串行锁两处现状缺口，由本 change 一并修复/披露）。本 change 兑现它的收益，是 `Docs/RoadMap.md` 阶段 6（效率优化）。

## What Changes

- 模型—工具循环新增**执行分组**规则：同一轮里**连续的只读工具调用**归入同一个并发组同时执行；写类与有状态工具（`write_file`、`edit_file`、`run_command`、`browser_navigate` / `browser_click` / `browser_type` / `browser_snapshot`、`spawn_subagent`）仍单独成组、按原顺序逐个执行。只读与写类之间、写类与写类之间的先后顺序永不交换。
- 只读组的**执行并发、交付按序**：发给模型、写入界面工具卡、落库 `toolCallsJson` 的结果顺序仍等于模型发出 `tool_use` 的原始顺序，与谁先执行完无关。
- 只读组内并发数默认**不设上限**：模型发几个就同时执行几个；同时新增配置项 `tool.parallel_max`（默认 0 = 不设上限；正整数 = 单个并发组一次最多同时启动的成员数，超出部分按原顺序在其后的子段中执行，交付顺序不变）。本产品为全权限零审批设计，也不引入任何确认机制。
- 同步调用的只读工具（`read_file`、`list_dir`、`glob_file`、`grep_file`、`read_spill`、`read_image`）在**组内成员多于一个时**改经 worker isolate 执行以便真正重叠；组内只有一个成员时维持现有同步路径，单工具场景的时序与现在完全一致。
- 取消语义对齐现有行为并补齐可见性：分组执行前发现本轮已取消则整组不启动；已启动的组等其成员自然结束后丢弃结果，不再发给模型。被丢弃成员的工具卡片从"执行中"置为终态并写明"因取消未取回结果"；历史重放为这些调用合成带取消说明的结果，不再合成空文本（让模型能区分"工具返回空"与"因取消没有结果"）。
- 组内单个调用失败或超时不影响同组其它调用：每个成员独立成败，失败者的错误文本 SHALL 带上工具名与实际失败原因（超时/异常原文），不得用不含原因的通用文案顶替。
- 子 Agent（`spawn_subagent` 创建的运行实例）复用同一个循环代码，自动获得同样的并行行为。
- C++ 侧只做一处最小修复：`web_fetch.cpp` 的 Python 探测改 `std::once_flag` + `std::atomic<bool>`（消除本 change 并发化 `web_fetch` 后首次探测的数据竞争）；`web_search` 的进程级串行锁维持现状（受既有测试保护的既有行为，本 change 只在用户文档与 known-bugs 如实披露，其上下文化另立 change）。其余并发前提已由上下文句柄化落地，另增多线程压力用例钉死。

## Capabilities

### New Capabilities

（无。本 change 是对现有 Agent 运行循环行为的规范补充，落在既有能力 `agent-runtime` 上。）

### Modified Capabilities

- `agent-runtime`：新增"只读工具并发执行、结果按序交付"的 Requirement（现有 5 条 Requirement 均不涉及一轮内多个工具调用的执行顺序与并发形态，故本 change 是对该能力的 ADDED，而非改写既有条文）。

## Impact

- **Dart 产品代码**：`lib/services/agent.dart`（工具循环分组与并发执行）、`lib/services/sidecar_bridge.dart`（`ISidecar` 接口新增"把指定工具调用派到 worker isolate 执行"的通用入口；`_webWorkerMain` 的 worker 分派扩展到六个同步只读工具）、`lib/models/app_config.dart`（新增配置项 `tool.parallel_max`，默认 0）。
- **测试替身**：`test/integration/helpers/fake_sidecar.dart` 实现新接口入口，并对**所有**工具入口记录开始/结束时刻与所经入口（同步或 worker），供时序与入口断言。
- **C++ sidecar**：`sidecar/src/web_fetch.cpp` 的 Python 探测静态量最小修复（D9）；其余导出与实现不变；`sidecar/test` 新增多线程并发调用用例（同上下文并发读、web_fetch 并发首探测）。既有 Catch2 用例（`context_ownership_test.cpp` / `context_test.cpp` / `spill_write_test.cpp`）已覆盖结果槽与 spill 序号的并发正确性，本 change 沿用并补缺口面。
- **测试**：`test/unit`（分组纯函数、配置项解析）、`test/integration`（FakeSidecar 时序与按序交付、真 DLL 并发）、`sidecar/test`（并发压力）、`integration_test` live（真实模型链路端到端正确性）、`test/smoke`（收尾第 5 层）。
- **文档**：`Docs/user-guide/tools-file.md` 与 `tools-web.md` 补"一轮内多个只读工具会并行执行、结果仍按发出顺序返回"，并如实写明 `web_search` 在 sidecar 现有实现里被进程级锁串行（并行收益当前只在 `web_fetch` 侧兑现）；`Docs/user-guide/configuration.md` 配置键表新增 `tool.parallel_max`；`Docs/known-bugs.md` 记一条 `web_search` 串行的既有缺陷。均与代码文案在同一 change 内同步。
- **不受影响**：模型请求体形状（`tool_result` 顺序不变）、压缩阈值计算（窗口 × 百分比规则不动）、Provider/模型探测、计量口径、`run_command`/浏览器/编辑类工具的串行行为。
