# web 管理屏（会话 / 图片 / 占用环 / Provider / 模板 / 首启向导）

> 对应 change：`web-management-ui`。前置文档：[无头核心与 web 客户端](web-core-shim.md)
> （怎么启动核心、怎么打开页面、RPC 通道与错误码）。本文只说**管理**这一层：在浏览器里
> 做原来必须回 Flutter 才能做的事。

## 这是什么

web 端不再只能聊天：左侧会话栏能新建 / 改名 / 删除 / 切换模板；输入框能贴图片；
上下文快照有占用环与真实上下文视图；顶栏的 `Providers` 与「模板」按钮打开管理页；
**第一次使用（配置文件还不存在）时**，页面直接显示首启向导，不需要先运行 Flutter 应用。

管理与聊天共用同一个核心进程、同一份配置与数据库；核心写盘后**运行中立即生效**（此后
创建或恢复的会话读新配置），不需要重启核心。

## 怎么打开

1. 按 [无头核心与 web 客户端](web-core-shim.md) 启动核心，用浏览器打开回显的地址。
2. 顶部连接状态显示「已连接」后：
   - 左侧栏：**会话列表**常驻，下面是会话管理（下表）；
   - 顶栏 `Providers`：Provider 管理页；
   - 顶栏「模板」：Agent 模板页；
   - 底部输入框：发消息 + 贴图片；
   - 消息区下方的上下文一行：占用环 + 「真实上下文」按钮。
3. **管理入口在单聊顶栏**：群聊打开时顶栏没有 `Providers` /「模板」，要先点回一个单聊。
   管理页**只覆盖主区**，左侧会话列表仍可见可点；打开群聊不会让列表消失。
   **点会话**会关闭管理页并把主区切到该会话（新建会话 / 新建组同样关闭管理页）。
   **删除当前会话会关闭管理页**：从左侧列表删掉当前会话后管理页自动关闭，主区按新会话
   加载或显示空聊天屏；删除**失败不关**（保留管理页并把「删除会话失败」显示出来，
   不掩盖错误）。
4. 如果配置文件还不存在（首启），核心会以空配置启动，页面直接是**首启向导**（见下文）。

## 会话管理（左侧栏）

| 操作 | 怎么用 | 会看到什么 |
|---|---|---|
| 新建 | 点「会话」标题右侧的 + | 立刻出现并选中一条新会话，可以直接发消息 |
| 重命名 | 每行的「改名」→ 内联输入框 → Enter 确认 / Esc 取消 | 空标题被忽略（不会把标题改成空串）；会话不存在时顶部红条显示「不存在」；群聊改名会同步群主区标题 |
| 删除 | 每行的「删除」→ 弹出确认浮层 → 再点「删除」 | 先确认再删；**群聊行**确认后走 `group.delete`（停链、销毁成员实例、成员 / 消息 / 摘要级联删除），**单聊行**走 `session.delete`。删除当前会话后主区按**下一条会话的类型**激活；删到最后一条时是**空聊天屏**。删除进行中切换模板会被拒绝并显示阶段（见下） |
| 切换模板 | 侧栏底部的「模板」下拉 | 成功后该会话之后的对话用新模板；失败时下方红字显示**失败阶段 + 候选模板名**（例如「阶段：会话正在删除，候选 "alt"」），旧实例与数据库不变。**群聊打开时该下拉禁用**并显示「群聊模板由各成员决定」（每个成员的模板来自成员行） |
| 换头像 / 恢复默认 | 侧栏最底部的**用户头像块**：点「换头像」选一张图，点「恢复默认」清掉 | 换头像先上传再保存到用户资料，成功后侧栏与所有用户消息气泡立刻换图（不需要刷新页面）；恢复默认把头像清空、回到身份图案。**头像资料读取失败**（打开页面时 `config.get` 出错）会在这里显示「头像资料读取失败：…」并提供「重试」，聊天屏照常加载，不会把失败当成"没有头像"静默吞掉 |

## 贴图片给模型看

- **怎么贴**：输入框里 Ctrl+V 粘贴剪贴板图片，或点输入框左侧的「图片」按钮选文件。
  选好的图片显示为缩略图，每张右上角有 × 可以移除。可以文字 + 图片一起发，也可以只发图片。
