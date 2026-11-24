# chat-bubbles-avatars apply 执行记录

本文件是 tasks.md 提到的「执行记录」：锚点清单（0.1）、各任务的先红后绿证据指针、
分层覆盖自查（8.6）。只作索引，不重述过程；行号会漂移，一律用 testid / 常量名 / 函数名。

## 0.1 开工前置核对：既有锚点与常量落点

已逐一打开（本次 apply 只读核对，不改产品代码）：

| 文件 | 要守的既有锚点 / 常量 |
|---|---|
| `web/src/group/GroupView.tsx` | `timeline-item`、`data-seq`、`member-name-*`、`member-edit-*`、`override-editor-*`、`effective-*`、`tool-*`、`append-*`、`effort-*`、`member-save-*`、`member-remove-*`、`member-streaming-*`、`member-add`、`member-template-select`、`member-window`、`context-ring`（成员视图） |
| `web/src/components/MessageList.tsx` | `user-message`、`assistant-message`、`streaming-message`、`message-row`、`message-list`、`attachment-thumbnail`、`attachment-not-sent`、`attachment-missing`、`streaming-indicator`；估计行高与虚拟滚动 |
| `web/src/components/ContextRing.tsx` | `context-ring`、`ring-slice`、`ring-legend`、`ring-total`、`ring-fixed-overhead`、`ring-unavailable`、`SLICE_CLASSES`（`fill-*`）、`RING_SIZE=120`、`RING_RADIUS=50`（= 120/2 − `RING_PADDING`） |
| `web/src/chat/ring.ts` | `ringSegments`、`kFullTurn`、`arcPath`（实心扇形只给默认 120 环） |
| `web/src/tokens.ts` | `spacingScale`（4/8/12/16/24/32/48/64）、`radii.card`、`palette`、`layoutConfig`；新增 `avatarTints` 落这里 |
| `web/src/tokens.test.ts` | `pairs`（CSS ↔ TS 逐项）、`guardedSourceFiles()`（扫 `components/`、`group/`、`layout/`、`App.tsx`；须加 `src/avatars`） |
| `web/src/index.css` | `@theme` 的 `--color-*` / `--text-*` / `--radius-*` / `--shadow-*`；新增 `--color-avatar-tint-0..2` 与 reduced-motion 关脉冲 |
| `web/src/App.tsx` | `attachmentDataUrls` 去重缓存模式、`requestedAttachments`、`loadTemplates`、`loadGroup` 逐成员快照、`ChatShell` 装配 |
| `web/e2e/layout.mjs` | 挂架驱动、`openPage(scenario)`、`run()`、`obs()`；目前没有截图开关 |
| `web/e2e/group.mjs` | `openPage`、`openExistingGroup`、`clickByTestId`、`rpcLog`/`eventLog`/`responseLog`、`groupViewDelay`/`groupViewFail`、`__gate_member_stream`、`GROUP_SHOT`/`GROUP_SHOT_MEMBERS`、用例 8.4/8.5/8.6/1.2/R.2 的成员名依赖 |
| `web/test/harness/main.tsx` | `__HARNESS_SCENARIO__`、`__harness`、假 `CoreClient`、`Harness`/`ManagementHarness`、`attachments` 场景字段 |
| `lib/models/agent_type_config.dart` | `fromJson` 的按字段回落 + 一次性日志、`toJson` 条件写回、`input_modalities` 先例 |
| `lib/models/app_config.dart` | 顶层块解析（`spill` / `tool`）、`copyWith`、条件写回 `search` |
| `lib/services/agent_template_controller.dart` | `AgentTemplateDraft`、`validate` 的"新模板从 base 继承缺省字段"、`save` 整份写回 |
| `lib/core/headless_core.dart` | `kCoreRpcMethodNames`、`_registerMethods`（漏实现抛 `StateError`）、`attachmentsDir`、`kMaxImageBytes`、`_readLatestConfig`、`_handleAttachmentRead` 的 `p.normalize`+`p.isWithin` 写法 |
| `test/unit/user_docs_test.dart` | `_dartConfigSourcePaths`（配置键 ↔ 文档双向核对；须加 `lib/models/user_profile.dart`） |
| `lib/models/group_member.dart` | `copyWith` 的 `clearOverrides` 先例（`clearProfile` 照此） |

