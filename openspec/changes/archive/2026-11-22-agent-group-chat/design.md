## Context

群聊的主线是「**单一共享原文 + 逐成员视图投影**」。写这个设计之前先核过下列现状事实（全部来自仓库现有代码与本地文档，不靠记忆）：

**会话与恢复路径（「会话 = 一个 Agent」的三条现状出口）**
- Flutter 启动恢复：`main.dart` 的 `_loadSessions()` 对列表里**每个**会话调 `_ensureAgentFor(s)`，后者直接 `_agentFactory.ensure(session, callbacks: ...)`。
- 无头核心：`_handleAgentSend` 直接 `factory.ensure(session, ...)`；`_handleSessionSwitchTemplate` 直接 `sessionController.switchTemplate(...)`。`serializeSession` 只输出 `id/title/agentType/parentSessionId/createdAt/updatedAt`，**没有 kind**。
- `agent.cancel` 按 `agents.lookup(sessionId)` 找实例；组会话的 sessionId 不会命中成员实例，会返回 `cancelled:false` +「该会话没有运行中的 Agent 实例」这种**假原因**。
- `Agent.restore()` 用 `messageRepo.queryBySession(sessionId)` 把整条会话历史全量载入 `Agent._history` 并常驻；`Agent._buildApiMessages` 把每条 `Message` 行拼成 `apiMessages`（thinking 回放、`tool_calls` → `tool_use`、紧随其后的**合成 user(tool_result)**）。
- `Agent.send` 在实例正忙时返回 `AgentRunResult.busy`；`Agent.dispose()` 会 `sidecar.disposeContext(handle)`；`Agent.ensureContext({String? defaultWorkspace})` 的缺省是 `defaultWorkspace ?? ConfigService.homeDir`。
- `AgentFactory.create(child: ChildRunOptions(...))` 已提供两条 seam：`systemPromptSuffix`（先例 `kSubagentRolePrompt`）与 `ensureContext(defaultWorkspace: child.workspace)`；`subagent_runner` 用 `_sidecar.getWorkspace(parent.sessionId)` 只读读父上下文工作区。

**覆盖层相关的现状口径**
- `kAgentTemplateEffectiveNote` 原文：「只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。」（`agent.dart` 的 `_resolveRoundThinking` 只重解析 thinking；窗口/工具/模型/系统提示词仍读冻结的 `config`。）
- 模板编辑器 `AgentTemplateController.validate`：思考强度空串接受（表示关闭），**非白名单字符串可归因拒绝**并列出合法档位。
- `AgentConfigResolver.resolveThinking`：`explicitEffort != null` 时按白名单判（非白名单 → `disabled`）；`null` 才走目录推导。所以「字段缺席」与「显式空串」在语义上必须分开表达。

**压缩**
- 阈值只有一个计算点 `CompactionEngine.thresholdTokens(maxContextTokens, percent)`；档位边界由同一 `T` 派生（`CompactionEngine.substitutesSpan` / `bandFloorTokens`）；`TODO.md` 顶部「🔒 钉死的原始要求」四硬约束：只按 token 数、阈值由模型窗口 × 百分比实时派生、换窗口跟着变、禁止条数门槛。
- 压缩输入是 `List<Message>`；`_resolveSummaries` 折叠，`_buildCompactionProjection` 拼投影。
- **参考上下文是第二条泄漏通道**：`_loadReferenceCandidates(dbOpen)` 用 `summaryNodeRepo.queryBySession(sessionId)` 取本会话全部摘要，交给 `selectSummaryReferences` 挑最多两条塞进折叠请求 —— 组会话里不改作用域，B 折叠时参考块会带 A 的摘要（含 A 的私有内容）。
- 摘要最终 assistant 行目前写 `thinkingJson: thinkingJsonStr`（`tool_calls` 在无工具轮时为空，但 thinking 仍写）。

**API 事实（本地文档）**
- `Docs/AnthropicAPIDoc.md` §1.3.2：`messages` 每条只有 `role` + `content`（官方原文「Each input message must be an object with a `role` and `content`」），无 `name`；同节原文「**Consecutive `user` or `assistant` turns in your request will be combined into a single turn.**」。
- `Docs/DeepSeekAPIDoc.md`：已抓取的字段明细只有 System message 变体，User/Assistant/Tool 变体**未抓取到**；该页**未记载** `messages` 可用 `name`，也**未记载**相邻同角色轮会合并。因此"DeepSeek 兼容端点也支持 name / 也会合并"都**没有本地文档依据**，不能当事实写进规范。

