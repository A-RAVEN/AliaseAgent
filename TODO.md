# TODO

> **这是本项目的唯一待办文档。** 所有待办事项统一记录在本文件（项目根目录 `TODO.md`）。
> 位置已在 `CLAUDE.md` 中登记，请勿在其它路径另建 TODO / TODOList / 待办 等文档；
> 新增、更新、勾选待办一律改这一份。与 `Docs/known-bugs.md`（已确认的缺陷）区分：
> 本文件装“尚未开始 / 已立项待做”的事项。

---

## 🔒 钉死的原始要求：上下文压缩的阈值 —— **这是用户的原始要求、终极要求，任何设计不得偏离**

> **本节不是待办，是判据。** 用户 2026-09-13 明令把这条钉死在 `TODO.md`：**之后所有关于上下文压缩的设计**（摘要层级、阈值、预算、触发条件、分批大小、什么时候合并、什么时候停止），**动手前必须先逐条对照本节自检**。自检不通过 ⇒ **是设计错了，回去改设计** —— 不是"取舍"，不是"待商榷"，不是"已知限制"。

**用户原话（不得改写、不得用转述代替）**：

1. 「不设条数阈值，只设 tokens 数阈值，token 数阈值本身通过模型的上下文总数乘以一个百分比来定，比如 25%x1m 作为阈值。这是我一直以来要求的设计，如果你的设计偏离了这个要求，说明你有问题」
2. 「不应该定死一个数，始终应该按照模型总上下文的比例来算」

**拆成四条硬约束**：

| # | 硬约束（可核） |
| --- | --- |
| R1 | **阈值只按 token 数定。** 禁止任何形式的**条数**阈值 / 门槛（"至少 N 条摘要才合并""连续 N 条""攒够 N 段"一律不行）。 |
| R2 | **阈值不是常数**，必须由「**模型总上下文 token 数 × 百分比**」实时算出（例：25% × 1M = 250k）。 |
| R3 | **换模型自动跟着变**：窗口变大变小，阈值跟着变。**任何写死的绝对 token 数都是偏离。** |
| R4 | **百分比是唯一的旋钮。** 要调就调百分比；如果现状"达不到这个阈值"，那是**实现有问题，去改实现**，不许反过来把要求改成"不合理"。 |

**用户补充裁定（2026-09-13，关于"什么时候合成 L2 摘要"）**：**阈值到了就做。** 已生成的 L1 摘要（从最旧开始累加）实测 token 超过阈值，就**立刻**把它们合成一条更粗的 L2 摘要，**不看当前上下文还有没有空余**。我问过一次"是只在快装不下时做、还是到阈值就做"，用户答复：**到阈值就做，这问题的答案很明显**。→ 不要再把它当成待议的取舍，也不要再问第二遍。

**用户补充裁定（2026-09-13，关于"什么时候压原文"）**：**两层是同一条规则，原文那一层同样是"攒够阈值就压"。** 原文从最旧开始累加估算 token，**超过阈值就把这一批整体压成一条 L1 摘要 —— 不等窗口装满**。这是用户 **2026-08-29 就定下的统一规则**（原文原话：「从最旧累计对话片段，累计 > 阈值就把这整批统一压成一份上级摘要；同规则累计一批 L1 > T → 统一压成一条 L2」，记在 `openspec/changes/archive/2026-09-01-add-auto-context-compaction/tasks.md`）。**⚠️ 现状偏离**：代码是"尾巴超过模型容量才压"（`CompactionEngine._foldTail` 里 `totalProxy <= budget` 直接返回不压），我一度把这处现状当成规则复述并写进设计 —— **已更正**。不要再把"只有装不下才压"当规则。

**每次涉及压缩设计，必须回答的自检五问**（答不上来 = 没自检）：

1. 这次设计里**每一个**"什么时候触发 / 什么时候合并 / 什么时候停止"的判据，是不是**全都是 token 数**？有没有偷偷夹带条数、轮次、层级数？
2. 阈值是**算出来的**还是**写死的**？百分比是多少、在**哪个函数**里算？（写函数名，不写行号）
3. 换成一个 1M 窗口的模型，这个阈值会不会**自动翻倍**？拿什么证明？
4. 我有没有为了让某个机制"能跑起来"而**额外加一条计数门槛**？——**有 ⇒ 直接判偏离。**
5. 这个设计**真的够得着**这个百分比阈值吗？算一下：够着它最多需要多少条摘要同时存在？**够不着 ⇒ 是实现缺陷，必须修**，不许写成"已知限制/病理情况"收口。

