## 1. 取值规则（纯逻辑，先做完再动别的）

- [x] 1.1 在 `lib/services/compaction/compaction_plan.dart` 里加一个纯函数表达这条规则，例如 `static bool summarySideWins(int beforeTokens, int afterTokens) => afterTokens < beforeTokens;`（**严格小于**：相等时取压缩前那一侧）。判据：1.2 通过。（"两处调用各一处"这一条不在这里核 —— 那两处要等 2.1、3.1 才存在，判据挪到 3.2。）
- [x] 1.2 新建 `test/unit/compaction_take_smaller_test.dart`：三个读数 —— 压缩后更小 ⇒ 用摘要；压缩后更大 ⇒ 用压缩前；两边相等 ⇒ 用压缩前。断言前打印三个输入与三处返回值。
- [x] 1.3 跑 `flutter test test/unit/compaction_take_smaller_test.dart`，贴出实际输出。
- [x] 1.4 在 `lib/services/compaction/compaction_plan.dart` 里加第二个纯函数 `static bool mayBeLeftOut({required int level, required bool sentAsSummary})` —— 因为容量不够而从这次请求里拿掉一条内容时，**只有二级及以上、且这一趟确实按摘要发出去的条目**允许被拿掉。判据：1.5 通过。
- [x] 1.5 在 1.2 那个文件里加三条对 `mayBeLeftOut` 的用例：一级摘要 ⇒ 不允许；二级摘要（这一趟按摘要发）⇒ 允许；原文 ⇒ 不允许。断言前打印每条输入与返回值。
- [x] 1.6 跑 `flutter test test/unit/compaction_take_smaller_test.dart`，贴出实际输出（含 1.2 与 1.5 的全部断言）。

## 2. 原文⇒一级：删掉折半与省略

- [x] 2.1 `lib/main.dart` 的 `_resolveOpenLevel1` 改成"一次模型调用 + 一次取值"：删掉折半递归那段，删掉 `return const []` 那段；压缩前赢时返回"这一段本身就是这一级的内容"的条目（`text` = 那段原文的纯文本渲染，`tokens` = `CompactionEngine.rawTokens(msgs)` 的估算值 —— 这两个字段的含义与改前不同，按 design D2 在字段旁写清楚）。判据：`grep -n "sublist(0, mid)" lib/main.dart` 零命中；4.1① 通过。
- [x] 2.2 保留脏水位那条规则，只换名字：`onOmit` 改成表达"这一段这一趟没有重新生成摘要"的名字（例如 `onNotResummarized`），调用方那处"不消费脏水位"的行为一个字不改。判据（要能失败，不许拿"既有测试照旧通过"当判据 —— 现有测试里没有一条走到 `clearDirty` 那个分支）：在 4.1 那个文件里加一条用例，造"有一段陈旧（`dirtySince > 0` 且区间够得到它）却没有重新生成摘要"的场景，用假仓库计数，断言 `clearDirty` **没有**被调用；再把 `onNotResummarized` 那处断掉，断言 `clearDirty` **被调用了**。两次输出都贴出来。
- [x] 2.3 Phase C：这类条目**永远按原文发**（不因为"够远了"就改发文本）。判据：4.1① 里断言投影里出现的是那段原文且工具块完整，并且**不出现**那条更长的摘要文本。
- [x] 2.4 不为这类条目写 `summary_nodes` 行。判据：4.1① 里断言库里查不到这一段的 level-1 行。

## 3. 一级⇒二级：删掉拒绝与丢弃

