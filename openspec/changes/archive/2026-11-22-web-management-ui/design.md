## Context

路线 C 已落聊天主循环。核心 RPC 面现仅 `core.ping/session.list/message.query/agent.send/agent.cancel`。**对抗审查核实的关键现状（产生状态的代码已追，本 change 必须正视）**：

1. **运行中核心无配置进程内同步**：`buildHeadlessCore` 里 `final providers = ProviderResolver(config)`（ProviderResolver 构造取 `Map.unmodifiable(config.providers)` 快照），`providerResolver: () => providers` 闭包捕获同一 final 局部量；`HeadlessCore.config` final。config.save/provider.probe/template.save 只写盘，运行中核心读不到新 provider/目录。Flutter 对应动作是 `main.dart._applyProviderConfig`（重建 ProviderResolver + `_templateController.replaceConfig` + 重注册模板）——**无头组合根没有等价物，必须移植**。
2. **启动门挡死真首启**：`HeadlessCoreRunner.start` 对 `ConfigStatus.notFound` 抛 HeadlessCoreStartupException（「先运行一次 Flutter 应用完成首启配置」），bin 入口 exitCode=1。配置文件不存在时核心不起、web 打不开。要 web 独立首启，须允许空配置启动并 serve 向导。
3. **核心无 AgentSessionController 实例**（lib/core grep 零命中）：session.switchTemplate/delete 需先在组合根构造它并注入 `_callbacksFor`。
4. **图片模态门禁**：`agent.dart` 按 `config.acceptsImages`（inputModalities 含 image）门控，不满足换成「[图片未发送：…]」可见文本；向导复用 setup_dialog 建的 general 是 `kDefaultInputModalities`（纯文本）；Flutter 模板编辑器有 modality-chip 可改模态——**D11 字段清单漏 input_modalities，web-only 流程贴图必被门控**。
5. **模板生效时机分两类**（agent-template-management 规范）：只有 thinking_effort 下一消息生效；model/tools/window/systemPrompt 创建时冻结、只对新会话生效（`kAgentTemplateEffectiveNote`）。初稿「下一轮装配生效」对 model/tools 为假。
6. **template.delete 撞既有规范**：agent-template-management「第一版 SHALL NOT 提供删除模板…开放的是 Provider 删除不是模板」；AgentTypeRegistry 无 remove/delete（只 register/add/update/clear）；无「被会话引用拒删」守卫。开放删除须 MODIFIED delta + 引用守卫 + 新 remove 代码。
7. **向导探测语义错配**：`ModelDiscoveryService.discover` 要求 provider 已在 config（否则「provider 不存在」）且成功即 ConfigService.save 写盘；setup_dialog 刻意注入 `ModelCatalogProbe.fetch`（只探测不写盘，Start 才落盘）。向导需 fetch-only 入口，不能直接用 discover。
8. **api_key 从不回显**：providers_page「不显示密钥明文」「留空表示沿用原密钥」；provider-model-discovery 规范「SHALL NOT 以明文显示密钥」。初稿「回显与 Flutter 一致」是假先例。
9. **图片上限有现成常量**：image_budget.dart `kMaxImageBytes=33554432`(32MiB)/`kMaxBase64ImageBytes=50331648`(48MiB)/`kMaxImageSide=8192`/`kManyImagesThreshold=15`，出处 DeepSeekAPIDoc §6.4.3/§6.4.1。发送期 planImageOmissions 超限换可见标记。上传门应复用既有常量，不另发明。
10. **历史图片浏览器取不到**：serializeMessage.attachments 只有路径，文件在 attachmentsDir；`_serveStatic`「拒绝访问 web 根之外的文件」。需 attachment.read RPC 供浏览器取历史图片字节。
11. **ConfigService.save 无校验**（直接 writeAsStringSync）；校验在 AgentTemplateController.validate / provider 表单层。config.save「校验后写」须点名复用校验器。
12. **占用环整圈钳制**：context_breakdown.ringSegments 累加到整圈为止、超出部分不画（tokens 保留）；三段之和可大于窗口。spec 须写这条。
13. **rename/delete 静默 no-op**：SessionRepository.updateTitle/delete 不读受影响行数；RPC 须自查存在性。
14. **图片类型判据是文件头魔数**（probeImageBytes 认 PNG/JPEG/GIF/WebP），不是 MIME。

约束：管理 RPC additive 复用 services；**口径澄清**——「不碰 agent 逻辑」指不改 agent/factory/registry/压缩/技能代码，但 RPC handler 会调用退役/销毁等生命周期操作、组合根须做配置同步与启动门调整（这些是 additive 接线，正常实现所需）。不发明魔数（图片上限复用既有常量）；砍内容可见可恢复；用户可见输出简体中文；管理屏属用户可见界面，**AGENTS 新规则要求真实打开截图 + read_image 视觉验收**。

