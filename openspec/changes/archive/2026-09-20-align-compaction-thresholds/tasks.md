## 1. 前置：规范基线、配置/阈值派生、测试可注入性

- [x] 1.1 **修规范基线的小节头**（否则归档会失败）：基线 spec 顶层是 `## ADDED Requirements`，而 openspec 只在 `## Requirements` 下收集 requirement ⇒ 本变更的 MODIFIED 块落不上去。**实际比拍板时以为的多一处**：本变更要改的**两份**基线都不合规 —— `openspec/specs/context-compaction/spec.md` 与 `openspec/specs/model-gateway/spec.md`，两份都要改。**另外还缺 `## Purpose` 小节**（第一版任务没提到这一条，实测归档在头改对之后第二次失败，报 `Spec must have a Purpose section`，所以两份都要补上 `## Purpose`）。**2026-09-13 拍板「只改本变更要改的那一份」** —— 实际执行即为上面这两份（都是本变更的 delta 目标）；其余 **36 份**同样不合规的基线 spec **另开一单**，不在本变更做（同坑随时复发，写进 `TODO.md` 即可）。**判据**：改之前先跑一次归档演练并**贴出失败原文**（`context-compaction MODIFIED failed for header ... not found` / `Spec must have a Purpose section` / `Aborted. No files were changed.`），改之后同一条命令正常返回计数（实测 `+ 1 added`、`~ 5 modified`）。
  - **2026-09-20 执行记录**：红态原文 = `context-compaction MODIFIED failed for header "### Requirement: Context budget trigger" - not found` / `Aborted. No files were changed.`；补 `## Requirements` 后第二次失败 = `model-gateway MODIFIED failed for header "### Requirement: Adaptive thinking parameter in request body" - not found`；再补后第三次失败 = `Spec must have a Purpose section`。三处都补齐后同一命令输出 `Totals: + 1, ~ 5, - 0, → 0` / `Specs updated successfully.`（演练用的是一个临时副本，跑完已删，归档目录无残留）。
- [x] 1.2 `lib/models/agent_type_config.dart`：新增 `compactionThresholdPercent`（配置键 `compaction_threshold_percent`，缺省 `25` —— **该缺省值 2026-09-13 已拍板确认**；缺失 / 不是整数 / 小于等于 0 / 大于 100 一律回落到缺省，并打印一次提示）。**判据**：`test/unit/agent_registry_test.dart` 新增三例（有值 / 没有这一项 / 值非法）并实际跑通；改之前该断言因字段不存在而红。
  - **2026-09-20 执行记录**：红态 = `Error: The getter 'compactionThresholdPercent' isn't defined for the type 'AgentTypeConfig'`；实现后该文件 13 条用例全绿（实测 `explicit percent -> 10`、`absent percent -> 25`、6 个非法值全部 `-> 25`）。
- [x] 1.3 `lib/services/compaction/compaction_plan.dart`：新增 `CompactionEngine.thresholdTokens(int maxContextTokens, int? percent)` 作为**唯一**的阈值计算点（模型容量 × 百分比 ÷ 100），删除 `_batchThreshold`，把三处调用点（分批边界、最新原文保留量、合成 L2 摘要的阈值）全部改成调用它。**判据**：`test/unit/compaction_engine_test.dart` 新增两条用例 —— 「同一份历史，模型容量翻倍 ⇒ 阈值翻倍且 L1 批数不增加」与「缺省 25 / 显式 50 各自算出的阈值」，贴实际输出。
  - **2026-09-20 执行记录**：红态 = `Error: Member not found: 'CompactionEngine.thresholdTokens'`；实现后两条用例绿（实测 `threshold 20000*25%=5000 40000*25%=10000`、`batchCount capacity20000=11 capacity40000=5 firstBatchRaw small=5285 large=10570`）。`lib/main.dart` 三处（`buildTree` × 2、`resolveFoldSeamInputs`）都补了 `thresholdPercent`，`_resolveSummaries` 的 `T = budget ~/ 2` 改为调用 `thresholdTokens`，并把该方法的参数名由 `budget` 改成 `maxContextTokens`（原来一个词指两样东西）。
- [x] 1.4 **让窗口测试能预置"库里已有的摘要节点"**（2026-09-20 实测后新增；**必须排在 2.3 之前，否则 6.2 的红态根本跑不出来**）：给 `ChatScreen` 增加一个可选注入项 `summaryNodeRepo`（与已有的 `sessionRepo` / `msgRepo` / `sidecar` / `summaryProvider` 同一个写法），`ChatScreenState` 里改成 `widget.summaryNodeRepo ?? SummaryNodeRepository()`。
  - **为什么必须加这一步（实测，不是推断）**：6.2 / 6.3 / 6.4 都要"库里已经有上一轮压出来的节点"这个前提，原计划用真数据库的临时库。**实测跑不通**：`testWidgets` 跑在 FakeAsync 区里，真实异步 I/O 的完成回调递不进来 ⇒ 测试直接挂死。证据：临时探针（`testWidgets` 里只做 `DatabaseService.openAt(临时目录)`）跑 120 秒无任何输出、不结束；**同样这几行放在普通 `test()` 里 5 条用例全绿**（`test/integration/summary_node_repository_test.dart`）。全仓只有本变更这一个文件试过"窗口测试 + 真数据库"这种组合。
  - **判据相应改法**：三条改用**注入的内存版仓储**来预置与回读节点（管道 → 仓储的调用形状由它验），**真数据库那一层由既有的 `summary_node_repository_test.dart`（普通 `test()`，真 SQLite）继续负责**。两层合起来覆盖完整，不重不漏。
  - **判据**：`flutter analyze` 无新增问题；6.2 用注入仓储跑通（不再挂死）。
  - **2026-09-20 执行记录**：注入项已加；`test/integration/compaction_projection_test.dart` 里新增内存版 `_FakeSummaryNodeRepository`（真数据库那一版已删）。`flutter analyze` 仍是 171 条、与改前逐条一致（唯一落在改动文件上的是 `lib/main.dart` 里既有的 `nsCount` 未使用告警，不是本次改动引入）。6.2 不再挂死。
  - **执行中补做的一处**（同一任务范围内，判据要求的"能预置"必须先能读到）：`_loadClosedSegments` 头上写着 `if (!DatabaseService.isOpen) return const [];` —— 注入的内存仓储因此**根本轮不到**，测试里 `closed` 恒为空。新增 `ChatScreenState._summaryStoreOpen`（注入的仓储恒可用；生产仓储要求数据库已打开），`_loadClosedSegments` 与 `_resolveSummaries` 的 `dbOpen` 都改用它。改之前实测 `[OBS] 6.2 ... L2覆盖= hasContinue=false projectedChars=99`，投影里只剩一条把整段对话（含当前用户消息）压掉的摘要；改之后两条预置 L1 摘要正常出现在投影里、当前用户消息也还在（`projectedChars=1082`）。

## 2. 判据：只认 token（不看条数、不等装满、不绕圈）

- [x] 2.1 `CompactionEngine.l2GroupCount`：从最旧开始累加、**首次超过阈值时返回这一组有几条**；**累加始终没超过阈值时返回 0**（改之前返回的是全部条数）。**判据**：新增用例「两条各 10、阈值 50 ⇒ 返回 0」（改之前返回 2）与「两条各 30、阈值 50 ⇒ 返回 2」；**同时点名更新既有断言** `test/unit/compaction_engine_test.dart` 里 `l2GroupCount([50], 200)` 的期望由 `1` 改为 `0`（理由随语义一起改）—— 这条不点名，跑到全量测试时必红而无人认领。
  - **2026-09-20 执行记录**：红态实测 `l2GroupCount([10,10], 50)=2 l2GroupCount([30,30], 50)=2 l2GroupCount([50], 200)=1` ⇒ 改后 `=0 / =2 / =0`，用例绿。
- [x] 2.2 `lib/main.dart` 收拢循环：删除 `consecutiveL1 >= 2 && groupCount >= 2` 这个**条数门槛**，判据改为"组数大于 0"；返回 0（没到阈值）时保持原有的"最旧的不进本次请求"路径（磁盘数据不动）。**判据**：`test/integration/compaction_projection_test.dart` 新增「只有一条 L1 摘要、而它自己就超过阈值 ⇒ `summarizeText` 会被尝试调用」的用例，贴 `summarizeTextCalls` 实际值；改之前该值为 0。
  - **2026-09-20 执行记录**：红态实测 `summarizeCalls=4 summarizeTextCalls=0` ⇒ 改后 `summarizeTextCalls=1`，用例绿。