**界面与线协议**
- web 侧已有 `RealContextView.tsx`（吃 `context.snapshot` 的 system/messages/tools）与 `ContextRing.tsx`（吃 `breakdown`）；`event_serialization.dart` 的 `serializeMessage` / `serializeContextSnapshot` 是唯一线上形状。
- `kCoreRpcMethodNames` 是 RPC 清单唯一来源。读它的守卫**强度要如实说**：核心启动时注册表与实现一致（漏注册抛 `StateError`）；`web_core_rpc_test` / `web_management_rpc_test` 断言 `rpcMethods == kCoreRpcMethodNames`；两个文档守卫（`web_core_docs_test` / `web_management_docs_test`）只做**整份文档的子串包含**（整行从宽，不是"逐行表格解析"）。所以新增方法必须同时改两份文档，否则红。

**约束**（来自 `CLAUDE.md` / `TODO.md`）
- 压缩相关设计必须先过「自检五问」，阈值不得写死、不得加条数门槛。
- 任何上下限/缓存尺寸必须有四类出处之一（用户明说、产品既有常量、平台硬限、`Docs/user-guide/configuration.md` 登记过的配置键），否则做成配置项或先报依据。
- 用户可见功能必须同 change 更新用户文档并留一条能失败的验收；测试分层以 `Docs/TESTING.md` 为准。

## Goals / Non-Goals

**Goals:**
- 一个组会话内，N 个成员共享**一份**原文（公开消息 + 各成员私有活动，单一 per-session `seq`），成员各自看到的是这份原文的一次投影。
- 投影是成员模型拿到上下文的**唯一出口**：他人私有内容在结构上进不了别的成员的视图、摘要输入与参考块。
- 压缩按成员各自的投影视图进行，阈值按各成员自己的模型窗口实时派生，参考上下文也按成员作用域，不引入共享摘要。
- 用户点名发言（v1），**组级单运行**，公开原文无并发写竞争；空视图与 prefill 两种退化请求被前置门挡住。
- 成员可定制：模板 + 覆盖层（工具子集 / 提示词追加 / 思考强度），持久，**创建/恢复时生效**（思考强度热更新）。
- web 组视图在真实应用里可用：会话列表按 kind 分流、公开时间线、成员分栏（含已移除）、每成员真实上下文与占用环、建组/加成员/编辑覆盖层/点名发送。
- 规模前置落地：成员视图按需装配、派生缓存跟随驻留视图、不引入无出处魔数。
- 组会话不成为第二条单 Agent 出口：任何单 Agent 入口遇到 `kind = group` 都拒绝或路由。

**Non-Goals:**
- 成员轮转、主持人、自由抢话、并行成员发言（调度只做「用户点名一个 + 组级单运行门」）。
- Flutter 侧组界面（Flutter 列表可见组会话，打开显示占位；组视图只做 web）。
- 覆盖层开放 `model` / `maxContextTokens` / provider / 系统提示词替换（只做收紧与追加）。
- 覆盖层对运行中实例的工具/提示词做逐轮热替换（v1 明确创建/恢复时生效，编辑走实例重建）。
- 改变 `spawn_subagent` 的一次性子运行语义（群成员不是子运行；`subagent-tool` 需求不动）。
- 改变模板管理行为（覆盖层是新能力，`agent-template-management` 需求不动）。
- 组间共享工作区、成员并发写同一文件的冲突裁决、@ 语法解析扩展（点名以 RPC 字段为准，@ 只是界面便利）。
- 任何 C++ sidecar 协议改动：请求形态仍是整份 messages + system + tools。

## Decisions

### D1 单一共享原文，不物理分 lane

组会话 = `sessions` 里一行（`kind = group`），组内**全部**消息（用户消息、各成员公开回复、各成员私有 thinking/工具轮）都存在这一个 `session_id` 下，共用一条 per-session `seq`。每条消息带 `author`（**稳定成员 id**；用户消息为空）与 `visibility`（`public` / `private-to-author`）。

