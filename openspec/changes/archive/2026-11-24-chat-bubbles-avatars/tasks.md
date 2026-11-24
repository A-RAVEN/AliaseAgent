## 0. 开工前置核对

- [x] 0.1 核对锚点与夹具（不改产品代码）：打开 `web/src/group/GroupView.tsx`、`web/src/components/MessageList.tsx`、`web/src/components/ContextRing.tsx`、`web/src/chat/ring.ts`、`web/src/tokens.ts`、`web/src/tokens.test.ts`、`web/src/index.css`、`web/src/App.tsx`、`lib/models/agent_type_config.dart`、`lib/models/app_config.dart`、`lib/services/agent_template_controller.dart`、`lib/core/headless_core.dart`、`web/e2e/group.mjs`、`web/e2e/layout.mjs`、`web/test/harness/main.tsx`，把本 change 要复用/必须保住的既有 testid 与常量列成清单贴进执行记录。清单**必须含**：`timeline-item`、`data-seq`、`user-message`、`assistant-message`、`streaming-message`、`member-name-*`、`member-edit-*`、`override-editor-*`、`effective-*`、`tool-*`、`append-*`、`effort-*`、`member-save-*`、`member-remove-*`、`member-streaming-*`、`member-add`、`member-window`、`context-ring`、`ring-*`、`spacingScale`、`radii.card`、`SLICE_CLASSES`（`fill-*`）、`tokens.test.ts` 的 `pairs` 与 `guardedSourceFiles()`、`kCoreRpcMethodNames`、`attachmentsDir`、`kMaxImageBytes`、`attachmentDataUrls`、`user_docs_test.dart` 的 `_dartConfigSourcePaths`；以及本 change 新增的常量落点：`kDefaultUserSeed` → `lib/models/user_profile.dart`、`RING_PADDING` → `web/src/components/ContextRing.tsx`、`avatarTints` → `web/src/tokens.ts` 与 `index.css`。失败判据：清单漏掉上述任一锚点、或把 `context-ring` 与新的紧凑环混成一个名字时，先补清单再开工。

## 1. 身份图案与头像解析（web 纯逻辑，先红后绿）

- [x] 1.1 红：新建 `web/src/avatars/identicon.test.ts`（web vitest 纯逻辑层），用例至少 7 条——①**golden 向量**：`'local-user'` → `h = 0x9D2CCBAC`、颜色索引 0、15 位掩码（b0..b14）`001101011101001`；`'m-1'` → `0x273835DA`、索引 0、掩码 `010110111010110`；`'general'` → `0x24B9216B`、索引 1、掩码 `110101101000010`；②`fnv1a32` 与公开测试向量一致（`'' → 0x811C9DC5`、`'a' → 0xE40C292C`、`'foobar' → 0xBF9CF968`）；③同种子连算两次结果逐项相同；④图案左右镜像（第 3 列 = 第 1 列、第 4 列 = 第 0 列）；⑤换种子变图案；⑥空串种子不抛且图案固定；⑦**无符号回归**：对最高位为 1 的种子（`'local-user'`）颜色索引仍落在 0..2（若实现用有符号 `%` 会得到 -1）。跑 `cd web && npm test` 见红（模块不存在）。失败判据：此时不红、或 golden 值与 design D1 的表不一致时，先对齐再继续。

- [x] 1.2 绿：新建 `web/src/avatars/identicon.ts`：FNV-1a 32 位 + 5×5 横向镜像（15 个独立格，行优先取位）+ `(h >>> 0) % 3` 取色；SVG 用**整数单位坐标系** `viewBox="0 0 5 5"`（格宽 1，按 `size` 缩放），填色类名用**固定字面量数组** `['fill-avatar-tint-0','fill-avatar-tint-1','fill-avatar-tint-2']`（不拼接，Tailwind 扫不到会掉色）。同时在 `web/src/tokens.ts` 与 `web/src/index.css` 的 `@theme` 新增 `avatarTints = ['#38BDF8','#D338F8','#F87338']` / `--color-avatar-tint-0..2`，并在 `web/src/tokens.test.ts` 里**同时**改两处：`pairs` 加三档、`guardedSourceFiles()` 加 `src/avatars`。跑 `cd web && npm test`：identicon 与 tokens 测试都绿。失败判据：只改 `tokens.ts` 不改 `index.css`（或反向）时 `tokens.test.ts` 必须红；把 `src/avatars` 漏在 `guardedSourceFiles()` 外时守卫扫不到新目录、不算完成。

