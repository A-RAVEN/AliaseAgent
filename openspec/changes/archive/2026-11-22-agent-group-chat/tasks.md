## 1. 前置：测试隔离夹具与 schema v9

- [x] 1.1 建集成测试隔离夹具 `test/integration/group_test_support.dart`：临时目录里的 `configPath` / `attachmentsDir` / `DatabaseService.openAt` / **核心 `lockPath`** + 假 sidecar + 假 probe；提供「本次运行没有写过用户真实 `~/.aliasagent`」的核对入口（记录运行前后真实目录里 db / config / **core.lock** 的 mtime+大小；`logs/` 作为已知副作用只记录基线、不要求不变）。先红后绿：先写一条空用例断言各路径都在临时目录、且真实目录读数未变——当前无此夹具，用例编译失败即红；夹具与用例同时跑绿。
- [x] 1.2 `messages` 加 `author` / `visibility`：**unit 只测纯模型** `lib/models/message.dart` 的 `fromRow`/`toRow`（列名、缺省 `public`、author 为 NULL 的用户消息）。先红后绿：`test/unit/message_author_visibility_test.dart` 的「round-trip」「缺省等于变更前行为」两条，当前模型没有字段 → 编译红。
- [x] 1.3 `sessions` 加 `kind` 与 `overrides_json`：`Session` 模型 `fromRow`/`toRow` 纯模型测试（unit）。先红后绿：`test/unit/session_kind_test.dart` 的「kind 缺省 single」「overrides_json 为 NULL 等于无覆盖」，当前无字段 → 红。
- [x] 1.4 `group_members` 表与 `GroupMemberRepository`（成员 id、`group_session_id` 外键级联、显示名唯一（仅未移除，用 `UNIQUE(group_session_id, name) WHERE removed_at IS NULL` 部分唯一索引）、模板名、`overrides_json`、`removed_at`）——**仓储断言放 integration 真库**：临时库 `openAt` 后验证唯一约束、软删、同名重建新 id、级联删除的行数。先红后绿：`test/integration/group_member_repository_test.dart` 四条用例（真 SQLite 行数），当前无表 → 红。
- [x] 1.5 `summary_nodes` 加 `member_id` + 含成员作用域的 span 索引与 **leaf_owner 索引**；`SummaryNodeRepository` 的写入/查询/`delete-before-insert` 全部带成员作用域（单会话 `member_id IS NULL`）。先红后绿：`test/integration/summary_node_member_scope_test.dart`（真库）写「同一 span 两成员各一行、互不删除」「**单会话 NULL 分支**：materialize 后同覆盖范围只有一行（若 WHERE 写成 `= NULL` 则重复行 → 红）」「findCovering 带成员参数、跨成员不命中」，当前无列 → 红。
- [x] 1.6 schema v8→v9 迁移（`messages.author`/`visibility`、`sessions.kind`/`overrides_json`、`summary_nodes.member_id`、`group_members`（含 `removed_at`）与两个含成员作用域的索引）+ `_onCreate` 与 `openAt` 两处镜像。先红后绿：扩 `test/integration/schema_migration_test.dart`：① 版本 8 库升级后行数与默认值正确；② **「升级产物 vs 全新建库」分别取 `PRAGMA table_info` / `PRAGMA index_list` 逐项一致**；③ 把该文件里**三处** `getVersion() == 8` 的断言一起改成 9（实测 grep 到 3 处；裁决里说两处，以文件为准）。先红后绿。

## 2. 覆盖层解析（agent-instance-overrides，纯逻辑为主）