- [x] 2.3 **先捕获红态（这一步必须排在 2.4 之前，顺序不可颠倒）**：把 6.1 / 6.2 的两个场景先写成用例，在**还没改触发口径的代码**上跑一遍，贴出"改之前"的实际输出（6.1 应为"原文原样全发、一条摘要都没有"；6.2 应为"库里没有任何层级 2 的摘要、发给模型的内容里也没有层级 2 的标记"）。
  - **⚠️ 2026-09-20 执行时修正了任务顺序**：这条原先排在 6.0，但 6.0 在文件里位于 2.4 之后，而 2.4 正是要把这处触发口径改掉 —— 按原顺序走到 6.0 时红态**已经拿不到了**（"改完代码就再也拿不到红态"是本项目 red-green 规则的硬要求，design 的 D7 也明写"tasks 的序号必须体现这个顺序"）。现移到 2.4 之前，编号 2.3；组 6 不再有 6.0，其余 6.1–6.7 编号不变。
  - **2026-09-20 红态实测（两个场景都已落地成用例并跑过）**：
    - 6.1：`[OBS] 6.1 阈值 1000 / 容量 4000 / 原文 raw=1512 lastFolded=null hasSummaryMarker=false hasContinue=true` —— 原文 1512 已超过阈值 1000，却一条摘要都没压，原样全发；断言 `Expected: not null / Actual: <null>`。
    - 6.2：`[OBS] 6.2 预置节点: lvl1[1,4]=600 | lvl1[5,8]=600` / `[OBS] 6.2 summarizeTextCalls=0 L2节点数=0 L2覆盖= hasL2Marker=false hasContinue=true` —— 库里两条 L1 合计 1200 已超过阈值 1000，却既没合成、也没进投影；断言 `Expected: non-empty / Actual: []`。
- [x] 2.4 **把触发口径改回统一规则**（用户 2026-08-29 定下、2026-09-13 重申）：**两层都是"从最旧累加、超过阈值就把这一批整体压一次成上一级"，不等窗口装满。** 落点（**逐处点名**）：①`CompactionEngine._foldTail` 里那条 `totalProxy <= budget` 早退；②`CompactionEngine.resolveFoldSeamInputs` 里按容量早退那条（`estimateConversation(t.tail) <= t.budget`）；③`buildTree` 的 `shouldCompact`（由①的产物推出，随①一起生效）；④`lib/main.dart` 后台压缩 `_runBackgroundFold` 的早退判据（它读的就是 `plan.shouldCompact`，只需把日志里 "conversation within budget" 这种按容量说话的措辞改对）。**模型容量只保留兜底作用**：压完、合并完仍超容量时，最旧的那部分不进本次请求（磁盘数据不删）。**判据**：见 6.1 与 6.2。
  - **⚠️ 原第⑤处（`_resolveSummaries` 收拢循环的退出条件）2026-09-20 执行时移到了 2.6**：那处一改，"合成被拒"那条路就会一步都不删、原样再来一遍 ⇒ **死循环**；也就是说它和 2.6 的"被拒即不再重试"是同一处改动，拆开做必然先写出一个不终止的循环。故⑤与 2.6 合并执行。
  - **2026-09-20 执行记录**：新增共用的 `_foldEndFor(messages, budget, T)`（`_foldTail` 与 `resolveFoldSeamInputs` 都走它，两处不可能再算出不同的切分点）；`_nominalFoldEnd` 按 2.5 改写；后台压缩那条日志改成按阈值说话。**6.1 实测转绿**：`[OBS] 6.1 阈值 1000 / 容量 4000 / 原文 raw=1512 lastFolded=11 hasSummaryMarker=true hasContinue=true`（改之前是 `lastFolded=null hasSummaryMarker=false`）。**6.2 仍红、符合预期**（要等第 3 组解冻 L1 与 2.6 的循环条件）：`summarizeTextCalls=0 L2节点数=0 hasL2Marker=false`。
- [x] 2.5 **改对"压哪一段"的方向**：现有 `CompactionEngine._nominalFoldEnd` 是"从最新往回保留、直到累计不超过阈值，其余全部压缩"。**它错在方向**：当总量刚刚超过阈值时，它压掉的是最旧那一小截（不到阈值），留下的原文反而可以接近一个阈值 —— 方向正好相反；被压的那一小截小到压不动（小于可压缩下限），合成出来的摘要不会更小，于是被整体丢掉。
  **改成**：**从最旧开始累加，每累计超过阈值就切出一批，一直切到剩下不足一个阈值为止；切出来的这些批就是要压的（每批各压成一条 L1 摘要），剩下那一截原样发送。**
  **⚠️ 2026-09-20 执行时发现的措辞坑（本任务与 design 的 D8 原先对不上，已一并改掉）**：本条原先写成"**首次**超过阈值的那一段就是这一批" —— 字面照做的话，远端永远只会有一批（`k` 恒等于 1），而 `k > 1` 正是"由 AI 挑选批次分界"那套机制唯一的触发条件 ⇒ **那套机制会被悄悄变成永远不执行的死代码**，4 条既有测试也随之失去意义。而 design 的 D8 又写着远端会"切成若干批，每批累计到阈值大小"。两处矛盾，正确读法是**反复按同一个规则切**（即上面改后的写法）：这样"总量刚过阈值 ⇒ 压掉约一个阈值、剩下一截不足一个阈值"成立，多批也存在，挑分界的机制不会被废掉。
  **判据**：构造"总量略大于阈值"的历史，断言被压批次的 raw ≈ 阈值（而不是"总量 − 阈值"），且留下的原文 raw < 阈值；另加一条"总量为阈值的 3.5 倍 ⇒ 切出 3 批、留下的原文 raw < 阈值"（证明多批还在、机制没被废）。改之前这两组断言都反着成立。
  - **2026-09-20 执行记录**：代码在改 2.4 的同一处编辑里落下（`_nominalFoldEnd` 重写为"从最旧按阈值切、返回最后一截的起点"）。红态用**变异测试**取：把该函数临时改回旧写法（从最新往回保留），跑用例 ⇒ `[OBS] 略超阈值: foldedRaw=300 verbatimRaw=1000 (阈值 1000，总量 1300)` 与 `[OBS] 3.5 倍阈值: 批数=3 foldedRaw=2500 verbatimRaw=1000`，两条断言分别红在 `Expected: a value greater than or equal to <1000> / Actual: <300>` 和 `<3000> / Actual: <2500>`；还原后同两条绿：`foldedRaw=1100 verbatimRaw=200` 与 `批数=3 foldedRaw=3300 verbatimRaw=200`。
  - **诚实标注**：那条"3.5 倍 ⇒ 3 批"的批数在新旧两种写法下**都是 3**，所以它**不区分新旧**，只用来钉住"多批还在"（防的是把规则误读成"只切一次"）；真正区分新旧的是 `foldedRaw` 与 `verbatimRaw` 两条。
- [x] 2.6 **给"合成被拒"写清推进规则**（否则收拢循环不终止；**2.4 的第⑤处也在这里一起做**）：现有排空循环带 `total > maxContextTokens` 条件，在"因超阈值进入、但投影并没超容量"时会一步都不删、原样再来一遍，同一组被反复送进 `summarizeText`。规则定死：**被拒的那一组记下来（本次已试），继续条件只看尚未被拒的条目；未超容量时被拒即不再重试。** **判据**：用假摘要器（`l2Tokens` 恒大于被替换的 L1 之和）+ 阈值已触发而投影未超容量的场景，断言 `summarizeTextCalls` 有上界且这趟压缩能正常结束；改之前会反复调用/不收敛。
  - **2026-09-20 执行记录**：收拢循环整段重写 —— 退出条件从"还超容量"扩成"**还超容量 或者 还有没被拒的、累计超过阈值的可压组**"；候选组按"连续的、尚未被提交过的 L1 段"找；被拒的条目记进一个**按对象身份**的集合（记录类型是结构相等的，必须用 `Set.identity()`），同一次压缩内不再提交。
  - **判据用例**：`test/integration/compaction_projection_test.dart` 的「合成被拒后不再重试：这一趟正常结束，那一组只试一次」。绿态实测 `[OBS] 合成被拒: summarizeCalls=1 summarizeTextCalls=1 hasMarker=true hasL2=false hasContinue=true`。红态用**变异测试**取：把"被拒即记录 + 未超容量即不再试"这两句注释掉 ⇒ 该用例**跑满 180 秒无任何输出、不结束**（同一组被反复送进 `summarizeText`），正是"不收敛"本身。
  - **诚实标注**：这条失败态是"挂死"而不是"断言变红"。用例里写了 `timeout: Timeout(Duration(seconds: 20))`，但 `testWidgets` 的用例体跑在 FakeAsync 区里、`await` 一个已完成 future 只让出微任务队列、不推进假时钟，**这个超时因此不会触发**；观察到的是运行器层面一直不返回（本次由外层 180 秒超时掐断）。也就是说"该判据能失败"成立，但失败的表现是**不终止**。
