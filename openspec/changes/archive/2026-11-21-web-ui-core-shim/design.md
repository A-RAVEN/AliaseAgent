## Context

现状：Flutter `main.dart` 在 initState 里组装依赖图（ConfigService → DatabaseService → SidecarBridge(FFI) → 各 repository → AgentTypeRegistry/ProviderResolver → AgentFactory → AgentSessionController），`Agent` 通过 **`AgentCallbacks`**（`onChunk`/`onToolCall`/`onToolResult`/`onThinkingDelta`/`onThinkingBlock`/`onAssistantMessage`/`onUserMessage`/`onStreamingChanged`/`onTurnCompleted`/`onSnapshot`/`onCompactionStatusChanged`/`onTitleChanged`/`onMeteringChanged`）把事件推给界面。发送入口是 `Agent.send`，装配/恢复走 `AgentFactory.ensure`/`create`、`Agent.restore`/`ensureContext`。

**这就是无头化的天然缝**：RPC 层只需实现一份"把 `AgentCallbacks` 序列化成 WebSocket 通知"的回调，再暴露少量 RPC 方法（会话/消息/发送/取消），即可复用全部业务逻辑，不改 `Agent` 一行行为。

**必须先处理的事实（对抗审查后修正，范围比初稿大）**：
1. foundation 依赖不止 services 六文件——`lib/models` 还有五个文件 import foundation（agent_type_config / app_config / provider_config / model_catalog_entry / message，用途 debugPrint/@visibleForTesting），全在无头传递闭包内。解耦清单必须含这五个 models，否则纯 Dart 加载到不了绿。
2. **三段启动逻辑住在 Flutter UI 层而非 services**，无头组合根必须搬迁/抽取：① `main()` 顶部 `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`（不做则纯 Dart 下 openDatabase 失败）；② `_initSearchAndTools` 的工具目录播种（基础工具+load_skill 的 JSON schema、browser_available 探测、ensureSearchInfra/getSearchProviders 门控）——ToolCatalog 初始为空，不播种则 AgentFactory.resolveCandidate 对默认模板抛 UnknownToolsException，send 根本走不通；③ `_toolsReadyCompleter` 发送门禁与 AgentFactory.summaryStoreOpen 真实谓词（默认 _neverOpen 会静默禁用摘要存储）。这些是"复用全部业务"表述里被漏掉的真实工作量。
3. **debugPrint shim 必须保留可重赋值钩子**：至少 9 个既有测试通过 `debugPrint = (msg,{wrapWidth}){...}` 重赋值捕获日志做正/负向断言。shim 若换成不可重赋值的打印符号，这些测试会红（违反"既有测试原样全绿"）；为保绿改测试又违反禁改验收标准。故 shim 必须是一个与 foundation 同签名、可重赋值的全局函数变量。

约束：不重写 live 资产、不改既有测试断言、不发明上下限魔数、Flutter 界面保留并行、用户可见输出简体中文。

## Goals / Non-Goals

**Goals:**
- 无头 Dart 核心进程独立运行（`dart run`），复用现有 services + FFI sidecar。
- WebSocket + JSON-RPC 2.0 通道 + 本机静态服务，端口 OS 分配并回显 URL。
- 最小 web 聊天验证页（React+Vite+TS）：发一条消息 → 流式回复 → 工具卡片，端到端证明架构成立。
- 核心 services **与传递依赖的 models** 与 flutter/foundation 解耦（debugPrint/visibleForTesting），行为不变；debugPrint shim 保留可重赋值钩子。
- 无头组合根搬迁 UI 层三段启动逻辑（sqflite ffi 初始化 / 工具目录播种与条件注册 / 发送门禁与 summaryStoreOpen），使默认模板能创建并 send。
- RPC 消息查询面支持分页/懒加载（查询面不复制"全量载入历史"反模式）。

**Non-Goals:**
- 不删不改 Flutter UI（灰度共存）。
- 不做完整聊天屏、F-002~F-004、会话列表虚拟滚动（后续屏幕 change）。
- 不把核心迁 TS（终态目标，后续专门 change）。
- 不做原生壳（Tauri 后置）、不做多会话并发压测、不做鉴权（本机回环，见风险）。
- **不改造 Agent.restore/_history 的全量常驻**：本 change 的分页只落在 message.query RPC 读路径；发送/创建路径经 restore 仍全量载入历史并常驻（现状如此）。"核心进程内存只留活跃投影"是**后续规模 change 的目标，不是本 change 的承诺**——避免把规模问题说成已解决。
- 不修复存量缺陷（50 轮上限静默/摘要 xN 不替换/技能失败明细寄生 UI/L2 丢弃无日志），但 web 入口不得把它们进一步降级（见 D9/D11 与已知限制）。

## Decisions