## Goals / Non-Goals

**Goals:**
- ① web 会话管理：新建/删除（确认+守卫）/重命名/切换模板。
- ③ web 图片输入/粘贴 + 附件预览 + 历史图片渲染 + 可见提示；占用环（整圈钳制）+ 真实上下文视图。
- ② web provider 管理（增删/改名级联/引用守卫/探测/密钥不明文）+ 模板编辑（含 input_modalities/生效时机提示）+ 首启向导（空配置可启动）。
- 管理 RPC additive + **组合根配置进程内同步** + 启动门空配置支持 + AgentSessionController 接线。
- 管理屏真实打开截图 + read_image 视觉验收。

**Non-Goals:**
- 不改 agent/factory/registry/压缩/技能代码（RPC handler 调生命周期操作 + 组合根接线除外）；不迁核心 TS；不做原生壳；不做规模优化。

## Decisions

> 授权口径：P1~P14 为技术实现决策，按常理与产品先例定、文档化；用户已拍板 ①②③ 合一个 change。组合根同步/启动门/删除开放是正常实现所需，不拿自造约束要求用户拍板。

### 核心接线（additive，审查逼出的必要修正）

- **D1 组合根配置进程内同步**：移植 Flutter `_applyProviderConfig` 等价物——ProviderResolver/templates 改可替换；config.save/provider.probe/template.save 成功后重建 resolver + replaceConfig + 重注册模板，使运行中核心此后创建的实例读新配置。provider.probe 从盘重读最新 config 再 discover（避免旧配置盖掉刚写的编辑）。
- **D2 启动门空配置支持**：HeadlessCoreRunner.start 对 notFound 改为以空配置启动并 serve 向导（而非拒启动）；malformed 仍可归因失败。bin 入口相应调整。真首启 web 可达。
- **D3 AgentSessionController 接线**：组合根构造 AgentSessionController（注入 factory/sessionRepo/retireAgent）+ `_callbacksFor`；session.switchTemplate/delete 复用之。
- **D4 会话 RPC**：`session.create/delete/rename/switchTemplate`。delete 复刻 main.dart `_deleteSession` 序列（cancel→AgentRegistry.disposeAndRemove→sessionRepo.delete，含「底层没证明排空不许假装删成功」失败放弃分支）+ beginDelete/endDelete 守卫；rename/delete 自查存在性（不存在可归因错误，不静默 no-op）。switchTemplate 失败显示阶段+候选名。
- **D5 管理 RPC 面 + kCoreRpcMethodNames 同步**：session.*/config.get/config.save/provider.probe/provider.probeFetch/template.list/save/delete/attachment.upload/attachment.read；_registerMethods 清单一致守卫；文档 RPC 表同步。

### 配置/模板/向导

- **D6 config.get/save**：config.get **脱敏 api_key**（不回显明文，与产品规范一致）；config.save 复用校验器（模板走 AgentTemplateController.validate，provider 三要素走表单规则），校验失败可归因拒绝，不静默写坏。
- **D7 provider.probe vs probeFetch**：`provider.probe{providerName}`=discover（provider 页用，要求已存在、成功写回 catalog+discovered_at）；`provider.probeFetch{provider三要素}`=ModelCatalogProbe.fetch（向导用，**只探测不写盘**，Start 才落盘，复用 setup_dialog 不变量）。脏模型名可见、错误落盘路径回显。
- **D8 provider 页四项守卫**（复用 provider-model-discovery 规范）：删除仅在被模板引用时拒绝并显示引用名单；改名同一保存级联改写引用模板；密钥不明文（留空沿用原密钥）；保存成功后自动探测一次。
- **D9 模板编辑**：字段含 provider/model/tools/systemPrompt/thinkingEffort（五档）/maxContextTokens/**input_modalities（模态勾选，选目录模型时回填）**/压缩阈值（kDefault*）；保存走 AgentTemplateController.validate/save（保持配置完整，未开放字段原样保留）；**生效时机分两类提示**（thinkingEffort 下一消息生效，其余对新会话生效，复刻 kAgentTemplateEffectiveNote）；模板名创建后不可改。
- **D10 template.delete（开放，MODIFIED agent-template-management）**：新增 AgentTypeRegistry.remove（additive）；**被会话引用拒删**（显示引用会话名单，防 agent_type 悬空）；general 不可删（新增产品规则，SessionRepository.create 默认 general）；删除走 config.save 同步。
- **D11 首启向导**：空配置启动（D2）→填 provider 三要素→provider.probeFetch（只探测）→选 catalog 首项模型（不硬编码）→建 general（**模态可选 image**）→Start 时 config.save + 组合根同步（D1）→随后可聊天。补问不改既有模型字段。