**公开行只存正文（结构性隐私）**：组成员回合的最终公开行 `tool_calls` 与 `thinking_json` 均为 NULL、无附件；私有证据只落 private 行。现状里最终 assistant 行会写 `thinkingJson`（并在有工具轮时聚合 `tool_calls`），若不改，私有思考与工具证据就坐在一行「别人也能读」的数据上 —— 隐私会退化成「映射时记得过滤」。单会话路径不变（无跨成员投影）。
**理由**：视图是投影，不是存储分区。原文一份 ⇒ 可审计、可回放、可换视图；`seq` 一条 ⇒ 压缩 span、分页游标、时间线顺序全部沿用现有机制。
**否决的备选**：每个成员一条 `sessions` 子记录 ⇒ 原文复制 N 份、`seq` 分裂；每成员一张 lane 表 ⇒ 视图不再是原文的函数。

### D2 视图投影是唯一出口

`View(X)` = 对原文序列做「可见性过滤 + 主客体映射」：

| 原文行 | 在 `View(X)` 里 |
| --- | --- |
| 用户消息（`author` 空、public） | user 轮，原样 |
| X 自己的公开回复（`author = X` id、public） | assistant 轮，第一人称，**不带**「X 说：」前缀 |
| X 自己的私有活动（`author = X` id、private） | 按现有 replay 机制回放：assistant(thinking + tool_use) + 合成 user(tool_result)（§3.4 的协议事实） |
| 其他成员 Y 的公开回复（`author = Y` id、public） | user 轮 + 文本归属前缀「Y 说：…」（Y = 渲染时从成员行解析的显示名，含已移除成员） |
| 其他成员的私有活动 | **整体剔除**（不以任何形式出现） |

**归属只能进文本**：Anthropic 的 `MessageParam` 只有 `role`/`content`（§1.3.2），DeepSeek 兼容页未记载 Messages 可用 `name`。**连续同角色轮**：§1.3.2 明示会合并；DeepSeek 兼容端点未记载 —— 故装配层原样发出相邻同角色轮（不插填充、不改 role、不造空 text 块），live 再断言相邻 user 轮不报错。
**投影不变量**：① 成员的 `tool_use` ↔ `tool_result` 之间不夹他人公开行（工具轮按 replay 原子回放）；② `tool_result` 放在所在 user 轮 content 数组最前；③ 每条可见项恰好出现一次。
**否决的备选**：system 轮标归属（§1.3.2 明确 input messages 没有 system role）；结构化 block 标归属（污染内容，端点对未知块更严格）；用不存在的 `name` 字段（无本地文档依据）。

### D3 成员实例：句柄、DB 作用域、视图三件事分开

`Agent` 增加两样东西，避免一个 `sessionId` 兼职三份：

1. **`handle`（实例句柄）**：sidecar 上下文键 + `AgentRegistry` 键 + `cancelRequest` 目标。单会话实例 `handle == sessionId`；成员实例是成员专属句柄（`<groupId>:<memberId>`）。
2. **`member` 上下文**：`groupId` / `memberId` / 显示名 / 覆盖层；单会话为 null。压缩作用域、组角色提示词、事件身份都由它派生。

`sessionId` 保持 = 组会话 id，因为它是 **DB 作用域**：成员写消息必须落进组会话、`sessionRepo.touch` 该 touch 组会话、`spawn_subagent` 子记录的 `parent_session_id` 必须是真实会话行（外键）。反过来拿成员句柄当 `sessionId`：消息写入撞外键；拿组 id 当句柄：N 个成员共用一个 sidecar 上下文，会互相 `cancel` / 互相 `disposeContext`（后者删掉别人在用的 spill）。

**成员视图装配替换 `restore()`**：成员实例的 `_history` 是**该成员的视图序列**（他人公开回复是合成 user 项、自己的行是原始行）。每轮开始时增量装配：从上次高水位 `seq` 之后按序读取原文行、按 D2 映射；自己的新行落库后直接就是视图项。`_callModel` 与压缩的输入因此天然是视图。

**否决的备选**：成员走 `ChildRunOptions` spawn 路径（会建 `parent_session_id` 子记录、回合结束销毁上下文）；只把 `sessionId` 换成成员句柄（外键与生命周期问题）。

### D4 逐视图压缩（取代共享摘要）

