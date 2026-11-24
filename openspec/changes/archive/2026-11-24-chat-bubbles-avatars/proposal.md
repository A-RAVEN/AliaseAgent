## Why

现在的群聊与单聊都不像聊天软件：消息是全宽行 + 用户名/成员名标签，群里多位成员只靠名字文字区分；右侧成员卡片把「生效工具」长列表与思考强度直接摊在卡片上，而真正要紧的两件事——谁在工作、这个成员占了多少上下文——反而看不出来。用户已确认一套「头像 + 气泡 + 成员卡片」的方案（纯前端生成的身份图案 SVG 样式稿已过目，评语「看起来还行」），本变更把它落成规范、设计与任务。

## What Changes

- **头像（模板级 + 用户级）**：默认头像是 GitHub 式身份图案（identicon）——拿成员 id / 用户标识算哈希，决定 5×5 横向对称网格哪些格填色、用哪种颜色；同一个 id 永远同一图案，改名不影响（id 没变）；纯前端 SVG 生成，不引第三方库、不存图。可选上传覆盖：上传了就用上传图，否则用身份图案；上传复用既有 `attachment.upload`（同一套大小上限与文件头魔数校验），**读回复用 `attachment.read` 换成 data URL 再渲染**（浏览器拿不到附件目录里的绝对路径，禁止把路径塞进 `<img src>`）。
- **头像字段**：模板加头像字段（`agent_types.<名字>.avatar_path`，模板存储、经 `template.save` 写回）；config 加用户头像字段（顶层 `profile` 块）。两者都只在有值时写回，缺省不新增键；「配置读取」与「保存参数」的三态规则分开规定（读取时空串 = 无覆盖；`template.save` 省略/`null` = 不改、`''` = 清除；`profile.save` 的 `avatarPath` 必填字符串）。
- **用户头像入口**：会话侧栏底部一块用户头像（换头像 / 恢复默认），经 `attachment.upload` + 新增的 `profile.save` 写盘；`config.get` 返回 `profile`（含实际生效种子 `identitySeed`），使界面刷新后仍能画出同一个头像。
- **气泡布局（群聊 + 单聊一起改）**：群聊公开时间线改为左右气泡——用户消息靠右（绿气泡、用户头像在右），成员消息靠左（头像 + 名字 + 气泡），多成员靠头像 + 名字区分（模板无上传图时图案本身不同；同一模板共用上传图时靠名字）；单聊同样改为用户右 / agent 左，保持心智一致；不再用全宽行 + 名字标签。
- **右侧成员卡片重设计（群聊）**：头像（身份图案或模板上传图）+ 名字 + 工作状态徽标（运行中绿点带脉冲 / 空闲灰点；数据取自 `group.list` 的 `busy` / `runningMemberId` 与流式事件）+ 小尺寸上下文占用环（**donut 描边环**，只画环、轨道常驻、鼠标悬停/键盘聚焦才看详情：对话/窗口 token 与原文/摘要分瓣，分母是该成员自己的窗口）+ 齿轮 ⚙ 按钮（点开收纳模板 / 工具子集 / 提示词追加 / 思考强度 / 移除；已移除成员的面板只读）。卡片上不再显示生效工具长列表与思考强度文字。
- **环的数字口径说清适用面**：`context-occupancy-ring` 的「环旁始终显示百分比」**只约束 Flutter 桌面输入行旁那只完整环**；web 的两只环都不强制百分比——web 完整环维持现状（对话/窗口 tokens + 三瓣图例），成员卡片的紧凑环把 **tokens 详情**放进悬停/聚焦浮层（不常驻、不换算法、不换分母）。
- **不改的东西**：投影、压缩、调度与既有 RPC 的行为语义一律不动；成员卡片的环直接复用 `group.view` 已返回的窗口与占用拆分（核心对每个成员早已逐成员拉过，本变更不新增拉取、不改 `group.list` 载荷）、不改数据库结构（成员头像取所属模板字段，不新增列）；Flutter 桌面聊天屏不在本变更范围。

## Capabilities

### New Capabilities