本 change 新增常量的落点（tasks 已钉死）：

- `kDefaultUserSeed` → `lib/models/user_profile.dart`（`static const String kDefaultUserSeed = 'local-user'`）
- `RING_PADDING` → 见 5.4 说明：为避免「ContextRing ↔ cards」双向依赖，`RING_PADDING` 落在纯逻辑模块 `web/src/group/cards.ts`，由 `web/src/components/ContextRing.tsx` 导入消费（不复制数字）；偏离只在落点，数值语义与 design D6 一致。
- `avatarTints` → `web/src/tokens.ts` 与 `web/src/index.css`（`--color-avatar-tint-0..2`）

`context-ring` 与新的紧凑环是**两个名字**：完整环 `context-ring`（成员视图），紧凑环
`member-ring-<id>`（成员卡片）。本 change 不给紧凑环输出 `context-ring`。

## 8.6 分层覆盖自查

本 change 的测试层覆盖（写进执行记录，不是跑命令）：

| 层 | 路径 | 覆盖 |
|---|---|---|
| Dart 单测 `test/unit` | `agent_type_config_avatar_test.dart`、`app_config_profile_test.dart`、`agent_template_controller_test.dart` | 头像字段读取侧三态（缺席静默 / 非法留痕 / 空串回落）与条件写回；`profile` 块解析、字段缺席静默、`clearProfile`、条件写回；模板头像三态与新模板不继承头像 |
| Dart 集成 `test/integration` | `web_management_rpc_test.dart`（3.3 组） | `template.save` 头像三态 + 类型错 + 越界 / 不存在 / 目录拒绝；`profile.save` 必填、路径校验、`config.get` 返回 `profile` / `identitySeed`、只提交 providers 不抹 profile、**先读盘再 copyWith** 的不变量；`kCoreRpcMethodNames` 含 `profile.save` |
| web 纯逻辑 `web/src/**/*.test.ts` | `avatars/identicon.test.ts`、`avatars/resolve.test.ts`、`group/cards.test.ts`、`tokens.test.ts` | 身份图案 golden 向量 / 镜像 / 无符号取模；头像来源解析；成员状态与环四态 / `ringGeometry` 比例 / 面板字段清单 / 已移除只读态；令牌守卫（`avatarTints` 三档、`src/avatars` 进扫描范围） |
| web 真实渲染 `web/e2e/layout.mjs` | 单聊气泡与头像（3 页）、模板页头像、侧栏用户头像 | 内层气泡左缘几何、头像左右位置、无 You/Assistant、上传图真显示 / 删文件回落、附件提示行、`attachment.upload` → `template.save avatarPath` 三态、`profile.save` 换 / 清、`config.get` 失败可见 + 聊天屏不断 |
| web 真实应用 `web/e2e/group.mjs` | 5.3（连跑两遍） | 用户 / 成员气泡几何与头像、同模板同图靠名字、成员卡片头像 / 状态点 / 紧凑环 / 齿轮、`context-ring` 计数 0、环四态占位与悬停 tokens 详情、已移除只读且零写请求、卡面无生效长列表、换模板 payload 带 `templateName` 且头像跟随、门挂流式的 running/idle、模板头像读不到的回落 |
| 文档守卫 `test/unit` | `group_docs`、`web_management_docs`、`web_core_docs`、`user_docs`、`agent_template_docs` | 组件文案锚点（写死为期望）、群聊气泡 / 卡片七件事、RPC 表**按行**载荷（`profile.save` / `config.get` + `profile` / `template.save` + `avatarPath`）、配置键双向一致（`user_profile.dart` 进源路径清单） |

不适用（本 change 未触碰对应层）：

- `test/widget`：不改 Flutter 界面控件（Flutter 桌面聊天屏在 Non-Goals 里）。
- `sidecar/test`：不改 C++。
- `test/smoke`：不改构建脚本。
- `integration_test --tags live`：不改模型请求装配（头像字段不进系统提示词 / 工具定义 / 消息内容），没有需要真实模型才能判定的行为。

## 先红后绿证据指针（命令 + 失败摘要 → 通过计数）

