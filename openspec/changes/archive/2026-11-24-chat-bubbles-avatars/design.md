## Context

现状（本变更前）：

- **群聊公开时间线**（`web/src/group/GroupView.tsx`）是 `<ul>` 里的全宽 `<li>` 卡片：作者名一行（「用户」或成员名）+ 正文，谁说的只靠名字文字区分；
- **单聊消息**（`web/src/components/MessageList.tsx`）是左对齐/`ml-auto` 的卡片，带「You」「Assistant」大写标签；
- **右侧成员卡片**把 `effective`（生效工具清单 + 思考模式/强度）直接摊在卡面上，「覆盖层」「移除」两个按钮也直接排在卡面；
- **没有头像**：任何地方都画不出"谁在说话"。

可复用件：

- `attachment.upload` / `attachment.read`（`lib/core/headless_core.dart`）：大小上限 `kMaxImageBytes`（32 MiB，出处 `Docs/DeepSeekAPIDoc.md` §6.4.3）、类型判定 `probeImageBytes`（文件头魔数），`attachment.read` 只允许读注入的附件目录内文件，并返回 base64；
- web 的聊天图片走 **`attachmentDataUrls`（路径 → data URL，按路径去重、失败置 `null`）** 这一条既有链路：浏览器拿不到 `~/.aliasagent/attachments/` 下的文件，头像必须走同一条路径；
- `template.list` 返回模板完整 JSON（`{...toJson(), name}`），`config.get` 返回脱敏配置；
- `group.view` 逐成员返回该成员本次运行内最近一次真实发出的快照（含 `windowTokens` 与 `breakdown`），且 `App.loadGroup` **已经**逐成员拉取并存在四态缓存 `groupSnapshots` 里；
- web 侧 `ContextRing`（复用 `web/src/chat/ring.ts` 的 `ringSegments` 口径与 `arcPath` 实心扇形）与 `RealContextView`；
- 设计令牌 `web/src/tokens.ts`（与 `index.css` 的 `@theme` 由 `tokens.test.ts` 逐项比对；其 `guardedSourceFiles()` 目前只扫 `components/`、`group/`、`layout/`、`App.tsx`）、`layoutConfig`；
- 既有 e2e 夹具：`web/e2e/layout.mjs`（测试挂架，真实布局）、`web/e2e/group.mjs`（真实 `web/dist` + 假核心，支持 `GROUP_SHOT` / `GROUP_SHOT_MEMBERS` 截图，以及 `groupViewDelay` / `groupViewFail` / `__gate_member_stream` 三个夹具）。

硬约束（本变更必须绕开的既有判据）：

- **`web/e2e/group.mjs` 用例 8.6** 用 `document.querySelector('[data-testid="context-ring"]') === null` 断言「成员视图里没有快照的成员不渲染环」；因此成员卡片的紧凑环 MUST NOT 复用 `context-ring` 这个标识（见 D6）。
- **`tokens.test.ts` 的「组件禁裸 hex / 禁任意 Tailwind 值」只扫 `guardedSourceFiles()` 列出的目录**；新增头像组件目录必须被加进该清单，否则守卫形同虚设。
- **`group.mjs` 用例 8.4** 依赖 `member-edit-<id>`（点开编辑）、`override-editor-<id>`（面板存在）、`effective-<id>`（面板里的生效结果）三条标识；本变更只改"这些入口长什么样"，不改这三条标识（见 D5）。
- **`group.mjs` 用例 8.4 / 8.5 / 8.6 / 1.2 与 `R.2`** 依赖 `member-name-<id>`（成员名节点），本变更 MUST 保留。

## Goals / Non-Goals

**Goals:**

- 每个「说话的人」（用户、群成员、单聊的 agent、模板）都有稳定、可辨认的头像：默认纯前端生成的身份图案，可上传覆盖；头像图片**经 `attachment.read` 换成 data URL** 再渲染（绝不把绝对路径塞进 `<img src>`）。
- 群聊与单聊统一成聊天式气泡：用户靠右（绿气泡 + 头像在右）、成员/agent 靠左（头像 + 名字 + 气泡）。
- 群聊右侧成员卡片一眼给出「谁在工作」与「占了多少上下文」，并把模板/工具/提示词/思考强度/移除全部收进一个齿轮面板；卡面不再有工具长列表与思考强度文字。
- 头像字段可持久（模板字段 + 用户配置字段），保存时整份写回、不丢其它配置段。
- 所有新行为都有能在坏掉时变红的测试，且文档同 change 同步。