- **上限**：单张图片最大 **33554432 字节（32 MiB）**，这是产品既有常量 `kMaxImageBytes`
  的值，出处 `Docs/DeepSeekAPIDoc.md` §6.4.3「单张图片最大大小」。超限会上传失败并在
  页面显示原因（**不截断、不静默丢图**）。
- **类型判定**：只看**文件头魔数**（PNG / JPEG / GIF / WebP），扩展名与浏览器报的
  MIME 都不作数 —— 和发送期同一套判据。
- **模型没声明看图能力**：模板的 `input_modalities` 里没有 image 时，消息下方会显示
  「图片未发送」提示行（文字照发）。要让它能看图，在模板页勾上 image 模态（下一步的
  模板页）。
- **文件丢了**：历史消息还引用着附件路径、但文件已经不在了时，那条消息下方显示
  「图片已丢失」提示行，不静默空白。
- **为什么不直接给图片 URL**：附件在 `~/.aliasagent/attachments/`，静态服务只服务 web
  构建产物目录，所以浏览器里的图片是经核心的 `attachment.read` 取回的 base64。

## 占用环与真实上下文

- **占用环**：三瓣 = 二级摘要 / 一级摘要 / 原文（顺序固定），每瓣弧度按 token 占窗口
  比例画。**整圈钳制**：三段之和超过窗口时，累加到整圈为止、超出部分不画；三瓣的
  token 数字仍原样显示（数字不是按弧度换算的）。系统提示词 + 工具定义**不在环上**，
  单独一行显示。
- **真实上下文**：点「真实上下文」展开，显示这一步实际发给模型的原始 JSON
  （system / messages / tools），可滚动、可点「复制」。
- 快照里没有占用拆分数据时，会显式写一行说明而不是画一个空环。

## Provider 管理页（顶栏 `Providers`）

- **添加 / 编辑**：点「添加 Provider」或某行的「编辑」。三个字段：名字、网关地址、
  API Key。网关地址必须是 `http://` 或 `https://` 开头的绝对地址。
- **密钥不回显**：列表只显示「已配置（不回显）」，编辑时密钥框是空的；**留空 = 沿用
  原密钥**（改地址不重填密钥不会把密钥弄丢）。密钥明文不会出现在任何接口响应或页面上。
- **改名级联**：编辑时改名字并保存，会**在同一次保存里**改写引用它的模板的 provider
  字段，不会留下悬空引用。
- **删除**：被任何模板引用的 Provider **拒绝删除**，并在该行显示引用它的模板名单。
- **探测**：每行「探测」拉取网关的模型目录并写回（显示新增 / 更新 / 移除 / 丢弃四类
  计数与探测时刻）。**保存成功后会自动探测一次**，不用手动再点。探测失败会显示原因；
  端点不是标准模型目录时还会给出错误落盘路径（完整响应可从那个文件取回）。

## Agent 模板页（顶栏「模板」）

- **列表**：每个模板显示头像、provider、模型、推理强度、输入模态；提供「编辑」「删除」。
- **可编辑字段**：provider、模型（可从 provider 目录选，也可手输）、推理强度（执行层
  合法档位 + 关闭）、系统提示词、工具勾选、上下文窗口覆盖（留空 = 用目录窗口）、
  `input_modalities` 模态勾选（勾 image 才能收图）、压缩阈值与等待阈值（1..100，留空 =
  沿用既有值）、**头像**（见下一条）。
- **模板头像**：编辑器里有头像预览、「选择图片」与「清除头像」。选图先经核心的附件接口
  上传、拿到路径；保存模板时把该路径作为头像提交，重新打开编辑器看到的就是这张图。点
  「清除头像」并保存会把配置里的头像键去掉，预览回到身份图案。**没碰头像的保存不带这个
  字段**（不会因为页面没带上而清空既有头像）；**新增模板不继承**任何既有模板（包括
  `general`）的头像。上传失败会显示可归因错误（点名原因），既有头像不变。
- **从目录选模型会回填**：模型下拉选目录条目后，上下文窗口与模态按目录值预填；之后你
  的修改为准（目录后续刷新不会改已保存的模板）。
- **模板名创建后不可改**：编辑既有模板时名字输入框只读。
- **生效时机**（页面顶部与这句同一口径）：

  > 只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。

  也就是说：改 `thinking_effort` 后，当前会话的下一条消息就用新档位；改模型 / 工具 /
  窗口 / 系统提示词只对**之后创建或恢复**的会话生效，运行中的实例不变。