- [x] 2.7 **删掉写死的绝对下限**（原排在 1.4，2026-09-20 执行时后移到 2.5 之后 —— 它的判据要构造接缝，而接缝的几何形状由 2.5 的切分方向决定，先写就是白写）：`CompactionEngine._minBatchRaw` 里的 `1025`（改为纯由阈值派生，即"阈值的一半"）。**判据（行为证据，不是扫源码）**：构造一条会把远端切成两批、每批约"阈值的一半"raw 的接缝 —— 改之前因那个 `1025` 下限被拒（回退到算术骨架），改之后按尺寸守卫被接受；两个状态的实际输出都贴出来。
  - **2026-09-20 执行记录**：红态实测（用例 `阈值一半落在 600～1025 之间的接缝仍被接受`，容量 4800 ⇒ 阈值 1200 ⇒ 新的下限 600、旧的下限 1025；接缝给在第 9 条 ⇒ 首批 900 raw，正落在两者之间）：`[OBS] 小窗口接缝: 阈值=1200 批数=2 首批条数=13 首批raw=1300` ⇒ 断言 `Expected: <9> / Actual: <13>`，即**被旧下限拒、回退到算术骨架**。删掉 `1025` 后同一条：`首批条数=9 首批raw=900`，用例绿。

## 3. L1 摘要不再一落盘就冻结：让累加能跨轮次攒到阈值

- [x] 3.1 `CompactionSegment` 增加"可参与合成 L2 摘要"的标记（可由 `summary && level == 1` 推出），`ClosedSummary` 带上"可否参与合成"的来源信息；`buildTree` 计算"还没处理的那一截从哪里开始"的语义**保持不变**（所有已载入节点都算已覆盖，原文绝不重新压一遍）。**判据**：单元断言「可参与合成的 L1 摘要仍然算在已覆盖范围内、不会因此多出新的 L1 批」。
- [x] 3.2 `lib/main.dart` 的 `_loadClosedSegments`：区分 `level >= 2`（冻结，永远不再作为合成输入）与 `level == 1`（可参与合成 L2 摘要）；两类都仍然排除各自覆盖的原文范围。**判据**：集成测试预置一条 `level = 2` + 一条 `level = 1` 的节点，断言 L2 不会被再次合成、而 L1 仍然参与成组。
- [x] 3.3 `lib/main.dart` 的 `_resolveSummaries`：把"冻结的那批 + 可调整的那批"两个列表改成**一张按时间从旧到新排好的表**，收拢循环在它上面按"连续的可调整 L1"成组，遇到冻结条目就打断成组；`finalSegments` / `finalSummaries` 按这张表的顺序产出。**判据**：集成测试断言发给模型的条目，覆盖范围**严格从旧到新递增**（用预置节点构造交错场景）。

### 组 3 执行记录（2026-09-20）

- **3.1**：`CompactionSegment.rollable`（= `summary && level == 1`）与 `ClosedSummary.rollable`（= `level == 1`）两个派生标记加好，注释写明"可参与合成"与"已覆盖"是两件事。判据：`test/unit/compaction_engine_test.dart` 新增两组用例 —— 「可参与合成的层级 1 摘要仍然算已覆盖：不会因此多压一遍原文」（断言没有任何**新压**的批次包含 seq ≤ 40 的原文）与「层级 2 的已落盘摘要不可参与合成」。实测绿：`[OBS] 可参与合成: 已载入条目=1 其中可参与合成=1 新压批次=3`。
  - **诚实标注**：这条断言我第一版写错了两次 —— 先误以为"尾部没超过阈值、不该产生新批次"（实际尾部 174 raw 已超过阈值 50，本来就会压），后又把**已落盘那条摘要本身**当成了"包含已覆盖原文的新批次"。两处都是我的期望写错，不是代码缺陷；已改成"新压的批次里不含已覆盖原文"。
- **3.2**：`_loadClosedSegments` 补上文档说明（两类都载入、都仍然排除各自覆盖的原文范围；区别只在能不能作为合成的输入）。判据：交错场景用例里预置了一条层级 2，实测 `summarizeTextCalls=1`、那条层级 2 原样保留 ⇒ 层级 2 没有被再次合成。
- **3.3**：`_resolveSummaries` 里"冻结的那批 + 可调整的那批"两个列表改成**一张按时间从旧到新排好的表**（`table`），成组只看"连续的、可参与合成的条目"，遇到层级 2 就打断；`finalSegments` / `finalSummaries` 按这张表的顺序产出。丢弃规则写明：层级 1 或本轮新产出的条目可丢（只影响这次请求，磁盘不删），**上一轮落盘的层级 2 永不丢**（那才是真正的"冻结"）。
  - 判据：交错场景用例 —— 预置"层级 1(1..4)、层级 1(5..8)、层级 2(9..12)"，实测 `[OBS] ... summarizeCalls=0 summarizeTextCalls=1 层级2覆盖=[9,12],[1,8] 投影里的覆盖起点（按出现顺序）=[1, 5, 9]`，顺序严格递增的断言通过。
  - **诚实标注**：顺序这条断言**不区分新旧代码**（旧写法给出的也是这个顺序）—— 它的作用正是 3.3 说的"防止改成单一有序表之后顺序错乱"，属于回归护栏，不是本次行为差异的证明。
- **3.4**：判据即下面那条跨轮次用例（与 6.4 同一条）。实测 `[OBS] 3.4/6.4 跨轮次: summarizeCalls=1 summarizeTextCalls=1 层级2覆盖=[1,19] hasL2Marker=true hasContinue=true` ⇒ **本轮只调了一次压原文**（等于本轮新批次数），与库里已有几条无关；合成只调一次。
  - **红态（变异测试）**：把 `ClosedSummary.rollable` 临时改成恒假（等于旧的"载入即冻结"）⇒ 同一条用例红：`[OBS] ... summarizeCalls=1 summarizeTextCalls=0 层级2覆盖= hasL2Marker=false`，断言 `Expected: <1> / Actual: <0>`；还原后恢复绿。
- [x] 3.4 回归"已经压过的段落不再重新压一遍"：`reuse != null` 的条目**不得**触发新的 `summarize`（只允许在合成 L2 摘要时走一次 `summarizeText`）。**判据**：集成测试断言预置 L1 参与的那一轮里，`summarizeCalls` 只等于本轮**新**批次数、不受既有节点数量影响，贴实际调用数。

## 4. 摘要长度不再由本设计写死（含规范与 C++ 同步）