**Non-Goals:**

- **Flutter 桌面聊天屏不在本变更**：本变更说的"单聊气泡"只指 web 客户端；Flutter 侧仍按既有规范，不加头像、不改气泡。
- 不改数据库结构：成员头像取所属模板的字段，`group_members` 不加列、不加迁移。
- 不改 `group.list` / `group.view` / `template.list` 的载荷语义（`config.get` 只**多**返回一个 `profile` 字段）。
- 不做头像裁剪/缩放/压缩、不做头像图库、不做 Gravatar 之类外部服务；**不做成员级头像角标**（同一模板多成员共用上传图时靠名字区分，见 D2）。
- 不做消息时间戳、不做用户昵称、不做成员排序/搜索。

## Decisions

### D1 身份图案：FNV-1a 32 位 → 5×5 横向镜像网格 + 三档派生色

- **网格 5×5、左右镜像**：这是 GitHub 身份图案（identicon）的公开惯例——5×5 方块、左右对称，认得出是"身份图案"而不是随手画的装饰图。左侧 3 列 × 5 行 = 15 个独立格（行优先编号 0..14），右侧 2 列镜像得到（列 3 = 列 1、列 4 = 列 0）。
- **哈希**：`h = fnv1a32(种子)`。FNV-1a 是公开的通用字符串哈希，标准实现十几行，确定性、跨平台一致，不引库。实现已用公开测试向量核过：`'' → 0x811C9DC5`、`'a' → 0xE40C292C`、`'foobar' → 0xBF9CF968`。
- **填色规则**：第 i 格填色当且仅当 `h` 的第 i 位为 1（`(h >>> i) & 1`）。
- **颜色索引**：`(h >>> 0) % 3` —— 必须先转无符号再取模。JS 的位运算结果是**有符号** 32 位，`h` 最高位为 1 时 `h % 3` 会得到负数（例如 `'local-user'` 的 `h = 0x9D2CCBAC`，有符号值是 −1658008660，`−1658008660 % 3 === −1`），负数下标取到 `undefined` 会让图案掉色。**golden 向量**（测试里写死，实现改动必须同时改 golden 并说明）：

  | 种子 | `h` | 颜色索引 | 15 位掩码（b0..b14，行优先） |
  |---|---|---|---|
  | `local-user` | `0x9D2CCBAC` | 0 | `001101011101001` |
  | `m-1` | `0x273835DA` | 0 | `010110111010110` |
  | `general` | `0x24B9216B` | 1 | `110101101000010` |

- **颜色**：`avatarTints = ['#38BDF8', '#D338F8', '#F87338']`——第 0 档就是 `palette.accent` 本身（不写换算值，保持单一事实源），另两档是 accent 的 HSL（实测 `H=198.44° S=93.2% L=59.61%`）色相 +90° / +180°、饱和度与亮度不变。颜色因此是从既有 accent 令牌**派生**的，不是凭感觉挑的三个十六进制；且**不用**语义色（`ok` / `warn` / `danger`），免得头像的红绿与状态点混淆。三档写进 `tokens.ts` 与 `index.css` 的 `@theme`（`--color-avatar-tint-0/1/2`），由 `tokens.test.ts` 的 `pairs` 逐项比对。
- **类名必须是字面量**：填色用固定字面量数组 `['fill-avatar-tint-0', 'fill-avatar-tint-1', 'fill-avatar-tint-2']`，MUST NOT 用 `` `fill-${token}` `` 拼接——Tailwind 只扫描源码里的字面量类名，拼出来的类会被裁掉、图案变空白。
- **几何**：SVG 用**整数单位坐标系** `viewBox="0 0 5 5"`，每格边长 1，宽高按 `size` 缩放（`width={size} height={size}`）——24/32 都不是 5 的整数倍，用整数单位让浏览器按 5 个等宽格排布，避免自己算小数格宽再累积误差。不声称 `shape-rendering` 能"消除毛边"（缩放后抗锯齿仍在）；只保证格子边界落在整数单位上。
- **纯函数**：`web/src/avatars/identicon.ts` 只产出 `{seed, size}` → 5×5 填色矩阵（含镜像映射）+ 颜色索引，组件只负责画 `<rect>`。空种子按空串处理（固定图案，不抛错）；种子取原样字符串（不 trim、不改大小写），保证"同 id 永远同图案"。
- **确定性边界**：图案只由种子决定，与主题、字号、成员显示名无关。