- [x] 1.3 红：新建 `web/src/avatars/resolve.test.ts`，用例至少 4 条——①同时给上传路径与 identitySeed 时返回上传图（`source: 'upload'`）；②只有 identitySeed 时返回身份图案（`source: 'identicon'`）；③上传路径为空串/null 时回落；④来源标记与种子原样透出。跑 `cd web && npm test` 见红。失败判据：此时不红时重写用例。

- [x] 1.4 绿：新建 `web/src/avatars/resolve.ts`（纯函数：`resolveAvatar({entityId, identitySeed, uploadedPath})`，不读文件系统、不做 DOM 判断），跑 `cd web && npm test` 转绿。失败判据：解析函数里出现"文件是否存在"的 IO 判断（那是 App 层字节链路的职责）时算偏离设计 D2。

## 2. 头像字段（Dart 模型与模板控制器）

- [x] 2.1 红：新建 `test/unit/agent_type_config_avatar_test.dart`（Dart 单测层），用例至少 4 条——①带 `avatar_path` 时解析出该路径；②**缺键时不打印告警**、值为 null；③值为数字/对象/空串时回落 null 且有一行日志点名 `avatar_path` 与原始值；④`toJson` 只在有值时写回（缺省模板不含该键）。跑 `flutter test test/unit/agent_type_config_avatar_test.dart` 见红。失败判据：此时不红时重写。

- [x] 2.2 绿：`lib/models/agent_type_config.dart` 增加 `avatarPath`（可选）、解析 + 一次性日志、`toJson` 条件写回，跑 2.1 转绿。失败判据：无头像的模板被写回空键、或每次读配置都打日志时不算完成。

- [x] 2.3 红：新建 `test/unit/app_config_profile_test.dart`（Dart 单测层），用例至少 6 条——①`profile` 带 `avatar_path`/`user_id` 时都读出；②没有 `profile` 键时值为 null、`toJson` 不写该块、**无告警**；③`profile` 不是对象、或字段非字符串/空串时回落并打一行日志；④**字段缺席静默**（只给 `{"user_id":"a"}` 时不因缺 `avatar_path` 打日志）；⑤`copyWith(clearProfile: true)` 能清掉 profile；⑥`toJson` 只在至少一项有值时写块。跑 `flutter test test/unit/app_config_profile_test.dart` 见红。失败判据：此时不红时重写。

- [x] 2.4 绿：新建 `lib/models/user_profile.dart`（`avatarPath` / `userId` / `fromJson` / `toJson` / `isEmpty`，并定义 `static const String kDefaultUserSeed = 'local-user'`）+ `lib/models/app_config.dart` 增加 `profile`、解析、条件写回、`copyWith(profile, clearProfile)`（沿用 `GroupMember.copyWith` 的 `clearOverrides` 先例），跑 2.3 转绿。失败判据：`copyWith` 无法清除 profile（被 `??` 兜住）、或 `kDefaultUserSeed` 散落到别的文件时不算完成。

- [x] 2.5 红：在既有 `test/unit/agent_template_controller_test.dart` 增用例——①草稿 `avatarPath` 为 `null` 时保存既有模板**沿用原值**；②为 `''` 时清除该键；③为非空字符串时写入；④**新增模板**省略头像时不带该键，且**不继承 `general` 的头像**（即使 general 有 `avatar_path`）。跑 `flutter test test/unit/agent_template_controller_test.dart` 见红。失败判据：此时不红时重写。

- [x] 2.6 绿：`lib/services/agent_template_controller.dart` 的 `AgentTemplateDraft` 增加 `avatarPath` 四态（`null` = 不改、`''` = 清除、非空 = 设置），并把"新模板从 base 继承缺省字段"的路径**排除头像**；跑 2.5 转绿。失败判据：新模板把 general 的头像继承过来、或三态被压成两态时不算完成。

## 3. 核心 RPC：模板头像与用户头像落盘