压缩输入 = 该成员的视图序列（`List<Message>` 形状，**保留原始 `seq`**）。`summary_nodes` 作用域键扩成 `(session_id, member_id, start_seq, end_seq)`，单 agent 会话 `member_id` 为空、**按 `IS NULL` 匹配**走原路径（`= NULL` 匹配不到，会把单会话的去重与查询打穿）。

**为什么压缩对象是逐视图**（三条都成立才换方案）：
1. **主客体一致**：共享摘要用第三人称写「A 说…」，塞进 A 自己的视图就视角错位。逐视图摘要天然正确。
2. **钉死阈值天然满足**：阈值 = 该成员自己模型窗口 × 配置百分比，逐视图实时派生；异构窗口的预算纠结结构上消失。
3. **泄漏通道结构消失**：摘要按成员私有存储，B 取不到 A 的摘要 —— 不靠「写摘要时小心」。

**参考上下文也是泄漏通道（必须一起堵）**：`_loadReferenceCandidates` 现在取本会话全部摘要；本 change 把它与 `selectSummaryReferences` 的候选集都按 `member_id` 过滤（单会话 `IS NULL`）。否则 B 的折叠请求会带 A 的摘要。

**代价（如实写）**：公开内容按各视图各压一遍（N 倍摘要算力 + N 份存储），但按各视图自身压力触发，实际成本 ≈ 各视图需求之和；**摘要是各成员的主观记忆，客观原文才是唯一真相**，摘要发散是特性。

**锚定与替换**：摘要区域锚定**原始 seq**；投影时按成员把被覆盖区域内的可见项替换成该成员的摘要。`CompactionEngine` 的 seam 选择、生成、L2→L1→原文、`substitutesSpan` 的 2T 规则全部复用，只换输入与作用域。

**摘要纪律只保留归属**：摘要请求追加「他人的话仍是「Y 说」，不得改写成第一人称」；**不加**"自包含 + 文件指针"（那是公开回复的纪律，摘要私有、跨成员不读）。

**压缩阈值自检五问（`TODO.md` 顶部要求，逐条回答）**：
1. 每个「何时触发/合并/停止」的判据是否全是 token？—— 是。触发与合并仍是 `thresholdTokens` 派生的 `T`；成员视图只换「`maxContextTokens` 取谁的」，无数条/轮次/层级门槛。
2. 阈值算出来还是写死？—— 算出来的，唯一计算点 `thresholdTokens`；百分比来自该成员模板的 `compaction_threshold_percent`（缺省 25，非法值回落并打日志）。
3. 换 1M 窗口会自动翻倍吗？—— 会：`maxContextTokens` 是每个成员自己实例的生效窗口（`agent-config` 的「生效上下文窗口的解析顺序」），换模板/模型即换窗口。
4. 有没有为跑起来加计数门？—— 没有。
5. 够得着百分比阈值吗？—— 够：逐视图的 `T` 是该成员窗口的 25%，视图就是它要压的那份内容，与单会话同一预算；不会因为"共享摘要要服务两种窗口"永远够不着。

### D5 调度 v1：用户点名 + 组级单运行门 + 两个前置门

`group.send` 必须带**一个** `speaker`；只跑该成员一轮。**组级单运行门**：按 `groupId` 级别的运行锁/注册判断 —— 组内已有成员在跑时，点名任何成员都返回可归因 busy（不是只查目标成员自己的忙闲，否则甲跑、乙被点名时仍会并发写公开原文）。

发送可带一条用户消息：带时由该轮写入一次（`author` 空、public）；不带时**不写空用户行**。两个前置门：
- 不带文本且该成员视图为空 → 可归因错误（不发 `messages: []`）；
- 不带文本且最后一条可见项是**本人 assistant 轮** → 可归因错误（否则退化成 prefill 续写）。

删除/移除成员时先取消其实例。**否决的备选**：并行发言（写竞争 + 归属时序不可复现）、自由抢话（需调度器与仲裁，下个 change）。

### D6 两段提示词纪律，都是代码常量