- [x] 3.1 收拢循环里 `l2.tokens >= groupSum` 那一段：不再拒绝、不再 DRAIN，改成按 1.1 的取值规则 —— 压缩后更小就用模型给的二级正文；否则二级的正文 = 那几条一级文本按原顺序拼接，`tokenCost` = 那几条实测 token 之和，照常落盘。判据：4.1④ 通过；并且 `grep -n "summarySideWins" lib/` 命中**两处**（一级 2.1 与二级这里各一处，不许有一级有、二级没有的特殊分支）。
- [x] 3.2 把收拢循环里可丢的判据换成 1.4 的 `mayBeLeftOut`（现在是 `(e.seg.level == 1 || !e.isClosed) && sentAsSummary(e)`，放行了一级摘要和这一趟新产出的段）。`candStart < 0` 分支保留 `table.removeAt(dropAt)` —— `indexWhere` 取的是最旧的那条，所以它现在只会丢到**最旧的二级摘要**。判据：`grep -n "mayBeLeftOut" lib/main.dart` 能核到调用；4.1② 与 4.1⑤ 通过。
- [x] 3.3 那条日志保留原样。如实记下它的条件（我原来写错了）：判据是 `if (total > maxContextTokens)`，只要收拢循环跑完还超容量就打印，**与"有没有丢过东西"无关**；`generate == false` 时整个收拢循环不跑，也不会打印。判据（改了，理由同 4.1⑤）：把这三件事**写进 Phase C 那段注释**（已做，`lib/main.dart` 里 `_buildCompactionProjection` 上方那段，三句都能 grep 到），**不再要求"断言日志里出现这一行"** —— 能走到那一行的两个状态（"丢光二级还是装不下"、"不等却超容量"）在两级结构下都推不出来，理由与 4.1⑤ 同：超容量只可能来自摘要自身的 token，而那正是可丢的那一层。
- [x] 3.4 把 Phase C 那句注释写准：现在写的是「其余的摘要段：这一趟什么都不发（要么已经被更粗的那条顶替，要么按容量省略）」—— 要写明**只有二级摘要**会因为容量被省略，一级摘要与原文不会。判据：这一条与 3.2 是同一处行为，跟着 3.2 的判据走（`mayBeLeftOut` 的调用点就在这段注释下面）；`grep -n "按容量省略" lib/main.dart` 命中的那句里出现「二级」只作为附带的措辞检查，**不单独作为本条的行为验收**。

## 4. 集成测试（假 sidecar 端到端）

- [x] 4.1 新建 `test/integration/compaction_no_drop_test.dart`，六条用例（每条断言前先打印现场：投影里出现的 seq、库里 `summary_nodes` 的行数、日志里那几行）。**这个文件要在做第 2 组之前先建好**（用例① 那时应当是红的 —— 这正是该看到的），因为 2.1/2.3/2.4 的判据都指向它：
  - ① 造"小批压不短"（假 summary provider 对那一批返回比原文更长的"摘要"）⇒ 投影里出现那段原文（工具块与思考块完整）、**不出现**那条更长的摘要、库里没有这一段的 level-1 行。
  - ② 造"超出模型容量、还有二级摘要可丢"⇒ 断言被拿掉的只有二级摘要、且是**最旧**的那几条；一级摘要与原文一条都没少；投影总 token 落到容量以内。
  - ③ 反向：压缩后确实更短的摘要，照旧被采用（防止把规则改成"永远用原文"也能过）；并在这一条里断言整份 `messagesJson` 里**没有相邻两条 `role:user`**（proposal 承诺过这条，原来没有任务接 —— 摘要块与标记的合并规则要保住）。
  - ④ 造"二级压不短"⇒ 断言造出来的二级正文是那几条一级文本的拼接，且这一趟投影的总 token 不比不合成时更大。
  - ⑤ 超容量时**一级摘要与原文一条都不许被拿掉**。判据（判据本身改了，理由见下）：1.5 的两条单元断言（一级 ⇒ 不允许、原文 ⇒ 不允许）＋ 4.1② 里"被拿掉的只有二级"那一条。
    **为什么不再要求"造出只剩一级与原文、仍然超容量的几何"**：那个状态在两级结构下推不出来。超容量意味着投影的总量超过模型容量，而投影的总量 = 摘要（按落盘的实测 token 算）+ 原文；原文那一侧是有上界的 —— 最新那段原文尾部不超过一个阈值 T，其余按原文发的段落都落在"距离不到 T"的近处，两样加起来到不了 4T = 模型容量。所以**超容量只可能来自摘要自身的 token**，而那时二级就在表里、就是可丢的那一条。硬造这个几何只会得到一条永远绿或永远红的假用例。
  - ⑥ 二级被拿掉之后核对库：`summary_nodes` 里那一行原样还在、它盖住的原文也还在 `messages` 表里（只是这次没发）。