### D2 头像存储、字节链路与优先级

| 实体 | 默认（身份图案种子） | 上传覆盖来源 |
|---|---|---|
| 群成员 | 成员 id（`group_members.id`） | 该成员所属模板的 `agent_types.<模板>.avatar_path` |
| 用户 | `profile.userId`（缺省由核心填 `kDefaultUserSeed`） | `profile.avatar_path` |
| 单聊的 agent | 会话 id | 该会话模板的 `avatar_path` |
| 模板（模板页预览） | 模板名 | 该模板的 `avatar_path` |

- 成员用**成员 id** 做种子（不用显示名）：与既有「改名不改变历史归属」同一语义，改名后头像不变。
- 单聊 agent 用**会话 id**（不用模板名）：会话改名不改 id；同一模板可能被多个会话用，用模板名会让这些会话头像完全相同；删除模板后历史会话也不该换脸。
- 模板页预览用**模板名**做种子：模板名创建后不可改，天然稳定；预览不需要"某个会话"的身份。
- **字节链路（P0 修订）**：头像字节统一由 **App 层**解析：路径 →（去重缓存）`attachment.read` → data URL；失败（文件被删/移走/越权）缓存 `null`。这与聊天图片的 `attachmentDataUrls`（`Record<path, dataUrl | null>`，按路径去重、失败置 null）是**同一个模式**，实现上并入同一份缓存或并列一份同形态缓存。**即使 `GroupView` 自己持有 `client: CoreClient`，头像字节也不在组件里发**——组件保持纯展示，四个调用点（单聊、群聊、侧栏、模板页）共用同一份去重缓存，同一张头像只请求一次。组件层 `Avatar` 只接收 `{dataUrl: string | null, source}`：有 dataUrl 画 `<img src={dataUrl}>`，没有画身份图案。**MUST NOT 用 `<img src="C:\\…">`、`file://` 或任何绝对路径**——静态服务拒绝 web 根外文件，浏览器拿不到。
- **回落**：取不到字节就画身份图案，并让 `data-avatar-source="identicon"` / `data-avatar-source="upload"` 在 DOM 上可观察；不弹错误横幅（装饰性资源），文档「已知限制」写明。
- **同一模板多成员共用上传图**：头像会一样。本变更**不加**成员级角标或 seed 叠加（那会把"头像"变成"身份标签"，用户没要）；区分靠**名字**（群聊气泡上方有名字、成员卡片有名字），规范里把"多成员靠头像 + 名字区分"写成带条件的断言：模板无上传图时图案本身不同，有上传图时靠名字。
- **`kDefaultUserSeed` 落点**：`lib/models/user_profile.dart` 的 `static const String kDefaultUserSeed = 'local-user'`。`config.get` 返回的 `profile` 除原始 `userId` 外再给一个 **`identitySeed`**（= `userId ?? kDefaultUserSeed` 的实际生效种子），web 端不必复制这个常量、也不会两处漂移。
- 头像数据来源不改任何 RPC：模板 `avatar_path` 从 `template.list`（已返回模板完整 JSON）建映射；用户头像从 `config.get` 的 `profile` 读。

### D3 上传通道、字段写回与三态语义

- **上传复用** `attachment.upload`（同一套上限与文件头魔数判定），**读回复用** `attachment.read`；路径存**绝对路径**（与 `attachment.upload` 返回值一致），不复制文件、不建第二个附件目录。
- **两个方向的三态必须分开写（P0 修订）**：
  - **配置读取侧**（`AgentTypeConfig.fromJson` / `AppConfig.fromJson`）：字段缺席 ⇒ 静默"无覆盖"（不打印日志）；字段存在但不是字符串、或是空串/纯空白 ⇒ 读作"无覆盖"并打印一行日志点名原始值。用户配置里出现空串是手误，不是"清除指令"。
  - **模板保存参数侧**（`template.save` 的 `avatarPath`）：字段省略或显式 `null` ⇒ **不改**（沿用既有值）；`''` ⇒ **清除**；非空字符串 ⇒ 设为该路径；其它类型 ⇒ `-32602` 拒绝。
  - **写头像 RPC**（`profile.save` 的 `avatarPath`）：**必填字符串**；`''` ⇒ 清除；非空 ⇒ 设为该路径；省略 / `null` / 其它类型 ⇒ `-32602`（它是一次写操作，不允许"什么都不写"却返回成功）。
  - 两侧终态一致（配置里没有键 = 无覆盖），但**入口规则不同**，实现与测试都不许混用。
