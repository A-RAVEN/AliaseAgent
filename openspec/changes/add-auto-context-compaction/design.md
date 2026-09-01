## Context

AliasAgent(Flutter 桌面 AI 对话应用,经 dart:ffi 调 C++ Sidecar,走 DeepSeek Anthropic 兼容端点)目前**对上下文无任何管理**:`_buildApiMessages`(lib/main.dart:1077-1149)把会话全量拼进 `apiMessages`,`_callModel`(main.dart:689)原样发给 sidecar;`model_gateway.cpp:500` 透传 `body["messages"]`。无截断、无压缩、无预算。

同时**零 token 度量**:`Message.token_count` 列存在(database_service.dart:42/:92)但**无 writer**;`OnDoneCallback(int, const char*, const char*)`(sidecar_api.h:46)**不带 usage**;SSE `message_start`/`message_delta`(AnthropicAPIDoc.md:354/:372)只被 LOG_TRACE(model_gateway.cpp:278-280)。

设计依据:本 change 全部技术决策固化于 `Docs/context-compression-reference.md`(含 6 视角对抗评审 + 6-claim N≥3 对抗验证 + 外部实现证据,含 Claude Code 参照 §5.4)。方案方向经对抗验证:6 条核心 claim 中 C2 SURVIVED、其余 5 条被 KILLED 后的**真缺陷均已修正**回写(见参考文档 §8)。

约束:CLAUDE.md 规定测试可观测性、不修改验收标准、无 user-in-the-loop 任务、对抗式 Workflow 诚实循环;DeepSeek 端点,严禁借 Anthropic 行为;usage 字段名随端点——Anthropic-format `/v1/messages` 用 `input_tokens`/`output_tokens`(2026-08-26 live 验证已确认,AnthropicAPIDoc.md:354/:372),`prompt_tokens`/`completion_tokens`(DeepSeekAPIDoc.md:661)是 chat/completions 字段,不适用于 `/v1/messages`。

## Goals / Non-Goals

**Goals:**
- 持续、自动地把发给模型的上下文维持在安全范围,无需手动 `/compact` 指令。
- 层级化压缩:近端原文、中端段总结、远端总结之总结;原始对话**无损留盘**(树是派生索引)。
- 通过接口**实测 usage**(Anthropic-format `/v1/messages` 的 `input_tokens`/`output_tokens`,2026-08-26 live 验证已确认)作**遥测/校准**并**驱动折叠后的尺寸判定**;上限为 per-agent-type 必填配置 `maxContextTokens`。**触发布局**由确定性本地估算器定(见 D3,非实测 usage 驱动——实测 usage 只写 `token_count` 作遥测 + 回读作尺寸判定)。
- 决策/执行分离保证**可测确定性**。

**Non-Goals:**
- 不提供手动压缩指令、不新增持续的"压缩管理"操作(仅一次性必填配置 `maxContextTokens`,同 apiKey)。
- 不做向量/嵌入检索式长记忆(无 embedding 基建;是远未来)。
- 不修改任何既有测试/验收标准来迁就实现。
- 不追求摘要内容可与原文逐字核对(摘要本质有损;靠"保留决策 + 再执行钥匙 + 原文可 re-expand"兜底)。

## Decisions

**D1 压缩形态 = 层级化摘要树 + recency 梯度**(非单一滚动摘要 / 非滑窗截断)。
- **三层梯度(近详→远略)**:`[L2 大摘要(最旧)][L1 小摘要(中段)][原文(最新)]`——最新保留原文,中段逐段压成 L1 小摘要,最旧的多段 L1 再卷成一条 L2 "总结之总结"。**只做两级**(L1 + L2),**不引入 level-3**。L2 的**输入是 L1 摘要文本**(2-pass 总结之总结),不是原始消息。
- **coarsen-only(只并不拆)**:摘要只越并越大、绝不拆细、绝不把已摘要的重新放回原文。若连 L2 都超预算,则"省略最旧"(**投影不发给模型**),**绝不删数据**(见 D9)。**每层摘要的实际 token 数运行时实测**(真实 usage `output_tokens`),"是否超预算/该不该 coarsen/省略"由实测值后置判定——**不预设压缩比**。
- **边界归属(确定性批量 + 唯一 LLM 微调缝)**:L1 批边界 = **算术**"从最旧累计原始 token > 阈值 T 划为一批"(确定性,各批≈T、可压,用户约定"**累计>阈值→整批一次压**");AI 挑话题缝(见 D5,方案A,唯一影响树形的 LLM 点,memo 化)**只在该批边界上微调到最近安全话题缝,且必须保证每个 L1 批仍≈T 大小——绝不可把某批切成会压不动的极小段**(2026-08-29 用户约定;违者回退算术骨架);**L1→L2 组边界 = 算术**(确定性,2026-08-29 用户决定"先尝试算术")——L2 按哪些 L1 分组完全由确定性算术规则决定,不调用 LLM。即"折哪些、几段、哪层、预算"纯函数,AI 缝仅微调、不改批构成。
- 理由:对数成本、粒度梯度(近详远略)、远端"总结之总结"保留决策链;外部 remnic LCM / hierarchical-context-ai-agent 验证。
- 备选:单一滚动总结(简单但 O(N) 重写、粒度差)、滑窗截断(破坏完整性/丢失再执行钥匙)。

