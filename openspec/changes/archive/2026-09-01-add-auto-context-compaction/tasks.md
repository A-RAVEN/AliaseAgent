# Tasks — add-auto-context-compaction

> **执行顺序阅读指南**: 本文件是**唯一任务载体**，openspec 会从此文件解析 `- [ ]`/`- [x]` 作为任务并按序执行。**完整审查证据（R1/R2/R3 被发现记录、refute/NOT-a-bug 判定）见 `design.md` 附录 A**，不作为任务解析。若要执行返工，先做 Section 0，再做 Section 1-6 未完成项。

## 0. 返工主清单 — 按推荐执行顺序 (Round 2/3 对抗审查 + 设计对齐 ⑨；均须先于后续 Phase 执行)

> 每项: 文件 / 问题 / 怎么修 / 对应设计条款 / 是否需要审批。推荐顺序 ①→②→③→④→⑧→⑤→⑦→⑥（前 5 项小而安全，后 2 项大子系统）。发现的完整证据见 design.md 附录 A。

- [x] **① FIX REAL BUG [HIGH] — 交互「thinking disabled」路径实际没关 thinking**（R3-1）
  - 文件: `sidecar/src/model_gateway.cpp` else 分支 (552-555)
  - 问题: `thinkingMode='disabled'`（`lib/main.dart:767-773`，agent 无/无效 thinkingEffort）落入 else 分支，只设 `max_tokens=4096` + 日志「Thinking: disabled」，**未发 `thinking` 字段**。实测 DeepSeek `/v1/messages` 缺省 thinking=ENABLED，故实际 thinking 开着、日志假报。
  - 根因: R1-1 修复只加在 summary 分支(549)，漏了交互 else(552)。
  - 修法: else 分支加 `body["thinking"]["type"]="disabled";`。
  - 设计: D7。**审批: 代码 bug 需审批。**
- [x] **② FIX TEST [HIGH] — "original messages are preserved" 测试名不符实**（R2-5）
  - 文件: `test/integration/summary_node_repository_test.dart` (62-79)
  - 问题: 只查 sqlite_master 有无 `messages`/`summary_nodes` 表，从不插消息/断言行存活/验证内容不变。materialize 删光行也通过。
  - 修法: 插真实消息 → materialize → 断言行仍在且内容未变 + `[OBS]` dump。
  - 设计: spec "Original conversation retained on disk"；D9。需加 `import message_repository.dart`（现文件中已有一行 scratch，见 §7 D1）。
  - **审批: 测试改动需审批。**
- [x] **③ FIX TEST OBSERVABILITY [LOW-MED] — 补 `[OBS]` dump 前置断言**（R2-6/7/8 + R3-3）
  - 文件: `test/integration/summary_node_repository_test.dart`(两测,35-60/81-87)、`schema_migration_test.dart`、`compaction_projection_test.dart`(under-budget,158-187)
  - 修法: 每处在断言前 `[OBS]` dump 实际结果（summary_nodes 行+tree_version / 迁移行+PRAGMA / 投影 JSON + lastFolded）。**R3-3 新增**: task 2.8 声称「前后 token」但无测试输出前后对比——在 over-budget 测试加 `[OBS]` 前后 conversation token 总量对比。
  - 设计: CLAUDE.md 测试可观测性。**审批: 测试改动需审批。**
- [x] **④ FIX COMPACTION BUG [MED] — 内部 chunk 边界未安全对齐**（R2-4）
  - 文件: `lib/services/compaction/compaction_plan.dart` `_budgetSegments` (159-172)
  - 问题: `_budgetSegments` 算术切分 far span，从不调 `_isSafeBoundary`；仅 far/near 缝(`foldEnd`,103)对齐。内部 summary-chunk 起点可能落在带 tool_calls 的 assistant 行。
  - 修法: 每个内部 chunk 起点对齐 `_isSafeBoundary`。
  - 设计: D6；spec "Safe segment boundary choice"/"Never cut mid-tool"。**审批: 产品逻辑改动需审批。**
- [x] **⑤ RECONCILE buildTree 签名 + 触发措辞 [已定 = (a) 纯文档修正]**（R3-2）
  - 文件: `design.md` D3, tasks 2.1
  - 问题: tasks 2.1/design D4 声明 `buildTree(history, config, proxy_usage)` 纯函数，但代码为 `buildTree(history, maxContextTokens)`（compaction_plan.dart:69-72，无 config/proxy_usage）。design D3「实测 usage 驱动触发」未兑现（measured input_tokens 落 token_count 但从不回读）。
  - **决策过程**: 曾标「需拍板 a/b」。经核对，**spec.md:6 明定 "deterministic local estimator" 触发**——代码对 spec 忠实，是 design/tasks 描述过度声称。故唯一正确方向 = (a) 修文档措辞对齐 spec，**非真实二选一，无需用户拍板**。选项 (b)（实现 measured-usage 回读触发）是新增功能，非本 change 验收偏差，默认不做。
  - **已改**: design.md D3 → 「触发预算 = 必填 maxContextTokens + 本地估算器；实测 usage 作遥测/校准，不驱动触发」；tasks 2.1 签名 → 已注「原始措辞 (config, proxy_usage) 与实现不符，已修正为 (history, maxContextTokens)」。**无代码改动。**
  - 设计: D4/D3。**状态: 已完成（文档级修正）。**
- [x] **⑥ IMPLEMENT dirty-seq 水位线 + per-node lazy 重算 [LARGE]**（R2-2）
  - 文件: `compaction_plan.dart`, `summary_node_repository.dart`, `main.dart`, `database_service.dart`(schema v4→v5)
  - 问题: `buildTree` 无状态整树重算；`bumpTreeVersion` 整表+1。design D8 要求 dirty-seq 失效+lazy 重折，缺（grep dirtySeq/staleAncestor/markStale=0）。
  - 修法: ①`sessions` 加 `dirty_since_seq`(默认0) ②`updateToolCalls`(leaf改)记 `min(dirty_since_seq, affected_seq)` ③`buildTree(...,dirtySinceSeq)` 复用 tree 前缀 `[0,dirtySinceSeq)`,只重算 `[dirtySinceSeq,end)` ④leaf 重算时祖先(parent_id链)一并重算；tree_version 每次物化 bump 一次。
  - 设计: D8「dirty-seq 标记失效,lazy 重折」+ D9。**设计方向已定(D8)，无用户设计决策**；仅实现细节（schema列/重算切分）是我的。
  - 注: 此项实际是修复本文件 Section 3 的 3.1（其 `[x]` 声称的「dirty-seq 水位线」未实现）。执行本项时若 3.1 逻辑被替换，按规则不撤销 3.1 的 `[x]`，如实记录此为返工。
- [x] **⑦ IMPLEMENT standing-requirements guard 生产者 [MED-LARGE]**（R2-3）
  - 文件: `main.dart`, `guard_anchors.dart`, `agent_type_config.dart`
  - 问题: `_guard = widget.guard ?? GuardAnchors()`(main.dart:210)，生产从不 seed，`setStandingRequirements`/`guard.add` 零生产调用，`inject()` 恒 ''。spec "Invariant never collapsed"/"Anchor re-injected" 从不触发。
  - 修法: ①`AgentTypeConfig` 加 `List<String> standingRequirements`(config key `standing_requirements`,显式用户手写) ②`initState` seed: `_guard = widget.guard ?? (() {g.setStandingRequirements(...); return g;})()` ③每轮注入不变(main.dart:779)。
  - 设计: D-guard「来源为显式 standing-requirements(非 LLM 从 prose 抽取)」。**设计方向已定(D-guard)，无用户设计决策**；生产者来源(config字段)是我选的最简显式机制。
- [x] **⑧ FIX model_gateway.cpp 注释 [comment only]**（R2-1）
  - 文件: `sidecar/src/model_gateway.cpp` (528-532, 546)
  - 问题: ①(528-532)「ONLY effective thinking control is output_config.effort」错——实测 `thinking.type` 才是 on/off(disabled/adaptive)，`output_config.effort` 是强度。被修正文档+代码自身(536/549 用 thinking.type)推翻。②(546)引「§2.5 / field table line 228」错——228 是 §3.1 chat/completions 空行，§2.5 无 thinking field table；「缺省 enabled」证据在 §2.5 prose(~185-186)。
  - 修法: 改写两注释块为「thinking.type=enabled/disabled/adaptive 是 on/off; output_config.effort 是强度; 正确引 §2.5」。
  - 设计: D7。**审批: 代码注释改动需审批。**（行为本身正确，仅注释错）
- [x] **⑨ REWORK — 闭段冻结/渐进封口（design D8 对齐）**
  - 起因: 用户在 `/opsx:explore` 中明确——"一旦对话片段被 AI 两道切分标记圈定，即成固定历史，摘要固定不变、可长期落盘复用"。对照现有实现发现 Phase 1/2 已实现的 `buildTree` 是"无状态全量重算"（每轮拿全部历史从头算分段），已闭段边界会随新消息移动、摘要可能被重新生成，与"闭段=固定历史、摘要不可变"不一致。**本项是后续 4.1-4.4 的前置依赖，必须先于 Phase 3 完成。**
  - 文件: `lib/services/compaction/compaction_plan.dart`, `lib/main.dart`, `lib/services/summary_node_repository.dart`
  - 问题: 现 `buildTree(history, maxContextTokens)`（compaction_plan.dart:69-125）是无状态全量重算——每轮从全部历史重新决定"哪些段折、边界在哪"；已闭段（已持久化在 `summary_nodes` 的 covered span）不参与输入，边界会随之漂移，`_resolveSummaries`（main.dart:1203-1254）按 span `findCovering` 复用时常因 span 不匹配而**重新摘要**，违背"闭段=固定历史、摘要落盘一次永久复用"。
  - 修法: ①`buildTree` 增入 `closedSegments`（已持久化闭段的 covered span）作为**输入**，保持纯函数；只对**未闭尾部**决定"再封几段、边界在何处"，**绝不重塑已闭段**。②`_resolveSummaries` 对**已闭段**强制命中其缓存摘要（无论 dirty-seq 水位线如何），绝不重摘要；dirty-seq 只影响未闭尾部。③本次新增的 4.3 AI 挑缝（memo）作用于未闭尾部与闭段两侧边界。
  - 设计: D8（渐进封口）/ D9 / 新 spec "Segment closure and summary immutability"。**审批: 产品逻辑重构需审批（用户已在探索中明确此设计意图，视为已授权方向，但具体改法仍需落地审查）。**
- [x] **⑩ FIX stage-review confirmed (2 confirmed + 1 principled)** — 对抗验证 stage-review 抓出的真缺陷
  - 文件: `lib/services/compaction/compaction_plan.dart` (buildTree closed 段), `lib/main.dart` (_resolveSummaries)
  - 问题: ①closed 段构造没传 `level: c.level` → closed 的 level-2 被错贴 L1 标记 / cache-miss 时以 level 1 落库降级（med, 3x confirm）;②open 尾部 level-2 段复用闸门写死 `level: 1` → 永不命中已持久化 L2 节点、每轮 2-pass 重摘要（low, 2x confirm）;③closed 段 cache-miss fall-through 到 fresh summarize → 违背"闭段绝不重摘要"（refuted 但原则性，一并修）。
  - 修法: ①`CompactionSegment(..., level: c.level)`;②`_resolveSummaries` open 复用按 `seg.level` 查询 `findCovering`;③closed 段 cache-miss 改为 `throw StateError`（caller 回退全量 verbatim，符合 R1-5 兜底；绝不再摘要不可变闭段）。
  - 设计: D8/D9 + spec "Segment closure and summary immutability" + "Original conversation retained on disk"。**状态: 已修复 + 17 测试全绿 + analyze 无新警告。**