- **新增模板不继承头像（P1 修订）**：`template.save` 新增模板时省略 `avatarPath` ⇒ 该模板**没有头像**，MUST NOT 沿用 `general` 或任何既有模板的头像（`AgentTemplateController.validate` 里"新模板从 base 继承缺省字段"的那条路径必须把头像排除在外）。
- **路径校验（P0 修订）**：`avatarPath` 非空时，核心 SHALL 用 `p.normalize(p.absolute(attachmentsDir))` 与 `p.normalize(p.absolute(path))` 判定是否在目录内（`fileAbs == dirAbs || p.isWithin(dirAbs, fileAbs)`，复用 `_handleAttachmentRead` 的同一写法；**禁**字符串前缀比较，`C:\\a\\att` 会误容 `C:\\a\\attacker`），再用 `File(fileAbs).isFileSync()` 确认是**文件**而不是目录；任一不满足 ⇒ `-32602`，错误文本点名「头像」字段与出问题的路径。
- **用户头像写盘不变量**：`profile.save` 先 `_readLatestConfig()` 再 `copyWith(profile: …)` 最后 `ConfigService.save` 整份写回；因此它**不需要** `applyConfig`（用户资料不参与 resolver / 模板注册）。这条不变量要写成代码注释与测试断言：即使内存里有一份旧配置快照，写盘也不能盖掉别人刚写进去的 provider/模板。
- **读取**：`config.get` 增加 `profile: {avatarPath, userId, identitySeed}`（路径可回显，无密钥风险）。
- **注册**：`profile.save` 进 `kCoreRpcMethodNames`（`_registerMethods` 漏实现抛 `StateError` 的既有守卫）与用户文档 RPC 表（`web_management_docs_test` / `web_core_docs_test` 会红）。
- **校验双保险**：即便调用方传别处路径，`attachment.read` 本身也拒绝附件目录外文件；`profile.save` / `template.save` 的前置校验只是让错误更早、更可归因。

### D4 气泡与头像组件：单聊与群聊共用

- 新增 `web/src/components/Avatar.tsx` 与 `web/src/components/MessageBubble.tsx`。
- **标识落点钉死（P1 修订）**：`data-testid="user-message"` / `assistant-message` / `streaming-message` = **整行容器**（含头像那一行），既有用例继续能用；**内层气泡**单独一个元素，`data-testid="bubble"` + `data-bubble-side="user|agent"`，**纯气泡、不含头像**。布局断言只量内层气泡，MUST NOT 量整行容器——整行天然占满宽度，`ml-auto` 改与不改都能绿，量不出东西。
- **对齐只量左缘（P1 修订，2026-11-24 裁决）**：用户侧断言「内层气泡**左缘** > 容器中点」（证它在右半区）；助手侧断言「内层气泡**左缘** ≈ 容器左缘（≤1px）」。**MUST NOT 断言"气泡右缘贴容器右缘"**——用户行最右边是头像 + 间距，气泡右缘本来就不贴容器边；助手侧同名对称问题。**也 MUST NOT 用"气泡宽度 < 容器一半"当对齐判据**：短文本的宽度与侧别无关，而 `max-w-xl`（576）在主区较窄时会超过容器一半，这条判据只会在部分宽度下成立。宽度只有"撑满上限"这一个可测含义，本变更不用它证侧别（左缘判据已经足够）。
- 用户（右）：整行 `flex flex-row-reverse`——气泡在内、头像在**行最右端**（头像之外还有行内间距，气泡右缘不与容器右缘对齐，这是正常的）；成员/agent（左）：头像在左、名字在气泡上方（**只有群聊传名字**，单聊只有一个 agent，名字是噪音）、气泡在右。
- 气泡底色：用户 = `bg-ok/15` + `border-ok/40` + `text-fg`；成员/agent = `bg-surface` + `border-line` + `text-fg`。选低饱和绿填充而不是实心亮绿：暗底长文本用实心亮色刺眼，而暗底上的绿调填充仍是明确的"绿气泡"；颜色令牌不新增（`ok` 即 `palette.success`）。
- 宽度上限沿用现有类（用户 `max-w-xl`、助手 `max-w-2xl`），圆角 `rounded-card`（= `radii.card`）。
- **单聊** `MessageList`：`user` → 右气泡 + 用户头像 + 既有附件缩略图/提示（`attachment-thumbnail` / `attachment-not-sent` / `attachment-missing` 三个 testid 与文案不动）；`assistant` / `streaming` → 左气泡 + agent 头像；`indicator`（「正在生成…」）保持纯文本，不配头像（它不是一条消息）；删掉「You」「Assistant」大写标签。
- **群聊** `GroupView` 时间线：`author === null` → 用户右气泡；否则成员左气泡（头像 + 名字 + 气泡）。保留 `data-testid="timeline-item"` 与 `data-seq`（既有 e2e 逐条比对 seq），新增 `data-bubble-side` 与 `data-avatar-source`。
- 两处共用同一份气泡与头像组件，"心智一致"由实现共享保证，而不是两套看起来像的实现。