**现状核对（2026-09-20 更新 —— 本节的上一版是 2026-09-13 读代码得出的，其中列出的偏离项已由 `openspec/changes/align-compaction-thresholds` 逐条处置；下面每条都附可核判据）**：

- ✅ **R2 / R3 已对齐（阈值只由一个百分比算出来，不再有写死的数）**：阈值现在只有一个计算点 —— `CompactionEngine.thresholdTokens(maxContextTokens, percent)`（模型容量 × 百分比 ÷ 100），原来的 `_batchThreshold`（写死"容量除以 2"）已删除，三处用途（分批边界、最新原文保留量、合成 L2 的阈值）全部改调它。百分比来自配置 `compaction_threshold_percent`（`AgentTypeConfig.compactionThresholdPercent`，缺省 25，缺失/非法值回落缺省并打印一次提示）。
  **可核判据**：`test/unit/compaction_engine_test.dart` 的「thresholdTokens」两条用例 —— 实测 `threshold 20000*25%=5000 40000*25%=10000`（容量翻倍 ⇒ 阈值翻倍）、`batchCount capacity20000=11 capacity40000=5 firstBatchRaw small=5285 large=10570`（容量翻倍 ⇒ 每一批的 raw 也跟着翻倍）；配置那条的判据在 `test/unit/agent_registry_test.dart`（有值 / 没有这一项 / 6 种非法值全部回落到 25）。
- ✅ **R1 已对齐（条数门槛已删除）**：原来合成 L2 除了 token 阈值还挂着 `consecutiveL1 >= 2 && groupCount >= 2` 这道"至少两条"的条数门槛，现在判据只剩 token —— `CompactionEngine.l2GroupCount` 在"累加始终没超过阈值"时返回 0（不再返回条数本身），收拢循环的判据是"组数大于 0"。
  **可核判据**：`test/integration/compaction_projection_test.dart` 的「一条 L1 摘要自己就超过阈值时仍然尝试合成更粗的 L2」—— 实测 `summarizeCalls=4 summarizeTextCalls=1`（改之前这个数是 0，被条数门槛拦下）；单元侧实测 `l2GroupCount([10,10], 50)=0 l2GroupCount([30,30], 50)=2 l2GroupCount([50], 200)=0`。
- ✅ **R3 已对齐（两处写死的绝对数都已删除）**：①`CompactionEngine._minBatchRaw` 里写死的 `1025` 已删（现在就是"阈值的一半"，纯派生）；②摘要请求在 `sidecar/src/model_gateway.cpp` 里写死的 `max_tokens 1024` 已删 —— 摘要请求现在不带任何本项目指定的输出长度，长度由模型/接口自己的默认值决定，"摘要一定更小"只由**实测**保证（合成出来的那条实测必须小于被它替换掉的那几条之和）。
  **可核判据**：①`test/unit/compaction_engine_test.dart` 的「阈值一半落在 600～1025 之间的接缝仍被接受」—— 改之前首批回退成 13 条 1300 raw（被旧下限拒），改之后是 9 条 900 raw（被接受）；②C++ 侧 `sidecar/test/http_client_test.cpp` 的两条摘要用例（断言"不再等于那个设计常量"、`thinking.type == "disabled"` 保留），实测 `[thinking]` 全绿 `29 assertions in 7 test cases`。规范同步：`openspec/specs/model-gateway/spec.md` 里"摘要 profile 的 `max_tokens` SHALL be 512-1024"那句已被本变更的 MODIFIED 块替换（归档演练实测 `~ 1 modified`）。
