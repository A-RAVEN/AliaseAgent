## Why

路线 C 已迁聊天主循环（`web-ui-core-shim` 无头核心 + `web-chat-screen` 完整聊天屏），但 web 端**不能独立管理**：开新会话、配 provider、改模板、贴图、看上下文环详情都还得回 Flutter。RPC 面只有 `core.ping/session.list/message.query/agent.send/agent.cancel`，无会话增删改、无配置/模板/探测接口。本 change 把 Flutter 剩余管理屏迁到 web，让 web 端逼近「完整应用」、能独立日常使用。用户拍板 ①②③ 合一个 change（2026-11-22）。

## What Changes

分三阶段（先易后难，②压轴）：

**① 会话管理（小）**
- 核心新增 RPC：`session.create`/`session.delete`/`session.rename`/`session.switchTemplate`（复用 SessionRepository.create/delete/updateTitle/updateAgentType 与 AgentSessionController.switchTemplate）。
- web 侧栏：新建会话按钮、删除（确认）、重命名（内联编辑）、切换 agent 模板。

**③ 聊天体验补齐（中）**
- 图片输入/粘贴：核心新增 `attachment.upload`（base64 → ConfigService.attachmentsDir，返回路径），`agent.send` 已收 attachments；web Composer 支持粘贴/选择图片、附件预览。
- 上下文占用环详情：web 渲染交互式占用环（复用 ContextSnapshot/ContextBreakdown，事件已含 breakdown）+ 真实上下文视图（system/messages/tools 原始 JSON，ContextSnapshot.toRawJson 已有）。

**② 配置管理（大，压轴）**
- 核心新增 RPC：`config.get`/`config.save`（复用 ConfigService.load/save）、`provider.probe`（复用 ModelDiscoveryService.discover）、`template.list`/`template.save`/`template.delete`（复用 AgentTypeRegistry）。
- web provider 管理页：增删 provider、填 api_key/base_url、探测模型目录（probe gate，复用首启向导的探测门逻辑）、脏模型名可见。
- web 模板编辑页：增删 agent 模板、选 provider/model、工具勾选、系统提示词、思考强度、上下文窗口覆盖。
- web 首启向导：无配置时引导填 provider → 探测 → 选模型 → 建 general 模板（复用 setup_dialog 的探测门，不硬编码模型）。

## Capabilities

### New Capabilities
- `web-management-ui`: web 端管理界面契约——会话增删改/切换模板、图片输入/粘贴与附件、上下文占用环详情与真实上下文视图、provider 管理/模型探测、agent 模板编辑、首启向导；以及这些屏幕所需的管理 RPC 面（session.*/config.*/provider.probe/template.*/attachment.upload）。

### Modified Capabilities
- `agent-template-management`: 「模板菜单支持列表、添加与修改」MODIFIED——开放模板删除（带「被会话引用拒删」守卫 + general 不可删 + 新增 AgentTypeRegistry.remove），推翻原「第一版 SHALL NOT 删除模板」；模板名仍不可改。
- `web-core-shim`: 「无头核心进程独立启动并回显访问地址」MODIFIED——配置文件不存在时以空配置启动 serve 首启向导（原 notFound 拒启动门），malformed 仍可归因失败。

## Impact

- **核心（additive 接线 + RPC）**：headless_core 增 session.create/delete/rename/switchTemplate、config.get/save、provider.probe/probeFetch、template.list/save/delete、attachment.upload/read；复用现有 services。**必要接线（审查逼出）**：组合根配置进程内同步（移植 Flutter _applyProviderConfig）、启动门空配置支持、构造 AgentSessionController。**口径**：不改 agent/factory/registry/压缩/技能代码，但 RPC handler 调生命周期操作 + 组合根接线属正常实现。kCoreRpcMethodNames 同步。
- **web**：新增管理组件（会话侧栏交互/图片附件/占用环/真实上下文/provider 页/模板页/首启向导）+ protocol.ts 增管理 RPC 调用；复用 web-chat-screen 的 tokens/渲染。
- **复用不动**：聊天主循环、压缩/技能/spill、C++ sidecar、Flutter 界面（灰度共存）。
- **不做**：核心 Dart→TS 迁移、原生壳（Tauri）、规模优化（restore/_history 内存边界）——独立后续 change。
- **测试**：管理 RPC integration（假 sidecar+openAt 隔离）、web 组件 vitest + 交互 puppeteer、配置/探测 live（真实网关）、design_audit + 可见窗口截图视觉验收（AGENTS 新规则）。
- **依赖**：占用环可能需绘图（SVG 手绘或轻量库，评估）；图片上传走 base64 RPC（不引 multipart 库）。

## 关键决策（P1~P10，技术实现决策，按常理与产品先例定、文档化）

- **P1 分阶段**：核心接线→①会话→③聊天体验→②配置管理，先易后难。
- **P2 口径**：不改 agent/factory/registry/压缩/技能代码；RPC handler 调生命周期操作 + 组合根接线（配置同步/启动门/AgentSessionController）属正常实现，不拿自造约束要求用户拍板。
- **P3 图片上限钉死**：上传门复用既有常量 kMaxImageBytes=32MiB（出处 DeepSeekAPIDoc §6.4.3），类型校验复用 probeImageBytes（文件头魔数非 MIME）；不另发明、不留 apply 前定。attachment.read 供浏览器取历史图片。
- **P4 探测双入口**：provider.probe=discover（provider 页，写回）；provider.probeFetch=fetch（向导，只探测不写盘，Start 才落盘）。首启不硬编码模型（catalog 首项）。
- **P5 api_key 脱敏**：config.get 不回显明文（产品规范 SHALL NOT）；编辑留空沿用原密钥（不静默丢密钥）。
- **P6 模板生效时机分两类**：thinkingEffort 下一消息生效，model/tools/window/systemPrompt 对新会话生效；web 显式提示。模板编辑含 input_modalities（解锁图片）。
- **P7 模板删除开放**：MODIFIED agent-template-management + 引用守卫（被会话引用拒删）+ general 不可删 + AgentTypeRegistry.remove。
- **P8 占用环整圈钳制**：复用 ringSegments（超窗口超出部分不画、tokens 保留）；真实上下文视图 toRawJson。
- **P9 测试通道 + 隔离**：纯逻辑 vitest + 管理屏布局/交互 puppeteer（扩 harness）；integration 组合根注入 configPath/attachmentsDir/假 probe，不写用户真实配置/不联网。
- **P10 视觉验收**：管理屏真实打开截图 + read_image 核对（AGENTS 新规则，测试绿不能替代）。