### D5 成员卡片：头像 + 状态点 + 紧凑环 + 齿轮面板

卡面结构（一行）：

```
[头像 32px] [名字 + 状态点 8px]            [紧凑环 32px] [齿轮 ⚙]
（齿轮展开的面板：模板下拉 / 工具子集 / 提示词追加 / 思考强度 / 生效结果 / 保存 / 移除）
```

- **状态点**：`running` = 8px `bg-ok` 圆点 + Tailwind `animate-pulse`；`idle` = 8px `bg-muted`。判定：`streamingMembers` 含该成员 id，或（`streamingMembers` 为空且 `group.runningMemberId === id`）→ running；否则 idle。成员间隙 `runningMemberId` 为 null 时按空闲显示（不猜）。`prefers-reduced-motion: reduce` 下脉冲停（`index.css` 里针对状态点类关动画）。圆点带 `title` 与 `aria-label`（「运行中」/「空闲」），运行中不得只靠颜色表达。
- **正在反应的既有可见文本**：`data-testid="member-streaming-<id>"` 保留（既有 e2e 与读屏都依赖），改为状态点旁的 `sr-only` 文本「正在反应…」。
- **紧凑环（见 D6）**：`data-testid="member-ring-<id>"`，只画环、不常驻数字；悬停或键盘聚焦弹浮层 `member-ring-detail-<id>`。
- **环的数据来源**：`App.loadGroup` 已逐成员拉 `group.view` 并存在四态缓存里，成员卡片直接读同一份：`ok` 且 breakdown 非空才画三瓣；`ok` 但三段都为 0 时**仍画轨道底环**（不是空白盒）；`loading` 画骨架占位；`empty` / `error` 画「—」占位并用 `data-ring-state` 标出。**不许画空环冒充零占用**（沿用既有「没有 breakdown 不画环」的口径）。
- **齿轮面板**：齿轮按钮沿用 `data-testid="member-edit-<id>"`（它本来就是"编辑成员"的入口），带 `aria-expanded` / `aria-controls`；展开的面板沿用 `data-testid="override-editor-<id>"`，内部沿用既有 testid：`tool-<id>-<tool>`、`append-<id>`、`effort-<id>`、`member-save-<id>`、`member-remove-<id>`、`member-name-<id>`（成员名节点仍在卡面），并新增模板下拉 `member-template-<id>` 与生效结果行 `effective-<id>`。**保存后不自动收起面板**（用户要能立刻在面板里看到新的生效工具与思考强度；也让既有 e2e 8.4 不必改判据）。
- **改模板**：保存时 `group.member.update` 的 payload 要带 `templateName`（现在 `saveOverrides` 只发 overrides，模板下拉会成摆设）；核心侧 `group.member.update` 已支持改模板并重建实例。
- **已移除成员（P1 修订）**：齿轮**仍可打开**，面板以**只读**呈现（模板/工具/提示词/强度控件禁用，保存与移除带 `aria-disabled="true"` 且点击不发起 RPC），面板里显示它移除前的生效结果；MUST NOT 让入口整个消失（否则历史成员的配置无从核对）。
- **卡面隐藏**：`effective` 长列表与「思考：…」不再在卡面出现，只在齿轮面板里；卡面按钮只剩齿轮（「覆盖层」「移除」两个卡面按钮删除，功能并入面板）。
- **命中高度**：齿轮、头像上传、换头像/恢复默认等新控件的可点高度沿用既有 ≥24px 判据（出处：`spacingScale` 的 24，既有 e2e 已对 `member-add` 等控件断言 ≥24px）。

### D6 紧凑环的几何：donut 描边环（不是实心扇形）

