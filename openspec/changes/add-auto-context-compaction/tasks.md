# Tasks — add-auto-context-compaction

> **执行顺序阅读指南**: 本文件是**唯一任务载体**，openspec 会从此文件解析 `- [ ]`/`- [x]` 作为任务并按序执行。**完整审查证据（R1/R2/R3 被发现记录、refute/NOT-a-bug 判定）见 `design.md` 附录 A**，不作为任务解析。若要执行返工，先做 Section 0，再做 Section 1-6 未完成项。

## 0. 返工主清单 — 按推荐执行顺序 (Round 2/3 对抗审查发现的修复)

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

## 1. Phase 0 — 遥测地基(token usage + 全序 + 配置)

- [x] 1.1 model_gateway 解析 `/v1/messages`(Anthropic 格式)SSE `message_start`/`message_delta` 的 usage,字段名按 Anthropic 格式 `input_tokens`/`output_tokens`(**原 [UNVERIFIED], 2026-08-26 live 验证已确认 `input_tokens`/`output_tokens`**),侧车防御性解析 usage 块(读端点实际返回的 token-count 字段);勿用 chat/completions 的 `prompt_tokens`
- [x] 1.2 sidecar FFI 新增 usage 回调(或扩展 on_done)把 input/output token 回传 Dart;sidecar_bridge 接收并透传
- [x] 1.3 insert 时把实测 usage 写入 `Message.token_count`(填补当前无 writer; 注: 仅存 input, output 未单独持久化 — 见 R1-9)
- [x] 1.4 `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;message/model/repository 透传 seq
- [x] 1.5 `AgentTypeConfig` 加必填 `max_context_tokens`;设置对话框新增必填项(同 apiKey 引导; 注: 运行时未设 maxContextTokens 仍静默禁用压缩 — 见 R1-7)
- [x] 1.6 schema v3→v4 迁移:seq + `summary_nodes` 表 + 每会话 `tree_version`;不给旧数据预建 rollup;镜像到 `openAt`;补迁移测试
- [x] 1.7 测试:usage 回传写库可观测(dump usage 后断言);seq 在同毫秒插入下严格单调;本地 token 估算器确定性

## 2. Phase 1 — 单层平铺 MVP(近段原文 + 一个根总结)

- [x] 2.1 实现 `buildTree(history, maxContextTokens)` 纯函数:分段 + 段边界规则 + 预算/cover + 近段原文 + 一个根总结;可注入 `FakeSummarizer`(决策/执行分离)（注: 原始措辞写作 `(history, config, proxy_usage)`，与实现不符——已修正为实际签名 `(history, maxContextTokens)`，对齐 spec "deterministic local estimator" 触发。见返工 ⑤(a)。）
- [x] 2.2 原子单元:折叠单元 = 带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result);段边界只落"真实用户文本 / 无 tool_use 的 assistant 终答",绝不落带 tool_calls 的行（注: 但 `_budgetSegments` 内部 chunk 边界未执行此规则 — 见返工 ④）
- [x] 2.3 摘要输出为 role:user 纯文本 + 明显标记(`## 更早上下文(压缩xN,非用户发言)`);不合成 thinking/tool_use/tool_result 块(DeepSeek /v1/messages 客户端侧标记,不依赖 chat/completions 的 `name` 字段)
- [x] 2.4 摘要请求 profile:复用 model_gateway,关 thinking、`max_tokens` 512-1024,末条 user 追加 summarize 指令;不用交互式 16K 路径
- [x] 2.5 组装投影:`_buildApiMessages` 改为读压缩树投影 `[system][摘要][近段原文][当前]`;节点按需展开(harness 注入,非 agent 工具)
- [ ] 2.6 后台折卷(idle-gated):槽空 + `_chain` 空 + 用户空闲才跑;request-id 定向 cancel;存断点"fold pending on segment N",下次空闲续折,绝不 delay 用户发送
- [x] 2.7 `summary_nodes` 落库(单事务)+ bump `tree_version`;折卷和用户请求轮换共享单槽
- [x] 2.8 测试:工具对完整性属性测试(折叠后仍合法交替、可喂回 `_buildApiMessages` 不拆对);树形/预算/确定性(FakeSummarizer);headless 集成(dump 折叠视图 + 前后 token)（注: 「前后 token」无测试实际输出 — 见返工 ③ R3-3）
- [x] 2.9 guard/anchor:实现不可压缩锚点——用户目标/验收标准/"don't touch X" 不变量 pin 为永不塌缩,每轮重注入,集合有界/去重/可失效;来源为显式 standing-requirements(非 LLM 从 prose 抽取)（注: 生产环境无生产者 seed, inject 恒空 — 见返工 ⑦）

## 3. Phase 2 — 失效/重算 + 两级梯度

- [x] 3.1 节点表按 `(session_id, level, start_seq, end_seq)` 键 + `covered_min/max_seq` 稠密非重叠 + `leaf_owner` 平面索引;insert/delete/updateToolCalls 标记受影响 span + 祖先 stale(dirty-seq 水位线),lazy 重算（注: dirty-seq 水位线/按受影响 span lazy 重算未实现，现为无状态整树重算 — 见返工 ⑥）
- [x] 3.2 失效触发基于**已有的** `updateToolCalls`(当前唯一叶子级修改);`tree_version` 递增验证;不为此变更引入新 delete/内容编辑(超出本 change 范围)
- [x] 3.3 两级梯度(knob B):level-1 段总结;recency 梯度作为 segment index + config 的纯函数
- [x] 3.4 测试:改中间叶子→仅受影响 span+祖先重算,cover 仍正确,tree_version 递增（注: 实际为整树重算，与「仅受影响 span」不符 — 见返工 ⑥）

## 4. Phase 3 — 全树 + canonical-cover 前锋 + 语义边界