- [x] 4.1 核对本变更新增的 `specs/model-gateway/spec.md` 与实现一致：摘要 profile 设 `thinking.type = "disabled"`、**不**带压缩设计指定的 `max_tokens` 常量。**判据**：该 delta 在归档后能替换掉基线里"摘要 profile 的 `max_tokens` SHALL be 512-1024"那句（配合 1.1 的 dry-run 一起验）。
- [x] 4.2 `sidecar/src/model_gateway.cpp`：摘要请求不再写死 `max_tokens = 1024`（改用模型/接口自己的默认值；`thinking.type = "disabled"` 必须保留）。**判据**：`sidecar/test` 新增用例断言摘要模式的请求体里不再出现写死的 `1024`、且 `thinking.type == "disabled"`，贴实际请求内容；改之前该断言红。**注意**：新断言只能写"不再等于设计常量（或该键不存在）"，**不得**写"等于 8000/8192"—— 本地文档只在 chat/completions 字段表里写了 8K 默认，`/v1/messages` 端点没有明文。
- [x] 4.3 **更新既有的 C++ 用例**：`sidecar/test/http_client_test.cpp` 的 `TEST_CASE("HTTP: summary profile caps max_tokens")` 里有 `REQUIRE(body["max_tokens"] == 1024)`，4.2 之后必红。**判据**：把它改成"该键不存在或不等于设计常量"，**保留** `REQUIRE(body["thinking"]["type"] == "disabled")` 与 `REQUIRE(!body.contains("output_config"))` 两条断言不要动；改之前先贴出它变红的实际输出（它是本次改动直接造成的红，不是"放宽验收"，但必须由本任务认领）。

  - **诚实标注**：4.2 新增的用例与 4.3 改完之后的既有用例，断言内容**实质重复**（都验"不再带那个写死的 1024"）。这是按任务要求做的（4.2 要新增、4.3 要更新既有），不是有意留冗余；若后续要收敛，删掉其中一条即可，两条都不是唯一守卫。

### 组 4 执行记录（2026-09-20）

- **4.1**：用一次归档演练做了真验证（不是看文档猜）—— 把本变更复制成临时副本归档，`model-gateway` 报 `~ 1 modified`，随后读归档后的基线规范：那条要求的正文已换成"……`thinking.type` SHALL be `"disabled"` and the request SHALL NOT carry a `max_tokens` constant chosen by the context-compaction design……"，旧的 `512-1024` 那句没了，旧场景 `Summary profile caps max_tokens` 也被换成 `Summary profile output length is model-governed`。演练产物（临时副本与归档目录）已删除，两份基线规范还原后已重新打上头修复。
- **4.2**：先加新用例 `TEST_CASE("HTTP: summary profile leaves max_tokens to the model")`，在**还没改源码**时跑 ⇒ 红：`REQUIRE_FALSE( still_sends_the_design_constant )` / `with expansion: !true`（请求体里还在发 `max_tokens == 1024`）。改源码（摘要分支不再写 `max_tokens`，`thinking.type="disabled"` 保留）并重建后 ⇒ 绿：`All tests passed (4 assertions in 1 test case)`。
- **4.3**：改源码后跑既有用例，红态原文：`REQUIRE( body["max_tokens"] == 1024 )` / `with expansion: null == 1024 (0x400)`（该键已不存在）。按任务把它改成"该键不存在或不等于设计常量"，另外两条断言原样保留；重建后 `[thinking]` 全绿：`All tests passed (29 assertions in 7 test cases)`。

## 5. 把"每会话压缩上限"整套删干净（用户 2026-09-13：「没有任何留着的理由」）

> 说明：这道闸门是**我自己加的**，不是用户要求（出处：`openspec/changes/archive/2026-09-01-add-auto-context-compaction` 里我写的 D10「便宜层优先 + 压卷预算」）。**归档目录不动**（历史留档），只清当前代码、测试、活文档。

- [x] 5.1 **删掉产品侧那道闸门**（`lib/main.dart`），逐项点名、不许只删一半：
  - `static const int kMaxFoldsPerSession = 30;` 与 `static const int kMaxFoldTokensPerSession = 500000;`
  - 两个公开 getter：`static int get maxFoldsPerSession` / `static int get maxFoldTokensPerSession`
  - 纯判据：`static bool isFoldBudgetExceeded({required int foldCount, required int foldTokens})`
  - 查库判据：`Future<bool> _foldBudgetExceeded(String sessionId)` 及其上方整段文档注释（那段注释本身就在描述这套烂设计的动机与"诚实界"，一并删）
  - **两处早退**：①`_callModel` 里 `if (await _foldBudgetExceeded(sessionId)) { … apiMessages = _buildApiMessages(messages); }` 那一支连同它的 D10 注释；删掉后注意**把原来的 `else` 分支拉平成顺序执行**（不要留下 `if (true)` 或空 else）。②后台压缩 `_runBackgroundFold` 开头 `if (await _foldBudgetExceeded(sessionId)) return;` 及其 D10 注释。
  - 顺带清掉 `_loadClosedSegments` 上方注释里提到 "fold budget" 的那半句（它引用的是这道闸门）。
  - **删之前先把"为什么删"写进代码注释**（别删得无声无息，下一个会话会把它重新发明出来）：它量的不是"花了多少钱"，而是"这个会话已经产出过多少条摘要"（被粗摘要覆盖的小摘要行从不删除，只增不减），越过一次就**永久关闭压缩**，触发后的后果比它要防的成本失控更糟；阈值本身还是条数 + 与窗口无关的写死绝对数。
  - **判据**：改之前先跑一次全量 `flutter test` 并**贴出 `cost_discipline_test.dart` 5.1 变红的实际输出**（这一步见 5.2 的顺序要求）；改之后 `flutter analyze` 无新增 problem。
- [x] 5.2 **删掉把它钉成预期行为的那个用例**（`test/integration/cost_discipline_test.dart` 的 `5.1 fold budget cap: count cap, token cap, at-cap-not-exceeded`）。**这一步是修改验收标准，已获用户明确授权（2026-09-13：「对于这种狗屎设计，没有任何留着的理由」）** —— 把这句话连同日期写进提交说明/change 记录，免得以后被当成"为了过测试偷偷删断言"。删完把该文件里已经失效的抬头注释（"Phase 4 cost discipline (D10): 5.1 … + 5.2 …"）改成只剩它实际还测的东西。
  - **同文件里另一个用例 `5.2 break-even` 不属于这道闸门**（它测的是"压出来的摘要确实更小、并且压缩成本能在若干次请求内赚回来"，是"压缩到底有没有省"的独立性质，删了它等于少一个守卫），**已拍板保留**，但要去掉它身上与已删设计相关的命名/注释。
- [x] 5.3 **清理活文档与注释里对这道闸门的描述**：
  - `Docs/context-compression-reference.md`：核一遍 Phase 4 / 成本纪律 / 测试层清单那几处，凡声称存在"每会话压缩次数或 token 上限"的表述一律改掉（如果它只写了"破平衡点回归"，那部分随 5.2 保留的用例一起留着）。
  - `integration_test/compact_quality_live_test.dart` 与 `test/integration/background_fold_test.dart` 里出现的 "fold budget" **指的是另一个东西**（每次请求可用的上下文额度，自调的 `maxContextTokens`），**不要删**；但要在这些注释里把两者说清（例如写成"上下文额度"），避免下一个会话把两个"budget"混成一个。
  - **判据**：`Select-String -Pattern 'kMaxFolds|kMaxFoldTokens|isFoldBudgetExceeded|_foldBudgetExceeded|maxFoldsPerSession|maxFoldTokensPerSession'` 在 `lib/`、`test/`、`integration_test/`、`Docs/`、`CLAUDE.md`、`TODO.md` 下**零命中**（`openspec/changes/archive/` 排除，历史不动）；并把命中数贴出来（改之前应为非零）。
- [x] 5.4 **如实收口"成本不能失控"这个意图**：这道闸门删掉之后，**该意图没有替代者**（摘要调用成本随对话长度线性增长，每次压出一批新摘要就调一次模型）。**2026-09-13 已拍板：先不补替代护栏** —— 那就**不许假装它还在**，在 design / proposal 里如实写明"暂时无人承担"。**若将来真有人要再加护栏**，必须同时满足三条（已写进 D9 与 `Docs/rejected-approaches.md` 第 22 条）：①量的单位就是被保护的资源（token / 花费本身），②阈值由模型容量派生，③触发后**降级**（少压一点、压得更粗）而不是**停摆**，且**能恢复**。

## 6. 测试：真的含 L2 摘要（用户点名要的用例）

### 组 5 执行记录（2026-09-20）