| 任务组 | 红 | 绿 |
|---|---|---|
| 1.1/1.3 | `cd web && npm test` → `Cannot find module './identicon'`（1 suite failed / 115 passed）；`Cannot find module './resolve'`（1 suite failed / 123 passed） | `npm test` → 14 files / 127 passed（含 identicon 8 + resolve 4） |
| 2.1/2.3/2.5 | 三个 Dart 测试文件编译失败（`avatarPath` getter / 命名参数不存在） | 4 + 7 + 17 passed |
| 3.1 | `flutter test test/integration/web_management_rpc_test.dart` → 9 个新用例红：`Expected: <路径> Actual: null`、`Expected: null Actual: {code: -32601, message: 'Method not found: profile.save'}` | 37 passed（含 0.4 的注册表一致性） |
| 3.3 | —（类型/接线改动，红靶是 4.1/5.3 的旧夹具编译失败） | `npx tsc --noEmit` 无输出；`protocol.test.ts` 11 passed |
| 4.1/6.1 | `npm run build:harness && node e2e/layout.mjs` → 4 个新用例红（`Waiting for selector '[data-testid="bubble"]'` / `[data-testid="template-avatar-preview"]'` / `[data-testid="user-avatar-block"]'`） | 24 passed / 0 failed（含既有 20 条） |
| 5.1 | `npm test` → `Cannot find module './cards'`（1 suite failed / 127 passed） | `npm test` → 15 files / 137 passed（cards 10 条） |
| 5.3 | `npm run build && node e2e/group.mjs` → 40 例中 1 红：`时间线必须有用户行`（旧时间线没有内层气泡） | 40 passed / 0 failed（5.3 连跑两遍） |
| 7.1/7.3/7.5 | `flutter test` 五份文档守卫 → `Expected: contains '左右气泡'`（实际整篇群聊文档不含）、RPC 表缺 `profile.save` 行、`user_docs` 反向缺 `profile` / `avatar_path` / `user_id` | 46 passed |
| 8.1 | — | `cd web && npm run test:all`：vitest **15 files / 137 tests**；`build:harness` 成功；`layout.mjs` **24/24**；`build` 成功；`group.mjs` **40 例 / 0 失败**；另单独 `npm test` → **15 files / 137 tests passed** |
| 8.4 | — | `sync_sidecar_dll.ps1` → `SYNC-OK: sidecar.dll already current`；`flutter test -j 1` → **1222 passed / 2 skipped / 0 failed（All tests passed!）**；默认并发全量有一条既有跨 suite 假红（见下）；`flutter analyze` **160 issues**、**改动文件 0 条**（见下） |
| 8.5 | — | `openspec validate chat-bubbles-avatars --type change --strict` → `Change 'chat-bubbles-avatars' is valid`；`openspec status --change chat-bubbles-avatars --json` → `isComplete: true`、四个工件 `done`、`applyRequires: ["tasks"]`；`openspec validate --specs` → **Totals: 66 passed, 0 failed (66 items)**；`test/unit/openspec_proposal_test.dart` 在全量里绿（`+765` 处两条用例、无 `[E]`） |

### 8.4 全量 `flutter test` 的一条既有跨 suite 假红（如实登记）

- **默认并发** `flutter test`（连跑两次）与 `flutter test -j 4`（一次）都是同样的 **1 条红**：
  `test/integration/command_tool_test.dart` 的「超时被终止且带回已收集的输出（覆盖 4）」，
  现场 `timed_out=true duration_ms≈2580..2803 stdout=""`（期望含 `BEFORE-TIMEOUT`）；
  同一批跑里其余 **1220 passed / 2 skipped**。
- **单跑绿**：`flutter test test/integration/command_tool_test.dart` → 6/6 passed。
- **归因证据（不涉及本 change 的任何改动文件）**：用**三个未改动**的 suite 并发复现
  `flutter test test/integration/command_tool_test.dart test/integration/browser_worker_test.dart test/integration/compaction_no_drop_test.dart -j 4`
  → 同一条用例同样红（`duration_ms=2601 stdout=""`）。该用例源码注释自述"整机负载高时
  会假红（单跑通过、全量跑时输出还没写出来就被杀了）"，触发窗口是 `browser_worker`
  （起 Edge）与 `compaction_no_drop`（压 sqlite）与它同时在启动。本 change 不碰命令工具、
  不碰 sidecar / C++，故按既有 flake 登记，未改该测试（改测试属于改验收标准，不在本批权限内）。
