# Add Browser Tool — Tasks

## 1. 前置验证（连续 checklist，非 STOP 门禁；结果回填 spec，供 2.4/5.3 等后续任务依赖）

- [ ] 1.1 核实 sidecar 的 `tool_use` → 工具执行循环已支持足够深的多步（参照 `lib/main.dart` 的 `while(true)` 工具循环与 50-turn cap、`_executeTool` 派发）。若某前提不满足，按「tasks 序号=执行顺序」新增**前置任务**实现之，不降级为单步；把结论记入 spec 的独立浏览器要求。
- [ ] 1.2 实测 headed 驱动系统 Edge：每 tab 资源（RAM / 冷启动）；**窗口最小化后 AI 连续 navigate/click/snapshot 是否仍成功执行且快照仍正确/新**（不只是「是否被拉回前台」）；据结果记录是否需加 `--disable-backgrounding-occluded-windows`，**两类分支结论都回填 spec 对应 Requirement**。
- [ ] 1.3 spike：确认 `channel="msedge"`/`"chrome"` 能否不经 `playwright install` 直接驱动系统 Edge（免 ~150MB Chromium 下载）；若只能捆绑 Chromium，须重估资源成本。
- [ ] 1.4 实测 tab/弹窗/下载/权限抑制：驱动一个会 `window.open`/`target=_blank` + 触发下载/权限弹窗的页面，记录所选 launch args + 显式 popup/新页关闭 handler + deny-downloads/permission-denial 配置是否能保持**单 tab / 无新窗 / 无弹窗 / 无下载 / 无权限授予**；结论回填 spec 的 stay-hidden 要求与 tasks 2.4 机制。

## 2. Playwright 浏览器 worker（Python）

- [ ] 2.1 新建 Python worker（镜像 `scripts/fetch_worker.py` 的 stdin/stdout JSON 协议），Playwright `channel="msedge"`（回退 `chrome`）、`headless=False` 启动。
- [ ] 2.2 实现**持久会话**（一次任务一个 daemon；`open` = 会话启动；`relaunch` = **AI 显式重开**，看门狗只检测/返回失败不自动重启，见 spec 健壮性），命令集 `browser_navigate` / `browser_click` / `browser_type` / `browser_snapshot`（worker stdin 协议用裸 `{"cmd":"navigate"/"click"/"type"/"snapshot"}`）。
- [ ] 2.3 `browser_snapshot` 返回**文本快照**（DOM `innerText` / 可读性提取），带长度上限/简要分块以控 token；worker 对每个 browser 工具的**每步调用**返回一个**可观测记录**（toolName / 完整 input / result / status / 快照长度 + **工具自己 emit 的 bringToFront 次数**、**popup/新页关闭次数**、**download-denied**、**permission-denied**、**当前 tab 数**），供测试归因（这些是工具自身动作/计数，非 OS 窗口态）。
- [ ] 2.4 **藏后台行为**：不 `bringToFront`（并记录上述“工具 emit 次数”，独立于 OS/browser focus 事件）、单 tab 复用（含显式 popup/新页关闭 handler）、自动处理 `dialog`、deny 下载/权限弹窗；仅通过「显式可见请求」机制才提升前台——**该机制未在 design 定义**（见 design Open Question 5；需另行立项），本 change 只承诺工具自身不因逐动作 raise。
- [ ] 2.5 **健壮性**：看门狗检测浏览器关闭、每步重读实时快照、URL/内容分叉检测、用户接管信号。

## 3. Sidecar 集成

- [ ] 3.1 sidecar 新增浏览器工具注册 + `tool_use` 派发；复用 subprocess 代理 / SSRF 防护 / 超时 / stderr→sidecar.log；提供 `browser_navigate -> {"cmd":"navigate"}` 等一一映射。
- [ ] 3.2 sidecar 提供 `browser_available()` 探测（返回 Playwright + 可用 Edge/Chromium 是否就绪），供 Flutter 端决定是否声明浏览器工具。
- [ ] 3.3 优雅降级：Playwright/Edge 不可用时，该工具**不声明**或返回可读错误，**绝不静默占位**。（注：`web_fetch`/`web_search` 都在 `if (hasProviders)` 内声明（`lib/main.dart:526-585`，受 provider 可用性门控）；`web_fetch` 缺 Python 时**降级到 curl fallback**（`web_fetch.cpp:96,670-672`）而非不声明——与本 change 的“浏览器运行时不可用则不声明/可读错误”不同，且浏览器工具应在 `if (hasProviders)` **之外**声明。）

## 4. Flutter 声明