- **5.1**：产品侧整套删干净，逐项核对 —— 两个常量、两个公开 getter、纯判据 `isFoldBudgetExceeded`、查库判据 `_foldBudgetExceeded`、`_callModel` 里的早退（原 `else` 分支已**拉平成顺序执行**，没有留下 `if (true)` 或空 `else`）、`_runBackgroundFold` 开头的早退、以及 `_loadClosedSegments` 注释里引这道闸门的那半句。删除理由按要求写成了代码注释（放在原址 `_summaryStoreOpen` 上方），逐条写明"量错了对象""触发后是永久停摆而不是降级""两个阈值都是用户明令禁止的类型""它比阈值先咬合"。
- **5.2**：删掉 `test/integration/cost_discipline_test.dart` 的 `5.1 fold budget cap` 用例（删它之前先跑了一次，贴出的红是 5.1 直接造成的：`Error: Member not found: 'maxFoldsPerSession'` 等 10 处），并在文件抬头写明**这是改动验收标准、已获用户明确授权**（附用户原话与日期）以及为什么"不是偷偷放宽断言"（被钉住的那个行为本身已被有意移除）。同文件的 `5.2 break-even` **保留并实测仍绿**：`[OBS] 5.2 break-even: totalFoldedRaw=696 totalSummaryTokens=552 savingsPerRequest=144 foldInput(696) < 8*144=1152 repaid=true`。
- **5.3**：判据 grep 的**改前命中数** = `lib/main.dart` 12 处 + `test/integration/cost_discipline_test.dart` 10 处 + `Docs/rejected-approaches.md` 1 处；**改后 = 0**（扫描范围 `lib/`、`test/`、`integration_test/`、`Docs/`、`CLAUDE.md`、`TODO.md`，排除 `openspec/changes/archive/`）。另外把两处**同名但含义不同**的 "fold budget" 措辞改成"模型上下文额度（`max_context_tokens`）"（`test/integration/background_fold_test.dart`、`integration_test/compact_quality_live_test.dart` 共 3 处），并在 `Docs/context-compression-reference.md` 里把三处"每会话折卷预算"的表述标为**已作废**（保留原设计记录的原文 + 删除线，另加一句删除理由与指针；不是把历史改写成"从来没写过"）。
  - **顺带发现并一并修正**：同一份文档里还有两处写着摘要 profile 用 `max_tokens` 512-1024 —— 那是 4.2 已作废的说法，留着就与实现矛盾；已改成"输出长度由模型默认值决定，2026-09-20 起不再写死"。
- **5.4**：`design.md` 的 D9 与 `proposal.md` 已写明"**先不补替代护栏**、'成本不能失控'这个意图**暂时无人承担**"，并列出将来要加护栏必须同时满足的三条；`Docs/rejected-approaches.md` 第 22 条同步更新（去掉已不存在的标识符，保留那两个数字，并记下"已从代码中整套删除"与授权来源）。
- **`flutter analyze`**：删完后回到 **171 条**、与本次改动前逐条一致（唯一落在改动文件上的是既有的 `nsCount` 未使用告警，不是本次引入）。

- [x] 6.1 **原文攒够阈值就压，不等窗口装满**（用例已在 2.3 里写好并捕获过红态，本任务负责确认它转绿）：构造"要发出去的内容**远没到模型容量**、但已经超过阈值"的场景 ⇒ 断言真的产出 L1 摘要、且它进入发给模型的上下文（`sidecar.lastMessagesJson` 含 `kSummaryMarker`、原文不再原样全发）。**判据**：2.3 捕获的红态 + 改后的绿态，两个输出都贴。
- [x] 6.2 **没超容量也要合成 L2**（用例已在 2.3 里写好并捕获过红态，本任务负责确认它转绿）：构造"当前原文并没有超过容量、上下文还有空余，但库里已有的两条 L1 摘要实测 token 相加超过阈值"的场景 ⇒ 断言**仍然**合成出 `level = 2` 的摘要，且它进入发给模型的上下文（含 `kLevel2SummaryMarker`）。**判据**：2.3 捕获的红态 + 改后的绿态。
- [x] 6.3 **L2 摘要真的进入投影**（注入的内存版摘要节点仓储 + 假摘要器，见 1.4）：断言 ①`sidecar.lastMessagesJson` 含 `kLevel2SummaryMarker`；②存的节点里存在 `level = 2` 的行，且它覆盖的范围等于被合成掉的那些 L1 摘要范围的并集；③**被合成掉的那些 L1 摘要的文本在投影里一条都不出现**（而不是只判"没有重复条目"——后者在旧代码里也成立，证明不了本变更）。**断言之前先把现场 `print` 出来**。**注意**：这条**不要**挂"改之前必红"——现行代码在超容量时已经能产出 L2 并进入投影（既有 `⑪.3 coarsen` 用例就是绿的），能红的只有 6.1 / 6.2 / 2.1 三处。
- [x] 6.4 **跨轮次累加**：先用注入的内存版仓储预置两条 `level = 1` 的节点（模拟上一轮压缩的产物），再让本轮真的发生一次压缩，断言这两条旧 L1 与本轮的新 L1 被合成进**同一条** L2 摘要（覆盖范围包含三者）。**判据**：改之前红（旧 L1 被冻结、不参与成组），贴两个状态的实际输出。
- [x] 6.5 **顺序不变式**：发给模型的条目，覆盖范围严格从旧到新递增（防止 3.3 改成单一有序表之后顺序错乱）。
- [x] 6.6 更新既有测试（**2026-09-13 用户已明确授权更新这几处期望值** —— 它们是规格变更的直接后果；但**只改与实现细节绑定的期望，不得放宽或删除任何断言**）：①`test/unit/compaction_engine_test.dart` 里 `l2GroupCount([50], 200)` 由 1 改 0（见 2.1，已完成）；②按"容量除以 2"手算的期望改为按配置百分比派生（**已定位到的三处红：`test/unit/compaction_engine_test.dart` 的 4.3 接缝三条用例 —— `valid seam repositions the L1 interior boundary` 期望 3 实际 7、`size guard rejects a seam carving a tiny batch` 期望 8 实际 4、`anchor guard rejects a seam that wholesale-reorders the batches` 期望 8 实际 4**）；③`test/integration/compaction_projection_test.dart` 既有的三个用例按新阈值重新取尺寸参数，保持各自原本要证明的性质 —— **注意既有 `⑪.3 coarsen` 只用 `summarizeTextCalls >= 1` 证明"压出更粗的摘要"，并不校验"更粗"，要补上"合成出来的 L2 摘要实测小于被它替换掉的那几条 L1 摘要之和"这条断言**；④那条"没超预算 ⇒ 全部原文发送"的用例按新规则重新界定为"**没超过阈值** ⇒ 全部原文发送"（触发口径变了，用例的边界跟着变，不是删掉它）。
- [x] 6.7 **真实模型跑到 L2 摘要（放在最后跑，2026-09-13 已拍板）**：等代码改完、6.1–6.6 与 7.1–7.4 全绿之后再跑这一条，避免跑两遍。`integration_test/compact_quality_live_test.dart` 增加或调整用例，使真实模型运行下真的产出 `level = 2` 的摘要，并断言它出现在真正发给模型的上下文里；**同时补上 `captureLiveShot` 截图**（`Docs/TESTING.md` §5.9：真实模型测试必须留图并用 `read_image` 目视验收）—— 这条用例缺截图正是 `TODO.md` 上的公开欠账，本任务一并结清。**判据**：实际跑 `flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows`，贴输出 + `read_image` 读图结论。

- [x] 6.8 **修掉全量测试暴露出来的浏览器"新标签页竞态"**（2026-09-20 执行时发现，属本变更之外的既有缺陷，但由本变更暴露、且挡住 7.2 的全量验证，故在此收口）：
  - **现象**：全量 `flutter test` 稳定失败一条 —— `test/integration/browser_worker_test.dart` 的 `browser_worker: click a target=_blank link FOLLOWS the new tab (design 甲)`，断言 `Expected: true / Actual: <false>`，现场 `[OBS] click result link -> {"ok":true,"url":"http://127.0.0.1:49199/",...snapshot:"Results\nresult link"...}` ⇒ 点完之后仍停在被点的原页面，没有跟随新标签页。**单独跑这个文件是绿的**（实测）。
  - **归属（实测，不是推断）**：把本变更的所有代码改动 `git stash` 掉、在改动前的代码上跑全量 ⇒ **232 条全过**；恢复改动后再跑 ⇒ 同一条稳定失败。所以"改动前就红"不成立，**这个失败必须由本变更认领**。
  - **根因**：`scripts/browser_worker.py` 的 click 分支里，`context.expect_page(timeout=NEW_PAGE_WAIT_SEC*1000)` 确实开了 1 秒等待窗，但 `pinfo.value` 是在 `with` 块**内部**、`page.click(...)` 刚返回时就**只读一次**。新标签页的 Page 事件到达得比 click 返回晚（文件里自己写着实测 0.16–0.36 秒；全量并发跑更晚）⇒ 这一读拿到的是 `None` ⇒ 不跟随新标签页。
  - **修法**：把"读取 `pinfo.value`"挪到 `with` 块**之后**（事件真正到达、或超时抛出的时刻），超时那一支保持"没有新页 ⇒ 原地导航"的原语义。
  - **判据**：红态 = 上面那条全量失败（已复现两次，附现场输出）；绿态 = 改完之后全量 `flutter test` 全过。**不得**用"单独跑这个文件是绿的"当验收。