**D2 摘要 role 用 `user`,不塞 system**(参照 Claude Code §5.4)。
- 顶层 `system` 留作真指令;摘要 = role:user 文本 + 正文标记(`## 更早上下文(压缩xN,非用户发言)`)。DeepSeek `name` 字段(DeepSeekAPIDoc.md:221)是 **chat/completions** 消息字段,`/v1/messages` 未验证——故**首选正文文本标记**,不依赖 `name:'history'`。
- 备选:摘要进 system(污染真指令)、发明 role("history" 非合法 role)。

**D3 触发预算 = 必填配置 `maxContextTokens` + 原始尺寸本地估算器；摘要尺寸 = 运行时实测(真实 usage)，不做压缩比假设**（对齐 spec "Context budget trigger"，2026-08-29 重构）。
- 接口拿不到精确窗口(无 `/models` 元数据);**触发**用确定性本地估算器 `ContextEstimator`(逐消息 proxy token 求和)算**原始会话尺寸**——spec 明定 "deterministic local estimator (sum of per-message proxy tokens)"。**这只算原始消息 token，不涉及"摘要会压多少"**。
- **统一规则(2026-08-29 用户定稿):批量 + 每层实测判 token 变少,零压缩比**。从**最旧**开始,累加(原文片段→L1;L1 片段→L2)原始 token,**合计 > 阈值 `T = maxContextTokens ~/ 2` 就把这一批压一次**成上一级摘要;**判据 = 压出的实测 token < 这一批的 token**(有效压缩;否则**拆半再压**,确定性、必终止——拆到单条/单工具轮仍不省,则该原子批**省略**——只不进投影、数据留盘,见 D9)。**最新始终保留原文(verbatim)**:只对较旧内容批量化/摘要/省略,**绝不动最新**——若仍超预算,只继续**省略最旧的较旧内容**(只不进投影,数据不删,见 D9),**最新永远 verbatim**。逐层向新推进,到 `Σ(L2)+Σ(L1)+最新原文 ≤ maxContextTokens` 停;若**最新一段单独**就 > 预算(单条 > 上下文窗口),属病态、无法靠压缩解决,记为**已知上限**(尽力而为)。**注(实现边界)**: 名义"最新 verbatim"段是**有界近期块**,上限 `T = maxContextTokens ~/ 2`(对应 spec "which newest content stays verbatim"的**有界近期块**语义,而非"全部最新一直压到预算");一条单独 > T(即便 ≤ 预算)的最新消息会被划入远端折叠。此为对 D3 措辞的精化,**与 spec 一致**(spec 只要求"折哪些/如何折由纯函数定","最新 verbatim"是选定的有界近期块)。`buildTree` 只定批量边界(原始 token 可加、确定性),**摘要尺寸运行时实测**(真实 `output_tokens`),不预判、无 `/4`/`/16`。
- **❗实现取舍(2026-08-29 对抗审查确认)**: 设计原措辞"拆到单条/工具轮仍不省则该原子批**原样保留**"→ **实现为"省略(投影不发送,数据留盘)"**,而非按原文发送。原因: 把原子批按原文插入远端会导致投影 `[摘要前缀][verbatim 尾]` 与 role 交替失去一致(远端内容混进 near);省略同样满足"绝不发送不小于原批的摘要" + 数据不删(D9),且不违反任何 spec SHALL(spec.md:6 的 omit 是预算驱动的合法动作)。**已知保真代价**: 极小的原子消息(如远端一个短用户输入)若其摘要(含结构开销)≥自身 raw,会被静默从投影丢弃,而"原样保留"可近似 raw 成本保回。**若需严格原样保留,须在投影层重构(verbatim 就地交错)——本轮不做**,如实记录。
- **实测 usage**：DeepSeek `/v1/messages`(Anthropic 格式)usage 字段为 `input_tokens`/`output_tokens`(AnthropicAPIDoc.md:354/:372；**2026-08-26 live 验证已确认**)。侧车防御性解析；`prompt_tokens`(:661)是 chat/completions 字段,不适用。真实 usage 写入 `Message.token_count`(task 1.3)作遥测 + 破平衡点回归(task 5.2)依据,并**驱动折叠后的尺寸判定**(回读,不是只当遥测)。
- 必填(同 apiKey);`stop_reason: length` 不作触发(:328 语义含糊)。