- [x] 3.1 红：在既有 `test/integration/web_management_rpc_test.dart`（集成层，真实 IO + 假边车）增用例——①`template.save` 带 `avatarPath`（临时附件目录里真写一张 PNG）后写盘成功，`template.list` 返回该模板带 `avatar_path`；②`avatarPath: ''` 清除后该键消失；③**省略或 `null` 不改**既有头像；④`avatarPath` 是数字/对象时 `-32602`；⑤指向附件目录之外、⑥目录内不存在的文件、⑦目录内的子目录，三者都 `-32602` 且写盘不变；⑧`profile.save` 写 `profile.avatar_path`，`config.get` 返回该路径与 `identitySeed`；⑨`profile.save` 传 `''` 清除该键；⑩`profile.save` 省略/`null`/数字 → `-32602`；⑪已存在 `profile` 时跑一次 `config.save`（只提交 providers）后 `profile` 仍在；⑫**读盘不变量**：先把一个 provider 直接写进磁盘，再调 `profile.save`，写盘后该 provider 仍在（证明它不是拿内存旧快照整份覆盖）；⑬`kCoreRpcMethodNames` 含 `profile.save` 且注册表与常量一致。跑 `flutter test test/integration/web_management_rpc_test.dart` 见红。失败判据：用例只断言返回值、不断言磁盘上的 `config.json` 时不算数——落盘才是红靶。

- [x] 3.2 绿：`lib/core/headless_core.dart` 新增 `_handleProfileSave`（`avatarPath` 必填字符串；`''` 清除；非空校验在 `attachmentsDir` 内且 `isFileSync()` 为真；先 `_readLatestConfig()` 再 `copyWith(profile: …)` 最后整份写回；不调 `applyConfig` 并把"为什么不调"写成注释）；`profile.save` 进 `kCoreRpcMethodNames` 与 `_registerMethods`；`_handleConfigGet` 的返回加 `profile`（含 `identitySeed`）；`_handleTemplateSave` 接受 `avatarPath` 四态并做与 `_handleAttachmentRead` 同口径的目录/文件校验（`p.normalize` + `p.isWithin` + `isFile`，禁字符串前缀）。跑 3.1 转绿。失败判据：`_registerMethods` 漏实现（抛 `StateError`）、`config.get` 没返回 `identitySeed`、或用字符串前缀比较目录时不算完成。

- [x] 3.3 绿：`web/src/protocol.ts` 新增 `ConfigGetResult` 类型（含 `profile: {avatarPath, userId, identitySeed}`）与模板摘要的 `avatarPath`（可选），让 `web/src/protocol.test.ts` 仍绿；App / TemplatesPage 改用该类型（不再用内联泛型）。失败判据：类型写成必填导致既有夹具编译失败、或只加了 `Profile` 没加 `ConfigGetResult` 时不算完成。

## 4. 单聊气泡与头像（web 纯逻辑 + 真实渲染）

- [x] 4.1 红：在 `web/e2e/layout.mjs`（puppeteer 真实渲染，走 `web/test/harness`）新增「单聊气泡」用例，**先把 testid 落点钉死**：`user-message`/`assistant-message`/`streaming-message` = 整行容器（含头像），内层气泡 `data-testid="bubble"` + `data-bubble-side` = 纯气泡（不含头像）。断言：①用户侧量**内层气泡**：`data-bubble-side="user"` 且其**左缘 > 消息区容器中点**（靠右），**不量右缘贴容器边**（头像 + 间距在它右边，永远贴不上）；②助手内层气泡 `data-bubble-side="agent"` 且**左缘距容器左缘 ≤ 1px**（靠左），不量右缘；③**不写"气泡宽度 < 容器一半"这类判据**（短文本宽度与侧别无关、`max-w-xl` 在窄容器会超过一半，只会在部分宽度成立）；④头像节点在用户行右侧、助手行左侧；⑤页面不存在文案为「You」/「Assistant」的角色标签；⑥头像有 `data-avatar-source`，身份图案的 `data-seed` 等于会话 id；⑦**上传图真显示**：给当前模板一个 `avatar_path` 且 data URL 可解码时，助手头像 `data-avatar-source="upload"`、`<img>` 的 `src` 以 `data:` 开头、可解码且尺寸等于头像令牌值；⑧**删文件回落**（与群聊 5.3⑭ 对等）：假核心对该路径的 `attachment.read` 返回错误时，助手头像 `data-avatar-source="identicon"`、正文与附件照常、无错误横幅；⑨既有附件缩略图与「图片未发送」提示行仍在。同时扩 `web/test/harness/main.tsx` 假数据源：注入 `profile`（含 `identitySeed`）、带 `avatar_path` 的模板，并加 `attachment.upload` / `attachment.read` 假分支（返回固定 1×1 PNG 的 data URL，且支持"指定路径读失败"）。跑 `cd web && npm run build:harness && node e2e/layout.mjs` 见红。失败判据：断言量整行容器、量右缘、或量"宽度 < 一半"时不算数——本任务的红靶是"内层气泡靠哪边"。