### 组 6 执行记录（2026-09-20）

- **6.7（真实模型跑到层级 2 + 补截图）**：**已跑通**，用的是本机配置里的真实 provider（`deepseek-v4-pro`，Anthropic 兼容端点）。命令：`flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows` ⇒ **`00:50 +1: All tests passed!`**。关键实测输出：
  - `[OBS] summary node level=2 nodeType=summary covered=[1,807] token_cost=463` —— 真实模型下**真的产出了层级 2**，覆盖 5 条层级 1 的全部范围。
  - `[OBS] ④ sent messages contain L2 marker=true contain L1 marker=false sentChars=15744` —— 它**真的进了发给模型的内容**，而被它合成掉的那 5 条层级 1 摘要**不再单独出现**。
  - `[OBS] ④ L2 phase: L1 count=5 L1 measured token sum=2580` / `budget=5160 T=1290` —— 触发靠的就是"这些摘要的实测 token 加起来超过阈值"，与"窗口装没装满"无关。
  - `[SHOT] captured test/live_visual/compact_quality_live.png (55508 bytes)`。
  - **目视验收（`read_image` 读 `test/live_visual/compact_quality_live.png`）**：截图已切到「真实上下文」视图，画面里 `[0] user` 那一条的标题就是 **`## 更早上下文(压缩xN,层级2,非用户发言)`**，其下才是 `(第402轮) …` 起头的原样近段原文，再往后是逐条 user/assistant。也就是说"层级 2 摘要排在请求最前面、后面的原文没有被重复的层级 1 摘要挤占"这件事是**看得见**的，不只是日志里的一句话。
  - **为让它跑通做的三处改动**（都写进了代码注释）：①把原来显示 `T=${kBudget ~/ 2}` 的过时算式改为调用 `thresholdTokens`；②fixture 由 `fillerTurns: 200` 加长到 `480`（实测 200 时原文总量只有 5471、阈值 911、首批仅 912 raw —— 原来那条"首批必须 > 1024"的守卫是靠**已经删掉的** `max_tokens 1024` 撑着的，现在改成"首批 > 2000 raw"，让批次远大于任何可能的摘要）；③新增第二阶段：把模型容量调到"摘要总量的两倍"，使阈值必然被超过，再发一轮，然后断言库里出现 `level = 2` 且它出现在真正发给模型的内容里。
  - **诚实标注（成本）**：这条用例一共真跑了 **3 次**（每次都花钱）：第 1 次红在 fixture 太短（守卫拦下，`firstSegRaw=912` 不大于 2000）；第 2 次红在我自己写错的最后一条断言（拿库里带换行的原文去和 JSON 转义后的字符串做子串匹配）；第 3 次全绿。前两次的红都记在上面，不省略。
  - **这条用例缺截图的历史欠账**：本次一并结清（原来 `TODO.md` 上挂着"真实模型用例没有截图"，现在有了，且截的是最能说明问题的那一屏）。

- **6.1 / 6.2**：两条用例已在 2.3 里写好并捕获过红态，本次确认**都已转绿**：6.1 `[OBS] 6.1 阈值 1000 / 容量 4000 / 原文 raw=1512 lastFolded=11 hasSummaryMarker=true hasContinue=true`；6.2 `[OBS] 6.2 summarizeTextCalls=1 L2节点数=1 L2覆盖=[1,8] hasL2Marker=true hasContinue=true projectedChars=1004`。
- **6.3**：`sidecar.lastMessagesJson` 含层级 2 标记 ✓；存的节点里存在 `level = 2` 的行且覆盖范围 = 被合成掉那些 L1 范围的并集（6.2 实测 `L2覆盖=[1,8]`，正好是 `[1,4] ∪ [5,8]`）✓；被合成掉的 L1 文本不再作为独立条目出现在投影里（2.2 那条用例的投影里只剩合成结果，实测 `projectedChars=545`）✓。按任务要求，这条**没有**挂"改之前必红"。
- **6.4**：跨轮次用例实测 `[OBS] 3.4/6.4 跨轮次: summarizeCalls=1 summarizeTextCalls=1 层级2覆盖=[1,19] hasL2Marker=true hasContinue=true` ⇒ 上一轮那两条 L1（`[1,4]`、`[5,8]`）与本轮新压的那一批被合成进**同一条**覆盖 `[1,19]` 的更粗摘要 ✓。红态用变异测试取（见 3.4 记录）。
- **6.5**：交错场景用例实测投影里的覆盖起点（按出现顺序）= `[1, 5, 9]`，严格递增的断言通过 ✓。诚实标注：这条是新旧代码都成立的回归护栏，不是行为差异证明。
- **6.6**：**实测比工件里写的多一处红**（工件原先只列了三处接缝用例），实际有 **5 处**既有用例因阈值口径变化而失效，全部重新取参数后转绿，**没有放宽或删除任何断言**：
  1. `test/unit/compaction_engine_test.dart` 的 `l2GroupCount([50], 200)` 期望 1 → 0（2.1 已完成）。
  2. 同一文件的 4.3 接缝三条：`valid seam repositions…` 与 `size guard rejects…` 把容量 `12000 → 24000`（保持注释里写明的"阈值 6000、远端 23 条、k=3"那套几何成立）；`anchor guard rejects…` 的几何在新切分下**已经不成立**（远端 28 条、每批 4 条、锚点窗口 2，与"每段 ≥ 阈值一半"互相覆盖，锚点守卫没有单独咬合的余地），改成一组能让它**单独**咬合的参数：容量 24160 ⇒ 阈值 6040、每批 9 条、远端 18 条、锚点窗口 4，接缝给在第 14 条 ⇒ 位移 5 > 4 被锚点守卫拒，而两段 10570 / 3020 raw 都 ≥ 尺寸下限 3020 ⇒ 尺寸守卫本来会放行。实测 `[OBS] anchor-guard 批数=2 firstLen=9 firstRaw=6795`；用例里**把"尺寸守卫本来会放行"这个前提也写成了断言**（实测 `尺寸下限=3020 接缝第一段=10570 接缝第二段=3020`），不是我在注释里声称。
  3. **追加一处（工件原先漏了）**：`test/unit/seam_selector_test.dart` 的 `4.3 end-to-end: memo-backed chooser preserves the LLM seam through buildTree` 同样按"容量除以 2"手算，容量 `12000 → 24000` 后恢复原文所述的几何：实测 `[OBS] seamInputs.k=3 farLen=24 memoized=[9, 15]`。
  4. `test/integration/compaction_projection_test.dart` 的 `⑪.3 coarsen` 按新阈值重新取尺寸：容量 200 ⇒ 阈值 50 ⇒ 每批 2 条（58 raw）；假摘要器 `l1Tokens` 由 `75`（≥ 58 ⇒ 被判无效、拆半重压）改成 `30`（< 58 ⇒ 有效），`l2Tokens: 20` 保持。实测 `[OBS] coarsen: summarizeCalls=12 summarizeTextCalls=6 maxRollUpInputs=2 l1Tokens=30 l2Tokens=20 hasL2=true`。
  5. **按任务要求补上的"更粗"断言**：假摘要器新增"每次合成吃进去几条 L1"的记录，断言 `l2Tokens < l1Tokens × maxRollUpInputs`（20 < 60）⇒ 合成出来的那条**实测小于**被它替换掉的那几条 L1 之和。原先只断言"调用过合成"，证明不了"更粗"，这个缺口就此补上。
  - ④那条"没超过阈值 ⇒ 全部原文发送"的用例**保留并重新界定**：它的场景本来就是"内容很少、低于阈值"，新规则下依旧成立，实测 `[OBS] under-budget projection: summaryMarkerPresent=false projectedChars=373 lastFolded=null` ✓。
