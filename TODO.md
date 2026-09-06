# TODO

> **这是本项目的唯一待办文档。** 所有待办事项统一记录在本文件（项目根目录 `TODO.md`）。
> 位置已在 `CLAUDE.md` 中登记，请勿在其它路径另建 TODO / TODOList / 待办 等文档；
> 新增、更新、勾选待办一律改这一份。与 `docs/known-bugs.md`（已确认的缺陷）区分：
> 本文件装“尚未开始 / 已立项待做”的事项。

## 状态标记
- `[ ]` 待办（未开始）
- `[~]` 进行中
- `[x]` 已完成

---

### [ ] 上下文压缩：L1 摘要泄漏 `ASSISTANT` 角色标签 + 重复对话下 L1 摘要冗余

**性质**：真缺陷（角色标签泄漏）＋ 设计商榷（冗余收拢）。

**背景 / 证据**：live 测试 `compact_quality_live_test` 的输出
`live_real_context_output.txt`（摘要 dump）里，第 2 条 L1 摘要正文以 `ASSISTANT用户在多轮开发中…` 开头
（第 1 条却是正常开头的 `对话摘要：…`）。这条污染的摘要会**原样进入真正发给 AI 的上下文**。

**根因（已核实代码）**：
- `lib/services/compaction/model_summary_provider.dart:176-183` 的 `_messageText` 把对话转写成
  `${m.role.toUpperCase()}: ${m.content}`（即 `USER: …` / `ASSISTANT: …`）。
- 摘要模型总结某段时，把转录里的 `ASSISTANT:` 标签**原样复制进了它自己写的摘要**。
- 代码对 `summarize` / `summarizeText` 返回的文本**没有“剥离前导 USER/ASSISTANT/SYSTEM 角色标签”的兜底**
  （已有：空摘要兜底 `R1-5`、失败兜底——唯独缺“正文误带角色标签”的清洗）。
- 该 L1 摘要落盘为 `ClosedSummary`（progressive closure）后会被**复用缓存**再吐出，
  脏标签会跟着持续出现。

**次要（设计商榷）**：
- `lib/services/compaction/compaction_plan.dart` 对高度重复对话按“原始 token 累加 > T”切成多个 L1 批，
  每批独立成摘要 → 多条内容重叠的 L1 摘要（本 case 为 2 条：`[1,133]` 628 tokens / `[134,270]` 548 tokens）。
- L2“摘要之摘要”（`l2GroupCount`，超预算才收拢）本次未触发，因为 L1 投影已放得下，
  于是两条重叠摘要都被放进上下文。
- 商榷点：对“重复对话”是否应让 L2 更早收拢以压低上下文里的重复？属调优/取舍，需评估。

**期望方向（供后续 change 参考）**：
1. 给摘要结果加“剥离前导角色标签”的清洗（USER/ASSISTANT/SYSTEM 前缀），入口在
   `model_summary_provider.dart` 的返回值处或投影构建处。
2. 评估：高度重复对话下，是否让 L2 收拢更早触发，减少上下文冗余。

**来源文件**：`lib/services/compaction/model_summary_provider.dart`、
`lib/services/compaction/compaction_plan.dart`、`live_real_context_output.txt`。

---

### [ ] 删除 SearXNG + `web_search` 改为「仅付费有效 + 失败返回空结果」

**性质**：清理死代码 + 优雅降级（非新功能）。两件是一体：删除的前提是“搜索失效变优雅”。

**背景 / 证据（已核实代码）**：
- `sidecar/src/search_provider.cpp:137-142`：`ensure_search_infra` **跳过 SearXNG 健康检查**，直接 `set_available(false)`（注释“assume unavailable”）；`searxng_search.cpp:36-40` 的 `is_configured()` 据此返回 false。故 `get_configured_providers()` **从不返回 SearXNG**。
- 结论：当前运行时搜索**本来就是“付费-only”**（还剩 zhipu / kimi，均需 API key）。删除 SearXNG ≈ **清死代码，功能零损失**。
- 现状 `dispatch_web_search` 在无可用 provider 时返回 `error_json("No search providers configured")`（`search_provider.cpp:265-266`）——即“搜不了会报错”。