- **删除**：`general` 模板不可删（新会话默认用它）；被既有会话引用的模板**拒绝删除**
  并显示引用会话名单（防悬空引用）；没被引用的模板删除后从配置与运行中注册表一起移除。
- **未开放编辑的字段原样保留**：保存不会丢掉命令超时、不可压缩要求等界面上没有的字段。

## 首启向导（配置文件不存在时）

1. 配置文件不存在 → 核心以**空配置**启动并 serve 本页（不是拒启动），页面直接是向导。
2. 填 provider 三要素：名字（默认 magpie，可改）、网关地址、API Key。
3. 点「下一步」→ 走**只探测不写盘**的探测：失败会显示原因（含错误落盘路径），且**不会
   留下半份配置**；目录为空时也会明确拒绝继续。
4. 探测成功 → 选模型：默认选中**目录首项**（产品里没有任何写死的模型名），可改。
5. 可选勾上「这个模型能看图」→ 写 `input_modalities` 含 image。
6. 点 Start：写 provider（连同探测到的目录）+ 建 `general` 模板（工具用核心给的默认
   清单）→ 组合根同步 → 页面回到聊天屏，可以直接发消息。

中途放弃（没点 Start）不会写任何文件。

## 管理 RPC 表

所有方法走 `ws://127.0.0.1:<端口>/ws`，JSON-RPC 2.0；错误码只用规范值：
`-32700` Parse error、`-32600` Invalid Request、`-32601` Method not found、
`-32602` Invalid params、`-32603` Internal error。
失败一律返回**可归因**的 `-32602` / `-32603` 错误，不静默失败。