- [x] 2.1 覆盖层模型与空值三态：字段缺席/JSON null = 无覆盖；工具子集显式 `[]` = 零工具；`thinkingEffort` 显式 `""` = 关闭；`model`/窗口替换字段被拒。先红后绿：`test/unit/agent_instance_overrides_test.dart` 的「缺席与模板逐字段相等」「显式 [] 是零工具」「显式空串是关闭」「替换字段被拒」，当前无实现 → 红。
- [x] 2.2 工具子集校验：只能取模板已有工具；未知工具、超出模板、重复名、空名一律拒绝并列名字（不静默删）；显式 `[]` 视为合法。先红后绿：同一文件的「扩出模板被拒（列出名字）」「未知工具被拒」「重复/空名被拒」「空子集合法」，先红后绿。
- [x] 2.3 求交与模板漂移：生效工具 = 模板 ∩ 子集（顺序按模板）；空子集求交为空；模板后来删掉子集里的工具时收紧并留一行说明。先红后绿：同一文件的「求交按模板顺序」「空子集求交为空」「模板漂移只收紧且留说明」，先红后绿。
- [x] 2.4 提示词追加与思考强度：append 语义、空追加不产生多余空行；`thinkingEffort` 白名单外**保存时拒绝**（复用 `AgentTemplateController.validate` 同一判据，不静默关闭）；`""` 接受为关闭。先红后绿：同一文件的「追加不替换」「空追加逐字相同」「非法 effort 保存被拒（列合法档位）」「显式空串接受」，先红后绿。
- [x] 2.5 覆盖层持久且不改模板：成员行与会话行的 `overrides_json` 由同一个解析器读写、重启后仍生效；保存覆盖层后模板注册表与该模板配置内容不变、其它会话不受影响。先红后绿：`test/integration/agent_instance_overrides_test.dart`（用 1.1 夹具）五条断言，先红后绿。

## 3. 视图投影纯函数

- [x] 3.1 投影函数 `View(X)` 的映射规则：用户消息原样、自己公开回复第一人称无前缀、他人公开回复 user 轮 + 「Y 说：」前缀（显示名，含已移除成员）、自己私有活动按 replay 回放、他人私有活动整体剔除。先红后绿：`test/unit/group_view_projection_test.dart` 五条用例，先红后绿。
- [x] 3.2 归属只看文本、不依赖 `name` 字段：断言装配出的每条消息只有 `role` 与 `content` 两个键（多出 `name` 即红）。先红后绿：`test/unit/group_view_no_name_field_test.dart`，先红后绿。
- [x] 3.3 剔除彻底性：他人私有行的 thinking / tool_use / tool_result 三类内容块在视图里一个都不出现（分别断言）。先红后绿：`test/unit/group_view_projection_test.dart` 三条用例，先红后绿。
- [x] 3.4 连续同角色不修补：两个他人公开回复相邻时视图是两条 user 轮，不插填充、不改 role、不造空 text 块；DeepSeek 兼容端点未记载合并行为 → live 另测（10.1）。先红后绿：同一文件的「连续 user 轮原样发出」，先红后绿。
- [x] 3.5 投影不变量结构断言：① 成员自己的 `tool_use` 与对应 `tool_result` 之间不夹他人公开行；② `tool_result` 位于所在 user 轮 content 数组最前；③ 每条可见项恰好出现一次。先红后绿：`test/unit/group_view_invariants_test.dart` 三条用例，先红后绿。
- [x] 3.6 唯一出口守卫：`test/unit/group_view_single_egress_test.dart` 断言成员请求的 messages 只由投影函数产出（注入计数或结构断言：不经过投影函数就产生成员请求即红）。

## 4. Agent seam：句柄 / 视图装配 / 写入 / 压缩作用域