- [x] 4.2 处置**三条既有用例** —— 它们断言的正是本变更要删掉的行为，不改它们 `flutter test` 不可能全绿。改的时候按仓库规矩三条齐备：**能溯源**（依据是用户 2026-10-05 那条"取小者、没有特殊情况"的原话，写进任务与提交信息）、**不许放松**（新的断言至少和旧的一样严，要断言新规则下的可观测结果，不许删掉或跳过）、**留下对照**（逐条贴出改前原文与改后原文）：
  - `test/integration/compaction_projection_test.dart` 里「被拒的那一组只许试一次」（`summarizeTextCalls == 1`）；
  - 同文件里「a level-2 that is not smaller than the L1s it replaces must be rejected, never sent」（`isNot(contains('L2 rolled up'))`）；
  - 同文件里「an un-compressible batch must be split down several times before omission」（`summarizeCalls > 6`）。
  判据：改完之后 6.2 的 `flutter test` 全绿；并且把这三条各自的新断言逐条贴出来，能看出"新规则下它断言的是什么"。
- [x] 4.3 跑 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 再跑 `flutter test test/integration/compaction_no_drop_test.dart`，贴出实际输出。

## 5. 用户文档

- [x] 5.1 `Docs/user-guide/context-compaction.md` 补一节「压缩不会少给你内容」：写清"压缩结果永不比压缩前大；压不短的时候就按原文发"。
- [x] 5.2 判据：`grep -n "压不短" Docs/user-guide/context-compaction.md` 有命中，且 `flutter test test/unit/user_docs_test.dart` 全绿（贴两次输出）。这一条不依赖「界面文案」守卫 —— 它是文档表述，不是界面文案。

## 6. 全层验证与变异

- [x] 6.1 `flutter analyze`：贴改动前与改动后两次的问题数，不得更多。
- [x] 6.2 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` + `flutter test`：贴总用例数与结果，必须全绿。
- [x] 6.3 `"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`：贴每一步读数，失败项不得多于改动前。
  **对照读数（上一轮实测，本次要重新跑一遍确认）**：2 passed / 3 failed，三个失败各自的原因 —— `dart analyze lib/` 报 10 个既有问题；`checkpoint_4/5/6_verify.dart` 段错误或还在用旧签名的 `send_message`；视觉回归三张图差异 2.75% / 4.58% / 12.99%。**这三条都是本变更之前就有的**，本次允许的结论是"数量与原因都不变"；多出任何一条新的失败就是本变更引入的。
  **本次实测（已收尾）**：`Total: 2 passed, 3 failed` —— **与基线逐项一致**。Step 1 Build `✓ BUILD PASSED`；Step 2 Analyze `✗ ANALYZE FAILED`（既有问题）；Step 3 Checkpoints `4 passed, 3 failed`（`checkpoint_6_verify.dart` 报 `type 'Null' is not a subtype of type 'List<dynamic>' in type cast`，与基线记的"段错误"是同一个脚本坏着、坏的形式不同）；Step 4 Launch & Verify `✓ ALL PASSED`；Step 5 Visual Regression `✗`，三张图 2.75% / 4.58% / **12.94%**（基线记的是 12.99% —— 差 0.05 个百分点，同一个用例、同一类原因，属渲染噪声，不是新增失败）。