> **授权口径（对抗审查 RS-01/M12 修正）**：下列 D1~D11 与 proposal「关键决策」一致，均为**助手推荐、供用户拍板，可否决**，不是已拍板事实。用户原话仅授权「路线 C + 取消 A + F-002~004 并入新 UI」；壳形态/前端栈/通信/无头 Dart/语言终态是助手推荐。文中「DSH 已验证」「生态最肥」「Cherry/Chatbox/Jan=Electron/Tauri」等是助手背景修辞，本地 Docs 无据、非用户逐条授权，引用时按"助手判断"对待。

- **D1 壳=纯浏览器起步（推荐，待拍板）**：核心起本机 HTTP+WS，浏览器开 localhost。理由：零新原生工具链、最快证明架构；界面是 web+WS，将来套 Tauri 不返工。备选 Tauri/Flutter 嵌 WebView/Electron 后置（对比见 explore 记录，proposal 不重复表）。
- **D2 前端=React+Vite+TS（推荐，待拍板）**：Markdown/流式/组件生态成熟、DSH 同族可参考；react-markdown 渲染、Tailwind 样式。独立 `web/` 子项目，引入 Node 构建链（本机已有 node）。备选 Vue/Svelte/原生。
- **D3 通信=WebSocket + JSON-RPC 2.0（推荐，待拍板）**：带 id 请求/响应 + 无 id notification（method 形如 `agent.event`）。**WebSocket 升级与 JSON-RPC 分发在本仓库无现成实现，属首次实证**（dart:io 公共 API，可行性由 2.2 先红后绿测试背书）；错误码用 JSON-RPC 2.0 规范值（-32700/-32600/-32601/-32602/-32603）。备选 HTTP+SSE 弃。
- **D4 核心=无头 Dart 进程（推荐，待拍板）**：新增组合根建图**且搬迁 Context 所列三段 UI 层启动逻辑**（sqflite ffi 初始化 / 工具播种与条件注册 / 发送门禁与 summaryStoreOpen 真实谓词），不依赖 Flutter；FFI 照旧加载 sidecar.dll（裸名加载依赖 CWD 含仓库根 DLL，启动文档须写明 CWD 约定）。Flutter 侧组合根不动。工具播种逻辑从 main.dart **抽取为共享函数**供两侧调用（避免复制分叉），抽取不改 Flutter 行为、既有测试全绿证明。
- **D5 语言终态=C++ + TS 两套（推荐，待拍板）**：Dart 核心过渡，架构验证后专门 change 迁 TS；本 change 不迁，但**须在 TODO.md 登记后继迁移条目**使收敛可追踪（RS-06）。C++ sidecar 恒留。
- **D6 范围=架构基石+最小验证页**：完整屏幕/规模优化/核心迁 TS 均后续 change。
- **D7 端口=OS 分配（port 0）**：`HttpServer.bind(loopbackIPv4, 0)` 取实际端口，回显 `http://127.0.0.1:<port>`；不写固定端口魔数。仅绑回环。
- **D8 foundation 解耦（范围修正）**：services 六文件 **+ models 五文件**（agent_type_config/app_config/provider_config/model_catalog_entry/message）的 foundation 换 `package:meta`（注解）+ 纯 Dart debugPrint shim。**shim 必须是与 foundation 同签名 `(String?, {int? wrapWidth})` 的可重赋值全局函数变量**，保住既有 9 处日志捕获测试。`Isolate` 不动。只换 import 与打印实现，不改业务逻辑/断言；既有全量测试原样全绿。
- **D9 事件映射（序列化落点修正）**：RPC 层实现 `AgentCallbacks`→`agent.event` notification（payload 带 sessionId+事件类型）。序列化**分类处理**：ToolCallActivity/AgentMetering 有现成 toJson 直接用；**Message 只有 toRow()（DB 行形状）、ContextSnapshot 只有 toRawJson()（缺 windowTokens/agentType/breakdown/capturedAt）、CompactionStatus 无序列化**——这三类由 RPC 层写**显式适配函数**（toRow 形状是否即对外契约须明确；快照适配要补占用环所需字段，不得静默丢 breakdown）。"不新造事件模型"指**不新造事件类型/语义**，允许必要的序列化适配；适配落在 tasks 2.3 点名。onCompactionStatusChanged/onMeteringChanged 无参，payload 由 RPC 层回读 agent.compactionStatus/agent.metering getter。**技能失败明细**（failureNotice/noticeLines）现寄生在 main.dart onSnapshot 回调上屏，web 路径须由 RPC 层主动读取并随快照事件推送，不得只剩计数（M8）。**AgentFactory.ensure 复用已存在实例时不重赋 callbacks**——RPC 层须在 ensure 后把该会话回调指向当前 WS 订阅者（callbacks 是可变公开字段），否则重连后事件发往旧回调（T5）。
- **D10 消息查询分页（辖域澄清）**：分页**仅限 message.query RPC 读路径**；`MessageRepository` 新增分页方法用**可选扩展/新接口**而非改既有接口签名（保住 FakeMessageRepository/_RecordingMessageRepo 两个 implements 夹具编译）。既有 queryBySession 全量方法保留（Flutter 与 Agent.restore 仍用）。**页大小请求方必填**，缺 pageSize 返回可区分 JSON-RPC 错误（-32602），核心不发明默认魔数；spec 补缺参负路径场景。"不载入整条历史"断言限定在 message.query 读路径，机器可观测判据=SQL 层 limit 或 repo 间谍计数（非仅断言返回页大小）。
- **D11 单实例守卫（A3 升级）**：双开后果含数据破坏（dispose_context 会 spill::remove_context_dir 删另一进程在用的溢出目录；sqlite 无跨进程锁），不止"双写"。故**加机器守卫**：无头核心启动时取命名互斥体/pidfile（Windows CreateMutex 或锁文件），已被占用则显式失败退出并提示"已有核心在运行"，不靠纯文档约定。Flutter 侧是否同样取锁=待拍板（首版至少无头侧自守 + 文档约定）。