- [x] 4.2 绿：新建 `web/src/components/Avatar.tsx`：只接收 `{dataUrl: string | null, source, seed, size}`；有 `dataUrl` 画 `<img src={dataUrl}>`，没有画身份图案；`onError` 时切回身份图案；两种形态都带 `data-avatar-source`。**禁止** `<img src={绝对路径}>` / `file://`。跑 4.1 中与头像来源有关的断言转绿。失败判据：图片加载失败留破图、或组件自己拼路径给 `<img>` 时不算完成。

- [x] 4.3 绿：新建 `web/src/components/MessageBubble.tsx`（`side`、`avatar`、`name?`、`children`；用户 `flex-row-reverse` + `bg-ok/15`/`border-ok/40`；助手 `bg-surface`/`border-line`；圆角 `rounded-card`、宽度上限沿用 `max-w-xl`/`max-w-2xl`），并改 `web/src/components/MessageList.tsx`：`user-message`/`assistant-message`/`streaming-message` 仍落**整行容器**，内层气泡带 `data-testid="bubble"` 与 `data-bubble-side`；保留 `attachment-thumbnail`/`attachment-not-sent`/`attachment-missing` 与既有文案；去掉 You/Assistant 标签；`indicator` 保持纯文本无头像。跑 4.1 转绿，并回归 `node e2e/layout.mjs` 既有布局用例。失败判据：既有 `message-row` 高度/贴底跟随用例变红、或附件提示文案被改时不算完成。

- [x] 4.4 绿：`web/src/App.tsx` 与 `web/src/components/ChatScreen.tsx` 接线：App 建**头像路径 → data URL 去重缓存**（与 `attachmentDataUrls` 同一模式：同一路径只请求一次，失败缓存 `null`，走 `attachment.read`），把用户头像 dataUrl、agent 头像 dataUrl、模板映射、会话 id 传给 `MessageList`/`ChatScreen`（组件层不再持有 `client`）。跑 `cd web && npm run build:harness && node e2e/layout.mjs` 全绿 + `cd web && npm test` 不回归；真实 App 的接线由 5.3 的 group.mjs 用例覆盖。失败判据：`template.list` 或 `config.get` 失败时整个聊天屏不渲染（正确行为是按身份图案渲染、不阻断）时不算完成。

## 5. 群聊气泡、成员卡片与紧凑环

- [x] 5.1 红：新建 `web/src/group/cards.test.ts`（web vitest 纯逻辑层），用例至少 7 条——①`streamingMembers` 含 id 时状态为 running；②`streamingMembers` 为空且 `runningMemberId === id` 时为 running（断线重连回退）；③两者都没有时为 idle（成员间隙不猜）；④快照四态映射到环状态 `ok`/`loading`/`empty`/`error`，只有 `ok` 且 breakdown 非空才画三瓣，`ok` 且三段全 0 仍画轨道；⑤**环几何比例**：`ringGeometry(120)` 与 `ringGeometry(32)` 的"外径 / 容器边长"差 ≤ 1px（同时断言 120 的外径仍是 `2×50`、32 的半径/描边按同一比例派生——**这是 P0-3 比例断言的红任务落点**，先于 5.4 的实现写红）；⑥齿轮面板字段清单恰好是模板/工具子集/提示词追加/思考强度/生效结果/保存/移除这七项；⑦已移除成员的按钮态：面板可开、保存与移除为禁用。跑 `cd web && npm test` 见红。失败判据：此时不红时重写。

- [x] 5.2 绿：新建 `web/src/group/cards.ts` 实现 5.1 的纯函数（含 `ringGeometry(size)`：`padding = size×10/120`、`strokeWidth = size×10/120`、`r = size/2 − padding − strokeWidth/2`、外径 = `2×(r + strokeWidth/2)`），跑 `cd web && npm test` 转绿。失败判据：把状态判定或几何算进组件 JSX（无法单测）时不算完成。