- [x] 4.1 `Agent` 增 `handle`（sidecar 上下文 + 注册表 + 取消键）与 `member` 上下文；单会话 `handle == sessionId` 行为不变，两成员各自注册互不覆盖。先红后绿：`test/unit/agent_member_seam_test.dart` 两条用例，先红后绿。
- [x] 4.2 成员视图增量装配替换全量 `restore()`：按 `seq` 区间读取原文并映射成视图；用「被要求全量读取整条会话就抛错」的仓库注入，成员装配仍成功。先红后绿：`test/unit/group_view_loader_test.dart` 的「全量查询即抛错的仓库下装配成功」「第二轮只读高水位之后的行（记录 seq 区间）」，当前成员路径不存在 → 红。
- [x] 4.3 成员写入带 `author`（成员 id）/ `visibility`；组成员回合的**最终公开行只存正文**（`tool_calls` **与 `thinking_json` 均 NULL**、无附件），私有证据只落 private 行；单会话最终行行为不变。先红后绿：`test/integration/group_message_write_test.dart`（1.1 夹具 + 假 sidecar）四条用例：公开行两个 JSON 列均为 NULL、私有中间行同时有工具与 thinking 证据、单会话最终行仍写 thinking/聚合工具、用户行 author 为 NULL。先红后绿。
- [x] 4.4 压缩作用域换成成员：`_loadClosedSegments` / `_resolveSummaries` / `materialize` / `findCovering` / **`_loadReferenceCandidates`** 全部带 `member_id`（单会话 `IS NULL`，NULL 分支有专门用例）。先红后绿：`test/unit/compaction_member_scope_test.dart`（同一句柄两个成员各自的摘要不互相顶替）+ `test/integration/group_compaction_test.dart`（真库两成员各压一次、单会话 NULL 分支去重）+ `test/unit/summary_reference_scope_test.dart`（候选集只含本人作用域）。先红后绿。
- [x] 4.5 压缩输入换成视图序列：折叠输入是该成员视图、摘要锚定原始 `seq`、投影按成员替换被覆盖区域的可见项、每个 span 恰好一种表示。先红后绿：`test/integration/group_compaction_projection_test.dart` 四条用例（视图输入、原始 seq 锚定、两成员各一条摘要、无共享摘要行），先红后绿。
- [x] 4.6 两段提示词常量落地：`kGroupMemberRolePrompt`（五件事齐备）+ `kGroupSummaryPromptSuffix`（**只有归属纪律**，不含"自包含 + 文件指针"）。先红后绿：`test/unit/group_prompts_test.dart` 逐字断言两段常量全文与"摘要纪律不含自包含"，先红后绿。
- [x] 4.7 摘要请求带归属纪律：摘要系统文本追加 `kGroupSummaryPromptSuffix`；被折叠文本里他人的话仍是「Y 说」。先红后绿：`test/unit/model_summary_provider_group_test.dart` 断言系统文本含该常量、folded 文本保留「甲 说：」，先红后绿。
- [x] 4.8 覆盖层在创建/恢复时生效：工具子集进 `toolsJson`、追加段进系统提示词、思考强度按覆盖层解析；**不重建实例时工具/提示词不变、思考强度下一消息变**；重建后新配置才进请求。先红后绿：`test/integration/group_override_effective_test.dart`（同一对话两次请求快照对比：编辑前 / 重建后；外加"不重建则工具不变、thinking 变"）三条用例，先红后绿。
- [x] 4.9 视图驻留集与缓存生命周期：同一历史在 1M/200k 窗口派生不同 `T`；常驻原文段不超 `T`；**解析缓存条目只跟随当前驻留视图的 seq 并集、不随会话全长增长**；同一公开行在两成员视图里解析计数 = 1。先红后绿：`test/unit/group_view_budget_test.dart` 四条用例，先红后绿。

## 5. 组服务与调度

