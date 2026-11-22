## 1. 设计 tokens + message.query additive 扩展（核心）

- [x] 1.1 建集中设计 tokens（`web/src/tokens.ts`）：方向/调色板（中性 ramp+sky accent+语义色）/字阶（12/14/16 沿用既有档、20/25 按 1.25 延伸）/间距 scale/圆角/elevation/图标集（design D2~D6）。重连四参数（退避 base=1s 参照 kimi_search 先例、cap=30s、心跳周期=15s、心跳超时=5s）+ bottomThreshold=24px 落可配常量 + 用户文档键表（配置项出处分支：默认值+范围+键表）。组件后续禁裸 hex/任意间距。
- [x] 1.2 **message.query additive 扩展**（design D10，审查逼出的必要修正）：`lib/services/message_page.dart` 增尾锚模式（anchor=tail 缺省，不传游标取最新一页：seq DESC limit 再反转）+ 反向游标 beforeSeq（seq < ? DESC limit 再反转）+ 返回 prevCursor（本页首条 seq）；保留 afterSeq/nextCursor 前向兼容。`lib/core/headless_core.dart _handleMessageQuery` 增 before/anchor 参数。**不改 MessageRepository 既有接口签名**（扩展方法）。
- [x] 1.3 核心扩展测试（`test/integration/web_core_rpc_test.dart` 增用例，假 sidecar+openAt 隔离）：尾锚取最新页（非最旧）、反向游标加载更早不重叠、前向兼容保留、缺 pageSize 仍 -32602。先红后绿贴现场。

## 2. web 测试基建（审查 TC-1/TC-6/EXT-06：布局走 puppeteer，逻辑走 vitest，心跳需假对端）

- [x] 2.1 搭测试基建并**钉死通道**：纯逻辑（renderMessages 归一/去重、protocol 重连状态机）用 vitest 单测；**布局/滚动断言（折叠单行高度、贴底跟随、上翻不打扰、跳底）用 puppeteer 真实渲染**（复用 web/e2e/smoke.mjs 的 headless Edge 先例；jsdom 无布局引擎 getBoundingClientRect 恒 0，测不了高度/滚动，不用它做布局断言）。**心跳超时用例搭假 WS 对端**（ws@8.23.0 已在盘：接受连接但不回 ping）。先写一个能红的骨架证明基建可用（红→绿）。

## 3. 渲染重构 + 折叠（修空气泡 + F-002 + live/history 一致 + 流式语义）

- [x] 3.1 抽 `renderMessages` 纯函数 + **归一/合并/去重层**（design D7）：live tool.call/tool.result 按 id 合并进消息 toolCalls（name→toolName 归一、补 status/result）；thinking 按 index 归一；最终消息聚合 toolCalls 去重（最终消息只渲染正文）。空正文工具轮**每 toolCall 一张单行折叠卡**（多工具=多卡）。vitest 逻辑测试先红后绿：空气泡用例（空正文工具轮→无空气泡、每工具一卡）、多工具可见用例、去重用例（工具卡不渲染两遍）、live/history 同形状用例。
- [x] 3.2 工具卡/思考卡默认折叠、折叠态严格单行（truncate+固定行高 24px），展开看全文。**puppeteer 真实渲染测单行高度**（折叠态 offsetHeight≈单行）+ 展开全文。先红后绿。
- [x] 3.3 **流式语义**（design D8）：每条 assistant.message（含中间轮）落定当轮流式文本、清缓冲；整轮流式态以 agent.streaming 为准（不用 turn.completed）。vitest/puppeteer 测试：中间轮落定不串轮、工具执行期间 streaming 仍 true。先红后绿。

## 4. 滚动跟随 + 跳底按钮（F-003 / F-004，puppeteer 交互测试）

- [x] 4.1 贴底跟随（bottomThreshold token 判定）：贴底新内容自动滚到底、上翻不打扰。**puppeteer 交互测试**（真实滚动）：贴底跟随、上翻不打扰两用例。先红后绿。
- [x] 4.2 悬浮跳底按钮（圆形 chevron-down，lucide，输入框上方**右对齐**参照 DSH；未读标记首版不做 deliberate 简化）：非贴底显示、点击滚到底恢复跟随、贴底隐藏。puppeteer 三态测试。先红后绿。

