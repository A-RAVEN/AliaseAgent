## 1. 先把读数留下（独立可验证，不改任何请求内容）

- [x] 1.1 摘要调用的**输入 token** 接住并进观测通道
  **实测（2026-10-03）**：`SummaryResult` 增加输入 token 字段；`ModelSummaryProvider.summarize` 与 `summarizeText` 各自接住 `inTok` 并各打一行。用例读数：`[OBS] captured summary observation lines: [[OBS] summary in=421/out=99 (level-1 fold), [OBS] summary in=421/out=99 (level-2 roll-up)]`，两个方法各自返回的输入 token 都是 421、输出都是 99。**变异已实测**：把二级那行观测去掉 ⇒ 用例红（`Expected: <2> / Actual: <1>`，理由串"两次摘要调用各打一行 —— 只打一行说明有一个方法没接住"）；改回 ⇒ 绿。变异标记已删（`grep MUTATION-` 计数 0）。
：`SummaryResult` 增加输入 token 字段；**落点在 `ModelSummaryProvider` 内部** —— `summarize` 与 `summarizeText` 各自把 `onDone(code, err, stop, inTok, outTok)` 里的 `inTok` 接住，并各自用 `debugPrint` 打一行 `[OBS] summary in=…/out=…`。放这里是因为 `lib/main.dart` 有四个调用点（一级折叠、二级保底路径、2-pass 合一、收拢循环），放 provider 里一处覆盖四个、漏打不了。**不进模型可见内容、不落库、不参与任何合格判断**（决定摘要是否合格的仍然只有输出大小）。
  **判据**：在 `test/unit/model_summary_provider_test.dart`（已有 `ModelSummaryProvider(sidecar: FakeSidecar…)` 的现成写法）里分别驱动两个方法各一次，假 sidecar 给 `inputTokens: 421 / outputTokens: 99`，断言①`SummaryResult` 上的输入 token 等于 421、②**两次调用都**读到含 `in=421` 的观测行。**这条要能失败**：先只接 `summarize` 一个方法（保持 `summarizeText` 今天的样子）跑一次 ⇒ 第二次调用的观测行缺失，用例必红；两个都接上 ⇒ 绿。两个状态的输出都贴。
- [x] 1.2 确认**"输出大小决定合格与否"这条没被碰**
  **实测（2026-10-03）**：`reject-bloated-L2` 与 `split-if-invalid` 两条既有用例都 `All tests passed!`（各 1 条）。
：跑 `test/integration/compaction_projection_test.dart` 里那两条既有用例 —— `⑪.3 reject-bloated-L2: a non-compressing level-2 is rejected, valid L1s kept` 与 `⑪.3 split-if-invalid: an un-compressible batch is split down to atomics and omitted` —— 全绿，贴输出。
- [x] 1.3 把**五处过时的"输出上限 1024"注释**改对
  **实测（2026-10-03）**：五处全部改写成"thinking 关掉、**不发 max_tokens**，输出长度由模型/接口默认值决定"（`model_summary_provider.dart` 三处、`summary_provider.dart` 一处、`seam_selector.dart` 一处）。判据读数：`lib\services\compaction\*.dart` 里 `1024` 零命中、`max_tokens 1024` 与 `max_tokens 512` 组合串零命中（新注释里仍写 "no max_tokens sent"，这是对的）；依据是 `sidecar/src/model_gateway.cpp` 的摘要分支注释 "Summary profile: thinking.type=\"disabled\" and NO max_tokens"，只有另两个分支才设 `max_tokens`（16000 / 4096）。`flutter analyze` = 171 issues，与改动前同数、无新增。
（`lib/services/compaction/model_summary_provider.dart` 三处、`lib/services/compaction/summary_provider.dart` 一处、`lib/services/compaction/seam_selector.dart` 一处）：摘要输出长度**由模型/接口默认值决定，本项目不设上限**（sidecar 摘要分支不带 `max_tokens`）。
  **判据**：`grep` 这五个文件里 `max_tokens` 与 `1024` 的组合串 ⇒ 零命中（贴改前改后两次 grep 输出）；`python -c "import ast; ast.parse(...)"` 无关（Dart 文件），改完跑 `flutter analyze` 不得新增问题（并入 3.1）。