- ✅ **触发口径已对齐（两层同一条规则：攒够阈值就压，不等窗口装满）**：`CompactionEngine._foldTail` 里那条"没超模型容量就直接返回、什么都不压"的早退已按统一规则改写 —— 从最旧开始累加，每累计超过阈值就切出一批，一直切到剩下不足一个阈值；模型容量降级为**只做兜底**（压完仍超容量时，最旧的那部分这次不发，磁盘数据不删）。"压哪一段"的方向也一并改对：旧写法是"从最新往回保留到不超过阈值、其余全压"，总量刚过阈值时它只压最旧的一小截（不到阈值，压不动）；新写法压掉的是一整批约等于阈值的量。
  **可核判据**：`test/unit/compaction_engine_test.dart` 的「切分方向」两条 —— 实测 `略超阈值: foldedRaw=1100 verbatimRaw=200`（旧写法是 `foldedRaw=300 verbatimRaw=1000`）、`3.5 倍阈值: 批数=3 foldedRaw=3300 verbatimRaw=200`（旧写法 `foldedRaw=2500`）；集成侧 `test/integration/compaction_projection_test.dart` 的「6.1 原文攒够阈值就压」—— 内容只占容量 37.5% 时也照压，实测 `原文 raw=1512 lastFolded=11 hasSummaryMarker=true`（改之前 `lastFolded=null hasSummaryMarker=false`，原样全发）。
- ✅ **L1 摘要"一落盘就冻结"已解除（累加能跨轮次攒到阈值）**：载入的节点按层级区分 —— 层级 1 **可以**参与合成更粗的摘要（它的文本照旧直接复用，**原文绝不重压**），层级 2 及以上才是冻结的。参与本次请求的条目改成**一张按时间从旧到新排好的表**，遇到层级 2 就打断成组。
  **可核判据**：`test/integration/compaction_projection_test.dart` 的「3.4/6.4 跨轮次累加」—— 预置上一轮两条层级 1，再加本轮新压的一批，实测 `summarizeCalls=1 summarizeTextCalls=1 层级2覆盖=[1,19] hasL2Marker=true`（只调一次压原文，且三者被合成进同一条）。**真实模型下也验过**：live 用例实测 `summary node level=2 covered=[1,807] token_cost=463`、`sent messages contain L2 marker=true contain L1 marker=false`。
- ✅ **"每会话压缩上限"（条数 30 + 绝对 token 50 万）已整套删除**（2026-09-13 用户裁定「对于这种狗屎设计，没有任何留着的理由」）：它**不是用户要求，是我自己在 2026-09-01 那次变更里加的**。它量的不是"花了多少钱"，而是"这个会话已经产出过多少条摘要"（被粗摘要覆盖的小摘要行从不删除，只增不减），越过一次就**永久关闭压缩**（内联 + 后台两条路一起停）—— 触发后的后果比它要防的成本失控更糟；而且两个阈值一个是条数门槛、一个是与窗口无关的写死绝对数，正撞 R1 / R3；它还会**比阈值先咬合**，让"攒够阈值就压"这条要求根本没机会发生。
  **可核判据**：`lib/`、`test/`、`integration_test/`、`Docs/`、`CLAUDE.md` 下 grep `kMaxFolds|kMaxFoldTokens|isFoldBudgetExceeded|_foldBudgetExceeded|maxFoldsPerSession|maxFoldTokensPerSession` **零命中**（改之前非零：`lib/main.dart` 与 `test/integration/cost_discipline_test.dart` 各有十余处）；删它的理由逐条写在 `lib/main.dart` 中 `_summaryStoreOpen` 上方的注释里；台账记在 `Docs/rejected-approaches.md` 第 22 条。
  **注意（收尾审查发现）**：**`TODO.md` 自己不在上面这串路径里、也不要加进去** —— 本条判据的正文里就写着这些名字，把 `TODO.md` 纳入搜索范围会让"零命中"永远不成立（自指）。改之前那串"12 + 10 + 1 处"是当时的粗略数，复现口径不一，别把它当精确账目。