**期望方向**：
1. 删除 SearXNG provider（`sidecar/src/searxng_search.cpp/.h`、`scripts/setup_searxng.sh|.bat`、`scripts/start_searxng.bat`、`tools/searxng/`）——纯清理，不依赖、不误伤。
2. `web_search` 改为“仅付费生效 + 软失败”：无可用 provider / 全部失败 / 结果为空 → 返回 `{ok:true, results:[]}`（空结果），而非报错，让 AI 看到“0 条”自然知道搜不了。入口在 `dispatch_web_search`。

**说明**：本项与“免费搜索 / 浏览器”无关；且删除 SearXNG 后**并不会自动出现免费搜索**——免费搜索的另议（见下条）。

**来源文件**：`sidecar/src/search_provider.cpp`、`sidecar/src/searxng_search.cpp/.h`、`scripts/setup_searxng.*`、`scripts/start_searxng.bat`。

---

### [ ] 添加「独立浏览器工具」，已定路线甲（外置窗口）——仍未实现，需先 spike

**决策**：选 **外置浏览器窗口**（路线甲），非内嵌。内嵌（WebView2）是**另一条独立替代路线**，暂缓，不是“增强”。

**性质**：新功能。**定位精确**：一个**独立于 `web_search` 的 sidecar 工具**，agent 可自由用于“搜索 / 导航 / 填表 / 看 JS 页 / 别的事”；**不是**把浏览器塞进 `web_search` 当免费搜索替代（此前 C1/C3 反证的是那个错误表述，不构成否决）。仍未实现，尚处 PARTIAL / 需 spike。

**机制（方向已定）**：
- **接入层**：**sidecar 工具**，镜像 `web_fetch` 的 Python 子进程模式；**不是 harness 级 MCP**——DeepSeek 端点不支持 MCP/server 工具（`Docs/DeepSeekAPIDoc.md:100,697`）。
- **驱动**：**Playwright 驱动系统自带 Edge/Chromium**（`channel="msedge"`/`chrome`，**免 ~150MB Chromium 下载**），**headed（用户可见）**，一次任务一个持久会话。
- **输出**：每步把页面落成 **DOM / 内文文本快照**，喂 DeepSeek；**OCR 仅在纯图页面才兜底**（当前仓库无 OCR，属新增，非复用现有通道）。
- 绝不与 `web_search` 混；`web_search` 独立保留（付费-only + 失败空结果，见上一条待办）。

**已确认的关键性质（这几轮问答定下）**：
- **AI 走程序级控制**（Playwright/CDP 命令直达浏览器进程，非屏幕级模拟），故**窗口最小化 / 被遮挡不影响 AI 操作**。
- **默认藏在后台、不频繁弹窗**：不每步调 `bringToFront`；**单 tab 复用**不开新窗口；**自动处理** `alert`/`confirm` 对话框；避免触发下载 / 权限弹窗；仅当用户明确要看时才把窗口提到前台一次。
- **健壮性（公共验收标准，须写进实现）**：关窗**自动恢复**（看门狗）；**每步重读实时快照**（不信任上次）；URL / 内容**分叉检测**；**用户接管信号**（检测到用户手动导航/切页 → 知会 AI 重读）。

**风险 / 门槛（未验证前勿拍板）**：
- **多轮 tool_use 循环是否已就位**（浏览器是多步）——**硬前提**，必须先验证。
- **headed 资源成本**：约 300-500MB/tab、2-5s 冷启动、孤儿进程风险（归档 `openspec/changes/archive/2026-07-27-upgrade-web-fetch-crawl4ai/design.md`）；需实测。
- **需 spike（外部事实，未验证）**：**最小化/隐藏窗口是否会被某些动作重新拉回前台**——建议实测：Edge 最小化 → AI 连续导航 → 看窗口是否自己弹。

**下一步**：先跑聚焦验证（多轮循环 + headed 资源 + 最小化是否弹）通过后，再开 change 立项。

**来源文件**：`sidecar/src/web_fetch.cpp`、`scripts/fetch_worker.py`、`Docs/DeepSeekAPIDoc.md`、`openspec/changes/archive/2026-07-27-upgrade-web-fetch-crawl4ai/design.md`。