### 图片 / 占用环

- **D12 图片上传/读取/渲染**：`attachment.upload{filename,base64}`→attachmentsDir（组合根暴露 attachmentsDir 注入），**大小上限复用 kMaxImageBytes（32MiB，出处 DeepSeekAPIDoc §6.4.3）**、类型校验复用 probeImageBytes（文件头魔数，非 MIME）；`attachment.read{path}`→base64（浏览器取历史图片，_serveStatic 拒 web 根外故需此 RPC）。web Composer 粘贴/选择→预览→send 带 attachments；MessageList 渲染附件缩略图 + **可见提示**（模型未声明 image→「图片未发送」行；文件丢失→「图片已丢失」行，复用 image-input 规范）。上传门与发送期预算（planImageOmissions）两层关系写明。
- **D13 占用环 + 真实上下文**：SVG 三瓣环复用 ringSegments（**整圈钳制：三段之和超窗口时超出部分不画、tokens 保留**）；真实上下文视图 toRawJson（system/messages/tools，可滚可复制）。

### 测试 / 视觉验收

- **D14 测试通道钉死 + 隔离**：纯逻辑 vitest（node，renderMessages/校验/选首项）；**管理屏布局/交互走 puppeteer**（扩 test/harness 挂管理屏场景，jsdom 无布局引擎测不了几何）；向导假 catalog 驱动（注入假 probeFetch 返回首项不同的两份 catalog）。integration 隔离：组合根暴露 configPath/attachmentsDir/probe 注入，测试用临时目录+假 probe，**不写用户真实 config/附件、不联网**（先备份用户 config）。
- **D15 视觉验收**：每管理屏真实打开截图 + read_image 核对（AGENTS 新规则）；design_audit 初态审计；测试绿不能替代。

## Risks / Trade-offs

- **[组合根同步/启动门触及核心接线]** → additive 移植 Flutter 既有逻辑（_applyProviderConfig/空配置启动），不改 agent 代码；integration 测试核同步后新 provider 可解析。
- **[template.delete 开放撞既有规范]** → MODIFIED agent-template-management delta + 引用守卫 + general 不可删；归档同步消除矛盾。
- **[图片模态门禁]** → 模板编辑/向导开放 input_modalities；web 可见提示「图片未发送」不静默。
- **[api_key 脱敏]** → 留空沿用原密钥合并规则，改 base_url 未重填密钥不丢真密钥。
- **[②配置管理量大]** → 压轴分任务；faithful 复用 Flutter 校验/探测门/级联/引用守卫。
- **[integration 文件 I/O 隔离]** → 组合根注入 configPath/attachmentsDir/probe，临时目录+假 probe，备份用户 config。
- **[管理屏视觉验收]** → 每屏真实打开截图+read_image，缺则不通过。

## Migration Plan

1. 核心接线（D1/D2/D3/D5）+ 会话 RPC（D4）+ 阶段①测试 + 视觉验收。
2. 阶段③：图片上传/读取/渲染（D12）+ 占用环（D13）+ 测试 + 视觉验收。
3. 阶段②：config/provider/模板 RPC（D6/D7/D9/D10）+ provider 页（D8）+ 模板页（D9）+ 向导（D11）+ 测试 + 视觉验收。
4. MODIFIED deltas（agent-template-management 删除开放；web-core-shim 启动门/RPC 面）归档同步。
5. 回退：web 独立子项目；核心接线 additive 兼容，Flutter 不受影响。

## Open Questions

- 占用环交互：首版展示三瓣环 + 点击切真实上下文视图（倾向）。
- 空配置启动的默认 provider 名：向导首启默认 magpie（与 setup_dialog 一致），可改。

## 已裁决（对抗审查后关闭）

- 图片上限默认 = kMaxImageBytes（既有常量，出处 §6.4.3），不另发明、不留 apply 前定。
- api_key 脱敏 + 留空沿用（产品规范 SHALL NOT 明文），不回显。
- 模板生效时机分两类（thinkingEffort 下一消息，其余新会话），web 显式提示。
- 向导用 probeFetch（只探测不写盘），provider 页用 probe（discover 写回）。
- template.delete 开放 + 引用守卫 + general 不可删（MODIFIED delta）。
- 组合根配置同步 + 空配置启动 + AgentSessionController 接线（必要 additive）。