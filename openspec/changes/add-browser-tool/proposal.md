## Why

App 的 AI 目前获取网页信息的方式有限：`web_search` 走的是**API provider**（付费的智谱/Kimi，外加一个**自托管 SearXNG——免费无 key，但在存在非空 search 配置下被置为不可用**，见 design），`web_fetch` 是**单 URL 抓取**（Crawl4AI，headless、一锤子，不可交互）。两者都**无法让 agent 一步步交互式地浏览**（导航/点击/填表/看 JS 页），也没有**用户可见的浏览器**。而 DeepSeek 是**非多模态**（只收文本），页面信息必须**落地成文本**才能喂给模型。本 change 为用户提供一个**用户可见、agent 可自主驱动**的独立浏览器工具——它与 `web_search` **并列且独立**，agent 拿它能浏览、也能干别的。

## What Changes

- 新增 **sidecar 浏览器工具组**：命令集 `browser_navigate` / `browser_click` / `browser_type` / `browser_snapshot`——一个**独立工具**，非 `web_search` 替代。一次任务开一个**持久会话**（worker daemon 在会话启动时拉起；看门狗**只检测**关闭、**AI 显式重开**，不自动重启）。
- 底层为 **Python Playwright 子进程 worker**（镜像 `scripts/fetch_worker.py` 的 subprocess 模式），驱动**系统已装的 Edge/Chromium**（`channel="msedge"`/`"chrome"`）。**注意**：`channel` 免 ~150MB Chromium 下载**已由 spike（2026-09-06）确认**——`channel="msedge"` 驱动系统 Edge、未用 bundled chromium（残差：本机已装 chromium，全新机器未复现，但机制已证，见 design Risk）。
- **headed（用户可见）**；AI **程序级控制**——窗口最小化/被遮挡**预期**不影响操作（最小化行为由 task 1.2 实测确定；遮挡分支由 task 1.5 实测：覆盖窗不破坏 ops、无需 `--disable-backgrounding-occluded-windows`）。
- 每步返回 **DOM/内文文本快照** 喂 DeepSeek。**OCR 本次不做**（当前仓库无 OCR，属后续独立决定，design Open Question）。
- **默认藏后台**：不每步 `bringToFront`；**单 tab 复用**；**自动处理** `alert`/`confirm`；避免触发下载/权限弹窗——上述“单 tab / 不弹窗 / 无下载 / 无权限”**已由 task 1.4（单 tab/弹窗/下载）与 task 1.6（权限，HTTPS 实测：不授予——Notifs denied、Geoloc 未授予；无弹窗仅 Notifs 路径确认）实测保持**。把窗口提到前台仅通过**显式可见请求**，且该机制**不在本 change 范围**（design Open Question 5，另行立项）；本 change 只承诺工具自身不因逐动作 raise。
- **健壮性**：看门狗**检测关窗→可检测失败→AI 重开**；**每步重读实时快照**；URL/内容**分叉检测**；**用户接管信号**。
- 与 `web_search` **独立**；`web_search` 本次不改（其"付费 key 提供商 + 自托管 SearXNG（空配置下可用、非空配置下被置不可用）"的投喂/软失败另行立项）。
- 无 BREAKING。

## Capabilities

### New Capabilities
- `browser-tool`: 一个独立、用户可见、agent 可驱动的浏览器工具（Playwright 驱动系统 Edge/Chromium），可浏览/交互/看 JS 页，每步向非多模态模型返回文本快照，带隐藏窗口与健壮性语义。

### Modified Capabilities
<!-- 纯增量新工具。本 change 不改任何既有 capability 的 requirement；UI 展示（如 ToolCallCard 展示浏览器状态）不在本 change 内。 -->

## Impact

- `sidecar/`：新增浏览器子进程 worker（Python + Playwright）+ 工具注册 + `tool_use` 派发；复用 `web_fetch` 的 subprocess/超时/stderr→sidecar.log（SSRF 防护不作为逐交互步复用，见 design），但从"单 URL 抓取"扩展为"交互式 headed 会话"。
- Python 依赖：新增 `playwright`（`crawl4ai` 已在）；`channel` 免下载 Chromium **已由 spike（2026-09-06）确认**（驱动系统 Edge、未用捆绑；全新机器未复现但机制已证）。
- Flutter（`lib/main.dart`）：在 `toolsJson`/`_toolDefs` **声明浏览器工具**。浏览器状态的 UI 展示（`ToolCallCard`/真实上下文视图）**不在本 change**，另行立项。
- 依赖/文档：`scripts/requirements.txt`、`DEBUGGING.md`、`Docs/TESTING.md` 相应更新。
- **前置验证项（已执行回填，非门禁）**：多轮 tool_use 循环深度**已由 task 1.1 确认**（支持深多步）；headed 资源成本、最小化（task 1.2）、channel（task 1.3）、单 tab/弹窗/下载（task 1.4）**已实测回填**（task 1.4 权限抑制未验证）；**遮挡（task 1.5）与权限抑制（task 1.6）已实测回填**（遮挡：覆盖窗不破坏 ops、无需 flag；权限：不授予、无弹窗仅 Notifs 路径）。