- [x] 5.1 `group.create` 建立组上下文与工作区：`ensureContext(groupId, workspace ?? 缺省)`，两条路径（带参/不带参）都断言实际工作区；成员创建经 `sidecar.getWorkspace(groupId)` 继承（**走生产路径，不靠夹具手工 setWorkspace**）。先红后绿：`test/integration/group_workspace_test.dart` 三条用例，先红后绿。
- [x] 5.2 组成员创建：模板 + 覆盖层 → 实例；不建 `parent_session_id` 子运行记录、回合结束不销毁实例。先红后绿：`test/integration/group_member_lifecycle_test.dart`（1.1 夹具）四条断言，先红后绿。
- [x] 5.3 组角色提示词注入：把 4.6 的 `kGroupMemberRolePrompt` 追加进成员系统提示词（复用 `systemPromptSuffix` seam）。先红后绿：`test/unit/group_prompts_test.dart`（模板提示词开头、角色说明结尾）+ `test/integration/group_member_lifecycle_test.dart`（成员快照系统提示词含常量），先红后绿。
- [x] 5.4 调度 v1 + 组级单运行门 + 两个前置门：点名一个只跑一个；**甲运行中点名乙返回 busy**（走组服务路径，不是只查乙的忙闲）；未点名可归因拒绝；不带文本且视图为空 → 可归因错误（绝不发 `messages: []`）；不带文本且最后可见项是本人 assistant → 可归因错误；不带文本但最后可见项是用户消息 → 正常发言且不写空用户行。先红后绿：`test/integration/group_send_scheduling_test.dart` 六条用例，先红后绿。
- [x] 5.5 `group.member.update`：原地改成员（id 不变）并重建实例；改名不改变历史归属；改覆盖层后下一次发言用新工具清单。先红后绿：`test/integration/group_member_lifecycle_test.dart` 三条用例，先红后绿。
- [x] 5.6 移除成员（软删）与历史归属：移除后行保留、`removed_at` 非空、`group.list` 仍返回（带 `removedAt`）；上翻历史每条行都能归属；同名重建是新 id、看不到旧私有行。先红后绿：`test/integration/group_lifecycle_test.dart` 四条用例，先红后绿。
- [x] 5.7 删除组级联：成员/消息/摘要行均为 0（真实 `SELECT COUNT(*)`）。先红后绿：`test/integration/group_lifecycle_test.dart` 一条用例，先红后绿。
- [x] 5.8 共享工作区读写：A 在组工作区写文件、B 读到同一内容（真实临时目录，不碰用户 homeDir）。先红后绿：`test/integration/group_workspace_test.dart` 一条用例，先红后绿。

## 6. 隐私硬边界与变异红靶

- [x] 6.1 隐私硬场景（**输入通道为主判据**）：A 的私有工具轮注入独特标记，断言 `B 的视图 messages 不含标记`、`B 的快照（toRawJson）不含标记`、**`B 的摘要请求输入（folded + 参考块）不含标记`**、`A 自己的视图里标记仍然存在`（反证）。先红后绿：`test/integration/group_privacy_test.dart` 四条用例（用假 SummaryProvider 捕获请求输入），先红后绿。
- [x] 6.2 变异红靶①（摘要输入通道）：临时让 `_loadReferenceCandidates` 去掉成员作用域（或让 folded 改用原文行），重跑 6.1 的「B 的摘要请求输入不含 A 标记」——必须变红；把命令与红输出贴进任务记录后**改回**，再跑绿。
- [x] 6.3 变异红靶②（拆两枪，单枪单红）：
  - ②a 关闭保存校验（接受 `run_command`）→ `test/unit/agent_instance_overrides_test.dart` 的「扩出模板被拒」必须红；
  - ②b 生效求交改成取模板全集（忽略子集）→ `test/integration/group_override_effective_test.dart` 的「子集收紧生效」必须红。
  两枪分别贴红输出后**改回**，再跑绿。
- [x] 6.4 单会话 NULL 分支红靶：临时把 `materialize` 的 delete-before-insert 去掉 `member_id IS NULL` 条件（写成 `= NULL`），跑 1.5 的「单会话 NULL 分支」——必须变红；贴输出后改回。

## 7. RPC、kind 守卫与事件