- ⚠️ **仍未消除的两项（如实留着，不粉饰）**：
  1. **"成本不能失控"这个意图现在无人承担**。删掉那道上限之后，没有任何东西管摘要调用的花销（每压出一批新摘要就多一次模型调用，随对话长度增长）。这是 2026-09-13 拍板"先不补替代护栏"的直接后果。将来若要再加护栏，必须同时满足三条（见 `Docs/rejected-approaches.md` 第 22 条与 design 的 D9）：量的单位就是被保护的资源（token / 花费本身）、阈值由模型容量派生、触发后**降级**而不是**停摆**且能恢复。
  2. **百分比取 25% 是先落地的取值，够不够得着要看对话有多长**（下一节的数字表）。这不是实现缺陷（实现侧的四重封顶已经全部拆掉），而是**阈值取值本身**的算术后果。2026-09-13 已拍板先按 25% 落地、实测再调；缺省值就写在 `AgentTypeConfig.kDefaultCompactionThresholdPercent`。

**够不够得着：把账算清楚（2026-09-20 更正后重写）**：

一次压缩会把"还没到阈值的那一截之外"的旧内容，按阈值切成若干批，每批压成一条 L1 摘要。所以**每压缩一次，待合成的摘要总量大约增加「(1 − 百分比) ÷ 百分比 × 每条摘要的大小」**。用"模型能装下 100 万 token、每条 L1 摘要约 1000 token"算：

| 配置的百分比 | 阈值（要攒够多少摘要 token） | 每次压缩大约增加多少 | 大概要压掉多少原文才出现第一条 L2 |
| --- | --- | --- | --- |
| 25% | 25 万 | 约 3000 | 约 6000 万 token 的对话 |
| 10% | 10 万 | 约 9000 | 约 1000 万 token 的对话 |
| 5% | 5 万 | 约 1.9 万 | 约 200 万 token 的对话 |

**这张表怎么读**：表里"每条 L1 摘要约 1000 token"是假设值，**不是固定的** —— 摘要长度现在由模型决定（本地文档 `Docs/DeepSeekAPIDoc.md`：`max_tokens` 上限 384K、非思考模式默认 8K），本仓库实测的 L1 摘要在 284～680 token 之间。**要凑够阈值，需要同时存在多少条 L1 = 阈值 ÷ 每条摘要大小**：按 1000 算约 250 条，按模型默认上限 8K 算约 31 条。也就是说"够不够得着"取决于三件事：阈值本身、每条摘要能有多大、能同时攒多少条 —— 前两件由这个百分比决定，第三件已经不再被封顶（冻结、条数门槛、写死的常量都已拆除）。

**实测旁证（2026-09-20 重测）**：真实模型跑 `compact_quality_live` 时，原文 12991 raw ⇒ 阈值 2165 ⇒ 一次性压出 **5 条 L1 摘要**（实测 549 / 290 / 680 / 550 / 428 token），随后**真的合成出 1 条层级 2 摘要**（覆盖 `[1,807]`，实测 768 token），而且它**确实出现在真正发给模型的内容里**（`contain L2 marker=true`、被合成掉的 5 条层级 1 **不再单独出现**）。上一版这里写的"只产出 2 条 L1、一条 L2 都没有；真实库 `summary_nodes` 0 行"是 2026-09-13 的旧观测，已不成立。

> **本节只钉"要求 + 现状"，不含方案。** 方案走 OpenSpec change；但**方案必须先过上面的自检五问**。另外，「**改用条数门槛**」这条被用户否决过的方案已记进 `Docs/rejected-approaches.md`（台账第 21 条）—— 那份台账是 Workflow / 子 agent 的固定输入，未来任何压缩设计都会看到它，**不要重新翻出来**。

---

## 状态标记
- `[ ]` 待办（未开始）
- `[~]` 进行中
- `[x]` 已完成

---

### [x] `compact_quality_live_test` 没留截图，缺 §5.9 要求的目视验收 —— **已完成（2026-09-20）**

**现象（可核）**：`integration_test/compact_quality_live_test.dart` 建了 `captureKey` 却**从未调用 `captureLiveShot`** —— 2026-09-13 跑该用例（`All tests passed!`，29s）后 `test/live_visual/` 下**没有新增任何截图**。而 `Docs/TESTING.md` §5.9 把「live 用例留截图 + 主循环 `read_image` 读图验收」写成**硬要求（非可选）**。