- `kGroupMemberRolePrompt`：附加在成员系统提示词之后（复用 `systemPromptSuffix` seam，先例 `kSubagentRolePrompt`）。五件事：他人以「Y 说：」出现在 user 轮；自己的历史以 assistant 轮呈现；他人的工具过程不可见；**公开回复**必须自包含（结论 + 文件指针）；共享工作区是协调通道。**先例原文**（`kSubagentRolePrompt`，多段相邻字面量拼成）：「结束时只输出一段自包含的最终结论（必要的背景、」+「结论与文件路径都写清楚）」—— 群角色说明把这条纪律从"子 Agent 的最终结论"泛化到"成员的每一次公开回复"。
- `kGroupSummaryPromptSuffix`：摘要请求追加**归属**纪律（「Y 说」不得改写成第一人称）；**不含**自包含要求。

写成常量的理由：文档守卫与单测能断言「提示词里真的写了这几句」，否则「纪律只写在 spec 里」无法验证。

### D7 共享工作区：由 group.create 产生

组会话没有单 Agent，也就没人替它建上下文 —— 所以 `group.create` SHALL 先 `ensureContext(groupId, defaultWorkspace: workspace ?? ConfigService.homeDir)`（`workspace` 为 RPC 可选参数，缺省复用 `Agent.ensureContext` 的既有缺省，不发明第二个缺省值）。成员创建时 `sidecar.getWorkspace(groupId)` 只读拿组工作区，再 `ensureContext(memberHandle, defaultWorkspace: groupWorkspace)`。成员是持久实例：不建 `parent_session_id` 子记录、不随回合销毁。

### D8 覆盖层：模板 + 会话/成员级覆盖（新能力 `agent-instance-overrides`）

解析点只有一个：`resolveCandidate(模板)` 之后把覆盖层叠上去再建实例。
- **空值三态（钉死）**：字段缺席/JSON null = 无覆盖；工具子集显式 `[]` = 零工具（交集语义）；思考强度显式 `""` = 关闭（不回落模板推导）。三者必须能区分。
- **工具子集**：`模板 tools ∩ 子集`（顺序按模板）。保存时校验：只能是模板已有工具，未知/超出模板的名字**拒绝并列名字**；模板后来删掉子集里的工具 → 求交收紧 + 一行日志（不能放回来）。
- **系统提示词追加**：append，拼在模板提示词之后。
- **`thinkingEffort`**：白名单内接受；**非白名单在保存时可归因拒绝**（复用 `AgentTemplateController.validate` 的同一判据），不静默关闭。
- **生效时机（按裁决取保守一致方案）**：工具子集与提示词追加 = **实例创建/恢复时生效**，与模板非推理字段同口径（`kAgentTemplateEffectiveNote` 原文：「只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。」）。**不新增逐轮 seam**。`thinkingEffort` 沿用既有热更新（下一消息生效）。`model`/窗口仍模板级冻结。
- **编辑即重建**：`group.member.update` 原地改成员（id 不变）并**销毁旧实例、按新配置重建**；会话级覆盖层编辑同理（重建该会话实例）。否则会出现"界面显示改了、请求还是旧配置"。
- **存储**：成员行与会话行的 `overrides_json`（DB，持久，同一个解析器）；模板降为预设；**不新增 `config.json` 键**。
- 单 agent 会话与群成员走同一条解析路径。

**否决的备选**：把覆盖层写进 `agent_types`（模板变成会话专属副本）；在 `config.json` 里按 sessionId 写覆盖（运行期 UUID 进配置解析路径）；工具/提示词逐轮热替换（与 `kAgentTemplateEffectiveNote` 的既有口径冲突，且要新增每轮 seam）。

### D9 规模前置：按需装配 + 由阈值界定 + 缓存跟随驻留

现状 `Agent.restore()` 全量载入并常驻；N 个成员直接沿用就是 N 份全量历史。做法：
- 成员视图**按 `seq` 区间**流式装配；不调用 `queryBySession` 全量查询。
- 被该成员摘要覆盖的区间不常驻，需要时按 `seq` 区间按需读。
- 驻留集由**该成员的 `T`** 界定（超过 `T` 就被该成员自己的压缩折叠）。
- 公开原文行解析结果可跨成员复用（行不可变，按 `seq` 缓存）；私有回放各成员各一份。
- **派生缓存生命周期跟随驻留视图**：缓存只保留当前驻留视图的 seq 并集；行被摘要覆盖或离开视图即淘汰。不设这个规则，长会话的缓存会覆盖整条原文，"驻留由 `T` 界定"被绕过。
- **不引入魔数**：不新增任何写死的缓存条数/字节上限；确需上限只允许做成配置键并登记到 `configuration.md`。当前设计不需要这样的上限。

