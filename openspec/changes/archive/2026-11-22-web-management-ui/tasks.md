## 0. 核心接线（additive，审查逼出的必要前置）

- [x] 0.1 组合根配置进程内同步（design D1）：移植 Flutter `_applyProviderConfig` 等价物——ProviderResolver/templates 改可替换；config.save/provider.probe/template.save 成功后重建 resolver + replaceConfig + 重注册模板。provider.probe 从盘重读最新 config 再 discover（防旧配置盖掉刚写的编辑）。integration 测试：新增 provider 保存后建新会话 resolveCandidate 读到新 provider（不抛 MissingAgentProviderException）。先红后绿。
- [x] 0.2 启动门空配置支持（design D2）：HeadlessCoreRunner.start 对 notFound 改以空配置启动 serve 向导；malformed 仍可归因失败；bin 入口相应调整。integration 测试：空配置启动成功 serve、malformed 可归因失败。先红后绿。
- [x] 0.3 AgentSessionController 接线（design D3）：组合根构造 AgentSessionController（注入 factory/sessionRepo/retireAgent）+ _callbacksFor。integration 测试：切换模板后事件发往当前 WS 订阅者。先红后绿。
- [x] 0.4 管理 RPC 面骨架 + 隔离注入（design D5/D14）：kCoreRpcMethodNames 扩展 + _registerMethods 清单一致；组合根暴露 configPath/attachmentsDir/probe 注入（供测试隔离，不写用户真实 config/附件、不联网）。integration 测试用临时目录+假 probe。先红后绿。

## 1. 阶段①：会话管理

- [x] 1.1 会话 RPC（design D4）：session.create/delete/rename/switchTemplate；delete 复刻 _deleteSession 序列（cancel→disposeAndRemove→delete + 失败放弃分支）+ beginDelete/endDelete 守卫；rename/delete 自查存在性。错误可归因。
- [x] 1.2 会话 RPC integration 测试（`test/integration/web_management_rpc_test.dart`，临时 configPath+openAt+假 sidecar 隔离）：新建/删除/重命名/切换成功 + 切换预检失败可归因（旧实例/DB 不变）+ **删除进行中切换→deleting 阶段拒绝（RPC 层守卫用例，变异①红靶）** + 删/改不存在会话可归因。先红后绿贴现场。
- [x] 1.3 web 侧栏交互（design D7）：新建/删除确认浮层/重命名内联/切换模板下拉（失败显示阶段+候选名）。protocol.ts 增会话 RPC。**测试通道**：纯逻辑 vitest + 交互 puppeteer（扩 test/harness 挂管理屏场景）。先红后绿。

## 2. 阶段③：图片 + 占用环

- [x] 2.1 附件 RPC（design D12）：attachment.upload（attachmentsDir 注入，上限复用 kMaxImageBytes=32MiB 出处 §6.4.3，类型校验复用 probeImageBytes 文件头魔数）+ attachment.read（返回 base64 供历史图片）。integration 测试（临时 attachmentsDir 隔离）：上传落盘返回路径、超限可归因、非图片拒绝、read 取字节。先红后绿。
- [x] 2.2 web 图片输入 + 渲染（design D12）：Composer 粘贴/选择→预览/移除→send 带 attachments；MessageList 渲染附件缩略图 + 可见提示（模型未声明 image→「图片未发送」行、文件丢失→「图片已丢失」行）。组件/交互测试（vitest 逻辑 + puppeteer 渲染）。先红后绿。
- [x] 2.3 占用环 + 真实上下文（design D13）：SVG 三瓣环复用 ringSegments（**整圈钳制**：超窗口超出部分不画、tokens 保留）+ 真实上下文视图（toRawJson）。组件测试：三瓣比例 + **超窗口整圈钳制用例** + 真实上下文 JSON 一致。先红后绿。

## 3. 阶段②：配置管理（压轴）