- [ ] 4.1 `lib/main.dart` 在 `_toolDefs`/`toolsJson` 声明浏览器工具，**放在 `if (hasProviders)`（`lib/main.dart:526-585`）之外**，由 `browser_available()`（task 3.2）决定是否加入——确保 `hasProviders==false`（如仅 SearXNG 无 key）时浏览器工具**仍声明**（只要浏览器运行时就绪）。浏览器状态的 UI 展示（`ToolCallCard`/真实上下文视图）**不在本 change**，另行立项。
- [ ] 4.2 增加 gate 解耦测试：`hasProviders==false`（provider 空/仅 SearXNG 无 key）+ 浏览器就绪 → 浏览器工具**仍在** `_toolDefs`；Playwright/Edge 不可用 → 浏览器工具**缺席**，而 `web_search`/`web_fetch` 仍只受 provider 门控。断言前/失败路径前 `[OBS]` dump `_toolDefs` 是否含浏览器工具。

## 5. 测试（匹配层 + 可观测性）

- [ ] 5.1 worker 层测试：`browser_navigate`/`browser_click`/`browser_type`/`browser_snapshot` + 藏后台行为；**输出可观测**（每个 case 在断言前 `debugPrint` 实际发出的命令名 / 完整 input / 返回 result，或用 Fake worker 记录）；**每条失败路径**（worker 错误 / 超时 / 结果异常 / Fake worker 抛错）在 `fail`/`markTestSkipped` 或异常传播前 dump（或确认该轮命令/input/result 已完整落盘的 Fake worker 记录），[OBS] 现场打印，确保失败可归因。Fake worker 分支仅用于非 UI 管线，不用于最小化/分叉检测。
- [ ] 5.2 sidecar 工具测试：注册/派发、不可用时降级；**断言前与每条失败路径**（注册/派发失败、超时）在 `fail`/`markTestSkipped` 之前 `debugPrint` 实际工具调用（工具名 / 完整 input / result/status）或落盘记录，[OBS] 现场打印；**降级到“工具不存在”**（spec 优雅降级）时 dump 该“可读错误/未声明”状态而非工具调用（无工具调用）；因 config 缺失 / 无 provider 在**任何工具调用前**便 `markTestSkipped` 的可不 dump（TESTING.md §3.2：dump 仅用于已发生工具调用/文件活动之后的失败路径）。
- [ ] 5.3 live（gated on 1.1 + 1.2 + 1.3 + 1.4）：置于 `integration_test/` 且 `@Tags(['live'])` + `library;`；真实模型 + 真 Edge 多步。**断言前** dump 该轮实际浏览器工具调用（toolName、完整 input、result/status）与快照长度；**每条失败路径**（超时 / 错误状态 / 窗口关闭 / **无最终回复(silent-completion)**）在 `fail`/`markTestSkipped` 之前 dump，确保失败可归因；因 config 缺失 / 无 provider / 无 thinking_effort 在**任何工具调用前**便 `markTestSkipped` 的可不 dump（TESTING.md §3.2）；`[OBS]` 现场打印。接受项可观测（均来自 worker 写出的**机器可读记录**——每一 browser 工具调用写一条，如 sidecar.log `browser-record: {"tool":…, "raise_count":…, "popup_closed":…, "download_denied":…, "permission_denied":…, "tabs":…}`，live 测试从该通道读取并 `[OBS]` 打印；这批计数**不进模型可见的 snapshot 文本**，避免污染 context/见 spec 文本快照）：**浏览器以 headless=False 启动且 browser/page 对象活/连上**（不用户可见断言）+ **snapshot 可由程序读取且返回了非平凡文本** + **工具自身 emit 的 bringToFront == 0**（非 OS 外部 focus 事件）+ **popup/新页关闭计数、download/permission 均 denied、tab 数==1**（其中依赖 task 1.4 才成立的，仅记录、不作 fail，由 1.4 回填）。

## 6. 诚实性审查

- [ ] 6.1 对全套 artifacts + 实现跑 **Workflow 对抗验证**（N≥3 视角怀疑者、多数决 kill、离线、参照本地文档），核对：如实（独立工具、非 `web_search` 替代）、无新增矛盾、无隐瞒/降级/删除真 bug、无越界（未改 `web_search`/`web_fetch`/`chat-ui` 行为、未把未验证外部行为当无条件 SHALL）、测试可观测性满足。发现问题按执行顺序插入修复任务（不倒退已勾选），全部到 `[x]` 后输出诚实性审查报告（已审查轮数、每轮问题数、最终任务状态）。