无（本变更不引入新能力，全部落在既有能力的规范改动上）。

### Modified Capabilities

- `agent-template-management`：模板字段增加头像（上传 / 清除 / 校验 / 完整写回 / 新增模板不继承），并规定头像缺失时回落身份图案。
- `agent-config`：新增 `agent_types.*.avatar_path` 的读取规则与顶层 `profile` 块（用户头像路径 + 用户标识 + 生效种子）的解析、缺省与写回规则。
- `agent-group-chat`：web 组视图的公开时间线改左右气泡（用户右 / 成员左），右侧成员卡片重做（头像 + 状态徽标 + donut 紧凑环 + 齿轮收纳 + 已移除成员只读面板）。
- `web-chat-screen`：单聊消息改为气泡 + 头像（用户右 / agent 左），与群聊同一套形态；头像字节经 data URL 渲染。
- `web-management-ui`：模板页的头像上传与预览；新增用户头像入口与 `profile.save` RPC（同步进方法清单与文档 RPC 表）。
- `context-occupancy-ring`：把「环旁始终显示百分比」的适用面写死为**Flutter 桌面输入行旁那只完整环**；web 完整环维持现状、紧凑环只在悬停浮层给 tokens 详情（都不要求百分比）。

## Impact

- **web 客户端**（`web/src/`）：新增身份图案与头像解析的纯逻辑模块与其 vitest；App 层的头像路径 → `attachment.read` → data URL 去重缓存（与聊天图片的 `attachmentDataUrls` 同一模式）；`MessageList`（单聊气泡 + 头像）、`GroupView`（群聊气泡 + 成员卡片 + 齿轮面板）、`TemplatesPage`（模板头像上传）、侧栏（用户头像块）、`ContextRing`（可选尺寸、小尺寸走 donut 描边）、`tokens.ts` 与 `index.css`（`avatarTints` 三档同步，`guardedSourceFiles` 补 `src/avatars`）、`protocol.ts`（`Profile`、`ConfigGetResult` 与头像字段）。
- **Dart 侧**（`lib/`）：`AgentTypeConfig`（`avatar_path` 解析与写回）、新增 `UserProfile` 模型（`lib/models/user_profile.dart`，含 `kDefaultUserSeed`）与 `AppConfig.profile`、`AgentTemplateController`（草稿四态与校验，新模板不继承头像）、`lib/core/headless_core.dart`（`profile.save` 注册、`config.get` 带 `profile`/`identitySeed`、`template.save` 接受头像并做附件目录/文件校验、`kCoreRpcMethodNames` 同步）。
- **文档**：`Docs/user-guide/group-chat.md`（气泡 + 成员卡片 + 齿轮 + 环悬停）、`Docs/user-guide/web-core-shim.md`（单聊气泡 + 头像 + RPC 表 `profile.save`）、`Docs/user-guide/web-management.md`（模板头像与用户头像 + RPC 表 + `config.get` / `template.save` 载荷行）、`Docs/user-guide/configuration.md`（`profile` 块与 `avatar_path` / `user_id` 键）、`Docs/user-guide/agent-templates.md`（模板头像字段）；README 功能索引按需同步。
- **测试**：web vitest（身份图案 golden 向量与确定性、头像优先级、令牌守卫、成员卡片判定）、web puppeteer（气泡左右与内层气泡几何、上传图 data URL 真显示、删文件回落、成员卡片状态点与齿轮、环悬停、单聊气泡）、`test/integration`（模板头像与用户头像字段经 RPC 落盘、越界/目录/类型错拒绝）、`test/unit` 文档守卫（RPC 表、配置键、界面文案）。全部按先红后绿推进。
- **不做**：不改数据库结构、不改投影/压缩/调度语义、不改既有 RPC 的请求与响应含义（`profile.save` 是新增方法，`config.get` 只是多返回一个字段）、不给 Flutter 桌面聊天屏加头像。**回退不是无损的**：旧版本保存模板或配置会丢掉 `avatar_path` / `profile` 键，回退前需备份 `~/.aliasagent/config.json`。