- [x] 5.3 红：在 `web/e2e/group.mjs`（puppeteer，真实 `web/dist` + 假核心）新增用例与夹具（**放在文件末尾 8.x 之后、独立组 id + 结束时清场**，并连跑两遍确认不串味），断言：①时间线里用户 `timeline-item` 的 `data-bubble-side="user"`、**内层气泡左缘 > 主列中点**（只量左缘，不量右缘/宽度）、头像在该行最右；②成员消息 `data-bubble-side="member"`、内层气泡左缘 ≈ 主列左缘（≤1px）、头像在左、名字在气泡上方；③两名成员（模板无上传图）的头像 `data-seed` 分别是两人 id、图案不同；④**同模板同上传图**：两人头像的 `<img src>` 相同、都以 `data:` 开头（`attachment.read` 的 data URL），但两条消息都能按名字归属（DOM 断言两条名字节点）；⑤成员卡片有头像（`member-avatar-<id>` 带 `data-avatar-source`）、状态点（`member-status-<id>` 的 `data-state`）、紧凑环（`member-ring-<id>`）与齿轮（沿用 `member-edit-<id>`）；⑥**成员都没有快照时全页 `context-ring` 数量为 0**（紧凑环不得叫 `context-ring`）；⑦悬停 `member-ring-<id>` 后 `member-ring-detail-<id>` 出现且含「对话」「窗口」与三瓣 **tokens** 数字（**不要求百分比**——web 环不在百分比条款内）；⑧快照 `empty`/`error` 的成员卡片不画三瓣（`data-ring-state` 非 `ok`）；⑨已移除成员：齿轮仍可开、面板只读（保存/移除 `aria-disabled`，点击后 rpcLog 里没有 `group.member.update`/`group.member.remove`）；⑩**改模板**：在面板里换模板并保存，`group.member.update` 的 payload 含 `templateName`，重拉后头像随模板变；⑪卡面不再有 `effective-<id>` 文本与「生效工具：」长列表（它们只在面板里）；⑫`__gate_member_stream` 挂住成员 A 的流式后断言 A `running`、B `idle`，解挂并让链结束后两者都 `idle`；⑬用 `groupViewDelay` / `groupViewFail` 夹具各造一个成员，断言卡片显示 loading/error 占位且不画三瓣；⑭模板设了 `avatar_path` 但假核心的 `attachment.read` 对该路径报错时，该成员 `data-avatar-source="identicon"`。假核心要补 `config.get` 的 `profile`、`template.list` 的 `avatar_path`、`attachment.upload`/`attachment.read`（返回固定 data URL）与 `group.member.update` 对 `templateName` 的处理。跑 `cd web && npm run build && node e2e/group.mjs` 见红。失败判据：断言只读 class 名而不读 `data-bubble-side`/`data-avatar-source`/`data-state`/`data-ring-state`、量右缘/宽度、或新用例插在 8.4/8.6 之前把既有夹具搞脏时不算数。

- [x] 5.4 绿：改 `web/src/components/ContextRing.tsx`：加可选 `size`（默认 120，既有调用零改动）；几何一律走 5.2 的 `ringGeometry(size)` 纯函数（`RING_PADDING` 具名常量，紧凑形态 `padding = size × RING_PADDING / 120`、`strokeWidth = size × 10 / 120`、`r = size/2 − padding − strokeWidth/2`），用**同心 `<circle>` + `stroke-dasharray`/`stroke-dashoffset`** 画 donut（`arcPath` 实心扇形只留给默认 120 环，不动）；紧凑形态先画铺底轨道环（三段全 0 也画），只画环、不画图例与环旁数字，`data-testid="member-ring-<id>"`（**不输出 `context-ring`**），三瓣用 `stroke-accent`/`stroke-ok`/`stroke-muted` 字面量类（**不要**沿用 `SLICE_CLASSES` 的 `fill-*`）。两尺寸的"环外径 / 容器边长"比例断言已在 5.1/5.2 红绿过，这里只消费同一函数、不再另写数字。跑 5.3 中与环有关的断言转绿，并回归 `cd web && npm run build:harness && node e2e/layout.mjs`（默认 120 环外观与 `ring-*` testid 不得变）。失败判据：紧凑环输出 `context-ring`、用实心扇形、三段全 0 时留空白盒、把 fill 类当描边用、或在组件里重算几何而不走 `ringGeometry` 时不算完成。

- [x] 5.5 绿：改 `web/src/group/GroupView.tsx`：时间线换成 `MessageBubble` + `Avatar`（用户右、成员左带头像与名字，保留 `timeline-item` 与 `data-seq`，新增 `data-bubble-side`）；成员卡片重做为「头像 + 名字 + 状态点 + 紧凑环 + 齿轮」，**保留 `member-name-<id>`**；齿轮沿用 `member-edit-<id>`（带 `aria-expanded`/`aria-controls`），面板沿用 `override-editor-<id>` 并装入模板下拉 `member-template-<id>`、`tool-*`、`append-*`、`effort-*`、`effective-<id>`、`member-save-*`、`member-remove-*`；保存时 `saveOverrides` 的 payload 带 `templateName`；保存后**不自动收起**面板；「正在反应…」改为 `member-streaming-<id>` 的 `sr-only` 文本；已移除成员的面板只读（控件 `disabled`、保存/移除 `aria-disabled` 且不发起 RPC）；`prefers-reduced-motion: reduce` 下状态点脉冲停（`index.css`）。跑 5.3 转绿。失败判据：既有 `web/e2e/group.mjs` 用例 8.4/8.5/8.6/1.2/R.2 被改成"少断言"才能过时不算完成——只允许改驱动路径，不允许削弱断言。