- [x] **⑪ REWORK 设计级 [HIGH] — 删除"压缩比估算"假设(无 `/4`/`/16`)，改"批量 + 每层实测判 token 变少"的统一分层压缩**（2026-08-29 用户拍板："不该基于假设估压缩量，压完按真实 usage 量；从最旧攒够一批就压一次，压出的 token 比这批少才算有效"；**设计 D1/D3/D4 重构 + 实现；顺带修掉"摘要 provider 丢弃真实 output_tokens"**，2026-08-29 已实现 + 201 测试全绿）
  - 文件: `lib/services/compaction/compaction_plan.dart`（`_summaryCompressionFactor` / `_summaryCostWithK` / `_summariesCost` / `_buildGradient` / `_foldTail`）+ `lib/services/compaction/model_summary_provider.dart`（摘要调用真实 usage）+ `lib/main.dart`（`_resolveSummaries`）。
  - 问题: ①`_summaryCompressionFactor = 4` 声称"L1 ≈ 原文的 1/4 token"——**无实测、无依据**,作废。②折叠前用 `/4`/`/16` **预估"压完剩多少"**,但"压完剩多少"**只能运行时知道**(真实 `output_tokens`);预估既错又没必要。③`ModelSummaryProvider.onDone` 收到真实 `inTok/outTok` 却**丢弃**,`SummaryResult.tokens` 反而用 `estimateTokens(content)` 另估。④旧"逐条折+回判"调用太多,成本高。
  - **机制定稿(2026-08-29,统一一条规则,各处一致)**:
    - **阈值** `T = maxContextTokens ~/ 2`(基于模型上下文估算,结构性可调;用户例: 预算 0.5M → T=0.25M;**不精确也行**)。
    - **规则(每层同一条)**: 从**最旧**开始,累加(原文片段→L1;L1 片段→L2),合计 token **> T** 就把这一批**压一次**成上一级摘要;**判据 = 压出来的实测 token < 这一批的 token**(才叫有效压缩;否则这批太大,拆小再压)。
    - **最新始终保留原文(verbatim)**:批量化只作用于**较旧**内容;最新一段一直不批量,直到预算仍超才动它。
    - 自底向上、逐层向新推进,到 `Σ(L2)+Σ(L1)+最新原文 ≤ maxContextTokens` 停。全压完仍超 → **省略最旧**(只不进投影,数据不删)。
    - **每次压缩量真实 `output_tokens`**,`SummaryResult.tokens` 用真值;`buildTree`/成本函数删除所有压缩比估算;每完成一次压缩按实测判"是否有效(token 变少)+ 是否还需更粗/省略"。
    - `k`/分段不再靠 `/4`:批量边界由"累加 token > T"决定(纯原始 token,可加、确定性),AI 缝(4.3)在其上挑话题边界。
  - 依据: 用户 2026-08-29 指示(零压缩比假设、批量、实测判 token 变少) + 设计 D3/D4 重构 + `/v1/messages` `output_tokens`(live 已验)。**审批点: 已获用户授权改 artifacts;实现触及 4.2 骨架成本模型,属本任务范围。**
  - 设计: D1/D3/D4(批量 + 每层实测,零压缩比假设)。
  - **实现(2026-08-29)**: `buildTree` 纯函数只定批量边界(raw > T=config~/2,最旧起)+ 保留最新原文;`_resolveSummaries` 度量→调整循环(每层真实 `output_tokens`,⑪.1):Σ(实测 L2+L1)+最新原文 > `maxContextTokens` → 先 coarsen 最旧 L1 组为 L2(实测累计 > T)再**省略最旧**(只不进投影,数据不删,D9);**split-if-invalid**: 实测摘要 ≥ 本批 raw → 拆半递归,**拆到单条仍不省 → 该原子批省略(数据保留)**。测试: compaction_engine(结构/raw 批量/缝/determinism/l2GroupCount) + compaction_projection(over-budget / coarsen / omit / split) + seam_selector,201 全绿。
  - **诚实注(实现取舍)**: 设计措辞"原子批不省则**原样保留**(按原文发)"——本实现把该原子批**省略**(只不进投影,数据留盘),而非按原文发送,原因: 把原子批按原文插入远端会破坏投影 `[摘要前缀][verbatim 尾]` 结构与 role 交替,且"最新才 verbatim";省略同样满足"绝不发比原批更大的摘要 + 数据不删"。若需严格"原样保留",需在投影层重构(verbatim 就地交错)——本轮不做,如实记录,不掩盖。
  - 状态: **已实现 + 202 测试全绿。**

### ⑪ 对抗复查(round-2,2026-08-29)CONFIRMED 发现 — 全部已修复

> 对抗验证(5 lens × ~18 findings,N≥3 REFUTE-skeptics,majority-kill)确认 10 条为 refuted(非 bug),6 条 CONFIRMED(其中 1 条是"split 三项不变量成立"的正面核验)。以下为 CONFIRMED 真缺陷的修复;按执行顺序插入(均为 ⑪ 后续任务,前置已完成)。

- [x] **⑪-A far-span 起点未安全对齐 → 首个 L1 批可能落在带 tool_calls 的 assistant 上**(spec "Safe segment boundary choice")。**初修(对齐 far 起点)→ 被 Round-2 对抗审查推翻(该对齐导入 reorder/空 far/memo 键失配),已撤销**。最终裁定: **far[0](折叠区首条)豁免**该规则——它是折叠区首条,其合成 tool_result 由同一 assistant 消息经 `_buildApiMessages` 产出,故不构成工具轮拆分(与"整会话 index 0 豁免"同理;渐进封口后以工具轮开头的尾部亦然);内部批边界仍由 `_batchL1` 安全对齐。
- [x] **⑪-B heavy-closed(foldEnd==0)override 折叠了最新 verbatim + 注释说反**。修法: foldEnd==0 时改为"折叠较旧、保留有界的最新 verbatim(按 raw ≤ budget)",修正反的注释,并对 budget 生长的 foldEnd **再安全对齐**(Round-2 确认)。D3/D4 "最新始终 verbatim"。
- [x] **⑪-C L2 coarsen 未判 "measured < replaced" 有效性**。修法: `l2.tokens >= groupSum`(无效压缩)→ 拒绝该 L2、改走 omit(只省略最旧的 open,数据留盘),接受一个不小于其替换内容的 L2。测试: compaction_projection '⑪.3 reject-bloated-L2'。
- [x] **⑪-D open 清空后仍超预算无检测**(closed+verbatim 病理超限,设计仅把"最新单独超预算"记为 known-limit)。修法: 循环后若 total > budget,`debugPrint` 表面残余缺口(不掩盖)。
- [x] **⑪-E 设计措辞"原子批原样保留" vs 实现"省略"不一致**。修法: design.md D3/D4 改为"省略(只不进投影,数据留盘)"并诚实记录保真代价 + 需投影层「verbatim 就地交错」重构才对严格一致(本轮不做);确认省略不违反任何 spec SHALL。tasks.md ⑪ 注同步。
- [x] **⑪-F split-if-invalid 三项不变量核验通过**(绝不发 ≥ 本批 raw 的摘要 / 必终止 / 省略仅投影层、不删数据)——无 bug,记录在案。

### ⑪ 二次对抗复查(Round-2,2026-08-29,⑪ 修复的二次审查)— 确认项已处理

> Round-2(4 fix-lens × 13 findings,N≥3 REFUTE-skeptics,majority-kill)对本轮 ⑪-A/B/C/D/E 修复做二次对抗。确认 4 条 refuted(非 bug,含"split 拆分 midpoint 不构成工具轮拆分"),CONFIRMED 指向 A/B 的**初修本身有缺陷**并给出更优解法;以下为处理。

- [x] **⑪-A 二次确认: farStart 快照引入 3 缺陷**[reorder(投影重排: 最旧未摘要工具轮落到摘要之后,违 Chronological 序)/ 空 far → shouldCompact=false(超预算却不压缩,违 spec "Reaches budget compacts")/ resolveFoldSeamInputs 未用同一 snap → LLM 缝 memo 键失配(该场景下 AI 缝静默 no-op + 浪费 prefetch)]。**处理: 撤销 farStart 快照 + near 前置,改判 far[0] 豁免**(见 ⑪-A 修订)。三缺陷随之消失。
- [x] **⑪-B 二次确认: budget 生长 foldEnd 未安全对齐**。处理: 该分支 foldEnd 计算后再 `_alignToSafeBoundary`。
- [x] **⑪-B 二次确认: 注释"never fold the newest"过度声称**(最新单条 > budget 时仍会被折)。处理: 注释预以"单条 > budget 属 D3 已记录病态已知上限"。**已并入 ⑪-B 修订。**
- [x] **⑪-C 二次确认: L2 有效性 guard 正确(Q1-Q4 全过;单 L1 已 > T 被 omit 是 D3/D4 "no merge of ≥2 → omit" 的设计行为,非 bug)**。无改动。
- [x] **⑪-E 二次确认: D3/D4 "每层拆半再压" 在 L2 层未实现(实现为 omit 最旧 L1,不拆半)**——design 文本 vs 实现的行为差异(非正确性 bug)。处理: design.md D4 增加"L2 无效压缩 → omit 最旧 open L1,而非拆半"之如实记录。**已并入 ⑪-E。**
- [x] **⑪-D(残余超预算检测)+ ⑪-E(原样保留→省略)二次确认未被推翻**。均成立。

### ⑪ 三轮对抗复查(Round-3 终审,2026-08-29)— 确认项已处理

> Round-3(5 lens × 16 findings,N≥3 REFUTE-skeptics,majority-kill)对当前(撤销快照后)⑪ 代码做终审。确认 3 条 refuted(含 "coarsened L2 重叠 sub-L1 违 D9" 被 refuted: D9 非重叠是**同层**不变量,materialize 键含 level;"split 拆分 midpoint 不构成工具轮拆分";"far[0] 豁免"被判定 **DEFENSIBLE**)。以下为 CONFIRMED 项的处理。

- [x] **⑪-R3-1 最新消息 raw ∈ (T, budget] 被折叠**(违 D3 "最新只要放得下就 verbatim";仅 > budget 才是病态)。**处理**: 经核对,spec 只要求"哪个最新保持不变 verbatim 由纯函数定"(**有界近期块**);故代码保持 `near ≤ T`(有界近期块),并把 design.md D3 的"最新 verbatim 放得下就保留"精化为"有界近期块 ≤ T;单条 > T 则划入远端折叠"——**与 spec 一致**,非降级。不改成 near ≤ budget(那会把 near 扩到整个窗口、破掉"给远端留预算",且大量测试结构崩坏)。
- [x] **⑪-R3-2 测试守卫"summary 绝不在 tool_calls 上开始"过宽 vs far[0] 豁免**。处理: engine/seam 测试断言改为 **interior only**(`.skip(1)`);spec.md "Safe segment boundary choice" 增注 far[0] 豁免(折叠区首条,其 tool_result 同消息合成,不构成拆分)。
- [x] **⑪-R3-3 bloat-reject 路径每轮重算新组 summarizeText → O(n) 浪费 LLM 调用**。处理: reject 时改为 **drain**(逐条 omit 该组条目、重测 total、不重算同组)——一次 summarizeText 后连续 omit,效率提升且保留仍有效的 L1(数据留盘 D9)。
- [x] **⑪-R3-4 循环把已有 L2 再 coarsen 成新 L2**(输入含旧 L2 文本,违"L2=总结之总结只两级"+"L2 输入是 L1 摘要文本";且可持久化两个重叠 L2 行,违同层 D9)。处理: **绝不重 coarsen 已有 L2**(open[0].level≥2 → 只 omit);coarsen 组只取最旧**连续 L1**。
- [x] **⑪-R3 正面核验**(非 bug): far[0] 豁免 **DEFENSIBLE**(工具轮是单条 assistant 消息,其 tool_result 同消息合成,任何消息间边界都落在同一圆整内)——无输入能拆分工具轮;buildTree/_foldTail **deterministic**;**无 /4**(仅注释);split-if-invalid 三项不变量成立;design D3/D4 reconcile **内部一致**、无陈旧"原样保留/拆半再压"矛盾;无 regression(progressive-closure reuse / seam memo / role 交替 / interior safe-snap 全保留)。
- [x] **⑪-R3 注**: "batch raw 是估算 proxy"是设计(D3: 本地 estimator 校验 raw,summary 实测;准确度由 Phase-4 破平衡点回归校验),非 bug;resolveFoldSeamInputs 在 heavy-closed 返回 null(foldEnd≤0)→ 无 AI 缝,用算术骨架——效率小缺口非正确性。

### ⑪ 收尾对抗审查(Round-4 wrap-up,2026-08-29)— 确认项已处理

> 按诚实循环"达 3 轮上限后仍需一轮 Workflow 收尾审查"。4 lens × 11 findings,N≥3 REFUTE-skeptics,majority-kill。CONFIRMED 绝大多数为**正面核验(无 regression)**: progressive-closure reuse（闭段恒缓存命中/绝不重摘要，脏水位线不consulting）、seam memo 路径（resolveFoldSeamInputs far/k == buildTree folded/k，memo 内容哈希 key）、interior safe-snap（far[0] 豁免正确限定）、预算在正常情形被遵守 + 残余缺口检测完好、闭段绝不 coarsen/省略。refuted: drain-over-omit（3/3）、valid-coarsen-then-omit 浪费（2/3）、"单条最新 > T 被折叠"（3/3，与 ⑪-R3-1 有界近期块裁定一致）、残余日志措辞（3/3）。