## 2. 参考上下文：选哪两条 + 请求里怎么分开

- [x] 2.1 **选择与去重（纯函数）+ 真的接上线**
  **实测（2026-10-03）**：新增 `lib/services/compaction/summary_reference.dart`（`SummaryReference` + `selectSummaryReferences`）；`SummaryProvider.summarize` 增加参考参数（默认空）；`_resolveSummariesInner` 在段循环前用 `_loadReferenceCandidates`（`_summaryNodeRepo.queryBySession`，库没开或读失败 ⇒ 空）取一次快照，逐段算参考传给 `_resolveOpenLevel1`，折半递归两半用同一份。①纯函数判据 6 条全绿（空历史 ⇒ 空；最近一级 + 层级最高；较细被较粗盖住只留较粗；互不覆盖时两条都带且按覆盖范围从旧到新；5 条候选仍 ≤2 条；覆盖到本批的候选被排除）。②**接线判据**（新增 `compaction_projection_test.dart` 的「参考上下文 · 折叠真的把上一条摘要传给了摘要模型」）：容量 2000 ⇒ 阈值 500，seq 1..10 各 100 raw，库里预置一条覆盖 seq 1..4 的一级摘要 ⇒ 折叠调用 1 次、读数 `每次参考=lvl1[1,4]`。**变异两处都已实测**：把选择规则改成"返回全部更早摘要" ⇒ 纯函数第④条红（5 条候选变 5 条）；把接线去掉（`_resolveOpenLevel1` 一律传空）⇒ 接线判据红（读数 `每次参考=（空）`、`Expected: non-empty / Actual: []`）；都改回 ⇒ 绿（两处各 7 条全过）。变异标记已删（`grep MUTATION-2.1` 计数 0）。
  实现中发现并改正的一处：去重方向最初写反了（留了更细那条），被纯函数用例当场抓住（`Expected: '二级' / Actual: '一级(新)'`），已改成"留更粗那条"。
：新增一个纯函数（放 `lib/services/compaction/` 下的新文件），输入是"已落盘的摘要节点列表（层级、覆盖序号、文本）+ 本批最旧序号"，输出**最多两条**参考：①候选里最近的一条一级、②候选里层级最高的一条；候选的硬条件是 `coveredMaxSeq` **严格小于**本批最旧序号（覆盖范围与本次批次交叠的一律排除）；**按覆盖范围去重**：较细那条被较粗那条完全盖住时只带较粗的那条；每条带上自己覆盖的序号范围；没有候选时返回空。接线上：在 `_resolveSummariesInner` 里这一趟折第一段**之前**取一次快照（`SummaryNodeRepository.queryBySession`，库没开或查不到就为空），把参考逐段传下去；`_resolveOpenLevel1` 需要新增入参（会话 id、库是否打开、已选好的参考），**折半递归时两半用同一份参考**，过滤用的是最外层那一批的最旧序号。`SummaryProvider.summarize` 增加一个参考参数（默认空）。
  **判据**：①新增 `test/unit/` 用例 —— 空历史 ⇒ 参考为空；多条候选 ⇒ 正好是"最近的一条一级"+"层级最高那条"；较细那条被较粗那条盖住 ⇒ 只留较粗那条；5 条候选 ⇒ 仍然只有 2 条；候选里有一条与本次批次交叠 ⇒ 不被选中。②**接线判据（能失败）**：给 `FakeSummaryProvider` 加"记录每次调用收到的参考"的字段，跑一次真实的折叠集成用例，断言它收到的正是上面那两条（顺序与内容都对）。**变异**：把选择规则改成"返回全部更早摘要" ⇒ 5 条候选那条必红；把接线去掉（`_resolveOpenLevel1` 一律传空）⇒ 第②条必红。贴两个状态的输出。
