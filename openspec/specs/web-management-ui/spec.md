# web-management-ui Specification

## Purpose

规定 AliasAgent 的 web 管理界面能力：在无头核心 + web 客户端之上提供会话管理（新建/删除/重命名/切换模板）、图片输入（上传/读取/渲染与可见降级提示）、上下文占用环与真实上下文视图、provider 管理与模型探测、agent 模板编辑与带引用守卫的删除、空配置首启向导，以及配套管理 RPC 面的注册一致性与配置进程内同步。管理屏属用户可见界面，其视觉验收要求亦在本能力内规定。

## Requirements

### Requirement: 会话管理 RPC 与侧栏交互
核心 SHALL 提供 `session.create/delete/rename/switchTemplate`，复用 SessionRepository 与 AgentSessionController（组合根须构造其实例并注入回调）。delete SHALL 复刻 Flutter 删除序列（cancel→disposeAndRemove→sessionRepo.delete，含「底层未证明排空不许假装删成功」的失败放弃分支）+ beginDelete/endDelete 守卫；rename/delete SHALL 自查存在性，不存在返回可归因错误（不静默 no-op）。web 侧栏 SHALL 支持新建/删除（确认）/重命名（内联）/切换模板；切换失败 SHALL 显示阶段与候选名。

#### Scenario: 新建会话
- **WHEN** 用户点新建按钮
- **THEN** session.create 创建并选中，可立即发消息

#### Scenario: 删除会话需确认且守卫生效
- **WHEN** 用户点删除并确认
- **THEN** 先弹确认；删除走 beginDelete 守卫（删除进行中拒绝切换、等待在途切换），清理上下文，侧栏移除；底层未证明排空时不假装删成功

#### Scenario: 删除进行中切换被拒
- **WHEN** session.delete 进行中调用 session.switchTemplate
- **THEN** 返回 deleting 阶段可归因拒绝，删除不得先于在途切换返回

#### Scenario: 重命名/删除不存在会话可归因
- **WHEN** 对不存在的 sessionId 调 rename/delete
- **THEN** 返回可归因错误，不静默 no-op

#### Scenario: 切换模板失败可归因
- **WHEN** 切换到预检失败的模板
- **THEN** 显示失败阶段与候选名，旧实例与数据库不变，不静默退回 general

### Requirement: 图片输入、上传、读取与渲染
核心 SHALL 提供 `attachment.upload{filename,base64}`（写 attachmentsDir 返回路径，组合根暴露目录注入）与 `attachment.read{path}`（返回 base64，供浏览器取历史图片，因静态服务拒 web 根外文件）。上传大小上限 SHALL 复用既有常量 kMaxImageBytes（32MiB，出处 DeepSeekAPIDoc §6.4.3），类型校验 SHALL 复用 probeImageBytes（文件头魔数，非 MIME）；超限/非图片 SHALL 可归因拒绝。`agent.send` SHALL 接受 attachments。web Composer SHALL 支持粘贴/选择/预览/移除；MessageList SHALL 渲染附件缩略图，并在模型未声明 image 模态时显示「图片未发送」可见提示行、文件丢失时显示「图片已丢失」提示行（复用 image-input 规范），MUST NOT 静默降级。

#### Scenario: 粘贴图片上传并发送（模态含 image）
- **WHEN** 模板 input_modalities 含 image，用户粘贴图片并发送
- **THEN** attachment.upload 落盘返回路径，agent.send 带附件，模型收到图片

#### Scenario: 模型未声明 image 时可见提示
- **WHEN** 模板 input_modalities 不含 image，用户贴图发送
- **THEN** 消息下方显示「图片未发送」可见提示行，不静默丢图

#### Scenario: 超限图片可归因拒绝
- **WHEN** 上传超过 kMaxImageBytes 的图片
- **THEN** 返回可归因错误（指明上限与出处），不静默截断

#### Scenario: 历史图片可读取渲染
- **WHEN** 加载含附件的历史消息
- **THEN** 经 attachment.read 取字节渲染缩略图；文件丢失显示「图片已丢失」提示

### Requirement: 上下文占用环详情与真实上下文视图
web SHALL 渲染占用环（二级摘要/一级摘要/原文三瓣，复用 ringSegments），**整圈钳制**：三段之和超过窗口时超出部分不画、真实 token 数原样保留（MUST NOT 画过整圈自覆盖）。SHALL 提供真实上下文视图（toRawJson 的 system/messages/tools，可滚可复制）。MUST NOT 静默丢 breakdown。

#### Scenario: 占用环三瓣按 token 比例且整圈钳制
- **WHEN** 快照 breakdown 三段之和 ≤ 窗口
- **THEN** 三瓣弧度按 token 占比；当三段之和 > 窗口时累加到整圈为止、超出部分不画、tokens 数字保留原值

#### Scenario: 真实上下文视图
- **WHEN** 用户打开真实上下文视图
- **THEN** 显示 system/messages/tools 原始 JSON，可滚可复制，与 toRawJson 一致

### Requirement: provider 管理与模型探测
核心 SHALL 提供 `config.get`（**脱敏 api_key，MUST NOT 回显明文**）/`config.save`（复用校验器，校验失败可归因拒绝）/`provider.probe`（=discover，provider 页用，要求 provider 已存在、成功写回 catalog+discovered_at）/`provider.probeFetch`（=ModelCatalogProbe.fetch，向导用，接受三要素、**只探测不写盘**）。web provider 页 SHALL 复用 provider-model-discovery 规范四项守卫：删除仅在被模板引用时拒绝并显示引用名单、改名同一保存级联改写引用模板、密钥不明文（留空沿用原密钥）、保存成功后自动探测一次。探测 SHALL 脏模型名可见、错误落盘路径回显。