**D4 确定性与成本:统一"批量 + 每层实测判 token 变少",零压缩比假设,批量边界纯函数**。
- **批量边界是纯函数**(确定):从最旧开始累加原始 token,合计 > 阈值 `T = maxContextTokens ~/ 2` 就划为一个 L1 批;累加 L1 token 合计 > T 划为一个 L2 批。原始 token 可加、确定性,故边界确定。AI 缝(4.3)在其上挑话题边界(唯一 LLM 树形点,memo 化)。
- **每层摘要尺寸运行时实测**(真实 `/v1/messages` `output_tokens`):每压一批**量一次**,判"压出的 token < 这一批的 token"(有效压缩;否则**拆半再压**,确定性必终止;拆到单条/单工具轮仍不省则该原子批**省略**——只不进投影、数据留盘 D9;见 D3 实现取舍注)。budget/coarsen/omit 由此实测值后置判定。**零压缩比假设**(无 `/4`/`/16`)。
- **每层有效性判定的实现细节**: "拆半再压"在 **L1(原文→L1)** 由 `_resolveOpenLevel1` 递归执行;在 **L2(L1 摘要→L2)** 无效压缩(实测 L2 token ≥ 被替换的 L1 摘要 token 之和)则**不采纳该 L2、改 omit 最旧的 open L1**(数据留盘 D9),而非拆半再压——实现比"每层同样拆半"更省调用且同样保证"绝不采纳不小于其替换内容的摘要"。此为设计措辞与实现的行为差异,**如实记录**,非缺陷。
- **最新始终保留原文**(verbatim):只对较旧内容批量化/摘要/省略,**绝不动最新**;仍超预算只继续**省略最旧的较旧内容**(数据不删),**最新永远 verbatim**。`buildTree` 只保证批量边界确定性 + 保留原文;不保证"压完必小于预算"——靠实测 + 调整达成。最新单段单独超预算 = 病态已知上限。
- **输入集含"已闭段"(见 D8 渐进封口)**:`buildTree(history, maxContextTokens, closedSegments)` 以闭段为输入之一,故边界纯函数;已闭段永不重塑,冻结复用已存实测 `token_cost`。