- [x] 3.1 config/provider RPC（design D6/D7）：config.get（**脱敏 api_key**）/config.save（复用校验器，失败可归因）/provider.probe（=discover 写回）/provider.probeFetch（=fetch 只探测不写盘，接受三要素）。kCoreRpcMethodNames 同步。integration 测试（临时 configPath+假 probe 隔离）：config 读写脱敏、probe 写回 catalog+discovered_at、probeFetch 不写盘、非标准端点可归因。先红后绿。
- [x] 3.2 模板 RPC（design D9/D10）：template.list/save（走 AgentTemplateController.validate/save 保持完整，含 input_modalities）/delete（新增 AgentTypeRegistry.remove + **被会话引用拒删** + general 不可删）。integration 测试：增删改、引用拒删、general 拒删、非法字段可归因、保存保持未开放字段。先红后绿。
- [x] 3.3 web provider 页（design D8）：列表+增删（**引用拒删显示名单**）+改名级联+编辑 api_key/base_url（**密钥不明文、留空沿用**）+探测按钮+保存后自动探测。组件/交互测试。先红后绿。
- [x] 3.4 web 模板页（design D9）：列表+增删（general 不可删）+编辑 provider/model/tools/systemPrompt/thinkingEffort 五档/maxContextTokens/**input_modalities 模态勾选**/压缩阈值+**生效时机分两类提示**+模板名不可改。组件/交互测试（含生效时机提示断言）。先红后绿。
- [x] 3.5 web 首启向导（design D11）：空配置启动→填三要素→probeFetch（只探测）→选 catalog 首项（不硬编码）→建 general（模态可选 image）→Start config.save+组合同步→可聊天；补问不改模型。**假 catalog 驱动通道**（注入假 probeFetch 返回首项不同两份 catalog，变异②红靶）。组件/交互测试。先红后绿。

## 4. 文档 + 守卫

- [x] 4.1 用户文档：新建 `Docs/user-guide/web-management.md`（会话/图片/占用环/provider/模板/向导怎么用、管理 RPC 表、图片上限=kMaxImageBytes 出处、密钥脱敏留空沿用、模板生效时机）；README 索引；configuration.md 补图片上限键；web-core-shim.md RPC 表同步管理方法 + 空配置启动。
- [x] 4.2 文档守卫（`test/unit`，参照 parallel_tools_docs_test 解析常量强先例）：管理 RPC 名取自 kCoreRpcMethodNames、图片上限取自 image_budget 常量、README 索引双向一致；改文案不改文档就红。先红后绿。

## 5. 全量验证 + 变异 + 视觉验收 + validate（主循环批次）

- [x] 5.1 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线本轮实测留档、改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`（**先备份用户 config**）；`npm --prefix web run build` + web 测试（vitest+puppeteer）全绿。
- [x] 5.2 两个变异（各贴红证据后恢复、复跑全绿、改动文件哈希逐位相同）：① 删 session.delete handler 的 beginDelete 调用 → **1.2「删除进行中切换→deleting 拒绝」RPC 守卫用例**必须红；② 向导写死模型名 → **3.5「假 catalog 首项变化不写死」用例**必须红。
- [x] 5.3 **管理屏视觉验收（AGENTS 新规则，缺则不通过）**：核心 serve + 真实打开会话侧栏/provider 页/模板页/向导/占用环，desktop-screenshot 截图 + 主 agent read_image 核对控件/渲染（非错误页/空窗）；design_audit 初态审计。贴截图路径与核对结论。
- [x] 5.4 配置/探测 live（--tags live，真实网关，**临时 configPath 隔离不写用户 config**）：provider.probe 真探测 magpie 写回；无头浏览器截图视觉验收。贴 live 输出与截图。
- [x] 5.5 `openspec validate web-management-ui --type change` 通过贴输出。归档同步 agent-template-management（删除开放）+ web-core-shim（空配置启动）MODIFIED delta + Purpose 口径。