- **不用 `arcPath`**：现状 `web/src/chat/ring.ts` 的 `arcPath` 产出的是**实心扇形**（`M center L A … Z`，从圆心出发）。紧凑环必须是**甜甜圈**：一圈有宽度的描边环 + 空心的中心。所以紧凑环用同心 `<circle>`：`stroke-dasharray = 该段占比 × 周长`、`stroke-dashoffset` 依次累加，`transform="rotate(-90 cx cy)"` 让起点在 12 点。`arcPath` 只服务默认 120 的完整环（保持现状，不动它）。
- **铺底轨道环常驻**：先画一个整圈 `<circle>` 轨道（`stroke-line`），再叠三瓣；三段都为 0 时只剩轨道环——**不许留空白盒**（与 `context-occupancy-ring` 的「三段都为零时仍然是环」同一精神）。
- **百分比口径的边界（2026-11-24 归档裁决）**：`context-occupancy-ring` 的「环旁 SHALL 始终显示百分比」**只约束 Flutter 桌面输入行旁那只完整环**（该能力原 Purpose 说的就是那只）。**web 的两只环都不强制百分比**：web 的完整环（成员视图标签内）保持现状——旁置「对话 / 窗口 tokens」与三瓣图例，没有百分比；紧凑环只画环，悬停/聚焦浮层给 **tokens 详情**（对话 / 窗口、三瓣 tokens、系统+工具固定开销），不要求百分比。这样既不改 web 完整环的现状外观，也不让紧凑环凭空多出一个新的百分比口径。
- **描边宽与留白按 size 等比派生**：以默认 120 环的实测几何为基准——外径占容器 `(2×50)/120 = 83.3%`（留白 `RING_PADDING = 10`，即现状 `120/2 − 50`）。紧凑环取 `padding = size × 10 / 120`、`strokeWidth = size × 10 / 120`（同一比例），`r = size/2 − padding − strokeWidth/2`。这样 32 环的"环外径 / 容器边长"与 120 环一致，并由一条断言守住两种尺寸的比例差 ≤ 1px（**不是**两套硬编码几何）。这条断言的可失败落点在 vitest：`ringGeometry(size)` 纯函数先红（见 D9 与 tasks 5.1）。
- **标识边界（P0 修订）**：紧凑环 `data-testid="member-ring-<id>"`，MUST NOT 输出 `context-ring`；**完整环（成员视图标签内）仍是 `context-ring`**。原因：`group.mjs` 8.6 用 `context-ring === null` 断言"没有快照的成员不渲染环"，紧凑环若也叫 `context-ring`，成员卡片一渲染该断言就假红。
- **类名（P0 修订）**：现有完整环用 `SLICE_CLASSES = ['fill-accent','fill-ok','fill-muted']`——那是 `fill-*`（实心填充），**不能**拿来画描边；紧凑环用 `stroke-accent` / `stroke-ok` / `stroke-muted` 三个字面量类（同一组颜色令牌，不新增颜色）。
- **悬停/聚焦详情**：`member-ring-detail-<id>` 给出「对话 X / 窗口 Y tokens」、三瓣逐项数字、系统+工具固定开销；数字只从 `ringSegments` 取（**不复制公式**）；Escape / 失焦关闭；`aria-describedby` 关联。

### D7 尺寸与令牌来源（不发明新魔数）

| 用途 | 取值 | 出处 |
|---|---|---|
| 气泡内头像 | 24 px | `spacingScale` 的 24（= 正文字阶 `base` 的行高 24，与单行文本等高） |
| 成员卡片头像 / 紧凑环 | 32 px | `spacingScale` 的 32 |
| 状态点直径 | 8 px | `spacingScale` 的 8 |
| 气泡圆角 | 8 px | `radii.card` |
| 气泡宽度上限 | `max-w-xl` / `max-w-2xl` | 现有组件类名（576 / 672 px），不新增数字 |
| 头像颜色 | `avatarTints` 三档 | D1：第 0 档 = `palette.accent`，另两档色相 +90° / +180°（S/L 不变），`tokens.ts` + `index.css` 同步 |
| 身份图案坐标系 | `viewBox="0 0 5 5"`、格宽 1 | D1（5×5 整数单位，按 size 缩放） |
| 环留白 / 描边宽 | `size × 10 / 120` | D6（现状 120 环 `120/2 − 50 = 10` 的比例） |
| 脉冲动画 | Tailwind `animate-pulse` | 既有工具类，不自造时长 |
| 新控件命中高度 | ≥ 24 px | `spacingScale` 的 24；既有 e2e 已对 `member-add` 等控件断言 ≥24px |

