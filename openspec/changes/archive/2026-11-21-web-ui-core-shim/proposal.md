## Why

AliasAgent 的 Flutter 自绘界面缺少可抄的 Markdown/流式/组件生态，观感债在累积（反馈台账 F-002 卡片折叠、F-003 自动贴底、F-004 跳底按钮）。同类项目（DSH=纯 web、Magpie=Wails+WebView2、Cherry/Chatbox/Jan=Electron/Tauri）几乎清一色 web 栈。用户已拍板 **GUI 直接 web 化（路线 C），取消原"Flutter 内立设计系统"的路线 A**（2026-11-16，原话「既然web化是目标，就没有A的必要吧」）。

但业务核心（agent 循环/压缩/技能/spill/句柄化/子 agent/配置/DB，lib/services 约 9 千行、含 models 约 1.05 万行 Dart）是被约 3.6 万行 unit+integration+live 测试护着的实测资产，一步重写风险前置。因此本 change 是路线 C 的**第一块基石**：先把"无头核心 + RPC 通道 + web 渲染"整条架构跑通，验证成立后再逐屏迁移；不动核心逻辑、不重写 live 资产。

## What Changes

- 新增**无头 Dart 核心入口**：复用现有 `lib/services` 业务层与 `dart:ffi` 加载 C++ sidecar，不依赖 Flutter 渲染，独立进程运行。
- 新增 **WebSocket + JSON-RPC 2.0 通道**：把"发送消息 / 流式 token / 工具调用事件 / 会话与消息查询"暴露给 web 客户端；流式与工具事件天然双向适配。
- 新增**本机静态服务**：核心进程同时 serve web 客户端产物；监听端口用 **OS 分配（port 0）**并回显实际 URL，不发明固定端口魔数。
- 新增 **web 客户端子项目（`web/`）**：React + Vite + TypeScript，Markdown 用 react-markdown、样式 Tailwind；本 change 只做一个**最小聊天验证页**（发一条消息→流式回复→工具卡片），证明架构端到端成立。
- **Flutter 界面保留并行**：本 change 不删不改 Flutter UI，灰度共存；完整聊天屏迁移、F-002~F-004、规模优化、核心迁 TS 均为**后续独立 change**。
- 新增用户文档与对应测试层（unit/widget/integration/live 按 TESTING.md 分层），文档守卫能失败。

## Capabilities

### New Capabilities
- `web-core-shim`: 无头 Dart 核心进程 + WebSocket/JSON-RPC 通道 + 本机静态服务 + 最小 web 聊天验证页的端到端契约（启动、端口回显、消息发送、流式/工具事件、会话/消息查询、错误路径、与 Flutter 并行共存）。

### Modified Capabilities
<!-- 本 change 只新增入口/传输层，不改既有能力的规格级行为；Flutter UI、核心 services、sidecar 接口均不变。故为空。 -->

## Impact

- **新增代码**：无头核心入口（`bin/` 或 `lib/core/`）、RPC/静态服务层、`web/` 前端子项目（React+Vite+TS，引入 Node 构建链，本机已有 node）。
- **复用不动**：`lib/services` 业务层、`dart:ffi` sidecar 桥、C++ sidecar、sqlite 持久化。
- **语言终态（明确收敛目标，非本 change 执行）**：C++（执行引擎）+ TS（编排+UI）两套；Dart 核心为**过渡层**，架构验证后由专门 change 迁 TS。本 change 不迁。
- **规模约束（指导本 change 的 RPC 面与后续屏幕 change，不引入反模式）**：现状 `message_repository.queryBySession` 全量载入历史无分页——本 change 的 **message.query RPC 读路径**支持分页/懒加载、页大小请求方必填；**发送/创建路径经 Agent.restore 仍全量载入历史并常驻属现状，"核心进程内存只留活跃投影"是后续规模 change 的目标，不是本 change 承诺**（避免把规模问题说成已解决）。会话列表后续虚拟滚动。token 估算已是廉价启发式（`context_estimator` 非分词器）、活跃上下文被压缩阈值钉死有界，故规模不构成"核心上系统语言"的理由。
- **依赖**：新增 web 前端依赖（react、react-markdown、tailwind、vite）；Dart 侧新增 websocket/静态服务所需最小依赖（优先标准库 `dart:io` HttpServer + WebSocket，避免引第三方）。
- **测试资产**：新增分层测试；不改动既有 3.6 万行核心测试的断言。

## 关键决策（供审查与用户拍板，可否决）

- **D1 壳**：纯浏览器起步（核心起本机 HTTP+WS，浏览器开 localhost）；原生壳（Tauri）后置可选，界面已是 web+WS 故套壳不返工。
- **D2 前端**：React + Vite + TS（Markdown/流式/组件生态最肥、DSH 同族可参考）。
- **D3 通信**：WebSocket + JSON-RPC 2.0。
- **D4 核心**：无头 Dart 进程，FFI 照旧；Flutter 并行灰度。
- **D5 语言终态**：C++ + TS 两套；Dart 过渡、后续 change 迁 TS（本 change 不做，但在 TODO.md 登记后继迁移条目使收敛可追踪）。
- **D6 范围**：本 change 只做架构基石 + 最小聊天验证页；完整聊天屏 / F-002~F-004 / 规模优化 / 核心迁 TS 均后续 change。
- **D7 端口**：OS 分配（port 0）+ 回显实际 URL，不写固定端口魔数。
- **D8 单实例守卫**：无头核心启动取锁文件/命名互斥体，双开显式失败退出（dispose_context 会删另一进程在用的 spill 目录、sqlite 无跨进程锁，后果含数据破坏，不止双写）。

> 授权口径：用户原话仅授权「路线 C + 取消 A + F-002~004 并入新 UI」；D1~D8 具体选型是助手推荐、待用户逐条拍板。「DSH 已验证/生态最肥/同类项目技术栈」是助手背景修辞，本地 Docs 无据，按助手判断对待。