**D5 语义边界选 A(LLM 在安全候选点挑话题缝),memo 化保可复现**。
- 结构安全切点可能拆开话题簇;A 把边界选择嵌入同一次摘要调用(边际成本小),memo 化(内容哈希 keyed)让重建/测试可复现。**它是"纯函数折叠计划"的唯一例外(只影响缝,不改'折哪些段'),且被 memo 化**。
- **实现机制(2026-08-29 调和批量 + AI 缝)**: 批量边界由"累加原始 token > 阈值 T"确定(算术、纯函数);`SeamSelector`(服务)在其上**选最近的安全话题缝**——异步 `ensure(batchRegion)`:当某批累积到 T 附近时,向模型请求该批内"最接近 T 的若干安全候选索引中,哪个是话题边界",按内容哈希缓存;失败/解析失败回退算术边界。**绝不让缝拆分工具轮**(缝必须落在真实用户文本/无工具 assistant 终答上)、**绝不改批量结构**(只微调分界位置以不拆话题簇)。**尺寸守卫(2026-09-01 补,防执行偏离)**: 微调后任一批 raw < `max(1, T~/2, 1025)`(1025 = summary profile 上限 `max_tokens=1024`+1,即"必然压不动"的边界;把 `T~/2` 与压缩上限取 max,是因为真实压缩边界是 1024 而非 T~/2——`T~/2` 可能 < 1024,见 R-A2-5c)→ 该缝必须被**拒**、**回退整段确定性算术骨架**(配置-话题并入首批一起压,而不是"原样发送"——"原样发送"会把最旧原文插进投影破坏 `[摘要][verbatim 尾]` 结构,见 D3 实现取舍)——保证批 raw > 1024(摘要 ≤1024 必 < raw)≈ 可压,**绝不让极小批被 split-if-invalid 整段 bloat-omit**(否则再执行钥匙/绝对路径丢失)。守卫只对"批 ≥ ~T 且 >1024"的大规模折叠有意义;小预算/小对话的批必 <1025,seam 一律回退算术(正确——小对话无需话题微调)。生产在 `_callModel` 先按批量边界预取 memo,再以 memo 背板 seam 微调分界;密封测试注入 `FakeSeamSelector` 或留 null(走算术边界,不额外消费 FakeSidecar 事件)。这是"纯函数折叠计划"的唯一 LLM 树形点,且被 memo 化。
- **两道切分标记圈定一个"已闭段"**:AI 在安全候选点落下前后两道标记,标记之间的历史即闭段 — 其内容与摘要在闭段后固定(见 D8 闭段冻结)。
- **❗实现偏差警告(历史;已被 ⑪ 取代)**:(原说法)Phase-1/2 代码(`_budgetSegments`)的**确定性骨架正确、仅边界缝用算术**——该说法里的"**骨架正确**"**只对**"安全边界/工具轮原子性/不重不漏 cover"成立;其"折哪些段、几段、预算"的批量划分规则基于 `/4` 成本 + 每~8条,已被 ⑪(`buildTree` 改"原始 token > T 批量")**作废**。边界缝由 AI 挑话题缝(4.3, 方案A, memo 化)这一方向保留,但**AI 缝只"微调原始 token 批量边界到最近安全话题缝",不得 wholesale 替换批量结构**(⑪ 会相应改 `_segmentsFromSeams`)。spec "Semantic boundary selection (topic seams)" 是关于"缝"的正确要求。
- 备选:C(结构切+recency 兜底,简单但保留接缝丢细节)。

**D-guard 不变量守卫(用户目标/验收标准/不变量永不塌缩)**。
- 用户目标、验收标准、"don't touch X" 不变量被 pin 为**不可压缩锚点**,每轮重注入(system 或消息头部),无论多旧都不塌缩。锚点集合**有界、去重、可失效**(随用户撤销需求淘汰);来源为**显式 standing-requirements 机制**(非 LLM 从 prose 抽取,temp=1 非确定)。这与 CLAUDE.md"禁止改验收标准"呼应。

**D6 折叠原子单元 = 完整工具轮 + 段边界规则 + node_type 门控**。
- 原子单元 = 带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result)(main.dart:1125-1147);绝不拆开。
- 段边界只落(a)真实用户文本 / (b)无 tool_use 的 assistant 终答;绝不落带 tool_calls 的行。
- 带 tool_calls 的叶子**永原样展开(node_type)**,无论多旧(近端超大 `tool_result` **正文**可按 Near-zone elision requirement 裁为"标记+再取记录",轮结构/工具对不变);纯文本输出,不合成 thinking/tool_use/tool_result 块(DeepSeekAPIDoc.md:199 等正确理由)。

**D7 压缩调用复用 `model_gateway`,用"摘要 profile"(关 thinking、`max_tokens` 512-1024、可选更便宜模型)**。
- 同一 `/v1/messages` 端点,末端 user 消息追加 summarize 指令(参照 Claude Code `querySource:'compact'`)。