- [x] 2.2 **提示词分块（两条路径都要照抄原文写死）**
  **实测（2026-10-03）**：`kSummarySystemPrompt`（今天那两句，逐字）、`kReferenceContextHeader`、`kSummarizeTextHeader`、`kReferenceOnlyProhibition` 四个常量落在 `model_summary_provider.dart`；有参考时 system = 今天那串 + 禁令句，消息依次是参考（带抬头与"第 1..4 段摘要"范围）、原文（带抬头）、末尾指令。**判据读数**：①有参考 —— 消息条数 3、参考下标 0、原文下标 1、`contents[原文]` 里不含参考正文、system 同时含"请忠实、精简…""请用与对话正文相同的语言…"与禁令句；②没有参考 —— `system` 硬编码等于 `kSummarySystemPrompt`、消息条数 3、不含任何抬头。**变异两处都已实测**：把参考拼进待压缩原文那条消息 ⇒ ①红（`Actual: <0>`，两条消息的下标相同）；把 system 写成无条件加禁令句 ⇒ ②红（`Expected` 是今天那串、`Actual` 多了禁令句）；都改回 ⇒ 绿（4 条全过）。变异标记已删（`grep MUTATION-2.2` 计数 0）。
：
  - **有参考时**：`system` = 今天那串原文（`你是 AliasAgent 的对话摘要器。请忠实、精简地用纯文本总结此前的对话。请用与对话正文相同的语言输出摘要。`）**加上**禁令句（"用户消息里会给你一段【参考上下文】和一段【待压缩原文】；参考只用来解析指代、判断什么已经说过了，严禁把它的内容写进摘要"）；消息依次是：参考一条（抬头 `【参考上下文 · 不要总结】`）、待压缩原文一条（抬头 `【待压缩原文 · 只总结这一段】`、本批消息逐条渲染）、末尾仍是 `kSummarizeInstruction`。
  - **没有参考时**：**system 就是今天那串原文**（不含禁令句），消息形状与今天完全一致（本批逐条成消息、无任何抬头），末尾仍是 `kSummarizeInstruction`。
  **判据**：provider 级用例（同 1.1）——①有参考时：参考与原文分属两条不同消息、各自含抬头串、`lastSystemPrompt` **同时**含今天那两句与禁令句；②没有参考时：`lastSystemPrompt` **硬编码等于**今天那串原文、`lastMessagesJson` 的消息条数与内容与今天一致（用断言写死，不许靠"手抄一份改前的 stdout 来对比"）。**这条要能失败**：把参考拼进待压缩原文那条消息里 ⇒ ①的"分属两条消息"必红；把 system 写成无条件替换 ⇒ ②必红。贴两个状态的输出。
- [x] 2.3 **二级那条链的输入不动**
  **实测（2026-10-03）**：判据写在 `test/unit/summary_reference_test.dart` 末尾那组源码扫描里 —— `summarizeText` 的声明不含参考参数、`_l1SummaryText(sessionId…` 调用点 200 字内不含 `reference`；两条断言全绿。**如实交代一处与条目原文的偏差**：条目原文要求"同一条集成用例里断言那条路径上 provider 收到的参考为空"，但那条保底路径在当前代码里几乎跑不到（`l2SubSpans` 只由收拢循环设置、从不回灌折叠路径），**行为用例构造不出来**，所以换成源码扫描 + 类型约束两条：谁给那条链加参考，`summarizeText` 会直接编译不过，`_l1SummaryText` 的调用点会被扫描抓住（`reason` 串写明了指错对象的情形：调用点不见了也会红）。
：`_l1SummaryText`（二级保底路径）与 `summarizeText` **都不接参考**。
  **判据**：同一条集成用例里断言那条路径上 provider 收到的参考为空（假 provider 记录每次调用收到的参考，按调用顺序检查），贴输出。

## 3. 验证

- [x] 3.1 `flutter analyze`：改动文件不得新增问题（贴输出与总条数）。
  **实测（2026-10-03）**：`171 issues found. (ran in 3.8s)` —— 与本次改动前同数（改动过程中一度到 184，是接口加参数后 8 个测试替身与 3 个文件缺 import 造成的 13 个编译错误，补齐后回到 171）。
- [x] 3.2 全量 `flutter test`
  **实测（2026-10-03）**：`SYNC-OK: sidecar.dll already current (2026/10/1 17:04:45)`；全量 `01:15 +308: All tests passed!`（改动前 297 + 本次新增 11 条：挑选规则 6 条、二级链源码扫描 1 条、接线判据 1 条、提示词分两条 2 条、输入 token 观测 1 条 —— 数字正好对上）。