- [x] **⑪-R4-1 空 far 压缩静默重发整段超预算对话且无日志**(honest-fail)。**修法**: `_callModel` 在 `resolved.segments.isEmpty`(整个 far 被 split-omit 成不可压缩、且无 verbatim 尾)时 `debugPrint` 表面"压缩未产出任何投影 → 重发整段超预算对话(已知病态上限)",不掩盖。

## 1. Phase 0 — 遥测地基(token usage + 全序 + 配置)

- [x] 1.1 model_gateway 解析 `/v1/messages`(Anthropic 格式)SSE `message_start`/`message_delta` 的 usage,字段名按 Anthropic 格式 `input_tokens`/`output_tokens`(**原 [UNVERIFIED], 2026-08-26 live 验证已确认 `input_tokens`/`output_tokens`**),侧车防御性解析 usage 块(读端点实际返回的 token-count 字段);勿用 chat/completions 的 `prompt_tokens`
- [x] 1.2 sidecar FFI 新增 usage 回调(或扩展 on_done)把 input/output token 回传 Dart;sidecar_bridge 接收并透传
- [x] 1.3 insert 时把实测 usage 写入 `Message.token_count`(填补当前无 writer; 注: 仅存 input, output 未单独持久化 — 见 R1-9)
- [x] 1.4 `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;message/model/repository 透传 seq
- [x] 1.5 `AgentTypeConfig` 加必填 `max_context_tokens`;设置对话框新增必填项(同 apiKey 引导; 注: 运行时未设 maxContextTokens 仍静默禁用压缩 — 见 R1-7)
- [x] 1.6 schema v3→v4 迁移:seq + `summary_nodes` 表 + 每会话 `tree_version`;不给旧数据预建 rollup;镜像到 `openAt`;补迁移测试
- [x] 1.7 测试:usage 回传写库可观测(dump usage 后断言);seq 在同毫秒插入下严格单调;本地 token 估算器确定性

## 2. Phase 1 — 单层平铺 MVP(近段原文 + 一个根总结)

- [x] 2.1 ❗边界缝实现偏差 — 实现 `buildTree(history, maxContextTokens)` 纯函数:分段 + 段边界规则 + 预算/cover + 近段原文 + 一个根总结;可注入 `FakeSummarizer`(决策/执行分离)（注: 原始措辞写作 `(history, config, proxy_usage)`，与实现不符——已修正为实际签名 `(history, maxContextTokens)`，对齐 spec "deterministic local estimator" 触发。见返工 ⑤(a)。）
  - **❗偏差说明(历史;已被 ⑪ 取代)**: (原说法)本任务确定性骨架正确、仅"边界缝"用算术(每~8条一刀) —— 该说法里"**骨架正确**"**只对**"安全边界/工具轮原子性/不重不漏 cover"成立;其"折哪些段、几段、预算"的**批量划分**基于 `/4` 成本+每~8条,已被 ⑪(`buildTree` 改"原始 token > T 批量")**作废**。边界缝 AI 化(4.3, 方案A, memo)方向保留,但 AI 缝只**微调**批量边界到最近安全话题缝,不 wholesale 替换(⑪ 会改 `_segmentsFromSeams`)。此 2.1/4.2/4.3/4.4 的 `[x]` 记录的是当时实现,批量/成本细节以 ⑪ 为准。
- [x] 2.2 ❗边界缝实现偏差(部分) — 原子单元:折叠单元 = 带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result);段边界只落"真实用户文本 / 无 tool_use 的 assistant 终答",绝不落带 tool_calls 的行（注: 但 `_budgetSegments` 内部 chunk 边界未执行此规则 — 见返工 ④）
  - **❗偏差说明**: 本任务的**原子单元/安全边界保证本身正确**(设计对齐);仅"边界缝"由算术分段(`_budgetSegments` ~8条一刀)决定,而设计选定方案 A(AI 挑话题缝,4.3)。故**仅该缝为偏差**;安全保证保留,缝选取须在 4.3 按方案 A 修正。后续设计不得把"算术缝"当作正确参照。
- [x] 2.3 摘要输出为 role:user 纯文本 + 明显标记(`## 更早上下文(压缩xN,非用户发言)`);不合成 thinking/tool_use/tool_result 块(DeepSeek /v1/messages 客户端侧标记,不依赖 chat/completions 的 `name` 字段)
- [x] 2.4 摘要请求 profile:复用 model_gateway,关 thinking、`max_tokens` 512-1024,末条 user 追加 summarize 指令;不用交互式 16K 路径
- [x] 2.5 组装投影:`_buildApiMessages` 改为读压缩树投影 `[system][摘要][近段原文][当前]`;节点按需展开(harness 注入,非 agent 工具)
- [x] 2.6 后台折卷(idle-gated):槽空 + 用户空闲才跑;可抢占 + 断点续;绝不 delay 用户发送
  - **实现(2026-08-30)**: ①`ChatScreen` 加 `backgroundFoldEnabled`(默认=生产: 未注入 summaryProvider); ②用户转轮完成后(`_endStreaming` 处, main.dart:1111 success + 1247 max-turns)调度 `_maybeScheduleBackgroundFold` → 2s idle 防抖 Timer; ③`_runBackgroundFold` 复用**同一纯函数 fold 路径**(`buildTree` + `_resolveSummaries`),空闲时预折+物化远端闭段,使下次 inline `_resolveSummaries` 命中缓存(用户 token-time 不重复折卷); ④**抢占**: `_sendMessage` 入口在 `_foldInFlight` 时 `_foldGen++`(使 fold 的 `isAborted`(`_foldGen != myGen`)在下一循环顶探悉并抛 `_BackgroundFoldCancelled`)+ `_sidecar.cancelRequest()`(释放单槽)+ 清防抖 Timer; fold 的 inflight summarize 抛错→`_resolveSummaries` 展开→fold `catch`(视为"aborted, 下次空闲续")——绝不 delay 用户; ⑤`_resolveSummaries` 增可选 `isAborted`(循环顶检查; inline 传 null 永不提前终止),背景折卷传 `() => _foldGen != myGen`。
  - **诚实注(最终状态,已与 2.6-返工收口)**: 抢占在初版以**单槽全局 `cancel_flag`** 实现,被对抗审查确认无法完全满足 D8"request-id 定向 cancel/绝不 delay"(execute() 每新请求重置全局 flag,enqueue→start 窗口内的 fold 调用可跑到用户请求前)。**已由 2.6-返工实现真正的 per-request-id cancel 收口**(`send_message`/`cancel_request` 带 `request_id`;C++ `cancel_request_id` 不被 execute 重置 + execute 起始查它 + xferinfo 查它;Dart bridge 每请求分配唯一 id,`cancelRequest()` 取消 fold 当前请求 id)→ **"绝不 delay" 现已满足**。Dart 侧另有防御纵深: fold 每个模型调用点 isAborted gate + sendMessage 抢占(含 pending timer)+ 导航 bump gen 并取消待定时器。
  - **断点续**: 持久化断点= `summary_nodes`(materialize 即 checkpoint;渐进封口下次只折未闭尾);`top closed seq` 仅作日志观测(非控制值——曾用 `_foldCheckpointSeq` 内存字段,被对抗审查判为死状态而移除)。
  - **测试**: `test/integration/background_fold_test.dart`(①idle 后后台折卷实际驱动 provider(under-budget 转轮后 lastFolded=null → idle 折后非空,非空转)+ ②in-flight fold 被用户发送触发抢占路径(cancelCount reset 后 ≥2,删掉 `_sendMessage` 抢占块会降到 1 → 非空转)+ [OBS] dump)。**诚实界**: 测试用 `FakeSidecar`(同步、不串行,区别于真实 `SidecarBridge._chain`),故**不断言"not delayed"**(那需串行化 FakeSidecar 证明)也不直接断言 fold 对象 abort(仅通过 gate 释放 error 模拟生产 cancel-throw)——只诚实验证"抢占路径触发(cancelCount reset 后 ≥2,删掉抢占块降到 1 → 非空转)+ 用户转轮完成('Turn2 done' 独立文本渲染,turn 1 已耗尽 FakeSidecar 队列故 ≠ turn1 Reply)+ fold 确实 in-flight(发送前 summarizeCalls≥1,该时点仅 fold 会调它,因 turn1 under-budget + turn2 未发)"。**与现有物化链路(pre-inline + summary_node_repository)复用同一代码**。203 测试全绿。
  - 设计: D8(单槽可抢占/事务落库/闭段冻结)。
  - **对抗审查(fresh lenses,2026-08-30)确认缺陷 + 修复**: 初版 `isAborted` 只在 `_resolveSummaries` Phase A/B 循环顶检查;fold 内部各自调 `_summaryProvider.summarize` 的路径无 gate → 若用户发送落在两次内部模型调用之间,fold 的下一次调用因 `execute()` 每新请求重置 `cancel_flag`(model_gateway.cpp:499)而被排队到用户请求前,延迟用户。**修复** ①`isAborted` 穿入 `_resolveOpenLevel1`(递归入口)+ `_l1SummaryText`(summarize 前)+ `_prepareSeamChooser`(seam ensure 前)②`_sendMessage` 抢占对 **pending** idle timer 也生效(`if (_foldInFlight || _foldIdleTimer != null)`)③导航(_selectSession/_newChat/_deleteSession)bump `_foldGen` **并取消待 `_foldIdleTimer`**(使 SCHEDULED 的 fold 也被抑制,否则 timer 在导航后触发并折旧会话)——且 `_newChat`/`_deleteSession` 在 await(create/delete)**之前**就实施(否则 timer 在 async 间隙触发) ④移除死字段 `_foldCheckpointSeq`(只写日志,非控制值) ⑤`dispose()` 取消待 `_foldIdleTimer`(防 pending-timer 泄漏/widget-test "Timer still pending")。**残余已知 limit(已被 2.6-返工收口)**: 上述"单槽全局 `cancel_flag` 无法完全满足 D8"的窗口已由 **2.6-返工实现真正 per-request-id cancel 关闭**(`send_message`/`cancel_request` 带 `request_id`;C++ `cancel_request_id` 不被 execute 重置 + execute 起始查它 + xferinfo 查它;Dart bridge 每请求分配唯一 id 并向 fold 当前请求取消)→ "绝不 delay" 已满足。此处的 ①②③④⑤ 是 Dart 侧防御纵深(非替代)。**诚实注**: 该竞态的忠实回归测试需真实串行化 sidecar;hermetic FakeSidecar(不串行)不可得,故 Dart 侧不写空转测试;真实路径已由 2.6-返工的 C++ `[reqid]` 定向取消测试覆盖。**已验证: 203 Dart 测试全绿 + C++ http/sse/reqid 离线全绿。**
- [x] **2.6-返工: 实现真正的 request-id targeted cancel(对齐 spec D8;2026-08-30 对抗审查确认单槽全局 cancel 无法完全满足 spec "SHALL be preempted (request-id targeted cancel)... never delays the user")**
  - **问题**: 初版用单槽全局 `cancel_flag` 实现抢占;`execute()` 每新请求把它重置为 false(model_gateway.cpp:499),故若用户发送落在 fold 已 enqueue 一次模型调用、但其 worker `execute()` 尚未重置 flag 的窗口,该 fold 调用不被取消、且因 `_chain` FIFO 排到用户请求前,短暂 delay 用户(违 D8「绝不 delay」+ spec)。
  - **修法(跨层)**: ①**C++ `send_message`/`cancel_request`** 增 `int request_id` 参数(`sidecar_api.h/.cpp`);`execute(..., int request_id=0)`: `rid = request_id!=0 ? request_id : next_request_id++`;新增 `std::atomic<int> cancel_request_id{0}`(**execute 不重置它**)+ `cancel(int request_id)` 设它;`execute` 起始查 `cancel_request_id==rid` → 立即 abort(**close enqueue→start 窗口**);`xferinfo_cb` 亦查 `cancel_request_id==request_id`(in-flight)。②**Dart bridge**(`sidecar_bridge.dart`): 每次 `sendMessage` 分配唯一 `requestId`(enqueue 前)并传入 FFI;`cancelRequest()` 改为 `_cancelRequestFn(_lastRequestId)`(面向 fold 当前请求,用户请求取不同 id 不受影响);timeout 亦按自身 `requestId` 取消。③`execute` 的参数带默认值 `=0`,故 **C++ 测试调用点无需改**;`cancel()`(无参)保留作 back-compat。
  - **设计**: spec "Background folding lifecycle" + design D8("request-id 定向 cancel"/"用户优先 绝不 delay")。
  - **验证(实测,诚实精确)**: ①`flutter analyze` 0 error(仅预存在 warning/info,非 error: legacy `test/checkpoint_*.dart` 的 NativeCallable 噪声 + lib 内 `nsCount`/`_webSearchFn`/`_webFetchFn`/`unused_catch_stack` 等,全部非本 change 引入);②**203 Dart 测试全绿**;③**C++ 离线测试全绿**: `sidecar_tests.exe "[http_client],[sse_parser]"` = 45 用例/189 断言 + 新增 `"[reqid]"` 2 用例/8 断言(`cancel_request(id)` in-flight 与 enqueue→start 两路径均 `done(-1,"cancelled")`)经 local mock server(127.0.0.1)ALL PASS;`sidecar.dll` 亦编译+部署。**诚实注(环境)**：完整 C++ suite 有 `search_provider_test` 的**真实网络 live 测试**(SearXNG/ZhipuAI/Kimi)——本环境无网络,**时快败(报 "SearXNG unavailable")时挂起**,不可靠;故本轮以**离线 mock 的 http/sse/cancel 精确段**验证 cancel 改动(与网络搜索测试无关),如实记录,不掩盖。 ④**latch 污染修复**(对抗审查抓出): `cancelRequest()` 若对**已完成的 id** 调用会把 `cancel_request_id` 置脏且永不清理(hot-restart 复用 id 会误伤)→ Dart bridge 加 `_pendingRequests`(sendMessage++、`finish()` 在 `onDone` 前 --),`cancelRequest()` 仅在 `_pendingRequests>0`(有在途请求)时取消;C++ `execute()` 收尾/start-check 在目标 id 命中后清零 `cancel_request_id`。⑤**最终设计一致性审查(任务+代码)**: confirtermed=`[]`(1 候选被多数决 refute)——最终代码**符合 D8/spec SHALL、无偏离**,返工任务正确,无回归。