**完成情况（2026-09-20，随 `align-compaction-thresholds` 一并结清）**：用例体内已加 `try/finally` 包住整个执行段，`finally` 里调 `captureLiveShot(tester, captureKey, 'compact_quality_live')`（通过/失败/跳过/超时四种出口都会留图）。实测输出 `[SHOT] captured test/live_visual/compact_quality_live.png (55508 bytes)`。
**验收（判据）**：跑该用例后 `test/live_visual/compact_quality_live.png` **确实存在且是本次新写的**；已用 `read_image` 实际看过 —— 截图切在「真实上下文」视图，画面里 `[0] user` 那一条的标题就是 `## 更早上下文(压缩xN,层级2,非用户发言)`，其下是原样的近段原文。

**遗留**：同类 live 用例是否都有截图，仍未逐一核对（本次只覆盖了这一个）。

---

### [ ] 把 36 个既有 spec 迁到当前格式（缺 `## Purpose` / `## Requirements`）

**现象（可核）**：`openspec/specs/` 下 39 份 spec 里，**36 份**仍是旧格式 —— 顶层只有 `## ADDED Requirements`，既没有 `## Requirements`（openspec 只在这个小节下收集条文），也没有 `## Purpose`。归档某份 spec 的改动时会直接失败，报错原文两种：
`<名字> MODIFIED failed for header "### Requirement: …" - not found` 与 `Spec must have a Purpose section. Missing required sections. Expected headers: "## Purpose" and "## Requirements"`。

**2026-09-20 更新（数字与范围）**：本变更 `align-compaction-thresholds` 只修了**它自己要改的那两份** delta 目标 —— `openspec/specs/context-compaction/spec.md` 与 `openspec/specs/model-gateway/spec.md`（两份都补了 `## Purpose` 并把 `## ADDED Requirements` 改成 `## Requirements`；归档演练实测 `Totals: + 1, ~ 5` 通过）。**因此剩余 36 份**（原先这里写"38 个"，是 2026-09-13 的数；此后 `browser-tool` 归档时新生成的一份本就合规，本变更又修了 2 份）。
**复核命令**：逐个读 `openspec/specs/**/spec.md`，看顶层是否存在 `## Purpose` 与 `## Requirements` 两个小节头。

**原因（已取证）**：既有 spec 用的是当时的 delta 格式（以 `## ADDED Requirements` 开头），例如 `openspec/specs/agent-config/spec.md` 首行是 `# Agent Config — Spec` 紧跟 `## ADDED Requirements`。它们最后一次改动来自 **2026-08-02（`91f627c`）** 与 **2026-08-08（`4d24aeb`）** 两次归档 —— 即**历史上每次归档产出的都是旧格式**。本变更没有顺手全改，是因为那是一次独立的仓库级改动，混进来会让 diff 无法审阅（用户 2026-09-13 已拍板：本变更只改自己要改的那两份）。

**验收（能失败的判据）**：`openspec validate --specs` 输出里**不再有 ✗**（或仅剩明确记为豁免的项）；且每份 spec 至少含一个 `#### Scenario:` 块。

---

### [ ] 上下文压缩：L1 摘要泄漏 `ASSISTANT` 角色标签 + 重复对话下 L1 摘要冗余

**性质**：真缺陷（角色标签泄漏）＋ 设计商榷（冗余收拢）。

**背景 / 证据**：live 测试 `compact_quality_live_test` 的输出
`live_real_context_output.txt`（摘要 dump）里，第 2 条 L1 摘要正文以 `ASSISTANT用户在多轮开发中…` 开头
（第 1 条却是正常开头的 `对话摘要：…`）。这条污染的摘要会**原样进入真正发给 AI 的上下文**。

**2026-09-13 复现 + 新证据（比上次更严重）**：重跑同一用例（`All tests passed!`，27s，摘要 610 / 626 tokens），
**两条 L1 都带上了角色标签**，且形态不同：
- L1 覆盖 `[1,133]`：`ASSISTANT: 用户目标：重构项目配置，关键改动是把连接超时从 120 秒改为 30 秒。…`
- L1 覆盖 `[134,270]`：`ASSISTANT用户在多轮开发协作中，围绕一个 Dart/Flutter 项目…`
**现场文档**：`Docs/context-history-sample.md`（模型实际看到的上下文，顺序 L2 → L1 → 原文；
用 `extract-summary-history` skill 生成）。**上一轮只有 1/2 命中，这次 2/2 —— 不是偶发。**