## 5. 虚拟滚动 + 消息分页落地

- [x] 5.1 会话列表虚拟滚动（库选型按 design Open Question，装包后核 README/体积/动态高度 API）：数百条只渲染可视区。测试：大列表 DOM 节点数受控。先红后绿。
- [x] 5.2 消息分页落地（用 1.2 扩展）：首屏 anchor=tail 取最新一页、上翻用 prevCursor 加载更早保持滚动位置。puppeteer 测试：首屏即最新（非最旧）、上翻加载更早位置不跳、虚拟列表动态高度与贴底/上翻无冲突。先红后绿。

## 6. WS 自动重连 + 心跳

- [x] 6.1 `RpcClient` 指数退避自动重连 + 心跳（周期 core.ping + **超时判死**触发重连，四参数取 1.1 tokens）；重连成功**重拉当前页恢复状态 + 依赖广播到当前订阅者**（无 ensure RPC）；重连中明确态。测试：断开自动重连（vitest 状态机）、**心跳超时触发重连（假 WS 对端不回 ping）**、重连恢复状态。先红后绿。

## 7. 用户文档 + 守卫同步（审查 TC-2/TC-3/RS-06/RS-07）

- [x] 7.1 更新 `Docs/user-guide/web-core-shim.md`（增完整聊天屏节：折叠/贴底/跳底/虚拟滚动/分页/重连怎么用、重连四参数与 bottomThreshold 取值表）或新建 `web-chat-screen.md`；README 索引同步。已知限制更新（空气泡已修、未读标记首版不做、F-001 仍另立项）。**同步 feedback.md F-002~004 状态字段标注拍板出处（TODO.md 2026-11-16/11-21）**。
- [x] 7.2 **同步旧文档守卫锚点**（审查 TC-2）：`test/unit/web_core_docs_test.dart` 的 '最小验证页' 锚点随文档更新而失效——显式改锚点集（改成完整屏口径），不改断言语义只改锚点；贴改前红证据。
- [x] 7.3 新文档守卫（`test/unit`）：**参照 parallel_tools_docs_test 解析常量强先例**（审查 TC-3，非仅 contains 子串）——数字参数（bottomThreshold/重连四参数）取值与文档绑定、限定小节，改文案不改文档就红、改数字不被间距 scale 无关数字满足。先红后绿。

## 8. 审计 + 全量验证 + 变异 + validate（主循环批次）

- [x] 8.1 对渲染页跑 `design_audit`（bin/alias_agent_core.dart 无窗口 serve + URL，自动加载首会话）：逐条修初态违规（文本尺寸/颜色数/对比度/间距 grid/控件尺寸），deliberate 例外（12px 元信息、未读标记不做）显式说明。**design_audit 不测折叠单行高度/展开态/非贴底态——那些由 3.2/4.x puppeteer 测试兜底**。贴审计输出。

**实测**（http://127.0.0.1:60718，147 元素）：字号 4 档（12/14/16/20，25 声明未用）、非中性色受控（6 种含中性）、对比度全 ≥AA（无违规）、控件尺寸达标（跳底 32×32、发送 36 高、会话行 36 高、输入框 48 高）。**1 条 low：line-length**（10 个文本块 >75 字符，最长 127，元素 span.min-w-0.flex-1 = ToolCard/ThinkingCard 折叠态单行摘要）。**deliberate 例外声明**：① 12px 仅元信息标签；② 未读标记首版不做；③ line-length 违规即 F-002 折叠卡单行截断的长工具输入摘要——视觉上是单行 truncate（F-002 硬要求），DOM 文本长导致审计按字符数点名，与 F-002 单行要求冲突，**声明为 deliberate 例外不修**（修短则破坏 F-002 单行折叠）。