| 方法 | 参数 | 返回 |
|---|---|---|
| `core.ping` | 无 | `{ok, service, protocolVersion, pid}` |
| `session.list` | 无 | `{sessions: [...]}`（顶层会话，按最近更新倒序） |
| `session.create` | `{title?, agentType?}` | `{session}`；`agentType` 必须是已存在的模板 |
| `session.rename` | `{sessionId, title}` | `{session}`；会话不存在 → `-32602` 可归因错误（不静默 no-op） |
| `session.delete` | `{sessionId}` | `{sessionId, deleted:true}`；走 beginDelete/endDelete 守卫，删除进行中的切换被拒 |
| `session.switchTemplate` | `{sessionId, templateName}` | `{sessionId, agentType, templateName}`；失败消息含阶段与候选名 |
| `message.query` | `{sessionId, pageSize, anchor?, cursor?, before?}` | 分页（详见 web-core-shim 文档） |
| `agent.send` | `{sessionId, text, attachments?}` | `{sessionId, status, finalText, error, metering}`；`attachments` 是 `attachment.upload` 返回的路径数组 |
| `agent.cancel` | `{sessionId, memberId?}` | `{sessionId, cancelled, reason?, memberId?, reactionChainStopped?}`；组会话按组路由（链运行中停整条链并回 `reactionChainStopped`，成员在链里排队时 `cancelled:false`） |
| `config.get` | 无 | `{missing, configPath, providers, agentTypes, tools, profile}`；**api_key 永不回显**（只给 hasApiKey）；`profile` = `{avatarPath, userId, identitySeed}`（`identitySeed` 是读取期派生值，不写回配置） |
| `config.save` | `{providers}` | `{config}`；providers 是**整份表**（没提交的现存 provider = 删除），值可带 `api_key`（留空 = 沿用）、`rename_from`（改名级联）、`models` + `discovered_at`（向导写目录） |
| `profile.save` | `{avatarPath}` | `{profile}`；`avatarPath` **必填字符串**：`''` = 清除、非空 = 设成附件目录内一个真实存在的文件；省略 / null / 其它类型 ⇒ `-32602`。整份配置写回（providers / agent_types 原样保留），不参与运行中 Agent 的装配 |
| `provider.probe` | `{providerName}` | 探测报告（新增/更新/移除/丢弃/`discovered_at`），成功写回目录 |
| `provider.probeFetch` | `{providerName?, baseUrl, apiKey}` | 探测结果（**只探测不写盘**，向导用） |
| `group.create` | `{title?, workspace?, reactionsEnabled?, maxRounds?}` | `{group}`；建组并建立组上下文（`reactionsEnabled` 省略 = 新建组开启自发反应；`maxRounds` 省略 / null = 默认 8，范围 1..50） |
| `group.update` | `{groupId, reactionsEnabled?, maxRounds?}` | `{group}`；改组的运行设置（至少一个字段；`maxRounds` 显式 null = 恢复默认；缺字段/类型不对/越界 ⇒ `-32602`，链运行中 ⇒ busy） |
| `group.chain` | `{groupId}` | `{groupId, sessionId, status, triggerSeq, rounds, stopReason, steps}`；当前 / 最近一条链（核心重启后 `idle`） |
| `group.list` | 无 | `{groups:[{...session, reactionsEnabled, maxRounds, busy, runningMemberId, members:[...]}]}`；成员带 `removedAt` / 「overrides」 / 「effective」 |
| `group.delete` | `{groupId}` | `{groupId, deleted:true}`；先停链，级联删除成员/消息/摘要 |
| `group.member.add` | `{groupId, name, templateName, overrides?}` | `{groupId, member}` |
| `group.member.remove` | `{groupId, memberId}` | 软删成员（行保留，先停链） |
| `group.member.update` | `{groupId, memberId, name?, templateName?, overrides?, clearOverrides?}` | 原地改并重建实例（先停链） |
| `group.send` | `{groupId, speaker?, text?}` | `{groupId, sessionId, status, triggerSeq}`；**异步且永不 busy**：写完用户消息后立刻回 `started`（链在后台跑，进度查 `group.chain`）；链/执行器运行中再发也接受（入队/被吸收），不回 `busy`；`speaker` 可选（省略 = 纯触发反应链 / 关闭态按 `@mention` 定向） |
| `group.view` | `{groupId, memberId}` | `{snapshot\|null}`；本次运行内最近一次真实发出的快照（反应轮也算） |
| `template.list` | 无 | `{templates, tools, providers, defaultTools, thinkingEfforts, allowedModalities, effectiveNote}` |
| `template.save` | `{originalName?, name, provider, model, thinkingEffort, systemPrompt, tools, maxContextTokens, inputModalities, compactionThresholdPercent?, compactionWaitThresholdPercent?, avatarPath?}` | `{template, created}`；校验失败消息含字段名；`avatarPath` 三态：省略 / null = 不改、`''` = 清除、非空 = 设成附件目录内的真实文件（类型错 / 越界 / 不存在 / 是目录 ⇒ `-32602`） |
| `template.delete` | `{templateName}` | `{templateName, deleted:true}`；general 不可删、被会话引用拒删（名单在错误消息里） |
| `attachment.upload` | `{filename, base64}` | `{path, bytes, format, mediaType, width, height}`；上限与类型校验见上 |
| `attachment.read` | `{path}` | `{path, bytes, base64, mediaType}`；只允许读附件目录内文件；文件不存在 → 「图片已丢失」可归因错误 |

## 测试

```powershell
# 核心侧：管理 RPC 全链路（临时 configPath / 临时附件目录 / 假 sidecar / 假 probe，不碰用户真实配置、不联网）
flutter test test/integration/web_management_rpc_test.dart

# 文档守卫（RPC 表 / 图片上限常量 / 生效时机常量 / 空配置启动）
flutter test test/unit/web_management_docs_test.dart

# web 侧：纯逻辑 vitest + 管理屏交互 puppeteer（headless Edge）
cd web
npm run test:all
```

## 已知限制

- **本机回环、无鉴权**：管理 RPC 与聊天共用同一条回环 WebSocket，本机信任边界内可接受；
  不要把核心暴露到网络。
- **没有 login / 多用户**：单用户单进程，同一时刻只跑一个核心（单实例锁）。
- **图片只走 base64 RPC**：单张上限见上；一次请求的图片总预算仍是发送期的既有规则
  （超预算的图片会被换成可见的省略说明，不会静默丢）。
- **模板生效时机分两类**：运行中实例的模型 / 工具 / 窗口 / 系统提示词不会因为保存模板
  而改变；要立刻生效请对会话切换模板（会重建实例）。
- **删除模板 / Provider 不会回头清理历史**：被删除的模板名可能还留在旧会话的
  `agent_type` 里——所以删除前有引用守卫；Provider 删除同理。
- **首启向导只建一个 general**：没有多套模板的批量导入；需要更多模板在模板页添加。