### D10 RPC 与事件

- 8 个群聊方法：`group.create` / `group.list` / `group.delete` / `group.member.add` / `group.member.remove` / `group.member.update` / `group.send`（带 `speaker`）/ `group.view`（成员 id），全部进 `kCoreRpcMethodNames`；失败可归因。
- `group.list` 每项带成员清单：id / 显示名 / 模板名 / `removedAt` / `overrides` / `effective`（生效工具清单、生效思考模式与强度）—— 覆盖层"真的生效"在界面上可核，**不额外加"列成员"方法**。
- `group.view` 只返回该成员**本次运行内**最近一次真实发出的快照（`toRawJson` + window/breakdown）；从未发言 → 空，界面占位。**不**用历史拼「没发过的上下文」；重启后为空是既定语义（与真实上下文视图"自本次启动以来"一致）。
- `message.query` 序列化加 `author` / `visibility`（不改分页语义；用户有权看全量，服务端不做可见性过滤）。
- `agent.event` 在既有 `sessionId` 之外加 `groupId` / `memberId`。
- `session.list` 带 `kind` 与 `overrides`（客户端据此分流 + 显示会话级覆盖层）。
- **`agent.cancel` 组路由**：组会话按 `groupId` 找运行中的成员：有则取消并返回 `memberId`；无则返回「该组当前没有成员在运行」（真话）；带 `memberId` 时只取消该成员，不在运行则指名可归因。**不允许**按 sessionId 查实例表后返回假原因。

### D11 web 组视图：真实应用可达

- 会话列表按 `kind` 分流：组 → 组视图，单会话 → 聊天屏。组件必须挂进 `App.tsx` 的真实路由，不能只存在于 harness。
- 组视图 = 公开时间线 + 成员私有分栏（切换/并排，含「已移除」栏）+ 每成员真实上下文视图（`RealContextView` + `group.view`）+ 每成员占用环（`ContextRing` + `ringSegments`，分母是**该成员自己的窗口**）。
- 操作面：建组、加成员、编辑覆盖层、选发言人并发送（`group.send.speaker`）。成员管理复用既有 web 管理页形态，不新造第二套管理界面。
- **验收以 payload 为判据**：e2e 断言 `group.send` 的 `params.speaker`、事件里的 `groupId`/`memberId` 落到哪个分栏；DOM 选中值只作辅助（`layout.mjs` 的 DOM 回退教训：页面状态对不代表参数对）。
- Flutter：组会话在会话列表可见，打开显示「请在 web 组视图打开」占位。

### D12 隐私不变量：结构保证 + 输入通道验收

- 公开行只存正文（D1），私有证据只在 private 行。
- 摘要在成员作用域存储；**参考上下文也按成员作用域**（D4）。
- 验收打**输入通道**：摘要请求实际收到的 folded 文本与参考块、投影函数产出的 messages。摘要模型输出文本只作附加证据（假 provider 固定文本、真模型改写标记都会让"断言输出"假绿/假红）。
- 反证：A 自己的视图里必须能看到标记（防止"两边都丢"也过）。

### D13 明确不修改的既有能力（读过主 spec 原文后的裁定）

- `real-context-view`：锚点是 Flutter 的 `ChatScreenState.contextSnapshot`（「expose it as a readable getter `ChatScreenState.contextSnapshot`」）；本期群视图只做 web。故不改。
- `context-occupancy-ring`：原文口径是「产生本次 `ContextSnapshot` 的 Agent 的实例生效窗口」，天然逐实例；每成员环只是同一口径的重复应用。故不改。
- `subagent-tool`：spawn 保持一次性子运行，群成员不是子运行。故不改。
- `agent-template-management`：模板仍是预设，覆盖层是外加一层。故不改。
- `web-chat-screen`：群视图是新增屏幕，既有聊天屏的渲染/分页/重连需求不被推翻。故不改。
- `user-documentation`：要求是「每个用户可达功能都要有一份文档」，新增 `group-chat.md` 即满足，不改需求文本。

### D14 迁移计划（schema v8 → v9）