- [x] 3.3 live 层
  **实测（2026-10-03）**：`flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows` 连跑两次都 `All tests passed!`（`00:52 +1`、`01:06 +1`）。
  **视觉验收（`read_image` 读 `test/live_visual/compact_quality_live.png`）**：画面是「真实上下文」那一屏，顶部一条压缩提示（`正在挑选分段主题` + `你发消息会让压缩先让路` + `下面是上一次实际发出的内容…`），下面 [0] 开始依次是一条二级摘要标记、若干条一级摘要标记、然后才是原文 —— 与本次改动的假设一致（摘要按 2 级→1 级→原文排）。
  **本次摘要调用的读数（新加的观测行，真实运行里的实测）**：一级折叠 5 次 `in=113/out=481`、`in=3/out=1368`、`in=100/out=603`、`in=114/out=538`、`in=121/out=612`；二级合一 1 次 `in=2674/out=764`。库里落盘：5 条一级（覆盖 1..159 / 160..322 / 323..483 / 484..645 / 646..807）+ 1 条二级（覆盖 1..483）。
  **⚠️ 实施中发现并如实记录的一件事（读数不是"总输入 token 数"）**：一级折叠那几次报的 `in` 只有 ~100，而那一段的原文实测 raw 是 2170（日志 `firstSegRaw=2170`）；同一次运行里二级合一报 `in=2674`，与它要合并的几条一级实测合计（约 2600）基本吻合。**最可能的解释是：这是 DeepSeek 兼容端点报的 `input_tokens`，不含命中缓存的那部分**（重复结构的摘要请求大部分命中缓存，所以只剩一百来 token；二级那次是全新的组合，所以接近全量）。本机没有直接证据（sidecar 日志里没有缓存字段、C 侧回调也只透出这一个数）。**结论：这个读数只能当"这次实际计费的新增输入"，不能当"这次发出去多少"**；要拿到真正的总输入，得让 sidecar 把缓存字段（`cache_read_input_tokens` 等）也透出来 —— 那是另一次改动的活，已记进 4.3。
  **人工看一遍摘要质量**：①**有没有复述参考上下文** —— 看不出整段照抄：二级那条与它盖住的那几条一级措辞不同（二级是重写过的合并版）。但要说清一个混淆因素：这次喂给模型的对话本身是**同一个 15 项任务清单循环 100 多轮**造出来的，所以几条一级摘要天然会反复出现同样的任务（这是原文如此，不是摘要抄了参考）。②**指代有没有解开** —— 几条一级摘要都是自足陈述（"将 timeout 常量收敛为 ConfigTimeout 枚举"这类），没有出现读了不知道指什么的人称代词。③**有没有明显漏掉的东西** —— 一级摘要覆盖的 15 类任务都写到了；一处**格式化瑕疵**：其中一条一级摘要正文以 `ASSISTANT` 这个角色标签开头（模型把渲染的角色前缀抄进了摘要），这是既有现象、与参考上下文无关，本次不修。
  **如实说明**：这条 live 用例自带一条"摘要必须保住再执行钥匙"的判据（本次运行里 `key-bearing node found=true`、`reply references preserved key: true`），那是改动前就有的既有判据；本次没有新增任何摘要文本判据，也没有取消它。
：`flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows` ⇒ 贴输出（**⚠️ 由主循环自己跑**，它会拉起真实界面与外部服务）。跑完**必须**用 `read_image` 读它留下的 `test/live_visual/compact_quality_live.png` 做视觉验收并给出画面结论（**无截图／截图无效不算通过**）。然后**人工看一遍摘要质量**：把这次真实压缩产出的摘要原文贴出来，逐条说明①有没有复述参考上下文、②指代有没有解开、③有没有明显漏掉的东西；**看不出问题就写"看不出"**。同时贴出这次摘要调用的 `in=…/out=…` 读数。**如实说明**：这条 live 用例自带一条"摘要必须保住再执行钥匙"的判据，它会红 —— 那是改动前就有的既有判据，本次不新增任何摘要文本判据，也不因本次裁定取消它。
- [x] 3.4 整套冒烟（CLAUDE.md 验证清单第 5 层，缺一层即未验证）
  **实测（2026-10-03）**：经 Git Bash 跑 `bash test/smoke/run_all.sh` = `Total: 2 passed, 3 failed`，逐项 Build PASS / Analyze FAIL / Checkpoints FAIL / Launch & Verify PASS / Visual Regression FAIL —— 与改动前记录的**同一组**（同样这三项红），没有本次引入的新失败。
