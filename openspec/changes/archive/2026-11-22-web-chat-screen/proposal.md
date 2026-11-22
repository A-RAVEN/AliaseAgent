## Why

`web-ui-core-shim` 立起了 web 化基石（无头核心 + WS/JSON-RPC + 最小验证页），但最小页**几乎不可日常使用**：用户实测「很多 agent 回复直接不显示」——根因是工具轮的空正文助手消息被渲染成大量空气泡，把真回复淹没（已记 `Docs/known-bugs.md`「web 验证页」条，实测某会话 62 条助手消息 56 条空正文）。同时反馈台账 F-002（工具/思考卡片默认折叠且折叠态单行）、F-003（贴底自动跟随）、F-004（跳底按钮）经用户 2026-11-16 拍板**并入新 web 界面**；WS 断开无自动重连（用户 2026-11-21 拍板并入本 change）。本 change 把最小验证页扩成**完整聊天屏**，让 web 界面真正能日常用。

## What Changes

- **修复空气泡渲染缺陷**：空正文工具轮助手消息不再渲染成独立空气泡，**每个 toolCall 渲染一张单行折叠卡**（多工具消息=多张卡，不是一卡只露一个工具）；助手消息的 `toolCalls`/`thinking` 内联渲染成卡片；**live 与 history 经归一/合并/去重后一致**（live 工具事件按 id 合并进消息、name→toolName 归一；最终消息聚合的整轮 toolCalls 去重，避免工具卡渲染两遍）。
- **F-002 卡片折叠**：工具调用与思考卡片**默认折叠**，折叠态严格**单行**高度（单行截断，展开才看全文）。
- **F-003 贴底跟随**：消息列表处于底部时新内容到达自动滚到底；用户上翻阅读历史时不打扰。
- **F-004 跳底按钮**：非贴底时显示悬浮"回到底部"按钮（圆形 chevron-down，参照 DSH），点击滚到底并恢复贴底跟随。
- **会话列表虚拟滚动**：数百~数千会话不卡（只渲染可视区）。
- **消息分页落地（含必要的接口 additive 扩展）**：屏上真正用起游标分页——**首屏锚定最新页**，上翻加载更早页。对抗审查核实：现 `message.query` 只有 afterSeq 升序前向游标，首屏不传游标拿到的是**最旧页**，无尾锚/反向能力，聊天屏"打开即最新"做不到。故本 change **additive 扩展 message.query**（尾锚 anchor=tail + 反向游标 beforeSeq + prevCursor，保留前向兼容），并给 web-core-shim 分页 requirement 补 MODIFIED delta。这是唯一触及核心处，增量查询能力、不改 agent 行为。
- **WS 自动重连 + 心跳保活**：断开指数退避自动重连，心跳（周期 core.ping + 超时判死）探测；重连后**重拉当前页消息恢复状态 + 依赖核心广播到当前订阅者**（核心无 ensure RPC，事件经 _broadcast 天然到达新连接）。重连/心跳四参数（退避 base/cap、心跳周期、心跳超时）落可配 tokens + 文档键表（base=1s 参照产品先例，其余助手定的默认可配）。
- **设计系统落地**：按 design-system 方法论先定方向/调色板/字阶/间距/组件约束再写组件，渲染审计（design_audit）验收。
- 用户文档同步 + 分层测试（web 客户端测试 + 渲染审计 + live 视觉验收）。

## Capabilities

### New Capabilities
- `web-chat-screen`: 完整 web 聊天屏的 UI 契约——消息/工具轮/思考的渲染与折叠、贴底跟随与跳底按钮、会话列表虚拟滚动、消息分页加载、WS 自动重连与心跳、设计系统约束与渲染审计。

### Modified Capabilities
- `web-core-shim`: 两条演进——① 「本机静态服务与最小 web 验证页」RENAMED+MODIFIED 为「本机静态服务与 web 客户端」（UI 契约移交 web-chat-screen，静态服务/React+TS/Markdown 保留）；② 「会话与消息查询支持分页」MODIFIED（additive：尾锚 anchor=tail + 反向游标 beforeSeq + prevCursor，保留前向兼容；归档同步时主 spec Purpose 一并改写为 web 客户端口径）。

## Impact

- **主要改动**：`web/src/`（App.tsx 重构 + 新增组件：消息列表/工具卡/思考卡/会话虚拟列表/跳底按钮；protocol.ts 加重连+心跳；新增设计 tokens）。
- **复用不动**：无头核心、RPC 通道、事件序列化、agent 业务逻辑。**唯一 additive 扩展**：message.query 查询接口（尾锚+反向游标，见上），不改 agent 行为、保留前向兼容。
- **不做**：restore/_history 内存边界（规模优化 change）、核心 Dart→TS 迁移（独立 change）、原生壳（Tauri 后置）、F-001 粘贴网址缺陷（Flutter 输入框问题，另立项）。
- **测试**：纯逻辑（renderMessages 归一/去重、protocol 重连状态机）vitest 单测；**布局/滚动断言（折叠单行高度、贴底、跳底）走 puppeteer 真实渲染**（jsdom 无布局引擎测不了高度/滚动）；心跳超时用假 WS 对端；design_audit 初态渲染审计；live 真实模型 + 无头浏览器截图视觉验收。
- **依赖**：虚拟滚动库（@tanstack/react-virtual 候选，本地无据待装包核）、lucide-react 图标、vitest（纯逻辑测试）；puppeteer-core 已在盘。引入须有理由。

## 关键决策（P1~P7，供审查与用户拍板，可否决；与 design D1~D13 对应，编号独立避免混淆）

- **P1 视觉方向**（design D1~D6）：延续收敛暗色 slate 方向，先定 tokens（调色板/字阶/间距/组件）再写组件。
- **P2 折叠语义**（design D7）：工具/思考卡默认折叠、折叠态严格单行、展开看全文；空正文工具轮每 toolCall 一张单行卡，不产生空气泡；live/history 归一/合并/去重一致。
- **P3 贴底/跳底**（design D9）：bottomThreshold=24px（间距 scale 步长=正文行高，可配+审计）；贴底跟随、上翻不打扰；跳底按钮右对齐参照 DSH，未读标记首版不做（deliberate 简化待拍板）。
- **P4 重连/心跳**（design D12）：指数退避 + 心跳超时判死；四参数（base=1s/cap=30s/周期=15s/超时=5s）落可配 tokens + 文档键表；重连重拉当前页+广播恢复（无 ensure RPC）。
- **P5 虚拟滚动**（design D11）：会话/消息列表虚拟化；库选型待装包核。
- **P6 范围**：只做聊天屏 UI + message.query additive 扩展；规模优化/核心迁 TS/原生壳/F-001 后续或另立项。
- **P7 分页接口扩展**（design D10）：message.query additive 增尾锚+反向游标+prevCursor，补 web-core-shim 分页 MODIFIED delta。这是聊天屏「打开即最新+上翻加载更早」的正常实现所需，增量查询能力、不碰 agent 逻辑。

> 授权事实出处：F-002~004 并入新 web 界面、空气泡修复+自动重连并入本 change，见 `TODO.md`「GUI web 化」节（2026-11-16 / 2026-11-21 用户拍板）与 `Docs/RoadMap.md`；`Docs/feedback.md` 三条状态字段尚标"待用户拍板"，tasks 7.x 同步标注拍板出处。