- **6.8**：红态 = 全量跑失败两次的那条浏览器用例（现场输出见上）；当时记的绿态 = 改完 `scripts/browser_worker.py` 之后**连续两次全量 `flutter test` 都是 `+248 All tests passed!`**。当时的修改点：把读取 `pinfo.value` 从 `with` 块**内部**挪到块**之后**。
  - **诚实标注**：这条缺陷不在本变更范围内（浏览器工具与上下文压缩无关），是**我的改动把它逼出来的**（改动前后各跑一次全量做对照：改动前 232 条全过、改动后稳定失败）。
  - **⚠️ 2026-09-20 收尾审查推翻了这条"已修复"（见 6.9）**：那处改动是**空操作**，"连续两次全绿"是**假绿**。

- [x] 6.9 **纠正 6.8：撤掉那处无效改动，并如实改口径**（2026-09-20 收尾审查发现；按规则已打勾的 6.8 **不得**改回未打勾，只能追加新任务纠正）：
  - **推翻的依据（我自己复核过，不是照抄审查 agent 的话）**：读本机安装的 Playwright 同步 API 源码 `site-packages\playwright\_impl\_sync_base.py`，`EventInfo.value` 的实现是 `while not self._future.done(): self._sync_base._dispatcher_fiber.switch()` —— 它是**阻塞等待**事件到达，**不会**提前返回 `None`。所以"在 `with` 块内部读会读到 None"这个前提**不成立**，把同一句读取挪到块外**语义等价**，等于没改。
  - **那真正的失败是什么**：`NEW_PAGE_WAIT_SEC = 1.0` 这个等待窗口在机器繁忙时不够 —— 超时后代码按"原地导航"继续，于是新标签页没被跟随。这与实测的"单独跑这个文件必绿、全量跑大约一半概率红"完全吻合（负载越高，弹窗注册越慢）。
  - **"连续两次全绿"为什么不能算数**：这条失败本来就是**间歇性**的。收尾审查连跑 6 次全量，结果 **3 次 `+248` 绿、3 次 `+247 -1` 红**，失败点每次都是同一条 `target=_blank` 用例。两次绿完全可能是碰巧。
  - **本任务的做法**：①把 `scripts/browser_worker.py` **还原到已提交版本**（`git checkout -- scripts/browser_worker.py`，已确认该文件相对已提交版本已无任何改动、`if click_err is None and pinfo.value is not None` 回到块内）；②`TODO.md` 里那条"联网 live 用例不稳定"的待办**补上更正后的根因**（是 1 秒等待窗口太短，不是读取位置）；③把全量测试的口径改成**如实口径**（见 7.2 的更正）。
  - **判据**：`git status --short scripts/browser_worker.py` 为空；仓库内 `Select-String 'READ pinfo.value AFTER THE BLOCK'` 零命中；且 7.2 的记录里不再声称"全量稳定全绿"。
  - **没有做的（如实说）**：**这条间歇性失败没有被修**。真要修得动 `scripts/browser_worker.py` 的等待策略（例如超时后回看 `context.pages` 是否多出一个 popup，或把等待窗口调大），那是浏览器工具那一条线的事，不属于本变更范围；已记进 `TODO.md` 待办。

## 7. 验证、记账与审查

### 7.6 诚实性审查报告（2026-09-20，Workflow 1 轮 / 12 个 agent）

**审查轮数**：**1 轮**（按任务规定"必须开且只开 1 轮"）。输入 = 【产物清单】+【声称清单】+【失败方案台账】；11 个子 agent 分头真跑命令/真做变异，1 个汇总。

**它确认成立的（都有实测输出或变异佐证）**：阈值只有一个计算点且容量翻倍阈值翻倍（沙箱变异 `~/2` ⇒ 用例红）、配置缺省 25 与非法值回落（变异去掉 1..100 校验 ⇒ 红）、条数门槛确实删净（变异改回 `count>=2` ⇒ 那条用例红，`summarizeTextCalls` 0）、`l2GroupCount` 只在超过阈值时成组（变异改回返回条数 ⇒ 红）、写死 1025 已删（变异恢复 ⇒ 首批退回 13 条）、触发口径与切分方向（两条用例的绿态数字与记录逐字一致；变异回旧写法 ⇒ 红）、"被拒即不再重试"在代码里（变异删掉记录 ⇒ 不终止）、每会话上限零命中且 break-even 用例保留（变异把摘要撑肥 ⇒ 红）、C++ 摘要请求与两条用例、`flutter analyze` 零新增（与改动前逐条比对，差异只有三条问题因新增代码下移的行号）、真实模型的层级 2 产物与截图（PNG 时间戳紧接该轮 9 次真实请求）。

**本轮发现的【产物缺陷】3 条，全部已修**：

1. **真实模型用例的第二轮是个假动作** —— `pumpUntilReplyOrTurnDone` 在"存下最终回复"时立刻返回，而那一刻 `_isStreaming` 仍为 true，紧接的点击被 `_sendMessage` 开头的 `if (_isStreaming) return;` 静默吞掉 ⇒ 第二轮**从来没发出去**，上一版 ④ 的断言其实是靠第一轮数据满足的。
   **修法与实测**：按事实重写 ④ —— 不再发第二轮（阈值的规则本来就是"攒够就压"，这 5 条层级 1 的实测合计本来就超过阈值，同一趟里就合成掉了），并把"够得着"写成**真断言**。绿态：`[OBS] ④ 层级 2：层级 1 条数=5 层级 1 实测 token 合计=2214 层级 2 条数=1 阈值=2165`、`④ sent messages contain L2 marker=true contain L1 marker=false`、`00:57 +1: All tests passed!`。
   **red-green**：红态即证据本身（用诊断连续 300 秒打印"快照长度不变、回复不变"，证明第二轮确实没发出去）；修完后的断言 `层级1实测合计 > 阈值` 是**新加的可失败判据**（够不着就会红）。
2. **真实模型用例从不清理旧截图** —— 它在 `_resolveLiveConfig()` 为 null 时会在 `try` 之前就返回，那条路径既不删旧图也不写新图，于是上一轮遗留的同名 PNG 会被当成本次结果。**修法**：`setUp` 里调 `clearLiveVisualDir()`。
   **诚实标注**：**未能证明此判据可失败** —— 我没有去构造"旧图存在 + 本轮跳过"那个状态来验证它会红，这是卫生性修复。
3. **那条"被拒不再重试"用例的失败表现是挂死而不是变红** —— 用例里声明的 20 秒超时在 `testWidgets` 的假时钟下不触发，整条流水线会一直挂着。
   **修法与实测（有 red-green）**：假摘要器加一条守卫，一趟里被调用超过 50 次就主动抛错。**变异实测**：把"被拒即记录 + 未超容量即不再试"两句注释掉 ⇒ 那条用例 **1 秒内**失败并给出原因 `Bad state: summarizeText 在一趟压缩里被调用了 51 次 —— "被拒即不再重试"这条推进规则没生效，这一趟不会结束`；**修之前**同样变异是**挂满 210 秒零输出**。还原后哈希与备份一致、用例恢复绿。

**本轮【记账项】5 条，已一次性修完**：①`TODO.md` 里那条 grep 判据**自指**（判据正文写在 `TODO.md` 里，把 `TODO.md` 纳入搜索范围就永远不可能零命中）⇒ 已把 `TODO.md` 从搜索范围里去掉并写明原因；②同处的"改之前 12 + 10 + 1 处"复现口径不一 ⇒ 已改成"非零，两个文件各有十余处"，不再当精确账目；③台账第 21 条还把 `consecutiveL1 >= 2 && groupCount >= 2` 记成"现存偏离项" ⇒ 已更新为"已于 2026-09-20 删除"；④单元用例名说"批数不变多"而实测是 11 → 5（断言本身是 `<=`，正确）⇒ 不改断言，仅记在此；⑤审查期间有并发写入者把工作区改成过变异态 ⇒ 见下面"审查窗口的可信度"。

