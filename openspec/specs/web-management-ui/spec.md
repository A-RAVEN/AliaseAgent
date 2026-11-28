# web-management-ui Specification

## Purpose

规定 AliasAgent 的 web 管理界面能力：在无头核心 + web 客户端之上提供会话管理（新建/删除/重命名/切换模板）、图片输入（上传/读取/渲染与可见降级提示）、上下文占用环与真实上下文视图、provider 管理与模型探测、agent 模板编辑（含模板头像上传/预览/清除）与带引用守卫的删除、用户头像入口与 `profile.save`、空配置首启向导，以及配套管理 RPC 面的注册一致性与配置进程内同步。管理屏属用户可见界面，其视觉验收要求亦在本能力内规定。

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

核心 SHALL 提供 `template.list/save/delete`。template.save SHALL 走 AgentTemplateController.validate/save（保持配置完整，未开放字段原样保留）；字段含 provider/model/tools/systemPrompt/thinkingEffort（五档）/maxContextTokens/**input_modalities（模态勾选，选目录模型时回填）**/压缩阈值（kDefault*）/**头像（`avatarPath`：上传、预览、清除）**。**生效时机分两类**：thinking_effort 对运行中 Agent 下一消息生效；model/tools/window/systemPrompt 只作用于之后创建或恢复的 Agent。**头像不属于这两类**：它不进模型请求，保存后界面重拉即可让该模板的头像在成员卡片、气泡与模板页上更新，SHALL NOT 要求重建 Agent 实例。web 模板页 SHALL 显式提示这一生效时机（复刻 kAgentTemplateEffectiveNote）。模板名创建后 MUST NOT 可改。

模板页的头像控件 SHALL：显示当前头像（上传图或身份图案）、提供选择图片的入口、提供清除入口。头像预览 SHALL 经 `attachment.read` 换成 data URL 后渲染，MUST NOT 把附件目录的绝对路径直接塞进 `<img src>`。上传 SHALL 复用 `attachment.upload`（同一套大小上限与文件头魔数判定），保存 SHALL 把得到的路径作为 `avatarPath` 交给 `template.save`；清除 SHALL 提交**空串**（`avatarPath: ''`）使配置里不再有该键。用户没有碰过头像时，保存 SHALL **省略** `avatarPath`（= 不改），MUST NOT 因为页面没带上这个字段而清空既有头像。模板页 MUST NOT 另建上传接口、MUST NOT 在浏览器里做第二套图片校验去替代核心的校验；上传或保存失败时 SHALL 显示可归因错误（点名原因），MUST NOT 静默丢弃用户的选择。

#### Scenario: 编辑模板生效时机分两类

- **WHEN** 用户修改模板的 thinkingEffort 与 model 并保存
- **THEN** thinkingEffort 对运行中对话下一消息生效；model 只对之后创建/恢复的会话生效，运行中实例 model 不变；界面显示生效时机提示

#### Scenario: 编辑 input_modalities 解锁图片

- **WHEN** 用户在模板编辑勾选 image 模态并保存
- **THEN** 该模板新会话接受图片输入（acceptsImages 为真）

#### Scenario: 保存保持配置完整

- **WHEN** 保存模板
- **THEN** 未开放编辑的受支持字段（命令超时/不可压缩要求/压缩参数等）原样保留，不静默丢失

#### Scenario: 模板页上传头像

- **WHEN** 用户在模板页为模板「甲」选择一张图片并保存
- **THEN** 先发 `attachment.upload` 拿到路径，再发 `template.save` 且 payload 的 `avatarPath` 是同一个路径；模板页预览更新为该图，重拉 `template.list` 后该模板仍带头像

#### Scenario: 清除模板头像

- **WHEN** 用户点清除某个模板的头像并保存
- **THEN** `template.save` 的 payload 里头像为空串（`avatarPath: ''`，清除语义），写回后该模板的 `avatar_path` 键消失，模板页预览回到身份图案

#### Scenario: 没碰头像的保存不清空既有头像

- **WHEN** 用户只改一个有头像模板的模型并保存，编辑过程中没碰头像控件
- **THEN** `template.save` 的 payload 省略 `avatarPath`，写回后该模板的 `avatar_path` 与原来逐字一致

#### Scenario: 新增模板不继承头像

- **WHEN** 用户在模板页新增一个模板并保存，没选头像
- **THEN** `template.save` 的 payload 省略 `avatarPath`，新模板没有 `avatar_path`，预览是身份图案（MUST NOT 沿用 general 的头像）

#### Scenario: 上传失败可归因且不丢选择

- **WHEN** 用户选择的文件超过单张上限、或文件头魔数不是支持的图片格式
- **THEN** 模板页显示可归因错误（点名上限或格式判定依据），既有头像不变，用户可重新选择

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
管理屏与全局设置菜单属用户可见界面，验收 SHALL 含真实打开界面后的截图 + 主 agent read_image 核对画面内容（控件/渲染与要求一致）。自动化测试全绿 MUST NOT 替代视觉验收；缺截图与视觉验收视作不通过。

#### Scenario: 管理屏真实打开截图核对
- **WHEN** 验收会话侧栏/provider 页/模板页/向导/占用环/全局设置菜单
- **THEN** 真实打开各屏（含点左栏底部「设置」后向上浮出的菜单）并截图，主 agent read_image 核对控件与渲染正确（非错误页/空窗），测试绿不能替代

### Requirement: 用户头像（侧栏入口与 `profile.save`）

web 客户端 SHALL 在**会话侧栏底部**提供用户头像块：显示头像是用户头像（上传图，没有则是身份图案）、一个「换头像」入口与一个「恢复默认」入口。用户头像的图片 SHALL 经 `attachment.read` 换成 data URL 后渲染（MUST NOT 把绝对路径塞进 `<img src>`）。换头像 SHALL 复用 `attachment.upload` 上传，再把路径交给核心的 `profile.save`；恢复默认 SHALL 调 `profile.save` 并传**空串**。成功后 SHALL 立即更新界面上的用户头像（用户消息气泡、群聊用户消息），MUST NOT 要求用户刷新整页才生效。

`config.get` SHALL 返回 `profile`（用户头像路径、用户标识与实际生效种子 `identitySeed`），使页面刷新后仍能画出同一个头像；`profile` 缺失时按身份图案渲染。**读取失败**（`config.get` 抛错）时头像块 SHALL 显示可归因的可见提示（含「重试」），MUST NOT 静默把失败当成"没有头像"。

核心 SHALL 提供 `profile.save{avatarPath}`：`avatarPath` SHALL **必填字符串**——`''` 表示清除该键、非空表示设为该路径、省略 / `null` / 其它类型 SHALL 返回 `-32602`（它是一次写操作，不允许"什么都没写"却返回成功）。非空路径必须是注入附件目录内**确实存在的文件**（目录边界与"是文件"的判定复用 `attachment.read` 的同一写法），否则返回可归因的 `-32602` 错误（点名路径与目录）；成功 SHALL 把整份配置写回磁盘（providers / agent_types / search / spill / tool 原样保留）并返回更新后的 `profile`。`profile.save` SHALL 同步进 `kCoreRpcMethodNames` 与用户文档的 RPC 表（沿用「管理 RPC 面同步与可归因」的条款），MUST NOT 只实现不登记。

#### Scenario: 换头像后整页用户头像同步

- **WHEN** 用户从侧栏用户头像块选择一张图片
- **THEN** 客户端发出 `attachment.upload` 与 `profile.save`（payload 带刚拿到的路径），成功后所有用户消息气泡与侧栏头像都换成本地图片，不需要刷新页面

#### Scenario: 恢复默认头像

- **WHEN** 用户点「恢复默认」
- **THEN** `profile.save` 的 payload 头像为空串，写回的配置里不再有 `profile.avatar_path`，界面上用户头像回到身份图案

#### Scenario: 刷新后头像仍在

- **WHEN** 用户设置头像后刷新浏览器
- **THEN** `config.get` 返回同一个 `profile.avatarPath`，侧栏与气泡显示同一张图，不出现「刷新后变回默认图案」

#### Scenario: 头像资料读取失败可见

- **WHEN** 页面打开时 `config.get` 失败
- **THEN** 侧栏用户头像块显示「头像资料读取失败：…」与重试入口，头像按身份图案渲染，聊天屏与群视图照常加载（MUST NOT 因为这次失败挡住消息）

#### Scenario: 头像保存缺字段或类型错被拒

- **WHEN** `profile.save` 的 `avatarPath` 被省略、传 `null`、或传数字
- **THEN** 返回 `-32602` 并点名 `avatarPath`，配置与界面头像都不变（不允许"静默当成功"）

#### Scenario: 头像保存失败可归因

- **WHEN** `profile.save` 收到附件目录之外或已不存在的路径
- **THEN** 返回可归因错误（点名路径与附件目录），配置不变，界面显示该错误而不是静默失败

#### Scenario: 只提交 provider 的保存不抹用户头像

- **WHEN** 用户已有头像，随后在 Provider 页保存一次
- **THEN** 写回后 `profile.avatar_path` 逐字不变，刷新后头像仍是那张图

#### Scenario: 方法清单与文档同步

- **WHEN** 核心启动注册管理方法
- **THEN** `kCoreRpcMethodNames` 含 `profile.save` 且 `_registerMethods` 有实现（漏实现抛错），用户文档的 RPC 表里也有这一行

#### Scenario: 没有 profile 时用身份图案

- **WHEN** 配置文件里没有 `profile` 键
- **THEN** 侧栏用户头像块与用户气泡都显示由常量用户标识生成的身份图案，界面不报错、不显示空图片框

### Requirement: 全局设置菜单（左栏底部唯一管理入口）

web 客户端 SHALL 在**常驻左栏的底部**（用户头像块之上、同一 footer 区）提供全局设置按钮（图标 + 「设置」文字），单聊、群聊与无选中会话三种状态下 SHALL 都可见且可用；管理入口 MUST NOT 依赖主区类型。点击按钮 SHALL 在其**上方**浮出一张圆角菜单（浮层，不挤动会话列表），每项 SHALL 由**图标 + 文字**组成。

菜单 SHALL **恰好两项**：「Provider 配置」打开既有 `ProvidersPage` 覆盖层；「模板配置」打开既有 `TemplatesPage` 覆盖层。MUST NOT 出现第三项，MUST NOT 加入用户资料 / 关于 / 反馈 / 登录等任何其它入口（用户 2026-11-25 明令「我说了要哪些就是哪些」）。两项 SHALL 复用现有管理页与 `App` 的 `panel` 状态（`setPanel('providers' | 'templates')`），MUST NOT 新写管理屏或第二条管理路由；管理页 SHALL 只覆盖主区，左栏保持可见可点（沿用「会话列表常驻左侧与主区切换」）。点菜单项后菜单 SHALL 关闭并打开对应管理页；菜单打开时点菜单外或按 `Escape` SHALL 关闭菜单并把焦点还给按钮；菜单已打开时再次点按钮 SHALL 关闭菜单。

按钮 SHALL 是真实 `button`，带 `aria-haspopup="menu"` 与反映开合态的 `aria-expanded`；菜单 SHALL 带 `role="menu"`，两项 SHALL 是 `role="menuitem"` 的可聚焦控件。管理入口 SHALL 全页唯一：不得在其它界面另设 Providers / 模板入口（旧入口的撤除见 `web-chat-screen` 的「单聊头部不承载管理入口」）。

#### Scenario: 群聊下打开模板配置

- **WHEN** 当前会话是群聊，用户点左栏底部的「设置」再点「模板配置」
- **THEN** `TemplatesPage` 覆盖层打开且只盖住主区，左栏仍可见、仍可点；菜单已关闭；群视图不因打开管理页而卸载或重置

#### Scenario: 单聊下打开 Provider 配置

- **WHEN** 当前会话是单聊，用户点左栏底部的「设置」再点「Provider 配置」
- **THEN** `ProvidersPage` 覆盖层打开；关闭后回到打开前的会话，标题与消息不变

#### Scenario: 菜单恰好两项且没有别的入口

- **WHEN** 用户点开全局设置菜单
- **THEN** 菜单项恰好 2 项，文字逐字为「Provider 配置」「模板配置」，每项带图标；菜单里没有用户资料 / 关于 / 反馈 / 登录或任何第三项

#### Scenario: 没有选中会话时入口仍在

- **WHEN** 用户删掉最后一条会话、主区是空聊天屏
- **THEN** 左栏底部「设置」按钮仍可见可用，点开仍是两项；打开 / 关闭管理页不报错

#### Scenario: 菜单开合与键盘

- **WHEN** 菜单打开时按 `Escape`，或点菜单外区域；或用户连续点两次设置按钮
- **THEN** 菜单关闭（`Escape` 后焦点回到设置按钮；第二次点按钮也是关闭），页面不留下不可关闭的浮层

#### Scenario: 单聊与群聊切换入口不消失

- **WHEN** 用户在单聊与群聊之间来回点选
- **THEN** 设置按钮始终在左栏底部（用户头像块上方）、位置与可用性不变，两个菜单项仍都能打开对应管理页