### D8 状态、字节与错误的只读来源

- 只读：`group.list` 的 `busy` / `runningMemberId`、`agent.streaming` 的 `memberId`、`group.chain`。**不新增**字段、不改请求形状。
- 断线重连后 `streamingMembers` 为空，但 `busy` / `runningMemberId` 仍在（既有语义）→ 状态点靠回退不出现「链在跑而全员空闲」；链在成员间隙 `runningMemberId` 为 null，显示全员空闲（不猜）。
- 头像数据的两次读取（`template.list` 建映射、`config.get` 读 `profile`）失败时：头像一律身份图案，**不阻断**群视图/单聊加载；但 `config.get` 的失败本身要有一个**可见**出口（侧栏用户头像块显示「头像资料读取失败：…」并可重试），MUST NOT 静默把失败当成"没有头像"。
- `attachment.read` 失败 → 该路径缓存 `null` → 该头像回落身份图案；同一路径不重复请求（去重缓存）。

### D9 测试策略（先红后绿，分层取最便宜的一层）

| 层 | 路径 | 覆盖 |
|---|---|---|
| web 纯逻辑（vitest） | `web/src/avatars/identicon.test.ts` | golden 向量（`local-user` / `m-1` / `general` 三组 h、索引、掩码）、同种子同图案、左右镜像、换种子变图案、空种子不抛、高位置 1 的种子索引仍落在 0..2（`>>>0` 回归） |
| web 纯逻辑（vitest） | `web/src/avatars/resolve.test.ts` | 上传覆盖 > 身份图案、来源标记、缺路径回落、无 userId 时用 identitySeed |
| web 纯逻辑（vitest） | `web/src/group/cards.test.ts` | 成员状态（running/idle/间隙）、环状态映射（ok/loading/empty/error、0 占用仍画轨道）、环几何比例（`ringGeometry(120)` 与 `ringGeometry(32)` 的"外径/容器边长"差 ≤ 1px）、面板字段清单 |
| web 令牌守卫（vitest） | `web/src/tokens.test.ts`（改） | `pairs` 加 `avatarTints` 三档；`guardedSourceFiles()` 加 `src/avatars`；改一侧 CSS 必红 |
| 真实渲染（puppeteer，测试挂架） | `web/e2e/layout.mjs` | 单聊：用户内层气泡**左缘 > 容器中点**、助手内层气泡左缘 ≈ 容器左缘（只量左缘，不量右缘/宽度）、头像在正确一侧、无「You/Assistant」、上传图 `<img src=dataUrl>` 真显示、**删文件后回落身份图案**（与群聊对等）；管理屏：模板页头像上传、侧栏用户头像换/恢复走 `profile.save`、`config.get` 失败显示可归因提示；新增截图开关供视觉验收 |
| 真实应用（puppeteer，真实 `dist` + 假核心） | `web/e2e/group.mjs` | 群聊气泡左右（只量左缘）+ 头像、成员卡片头像/状态点/紧凑环（`member-ring-<id>`，且成员视图无快照时 `context-ring` 仍为 `null`）/环悬停浮层（tokens 详情，无百分比）、齿轮面板收纳（工具子集/提示词/思考强度/**模板**/移除）、卡面不再有工具长列表、已移除成员只读面板、同模板同上传图靠名字区分、`GROUP_SHOT` 截图 |
| Dart 集成（真实 IO + 假边车） | `test/integration/web_management_rpc_test.dart` | `template.save` 带头像写回并在 `template.list` 可见；三态（省略/null 不改、`''` 清、非空设、类型错拒绝）；越界/不存在/目录路径拒绝；`profile.save` 写 profile 且 `config.get` 返回 `identitySeed`；`profile.save` 的 `avatarPath` 必填；`config.save` 不抹 profile；先读盘再 `copyWith` 的不变量 |
| Dart 单测 | `test/unit/agent_type_config_avatar_test.dart`、`test/unit/app_config_profile_test.dart`、`test/unit/agent_template_controller_test.dart` | `avatar_path` 解析回落（缺席静默）与写回；`profile` 块缺省不写回、`clearProfile`、整份写回不丢段、字段缺席静默；控制器三态 + 新模板不继承头像 |
| 文档守卫 | `test/unit/{group_docs,web_management_docs,web_core_docs,user_docs,agent_template_docs}_test.dart` | 真实新组件里的文案锚点；RPC 表含 `profile.save` 且 `config.get` / `template.save` 载荷行带 `profile` / `avatarPath`；配置键双向一致（`lib/models/user_profile.dart` 进 `_dartConfigSourcePaths`） |