**审查窗口的可信度（必须如实说）**：这一轮我让 11 个子 agent **并发**跑命令、其中若干被允许"改文件做变异、跑完还原"，结果它们**互相**把对方的变异态当成了正式态（上下文里出现过 `bool get rollable => false; // MUTANT-M1`、`// MUTATION-B: rejection not recorded`、`level: 1, // MUTANT-M2` 等残留），有一段时间**仓库里的测试结果按时间先后都不可信**。我在收尾时自己做了完整性复核：全仓 grep 变异标记 = 0 命中、`lib/main.dart` 与 `compaction_plan.dart` 哈希与交付态一致、本变更的 6 个测试文件合跑 `+60 All tests passed`、C++ `[thinking]` 全绿、归档演练仍 `+ 1, ~ 5`。**教训已写进 `~/.dsh/AGENTS.md`**：子 agent 禁止运行会开窗口/连外部服务/改工作区的命令，变异与"跑整套"由主循环自己做、一次只做一件。

**最终任务状态**：36 条全部完成（34 条原有 + 6.9 纠正任务 + 本审查任务）；`openspec validate align-compaction-thresholds --strict` 通过。

**仍未消除的缺口（不粉饰）**：①"成本不能失控"无人承担（用户 2026-09-13 拍板先不补护栏）；②全量 `flutter test` 约一半概率因**既有的**浏览器"等待新标签页"竞态变红 —— 本变更只暴露了它、**没有修好它**（6.8 那处改动经复核是空操作，已撤），已记进 `TODO.md`；③`ctest` 会因**既有的**联网搜索 live 用例不稳定而变红，已记进 `TODO.md`。
- [x] 7.2 先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`（或走 `run.bat` 第 [3/5] 步），再跑**全量** `flutter test`，贴 `All tests passed` 与用例数。
- [x] 7.3 C++：`cmake --build sidecar/build/windows --config Debug` + `ctest --test-dir sidecar/build/windows --config Debug`，贴输出。
- [x] 7.4 冒烟：`test/smoke/run_all.sh`（Windows 上 `run.bat`），贴输出（**不得**用它代替 6.7 的真实模型测试）。

### 组 7 执行记录（7.1–7.4，2026-09-20）

- **7.1 `flutter analyze`**：**零新增**。做法不是"看总数没变"，而是逐条比对 —— 把改动暂存掉跑一次、恢复后再跑一次，两份清单做差异比较：改动前 171 条、改动后 171 条，差异只有**同三条问题因新增代码而下移的行号**（`unnecessary_brace_in_string_interps` 73→80、`prefer_function_declarations_over_variables` 295→329、`lib/main.dart` 的 `nsCount` 2488→2555）。这三条都在我没有改动的行上。（顺带印证了本项目"记录里禁止写死行号"那条规矩：行号确实会腐烂。）
- **7.2 全量 `flutter test`**：先 `scripts\sync_sidecar_dll.ps1`（输出 `SYNC-OK: sidecar.dll already current`），再跑全量 —— 当时**连续两次**都是 `+248 All tests passed!`。改动前的对照是 `+232 All tests passed!`（多出来的 16 条是本次新增的用例）。
  - **⚠️ 2026-09-20 收尾审查更正**：这两次全绿**不能**当作"全量稳定通过"。收尾审查连跑 6 次，结果 **3 次 `+248` 绿、3 次 `+247 -1` 红**，红的时候永远是同一条 `test/integration/browser_worker_test.dart` 的 `browser_worker: click a target=_blank link FOLLOWS the new tab (design 甲)`（`Expected: true / Actual: <false>`）。
  - **这条失败不是本变更引入的**（改动前后各跑一次做对照：改动前 232 条全过、改动后开始出现），但它**也不是本变更修好的** —— 6.8 那次改动经复核是空操作（见 6.9），真正的成因是 `scripts/browser_worker.py` 里 `NEW_PAGE_WAIT_SEC = 1.0` 这个等待窗口在机器繁忙时不够。**本变更对它的贡献仅限于：暴露了它**。
  - **本变更自己的口径（如实）**：属于本变更的用例全绿 —— `test/unit/compaction_engine_test.dart`、`test/unit/agent_registry_test.dart`、`test/unit/seam_selector_test.dart`、`test/integration/compaction_projection_test.dart`、`test/integration/cost_discipline_test.dart`、`test/integration/background_fold_test.dart` 六个文件单独跑都是 `All tests passed`；**全量**则约一半概率因上面那条浏览器用例变红，那条已记进 `TODO.md` 待办。
- **7.3 C++**：`cmake --build sidecar/build/windows --config Debug` 成功；`ctest` 报告 `237 条 / 236 过 / 1 败`，失败的是 **`[zhipuai][live][rate-guard]` 这条联网 live 用例**（`[rate-guard live] 0/5 succeeded`，报 `connection error — Could not connect to server` 或 `HTTP 401 — 令牌已过期或验证不正确`）。**归属已用对照实验定死**：①同一个二进制、代码零改动，连跑三次 `[zhipuai]` 组 —— 两次 5/5 通过、一次 0/5 失败；②单独跑那条用例 4 次全部 5/5 通过；③直接对该服务发一次 HTTPS 请求能拿到响应（401，因为没带密钥）⇒ 主机可达；④**把 sidecar 的改动全部暂存掉、在改动前的代码上跑完整 `ctest`，失败的是同一条**（236 条 / 235 过 / 1 败，同样 `[rate-guard live] 0/5`）。⇒ 这是**既有的、外部搜索服务不稳定**造成的失败，与本次改动无关。
  - 本变更该负责的部分单独跑：**排除联网 live 用例后 `All tests passed (3781 assertions in 233 test cases)`**；摘要相关 `[thinking]` 全绿（`All tests passed (29 assertions in 7 test cases)`）。
- **7.4 冒烟**：用 Git Bash 跑 `bash test/smoke/run_all.sh`（`run.bat` 里有 `pause` 且会拉起 GUI，不适合自动跑）。结果 **2 过 3 败**：
  - 过：`Build`（`√ Built build\windows\x64\runner\Debug\alias_agent.exe`）、`Launch & Verify`（窗口出现、截图 179577 字节、日志无 ERROR、数据库 3 张表/1 个会话都在）。
  - 败：`Analyze`（`10 issues found`）、`Checkpoints`（`4 passed, 3 failed`：`checkpoint_4` / `checkpoint_5` 段错误、`checkpoint_6` 在它自己第 90 行抛 `type 'Null' is not a subtype of type 'List<dynamic>'`）、`Visual Regression`（3 张图差异 2.75% / 4.58% / 12.99%，阈值 1%）。
  - **归属用对照实验定死**：把本次改动全部暂存掉、在改动前的代码上跑同样这三步 ⇒ **逐项数字完全一致**（analyze 同样 10 条；视觉回归同样 2.75% / 4.58% / 12.99% 三处；checkpoints 同样 4 过 3 败、同样那两个脚本段错误）。⇒ 这三处失败**改动前就存在**，不是本次引入。
  - 按任务要求：**冒烟没有被用来代替 6.7 的真实模型测试**。

- [x] 7.5 更新 `TODO.md`：①顶部「🔒 钉死的原始要求」里的**现状核对**段落 —— 把已经消除的偏离项逐条改成"已对齐（附可核判据）"，如实保留仍未消除的项，并按 D9 / 第 5 组的删除结果更新（每会话压缩上限不再是"待裁定"，是"已整套删除"），把 D8 更正后的那张数字表补进去；②**新增一条待办**：其余 **36 份**基线 spec 仍不合规（顶层没有 `## Requirements`，也缺 `## Purpose`；本变更只改了 `context-compaction` 与 `model-gateway` 这两份 delta 目标），需要单独一次仓库级改动。
- [x] 7.6 **诚实性审查（收尾，必须开且只开 1 轮 Workflow）**：输入 = 【产物清单】+【声称清单】+【失败方案台账 `Docs/rejected-approaches.md`】；审**产物本身与"声称↔产物"的对应关系**（跑测试、跑变异、读实测产物），**不审措辞**；发现二分类为【产物缺陷】/【记账项】；每条修复必须带 red-green 证据，构造不出失败态的明写「未能证明此判据可失败」。停止时按 `CLAUDE.md` 输出审查报告。