：经 Git Bash 跑 `bash test/smoke/run_all.sh`（**不要用 `run.bat`**：它只跑一个单测文件，最后一步还会启动应用本体），贴各步结果，并逐项区分**改动前就红**的三项（Analyze、Checkpoints、Visual Regression）与本次引入的失败 —— 口径是"失败项与改动前一致、不得新增"（**⚠️ 由主循环自己跑**）。

## 4. 文档与收口

- [x] 4.1 `Docs/user-guide/context-compaction.md` 同步：在"会花钱"那一节补一句"生成摘要时会带上一段更早的摘要当参考（这样摘要之间不会各说各话），因此每次摘要调用的输入会比过去多一点"（不写内部实现），并确认既有那句"生成摘要要走一次模型调用 —— 这一步是要计费的。阈值调得越低，压得越勤，调用越多。"仍然成立。
  **判据**：`grep` 该文档里这句新增原文必须命中（**删掉或改写它即红**；`test/unit/user_docs_test.dart` 只核对配置键、反引号代码名与 `界面文案：` 标记，**盖不住纯叙述句**，所以它"仍绿"不算验收），贴两条 grep 输出；再跑 `flutter test test/unit/user_docs_test.dart` 确认没有连带失败（贴输出）。
- [x] 4.2 逐条核对 delta 里每个 SHALL（**含括注的义务**）都有对应场景与实现任务覆盖；特别确认：**没有文本相似度闸门**（delta 里"不因文本相似而拒绝/重试"那句只约束相似度闸门，既有"同一段不许两种表示"的结构检查照旧生效），且阈值 / 投影分档 / 何时压 / 何时等这四件钉死的事一个字没碰（贴核对清单：每条义务 → 场景 → 任务）。
- [x] 4.3 收口记账：把 3.3 的 `in=…/out=…` 读数与人工结论写进本条；写清这次优化**没有**成本上限、**没有**摘要质量的自动告警，以及将来要重新考虑这两件事的触发条件（真在实际使用里看到重复；要按会话统计压缩开销）。
- [x] 4.4 本轮审查改过的判据留档（AGENTS.md 第 18 条：改既有判据要能溯源、不许放松、留下改前改后对照）。依据是用户 2026-10-03 的两条裁定（"质量不设每次测试都查的硬要求""把输入 token 记下来"）。收尾报告里并排贴出下列三处：
  - **任务 1.1 的判据**：改前「让**一次**摘要调用返回 `inputTokens: 421 / outputTokens: 99`，断言①…等于 421、②打出的观测行里含 `in=421`」→ 改后「**分别驱动两个方法各一次**，断言两次都读到 `in=421`」（**加严**：原来只驱动一级折叠那一处，`summarizeText` 完全不打观测行也能全绿）。
  - **任务 1.2 的判据**：改前「跑 live 里那条 `token_cost` 断言」→ 改后「跑 `compaction_projection_test.dart` 的两条既有用例 `⑪.3 reject-bloated-L2` / `⑪.3 split-if-invalid`」（**换层**：live 那次留给 3.3，避免同一条 live 被跑两次；两条新点名的用例更直接钉住"输出大小决定合格"）。
  - **任务 4.1 的判据**：改前「跑 `flutter test test/unit/user_docs_test.dart` 仍绿」→ 改后「`grep` 新增原文必须命中（删掉即红），另跑该测试确认无连带失败」（**加严**：原来那句恒真 —— 该测试盖不住纯叙述句，文档一个字不写也照样绿）。

## 5. 本节实测汇总（2026-10-03）