## Risks / Trade-offs

- **[头像文件被删或移走]** → `attachment.read` 失败 → 缓存 `null` → 回落身份图案（`data-avatar-source="identicon"`），不弹错、不阻断渲染；文档「已知限制」写明。
- **[紧凑环只画环，没有常驻百分比]** → 与 `context-occupancy-ring` 的「环旁始终显示百分比」**不冲突**（2026-11-24 归档裁决）：那条只约束 Flutter 桌面输入行旁那只完整环；web 的完整环维持现状（tokens + 图例、无百分比），紧凑环只画环、悬停浮层给 tokens 详情。本变更给该能力加一条 MODIFIED 把这个边界写死，避免后人把 web 环也套进百分比条款。
- **[紧凑环与完整环抢 testid]** → 紧凑环 `member-ring-<id>`、完整环 `context-ring`；8.6 的 `context-ring === null` 断言保持有效。
- **[同一模板多成员共用上传图]** → 头像相同；规范把「多成员靠头像 + 名字区分」的条件写明（无上传图时图案不同，有上传图时靠名字），本变更不做成员级角标。
- **[成员多时逐成员快照体积]** → 现状 `App.loadGroup` 已经逐成员串行拉 `group.view`，本变更不新增任何拉取；若日后成员规模变大导致卡顿，另立变更做轻量用量字段（本变更刻意不动 RPC 载荷）。
- **[气泡改造让既有 e2e 断言失效]** → 保留 `timeline-item` / `data-seq` / `user-message` / `assistant-message` / `member-name-*` / `member-edit-*` / `override-editor-*` / `effective-*` / `tool-*` / `append-*` / `effort-*` / `member-save-*` / `member-streaming-*` 这些既有判据锚点；只改内部结构与对齐。齿轮面板「保存后不收起」正是为了让既有用例 8.4 继续成立。
- **[身份图案颜色与状态色混淆]** → 头像色只取 D1 的三档派生色，状态点固定 `ok`/`muted`，两者集合不相交；填色类名字面量固定，不拼接。
- **[新增 RPC 漏注册 / 文档漏写]** → `kCoreRpcMethodNames` 与 `_registerMethods` 不一致会抛 `StateError`；文档 RPC 表守卫按同一常量逐行核对。
- **[`profile` 块让旧配置出现无意义 diff]** → 只在有值时写回；旧配置读到 `profile` 缺失即视为"没有头像、用默认种子"，升级不改字节。
- **[回退不是无损的]** → 旧版本**没有**头像字段的解析与写回路径：用旧版本保存一次模板或配置，会把 `agent_types.*.avatar_path` 与 `profile` 块**丢掉**（旧 `toJson` 只写它认识的键，模板保存又整份写回）。回退前先备份 `~/.aliasagent/config.json`；本变更不声称"回退无损"。
- **[`agent-config` 的 Purpose 需要扩写]** → 归档同步 delta 时把它扩成"配置文件里的字段规则（模态 + 模板头像字段 + 用户资料块）"，否则 Purpose 与新增需求不匹配。

## Migration Plan

- 无数据库迁移：成员头像不落库，取模板字段；模板与 profile 都是 `config.json` 的增量键。
- 旧配置：`agent_types.*.avatar_path` 缺失 → 无覆盖，显示身份图案；`profile` 缺失 → 用户头像用常量种子，`config.get` 返回 `{avatarPath: null, userId: null, identitySeed: 'local-user'}`。首次上传时才创建 `profile` 块。
- 回退：撤掉本变更的代码即可；已上传的图片留在附件目录（与既有聊天图片同一命运）。**旧版本保存会丢 `avatar_path` / `profile`（见 Risks）**，回退前备份配置；本变更不承诺无损回退。
- 部署顺序无关：字段只在对应界面动作发生时才写，读侧对缺失一律按默认渲染。

## Open Questions

- 气泡要不要显示时间戳、要不要支持"发送失败重试"角标 —— 本次不做，留给后续变更。
- 是否需要一个「在管理页集中管理头像」的页面 —— 本次只给模板页上传与侧栏用户头像两处入口，够用。