- [x] 6.4 变异验证，每条先红后绿并贴红时的实际输出：
  **六条读数（都实测过，跑完即撤回，`MUTATION-` 残留 0）**：
  - ① 红 `+3 -2`：4.1① 按原文出现 3/24、4.1④ 7/60，`tool_use=false` → 撤回后 `+5` 全绿；
  - ② 红 `+4 -1`：4.1④ 按原文出现从 59/60 掉到 43/60、`tool_use=false` → 撤回后全绿。
    **手法替换说明**：原任务写的是"改回拒绝 + DRAIN"，我实际用的是**等价的更小变异** `final l2Wins = true;`（二级永远采用模型给的那条）—— 它同样把"取小者"这一支断掉，能让 4.1④ 变红；恢复整段"拒绝 + DRAIN"只是把旧代码抄回来，证伪力一样而改动面大得多。
  - ③ 红 `+5 -1`：1.5 里「一级摘要 ⇒ 不允许」读到 `mayBeLeftOut=true` → 撤回后 `+6` 全绿；
  - ④ 红 `+4 -1`：4.1② 的区间起点变成 `[1,3,5,7,21]`（丢了**最新**那条、`seq 1..` 反而留在投影里）→ 撤回后全绿；
  - ⑤ 红 `+5 -1`：1.2 里「两边相等 ⇒ 用压缩前那一侧」读到 `true`（另两条仍绿）→ 撤回后全绿；
  - ⑥ 红 `+36 -3`：**同时**打红 4.1①、4.1④ 与 4.2 改写过的第③条（「⑪.3 压不短 ⇒ 那一段按原文发出去」报 `Expected: not contains '## 更早上下文'`）→ 撤回后 `+45` 三个文件全绿。这一条证明"新写的与改写的断言都确实盯着新行为"。
  - ① 把一级的取值改回"更短才用、否则丢掉那一条" ⇒ 4.1① 变红；
  - ② 把二级的取值改回"拒绝 + DRAIN" ⇒ 4.1④ 变红；
  - ③ 把 1.4 的 `mayBeLeftOut` 放宽回 `level == 1 || !isClosed`（等于旧判据）⇒ 1.5 里"一级摘要 ⇒ 不允许"那条变红。【原来指向 4.1⑤，但 ⑤ 的判据已按上面的理由重写，不再直接断言这条；1.5 才是真正绑住它的地方。】
  - ④ 把丢弃顺序改成从**最新**的那条二级开始丢 ⇒ 4.1② 变红；
  - ⑤ 把 1.1 的严格小于改成"小于等于"（相等时取摘要）⇒ 1.2 变红；
  - ⑥ 把**代码**里"这类条目按原文发"那一支断掉（让 Phase C 对 `verbatimAtLevel` 的条目也按摘要发文本）⇒ 4.1① 与 4.2 改过的第③条（`contains('A' * 100)`）**必须同时变红**。这一条防的是"新写/改写的断言其实没盯着新行为"。【原来写的是"把 4.2 改过的断言改回旧行为（或删掉）⇒ 必须变红"，这条在逻辑上不成立：删掉测试永远不会让套件变红，而**旧断言在新代码下恰好仍然成立**（`summarizeCalls > 6` 现在是因为"一批一次"而不是"折半"），所以改回去也不会红 —— 真正能证伪的是"改代码"。】
- [x] 6.5 清残渣：`grep -rn "MUTATION-" lib/ test/ integration_test/ sidecar/` 零命中；跑测试产生的临时文件清掉。
  **判据改了（原来写的是搜 `MUTATION`，那条永远不成立）**：`grep -r` 默认**忽略大小写**，搜 `MUTATION` 会把 `lib/main.dart` 与 `lib/services/summary_node_repository.dart` 里十几处无关的小写 `mutation` 注释（讲"叶子级内容变更"的）一起算进去，永远搜不出零命中。变异标记统一用连字符形式 `MUTATION-`（本轮实测：`MUTATION-` 命中 0，小写 `mutation` 注释 14 处）。临时文件：跑测试写出来的 `%TEMP%\apply_*.log` 之类，收尾时清掉（`%TEMP%` 才是它们该待的地方，仓库里不许留）。

## 收尾读数（归档与提交时用，都是实测）

| 项 | 读数 | 命令 |
|---|---|---|
| `flutter analyze` | **170**（与改动前**持平**；中途曾多出 1 条 `avoid_print`，已修） | `flutter analyze` |
| 全量 VM 测试 | **`+349: All tests passed!`**（基线 338 + 本变更新增 11 条 = 349） | `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` + `flutter test` |
| 新集成用例 | **`+5: All tests passed!`** | `flutter test test/integration/compaction_no_drop_test.dart` |
| 新单元用例 | **`+6: All tests passed!`** | `flutter test test/unit/compaction_take_smaller_test.dart` |
| 改过的既有用例 | **`+34: All tests passed!`** | `flutter test test/integration/compaction_projection_test.dart` |
| 用户文档一致性 | **`+5: All tests passed!`** | `flutter test test/unit/user_docs_test.dart` |
| 变异 | 六条逐条先红后绿，`MUTATION-` 残留 0 | 见 6.4 |
| 冒烟 | 见 6.3 | `test/smoke/run_all.sh` |

改动规模（`git diff --stat`）：`lib/main.dart` +170/−?、`lib/services/compaction/compaction_plan.dart` 44 行、`Docs/user-guide/context-compaction.md` 11 行、`CLAUDE.md` 4 行，共 **148 插入 / 81 删除**；新增两个测试文件（25 KB + 4 KB）。

**注意（与归档无关但提交时会带上）**：`CLAUDE.md` 的 4 行改动是本会话早先加的规则（"拿注释/用例当证据必须再追一步"与"对抗审查的产出只能当待核假设"），**不属于本变更的范围**，提交时要么单独说明、要么分开提。
