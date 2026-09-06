## Context

App 工具边界在 **C++ FFI sidecar**（`dart:ffi` → `web_fetch`/`web_search`）。`web_fetch`（`sidecar/src/web_fetch.cpp`）目前是**单 URL 抓取**：C++ sidecar 起 Python 子进程 `scripts/fetch_worker.py`（**Crawl4AI**），返回 clean Markdown；带 SSRF 前置/blocklist、15s/30s 超时、stderr→sidecar.log。这是**本设计要复用的既有 subprocess 模式**。

关键事实（已核查）：
- 仓库**没有**“Playwright MCP”；`web_fetch` 的浏览器是 crawl4ai 的 **headless、单 URL** 抓取器（`fetch_worker.py:40-56`），不可交互、不可见。
- DeepSeek（Anthropic 兼容端点）**只收文本、不支持 MCP/server 工具**（`Docs/DeepSeekAPIDoc.md:100,697`）→ 工具必须走 sidecar，**不是** harness MCP。
- 归档 `2026-07-27-upgrade-web-fetch-crawl4ai/design.md` 记录浏览器成本/脆弱性：~150MB Chromium 下载、300-500MB/tab、2-5s 冷启动、孤儿进程风险；且有 curl fallback 兜底。
- `web_search` 的 provider：付费的智谱（0.01-0.05 元/次)、Kimi（需 key），外加 **自托管 SearXNG（免费、无 key）**。SearXNG 在**存在非空 search 配置**时会被 `ensure_search_infra` 的**跳过 liveness 检查**（`search_provider.cpp:137-142`）置为不可用（`set_available(false)`），从而不进入 `get_configured_providers()`；但在**空配置 / `{}` 路径**（`search_provider.cpp:85-89` 提前返回，不触发 disable），`SearXNGSelfHost::available_` 保持默认 `true`（`searxng_search.h:37`），`get_configured_providers()` 会返回它。故“从不进入”并非恒真——仅在非空配置路径成立。

## Goals / Non-Goals

**Goals:**
- 给 agent 一个**独立、用户可见、可驱动**的浏览器工具（外置窗口路线甲），可浏览/交互/看 JS 页。
- 每步向**非多模态** DeepSeek 返回**文本快照**。
- **与 `web_search` 独立**（并列，非替代）。
- 复用现有 **subprocess / 超时 / stderr→sidecar.log** 基建降低风险；**SSRF 防护不作为逐交互步复用**（现 web_fetch 的 SSRF 是“按目标 URL 预查 hostname→IP 封禁”，对交互式导航到任意 host 不适用；见 Decision/风险，任务 3.1 只声明复用 subprocess/超时/日志）。
- 默认藏后台、不频繁弹窗；程序级控制（窗口最小化预期不影响操作）。

**Non-Goals:**
- **不把浏览器当 `web_search` 的免费搜索替代**；**不改 `web_search` provider**（付费-only + 失败空结果另行立项）。
- **不做内嵌 WebView2**（独立路线，暂缓）。
- **不做浏览器状态的 UI 展示**（`ToolCallCard`/真实上下文视图——另行立项；本 change 只在 `lib/main.dart` 声明工具）。
- **不做 OCR**（当前仓库无 OCR；OCR 是后续独立决定，见 Open Question）。
- 不做“完美的人类竞态解”——只做工程上的检测与重同步。

## Decisions

1. **驱动栈 = Python Playwright，驱动系统 Edge/Chromium（`channel="msedge"`/`"chrome"`）。**
   - 为什么 / 备选：预期可**免 ~150MB Chromium 下载**（归档里最重的成本项），Win11 自带 Edge。**但“channel 是否真正免下载”是外部、未验证事实**——需 spike（见 Risk / Open Question 1），不当作已定结论。备选“捆绑 Chromium”被否（下载+版本漂移）；“裸 CDP”被否（等于重造 Playwright）。
2. **持久的 sidecar 子进程 worker（长驻），而非 per-call 一次性。**
   - 为什么：浏览器“点→看→再点”是**多步**；一次性不能维持多步状态。
   - 实现：sidecar 起一个 **Playwright worker daemon**，会话启动时拉起；一次任务一个会话。
   - **两层命名**（勿混同）：
     - **sidecar 工具集**（对外、供 AI 调用的工具名）：`browser_navigate / browser_click / browser_type / browser_snapshot`；
     - **worker stdin 协议**（sidecar 与 worker 间内部 JSON 命令）：裸 `{"cmd": "navigate"/"click"/"type"/"snapshot", ...}`；sidecar 提供 `browser_navigate -> {"cmd":"navigate"}` 等一一映射（见 tasks 3.1）。
     - `open` = 会话启动；`relaunch` = **AI 显式重开**（看门狗只检测关闭、返回失败状态，不自动重启；见 Decision 5），不单列命令。
   - 备选：crawl4ai 直接当浏览器 → 否（`arun(url)` 每步新开会话）。
3. **headed（`headless=False`）+ 默认藏后台。**
   - 用户可见；但**不每步 `bringToFront`**、**单 tab 复用**（含显式 popup/新页关闭 handler）、**自动 `dialog` 处理**、**deny 下载/权限弹窗**（显式配置）。
   - 这些作为**固化的 worker 行为**；worker **记录 raise/focus 计数**供测试断言“未 emit bringToFront”。
   - **“仅在某显式可见请求时才提升前台”**：本 change 的浏览器状态 UI 在范围外，因此该**可见请求信号需另行定义**（见 Open Question 5），本 change 不承诺任何 UI 触发；只承诺工具**自身不因逐动作**而 raise。
   - **风险**：窗口最小化/遮挡下，Edge/Chromium 的焦点/前台/是否仍执行、快照是否仍准是**外部事实**，可能需 `--disable-backgrounding-occluded-windows` 等 flags（见 Risk 3）。