**根因（已核实代码）**：
- `lib/services/compaction/model_summary_provider.dart:176-183` 的 `_messageText` 把对话转写成
  `${m.role.toUpperCase()}: ${m.content}`（即 `USER: …` / `ASSISTANT: …`）。
- 摘要模型总结某段时，把转录里的 `ASSISTANT:` 标签**原样复制进了它自己写的摘要**。
- 代码对 `summarize` / `summarizeText` 返回的文本**没有“剥离前导 USER/ASSISTANT/SYSTEM 角色标签”的兜底**
  （已有：空摘要兜底 `R1-5`、失败兜底——唯独缺“正文误带角色标签”的清洗）。
- 该 L1 摘要落盘为 `ClosedSummary`（progressive closure）后会被**复用缓存**再吐出，
  脏标签会跟着持续出现。

**次要（设计商榷）**：
- `lib/services/compaction/compaction_plan.dart` 对高度重复对话按“原始 token 累加 > T”切成多个 L1 批，
  每批独立成摘要 → 多条内容重叠的 L1 摘要（本 case 为 2 条：`[1,133]` 628 tokens / `[134,270]` 548 tokens）。
- L2“摘要之摘要”（`l2GroupCount`，超预算才收拢）本次未触发，因为 L1 投影已放得下，
  于是两条重叠摘要都被放进上下文。
- 商榷点：对“重复对话”是否应让 L2 更早收拢以压低上下文里的重复？属调优/取舍，需评估。

**⚠️ 动手前必读**：本条的「期望方向 2」以及一切 L2 触发条件的调整，**必须先对照本文件顶部「🔒 钉死的原始要求」的自检五问** —— **不得靠"至少 N 条才合并"这类条数门槛让它更早触发**（那正是用户禁止的偏离方式，且代码里已经存在一处）。

**期望方向（供后续 change 参考）**：
1. 给摘要结果加“剥离前导角色标签”的清洗（USER/ASSISTANT/SYSTEM 前缀），入口在
   `model_summary_provider.dart` 的返回值处或投影构建处。
2. 评估：高度重复对话下，是否让 L2 收拢更早触发，减少上下文冗余。

**来源文件**：`lib/services/compaction/model_summary_provider.dart`、
`lib/services/compaction/compaction_plan.dart`、`live_real_context_output.txt`。

---

### [ ] 删除 SearXNG + `web_search` 改为「仅付费有效 + 失败返回空结果」

**性质**：清理死代码 + 优雅降级（非新功能）。两件是一体：删除的前提是“搜索失效变优雅”。

**背景 / 证据（已核实代码）**：
- `sidecar/src/search_provider.cpp:137-142`：`ensure_search_infra` **跳过 SearXNG 健康检查**，直接 `set_available(false)`（注释“assume unavailable”）；`searxng_search.cpp:36-40` 的 `is_configured()` 据此返回 false。故 `get_configured_providers()` **从不返回 SearXNG**。
- 结论：当前运行时搜索**本来就是“付费-only”**（还剩 zhipu / kimi，均需 API key）。删除 SearXNG ≈ **清死代码，功能零损失**。
- 现状 `dispatch_web_search` 在无可用 provider 时返回 `error_json("No search providers configured")`（`search_provider.cpp:265-266`）——即“搜不了会报错”。

**期望方向**：
1. 删除 SearXNG provider（`sidecar/src/searxng_search.cpp/.h`、`scripts/setup_searxng.sh|.bat`、`scripts/start_searxng.bat`、`tools/searxng/`）——纯清理，不依赖、不误伤。
2. `web_search` 改为“仅付费生效 + 软失败”：无可用 provider / 全部失败 / 结果为空 → 返回 `{ok:true, results:[]}`（空结果），而非报错，让 AI 看到“0 条”自然知道搜不了。入口在 `dispatch_web_search`。

**说明**：本项与“免费搜索 / 浏览器”无关；且删除 SearXNG 后**并不会自动出现免费搜索**——免费搜索的另议（见下条）。

**来源文件**：`sidecar/src/search_provider.cpp`、`sidecar/src/searxng_search.cpp/.h`、`scripts/setup_searxng.*`、`scripts/start_searxng.bat`。

---