#### Scenario: 探测模型目录（provider 页）
- **WHEN** 用户对已存在 provider 点探测
- **THEN** provider.probe 返回 catalog+discovered_at 并写回；非标准端点/脏模型名可见、错误落盘路径回显

#### Scenario: 密钥不明文且留空沿用
- **WHEN** 用户编辑 provider 改 base_url 但未重填密钥并保存
- **THEN** 沿用原密钥（不静默换成空串），界面不回显密钥明文

#### Scenario: 删除被引用 provider 拒绝
- **WHEN** 删除被模板引用的 provider
- **THEN** 拒绝并显示引用它的模板名单

#### Scenario: 改名级联
- **WHEN** 改名 provider 并保存
- **THEN** 同一保存级联改写引用该 provider 的模板

### Requirement: agent 模板编辑
核心 SHALL 提供 `template.list/save/delete`。template.save SHALL 走 AgentTemplateController.validate/save（保持配置完整，未开放字段原样保留）；字段含 provider/model/tools/systemPrompt/thinkingEffort（五档）/maxContextTokens/**input_modalities（模态勾选，选目录模型时回填）**/压缩阈值（kDefault*）。**生效时机分两类**：thinking_effort 对运行中 Agent 下一消息生效；model/tools/window/systemPrompt 只作用于之后创建或恢复的 Agent。web 模板页 SHALL 显式提示这一生效时机（复刻 kAgentTemplateEffectiveNote）。模板名创建后 MUST NOT 可改。

#### Scenario: 编辑模板生效时机分两类
- **WHEN** 用户修改模板的 thinkingEffort 与 model 并保存
- **THEN** thinkingEffort 对运行中对话下一消息生效；model 只对之后创建/恢复的会话生效，运行中实例 model 不变；界面显示生效时机提示

#### Scenario: 编辑 input_modalities 解锁图片
- **WHEN** 用户在模板编辑勾选 image 模态并保存
- **THEN** 该模板新会话接受图片输入（acceptsImages 为真）

#### Scenario: 保存保持配置完整
- **WHEN** 保存模板
- **THEN** 未开放编辑的受支持字段（命令超时/不可压缩要求/压缩参数等）原样保留，不静默丢失

### Requirement: 模板删除（开放，带引用守卫）
核心 SHALL 提供 template.delete（新增 AgentTypeRegistry.remove，additive）。**被会话引用的模板 SHALL 拒删**并显示引用会话名单（防 agent_type 悬空）；**general 模板 MUST NOT 可删**（可归因拒绝）；删除 SHALL 走 config.save + 组合根同步。此能力开放修改 agent-template-management「第一版 SHALL NOT 删除模板」（见该能力 MODIFIED delta）。

#### Scenario: 删除被会话引用模板拒绝
- **WHEN** 删除被既有会话 agent_type 引用的模板
- **THEN** 拒绝并显示引用会话名单，不产生悬空引用

#### Scenario: general 不可删
- **WHEN** 尝试删除 general
- **THEN** 可归因拒绝，general 保留

### Requirement: 首启向导（空配置可启动）
核心 SHALL 允许配置文件不存在时以空配置启动并 serve 向导（修改启动门，见 web-core-shim MODIFIED）。web 向导 SHALL：填 provider 三要素 → provider.probeFetch（只探测不写盘）→ 选 catalog 首项模型（MUST NOT 硬编码）→ 建 general（模态可选 image）→ Start 时 config.save + 组合根同步 → 随后可正常聊天。补问 SHALL NOT 改写既有模型字段。

#### Scenario: 空配置首启建 general
- **WHEN** 配置文件不存在时启动核心并打开 web 完成向导
- **THEN** 核心以空配置启动 serve 向导；完成后建 general（model=catalog 首项）写回配置并同步运行中核心，随后可正常聊天

#### Scenario: 不硬编码模型
- **WHEN** 假 probeFetch 先后返回首项不同的两份 catalog
- **THEN** 向导选用模型随 catalog 首项变化，不写死任何模型名

#### Scenario: 探测中途失败不留半份配置
- **WHEN** 向导探测失败或用户中途放弃（未点 Start）
- **THEN** 不写盘（probeFetch 只探测），不留半份配置

### Requirement: 管理 RPC 面同步与可归因
新增管理 RPC SHALL 同步进 kCoreRpcMethodNames（_registerMethods 清单一致守卫）与文档 RPC 表。管理 RPC 失败 SHALL 返回可归因 JSON-RPC 错误，MUST NOT 静默失败或崩溃。config.save/provider.probe/template.save 成功后 SHALL 触发组合根配置进程内同步（重建 resolver + 重注册模板），使运行中核心此后创建的实例读新配置。

#### Scenario: 配置同步后新 provider 可解析
- **WHEN** web 新增 provider 并保存后建新会话
- **THEN** 组合根同步后 resolveCandidate 读到新 provider，不抛 MissingAgentProviderException

#### Scenario: 方法清单一致
- **WHEN** 核心启动注册管理 RPC
- **THEN** kCoreRpcMethodNames 与实现一致（漏注册抛 StateError），文档 RPC 表含全部管理方法

### Requirement: 管理屏视觉验收
管理屏属用户可见界面，验收 SHALL 含真实打开界面后的截图 + 主 agent read_image 核对画面内容（控件/渲染与要求一致）。自动化测试全绿 MUST NOT 替代视觉验收；缺截图与视觉验收视作不通过。

#### Scenario: 管理屏真实打开截图核对
- **WHEN** 验收会话侧栏/provider 页/模板页/向导/占用环
- **THEN** 真实打开各屏截图，主 agent read_image 核对控件与渲染正确（非错误页/空窗），测试绿不能替代