- [x] 5.6 绿：`web/src/App.tsx` 把模板头像映射、用户头像 dataUrl 与各成员头像的 dataUrl 一并传给 `GroupView`（模板映射复用 4.4 的同一份状态，头像字节走同一份去重缓存）；`template.list` 或 `attachment.read` 失败时按身份图案渲染且不阻断群视图加载。跑 `cd web && npm run build && node e2e/group.mjs` 全绿。失败判据：群视图加载因头像数据失败而占位/报错时不算完成。

## 6. 用户头像入口与模板页上传

- [x] 6.1 红：在 `web/e2e/layout.mjs`（测试挂架 + 假核心）新增「头像上传」用例：①模板页有 `template-avatar-upload`/`template-avatar-clear`/`template-avatar-preview`；选图后假核心收到 `attachment.upload` 与 `template.save`，且 `avatarPath` 等于上传返回路径；清除后 `template.save` 的 `avatarPath` 为空串、没碰头像的保存**不带**该字段；②侧栏有 `user-avatar-block`/`user-avatar-change`/`user-avatar-reset`；换头像后收到 `attachment.upload` 与 `profile.save`（payload 带路径），恢复默认后 `profile.save` 的 `avatarPath` 为空串；③`config.get` 失败时头像块出现可归因提示（含重试），聊天屏仍渲染。扩 `web/test/harness/main.tsx`：假核心支持 `profile.save`、`config.get` 返回 `profile`（含 `identitySeed`）、`template.list` 带 `avatar_path`、`attachment.upload`/`attachment.read` 假分支，并给侧栏注入一个假 `client`（`UserAvatarBlock` 需要它）。跑 `cd web && npm run build:harness && node e2e/layout.mjs` 见红。失败判据：只断言按钮存在、不断言 RPC payload 或失败出口时不算数。

- [x] 6.2 绿：`web/src/components/TemplatesPage.tsx` 加头像控件（预览、选择文件、清除），上传走 `attachment.upload`、保存时按需带 `avatarPath`（没碰就不带、清除带空串），失败显示可归因错误。跑 6.1 的模板页断言转绿。失败判据：在浏览器里另写一套图片校验去替代核心校验（重复口径）时不算完成。

- [x] 6.3 绿：新增 `web/src/components/UserAvatarBlock.tsx`（头像 + 「换头像」+「恢复默认」+ 读取失败的可见提示与重试），`web/src/components/ChatShell.tsx` 增加 `sidebarFooter` 槽位并渲染在 `<aside data-testid="session-sidebar">` 内；`web/src/App.tsx` 接 `profile` 状态、`loadProfile`（`config.get`）与保存动作（成功后就地更新，不整页刷新；失败走可见提示）。跑 6.1 全绿。失败判据：`loadProfile` 失败被静默当成"没有头像"、或头像更新要刷新页面才生效时不算完成。

- [x] 6.4 绿：`web/src/protocol.ts` 与假核心夹具对齐（`ConfigGetResult.profile`、模板 `avatar_path`），跑 `cd web && npm run test:all` 全绿（vitest + 挂架 + 真实应用 e2e）。失败判据：任一 e2e 用例红、或 `src/protocol.test.ts` 红时不算完成。

## 7. 文档同步（守卫必须先红）

- [x] 7.1 红：改 `test/unit/group_docs_test.dart` 的 web 文案扫描源——**不要**再拿已在 `GroupView.tsx` 里存在的旧文案当锚点（那会恒绿）；**把锚点写死为"期望存在"**（组件文案未实现时先红）：扫 `web/src/group/GroupView.tsx` 的「生效结果」与「成员卡片」两个锚点，并要求 `Docs/user-guide/group-chat.md` 覆盖这些点（气泡左右/头像来源/状态点/紧凑环只画环且悬停看 tokens 详情/齿轮面板七项/已移除只读/同图靠名字）。**管理屏文案不写进本文件**——「换头像」「恢复默认」「头像资料读取失败」（`UserAvatarBlock.tsx`）与「清除头像」（`TemplatesPage.tsx`）归 `web_management_docs_test.dart`（见 7.3）。跑 `flutter test test/unit/group_docs_test.dart` 见红（`GroupView.tsx` 里还没有「生效结果」/「成员卡片」、文档也还没有）。失败判据：这些锚点在产品代码里已存在（本轮不该有）时说明选错锚点，重选；把管理屏文案塞进 group 守卫时不算数。