### [x] 添加「独立浏览器工具」，已定路线甲（外置窗口）——**已立项并实现**：`openspec/changes/add-browser-tool`

**⚠️ round-10 更正（12.26(15)）**：本条原先写「仍未实现，需先 spike」「尚处 PARTIAL / 需 spike」「下一步：先跑聚焦验证…再开 change 立项」——**均已过期**。该 change 已立项并落地（`openspec/changes/add-browser-tool/`，含 `.openspec.yaml` + proposal/design/specs/tasks；`scripts/browser_worker.py`、`sidecar/src/browser.cpp` 均已实现）。**剩余未完成项只在 tasks.md 里**：**12.34**（产物收尾审查）。**12.1 已按用户裁定结案（口径是「未复现」，不是「已修复」）**；12.30 / 12.33 已完成。（**⚠️ 更正历史：round-12 时此处写「12.1 与 12.30」，round-13 时写「12.1 与 12.30」均已过期 —— 以 tasks.md 的 checklist 为准，不要以本行为准。**）

**决策**：选 **外置浏览器窗口**（路线甲），非内嵌。内嵌（WebView2）是**另一条独立替代路线**，暂缓，不是“增强”。

**性质**：新功能。**定位精确**：一个**独立于 `web_search` 的 sidecar 工具**，agent 可自由用于“搜索 / 导航 / 填表 / 看 JS 页 / 别的事”；**不是**把浏览器塞进 `web_search` 当免费搜索替代（此前 C1/C3 反证的是那个错误表述，不构成否决）。**已被 `add-browser-tool` 实现**（见上）。

**机制（方向已定）**：
- **接入层**：**sidecar 工具**，镜像 `web_fetch` 的 Python 子进程模式；**不是 harness 级 MCP**——DeepSeek 端点不支持 MCP/server 工具（`Docs/DeepSeekAPIDoc.md:100,697`）。
- **驱动**：**Playwright 驱动系统自带 Edge/Chromium**（`channel="msedge"`/`chrome`，**免 ~150MB Chromium 下载**），**headed（用户可见）**，一次任务一个持久会话。
- **输出**：每步把页面落成 **DOM / 内文文本快照**，喂 DeepSeek。~~**OCR 仅在纯图页面才兜底**~~ —— **⚠️ round-11 更正（12.29）：OCR 已由 `design.md:24` 明确列为 Non-Goal（本 change 不做 OCR）**，此处原写法与之一致性不足，以 design 为准。
- 绝不与 `web_search` 混；`web_search` 独立保留（付费-only + 失败空结果，见上一条待办）。

**已确认的关键性质（这几轮问答定下）**：
**⚠️ round-11 更正（12.29）：下面第 82-90 行原写「外部未验证、待 spike 回填」「必须先验证」等 —— 这些实测**已经做完**（`openspec/changes/add-browser-tool/tasks.md` 的 1.1–1.6 均已回填结论：多轮循环支持深多步、headed 资源与最小化/遮挡行为已实测、channel 已定、单 tab/弹窗/下载已实测、遮挡与权限抑制已实测）。以下段落保留为**立项前的原始计划**，其「未验证」措辞**已过期**，不要再按它判断现状。**
- **AI 走程序级控制**（Playwright/CDP 命令直达浏览器进程，非屏幕级模拟）。~~窗口最小化/被遮挡是否影响 AI 操作……外部未验证行为，需实测（对应 change 的 task 1.2）后回填~~ —— **已实测回填（task 1.2/1.5）**。
- **默认藏在后台、不频繁弹窗**：不每步调 `bringToFront`；**跟进点击新开的标签页**（design 甲——原「单 tab 复用」的写法已作废，多标签页为预期）；**自动处理** `alert`/`confirm` 对话框；避免触发下载 / 权限弹窗——“不弹窗/无下载/无权限/新页可被跟随是否真能保持”为**外部未验证**，需实测（task 1.4）回填。把窗口提到前台仅通过显式可见请求，该机制**不在本 change 范围**（另行立项）。
- **健壮性（公共验收标准，须写进实现）**：看门狗**检测关窗→可检测失败→AI 重开会话**；**每步重读实时快照**（不信任上次）；URL / 内容**分叉检测**；**用户接管信号**（检测到用户手动导航/切页 → 知会 AI 重读）。