- [x] 8.2 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线本轮实测留档、改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`；`npm --prefix web run build` + web 测试（vitest + puppeteer）全绿。

**实测**：DLL already current；analyze 161=基线、改动 Dart 文件零新增；全量 `+893 ~1 All tests passed! exit 0`（首跑撞 user_docs_test 守卫红，8.7 修后复跑全绿）；web build 绿（405.9KB js）；`npm --prefix web run test:all` vitest 41 passed（6 文件）+ puppeteer 7/7。

- [x] 8.3 两个变异（各贴红证据后恢复、复跑全绿、改动文件哈希逐位相同）：① 工具卡默认折叠改默认展开 → 3.2 puppeteer 单行高度用例必须红；② 删 RpcClient 自动重连 → 6.1 断开重连用例必须红。

**实测**：① ToolCard.tsx `useState(false)→true` → puppeteer「折叠卡」用例 FAIL「第 1 张工具卡默认必须折叠」（collapsed:false/height:181）；恢复后该用例绿。② protocol.ts onclose 删 `scheduleReconnect()`（留方法）→ vitest protocol 3 条红（「服务端断开后自动重连」等超时 4045ms）；恢复后哈希逐位 = 57F9F8E0…EE454，5 条全绿。**ToolCard 哈希如实披露**：恢复后内容逐字相同（useState(false)）+ 全套 web 测试绿，但 edit 工具把原文件的混合行尾规范化成纯 LF，致哈希 CC1809CA ≠ 变异前 440A31A2——原文件未跟踪、无 git 基线，子 agent 留下的精确行尾混合不可考，无法逐位复原；差异**仅行尾、内容无残留变异**（测试全绿证明）。

- [x] 8.4 `integration_test` live（--tags live，真实模型，无头浏览器镜像入口）：完整屏发一条触发工具的消息→断言折叠卡/真回复/贴底/跳底。**移除/条件化 smoke.mjs 的手动滚底步**（审查 TC-5，避免人造状态掏空贴底断言）+ report 增滚动度量；页面内截图 `read_image` 视觉验收。贴 live 输出与截图路径。

**实测**：smoke.mjs 移除手动滚底步、改测自然贴底度量（report.scroll.distanceFromBottom + jumpButtonVisible）；live_support 加断言「距底 ≤ 24px token + 贴底时跳底按钮隐藏」（强化验收）。`flutter test --tags live --run-skipped test/live/web_core_shim_live_test.dart` → `+1 All tests passed! exit 0`。现场：自然贴底 distanceFromBottom=0（scrollTop 0/scrollHeight 711/clientHeight 711，**无手动滚底**）、jumpButtonVisible=false、tool.call read_file executing→tool.result done、回复含 ALIASAGENT_WEB_LIVE_OK、快照「上下文窗口 1048576 tokens」。截图 test/live_visual/web_core_shim_live.png（52473 B/1280×900）已 read_image 判收：工具轮折叠单行卡、思考卡单行、真回复露出含代码块、**无空气泡**、贴底、快照行/输入框/发送齐全，暗色 slate+sky 信号色层次清晰，无 overflow/黑帧。

- [x] 8.6 用户可见收尾（子 agent flagged 缺口补任务）：`web/index.html` 的 `<title>` 从「AliasAgent · web 验证页」改为完整聊天屏口径（如「AliasAgent · web 聊天」），与 web-core-shim MODIFIED「不再限定最小验证页」一致；`Docs/known-bugs.md`「web 验证页」条标注已修（出处本 change）。改完重建 web/dist。

**实测**：title 改「AliasAgent · web 聊天」；known-bugs「web 验证页」条加「2026-11-22 已修」注（出处 web-chat-screen）；web/dist 重建。

- [x] 8.7 同步 `test/unit/user_docs_test.dart` 的 `_otherCodeNames` 允许清单（7.1 文档新增 RPC 参数名触发守卫红）：把 `anchor/tail/head/cursor/before` 映射到 `lib/core/headless_core.dart`（这些名字在该文件真实存在，守卫逐条核对）。只增允许条目+正确源指针，断言「文档代码名必须在代码里存在」不变（§7 扩覆盖不放松）。贴改前红（[anchor,tail,head,cursor,before] 找不到）→改后绿。

**实测**：改前红 `这些名字在文档里当成代码名写，但代码里找不到：[anchor, tail, head, cursor, before]`；加 5 条映射（均核实在 headless_core.dart：params['anchor'/'before'/'cursor']、anchor 取值 'tail'/'head'）后 `+5 All tests passed!`。

- [x] 8.5 `openspec validate web-chat-screen` 通过贴输出。归档时主 spec web-core-shim Purpose 同步改写为 web 客户端口径（审查 RS-07）。

**实测**：`Change 'web-chat-screen' is valid`