## Risks / Trade-offs

- **[foundation 解耦动了核心文件]** → 只换 import/打印 shim（含 models 五文件），不改逻辑；shim 保可重赋值钩子；验收=既有全量测试原样全绿 + 变异。任何行为漂移立即回退。
- **[无头进程与 Flutter 进程双开破坏数据]** → D11 机器守卫（命名互斥体/pidfile）+ 文档约定；dispose_context 删共享 spill 目录、sqlite 无跨进程锁是真实冲突面，非仅双写。
- **[本机 WS 无鉴权]** → 仅绑 127.0.0.1 回环；本机信任边界内可接受。不引入审批/沙箱（用户零审批立场）。
- **[React/Node 构建链进仓库]** → 独立 `web/` 子项目、独立 lockfile；冒烟入口（run.bat/run_all.sh）新增 web 构建步须落任务（T8），无窗口。
- **[最小验证页不代表完整体验]** → 明示只证架构；F-002~F-004 与规模优化后续 change。
- **[debugPrint shim 改变日志去向]** → shim 同签名可重赋值，保住既有日志捕获正/负向断言；现场打印不丢。
- **[存量缺陷被 web 继承]** → 50 轮上限触发静默且不可配（M7）、摘要标记 xN 从不替换真实条数（M9）、L2 容量丢弃无日志（M10，用户曾授权静默丢弃）——本 change 不修，但 spec「错误路径可观察」须覆盖"send 返回但整轮 failed"的通知形态，web 不得比 Flutter 更盲；其余记入已知限制/后续 change。
- **[live 视觉验收通道错配]** → captureLiveShot 只截 Flutter RepaintBoundary，截不到浏览器页；web 验证页须用 OS 全屏截图（CopyFromScreen，TESTING.md §4.4）或无头浏览器+页面内截图新通道，tasks 4.2 点名（EXT-05/T4）。拉起浏览器给用户看触碰禁开窗令，apply 时需用户当场许可或走无头浏览器通道。

## Migration Plan

1. 先做 foundation 解耦（D8），既有全量测试原样全绿 → 证明核心纯 Dart 化无行为漂移。
2. 加无头组合根 + RPC/静态服务（D4/D7/D9/D10），用假 sidecar 的 integration 测试验通道。
3. 加 `web/` 最小验证页（D2），live 测试真实模型端到端 + 视觉验收。
4. Flutter 保持可用；回退=不启动无头进程即回到纯 Flutter，零数据迁移（同一 DB、同一 sidecar）。
5. 后续 change：完整聊天屏（含 F-002~F-004、虚拟滚动、分页落地）→ 核心迁 TS（终态 C+++TS）。

## Open Questions

- 单实例守卫形态：命名互斥体（CreateMutex）vs 锁文件（pidfile）——首版倾向锁文件（跨平台、可诊断），apply 前定；Flutter 侧是否同取锁待拍板。
- 无头核心启动形态：首版 `dart run bin/alias_agent_core.dart`，exe（dart compile exe）后置。
- web 产物 serve 与开发期 Vite proxy 关系：生产 serve 构建产物、开发 Vite proxy 到核心 WS，apply 落实。
- Message 对外契约形状：toRow()（DB 蛇形）直接作 RPC payload，还是适配成驼峰 toJson——倾向显式适配函数明确契约，apply 前定（D9）。

## 已裁决（对抗审查后关闭）

- **页大小缺省**：请求方必填，缺 pageSize 返回 -32602 错误，核心不发明默认魔数（原 Open Question 关闭，落 D10 + spec 负路径 + tasks 3.2）。