- [x] 7.2 绿：改 `Docs/user-guide/group-chat.md`——「在 web 哪里」「怎么操作」补：公开时间线是左右气泡（用户右绿气泡 + 右端头像；成员左带头像与名字）、成员卡片有头像/状态点/紧凑环（只画环、悬停或键盘聚焦看 **tokens 详情**）/齿轮、齿轮面板里有什么（模板 / 工具子集 / 提示词追加 / 思考强度 / 生效结果 / 移除）、已移除成员的面板是只读、头像从哪来（模板上传图优先，否则默认身份图案；头像图经附件接口取回，文件丢了回落默认图案）、同模板多成员共用上传图时靠名字区分。内容必须与 7.1 的扫描锚点逐字对应。跑 7.1 转绿。失败判据：文档仍写"成员卡片上有生效工具清单/移除按钮"之类旧形态、或讲不清紧凑环不给百分比时不算完成。

- [x] 7.3 红：在 `test/unit/web_management_docs_test.dart` 与 `test/unit/web_core_docs_test.dart` 增加两类断言——**(a) 管理屏文案锚点（写死为期望，未实现时先红）**：`web_management_docs_test` 扫 `web/src/components/UserAvatarBlock.tsx` 的「换头像」「恢复默认」「头像资料读取失败」与 `web/src/components/TemplatesPage.tsx` 的「清除头像」，并断言 `web-management.md` 覆盖这些点；**(b) 按表行的载荷断言（解析 markdown 表格行，不用整篇子串）**：①RPC 表必须有 `profile.save` 一行（清单来自 `kCoreRpcMethodNames`）；②`config.get` 那一行必须带 `profile`（或 `identitySeed`）字样；③`template.save` 那一行必须带 `avatarPath` 字样（`web_management_docs_test` 与 `web_core_docs_test` 各自覆盖自己那份文档的表）。跑 `flutter test test/unit/web_management_docs_test.dart test/unit/web_core_docs_test.dart` 见红。失败判据：只查整篇子串（正文提一句也能过）、或把 group 文档锚点塞进这两个文件时不算数。

- [x] 7.4 绿：改 `Docs/user-guide/web-management.md`（模板页头像上传/预览/清除；侧栏用户头像换/恢复默认与失败提示；RPC 表加 `profile.save`；`config.get` 行加 `profile`/`identitySeed`；`template.save` 行加 `avatarPath`）与 `Docs/user-guide/web-core-shim.md`（单聊气泡与头像、脚本 RPC 表同样补齐载荷行），跑 7.3 转绿。失败判据：表行缺字段、或文案与代码里 `template-avatar-*`/`user-avatar-*` 控件名对不上时不算完成。

- [x] 7.5 红：在 `test/unit/user_docs_test.dart` 的 `_dartConfigSourcePaths` 里**加入 `lib/models/user_profile.dart`**（不要用 `_otherCodeNames` 绕过），并在 `test/unit/agent_template_docs_test.dart` 增加模板头像字段锚点；断言 `Docs/user-guide/configuration.md` 的配置示例含 `profile` 块（`avatar_path`、`user_id`）与模板 `avatar_path`，`agent-templates.md` 的字段说明列头像。跑 `flutter test test/unit/user_docs_test.dart test/unit/agent_template_docs_test.dart` 见红。失败判据：把新模型文件漏在源路径清单外（文档键找不到解析路径）时守卫必须红。

- [x] 7.6 绿：改 `Docs/user-guide/configuration.md`（`profile` 块与 `avatar_path`/`user_id` 键：含义、缺省、写回时机、手写规则；**并写明旧版本不认识这两个键、用旧版本保存会丢掉它们，降级前备份配置**）与 `Docs/user-guide/agent-templates.md`（模板头像字段、上传入口、回落身份图案、新增模板不继承头像），跑 7.5 转绿并重跑 `flutter test test/unit/agent_template_docs_test.dart test/unit/user_docs_test.dart`。失败判据：文档写了代码没有的键、或代码解析了文档没写的键时守卫必须红。

- [x] 7.7 README 功能索引：本次不新增 `Docs/user-guide/` 文件，`README.md` 无需新增链接；跑 `flutter test test/unit/user_docs_test.dart` 确认"文档 ↔ 索引双向一致"仍绿。失败判据：新增了文档文件却没进索引（守卫红）时不算完成。