- [x] 7.1 八个群聊 RPC 与 `kCoreRpcMethodNames`：`group.create` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send` / `group.view`；`group.list` 每项带成员清单（id / 显示名 / 模板名 / `removedAt` / `overrides` / `effective`）。先红后绿：`test/integration/group_rpc_test.dart` 四条用例，先红后绿。
- [x] 7.2 `message.query` 序列化 `author` / `visibility`（可空字段如实写出）。先红后绿：`test/integration/group_rpc_test.dart` 一条用例，先红后绿。
- [x] 7.3 `agent.event` 带 `groupId` + `memberId`，`sessionId` 保留；事件类型不新造。先红后绿：`test/unit/event_serialization_group_test.dart` + `test/integration/group_rpc_test.dart` 两条事件身份断言，先红后绿。
- [x] 7.4 `group.view` 语义：本次运行内最近一次真实发出的快照；未发言/重启后返回空；不用历史拼装。先红后绿：`test/integration/group_rpc_test.dart` 三条用例（含"重建核心后视图为空"），先红后绿。
- [x] 7.5 kind 分派守卫（核心与 Flutter 两侧）：`session.list` 序列化 `kind`（组/单会话都在列表里）；`_loadSessions`/`_ensureAgentFor` 跳过组会话；`agent.send` 与 `session.switchTemplate` 对组会话可归因拒绝；**任何单 Agent 请求的 messages 不含他人 private 行**。先红后绿：`test/integration/group_kind_guard_test.dart` 五条用例（建组→列表含组→单会话入口不建 Agent 不套模板→拒绝信息→请求内容无私有行），先红后绿。
- [x] 7.6 Flutter 侧组会话占位：会话列表仍显示组会话，点开时显示「请在 web 组视图打开」占位、不进入单 Agent 对话界面、不加载整份原文当聊天历史。先红后绿：`test/widget/group_session_placeholder_test.dart`（先红：当前打开组会话会走普通消息加载路径），先红后绿。
- [x] 7.7 `agent.cancel` 组路由：组内无成员运行时返回真话（不是"查不到实例"）；有成员运行时取消并返回 `memberId`；带 `memberId` 且不在运行 → 可归因指名。先红后绿：`test/integration/group_rpc_test.dart` 三条用例，先红后绿。
- [x] 7.8 分页回归：对组会话跑尾锚 / `beforeSeq` / `head`+`afterSeq` 三种取页，行为与引入前一致；既有 `test/integration/web_core_rpc_test.dart` 与 `web_management_rpc_test.dart` 的 `rpcMethods == kCoreRpcMethodNames` 断言仍绿。先红后绿：`test/integration/group_rpc_test.dart` 回归用例。

## 8. web 组视图（真实应用可达）

- [x] 8.1 `web/src/protocol.ts`：群聊方法、`kind`、成员字段（含 `removedAt`/`overrides`/`effective`）、`author`/`visibility`、取消响应的 `memberId`。先红后绿：`web/src/protocol.test.ts` 类型与序列化断言（先红后绿）。
- [x] 8.2 组视图纯逻辑：公开时间线 / 成员分栏（含「已移除」栏）/ 未发言占位 / 发言人选择的校验（含空视图与 prefill 两种可归因错误的界面呈现）。先红后绿：`web/src/group/model.test.ts` 五条用例（vitest），先红后绿。
- [x] 8.3 真实挂载：`App.tsx` 按 `session.list.kind` 把组会话路由到组视图、单会话仍进聊天屏（组视图不是只存在于 harness）。先红后绿：`web/e2e/group.mjs` 的入口断言（先建组→刷新→点组→看到组视图），先红后绿。
- [x] 8.4 组视图操作面：建组、加成员、编辑成员覆盖层（工具子集 / 提示词追加 / 思考强度，展示 `effective`）、选发言人并发送。先红后绿：`web/e2e/group.mjs` 驱动四步并断言结果，先红后绿。
- [x] 8.5 事件与发送的 payload 判据：`group.send` 的 `params.speaker` 正确；`agent.event` 的 `memberId` 事件落到对应分栏、公开回复落到时间线；**以 payload 为判据，DOM 选中值只作辅助**。先红后绿：`web/e2e/group.mjs`（记录实际发送的 RPC params 与收到的事件 payload），先红后绿。
- [x] 8.6 复用既有组件：每成员真实上下文视图（`RealContextView` + `group.view` 快照）与每成员占用环（`ContextRing`，**分母是各自实例窗口**）。先红后绿：`web/src/group/model.test.ts` 的 ring 分母断言 + `web/e2e/group.mjs` 的组件可见性断言，先红后绿。
- [x] 8.7 布局与设计系统：1280 宽与窄屏不重叠/不溢出，跑 `web/e2e/group.mjs` 几何断言 + 对页面跑一次 `design_audit`（修最小字号/对比度/触控尺寸）。先红后绿：几何断言先写（当前无组视图 → 红）。
- [x] 8.8 组视图上翻分页：复用聊天屏既有分页（`web/src/chat/paging.ts` + `message.query` 的 `before`/`prevCursor`），公开时间线与成员私有分栏**同步上翻补页**（加载更早页时两栏都补、按 author/visibility 归位、不丢不重）；spec「移除成员后上翻含其发言的历史页」场景由此在真实产品里走通。先红后绿：`web/e2e/group.mjs` 新增上翻用例（payload 判据：`message.query` 实际带了 `before`；DOM：时间线与私有分栏行数都增长、已移除成员的历史私有行在上翻后落到它的栏里、行不重复）。当前只取尾页 ⇒ 红。
- [x] 8.9 把 `web/e2e/group.mjs` 接进 `web/package.json` 的 `test:all`（否则它会腐烂）。验收：`npm run test:all` 实际执行到 group.mjs 并打印其输出。

## 9. 文档同步与文档守卫

- [x] 9.1 新建 `Docs/user-guide/group-chat.md`：组是什么、在 web 哪里、怎么建组/加成员/编辑覆盖层/点名发言、出错会看到什么（含空视图、prefill 两种可归因错误、组会话在 Flutter 的占位）、已知限制（看不到他人私有过程、成员看不到彼此工具证据、只支持点名、**重启后真实上下文视图为空**、已移除成员只读）。`界面文案：` 标记只用于 `lib/` 里真实存在的字符串（该守卫只扫 `lib/`）。验收：`test/unit/group_docs_test.dart` + 既有 `test/unit/user_docs_test.dart` 通过。
- [x] 9.2 `README.md` 功能文档索引补一行指向 `Docs/user-guide/group-chat.md`；先红后绿：README 未加时 `test/unit/user_docs_test.dart` 的「目录里有、索引里没链」变红。
- [x] 9.3 `Docs/user-guide/configuration.md` 增「成员/会话覆盖层」一节：三字段（`toolsSubset` / `systemPromptAppend` / `thinkingEffort`）、**空值三态**（缺席 / 显式 `[]` / 显式空串）、生效时机（创建/恢复 + 思考强度热更新 + 编辑重建）、明确它们**不是 `config.json` 键**。验收：`test/unit/group_docs_test.dart` 断言三个字段名与代码常量一致。
- [x] 9.4 `Docs/user-guide/web-core-shim.md` 与 `Docs/user-guide/web-management.md` 的 RPC 表各补 8 个群聊方法与 `agent.cancel` 的组路由行为。先红后绿：先加方法进 `kCoreRpcMethodNames` 而不改文档，`test/unit/web_core_docs_test.dart` 与 `test/unit/web_management_docs_test.dart` 都因「文档没有列出这些方法」变红（两个守卫是整份文档子串包含，不解析表格）；补完两份文档后绿。
- [x] 9.5 新增文档守卫 `test/unit/group_docs_test.dart`：① **解析 group-chat.md 的 RPC 表行**（不是"文档任意处出现即通过"），逐行核对群聊方法；② 覆盖层三字段名取自产品解析路径的常量；③ `界面文案：` 句子在 `lib/` 里逐字存在；④ 已知限制锚点（重启后视图为空、已移除只读、空视图/prefill 错误）存在。先红后绿。
- [x] 9.6 扩 `test/unit/user_docs_test.dart` 的 `_otherCodeNames`：把 `author` / `visibility` / `public` 登记到**真实解析符号所在文件** `lib/models/message.dart`（`Message.toRow` / `fromRow` 的列名与缺省值），登记前先 grep 确认三个字符串真在该文件里。先红后绿：先写 group-chat.md 出现这些反引号名字而不登记 → 既有守卫报「代码里找不到」变红。

## 10. live 与视觉验收（apply 执行）

- [x] 10.1 新增 live 用例 `integration_test/group_chat_live_test.dart`（`@Tags(['live'])`）：真实模型下建组（`group.create` 走真实工作区产生路径）、加两个成员，点名「甲」发言并要求它用工具改共享工作区文件（工具轮注入本次运行独有的私有标记），再点名「乙」；断言 B 的视图/快照/**摘要请求输入（捕获摘要请求 payload）**都不含甲私有标记、甲的公开结论回到组里且带文件指针；另断言**相邻 user 轮不导致接口报错**。隔离：临时 DB + 临时 lock + 临时工作区，`configPath` 指向用户配置的**临时副本**（不改用户 db/config）。断言前打印实际工具调用（名/完整 input/result）、两次成员视图差异、捕获到的摘要请求 payload。
- [x] 10.2 运行 live 并保存证据：`flutter test --tags live --run-skipped integration_test/group_chat_live_test.dart -d windows`（仓库根、sidecar.dll 已刷新），把工具调用、成员视图差异、摘要请求 payload、相邻 user 轮结果全部打印（失败要有可归因现场）。
- [x] 10.3 视觉验收：用**临时 config / DB / lock / attachments** 起无头核心与 `web/dist`，真实打开组视图截图到 `test/live_visual/group_chat_live.png`，再 `read_image` 核对公开时间线、两个成员私有分栏、某成员真实上下文视图、某成员占用环（分母为其窗口）；顺手跑 `web/e2e/group.mjs` 几何断言。缺截图或未读图视为不通过。
- [x] 10.4 隔离复核：用 `test/integration/group_test_support.dart` 的运行前后读数核对用户真实 `~/.aliasagent` 下 **db / config / core.lock** 的 mtime 与大小未变；`logs/` 作为已知副作用记录基线（不要求不变）；确认没有测试写成 `ConfigService.save()` 到真实路径。
- [x] 10.5 收尾跑 `openspec validate agent-group-chat --type change`，要求 valid；失败则按报错修工件（验收是该命令退出码为 0）。

## 11. 主循环批次（由主循环执行，不是 apply 勾选清单）

本节不是 apply 的勾选任务：apply 到第 10 节结束。以下由主循环在 apply 完成后逐项执行并复核：

- 全量：`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` → `flutter analyze` → `flutter test`（改动文件不得新增问题，全量必须绿）。
- web：`cd web && npm run test:all`（vitest + harness + 布局驱动，确认 group.mjs 被跑到）。
- 变异红靶复核：按 6.2 / 6.3（②a、②b）/ 6.4 记录的命令重放，确认四处变异各自让点名用例变红，再确认代码已改回、用例变绿。
- 视觉复核：`read_image` 读 `test/live_visual/group_chat_live.png`，逐项核对组视图画面（公开时间线 / 成员分栏 / 真实上下文 / 占用环）。
- live 复核：重跑 `flutter test --tags live --run-skipped integration_test/group_chat_live_test.dart -d windows`，检查打印的摘要请求 payload、邻居 user 轮结果与隐私标记隔离。
- 规范复核：`openspec validate agent-group-chat --type change` 与 `openspec validate --specs`（记录同步前后的数字）。

> **2026-11-22 主循环复核完成**：① 全量 sync DLL→analyze 160（改动文件 0 新增）→flutter test `+1039 ~1 All tests passed!`；② web `test:all` vitest 82 + layout 19/19 + group.mjs 6/6（含 8.8 分页）；③ 四变异独立重放各自红（6.2 折叠改原文→B 输入含 A 私有标记；6.3a 关保存校验→扩出模板返回 null；6.3b 求交取全集→子集 list_dir 仍含 read_file；6.4 `=NULL`→单会话去重 Expected 1 Actual 0），三靶文件恢复 SHA256 逐位一致，四靶复绿 `+22`；④ 视觉 read_image `test/live_visual/group_chat_live.png`（全 UI 部件）+ 真核心真模型 CDP 截图（甲自包含公开结论/乙占位/环不静默当 0/成员生效工具），design_audit 真核心组视图 No violations/86；⑤ live 重跑绿（甲 write_file note-a.txt 实证、乙输入/快照不含甲私有、乙含「甲 说：」、甲含自己私有反证、turn.failed=0、事件带 groupId/memberId）；⑥ validate change valid + specs 64/64。隔离复核：用户 db/config/core.lock 零写入（测试组级联删除后 single=2/group=0/members=0/孤儿 256=基线，config 哈希未变）。已知限制：dirty_since_seq 会话级致乙摘要保守多算；live 历史短摘要请求=0（输入通道由 6.1/6.2 集成+变异证明）；§2/§3 实现先于测试（§2 四变异补红、§3 无实现前红，如实记录）。