**D8 后台折卷 idle-gated + 可抢占(request-id 定向)+ 断点续 + 事务原子落库 + 闭段冻结(渐进封口)**。
- 单槽(模型路径);折卷与用户请求轮换共享、用户优先;`summary_nodes` 表事务写 + `tree_version` 递增;materialize == buildTree(后台路径=纯函数)。
- **抢占 = request-id 定向 cancel(2026-08-30 实施,满足 spec "never delays")**: 初版单槽全局 `cancel_flag`(execute() 每新请求重置)无法完全定向;现改为**真正的 per-request-id cancel**——Dart bridge 每个 `sendMessage` 分配唯一 `requestId`(enqueue 前)并传入 C++ `send_message`;C++ `execute(..., request_id)` 用 `std::atomic<int> cancel_request_id`(**execute 不重置**)+ `cancel(int request_id)` 设它;execute 起始查 `cancel_request_id==rid` → 立即 abort(close **enqueue→start** 窗口),`xferinfo_cb` 亦查它(in-flight);用户请求取不同 id,**不受影响**。Dart 侧另: fold 每个模型调用点(seam/`_resolveOpenLevel1`/`_l1SummaryText`/Phase A,B)均有 isAborted gate + `_sendMessage` 抢占对 pending timer 也生效 + 导航 bump `_foldGen` 并取消待定时器。C++ 测试(http_client/sse_parser + `[reqid]` targeted-cancel 新增 2 测)离线经 local mock server 全绿。
- **闭段冻结(progressive closure)**:某段被两道切分标记圈定后,其消息内容与摘要即固定为永久历史 — 摘要落库**一次**,此后逐轮从持久化节点**复用,绝不重新摘要**;dirty-seq 惰性重算**只作用于未封口的尾部**,已闭段不参与(其内容因工具轮已完结而不再被 `updateToolCalls` 触及)。`buildTree` 因此是**渐进封口**的纯函数:读入已持久化的闭段边界作为输入,只对未闭尾部决定"再封几段",绝不重塑已闭段。**注:当前 reuse-gate(复用闸门)尚无显式"已闭段强制命中缓存"逻辑——这是 tasks ⑨ 要实现的落点此处为设计目标,非现状。**
- **`materialize` 必须 UPSERT(不是裸 INSERT)**:同一事务内先删同 `(session_id, covered_min_seq, covered_max_seq)` 的旧行再插。否则同 span 因 staleness 重算时会叠重复行 → ①违反 D9「covered 稠密非重叠」②`findCovering` 无 ORDER BY 取 `rows.first`(=旧 stale 行)→ stale reuse。此即 2026-08-28 设计一致性审计抓到的真实缺陷(见附录 A)。**渐进封口只关闭了"已闭段重复写"的常见触发路径;UPSERT 仍是 load-bearing(承载性)的——任何发生在未闭尾部/预算变化/dirty 尾部的重算都可能对同 span 再次 materialize,必须"先删旧行再插"才能维持 D9 稠密非重叠 + `findCovering` 取最新。不得弱化为"纯防御/可能不触发"。**
- 注意:串行化的**只是模型路径**,web_search/web_fetch 在独立 worker isolate(不可与用户模型请求并发但工具/网络路径未被门控)。