1. `messages` 加 `author TEXT`（可空）与 `visibility TEXT NOT NULL DEFAULT 'public'`。
2. `sessions` 加 `kind TEXT NOT NULL DEFAULT 'single'` 与 `overrides_json TEXT`。
3. 新建 `group_members`（`id` / `group_session_id REFERENCES sessions(id) ON DELETE CASCADE` / `name` / `template_name` / `overrides_json` / `removed_at` / `created_at`）；成员名唯一用**部分唯一索引**（`UNIQUE(group_session_id, name) WHERE removed_at IS NULL`），软删行不挡同名重建。
4. `summary_nodes` 加 `member_id TEXT`（可空），建含 `member_id` 的 span 索引与 leaf_owner 索引；旧行 NULL = 单会话路径（读/写/删除一律 `IS NULL` 匹配）。
5. `_onCreate` 与 `openAt` 两处 schema 镜像；迁移只加列/加表/加索引，旧行语义：`visibility='public'`、`author=NULL`、`kind='single'`、`overrides_json=NULL`、`member_id=NULL`。
6. **验证方式**：升级产物与全新建库分别取 `PRAGMA table_info` / `PRAGMA index_list` 逐项比对（列名/类型/默认值/索引名与列），不是"看起来一样"。既有 `schema_migration_test` 里 `getVersion() == 8` 的断言**实测有三处**（裁决里说两处，以文件为准），要一起改成 9。
7. **回退**：数据库版本只向前；回退代码前须用迁移前库文件备份（sqflite 对降级不做静默处理）。真实用户数据不删任何行。

### D15 文档同步（守卫强度如实写）

- 新建 `Docs/user-guide/group-chat.md` + `README.md` 功能索引一行。已知限制写明：看不到他人私有过程、成员看不到彼此工具证据、调度只支持点名、**重启后成员真实上下文视图为空**、组会话在 Flutter 只有占位。
- `configuration.md` 补「成员/会话覆盖层」：三字段（`toolsSubset` / `systemPromptAppend` / `thinkingEffort`）、空值三态、生效时机（创建/恢复 + 思考强度热更新 + 编辑重建）、并明确它们**不是** `config.json` 键（存在成员/会话行的 `overrides_json` 里）。
- `web-core-shim.md` 与 `web-management.md` 的 RPC 表各补 8 个群聊方法（两个守卫都是**整份文档子串包含**，不解析表格，漏写即红）。
- 文档守卫（新增 `test/unit/group_docs_test.dart`）：**解析 RPC 表的行**（不是"文档任意处出现即可"）；覆盖层字段名从代码常量取；`author` / `visibility` / `public` 登记进 `user_docs_test._otherCodeNames` 时指向**真实解析符号所在文件**（`Message.toRow` / `fromRow` 的列名），不是随手写个文件路径。

### D16 kind 分派守卫（堵第二条出口）

组会话出现在顶层列表 ⇒ 三条现状入口都会把它当单会话：`main.dart._loadSessions` 对每个会话 `_ensureAgentFor`、`_handleAgentSend` 直接 `factory.ensure`、`_handleSessionSwitchTemplate` 直接切模板。一旦命中，`Agent.restore()` 会把组原文（含他人 private 行）全量载入并喂模型 —— 这就在投影之外开了第二个出口。
做法：`Session.kind` + 三处守卫。启动恢复与列表渲染保留组会话（可见），但**不建实例**；`agent.send` 对组会话返回可归因错误（指明走群聊 RPC）；`session.switchTemplate` 对组会话拒绝；Flutter 打开组会话显示「请在 web 组视图打开」占位。`serializeSession` 加 `kind`，`session.list` 消费者据此分流。
**验收**：建组 → `session.list` 含组 → 单会话入口（恢复/发送/切模板）不建 Agent、不套模板；任何单 Agent 请求的 messages 不含他人 private 行。

### D17 成员身份与软删

`author` 存**稳定成员 id**，显示名渲染时从 `group_members` 解析（改名不改归属）。成员移除是**软删**（`removed_at`），行保留 ⇒ 历史行始终有归属；`group.list` 返回已移除成员（带 `removedAt`），客户端渲染「已移除」分栏。移除后同名重建 = 新 id，看不到旧私有行。`group.member.update` 原地改 id 不变（改名/换模板/改覆盖层都走它），并重建实例。

### D18 取消路由