- **4.1 文档**：新增句命中读数 `L77: …生成摘要时会带上一段更早的摘要当参考（这样相邻的摘要之间不会各说各话），因此每次摘要调用的输入会比过去多一点。`；既有那句"这一步是要计费的"仍在（1 处）；`flutter test test/unit/user_docs_test.dart` = `00:00 +5: All tests passed!`。判据能失败已核：把新增句删掉即 grep 零命中。
- **4.2 交叉核对（义务 → 场景 → 任务）**：①只有覆盖范围严格早于本批的摘要可作参考 → 场景「Only summaries that end before the batch are eligible」→ 任务 2.1（纯函数第 6 条用例）；②最多两条、不随会话增长 → 场景「The reference context stays bounded…」→ 2.1（5 条候选仍 ≤2）；③按覆盖范围去重、同一段不以两种文本进同一请求 → 场景「The same span is never carried twice」→ 2.1（去重用例）；④参考与原文分属两条消息、各带抬头 → 场景「A later fold carries the reference and the text as separate messages」→ 2.2（判据①）；⑤有参考才加禁令句、system 保留今天那两句 → 同场景 → 2.2（判据①②）；⑥没有合格候选（第一段 / 库没开）时与今天一字不差 → 场景「The first fold…」「The summary store being unavailable…」→ 2.2（判据②）、2.1（`dbOpen` 为假返回空）；⑦二级那条链的输入不变 → 场景「The level-2 roll-up chain input is unchanged」→ 2.3 源码扫描；⑧摘要文本与参考相似不判失败/不重试 → 场景「A summary that echoes the reference is still accepted」→ 本变更的实现里**没有任何相似度判断**（`grep` 全仓 `similarity`/`ngram` 无命中），既有"同一段不许两种表示"的结构检查未动、仍由 `compaction_projection_test.dart` 的既有用例兜着；⑨每次调用的输入 token 进观测通道、不进模型可见内容、不参与合格判断 → 场景「The input token count is recorded / never reaches the model / Input tokens never decide whether a summary is kept」→ 1.1（两个方法各打一行、`SummaryResult.inputTokens`）与 1.2（输出大小仍决定合格）。
- **本变更没碰的四件钉死的事**：阈值（`compaction_threshold_percent`）、投影分档、何时压（攒够阈值就压）、何时等（等待门槛）—— 本次改动只落在"摘要请求里多两段文字"与"多一行观测"，`git status` 里没有这几个机制的实现文件（`compaction_plan.dart` 未改、`agent_type_config.dart` 未改）。
- **4.3 收口记账**：本次摘要调用的读数（真实运行）：一级折叠 5 次 `in=113/out=481`、`in=3/out=1368`、`in=100/out=603`、`in=114/out=538`、`in=121/out=612`；二级合一 `in=2674/out=764`。**这个读数只等于"这次实际计费的新增输入"，不等于"这次发出去多少"**（证据：一级那几次的原文 raw 是 2170，读数却只有 ~100；二级那次是全新组合，读数 2674 与它的输入规模吻合 —— 最可能是兼容端点报的 `input_tokens` 不含命中缓存的部分）。**这次优化没有成本上限、没有摘要质量的自动告警**；要重新考虑这件事的两个触发条件：①真在实际使用里看到摘要之间重复，②要让读数变成"真实总输入"，那得另开一个 change 让 sidecar 把缓存字段（`cache_read_input_tokens` 等）也透出来（本变更的 `Impact` 不含 C++ 侧，不在这里偷偷加）。
- **人工看质量这一项**：这一轮看得出的结论只有"看不出整段照抄参考、也没有悬空指代"，以及一处与参考无关的格式化瑕疵（一条一级摘要以 `ASSISTANT` 角色标签开头）。**看不出问题就是看不出**，不作为通过判据。

## 6. 做完之后"人工看一次质量"看出来的两件事（2026-10-03 补记，尚未做）

用户在 2026-10-03 明确要求质量靠"跑完自己看一次"。这一轮我按 `extract-summary-history` 的路子做了：先起库抓捕器、再跑 live、然后看摘要正文。**看的过程本身暴露了两件事，按"发现必须落成带能失败判据的任务"记为下面两条**（本 change 其余 14 条已完成；这两条是新发现的，尚未实施）。