- [x] 2.7 `summary_nodes` 落库(单事务)+ bump `tree_version`;折卷和用户请求轮换共享单槽
- [x] 2.7 `summary_nodes` 落库(单事务)+ bump `tree_version`;折卷和用户请求轮换共享单槽
- [x] 2.8 ❗边界缝实现偏差(测试) — 测试:工具对完整性属性测试(折叠后仍合法交替、可喂回 `_buildApiMessages` 不拆对);树形/预算/确定性(FakeSummarizer);headless 集成(dump 折叠视图 + 前后 token)（注: 「前后 token」无测试实际输出 — 见返工 ③ R3-3）
  - **❗偏差说明**: 本任务的**工具对完整性/交替合法断言正确**;其**树形/预算/确定性测试断言的是算术分段(`_budgetSegments`)这一"缝偏差"的形态**——骨架断言(预算/确定性/cover)仍成立,但**边界缝相关断言须随 4.3(方案 A)重新对齐**。工具对完整性断言保留;缝相关断言标记为待随 4.3 修正。
- [x] 2.9 guard/anchor:实现不可压缩锚点——用户目标/验收标准/"don't touch X" 不变量 pin 为永不塌缩,每轮重注入,集合有界/去重/可失效;来源为显式 standing-requirements(非 LLM 从 prose 抽取)（注: 生产环境无生产者 seed, inject 恒空 — 见返工 ⑦）

## 3. Phase 2 — 失效/重算 + 两级梯度

- [x] 3.1 节点表按 `(session_id, level, start_seq, end_seq)` 键 + `covered_min/max_seq` 稠密非重叠 + `leaf_owner` 平面索引;insert/delete/updateToolCalls 标记受影响 span + 祖先 stale(dirty-seq 水位线),lazy 重算（注: dirty-seq 水位线/按受影响 span lazy 重算未实现，现为无状态整树重算 — 见返工 ⑥）
- [x] 3.2 失效触发基于**已有的** `updateToolCalls`(当前唯一叶子级修改);`tree_version` 递增验证;不为此变更引入新 delete/内容编辑(超出本 change 范围)
- [x] 3.3 两级梯度(knob B):level-1 段总结;recency 梯度作为 segment index + config 的纯函数
- [x] 3.4 测试:改中间叶子→仅受影响 span+祖先重算,cover 仍正确,tree_version 递增（注: 实际为整树重算，与「仅受影响 span」不符 — 见返工 ⑥）

## 4. Phase 3 — 全树 + canonical-cover 前锋 + 语义边界