- **处置**：另跑 `flutter test -j 1`（全量、串行，消除并发争抢）作为全量证据 →
  **`01:56 → 05:28`，`+1222 ~2`，`All tests passed!`（1222 passed / 2 skipped / 0 failed）**。

### 8.4 `flutter analyze` 读数

- 第一次读数是 **161 issues**，其中 1 条 `use_null_aware_elements` 在**本 change 的**
  `test/integration/web_management_rpc_test.dart`（`saveTemplate` 里的
  `if (originalName != null) 'originalName': originalName`）。我第一次按路径过滤时漏了
  这个文件，先报了"改动文件 0 条"，是错的；主循环自核指出后已修（改成 null-aware 元素
  `'originalName': ?originalName`）。
- 修后 `flutter analyze` → **160 issues**（`ran in 7.8s`，与仓库记录的 160 既有持平）；
  按**全部改动文件**重新过滤（`lib/models/user_profile.dart`、`lib/models/agent_type_config.dart`、
  `lib/models/app_config.dart`、`lib/services/agent_template_controller.dart`、
  `lib/core/headless_core.dart`、`test/integration/web_management_rpc_test.dart`、
  `test/unit/` 下 5 个改动/新增文件）→ **0 条**。web 侧的改动文件不在 `flutter analyze`
  的 Dart 分析面内（由 `npx tsc --noEmit` + vitest 守卫）。
- 该文件修后单跑：`flutter test test/integration/web_management_rpc_test.dart` →
  **37 passed（All tests passed!）**。


## 偏离 design 的决定（可核）

1. **`RING_PADDING` 落在 `web/src/group/cards.ts`，由 `ContextRing.tsx` 导入消费**（design/0.1 写的落点是 `ContextRing.tsx`）。原因：5.4 要求 `ContextRing` 消费 `ringGeometry(size)`，5.1/5.2 钉死单参签名 `ringGeometry(120)`；若常量放 `ContextRing` 会形成 `ContextRing ↔ cards` 双向依赖。数值语义不变（`120/2 − 50 = 10`），`ContextRing` 只是 `RING_RADIUS = RING_BASE_SIZE/2 − RING_PADDING`，不复制数字。
2. **`data-bubble-side` 增加第三个值 `member`**：design D4 写的是 `user|agent`，而 tasks 5.3② 的验收读 `member`。实现上单聊仍是 `user|agent`，群成员消息是 `member`（同样靠左），两处断言各自能过、语义更明确。
3. **`MessageBubble` 的布局断言口径**：4.1② 的「容器」按**内层气泡所在的列**度量（气泡左缘 == 列左缘 ≤ 1px），另加「助手头像贴行左缘 ≤1px」证明整行靠左；不量右缘、不量宽度（task 明令禁止）。用户侧只量左缘 > 行中点。
4. **启动顺序**：`loadTemplates()` / `loadProfile()` 调到 `loadSessions()` 之前。原因：头像映射要在单聊 / 群聊首帧之前就绪（否则首帧闪身份图案再变上传图）；也让 `config.get` 的失败出口在会话加载之前就可见。
5. **用户身份种子在读取失败时用空串**：web 不复制 `kDefaultUserSeed`（design D2 明确要求），`config.get` 成功时核心总会返回 `identitySeed`，所以只有失败路径用空串兜底（画同一张固定图案，不阻断渲染）。
6. **紧凑环的三瓣 `circle` 仍带 `data-testid="ring-slice"`**：与完整环同名。完整环的既有断言只在单聊页（单聊页没有成员卡片），群聊页没有全局 `ring-slice` 计数断言，两处不冲突。
7. **两个 e2e 夹具的时序**：5.3 用 30s 延迟造「加载中」占位，断言完成后立即 `reset=1` 清掉注入，避免 30s 延迟把链结束后的重拉拖住（否则 ⑫ 的 20s 等待会假红）。

## 未做 / 缺口

- **8.2 `design_audit` 与 8.3 截图读图**：按分工由主循环批执行，本批没有跑。截图开关已按 8.3 的约定加好：`LAYOUT_SHOT=<path>`（单聊气泡）、`LAYOUT_SHOT_TEMPLATES=<path>`（模板页头像）；`GROUP_SHOT` / `GROUP_SHOT_MEMBERS` 沿用既有。