## 8. 整体校验与视觉验收（一条都不许跳）

- [x] 8.1 全量 web 测试：`cd web` → `npm run test:all`（vitest + `build:harness` + `node e2e/layout.mjs` + `build` + `node e2e/group.mjs`），贴每条命令的通过/失败计数；再单独跑一遍 `cd web && npm test`（golden 向量与令牌守卫）。失败判据：只跑其中一段、或任一用例红时不算完成。

- [x] 8.2 `design_audit` 视觉验收（主循环实测，核心 50474）：1280 余 2 项——复选框 input 13×13 medium（自发反应开关，刻意保留，与 group-chat-layout 同残留）+ 气泡正文 line-length low（最长 92 字符，消息内容自然长短，max-w-xl/2xl 约束）；720 余 1 项（同复选框 medium）。两宽度均无横向溢出、无新低对比；新增头像/状态点/齿轮/环悬停浮层命中≥24px，头像三档色（accent 90° 递进）与语义色不混淆。

- [x] 8.3 截图视觉验收（主循环 read_image 四图核对，headless Edge 假核心，未开应用窗口）：`LAYOUT_SHOT`/`LAYOUT_SHOT_TEMPLATES` 开关已加。bubbles_single.png——用户绿气泡靠右+identicon 头像在右、助手靠左带头像、无 You/Assistant 标签、侧栏用户头像+换头像/恢复默认；bubbles_group.png——用户右/成员甲左（橙 identicon+名字+气泡）、右侧成员卡片=头像+名字+状态点+紧凑环+齿轮⚙、卡面无工具长列表；bubbles_members.png——成员视图完整环仍 context-ring 旁置 tokens 与三瓣图例（不核对百分比）、真实上下文 JSON、私有过程行；bubbles_templates.png——general/alt 各带 identicon 头像。四图均与气泡/卡片要求相符。

- [x] 8.4 Dart 侧校验：`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 后跑 `flutter test`（全量 VM 测试）与 `flutter analyze`（改动文件不得新增问题），贴输出。失败判据：把 `Failed to lookup symbol` 这类"DLL 没刷新"的红当成回归、或 analyze 新增问题时不算完成。

- [x] 8.5 提案与 OpenSpec 校验：跑 `flutter test test/unit/openspec_proposal_test.dart`（提案守卫）、`openspec validate chat-bubbles-avatars --type change --strict`、`openspec status --change chat-bubbles-avatars --json`（tasks 为 done、`applyRequires` 全完成）；另跑 `openspec validate --specs` 确认主规范未被本轮工件改动带红。失败判据：strict 非 valid、或状态里仍有 blocked 工件时不算完成。

- [x] 8.6 分层覆盖自查（写进执行记录，不是跑命令）：本 change 的测试层覆盖为——Dart 单测 `test/unit/`（模型字段、模板控制器、文档守卫 5 份）、Dart 集成 `test/integration/web_management_rpc_test.dart`（头像字段经 RPC 落盘、越界/目录/类型错、读盘不变量）、web 纯逻辑 `web/src/**/*.test.ts`（身份图案 golden、头像解析、成员卡片判定、令牌守卫）、web 真实渲染 `web/e2e/layout.mjs` 与 `web/e2e/group.mjs`（内层气泡几何、data URL 头像、成员卡片与环、齿轮与只读面板）；`test/widget` / `sidecar/test` / `test/smoke` 不适用（本 change 不改 Flutter 界面控件、不改 C++、不改构建脚本）；`integration_test --tags live` 不适用（不改模型请求装配，没有需要真实模型才能判定的行为）——若主循环另有要求，按需求补跑并如实报告。失败判据：写"live 通过"而实际没跑、或声称某层不适用但改动其实碰到了该层时不算完成。

---

**归档前置（不在 apply 范围，归档时由用户单独发话）**：`agent-config` 的 Purpose 目前只写"每个 Agent Type 能收什么模态"，归档同步 delta 时必须扩成"配置文件里的字段规则（模态 + 模板头像字段 `avatar_path` + 用户资料块 `profile`）"；`context-occupancy-ring` 的 Purpose 需补一句"web 成员卡片的紧凑环只画环、详情在悬停浮层"；`agent-group-chat` 与 `web-chat-screen` 的 Purpose 各补一句"气泡与头像"。归档报告里贴 `openspec validate --specs` 的"同步前 / 同步后"数字。理由与边界见 design.md 的 Risks。