**D9 存储:seq 全序 + `summary_nodes` 树 + 派生索引**。
- `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;树边界用 `(session_id, start_seq, end_seq)`,不用 UUID。
- `summary_nodes`:(session_id, level, start_seq, end_seq, node_type, parent_id, summary_json, token_cost, summary_prompt_version, model, covered_min_seq, covered_max_seq);`summary_json`(role blocks)非单段 text;covered_min/max **稠密非重叠**(由 `materialize` 的 UPSERT 保证——**load-bearing**,任何重算都必须"先删旧行再插",见 D8);+ `leaf_owner` 平面索引;parent_id 仅导航;**parent 导航逻辑属 Phase-3 level-2 成树后行为,当前 DEFERRED**(列已铺、行为未落地);memo 化摘要(content hash + prompt version + model)。**闭段的 `covered_min/max_seq` 即其两道切分标记,持久化后驱动后续复用的"冻结"判定。**
- 原始 `messages` 表逐字保留;树节点按需展开路径由 harness 注入(非 agent 工具)。**三层皆不可变持久化**:原文(消息表)+ L1 小摘要 + L2 大摘要都作为稳定数据落盘,永不删除;"**省略最旧**"仅是**投影决定**(这次不发给模型),**绝不等于删除数据**——被省略的内容仍在磁盘,将来可由 harness/agent 的 **re-expand 机制**(本轮不实现,仅占位)从磁盘重新展开。**禁止把"省略/丢弃"实现为删库/删行。**

**D10 便宜层优先 + 折卷预算**。
- 先用 DeepSeek prompt-caching(user_id,:241)+ **对远端采用"已存在的更粗摘要层"**(不是直接裁剪、不丢决策/再执行钥匙)作为便宜层;近端超大 `tool_result` **正文**(非工具对)允许轮内裁剪为"截断标记 + 再取记录"(保住 tool_use 块与工具对,不折叠该轮);LLM 树仅长会话升级。每会话折卷次数/token 上限 + 破平衡点回归(折卷 input ≪ 每请求省下 input)。

## Risks / Trade-offs

- [压缩本质有损] → 摘要保留决策/结论 + 再执行钥匙(tool_input 原文/绝对路径)+ 原文留盘可 re-expand;live 连续性测试 + 对抗审查兜底。
  - **A-2 窗口 live 定位(与 P1 行为连续性互补, corrected)**: 窗口真模型 live(`integration_test/` + `-d windows`)是 change 自规划的 **P1 行为连续性**形态——设 cap 远低于真实窗口跑 N 轮,断言不超限 + **助手能引用早期上下文/决策**(观察通道 = 实际工具调用 + 文件终态);摘要"措辞质量"好坏不单测(`Docs/context-compression-reference.md:165`),靠 live 行为 + 对抗审查兜底。A-2 在**此基础上额外**经**自身临时 DB 的 `summary_nodes`** 读回**真实摘要文本**并断言其保留再执行钥匙:调用 `SummaryNodeRepository.queryBySession`(summary_node_repository.dart:104)+ **测试侧自行解析 `node.summaryJson` 的 `content[].text`**(不能用不同 library 的私有 `ChatScreenState._summaryTextFromJson`);折叠经 **`AppShell(configLoader: () => ConfigResult.ok(小 maxContextTokens))`**(main.dart:70-71)注入触发,不用读真实 `/Users/.../config.json` 的 `const MyApp()`。**不否定行为连续性、不拆两路、不下放 offline Fake**;此为**字面 key 存在性**(强于 design 保留合同,合规有损 summarizer 会 false-fail)的补充信号,需跨 benchmark 标定。
- [tool_use/tool_result 拆分导致 API 400] → 原子单元 + 边界规则 + node_type 门控 + 工具对完整属性测试。
- [单槽折卷卡用户 / 抢占误杀用户请求] → request-id 定向 cancel + `_chain` 空时入队 + 断点续;折卷绝不进入用户关键路径。
- [非确定摘要破坏测试确定性] → 决策/执行分离 + FakeSummarizer + memo 化;断言树形不断言措辞。
- [边界拆话题(语义)] → A 方案 LLM 挑话题缝,memo 化保确定性;测试注 FakeSummarizer 固定边界。
- [预算锚点不可验证] → 必填 `maxContextTokens` + 实测 usage;未授权时不借 Anthropic 数字;已知精确窗口仅让用户填得更准(可选)。
- [旧库迁移 / 同毫秒排序] → seq 回填 best-effort;不给旧数据预建 rollup;schema 镜像 `openAt`;迁移测试。
- [web_search/web_fetch 未被单槽门控] → 折卷只走模型路径;工具/网络路径的记录处理按 §3.2(web_fetch/web_search 不视为幂等读轮)。

## Migration Plan

1. **schema v3→v4**:`messages` 加 `seq INTEGER`(backfill by created_at+rowid,best-effort)+ `(session_id, seq)` 索引;新增 `summary_nodes` 表;新增每会话 `tree_version`。**不给旧数据预建 rollup**(旧消息作未压缩叶子,惰性向前建高水位);schema 镜像到 `openAt`(database_service.dart:69-111);补 v3→v4 迁移测试。
2. **Phase 0 先行**:usage 遥测(解析 `/v1/messages` 的 `message_start`/`message_delta` usage → 新 FFI 回调 → `token_count`)+ seq 列 + 必填 `maxContextTokens` 配置。此阶段无压缩行为变化。
3. **配置迁移**:首次启动设置对话框增加 `maxContextTokens` 必填项(同 apiKey 引导)。
4. **回滚**:停用压缩(不建压缩树、直接全量)即回到现行为;树是派生索引,删除 `summary_nodes`/`tree_version` 即回到无压缩(原始 `messages` 仍在)。

## Open Questions

- 语义边界 A 的 memo 键 / 是否复用同一摘要调用(实现层,我把关;见参考文档 §8 D1/D2/D3 已降级为实现细节)。
- DeepSeek `/v1/messages`(Anthropic 兼容)的 usage 精确字段名(Anthropic 格式 `input_tokens`/`output_tokens`)——已确认(2026-08-26 live 探测,见 D3);`prompt_tokens` 是 chat/completions 字段。精确窗口数(可选优化,不做前置;用户授权时从官方核实)。
- 摘要是否要"意图叙述"还是纯结构化记录(tool_input/outcome/refetch_hint 是数据,可纯机械;叙述部分可选)。

---

## 附录 A — 对抗审查证据记录（Round 1/2/3; 仅证据链，不作任务解析）

> 本附录记录各轮对抗 Workflow 的发现证据、refute/NOT-a-bug 判定，用于回溯。**不作为可执行任务** — 可执行任务在 `tasks.md` Section 0（返工）与 Section 1-8（原始任务 + 诚实审查）。所有 Workflow 均为 N≥3 REFUTING skeptics per finding、perspective-diverse、majority-kill、STRICTLY OFFLINE（只读本地文件，外部真实性对照 `Docs/*.md`）。

### R1（55 agents）— 已修复问题（其修复已在 tasks.md 1.1-1.7 保留 `[x]`）

- R1-1 summary profile 须发 `thinking.type=disabled`（DeepSeek 缺省 enabled，absence≠disable）。已修 model_gateway.cpp。**注意**: 该修复只加在 summary 分支(549)，交互 else(552) 未加 — 见返工 ①。
- R1-2 `dispatch_done` `stop_reason.c_str()` 悬垂于临时字符串("") — UB。已修（走 stable pending_strings）。
- R1-3 compaction 投影不得发连续 role:user（DeepSeek 未记载 same-role merge）。已修（所有摘要并入一个 role:user 前缀）。
- R1-4 安全段边界不得落入带 tool_calls 的 assistant。已修 `_alignToSafeBoundary`。**注意**: 仅修 far/near 缝(103)，内部 `_budgetSegments` chunk 未对齐 — 见返工 ④。
- R1-5 摘要失败不得静默替换上下文为 "(empty summary)"。已修（ModelSummaryProvider 在 done(-1) 抛错，_callModel 回退全量 verbatim）。
- R1-6 加 v3→v4 迁移测试。已加 schema_migration_test.dart。

### R2（34 agents）— Round-2 发现

- **R2-1 thinking 禁用机制（EXTERNAL-TRUTH，2026-08-26 live 探测解决）**: `thinking.type="disabled"` 在 `/v1/messages` 实测有效（无 reasoning block）；`reasoning.effort="none"` 实测无效（仍有 block）。当前 summary 分支(549)正确。→ 返工 ⑧（改注释）+ Docs 已修。同探针确认 usage 字段为 `input_tokens`/`output_tokens`（tasks 1.1/5.4 的 `[UNVERIFIED]` 已解除）。
- **R2-2 task 3.1 dirty-seq 水位线/按受影响 span lazy 重算缺失**（stateless 整树重算 + 整表 bump）→ 返工 ⑥。
- **R2-3 task 2.9 guard 生产失效**（`_guard=GuardAnchors()` 空实现，零生产 seed，inject 恒'') → 返工 ⑦。
- **R2-4 内部 `_budgetSegments` chunk 边界未安全对齐** → 返工 ④。
- **R2-5 "original messages preserved" 测试名不符实**（只查 sqlite_master 表名）→ 返工 ②。
- **R2-6 under-budget 投影测试无 `[OBS]` dump** → 返工 ③。
- **R2-7 summary_node_repository 两测试无 `[OBS]` dump** → 返工 ③。
- **R2-8 schema_migration_test 无 `[OBS]` dump** → 返工 ③。
- **R2-9 决策点**（R2-1/R2-2 需决策）— 经 live 探测 + D8 解读后，R2-1 无需新决策（当前行为正确，只改注释）；R2-2 设计方向已定（D8），无用户决策。**不再需要 R2-9 的 a/b 决策。**
- **R2-11 code-change approval gate**（用户策略: 任何代码改动作先落 task + 批准）— 全部返工项均列在 tasks.md Section 0。

### R3（34 agents）— Round-3 artifact-vs-code-baseline audit 发现

- **R3-1 交互「thinking disabled」路径实际没关 thinking**（HIGH，前两轮漏掉）→ 返工 ①。根因 R1-1 只修 summary 分支。
- **R3-2 buildTree 签名 `(history, config, proxy_usage)` vs 代码 `(history, maxContextTokens)` 不符；design D3「实测 usage 驱动触发」未兑现** → 返工 ⑤。**已定 (a) 纯文档修正**（spec.md:6 明定 "deterministic local estimator" 触发，代码对 spec 忠实，是 design/tasks 描述过度声称；无真实二选一）→ design.md D3 + tasks 2.1 已改，无代码改动。
- **R3-3 task 2.8 声称「前后 token」但无测试输出前后对比** → 返工 ③。
- **R3-4 (=R2-4 再确认)** 内部 chunk 边界 → 返工 ④。
- **R3-5 (=R2-1 注释)** `model_gateway.cpp:528`「ONLY output_config.effort」错 → 返工 ⑧。
- **R3-6 (=R2-1 引用)** `model_gateway.cpp:546` 引「line 228」错（228 是 §3.1 空行，非 §2.5）→ 返工 ⑧。

### Verified NOT-a-bug（majory-refuted; 后续轮次勿再报告）

- near-zone oversized tool_result body elision 未实现 → 对应 task 5.3（Phase 4，`[ ]`），属正常待办。
- 层级 level-2「总结之总结」+ 语义边界未实现 → 对应 task 4.1/4.3（Phase 3，`[ ]`），属正常待办。
- D10 成本纪律（prompt-caching、折卷预算、破平衡点）未实现 → task 5.1/5.2/5.3（Phase 4，`[ ]`），属正常待办。
- C1「overstates D8」→ refuted：D8(design.md:58) 确写「dirty-seq 标记失效」；D4 与 D8 均坚持 `materialize==buildTree`（幂等缓存），增量+同输出是设计自身解法，非新矛盾。

### 设计一致性审计（Round A，2026-08-28；21 agents，7 claims × 3 skeptics，offline）

> 目的：独立核对「当前摘要生成/管理实现是否对齐 design D1-D10 + specs」。结论：**没有任何一条被多数判定为真实偏离**（isDeviation 全 False）。判定：MATCHES / DEFERRED=待办`[ ]`（非假完成）/ DEVIATED=真实偏离。

- **D1/2/4（摘要形态/投影[摘要][近段原文][当前]/决策执行分离 buildTree 纯函数 + FakeSummarizer seam）= MATCHES 3/3**。
  - 摘要 = `role:user` 文本 + 标记 `## 更早上下文(压缩xN,非用户发言)`（summary_provider.dart:35 逐字一致）；无 name:'history' 依赖、不塞 system。
  - 决策/执行分离：`buildTree(history, maxContextTokens)` 纯函数（注释明示不调模型），`_summaryProvider.summarize()` 只填已定死叶子内容。
  - 注：design D4 曾写 `buildTree(history, config, proxy_usage)` 与代码不符——返工 ⑤(a) 已裁定为**文档纠偏**（spec 明定 local estimator 触发），代码本来就对，非偏离。
- **D3（触发预算 = maxContextTokens + 本地确定性估算器）= MATCHES 3/3**。实测 usage 只写 `token_count` 作遥测/校准，不回读驱动触发（对齐 spec）。
- **D7（摘要 profile = 复用 model_gateway、关 thinking、max_tokens 1024）= MATCHES 3/3**。
- **D5/D10（语义边界 A、成本/便宜层）= DEFERRED 3/3**（对应 4.3 / 5.x 待办，非假完成）。
- **D6（原子单元 + 安全边界）= 2 MATCHES / 1 DEVIATED（未达多数，不以偏离计）**。原子性+边界规则满足 spec「绝不拆工具轮 / 绝不落 tool_calls 行」（工具轮因 tool_result 合成而**按构造原子**）；但 D6 原文「带 tool_calls 的叶子**永原样展开**(node_type)」的更强说法**未实现**——远区 tool_calls 叶会被折进摘要，属 Phase 3 node_type/level-2 机制（DEFERRED，对应 4.2/4.3）。
- **D8（事务落库 + 复用 + dirty-seq）+ D9（存储）= 各 1 个怀疑者独立抓到同一真实缺陷** → **追加返工任务 R0-H-BUG（materialize UPSERT）**：
  - `materialize` 只 `txn.insert`、从不删同 covered span 的旧行。同 span 因 staleness 重算 → 叠重复行 → 违反 D9「covered 稠密非重叠」+ `findCovering` 无 ORDER BY 取 `rows.first` = 旧 stale 行 → **stale reuse**（正是 dirty-seq/⑥ 使其更常可达）。
  - **修法（已写入 D8/D9）**：materialize 在**同一事务内先删同 `(session_id, covered_min_seq, covered_max_seq)` 旧行再插**（upsert），保稠密非重叠 + 取到最新。
- **D9 parent_id 导航 = DEFERRED**（列已铺、行为未落地，属 Phase-3 level-2 成树后）。