**风险 / 门槛（立项前的判断，现状见上）**：
- ~~**多轮 tool_use 循环是否已就位**——**硬前提**，必须先验证~~ —— **已验证（task 1.1：支持深多步）**。
- **headed 资源成本**：约 300-500MB/tab、2-5s 冷启动、孤儿进程风险（归档 `openspec/changes/archive/2026-07-27-upgrade-web-fetch-crawl4ai/design.md`）；**已实测回填（task 1.2）**。
- ~~**需 spike（外部事实，未验证）**：最小化/隐藏窗口是否会被某些动作重新拉回前台~~ —— **已实测回填（task 1.2）**。

**下一步**：**已不需要「先立项」**（change 已立项并落地）。仍未完成的只有 `openspec/changes/add-browser-tool/tasks.md` 里的 **12.34**（产物收尾审查）。

**来源文件**：`sidecar/src/web_fetch.cpp`、`scripts/fetch_worker.py`、`Docs/DeepSeekAPIDoc.md`、`openspec/changes/archive/2026-07-27-upgrade-web-fetch-crawl4ai/design.md`。

---

### [ ] add-browser-tool live 真实桌面验证未通过（白屏卡死 + browser_available probe 超时）

**性质**：真实缺陷（浏览器工具在真实桌面的端到端可靠性未确认）＋ 待查。**5.3 暂不视为验收通过**。

**背景 / 证据（2026-09-06~07 实跑多次）**：
- 一次运行 `flutter test --tags live --run-skipped integration_test/browser_live_test.dart -d windows` 返回 `exit 0 / All tests passed`（脚本断言层未抛错：模型真实调用 browser_navigate/browser_snapshot，sidecar.log `browser-record` 符合 raise_count=0/tabs=1/snapshot_len=29）。**但用户目击真窗口白屏、卡死**，据此不能判“通过”。
- 另一次运行 **skipped**：`browser stack unavailable: {ok:true, available:false, error: browser probe did not run}`（`browser_available()` 的一次性 subprocess probe 30s 超时）。
- 手动跑 probe（`python scripts/browser_worker.py` 发 `{"cmd":"available"}`）仅 ~1.5s 即返回 `available:true, channel=msedge`——worker 探测本身不慢，是 C++ `subprocess::run` 包装在真实桌面负载下超时。
- 曾怀疑残留 `msedgewebview2.exe` 泄漏，**经查父进程为 SearchHost.exe / WidgetBoard.exe（Windows 系统组件），非本工具 worker**，排除该假设（此前误杀一批系统组件子进程，已向用户说明）。

**根因（未定，待排查）**：
- 白屏卡死：可能 headed Edge worker 在真实桌面的资源/渲染不稳、或 `lib/main.dart` 的 `_initSearchAndTools` 异步化（await browserAvailable）影响启动、或 integration_test `-d windows` 真窗口渲染。
- probe 超时：`browser_available()` 一次性 subprocess probe（spawn python → headless 探测 Edge）在系统负载下不稳（30s 超时）。
- headed Edge worker 进程清理：此前发现该环境下 `in_job=false`（宿主已在 job 内 → AssignProcessToJobObject 失败 → TerminateJobObject 无效）→ 孤儿 Edge 进程风险。

**期望方向（后续 change/修复）**：
1. 系统排查白屏卡死 + probe 超时确切根因（app 启动日志 / sidecar.log / probe 确切报错栈）。
2. 修 `browser_available()` probe 稳定性（降一次性 headless Edge 冷启动成本 / 更长超时 / 重试 / 缓存结果；**不可**复用持久 worker——探针在 app init 阶段跑（`_initSearchAndTools`@main.dart:518），此时没有任何浏览器会话，持久 worker 是每次 browser 任务才懒启动，无可复用对象）；确保 headed Edge worker 退出时可靠清理，规避孤儿进程累积。
3. live 真实桌面可用性需重新验证；在此之前 5.3 不视为通过。

**来源**：`integration_test/browser_live_test.dart`、`sidecar/src/browser.cpp`（browser_available subprocess probe、run_browser_op 进程管理）、`lib/main.dart`（_initSearchAndTools 异步化）。