- [x] 4.1 层级用文本标记编码(非角色/块);"总结之总结"(level-2)卷起
  - **实现注(设计一致性复核 R-reverify #1)**: `materialize`/`findCovering` 的 UPSERT 删除键与查询键当前为 `(session_id, covered_min_seq, covered_max_seq)`（**无 level**）。一旦建 level-2，level-2 节点的 covered span 可能与被它卷起的 level-1 节点共享相同 `(covered_min,max)`（单子上卷 / coarsen-left 情形），会导致 materialize 跨层删错行、`findCovering` 取到任意层行。**本任务须把 `level` 加入删除/查询键**（并给 findCovering 加 ORDER BY / 或按 level 过滤），维持 D9「covered 稠密非重叠」在跨层下仍成立。
- [x] 4.2 canonical-cover 前锋(预算驱动 `coarsen-only`):`[L2 大摘要(最旧)][L1 小摘要(中段)][原文(最新)]` 三层梯度,coarsen-only(只并不拆、只两级);cover 稠密 + 完整 + 梯度单调(近详→远略);连 L2 都超预算则"省略最旧"——**只从投影省略(不发给模型),绝不删原文/摘要**(见 spec "Original conversation retained on disk" + design D9)
  - **实现注(2026-08-29 用户确认)**: ①只并/只造粗层,永不拆细;②保留"多条 L1 + 一条 L2"的中间层(不是整段卷成单条 L2);③"省略最旧"只在投影层生效(本次不发给模型),底层原文 + L1 + L2 全落盘不变;④将来 re-expand 机制本轮不做、仅占位;⑤**边界归属**:L1 段边界 = AI 挑话题缝(4.3, 方案A, 唯一 LLM 点);**L1→L2 组边界 = 算术**(确定性,用户 2026-08-29 决定"先尝试算术")——即 L2 分组按确定性算术规则(固定组大小/预算驱动 coarsen-only),**不调用 LLM**;L1 段内部边界仍由 AI 切缝。
- [x] 4.3 语义边界 A:LLM 在安全候选切点挑话题缝(嵌入同一摘要调用)+ memo 化(content hash keyed)保重建/测试可复现
  - 实现: `SeamSelector`(seam_selector.dart, 内容哈希 keyed, `ensure` 异步跑 LLM 挑 `{"seams":[...]}` + `memoizedSeams` 同步读; 失败/解析失败缓存空→回退算术骨架) + `buildTree` 增 `L1SeamChooser` 可选参 → `_budgetSegments(far, budget, chooser)`: 段数/预算/cover 仍纯函数(注: 其**预算/K 部分**依赖 `/4`, 随返工 ⑪ 改运行时实测/结构默认粒度; 结构+缝校验仍纯函数), chooser 缝经 `_normalizeSeams` 校验(安全边界/严格递增/恰好 k-1/界内), 违规则回退算术; 生产在 `_callModel` 先 `resolveFoldSeamInputs` 预取 memo 再以 memo 背板 chooser 重建, `_seamSelector` 仅在 `widget.summaryProvider==null && resolver!=null`(生产) 接入, 密封测试注入 `FakeSeamSelector` 或 null(走算术, 不额外消费 FakeSidecar 事件)。设计 D5 注。
  - 对抗审查: R3(2026-08-29)复现并修正 2 个真 bug(memo key 补 `toolCallsJson`; FakeSeamSelector 增 warm-memo 短路), 均已修 + 测试。测试: compaction_engine_test 13(含 4.3 seam reposition/无效缝回退/resolveFold/determinism) + seam_selector_test 5(含 memo 不重调 LLM / 内容哈希区分 / Fake memo 契约 / 端到端)。
- [x] 4.4 测试:cover 稠密且完整;梯度单调(近详→远略);总预算 ≤ `maxContextTokens`;LADDER 可断言;确定性(同 history+config → 同树形);memo(重建用缓存不重调 LLM)
  - 覆盖: cover 稠密完整(over-budget 折叠远段 + LADDER 连续稠密); 梯度单调(LADDER 用工具轮密集 far span 真产 [L2:1-16][L1:17-80][verbatim:81-100] + l2SubSpans=[[1,8],[9,16]], 非空); 总预算 ≤ max(各测试断言 projected ≤ budget; 注: 这是**旧 `/4` 预估**下的断言, 返工 ⑪ 后"摘要尺寸/是否超预算"改**运行时实测**, 该断言随实现重调); 确定性(同 history+budget+seamChooser → 同树形); memo(重建用缓存不重调 LLM, Model+Fake 双测); 2-pass LADDER 链(buildTree 产 level-2 非 null l2SubSpans)。
  - **诚实注(2026-08-29)**: 唯一未做满的是 **main.dart `_resolveSummaries` 的 2-pass `summarizeText` 完整集成测试**——在现行 `/4` 成本模型下, 带 l2SubSpans 的 level-2 只在极窄预算窗口内可达, 用户新消息即移出窗口, 无法稳定端到端触发(实测 summarizeTextCalls=0)。该链已在 plan 层(compaction_engine_test '4.4 LADDER')验证 buildTree 产 l2SubSpans 非空 + `_resolveSummaries` 读该分支。⑪(删除压缩比假设 + 尺寸运行时实测)正是为此设计重构——中间层由运行时实测产生而非预算比率窗口, 改完后此集成测试才可稳定。不隐藏此缺口。

- [x] **A-1 有意义真实上下文 fixture**: 手工构造一段贴近真实 AliasAgent 会话的"有意义"上下文(配置重构场景)。**关键约束(设计和对抗审查要求)**: ①load-bearing **再执行钥匙**——绝对路径 `/Users/acme/src/config.dart` 与决策 `timeout 120→30`——**必须落在可折叠 band(远端 L1/L2)**,既不在"最新 verbatim 有界近期块(≤T)"、也不在"省略最旧"(否则摘要碰不到/被故意丢弃 → 断言必失败或凭运气过);②会话至少产出 ≥1 个可折叠 L1 段;③会话含 ≥1 个真实工具轮(`read_file`/`write_file` 绝对路径 + 结果)。**用户目标与硬不变量(`don't touch email`)不列为"摘要必须含"的 key**——它们由 standing-requirements 守卫重注入承担(spec.md:36 "不变量 never folded into a summary"),属守卫层、另测。
  - **诚实注**: 原文来源=**手工构造**(贴近该 app 真实 tool 轮 + 决策 + 路径格式),非下载/非小说;也可换 AliasAgent 真实会话片段(更真但内容不完全可控、不一定正好把 key 放进折叠带)。默认用构造 fixture(可控/可断言/可复现)。
- [x] **A-2 真实上下文压缩质量测试(live)**: 用 A-1 fixture 构造超预算会话 → 真实 summarizer(`ModelSummaryProvider` 走真 `/v1/messages`)→ **覆盖率断言(限再执行钥匙)**: 摘要**包含** 绝对路径 `/Users/acme/src/config.dart` 与决策关键词(`30`/timeout),且摘要在其跨度内进入投影 `[摘要][近段原文][当前]`。**不**断言目标/不变量出现在摘要正文(属守卫重注入层,spec.md:36 明言不变量从不进摘要;另在 systemPrompt 重注入层测)。**标 `live`/可跳过**(需真实 apiKey+网络;断网 skip 保留)。
  - **`[OBS]` 可观测性(CLAUDE.md 硬要求,断言前逐项 dump)**: ①summarize 调用的**输入**(折叠带 transcript + `kSummarizeInstruction`,证明 path 是否对模型可见)②调用的**result/status**(doneCode / 真实 `output_tokens` / doneErr)③**完整摘要文本**(供人工评估)④它断言的**投影**(`sidecar.lastMessagesJson`)⑤**持久化文件状态**(messages 原始行不变 + `summary_nodes` 摘要行 + tree_version)。失败须能归因(是模型 err / fixture 没把 path 放进折叠 transcript / 摘要未落库 / 投影错)。
  - **诚实界(校准而非"决定性命中",非"唯一真质量测试")**: ①此"字面 key 出现"断言**强于** design 的保留合同(design 非目标: 不追求逐字核对;靠语义保留 + 原文可 re-expand + 再执行钥匙原样展开 D6 兜底)——即**校准的质量杆**("好的 summarizer 应通过"): 一个有损但合规的 summarizer 可能语义保留决策却不复现字面路径/数字 → 会 false-fail。故以 `[OBS]` 全文 + 该断言共同构成质量评估,并标注此断言比 design lossiness 合同更强(非 design 保证,需跨 benchmark 标定)。②**非"唯一真实质量测试"**——design.md:87 + Docs/context-compression-reference.md P1 已规划**行为连续性 live 测试**(integration_test,`@Tags live`,跑 N 个真实 turn,断言 assistant 引用先前决策/工具,同样断言前 dump 工具调用+文件状态);A-2 只定位为**"断言摘要再执行钥匙覆盖率的 live 测试"**,与行为连续性测试互补。
  - **可选确定性兜底(与本任务分离)**: 若本环境无网络,可另用一个返回"rich 固定摘要"的假端点(如 bridge_realtime 的 `_SseServer`)离线跑管线——但那属机制测试(B),**不减损本 A-2 作为"真实摘要覆盖"live 测试的定位**。

## A-2 分层合规返工（非合规 → 按规范重做，proposal-grade 拆解）

> **Context**：A-2 现在实现为 **headless `test/integration/compaction_fidelity_live_test.dart`**（`@Tags(['live'])`、无窗口），违反 `Docs/TESTING.md` §2.4「live 的正确形态是窗口真模型（`integration_test/` + `-d windows`）」；项目先例是 headless live 判违规**删除**（`live_file_tools_test.dart`）。**不做合理化、不改标签、删掉不合规形态并重做。**

> **Goals / Non-Goals**：
> - Goal：把"真实上下文压缩质量"落到**合规**形态（窗口真模型 live），不丢"能评估质量"这个原始诉求。
> - Non-Goal：**不**保留 headless live；**不**给 TESTING.md 加"真模型组件"类别来洗白 headless live。

> **关键设计决策（对抗审查多轮后修正）**：
> - **P1/design.md:87 的已文档化 live 形态** = **行为连续性**（`Docs/context-compression-reference.md:140/:160-161`：设 cap 远低于真实窗口跑 N 轮，断言不超限 + 助手能引用早期上下文/决策 + 工具照常；观察通道 = 实际工具调用 + 文件终态）。这是 change 自身规划。
> - **摘要"措辞质量"的边界**（`Docs/context-compression-reference.md:165` "诚实的边界"）：摘要质量好坏无法单测——只保证结构合法/预算不超/决策保留/不拆对；**措辞好坏靠 live 行为 + 对抗审查兜底**。
> - **A-2 的"直接读真实摘要文本"是用户诉求驱动的补充**（用户多次指令要"评估摘要文本质量"）：窗口 live 用自己的**临时 DB**（`setUp` `DatabaseService.openAt(tempDir)`，`dbOpen=true`），真实折叠时 `_resolveSummaries` 把真实模型返回的摘要 materialize 进 `summary_nodes.summary_json`（main.dart:1576-1587），测试拥有该 DB、可 `SummaryNodeRepository.queryBySession` 读回原文。
> - **诚实界限（必须保留、不淡化）**：A-2 的断言是**字面 key 存在性**（真实摘要文本**包含** `/Users/acme/src/config.dart` + `timeout` + `30`）——这是**强于 design 保留合同**的校准杆：一个有损但合规的 summarizer 可能语义保留决策却不复现字面路径/数字 → **会 false-fail**；故**非 design 保证**，需跨 benchmark 标定。该断言是补充信号（叠加在 P1 行为连续性上），**不是**"非精确措辞 / 与 P1 不冲突"的轻描淡写——它确实在做字面文本存在性核对，只是核对"key 是否幸存"而非"逐字重放"。
> - **P1 行为连续性 = 本窗口 live 一并交付（R-A2-3 ③c）**：P1 的连续性 live（助手引用早期上下文/决策）由 R-A2-3 的**模型回复引用 key 断言**一并落地（非独立未实现项）；A-2 的"真实摘要保留 key"直测（R-A2-3 ③a）叠加其上，两者互补、都在同一个合规窗口 live 里。**不把它下放给 offline Fake**（Fake 只能证投影机制，证不了真实模型保真）。


> 折叠触发：窗口 live **不用** `const MyApp()`（它硬编码 `AppShell(configLoader:null)`→读真实 config、无法设小 `maxContextTokens`、且折叠门 `agentType.maxContextTokens` 来自真实 registry）。改用 **`MaterialApp(home: AppShell(configLoader: () => ConfigResult.ok(smallConfig)))`**（`AppShell.configLoader` main.dart:70-71 可注入；`smallConfig` = `AppConfig(agentTypes:{general: AgentTypeConfig(maxContextTokens: 300, provider: <real>, model: <real>...)}, providers:{<real provider>})`）→ registry/resolver 用 injected 小容量 + 真实模型 → `shouldCompact` 成立 → 真折叠。

- [x] **R-A2-1 删除不合规 headless live**：删除 `test/integration/compaction_fidelity_live_test.dart` 及其专用 `_RecordingSidecar`（**无** `ProviderConfigCfg` 该符号，删错——修正）。无依赖。验证：该文件消失。（已验证：文件已删，无其他文件 import 它。）
- [x] **R-A2-2 修正 design 决策**：`design.md:87` 改正为"窗口 live 是 **P1 已规划的行为连续性**（助手引用早期上下文/决策，观察通道=工具调用+文件终态）；A-2 在**此基础上额外**经**自身临时 DB 的 `summary_nodes`** 读回**真实摘要文本**并断言其保留再执行钥匙（`queryBySession` + **测试侧自行解析 `node.summaryJson` 的 `content[].text`**，不能用私有 `_summaryTextFromJson`）；折叠经 `AppShell(configLoader: 小 maxContextTokens)` 注入触发；不否定行为连续性、不拆两路、不下放 offline Fake"。依赖 R-A2-1。验证：`design.md` 含该改句 + 无"摘要文本不可得"旧措辞 + 无私有方法引用。（已验证：design.md:87 已含 A-2 窗口 live 定位补充；grep 无"摘要文本不可得"/"私有方法"残留。）
- [x] **R-A2-3 建窗口真模型 live（直测真实摘要质量）**：`integration_test/compact_quality_live_test.dart`，`@Tags(['live'])`+`library;` + `hasCompleteConfig` 门（api_key+base_url+model 全非空，缺则 `markTestSkipped`）+ `sqfliteFfiInit` + **`databaseFactory = databaseFactoryFfi`**（load-bearing：`sqfliteFfiInit()` 不设全局 `databaseFactory`；integration_test 跑的是测试自身 `main()`（lib/main.dart:46 不执行）→ 全局未设 → `openAt` 的 `openDatabase` 会抛 `StateError('databaseFactory not initialized')`——所有 DB 测试先例都显式设这行，如 real_api_test.dart/thinking_integration_test.dart）+ `IntegrationTestWidgetsFlutterBinding` + `setUp` `DatabaseService.openAt(tempDir)`（dbOpen→materialize 生效）。**执行顺序（load-bearing）**：① **先 `create` Session 行 + 把 A-1 fixture 消息 seed 进该 session**（fixture `sessionId` 从 's1' 改写成真实 session id；用 `SessionRepository.create` 或直接 insert，并确保该 session 是 `sessions.first`——`SessionRepository.list()` 按 `updated_at DESC`，create 后 updated_at 最新 → first；否则 `_loadSessions`(main.dart:574-585)选中空会话、send 时 `_currentId==null` → `_newChat()`(main.dart:689-706)建全新空会话，fixture 被孤立）；② 然后 **pump** `MaterialApp(home: AppShell(configLoader: () => ConfigResult.ok(smallConfig)))`（`smallConfig`: `agentTypes.general.maxContextTokens: 300` + provider/model 用真实值 + providers 用真实 apiKey/baseUrl；`maxContextTokens` 调优至 `plan.shouldCompact` 成立）→ 应用 initState `_loadSessions` 选 `sessions.first`（fixture 会话）+ `_loadMessages` 载入其消息；③ send 一条消息 → 触发真折叠 → `pumpUntilReplyOrTurnDone` → **⑩c 门**：若 `readFinalAssistantReply` 以 `'Error:'` 开头（模型/API 错误）→ `markTestSkipped('API unavailable')`（TESTING.md §3.2，镜 real_api_test.dart:177-182）+ return。**否则** `SummaryNodeRepository().queryBySession(sessionId)` 读 `summary_nodes`：
  - **空**（`Error:` 已排除）：`[OBS]` dump `dumpToolCards`+`dumpFile`+折叠相关证据 → `fail('no summary persisted — fold errored OR bloat-omit; the far-span re-execution keys were never preserved in a summary')`。**不 skip**——空 `summary_nodes` 若源于 D3/D4 split-if-invalid 的 bloat-omit（真实模型把每批都压得 ≥ 原批而省略，main.dart:1638-1646/1782-1825），那是**真实质量失败**（模型没能把含钥匙的远端压成更小摘要），必须 surface 而非隐藏；若源于 fold 摘要器抛错降级 verbatim（main.dart:870-885），也会因未 materialize 落空 → 同样以 [OBS] 暴露，可归因。**只有 `Error:` 回复属环境、才 skip**。
  - **非空**：测试侧解析 `node.summaryJson`（`{role,content:[{type:text,text}]}`）取 `text`，断言 **③a 真实摘要文本含 key**（`/Users/acme/src/config.dart` + `timeout` + `30`）+ **③b 有效压缩**（该 summary 节点 `token_cost` < 折叠带 raw；即"真实摘要 < 它替换的批"，否则 bloat,非质量胜）+ **③c P1 行为连续性**（`readFinalAssistantReply` **引用** preserved key，如含 `30`/`timeout`/`config.dart`/`email`——证 key 进了模型收到的投影、助手能用，恢复 A-2 的"投影进入"信号）。注：不能调用私有 `ChatScreenState._summaryTextFromJson`——不同 library，测试自行解析 summary_json。→ `[OBS]` dump `dumpToolCards`+`dumpFile`+**摘要全文**+raw vs token_cost。`timeout: Timeout(Duration(seconds:300))`。依赖 R-A2-2。
- [x] **R-A2-4 A-1 fixture session-id 参数化**：`real_context_fixture.dart` 的 `buildConfigRefactorConversation` 增 `{String sessionId = 's1'}` 参数（或 R-A2-3 测试侧把 fixture 消息的 sessionId 改写成真实 session id）；确认超预算会话可触发折叠（maxContextTokens 调优）。依赖 R-A2-3。验证：窗口 live 里 `queryBySession(realId)` 返回 seed 的消息。
- [x] **R-A2-3a 严格 hasCompleteConfig 门（诚实审查发现A, LOW，修复 R-A2-3 测试代码）**：`_resolveLiveConfig`（integration_test/compact_quality_live_test.dart）曾用 `?? 'https://api.deepseek.com/anthropic'`、`?? 'deepseek-v4-pro'` 兜底，空 base_url/model 时不 skip，违 `Docs/TESTING.md §2.4:58`「绝不用 fallback 默认端点（空 base_url 会落到错端点）」。已修：env 分支 require overrideBase+overrideModel 均非空，缺则返回 null→skip；config 分支 require providerCfg.baseUrl + base.model 均非空，否则 null→skip；删除全部默认端点/model 兜底。依赖 R-A2-3（含逻辑是 R-A2-3 的代码）。验证：analyze 0 + 空 base/model 时 skip（不再往错端点发）。
- [x] **R-A2-3b seam 感知守卫诚实化（诚实审查发现B, MED）**：`firstSegRaw>1024` 守卫在**无 seam** 算术计划上算（compact_quality_live_test.dart:146-174），但实际折叠用 `ModelSeamSelector`(main.dart:274-276/857，因 AppShell 未注入 summaryProvider 而启用) → LLM seam 可切出更小批（实测 covered=[5,270] 只能由 seam 在 seq5 切出，算术 T≫150 不会在 seq5 切），该细小批 bloat-omit 丢路径 → ③a 诚实失败。已修：守卫注释明确为「算术基线（防算术级联挂死）；LLM seam(生产)可能切出更小批，后果由 ③a/空摘要 honest surface，不声称覆盖 seam（seam 需 LLM 不可预计算）」+ ③a reason 明确归因 seam 细小批 bloat-omit 机制。依赖 R-A2-3a。
- [x] **R-A2-5c 【生产返工，超出 R-A2 测试范围】恢复"累计>阈值→整批一次压"(修复 seam 整体替换批结构的执行偏离)**
  - **Context**：用户约定(2026-08-29 已定)：**从最旧累计对话片段，累计 > 阈值 `T=maxContextTokens~/2` 就把这整批统一压**成一份上级摘要；**同规则累计一批 L1 > T → 统一压成一条 L2**。核心是"累计→超阈值→整批一次压"，**不是"每段/每缝单独压"**。design.md D5(53-54) 明言"seam **只微调分界位置、绝不改批量结构**"。但**执行偏离**：`lib/services/compaction/compaction_plan.dart` `_batchL1`(346-354) 当 seamChooser 存在且返回合法缝时，用 `_normalizeSeams`+`_segmentsFromSeams` **整体替换**掉"累计>阈值"的算术批边界，变成**每个 seam 段各自压缩**。
  - **偏离后果(实测 A-2 窗口 live)**：AI 挑缝把"配置话题"(seq1-5,~150 token)当独立话题切成单独小段 → 单独压缩压不动 → split-if-invalid **整段 bloat-omit** → 再执行钥匙(绝对路径)丢失 → 摘要面 `covered=[6,270]` 不含路径 → A-2 ③a 失败 / flaky(seam 随机，有时保有时丢)。这正是用户指出的"对每个片段单独压缩"，违背约定。
  - **Goals**：(1) 恢复"累计>阈值→整批一次压"；(2) seam 仅为**微调**——只能在"累计>阈值批边界"附近调整到最近安全话题缝，用于话题连贯，**绝不能把某批切成会压不动的小段**；(3) L2 同规则(累计 L1 > T → 一条 L2)。
  - **Non-Goals**：不删除 seam(方案 A 保留)；不改变"最新始终 verbatim / 只省略最旧 / 数据留盘 D9"；不削弱 A-2 ③a 断言。
  - **设计决策(改法)**：给 seam 加**双重守卫**(任一失败 → **回退整段确定性算术骨架**)——①**尺寸守卫**：任一段 raw < `max(1, T~/2, 1025)` (`1025`=summary 上限 `max_tokens=1024`+1；真实压缩边界是 1024 而非 T~/2，`T~/2` 在小预算可能 <1024，如 A-2 自调 T~/2≈957)即判"切成会压不动的小段"；②**锚定守卫**：每个 seam 必须落在**对应算术批边界**的邻域窗口内(如 ±该批的一部分)，否则判"**wholesale 重排批结构**"(正是本任务点名要修的 `整体替换批边界` 偏离)→ 拒。两守卫都要，否则尺寸守卫只挡"极小段"，一个段都够大的 seam 仍可整体重排(其构成仍是"一缝一段各自压"——偏语义)。**诚实记录(2026-09-02 轮3 审查据实修正)**：该"缝约束在批边界窗口内"的效果由**锚定守卫 post-hoc 拒**承担——`seam_selector.dart`(94-97/105-117)本身**未**把候选集收窄到"批边界附近"，仍向模型给**全量安全集**，prompt 也未限"从对应批边界附近挑"；far/wholesale 缝被锚定守卫拒→回退算术。故用户意图"缝只微调、绝不重排"**成立**(经守卫拒绝达成)，但**机制是守卫拒、非候选集收窄**；其代价是 LLM 更常提出会被拒的 wholesale 缝→更多算术回退(话题连贯性比"候选集收窄"方案弱，但**正确性不受影响**，含钥匙保 护全在双守卫)。**候选集收窄**是一项**未实现的已知细化**(可让话题缝更常生效)，如需可按后续任务补做。**约束产生的净效果(缝只影响"把边界挪到最近话题缝"，不改变批的构成/数量)**由锚定守卫保证。**L2 分组同样不得被 seam 改成极小 L1 组**。**注意**：双守卫对"批≥~T 且 >1024"的大规模折叠才有意义；小预算/小对话批必 <1025 → seam 一律回退算术(正确——小对话无需话题微调)。**不做**"含钥匙批压不动就原样发送"——D3(design.md:41)/⑪-E 已定论原子批"省略(投影不发、数据留盘)"；"原样发送"会把最旧原文插进投影、破坏 `[摘要][verbatim 尾]` 结构与 recency 梯度(design.md:28)，且需投影层 verbatim-就地-交错重构(design.md:41 "本轮不做")。故含钥匙批的命脉靠**双守卫**，而非改 omit 语义。
  - **验收**：(1) `compaction_engine` 新增单测——给定会把配置话题切出 <max(T~/2,1025) 小段的 seam，断言 seam 被拒、走整段算术骨架、该批 raw>1024；(2) **已知需改(迁移)现有 seam 测试**——均用 seamChooser `[1,6,11]` + budget160、断言 `summaries.first.messages.length, 1`(首批=1 条，即旧"极小首批"偏离行为)：(a) `test/unit/compaction_engine_test.dart:172-197`('4.3 valid seam repositions the L1 interior boundary')；(b) `test/unit/seam_selector_test.dart:121-147`('4.3 end-to-end: memo-backed chooser preserves the LLM seam through buildTree')。**空转**：`test/unit/compaction_engine_test.dart:224-237`('deterministic with seamChooser') 用同一 `[1,6,11]`——被守卫拒后两次都回退算术(测试不红但 seam 路径不再覆盖)。**迁移方向**：改用"**各段均 ≥max(T~/2,1025) 且各 seam 落在对应算术批边界邻域内**"的**大预算** seam(真正微调，非 wholesale 重排)以保留正向"seam 生效(边界被挪到最近的合法话题缝)"断言；并**新增**断言"wholesale 重排(seam 远离算术批边界)或过小 seam 被**双守卫**拒→回退算术"；(测试改动需审批，同 R1-H3-1 interior-snap 测试)；(3) A-2 窗口 live **结构 flakiness 关闭**——含钥匙批不再被 seam 切成 <max(T~/2,1025) 小段、`covered` 覆盖到含钥匙批(结构稳定，钥匙批 raw>1024 恒可压)；③a 仍是**字面杆**(design.md:87，lossy 模型仍可能 false-fail)，**只承诺"钥匙批必进摘要(结构)"，不承诺"字面路径每次必现"**；(4) `flutter analyze` 0 error。依赖 R-A2-3b(守卫诚实化)；**是 R-A2-5 的前置**(R-A2-5 依赖已补入 R-A2-5c。)
  - **为何不只改测试**：根因是**生产折叠算法偏离约定**，改测试只能掩盖/跳过，不能算真修；按"设计正确/执行偏离"须**重做对齐设计**([[feedback-redo-execution-deviation]])。
- [x] **R-A2-5d 【生产返工，超出 R-A2 测试范围】让工具轮输入(含绝对路径)真正到达摘要器**(修复 content-empty tool-call assistant 被折叠输入丢弃)
  - **Context**：`lib/main.dart` `_buildChatItems`(605-658) 跳过"content 为空且有 toolCallsJson"的 assistant(只建 ToolCallCard,不建 ChatMessageItem)→ `_chatItemsToMessages`(653-658) 漏掉它 → 该消息不进 `buildTree`/折叠输入 → `ModelSummaryProvider.summarize` 的 `folded` 里**没有**带 tool_use 的 assistant → `_toolRoundText`(model_summary_provider.dart:184-194) 不触发 → `kSummarizeInstruction` 要求"保留工具调用 input(含绝对路径)"，但**工具轮 input 根本不在摘要器视野**。**归因（务必精确）**：这是由**代码层**确认的独立缺口(content-empty 工具轮必丢)——但**不是**由 A-2 实测摘要"No file paths / no tool calls"证明的；该实测的**主因是 seam-omit**(R-A2-5c：covered=[6,270]，含路径的 seq1-4 批被 seam 切出丢弃，摘要器看到的是无路径的 seq5+)。且 fixture 把路径写在**纯文本** seq1(user)/seq3(assistant)，若未因 seam 丢弃、摘要器本就可见——故工具轮丢失只影响"路径作为 tool_use input 显式出现"，不改变"(纯文本)路径可能被摘要保真"这一主信号。工具轮若是"仅工具无正文"(deepseek tool-only turn)则必丢。
  - **Goals**：让**工具轮的 tool_use input(绝对路径)进入折叠输入/摘要器**，使再执行钥匙可被摘要保真。**不破坏**工具轮原子性(绝不拆 tool_use/tool_result)、不改变 `_buildApiMessages` 的合成语义、不难测它。
  - **设计决策(改法)**:在折叠输入构造(或 `_chatItemsToMessages`)保留 content-empty 的 tool-call assistant 消息(它们承载 tool_calls 与结果)，使 `folded` 含工具轮 → 摘要器 `_toolRoundText` 渲染 `input.path`。**前置需要先核实**：`_buildApiMessages`(main.dart:2032-2118)现在是否就靠这些 tool-call assistant 合成 tool_use/tool_result？若之前也被丢，则该修复同时恢复"模型看到工具轮"——需在 unit/integration 验证工具轮完整进出。
  - **验收**：(1) unit/integration 测试——含 content-empty tool-call assistant 的消息列表折叠时，摘要器 `folded` 含工具轮、`_toolRoundText` 渲染出 `input.path`；(2) `_buildApiMessages` 合成 tool_use/tool_result 不被破坏(工具对完整性测试)；(3) A-2 窗口 live 的 [OBS] 摘要可观测到工具轮 input(填补"No tool calls"缺口)；(4) analyze 0 error。
  - **说明**：与 R-A2-5c 是互补的两条独立根因(seam-omit + 工具轮丢失)；执行时需一起做才真正闭合"路径丢失"。**未在 R-A2-5 范围内**——是独立生产改动。

### 诚实审查 轮1 发现（R-A2-5c/5d 实现，2026-09-02；已修复）

> 轮1(4 lens × 8 findings, N≥3 REFUTE-skeptics + majority-kill, offline)对 R-A2-5c/R-A2-5d 的实现做对抗。CONFIRMED 2 条真缺陷(均关于 R-A2-5d)，如下已修复。均**不改验收标准**：A-2 ③a 保留在窗口 live，未下放 offline。

- [x] **R-A2-5d-1 FIX [HIGH] `_buildApiMessages` 对 content-empty tool-call assistant 双重合成 tool_use/tool_result**（审查轮1 确认）
  - 文件: `lib/main.dart` `_buildApiMessages`(2033-2117)。
  - 问题: R-A2-5d 保留 content-empty tool-call assistant 后，`_chatItemsToMessages` 含 [user, 空中间件(final 之前的 tool 助手), final-allTurnToolCalls]。`_buildApiMessages` 对**每个** toolCallsJson 非空的 assistant 都合成 tool_use + synthetic tool_result(main.dart:2056-2079/2081-2114)；而 final assistant 由 1143-1144 冗余携带 `allTurnToolCalls`(该轮全部工具调用的超集)。故空中间件(含 toolA) + final(含 toolA) → **同一 tool_use_id / tool_result 被合成两次** → 无效请求(重复 tool_use_id)。R-A2-5d 前该空中间件被 `_buildChatItems` 丢弃,单个 final allTurnToolCalls 还原一轮——**旧行为对"仅工具无正文"轮是单次合法合成**;R-A2-5d 把它保留后 = 其要修复的子情形被破坏。非空中间件的同类重复为**预存在**,一并修。
  - 修法: `_buildApiMessages` 增 `emittedToolUseIds` 集合——**仅首个(最旧)携带某 tool_use_id 的 assistant 合成该 tool_use + tool_result**;空 id 视为恒唯一(不误去重)。`ownedToolCalls` 单次计算,供 tool_use 块与 tool_result 共用。注释说明"最终 assistant 冗余携带 allTurnToolCalls → 每轮只合成一次"。
  - 设计: D6 工具轮原子性(保留,不拆对)——只去重合成,不改轮结构。**验收**: tool_call_test / tool_persistence_test / tool_result_elision_test / compaction_projection_test 全绿(+各自 [OBS])。
- [x] **R-A2-5d-2 FIX [MED] R-A2-5d 首个单测空转(绕过 `_buildChatItems`)**（审查轮1 确认）
  - 文件: `test/unit/model_summary_provider_test.dart`。
  - 问题: 原测试直接 `summarize(folded: [toolAssistant])`,绕过 R-A2-5d 实际改动点(`_buildChatItems`/`_chatItemsToMessages`)。`ModelSummaryProvider._toolRoundText` 不受 R-A2-5d 影响、只要喂给 tool assistant 就渲染——故该测试**在未修复时也通过**,无法检测"`_buildChatItems` 再次丢弃空 assistant"的回归。
  - 修法: ①把该单测重框为**summarizer 契约测试**(注释声明 scope: 只验"给定含工具轮的 folded → 渲染 input.path",不声称测 `_buildChatItems`);②**新增真回归测试** `compaction_projection_test.dart` 'R-A2-5d FIX: a content-empty tool-call assistant reaches the fold input'——用 `_RecordingSummaryProvider` 记录每次 summarize 的 `folded`,pump 真 `ChatScreen`(`_loadMessages`→`_buildChatItems`→send→超预算折叠),断言某个 `folded` 含 content-empty tool-call assistant 且其 toolCallsJson 含 `kConfigPath`。**改动前该 widget 测试必失败**(空 assistant 被丢),改动后绿([OBS] foldedCalls=3 hasToolRound=true hasPathKey=true)。
  - 设计: CLAUDE.md 测试可观测性(断言前 [OBS] dump)。

### 诚实审查 轮2 发现（R-A2-5d 轮1 修复的 2 次审查,2026-09-02;已修复）

> 轮2(4 lens × 4 findings, N≥3 REFUTE-skeptics + majority-kill, offline)对 R-A2-5d-1/R-A2-5d-2 修复做二次对抗 + R-A2-5c 回归。CONFIRMED 1 条(测试覆盖缺失,非代码 bug),如下已修复。

- [x] **R-A2-5d-3 FIX [MED] 去重无 hermetic 回归测试(revert 去重后 143 测试仍全绿,仅 A-2 live 会暴露)**（审查轮2 确认）
  - 文件: `test/integration/compaction_projection_test.dart`(新增 'R-A2-5d-1 DEDUP' 测试)。
  - 问题: R-A2-5d-1 的 `emittedToolUseIds` 去重(R-A2-5d-1 修复)不被任何 hermetic 测试覆盖——R-A2-5d FIX widget 测试只断言 summarizer 的 `folded` 输入,不检 `lastMessagesJson`;tool_result_elision/A-1 fixture 的"final 助手"均不重复携带 id;tool_call_test 驱动 live 轮但从不基于重建历史重发。故 revert 去重会重新引入重复 tool_use_id,而 143 hermetic 测试全绿——只有 env-skip 的 A-2 live 会暴露。
  - 修法: 新增 hermetic 回归测试——seed 一个对话含"中间 tool 助手(自身 turnToolCalls)"+"final 助手(重复携带 allTurnToolCalls 超集)",pump ChatScreen 走真 send 路径(under-budget → `_buildApiMessages`),解析 `sidecar.lastMessagesJson`,断言该 id 恰有 **1** 个 tool_use + **1** 个 tool_result(revert 去重 → 变 2)。[OBS] 前置 dump: toolUseCount/toolResultCount。
  - 验证: `flutter test test/integration/compaction_projection_test.dart --name DEDUP` → [OBS] toolUseCount=1 toolResultCount=1(All tests passed)。

### 诚实审查 轮3（收尾,2026-09-02）发现 — 已修复

> 轮3(收尾,3 lens × 1 finding, N≥3 REFUTE-skeptics + majority-kill, offline)对 R-A2-5d-3 补测 + R-A2-5c/5d-1/5d-2 全量回归。CONFIRMED 1 条(**记录准确性**,非正确性/非 ③a 弱化)。

- [x] **R-A2-5d-4 FIX [MED,记录准确性] R-A2-5c 任务文本过度声称"seam SELECTOR 候选集已收窄到批边界附近"**（审查轮3 确认）
  - 文件: `openspec/changes/add-auto-context-compaction/tasks.md`(R-A2-5c 设计决策)、`design.md` D5。
  - 问题: 已完成 R-A2-5c 任务声称"seam SELECTOR 的候选集须只含'各算术批边界附近'的安全候选, prompt 明示'从对应批边界附近挑出 count 个'"——但 `seam_selector.dart`(94-97/105-117) **未变**,仍给模型**全量安全集**、prompt 列全部候选,`ensure(far,k)` 也不收算术边界。实际约束为 `_batchL1` 的**锚定守卫 post-hoc 拒**(compaction_plan.dart `_seamAnchorGuardAccepts`)——far/wholesale 缝被拒→回退算术骨架。**正确性不受影响**:含钥匙/路径批次保 护全在尺寸守卫 + 锚定守卫(compaction_engine_test 'size guard' 断言首批 raw>1024 已测),A-2 ③a 未动。仅是"机制是守卫拒、非候选集收窄"的记录过度声称;代价是 LLM 更常提被拒的 wholesale 缝→更多算术回退(话题连贯较"候选集收窄"弱)。
  - 修法(记录据实修正,不改代码): tasks.md R-A2-5c 设计决策 + design.md D5 改为——锚定守卫 post-hoc 保证"缝落在对应算术批边界邻域"(用户意图"缝只微调、绝不重排"成立且经守卫拒达成);**候选集收窄是未实现的已知细化**(可让话题缝更常生效,如需按后续任务补做),如实记录,不声称已实现。

- [x] **R-A2-5 回归 + 运行验证**：`flutter test test/integration/`（offline 全绿 + headless live 已删）+ `flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows`（窗口 live 通过 + 读到真实摘要含 key）+ `flutter analyze`（我的文件 0 error）。依赖 R-A2-3/4/R-A2-5c/R-A2-5d。
  - **验证实证(2026-09-02)**：窗口 live `-d windows` 真跑 → **All tests passed(exit 0)**。③a 摘要节点1(covered=[1,133],token_cost=555) 原文含 `/Users/acme/src/config.dart`+`timeout 120→30`+`email 相关配置绝不动`+`关键再执行钥匙/路径`；③b `555<1828` 有效压缩；③c 助手回复引用 key。此前 A-2 flaky 根因(seam 把配置话题 seq1-5 切小段→bloat-omit)已被 R-A2-5c 双守卫消除(配置话题并入 133 条大批 raw 1828>1024 一起压)。**诚实修正**：早先"本机无 apiKey、live 跳过"系误判——config.json 用 snake_case `api_key`(非空)，代码 `ProviderConfig.fromJson` 读 `api_key` 解析正确；实为未跑+看错字段名，非无 key。
- [x] **R-A2-6 诚实审查**：对本返工所有新增/改动开 Workflow 对抗验证（offline，N≥3 REFUTE-skeptics + majority-kill），确认合规 + 无新矛盾 + **未降级**（真实摘要质量断言保留在窗口 live，未下放 offline Fake）。依赖 R-A2-5。
  - **实证(2026-09-02)**：本返工已开 **3 轮**对抗式 Workflow（轮1 实现审查 → 轮2 修复二次审查+R-A2-5c 回归 → 轮3 收尾全量回归），各轮 N≥3 REFUTE-skeptics + majority-kill、offline。共确认 4 条真缺陷(见 R-A2-5d-1/2/3/4)，全部修复 + 回归验证。**未降级**：A-2 ③a 保留在窗口 live，未下放 offline Fake——并以窗口 live 真跑实证(③a/③b/③c 全过)作为最强验证。诚实性审查已达标。
  - **诚实注**：A-2 的 `[x]` 是关于"有意义真实上下文压缩质量测试"需求成立；但形态 headless-live 不合规。本返工把该需求落到**合规窗口 live（直测真实摘要质量）**——这正是对抗审查修正后的正确做法，不撤销 A-2 已勾选状态。

## 5. Phase 4 — 成本纪律 + 便宜层

- [x] 5.1 每会话折卷预算(折卷次数 / 折卷 token)封顶;可见性只作调试/回放视图(不引入用户可见的"管理压缩"操作)
  - 实现: `ChatScreenState.kMaxFoldsPerSession=30` / `kMaxFoldTokensPerSession=500000` + `isFoldBudgetExceeded(foldCount, foldTokens)`(纯函数封顶判定,public 供测)+ `_foldBudgetExceeded(sessionId)`(用 `summary_nodes` 的节点数 + `token_cost` 求和作折卷成本代理,`DatabaseService.isOpen` 守卫)。`_callModel`(on-demand 折卷)与 `_runBackgroundFold`(idle 后台折卷)均查 budget,超限→跳过折卷、改发 verbatim(best-effort 已知超限)。**可见性**: 仅 debugPrint(调试/回放视图),无用户可见"管理压缩"操作。
  - 测试: `cost_discipline_test.dart` '5.1 fold budget cap' — 纯函数封顶判定(count→cap+1 触发 / token→cap+1 触发 / 恰在 cap 不触发)。注: 完整 widget+真库路径因 FakeAsync black-hole(harness 已知限制)未做端到端;封顶逻辑本身直接单测。**诚实界**: `token_cost` 为折卷**输出**尺寸的代理,折卷 **input** 成本未按会话持久化(无该字段);封顶用可得的单调代理。
- [x] 5.2 破平衡点回归测试:折卷 input tokens ≪ 每请求省下的 input tokens(用实测 usage)
  - 实现: `cost_discipline_test.dart` '5.2 break-even' — 用 `_AccumulatingSummaryProvider` 累加**整次折卷**的 `totalFoldedRaw`(各 L1 批 estimateConversation 之和)与 `totalSummaryTokens`;断言 `savingsPerRequest = totalFoldedRaw - totalSummaryTokens > 0`(摘要 < raw,真正省)且 `totalFoldedRaw < kBreakEvenRequests(8) × savingsPerRequest`(折卷 input 在 8 请求内被省回)。**诚实界**: 这是归一化代理(design D10 的破平衡点),非 A-2 的"真实 usage"测量;真实折卷是单次 summarize 调用、input≈folded span,已由 A-2 live(real output_tokens)实证。
- [x] 5.3 便宜层:DeepSeek prompt-caching(`user_id`)+ 对远端采用**已存在的更粗摘要层**(非直接裁剪、不丢决策/再执行钥匙);近端大 `tool_result` **正文**(非工具对)轮内裁剪为截断标记 + 再取记录
  - 实现 ①**(已存在的更粗层)**: 对远端采用 level-2 "总结之总结"(4.x 已实现,非直接裁剪、不丢决策/再执行钥匙)——无需新代码。
  实现 ②**(prompt-caching user_id)**: `model_gateway.cpp` execute() 恒定注入 **嵌套** `body["metadata"]["user_id"]="aliasagent"`(对 Anthropic 兼容 `/v1/messages`,`user_id` 必须放 `metadata` 下——Docs/DeepSeekAPIDoc.md §2.2 `/v1/messages` Simple Fields "`metadata` | 仅`user_id`支持",§7 note 10 "`metadata.user_id`: 可用于 KVCache 缓存隔离";**顶层** `user_id` 是 §3.1 chat/completions 形式,`/v1/messages` 会忽略)。稳定 **app 级** 标识符,char set 合法。**诚实注**: 用稳定 app 级 id(非 per-session),因 summary profile 无会话上下文、避免贯穿 SummaryProvider 接口——per-session 隔离留作后续精细化;测试 `http_client_test.cpp` '[http_client] request body with all fields' 断言 `body["metadata"]["user_id"]=="aliasagent"`(Catch2 全绿)。
  实现 ③**(近端大 tool_result 正文裁)**(spec "Near-zone oversized tool_result body elision"): `_buildApiMessages` 的 tool_result 合成中,`_elideOversizedToolResult` 对超过 `kToolResultElisionThreshold=8000` 的正文裁为 头尾预览 + `[tool_result body elided: N chars > threshold; refetch via <tool> "<path>"]` 标记(tool_use 块/工具对/轮结构不变,D9 数据不删)。测试 `tool_result_elision_test.dart`: 超大→标记+tool_use/tool_result 结构保留,role 交替合法;小正文→原样透传。
- [x] 5.4 评估/钉 DeepSeek `/v1/messages`(Anthropic 格式)usage 字段(`input_tokens`/`output_tokens`, **2026-08-26 live 验证已确认**);`prompt_tokens` 属 chat/completions,勿混用;禁止借 Anthropic 模型窗口数
  - 评估: 2026-08-26 live 探测已确认 + 本 change 的 **A-2 live 测试**又用**真实 output_tokens**(≈1024)实证。钉: `model_gateway.cpp` 防御解析 `input_tokens`(message_start)/`output_tokens`(message_delta),Catch2 `sse_parser_test.cpp` '[sse_parser][usage]' 钉 `done_input_tokens==25`/`done_output_tokens==15`;Dart 侧 schema v6 持久化 `output_token_count`,`schema_migration_test` 钉 v6;`Docs/context-compression-reference.md`/`DeepSeekAPIDoc.md` 记录 `/v1/messages` 用 `input_tokens`/`output_tokens`、`prompt_tokens`/`completion_tokens` 属 chat/completions。**禁止借 Anthropic 模型窗口数**: 已遵守(`maxContextTokens` 为必填配置,无默认窗口)。

## 6. Phase 5 — 对抗式诚实审查(Workflow)

- [x] 6.1 开 Workflow 对**全部已勾 `[x]`** 任务做对抗验证:多 agent 从不同维度独立审查,交叉验证发现的问题(禁止手动/确认式单 agent)
- [x] 6.2 逐项核查压缩历史从不:(a)拆 tool_use/tool_result (b)丢 tool_input 再执行钥匙 (c)丢用户目标/验收标准/不变量 (d)合成 thinking/tool_use/tool_result 块 (e)丢 workspace 根
- [x] 6.3 发现的问题**追加为新任务**到文件末尾(绝不撤销旧 `[x]` 勾选);最后一项仍是诚实审查任务
- [x] 6.4 回归检查前几轮已修项是否被本轮破坏;发现回归 → 追加修复任务
- [x] 6.5 反复循环,直到诚实审查确认无问题,或达 **3 轮上限**;达上限后仍需一轮收尾审查且所有发现全修复
- [x] 6.6 停止时输出审查结果报告:已审查轮数、每轮问题数、最终任务状态(最后一条消息必须是该报告)

## 7. 原始 Round-1 审查遗留（未完成项，enforcement 类）

- [x] 7.1 R1-7 runtime "required config" enforcement: 运行时未设 `maxContextTokens` 仍静默禁用压缩（无 setup prompt）— spec 要求像缺 apiKey 一样 surface。Setup dialog 仅对新配置强制，运行时 re-prompt 未接。
  - 实现: `_loadConfig` 在 `ConfigStatus.ok` 后经 `addPostFrameCallback` 检查 `registry.lookup('general')?.maxContextTokens`，为 null/≤0 时 `_showSetup()`；加测试 `ok config whose agent lacks maxContextTokens surfaces SetupDialog (R1-7)`（app_shell_test.dart，通过）。审计未跑 return — 若后续 Phase 6.x 对抗审查发现过宽/循环可再调。
- [x] 7.2 R1-8 task 3.1 dirty-seq 水位线/按受影响 span 重算未实现（现为无状态整树重算）。设计分叉；需「watermark 方案」或「显式 stateless recompute 验收」。**已在返工 ⑥ 覆盖。**（⑥ 已实现 markDirty/clearDirty/dirtySinceSeq + reuse-gate；本项以完成处理。）
- [x] 7.3 R1-9 task 1.3 仅存 input_tokens 到 token_count，output 丢弃（单 INTEGER 列）。注: budget 触发仅需 input；output 已携带但未持久化。
  - 实现: schema v5→v6 `messages.output_token_count` + Message model + message_repository.insert + main.dart 两处写 `lastOutputTokens` + FakeMessageRepository 同步；schema_migration_test 补 v6 断言（通过）。
- [x] 7.4 R1-10 (预存在, 非本 change 范围) `_formatSearchResultForDisplay` `preview.substring(0, maxLen-totalLen-5)` 可抛 RangeError → 被 try/catch 吞，搜索结果丢弃。Report to owner；不修（scope discipline）。
  - 处理: 记档为已知预存在缺陷、非本 change 范围（scope discipline，不修）；design 附录 A 已标注。

## 8. 诚实审查循环任务（Phase 5 的收尾 per CLAUDE.md 3 轮上限规则）

- [x] 8.1 re-run adversarial Workflow over ALL `[x]` tasks INCLUDING R1-1..R1-6 + 返工 ①-⑧, verify no regression (tests: 61 integration + widget 69 + C++ 229/230 + migration/alternation/engine/guard + analyzer 9 pre-existing-only)。
  - Workflow `review_phase8_wrap.js`(4 维度:N≥3 REFUTE-skeptics + majority-kill,offline)跑 `[x]` 全量 + 最新修复。**发现并修复**: R8-a(空摘要(empty summary)done==0 静默占位符→改成 throw 回退 verbatim)、R8-b(R1-5 verbatim 回退无 hermetic 测试→新增 compaction_projection_test R1-5)、R8-c(stale omit 时 clearDirty 仍清零→onOmit 门控 persistFailed 阻止清零)、R8-d(coarsen L2 持久化但渐进封口不采纳→_loadClosedSegments 排序改 (minSeq ASC,maxSeq DESC,level DESC) 优先采纳最粗覆盖节点)、stale 注释(bump tree_version→markDirty)。
- [x] 8.2 confirm R1-3 (role alternation), R1-5 (summary-failure fallback), R1-6 (migration test) 在本轮返工后仍成立。
  - R1-3 成立(compaction_projection_test 'no consecutive role:user';elision path 也验证 alternation);R1-5 成立+新增测试(main.dart verbatim 回退 + R1-5 fallback 测试);R1-6 成立(schema_migration_test v3→v4/v6)。
- [x] 8.3 确认返工 ⑤ 的 (a)/(b) 决策已正确整合，返工 ⑥⑦ 已正确落地。
  - ⑤(a)/(b) 整合(buildTree=history,maxContextTokens,closed,seamChooser;触发=确定性本地估算器,design Goals 已对齐 D3);⑥ dirty-seq 水位线 + markDirty/clearDirty/dirtySinceSeq + materialize UPSERT(含 R8-c 修复);⑦ standing-requirements 守卫生产者从 config 播种 + 每轮 systemPrompt 注入。
- [x] 8.4 停止时输出审查结果报告: 已审查轮数、每轮问题数、最终任务状态（最后一条消息必须是该报告）。

## 10. 诚实审查 轮2/轮3 发现（追加修复）

- [x] **R2-H3-1 REGRESSION `farStart` 时间顺序颠倒 → 已撤销**（轮2 refuted）
  - 文件: `lib/services/compaction/compaction_plan.dart`
  - 轮1 的 H3-1 先改 `farStart` 拆分 leading→verbatim；轮2 对抗审查发现该做法让**最旧 leading 消息排在 far 摘要之后**（投影 `[摘要][verbatim]`，main.dart:1304-1305），时间倒序。
  - 修法: 撤销 `farStart`，恢复 `far=sublist(0,foldEnd)`/`near=sublist(foldEnd)`；buildTree Docstring 精确化——index 0 为会话起点段边（豁免，非段间边界；用户必发首条 user；between-message 边界无法拆合成 tool_result）。保留 `_budgetSegments` 内部 snap。见 Section 9 H3-1 最终裁定。
  - 设计: D6。**审批: 产品逻辑改动需审批。**
- [x] **R3-H-TEST 强化 vacuous「never splits a tool round」测试 → 最终改为真正非空转 D6 内部 snap 测试**（轮3 + 收尾轮 refuted）
  - 文件: `test/unit/compaction_engine_test.dart` (58-83)
  - 问题: ①原本 under-budget（vacuous）；②轮3 改为 over-budget(200) 仍 vacuous——k=1 退化单 chunk，无内部边界，`seg.messages.first` 只检查 index 0；收尾轮用无-snap 假实现证明该测试照常通过。
  - 最终修法: 改为 `interior far-span chunk boundaries are snapped to a safe boundary`：budget=160 使 k=2（chunkSize=10，边界在 index 10=带 tool_calls 的 assistant），`_budgetSegments` 将其 Snap 到 11。断言 ①`shouldCompact==true` ②summary chunks ≥2（非退化）③无 summary chunk 以 tool_calls 开头。实测 `[OBS] starts=0,11`（Snap 生效；无-snap 会在 10 起 chunk2 而 fail）。**真正非空转、可失败。**
  - 设计: D6。**审批: 测试改动需审批。**

## 9. 诚实审查 轮1 发现（由 honesty-review Workflow 验证；追加修复）

> 轮1（18 agents，6 claims × 3 个 REFUTE 怀疑者，offline）结果：claim 2/5/6 存活；claim 1 评论细节 nit（非 refute 但需改）；claim 3 与 claim 4 被 refute，须修复。以下为追加修复任务。

- [x] **R1-H3-1 FIX `_budgetSegments` 最左 chunk 起点未安全对齐（claim 3 refuted；最终= 文档精确化 + 保留内部 snap）**
  - 文件: `lib/services/compaction/compaction_plan.dart`
  - 问题（轮1）: 只 snap 内部边界；首个 chunk 起点 index 0 未检查。
  - **最终裁定（轮2 refuted 后修正）**: 先试 `farStart` 拆分 leading→verbatim，但轮2 对抗审查发现该做法引入**时间顺序颠倒**（最旧 leading 消息被排在 far 摘要之后投影，main.dart 投影为 `[摘要][verbatim]`）。改回：**index 0 是会话起点段边，非段间边界，豁免**（用户必发首条 user 文本；且 between-message 边界无法拆 tool round——tool_result 由同一 assistant 消息合成）。故**撤销 farStart**，改为精确化 buildTree 注释（内部 chunk 起点由 `_budgetSegments` 对齐安全边界，保留④；fold 边界对齐保留）。malformed-lead 测试移除。
  - 设计: D6。**审批: 产品逻辑改动需审批。**
- [x] **R1-H4-1 FIX clearDirty 在 materialize 失败时会掩盖真实陈旧（claim 4 correctness refuted）**
  - 文件: `lib/main.dart` `_resolveSummaries`
  - 问题: 若某个 summary 的 `materialize` 抛错被 catch 吞（行 ~1235），循环继续；随后 `clearDirty` 无条件重置 watermark → 下一轮 `dirtySince==0`，旧 stale 缓存节点被复用，违背自身注释「a failure just means a stale cached node gets regenerated」。
  - 修法: 记录本次 pass 是否有 persist 失败；仅当全部成功才 `clearDirty`；否则保留 watermark。
  - 设计: D8。**审批: 产品逻辑改动需审批。**
- [x] **R1-H4-2 CLEAN UP `bumpTreeVersion` 死代码 + 错文档 + 旧测试（claim 4 spec refuted）**
  - 文件: `lib/services/summary_node_repository.dart`, `lib/main.dart`, `test/integration/summary_node_repository_test.dart`
  - 问题: `bumpTreeVersion` 生产已无调用（updateToolCalls 改用 markDirty），但注解仍写「Called from updateToolCalls」；`treeVersion()` 生产也无人读；测试「bumpTreeVersion invalidates the tree」断言被取代的失效机制。dirty 失效已由 `_resolveSummaries` 的 reuse-gate 承担。
  - 修法: ①`bumpTreeVersion` 保留为物化计数（materialize 内已 bump），改注解为「materialize 每写一次 bump 一次，仅作计数，不驱动失效」②旧测试改为断言 markDirty/clearDirty 语义（或删除被取代的断言，说明已被 dirty-watermark test 覆盖）③更新 database_service 陈旧注释「Create the v4 schema」/「Migrate 1→4」。
  - 设计: D8/D9。**审批: 代码+测试改动需审批。**
- [x] **R1-H1-1 FIX model_gateway 注释把 `adaptive` 误标为 §2.5 记载（claim 1 comment nit）**
  - 文件: `sidecar/src/model_gateway.cpp` 注释块 (~524-535)
  - 问题: 注释列出 `thinking.type` 值 `enabled | disabled | adaptive`，但 §2.5 的开关文本只记载 `enabled/disabled`；`adaptive` 非官方文档（doc L212 注明仅 live-verified + 项目使用）。
  - 修法: 注释改注 `adaptive` 为「项目使用 / live-verified；非 §2.5 官方记载」。
  - 设计: D7。**审批: 代码注释改动需审批。**

## 11. 设计一致性审计 发现（Round A，2026-08-28；追加修复）

> Round A（21 agents，7 claims × 3 REFUTE 怀疑者，offline）：无任何条款被多数判定为真实偏离（D1/2/4、D3、D7 全 MATCHES；D5/D10 全 DEFERRED；D6、D8、D9 各有 1 个怀疑者提出异议）。异议中，**D8/D9 抓到同一真实 bug** → 追加为下条。完整证据见 design.md 附录 A Round A 段。

- [x] **R0-H-BUG FIX `materialize` 只会 INSERT、从不删同 covered span 旧行 → 重复行 + stale reuse**（D8/D9 audit 发现；最小修复 + 直接可测）
  - 文件: `lib/services/summary_node_repository.dart` `materialize`（只 `txn.insert`）；`test/integration/summary_node_repository_test.dart`
  - 问题: 同 span `[a,b]` 被重算时再插新行不删旧 → 违反 D9「covered 稠密非重叠」+ `findCovering` 取到旧行。
  - 修法(**最小,不过度设计**): `materialize` 在同一事务内**先删同 `(session_id, covered_min_seq, covered_max_seq)` 旧行再插**(upsert)。补**直接可复现**测试 `materialize is an upsert`：同 span 写两次(OLD→NEW) → `queryBySession` 一行、`findCovering` 返回 NEW；改前必失败。未动 reuse-gate / 未加 span 级追踪(那才是过度设计)。
  - 设计: D8/D9。**审批: 产品逻辑改动(已完成+验证)。**