4. **每步返回文本快照**（DOM `innerText`/可读性提取），喂 DeepSeek；快照带**长度上限/分块**控 token。OCR 不在本 change。
5. **健壮性**（公共验收标准）：看门狗**只检测**浏览器关闭→返回可检测失败状态→**AI 显式重开会话**（不自动重启，避免把已死会话藏着）；**每步重读实时快照**；URL/内容哈希**分叉检测**；用户手动导航→发“用户接管”信号让 AI 重读。
6. **接入/声明**：“Playwright/Edge 不可用则工具不声明或报可读错误，绝不静默占位”是**本 change 的新政策**，且**声明门 = 浏览器运行时，不与搜索 provider 可用性耦合**。**关键**：浏览器工具**声明在 `if (hasProviders)`（`lib/main.dart:526-585`）之外**，在 `_toolDefs`/`base` 里由独立的“浏览器可用性探测”（如 sidecar 提供 `browser_available()`，返回 Playwright + 可用 Edge/Chromium 是否就绪）决定是否加入——这样当 `hasProviders==false` 时（仅**非空** search 配置触发 `search_provider.cpp:140-141` 对 SearXNG `set_available(false)`、且无 zhipu/kimi key → provider 空；**空 `{}` 配置**下 SearXNG 保持可用 → `hasProviders==true`，见 design:9），**浏览器工具仍会声明**（只要浏览器运行时就绪）。参照：`web_search`/`web_fetch` 的声明都在 `if (hasProviders)` 内、受 provider 可用性门控（`lib/main.dart:526,536,570`）；`web_fetch` 缺 Python 时降级到 curl（`web_fetch.cpp:96,670-672`）。**若误把浏览器工具放进 `if (hasProviders)`，它会因 provider 原因被静默隐藏（隐藏降级）——这违背其“独立/浏览器运行时门控”的声明，故必须放在该块之外。**

## Risks / Trade-offs

- **[多轮 tool_use 循环深度] → 前置验证。** 浏览器是多步。**核实 sidecar 的 tool_use 循环**（`lib/main.dart:922` `while(true)`、50-turn cap `:1347`，等）已支持足够深的多步；若不够，**新增前置任务实现之**（不降低多步为单步）。实现前列验证。
- **[headed 资源成本] → 单会话 + 进程组清理 + 实测。** 300-500MB/tab、2-5s 冷启动、孤儿浏览器进程；单会话避免重复冷启动，`process-group/JobObject` kill 兜底。
- **[窗口最小化/遮挡下的行为（外部、未验证）] → 实测（task 1.2）。** Edge 最小化 → AI 连续 navigate/click/snapshot → 记录①是否被拉回前台、②命令是否仍成功执行、③快照是否仍新/准；据结果决定是否加 `--disable-backgrounding-occluded-windows`，并把两类分支都回填 spec。
- **[`channel` 是否真免 ~150MB Chromium 下载（外部、未验证）] → spike。** 实测 Playwright 能否不经 `playwright install` 直接驱动系统 Edge；确认前不作为收益事实。
- **[单 tab / 弹窗 / 下载 / 权限抑制是否真能成立（外部、未验证 + 需机制）] → 实测（task 1.4）。** 单靠“复用 tab”不足以压制 `window.open`/`target=_blank` 或下载/权限弹窗；需显式 popup/新页关闭 handler + deny-downloads/permission-denial 配置，且需驱动一个会触发它们的页面实测记录，结论回填 spec/tasks 2.4。
- **[反爬/ToS] → 用户可见 + 只读尊重。** 程序化访问部分站点会拦；本工具不替代付费搜索，用户可人工协助；不承诺绕过反爬。
- **[Python/Playwright 依赖] → 优雅降级。** 缺失时工具不声明或返回可读错误，不静默占位。
- **[文本快照 token 成本] → 快照限长/分块。** 避免撑爆上下文（项目已有上下文压缩体系）。

## Migration Plan

纯增量新工具，无 BREAKING。接入：新增 Playwright worker + sidecar 工具注册 → Flutter `_toolDefs` 声明 → 测试。回滚：移除工具声明即可，不影响既有 `web_fetch`/`web_search`。

## Open Questions

1. **`channel="msedge"/"chrome"` 是否能不经 `playwright install` 免下载驱动系统 Edge**（外部、需 spike；若只能捆 Chromium，则资源成本上升）。
2. **多轮 tool_use 循环深度**（是否需为多步浏览器补深；前置验证）。
3. **OCR**：纯图页面处理**本 change 不做**；若后续要做，需先选型（Tesseract vs PaddleOCR）。
4. 快照取“结构化 JSON（accessibility）”还是“纯 `innerText`”——前者利于 AI 定位，但 DeepSeek 可用性需实测。
5. **“显式可见请求”信号**：本 change 浏览器状态 UI 在范围外，若后续真的要让用户“主动把浏览器调到前台”，需另定义信号（如聊天里说“显示浏览器”→ agent 调某命令）；本 change 不承诺。
6. **单 tab / 弹窗 / 下载 / 权限抑制机制**：是否/如何用显式 popup 关闭 handler + deny-downloads/permission-denial 配置实现（task 1.4 实测后定）。