- [ ] 4.1 层级用文本标记编码(非角色/块);"总结之总结"(level-2)卷起
- [ ] 4.2 ascend-on-the-left canonical-cover 前锋;预算驱动 `coarsen-only`(缩 N_verbatim / 换粗父);cover 稠密 + 完整 + 梯度单调
- [ ] 4.3 语义边界 A:LLM 在安全候选切点挑话题缝(嵌入同一摘要调用)+ memo 化(content hash keyed)保重建/测试可复现
- [ ] 4.4 测试:cover 稠密且完整;梯度单调(近详→远略);总预算 ≤ `maxContextTokens`;LADDER 可断言;确定性(同 history+config → 同树形);memo(重建用缓存不重调 LLM)

## 5. Phase 4 — 成本纪律 + 便宜层

- [ ] 5.1 每会话折卷预算(折卷次数 / 折卷 token)封顶;可见性只作调试/回放视图(不引入用户可见的"管理压缩"操作)
- [ ] 5.2 破平衡点回归测试:折卷 input tokens ≪ 每请求省下的 input tokens(用实测 usage)
- [ ] 5.3 便宜层:DeepSeek prompt-caching(`user_id`)+ 对远端采用**已存在的更粗摘要层**(非直接裁剪、不丢决策/再执行钥匙);近端大 `tool_result` **正文**(非工具对)轮内裁剪为截断标记 + 再取记录
- [ ] 5.4 评估/钉 DeepSeek `/v1/messages`(Anthropic 格式)usage 字段(`input_tokens`/`output_tokens`, **2026-08-26 live 验证已确认**);`prompt_tokens` 属 chat/completions,勿混用;禁止借 Anthropic 模型窗口数

## 6. Phase 5 — 对抗式诚实审查(Workflow)

- [ ] 6.1 开 Workflow 对**全部已勾 `[x]`** 任务做对抗验证:多 agent 从不同维度独立审查,交叉验证发现的问题(禁止手动/确认式单 agent)
- [ ] 6.2 逐项核查压缩历史从不:(a)拆 tool_use/tool_result (b)丢 tool_input 再执行钥匙 (c)丢用户目标/验收标准/不变量 (d)合成 thinking/tool_use/tool_result 块 (e)丢 workspace 根
- [ ] 6.3 发现的问题**追加为新任务**到文件末尾(绝不撤销旧 `[x]` 勾选);最后一项仍是诚实审查任务
- [ ] 6.4 回归检查前几轮已修项是否被本轮破坏;发现回归 → 追加修复任务
- [ ] 6.5 反复循环,直到诚实审查确认无问题,或达 **3 轮上限**;达上限后仍需一轮收尾审查且所有发现全修复
- [ ] 6.6 停止时输出审查结果报告:已审查轮数、每轮问题数、最终任务状态(最后一条消息必须是该报告)

## 7. 原始 Round-1 审查遗留（未完成项，enforcement 类）

- [x] 7.1 R1-7 runtime "required config" enforcement: 运行时未设 `maxContextTokens` 仍静默禁用压缩（无 setup prompt）— spec 要求像缺 apiKey 一样 surface。Setup dialog 仅对新配置强制，运行时 re-prompt 未接。
  - 实现: `_loadConfig` 在 `ConfigStatus.ok` 后经 `addPostFrameCallback` 检查 `registry.lookup('general')?.maxContextTokens`，为 null/≤0 时 `_showSetup()`；加测试 `ok config whose agent lacks maxContextTokens surfaces SetupDialog (R1-7)`（app_shell_test.dart，通过）。审计未跑 return — 若后续 Phase 6.x 对抗审查发现过宽/循环可再调。
- [x] 7.2 R1-8 task 3.1 dirty-seq 水位线/按受影响 span 重算未实现（现为无状态整树重算）。设计分叉；需「watermark 方案」或「显式 stateless recompute 验收」。**已在返工 ⑥ 覆盖。**（⑥ 已实现 markDirty/clearDirty/dirtySinceSeq + reuse-gate；本项以完成处理。）
- [x] 7.3 R1-9 task 1.3 仅存 input_tokens 到 token_count，output 丢弃（单 INTEGER 列）。注: budget 触发仅需 input；output 已携带但未持久化。
  - 实现: schema v5→v6 `messages.output_token_count` + Message model + message_repository.insert + main.dart 两处写 `lastOutputTokens` + FakeMessageRepository 同步；schema_migration_test 补 v6 断言（通过）。
- [x] 7.4 R1-10 (预存在, 非本 change 范围) `_formatSearchResultForDisplay` `preview.substring(0, maxLen-totalLen-5)` 可抛 RangeError → 被 try/catch 吞，搜索结果丢弃。Report to owner；不修（scope discipline）。
  - 处理: 记档为已知预存在缺陷、非本 change 范围（scope discipline，不修）；design 附录 A 已标注。

## 8. 诚实审查循环任务（Phase 5 的收尾 per CLAUDE.md 3 轮上限规则）

- [ ] 8.1 re-run adversarial Workflow over ALL `[x]` tasks INCLUDING R1-1..R1-6 + 返工 ①-⑧, verify no regression (tests: 61 integration + widget 69 + C++ 229/230 + migration/alternation/engine/guard + analyzer 9 pre-existing-only)。
- [ ] 8.2 confirm R1-3 (role alternation), R1-5 (summary-failure fallback), R1-6 (migration test) 在本轮返工后仍成立。
- [ ] 8.3 确认返工 ⑤ 的 (a)/(b) 决策已正确整合，返工 ⑥⑦ 已正确落地。
- [ ] 8.4 停止时输出审查结果报告: 已审查轮数、每轮问题数、最终任务状态（最后一条消息必须是该报告）。

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