`agent.cancel` 现在是 `agents.lookup(sessionId)`；组会话的 sessionId 不是任何实例的键 ⇒ 永远 `cancelled:false` + 假原因。组会话 SHALL 按 `groupId` 找在运行的成员（组级单运行门保证至多一个），返回 `memberId`；带 `memberId` 时只取消该成员并指名结果。文档 RPC 表同步这条行为。

### D19 参考上下文成员作用域

`_loadReferenceCandidates` + `summaryNodeRepo.queryBySession` + `selectSummaryReferences` 三处一起加成员作用域（单会话 `IS NULL`）。这是本 change 新增的泄漏通道，必须与视图、摘要存储同批落地；验收断言 B 的摘要请求输入（folded + 参考块）不含 A 的标记。

### D20 测试分层与守卫诚实（按裁决）

- **仓储类断言下沉 integration**：唯一约束、级联删除、`delete-before-insert`、`findCovering` 的成员/NULL 分支用 `DatabaseService.openAt` 的真库证明；unit 只留纯模型 `toRow`/`fromRow` 与纯函数（投影、覆盖层解析、参考挑选）。
- **夹具补 `lockPath`**：核心单实例锁也要指到临时目录；隔离复核的基线包含 db/config/**core.lock**，日志（`~/.aliasagent/logs`）列为**已知副作用**（测试不追求零写入日志）。
- **视觉验收**使用临时 config / DB / lock / attachments，不碰用户真实目录。
- **迁移验证**用 `PRAGMA table_info` / `index_list` 与全新建库对比；`schema_migration_test` 里**三处**版本断言一起改（实测三处，非两处）。
- **文档守卫如实**：既有 web 文档守卫是整份文档子串包含（从宽），新增的群聊守卫解析 RPC 表行；`_otherCodeNames` 指向真实解析符号。
- 补两条断言：同一公开行在两成员视图里解析计数 = 1；两成员窗口不同时环分母各为各自 `window`。

## Risks / Trade-offs

- **[N 倍摘要算力与存储]** → 逐视图按各自压力触发，成本 ≈ 各视图需求之和；成员数由用户自选。摘要发散是特性（原文唯一）。
- **[成员视图内存]** → D9 前置：按需装配 + 驻留由 `T` 界定 + 缓存跟随驻留；「全量查询即抛错」仓库与「缓存不随会话增长」两条用例守。
- **[组会话被当单会话恢复]** → D16 三处守卫 + integration 用例（建组→单会话入口不建实例→无他人 private 行）。这是最高优先的出口泄漏。
- **[参考上下文泄漏]** → D19 三处成员作用域 + 6.1 输入通道断言（参考块漏作用域即红）。
- **[红靶打错通道]** → D12/D20：红靶打输入通道；摘要模型输出只作附加证据。
- **[归属前缀污染正文]** → 只在他人公开回复上；摘要保留归属；不引入伪 `name`。
- **[公开行只存正文导致组会话丢"整轮工具调用聚合"]** → 只影响组会话最终公开行；私有行保留证据、自己的视图照常回放；单会话不变。测试断言 `tool_calls` 与 `thinking_json` 均 NULL。
- **[覆盖层"改了没生效"]** → 创建/恢复生效 + 编辑重建实例 + 两次请求快照对比用例；界面 `effective` 字段可核。
- **[模板漂移让覆盖层子集变窄]** → 每次实例创建/恢复求交 + 一行日志；成员配置视图显示生效清单。
- **[web 私有分栏与分页配合]** → 分页仍按 `seq`；已加载页按 `author`/`visibility` 分流，上翻补两栏；已移除成员行也有去处。
- **[迁移不可回退]** → 文档与任务写明回退需迁移前备份；迁移只加列/表，不删行。
- **[测试写用户真实目录]** → 夹具 `lockPath` + 视觉验收临时目录 + 复核 db/config/core.lock；日志列为已知副作用。

## Open Questions

- 私有分栏默认是「并排」还是「切换」：留给 web 组视图的视觉验收定（不影响任何规范条文）。
- 成员覆盖层编辑界面的形态（抽屉 / 弹窗 / 复用模板页）：落地时按设计系统定，两种都满足"可编辑 + 生效可观察"。
- 已移除成员分栏是否默认折叠：视觉验收时定（不影响归属与数据可达性）。