- [x] 6.1 **摘要正文以角色标签开头**
  **实测（2026-10-03）**：新增 `stripLeadingRoleLabel`（只削"标签 + 冒号/：` 或"标签紧跟中文"两种形态，英文正文开头的 `ASSISTANT ` 与正文中间的标签原样保留），在 `summarize` 与 `summarizeText` 两个出口各用一次 —— **请求体一个字没改**，所以"没有参考时与今天逐字相同"那条仍然成立。用例读数（`test/unit/model_summary_provider_test.dart`，该文件 7 条全过）：三种实测形态都削掉（`ASSISTANT用户是…`→`用户是…`、`ASSISTANT: 用户目标：…`→`用户目标：…`、`ASSISTANT:本次…`→`本次…`），两类不许误伤的输入原样返回。**变异已实测**：把出口改回不削（`text.toString().trim()`）⇒ 用例红（`Expected: '用户是一名开发协作代理…' / Actual: 'ASSISTANT用户是一名开发协作代理…'`）；改回 ⇒ 绿；`grep MUTATION-6` 计数 0。
  **真实读数（live 连跑）**：改后 `以角色标签开头的摘要条数 = 0 / 6`（改前 `3 / 5`，两次都贴了节点正文作为对照）。
：5 条一级摘要里有 3 条正文以 `ASSISTANT` / `ASSISTANT:` 开头（`ASSISTANT用户是一名开发协作代理…`、`ASSISTANT: 用户目标：…`、`ASSISTANT:本次对话为重复循环的第240–320轮…`），二级那条没有。根因在渲染：`ModelSummaryProvider._messageText` 把每条消息渲染成 `ROLE: 正文`，模型把这个前缀抄进了摘要第一句。
  **判据**：加一条能失败的检查（例如摘要落盘后断言正文不以 `^\s*(USER|ASSISTANT|SYSTEM)\s*[:：]?` 开头，或在渲染时改用不会与正文混淆的格式）；在一条真实 live 压缩上跑一次，读数应是"以角色标签开头的摘要条数 = 0，改之前 ≥ 1"（本次实测 3/5，贴改前读数与改后读数）。
  **溯源**：用户 2026-10-03 裁定"跑完测试后自己看一次压缩质量" —— 这条就是看出来的。
- [x] 6.2 **库抓捕器遇到瞬时文件会整段终止**
  **实测（2026-10-03）**：`tools/capture_compact_db.ps1` 的拷贝从"通配整个目录"改成"按名字逐个拷（`aliasagent.db` / `-wal` / `-shm` / `-journal`）+ 每个文件各自 try/catch"，缺了就跳过。①**端到端**：修好后起抓捕器再跑 live，抓捕器**自己以 exit 0 收尾**（`CAPTURED 123 copies; last source …\aliasagent_compact_db8eb98a`、`DB=…\compact_db_captured\aliasagent.db (471,040 bytes)`），修之前两次都是 exit 1、一格库都没有。②**反例构造**（同一竞态下比两种写法，跑在 `%TEMP%` 里、不碰仓库文件）：制造者不停创建/删除 `aliasagent.db-journal`，各跑 300 轮 —— **旧写法失败 93/300 轮**（就是生产里那次 `Could not find file …db-journal` 的成因），**新写法失败 0/300 轮**且最终库在（4098 字节）。如实说明：那次竞态本身没法按需精确复现（它取决于两帧之间文件是否被删），所以这条判据是"竞态压力下比新旧两种写法 + 端到端真抓一次"，不是"精确重放同一个失败"。竞态制造者收尾时报了一次 `ItemExistsUnauthorizedAccessError`（后台任务在删文件时的无害告警），读数不受影响。
：`tools/capture_compact_db.ps1` 本次实测 `exit code 1`，报 `Copy-Item : Could not find file '…\aliasagent_compact_c7845207\aliasagent.db-journal'`，结果是**一格可用的库都没抓到**（脚本第 40 行对 `*` 通配拷贝，SQLite 的 `-journal` 在两帧之间被删掉就抛错；脚本开头设了 `$ErrorActionPreference='Stop'`，cmdlet 上的 `-ErrorAction SilentlyContinue` 压不住）。本次因此改用 live 日志里的 `[OBS] summary node text:` 作为质量材料（内容同源，够看质量），但"把投影留档成文档"这条路当时是断的。
  **判据**：修好之后连跑两次抓捕 + live，两次都要真的抓到库（贴 `%TEMP%\compact_db_captured\aliasagent.db` 的存在与大小）；反例构造：把 `-journal` 在拷贝前删掉，脚本必须**跳过它继续拷**、退出码为 0（现在会红）。
