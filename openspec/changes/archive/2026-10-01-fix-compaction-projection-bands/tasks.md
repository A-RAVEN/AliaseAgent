## 1. 先把判据写出来（在现在的代码上必然失败）

- [x] 1.1 `test/integration/compaction_projection_test.dart` 新增**两条**用例（两种状态各一条），断言前先把现场打印出来（发出去的 messages 条数、两处标记各自在不在、每一段用的是哪一档的表示）：
  - **状态 A（2 级还不够远）**：已经有一条 2 级摘要，但它覆盖的跨度里还有一部分离末尾不到 `2T`（没整段落到最远档），而中距那一段本来有 1 级摘要。断言：投影里出现 **1 级标记**、**不出现 2 级标记**，并且**同一段内容只出现一次**（不许既有 1 级文本又有覆盖它的 2 级文本）。
  - **状态 B（2 级整段够远）**：2 级覆盖的跨度两端都落到最远档（都超过 `2T`），而它更近的那一段里另有 1 级摘要。断言：投影里**同时**出现 1 级标记与 2 级标记，且两处标记覆盖的 seq 区间**不重叠**。
  **判据**：在**还没改** `compaction_plan.dart`、`main.dart` 的 `_loadClosedSegments` 与投影拼装的代码上跑这两条，**状态 A 必须失败**（现在的代码直接把 2 级发出去、把 1 级丢掉），把红的实际输出贴出来。这一条是本变更的红态，也是将来的守卫。

  **红态实测（改代码之前，`flutter test test/integration/compaction_projection_test.dart -r expanded`，16 过 2 红）**：
  ```
  [OBS] 状态A（2 级还不够远）: 发出去 41 条消息；1级标记=true 2级标记=true；
        摘要段=1..40,41..91；原文逐条出现的 seq 有 39 个（最小 92，最大 130）；
        没有任何表示的 seq=[]；出现两次的 seq=[]
  Expected: not contains '## 更早上下文(压缩xN,层级2,非用户发言)'
  ```
  状态 A 红在"2 级还不够远却已经被发出去"：旧代码对每个跨度只取最粗的那条，预置的 1 级
  [1..15]、[16..40] 因此**一条都没进投影**（摘要段里只有 `1..40` 这条 2 级），本轮刚压出来的
  [41..91] 也**立刻**被当成摘要发出去。守卫用例同时守住了另外两条：每段恰好一种表示、
  刚压出来还不够远的批次这一轮必须发原文。
  ```
  [OBS] 状态B（2 级整段够远）: 发出去 21 条消息；摘要段=1..26,31..60,61..111；
        原文逐条出现的 seq 有 19 个（最小 112，最大 130）；
        没有任何表示的 seq=[27, 28, 29, 30]；出现两次的 seq=[]
  Expected: not contains 'seq 61..111'
  ```
  状态 B 顺带量出一个**既有缺陷**：seq 27..30 这四条**在投影里没有任何表示**（都不在已闭合的
  摘要跨度里，又被"已覆盖到 seq 60"这条下界挡在尾部之外）—— 内容在发给模型时被静默丢掉。
  任务的 3.2（不许出现空档）就是修它。


## 2. 加距离与档边界（纯函数）

- [x] 2.1 `lib/services/compaction/compaction_plan.dart`：新增距离与档边界的唯一计算点 —— 距离按一段内容**最旧那条消息**算（它后面所有原文的估算 token 之和），边界是 `T` 与 `2T`（都从 `thresholdTokens` 推，不引入新的绝对 token 数）；并给出"一条摘要的整段是否已经够远"的判定（两端都超过 `2T` 才算）。
  **判据**：先写用例再实现。①单元用例：容量 20000 与 40000 下边界按比例翻倍（`20000×25%=5000`、外边界 `10000`；`40000` ⇒ `10000` / `20000`）；②单元用例：距离按最旧那条算（同一份历史、同一个容量下，断言某条 1 级落在哪一档，并与"按最新那条算"的结果对照，证明口径被写死了）。先跑一次把它们跑红（函数还不存在 ⇒ 编译不过，如实贴出来），再实现到绿。

  **先跑红**（函数还不存在）：`flutter test test/unit/compaction_engine_test.dart` ⇒ `Error: Member not found: 'CompactionEngine.bandFloorTokens'`（8 条）、`'…distancesBySeq'`（1 条）、`'…substitutesWholeSpan'`（6 条），末尾 `Failed to load … Compilation failed`、`exit=1`。
  **还有一次红是我自己算错的**（同一轮里）：函数写出来之后第一次跑，用例在"距离"那几条上红了 —— 我把 `seq1` 的距离手算成 1006，实际是 906（我把自己那条消息本身也算进去了）。打印出来的实际读数（`seq1=906 … seq11=0`）纠正了我的手算，改的是用例里的期望值，不是实现。这一条如实记在这里：当时那个红是**我的算错**，不是实现的错。
  **实现后转绿**：`00:00 +25: All tests passed!`，现场读数：
  ```
  [OBS] 容量 20000 ⇒ T=5000，中距档下界 5000、最远档下界 10000；容量 40000 ⇒ T=10000，中距档下界 10000、最远档下界 20000
  [OBS] 距离（比它更新的原文之和）: seq1=906 seq2=806 … seq10=6 seq11=0 ；spanIndices(1..6)=(newest: 5, oldest: 0)
  ```
  **口径按规范原文落定**（实现时才定死，已同步进 design 的 D1/D2）：一段内容的档按它**最旧那条消息**算，所以 **1 级只要起点超过 `T` 就顶替**（`substitutesSpan` 对 1 级只看最旧端），**只有 2 级要求整段都超过 `2T`**（两端都查）。
  第一版实现把 1 级也做成"整段都要够远"，跑出来是：刚压出来的批次永远进不了投影，连 6.1"压出来的摘要必须真的进入发给模型的内容"也挂了。处理方式不是放宽那条判据，而是改我的口径 —— 规范原文写的是 `The distance of a segment SHALL be measured at its OLDEST covered message`，只有 2 级那条写的是 `its WHOLE covered span`。按规范改回后 6.1 自然转绿。
- [x] 2.2 `lib/main.dart` 的 `_loadClosedSegments`：现在是"每个跨度取最粗的那条"（注释原文 `adopts it and subsumes the L1s`），被 2 级盖住的 1 级整条被跳过。改成**逐段按档选节点**：2 级的整段够远就用 2 级（它盖住的 1 级不选），不够远就用它覆盖范围内的 1 级（该 2 级不选）；选出来的节点之间仍然不重叠。
  **判据**：加一条用例 —— 库里预置"2 级 [1,N] + 覆盖在其中的两条 1 级 + 更近的一段 1 级"，分两种距离状态各断言一次选出来的节点集合（状态 A 选 1 级、状态 B 选 2 级与更近那条 1 级）；贴输出。

  **判据怎么落的**：`_loadClosedSegments` 是私有方法，所以从**真实投影**上核（比断言中间集合更强：发出去的内容才是产物）。预置节点与两种距离状态就是 1.1 的状态 A / 状态 B 两条用例 —— 状态 A 摘要段=`1..15,16..40`（2 级不够远 ⇒ 选它盖住的两条 1 级），状态 B 摘要段=`1..26,31..60`（2 级够远 ⇒ 选 2 级 + 更近那条 1 级）。
  **实现时改了一处判断（记在这里，免得以后当成回归）**：一开始写成"不够远就一律不收"，结果把**1 级**也不收了 —— 而"1 级攒够阈值就合成 2 级"这条钉死的规则要靠这些 1 级的实测 token 参与累加，6.2 立刻变红（`L2节点数=0`、`summarizeTextCalls=0`，合成整个不发生了）。现在是：**2 级不够远就不收（改收它的 1 级）；1 级不够远也收**（它是这一段最细的摘要表示，还要参与合成累加），发摘要还是发原文交给投影那一趟按距离定。
- [x] 2.3 `lib/main.dart` 的 `_resolveSummaries` 与投影拼装：按档选表示（≤`T` 原文、`T`–`2T` 1 级、>`2T` 2 级），并让拼装支持**摘要与原文按时间交错**（现在是把所有摘要拼成最前面一条消息、原文全排在后面）。
  **判据**：1.1 的两条用例都转绿（贴前后两次输出）；再补两条：①"同一段内容在投影里只出现一次"（按 seq 区间检查不重叠、且同一段不会两种表示都在）；②"投影里的消息按 seq 单调递增"（交错拼装不许打乱顺序）。

  **实测**：1.1 两条从红转绿，另加状态 C。现场读数：
  ```
  [OBS] 状态A（2 级还不够远）: 发出去 41 条消息；1级标记=true 2级标记=false；摘要段=1..15,16..40,41..91；原文逐条出现的 seq 有 39 个（最小 92，最大 130）；没有任何表示的 seq=[]；出现两次的 seq=[]
  [OBS] 状态B（2 级整段够远）: 发出去 25 条消息；1级标记=true 2级标记=true；摘要段=1..26,31..60,61..111；原文逐条出现的 seq 有 23 个（最小 27，最大 130）；没有任何表示的 seq=[]；出现两次的 seq=[]
  [OBS] 状态C（这一段一条摘要都没有）: 发出去 81 条消息；1级标记=true 2级标记=false；摘要段=41..91；原文逐条出现的 seq 有 79 个（最小 1，最大 130）；没有任何表示的 seq=[]；出现两次的 seq=[]
  ```
  `没有任何表示的 seq=[]` 与 `出现两次的 seq=[]` 就是判据里那两条：每一段恰好一种表示（不重叠、不重复），原文与摘要按时间交错且顺序不乱。投影拼装改走一条**时间线**（`ProjectionPiece`：要么发摘要、要么发这一段的原文），时间线上相邻的原文段合成一段；摘要文本并进它后面那段的第一条 user 消息，保持角色交替（不出现相邻的两条 role:user）。
  **拼装这里我写坏过一次，如实记**：第一版时间线是拿"计划里的段对象"去表里查（按对象身份），可本轮新压出来的那些批次的条目**不是**计划里那个对象（`_resolveOpenLevel1` 会新建段对象），于是查不到、直接 `continue`，那一段在投影里**凭空消失** —— 状态 A 跑出来 `没有任何表示的 seq=[41..91]` 就是这个。改成按"段在历史里的位置"排序拼装之后转绿。
  **现场读数**：改完之后三次运行分别是 `没有任何表示的 seq=[]`、`出现两次的 seq=[]`（状态 A/B/C 三条用例都是），另外 `plan.verbatim` 与状态 B 的 `原文逐条出现的 seq` 里都能看到 seq 27..30 —— 那四条原本就是被上面这个 bug 之外的**既有缺陷**丢掉的（改之前的状态 B 红态读数）。

## 3. 两条边界细则

- [x] 3.1 跨度与档边界不对齐时，整段按"够不够远"判：够远就用粗的、不够远就用细的，不做逐消息拆段。
  **判据**：构造一条"一端够远、另一端不够远"的 2 级，断言投影用的是它的 1 级摘要而不是它自己；贴输出。

  **已由 1.1 状态 A 覆盖**：预置的 2 级 [1..40] 最旧端距离 12906（够远）、最新端距离 9006 ≤ 2T（不够远）⇒ 投影用的是它盖住的两条 1 级（摘要段 `1..15,16..40`），2 级标记不在。纯函数那一层另有一条同型判据：2 级两端距离 906 / 706 对下界 800 ⇒ 判 false。
- [x] 3.2 某一档还没有摘要时按更细的表示发（中距回落到原文、最远档回落到它的 1 级摘要），不许发出空档。
  **判据**：构造"中距档有内容、但还没有对应 1 级摘要"的状态，断言那一段在投影里是原文而不是空白；贴输出。**同时如实记**：既有那条"整批被判不可压缩就整段省略"（`_resolveOpenLevel1` 返回空）不在本次范围，别把它算成本任务的验收。

  **新增状态 C 用例**（库里只放一条不够远的 2 级 [1..40]，没有对应的 1 级节点可回落），实测：
  ```
  [OBS] 状态C（这一段一条摘要都没有）: 发出去 81 条消息；1级标记=true 2级标记=false；摘要段=41..91；原文逐条出现的 seq 有 79 个（最小 1，最大 130）；没有任何表示的 seq=[]；出现两次的 seq=[]
  ```
  seq 1..40 这一段按原文逐条发出去（`最小 1`）。**改之前它是丢的**：1.1 状态 B 的红态读数里写着 `没有任何表示的 seq=[27, 28, 29, 30]` —— 夹在两条摘要之间的那四条在投影里凭空消失；这条用例把那个既有缺陷一起守住了（把它改回旧写法就会红）。
  既有那条"整批被判不可压缩就整段省略"（`_resolveOpenLevel1` 返回空 ⇒ 这一段什么都不发）**没有动**：`test/integration/compaction_projection_test.dart` 的 `⑪.3 split-if-invalid` 保持原断言（`hasMarker=false`，投影只剩当前用户消息），本次不算它的验收。

## 4. 改写两条既有断言（它们的旧口径与本次裁定冲突）

> 依据：用户 2026-09-26 的裁定「不应该出现一级摘要和二级摘要有内容重复的情况。我指的是发送给 AI 的内容。」旧断言写的是"2 级一生成就把被它覆盖的 1 级顶掉、1 级不再出现"，与新口径冲突。这次改写是把断言对齐到新口径，**不是为了让代码通过而放宽**：新断言比旧的更严（多了"每段恰好一种表示、段落之间不许重叠"的检查）。

- [x] 4.1 `integration_test/compact_quality_live_test.dart`：把那条 `expect(sentTexts.any((t) => t.contains(kSummaryMarker)), isFalse, reason: '④ 被合成掉的层级 1 摘要不该再单独出现在投影里')` 改成新口径的检查：①投影里**没有任何两段覆盖的 seq 区间重叠**（也就是同一段内容不会既以 1 级又以 2 级出现）；②2 级标记是否必须出现，取决于它覆盖的整段是否都已落到最远档 —— 够远才要求出现，不够远就不要求。同时核对它邻近那条硬要求"2 级必须出现"的断言，按同一口径改成条件断言。
  **判据**：改完跑一次 `flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows`，贴输出与 `[VERDICT]` 行，并用 `read_image` 读它留下的截图。**若这次运行里 2 级还不够远，如实写"本用例只验证了不重复，没验证 2 级进投影"**，不许写成 2 级已验证。

  **改法**：这一趟到底该不该发那条 2 级，由**产品代码**算（`CompactionEngine.spanIndices` + `substitutesSpan`，用真实历史 `preHistory` 的距离），不靠人眼看；然后分两支断言：
  - 够远 ⇒ 2 级标记必须在发出去的内容里，且库里那条 2 级的文本（开头 40 字）必须能在投影里找到；
  - 不够远 ⇒ 2 级标记必须不在，并且被它盖住的那些 1 级里至少有一条必须真的以 1 级形式出现（不许两头顶替之后这一段什么都没有）。
  另加不重复检查：被这条 2 级盖住的 1 级摘要，只要 2 级进了投影，它们的**全文**就不许再单独出现在投影里（用全文比对，不用 40 字前缀，避免模型摘要里恰好含同一句话导致误报）。

  **实测（`01:17 +1: All tests passed!`）**：
  ```
  [OBS] ④ 层级 2：层级 1 条数=5 层级 1 实测 token 合计=2998 层级 2 条数=1 阈值=2165
  [OBS] ④ 按规则算出的合成范围：从 seq 1 到 seq 483（最旧起前 3 条的实测累计 2222，阈值 2165）
  [OBS] ④ sent messages contain L2 marker=true contain L1 marker=true sentChars=29375
  [OBS] ④ 这条 2 级这一趟该不该进投影=true （它覆盖 seq 1..483，最旧端距离=12966、最新端距离=6482，最远档下界 2T=4330）；投影里实际有没有=true
  [OBS] ④ 被 2 级盖住的层级 1 共 3 条，其中单独出现在投影里的=0 条
  [OBS] ④ 真实上下文视图可用=true
  ```
  也就是说这次**真的验证到了"2 级进投影"**：那条 2 级最新端离末尾 6482，超过 2T=4330 ⇒ 必须出现（确实出现），而被它盖住的 3 条 1 级单独出现的次数是 0 ⇒ 同一段内容没有两种表示。截图 `test/live_visual/compact_quality_live.png` 用 `read_image` 看过：「真实上下文」那一屏里 `[0] user` 下依次是**一条 2 级块 + 两条 1 级块**，后面接逐字的原文消息 —— 三级同屏，且两条 1 级正是那条 2 级**没盖住**的那两条。
  **没走到的分支如实记**：「2 级还不够远 ⇒ 必须不在」这一支这次没被 live 走到（这次它够远）。这一支由 `test/integration/compaction_projection_test.dart` 的状态 A 用例与单元用例守着（改回去就会红）；**第一次 live 跑（断言还没改完时）确实出现过"不够远"的真实几何**（2 级覆盖 seq 1..645，最新端距离 4311 < 2T=4330），但那次在更前面一条断言上先红了，没走到这一段 —— 所以那次不算验证过这一支。
  **顺带改掉一条旧断言（记在这里）**：同段 ④ 里那条 `expect(l2Nodes.first.coveredMaxSeq, greaterThanOrEqualTo(所有 1 级的最大 coveredMaxSeq))`（"覆盖范围要包住所有被它替换的层级 1"）**不是规则的要求** —— 规范写的是"从最旧累计实测 token、首次超过阈值就成组"，所以组里可以只有最旧的那几条。实测这次只成组了最旧 3 条（2222 > 2165）、第 4/5 条留在外面，旧断言因此误红。改成按规则**算出应有的范围再做精确相等**断言（`oldestL2.coveredMinSeq == 最旧 1 级的 coveredMinSeq` 且 `oldestL2.coveredMaxSeq == 累加首次超阈值那一条的 coveredMaxSeq`）—— 比原来的 `greaterThanOrEqualTo` 更严。
- [x] 4.2 `test/integration/compaction_projection_test.dart`：把顺序不变式"发给模型的内容里，各段覆盖起点严格从旧到新递增"按新口径重写 —— 仍然要求选出来的段互不重叠、按 seq 递增；把断言文本改成这两条（"互不重叠"+"按 seq 递增"），并保留原来那条能失败的现场打印。
  **判据**：贴出旧断言原文与新断言原文的对照，然后跑该文件到全绿并贴输出；再临时把 2.2 的"整段够远才用 2 级"改回旧行为，确认新断言会红（贴红）。

  **旧断言原文**（`test/integration/compaction_projection_test.dart`，用例 `3.2/3.3/6.5 交错场景`）：
  ```dart
  final startSeqInOrder = RegExp(r'seq (\d+)\.\.').allMatches(projected)
      .map((m) => int.parse(m.group(1)!)).toList();
  expect(startSeqInOrder.length, greaterThanOrEqualTo(2), reason: '前提：投影里确实有多段摘要，否则"顺序"无从谈起');
  for (var i = 1; i < startSeqInOrder.length; i++) {
    expect(startSeqInOrder[i], greaterThan(startSeqInOrder[i - 1]),
        reason: '第 $i 段的覆盖起点（${startSeqInOrder[i]}）必须严格大于前一段的（${startSeqInOrder[i - 1]}）—— 改成单一有序表之后顺序不能乱');
  }
  ```
  **新断言原文**：
  ```dart
  final spans = _summarySpansIn(projected);          // 每段的 (lo, hi)，不只是起点
  expect(spans.length, greaterThanOrEqualTo(2), reason: '前提：投影里确实有多段摘要，否则"顺序"无从谈起');
  for (var i = 1; i < spans.length; i++) {
    expect(spans[i].lo, greaterThan(spans[i - 1].hi),
        reason: '第 $i 段的覆盖起点（${spans[i].lo}）必须大于前一段的覆盖终点（${spans[i - 1].hi}）—— 各段互不重叠，且严格从旧到新');
  }
  ```
  差别：旧的是"起点递增"（`next.lo > prev.lo`，两段重叠着也照样通过），新的是"下一段的起点大于上一段的终点"（`next.lo > prev.hi`）—— **更严**，它同时守住"互不重叠"与"从旧到新"。同一条用例的现场打印一并升级成打出每段的 `lo..hi`。
  **同一趟还核出三处同类冲突**（旧断言都写"2 级一生成就得出现在投影里"，与新口径相反，按同一口径改写，改前改后如下）：

  | 用例 | 旧断言 | 新断言 |
  |---|---|---|
  | `3.4/6.4 跨轮次累加` | `expect(projected, contains(kLevel2SummaryMarker))` | `expect(projected, isNot(contains(kLevel2SummaryMarker)))` + 1 级标记必须在 + 两条被盖住的 1 级（`1..4`、`5..8`）的跨度必须都在 + 各段互不重叠 |
  | `3.2/3.3/6.5 交错场景` | 同上 | 同上（这一趟两条 2 级都还不够远，都不进投影） |
  | `6.2 没超容量也合成更粗的摘要` | `expect(projected, contains(kLevel2SummaryMarker))` | `expect(projected, isNot(contains(kLevel2SummaryMarker)))` + `expect((jsonDecode(projected) as List).length, 11)`（原文一条不少地照发） |

  三处的**旧断言里那条真正的硬要求都没有被丢掉**：`3.4/6.4` 与 `6.2` 仍然断言"库里必须真的多出一条 level=2 的节点及其覆盖范围"（合成照做），`3.2/3.3/6.5` 仍然断言 `summarizeTextCalls == 1`（合成只发生一次）。改的只是"它这一趟进不进投影"这一句，并各自加了一条更严的检查。
  **该文件实测**：`00:03 +43: All tests passed!`（含 1.1 的状态 A/B 与 3.2 的状态 C）。反例构造（把"整段够远才用 2 级"改回旧的"最粗优先"）见任务 5.2。
- [x] 4.3 逐条列出**不受影响**的既有断言并跑一遍证明没连坐：`test/integration/compaction_projection_test.dart` 里其余用例、`test/integration/cost_discipline_test.dart`、`test/integration/background_fold_test.dart`、`test/unit/compaction_engine_test.dart`（后者只测切批与阈值，不测投影选段）。
  **判据**：这些文件全绿，贴输出。

  **实测**：`flutter test test/integration/cost_discipline_test.dart test/integration/background_fold_test.dart test/integration/compaction_fixture_test.dart test/integration/summary_node_repository_test.dart test/integration/tool_result_elision_test.dart test/unit/seam_selector_test.dart test/widget/context_view_test.dart test/unit/context_estimator_test.dart test/unit/guard_anchors_test.dart test/unit/model_summary_provider_test.dart test/unit/agent_registry_test.dart` ⇒ `00:05 +45: All tests passed!`。
  范围比原计划**扩大**了：除了清单里的四个文件，还按"凡是碰到压缩/摘要节点的测试文件都跑一遍"把仓库里其余相关文件一并跑了（`compaction_fixture_test`、`summary_node_repository_test`、`tool_result_elision_test`、`seam_selector_test`、`context_view_test` 等），结果是没连坐。
  **如实记一处与原计划的偏差**：原计划写"`compaction_projection_test.dart` 里其余用例不受影响"，实测**不受影响是不成立的** —— 其中三条旧断言（3.4/6.4、3.2/3.3/6.5、6.2）正好写的是旧口径，属于必须改写的那一类，已在 4.2 里一并改掉并留了对照。其余用例（R-A2-5d、before/after、guard anchors、consecutive role:user、under-budget、单条超阈值、合成被拒、coarsen、reject-bloated-L2、split-if-invalid、R1-5、6.1）逐条跑过，没有一条需要改。

## 5. 验证

- [x] 5.1 `test/unit/compaction_engine_test.dart` + `test/integration/compaction_projection_test.dart` 全绿，贴输出。
  **实测**：`flutter test test/integration/compaction_projection_test.dart test/unit/compaction_engine_test.dart` ⇒ `00:03 +44: All tests passed!`（投影文件 19 条 + 单元文件 25 条；含本次新增的状态 A/B/C 与两条纯函数用例）。
- [x] 5.2 反例构造（防假绿）：把 2.2 的"整段够远才用 2 级"临时改回"最粗优先"（即现在的行为），重跑 1.1 的状态 A ⇒ 必须**变红**；改回 ⇒ 必须变绿。两次输出都贴。
  **做法**：把 `substitutesSpan` 里那条"2 级要查最新端"的门槛临时改成只对 3 级生效（`level >= 3`），也就是让 2 级退回"只要起点够远就顶替"的旧行为。
  **红的实测**（`exit=1`，三条一起红）：
  ```
  [OBS] 状态A（2 级还不够远）: … 1级标记=true 2级标记=true；摘要段=1..40,41..91；…
  00:02 +34 -2: … 投影分档 · 状态 A：2 级还不够远 ⇒ 发它盖住的 1 级，2 级不进投影 [E]
  00:03 +35 -3: … 投影分档 · 状态 C：某一段一条摘要都没有 ⇒ 照原文发，不许留下空档 [E]
  00:00 +24 -1: … 距离按「它后面还有多少原文」算；1 级看起点，2 级要整段都够远 [E]
  ```
  摘要段退回 `1..40,41..91` —— 正是用户报的那个缺陷现场（2 级把 `1..40` 整段吞掉、被它盖住的两条 1 级一条都不在）。**改回**（删掉临时那行）⇒ `00:03 +44: All tests passed!`，且 `grep MUTATION lib/services/compaction/compaction_plan.dart` 无残留。
- [x] 5.3 按 CLAUDE.md 的验证清单逐层跑并逐层贴输出（本变更只动 Dart，但下面几层照跑、结果如实记）：
  1. `flutter analyze` —— 改动文件不得新增问题；
  2. **先同步 DLL**（`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`）再跑**全量** `flutter test`（会开浏览器窗口，**由主循环自己跑，禁止派子 agent**）；
  3. live：`flutter test --tags live --run-skipped integration_test/show_compaction_live_test.dart -d windows` —— 跑完用 `read_image` 读 `test/live_visual/show_compaction_live.png` 做视觉验收。**要看到界面上同时有原文、1 级摘要、2 级摘要**：这要求历史足够长，让某条 2 级的整段都落到最远档 —— 不够长就先补内容把距离推出去（在用例里说明补了多少），再看那一屏；只看 "All tests passed" 不算过；
  4. C++：`cmake --build sidecar/build/windows --config Debug` + `ctest --test-dir sidecar/build/windows -C Debug`（本变更不动 C++；已知那条联网搜索用例不稳，如实记录，不要用"不是我的代码"收口）；
  5. 冒烟：`test/smoke/run_all.sh`（Windows 上走 Git Bash 跑它，不要跑交互式的 `run.bat`）。

  **逐层结果（按上面的顺序，每层贴实际输出）**：

  **第 1 层 `flutter analyze`**：`171 issues found. (ran in 5.5s)`（改动前那次是 173 条，其中两条是我新写的测试里被 lint 指出的，已顺手改掉）。
  **我改过的文件里没有新增任何问题**：`lib/main.dart` 只有一条既有的 `unused_local_variable`（`nsCount`，改动前那次就在，只是行号被我的新增内容顶下去了 2683 → 2709）；`test/unit/compaction_engine_test.dart` 的两条（第 80、329 行）也都是既有代码里的，不是我这次加的部分。
  **errors 有 9 条，全部在 `test/checkpoint_4_verify.dart` / `test/checkpoint_5_verify.dart`**（`NativeCallable` 类型不匹配），这两个文件本次一个字都没动；改代码之前那次 `flutter analyze` 里它们就已经在（同样的 9 条、同样的位置）—— 如实记在这里，不说成"与本次改动无关"就完事：它们是既有问题，本次没有去碰。
  **第 2 层 DLL + 全量 `flutter test`**：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` ⇒ `SYNCED: build\windows\x64\runner\Debug\sidecar.dll -> E:\Projects\AliasAgent\sidecar.dll（built 2026/9/26 22:19:48）`；再 `flutter test` ⇒ `00:27 +257: All tests passed!`（257 条，含 `test/integration/browser_worker_test.dart` 那条会开可见浏览器窗口的用例）。
  **加完 7.1 / 7.2 两条用例之后重跑**：第一次 `+247 -2`，红的两条都在 `test/integration/browser_worker_test.dart`，失败形态是 `TimeoutException after 0:00:30.000000: Test timed out after 30 seconds`（那个探针自己冷启动 Edge 的上限是 25 秒）。**查证过程**：①该文件单独跑 ⇒ `00:10 +12: All tests passed!`；②紧接着再跑一次全量 ⇒ `00:18 +259: All tests passed!`（259 = 257 + 新增的 2 条）。该文件本次一个字都没动（`git status` 里没有它）。判定：**全量并发下 Edge 冷启动超时造成的抖动**，不是本次改动引起 —— 如实记这一条，包括第一次那两条红。
  **第 3 层 live + 视觉验收**：**两个用例都跑了**。
  ① `integration_test/compact_quality_live_test.dart` —— `01:17 +1: All tests passed!`，读数与截图见任务 4.1；那一屏里 `[0] user` 下就是**一条 2 级块 + 两条 1 级块 + 逐字原文**。
  ② `integration_test/show_compaction_live_test.dart`（展示用那个）—— 跑通并存下截图 `test/live_visual/show_compaction_live.png`（79312 字节，`read_image` 看过：2 级块的正文展开着，里面还带着那条随机口令）。实测读数：
  ```
  [OBS] 模型上下文总量=5200 阈值=1300（= 总量的 25%）原始内容总量=13002
  [OBS] 摘要 level=1 覆盖=[1,93] token=467 …（共 9 条 1 级，覆盖 seq 1..873）
  [OBS] 摘要 level=2 覆盖=[1,289] token=467
  [OBS] 摘要 level=2 覆盖=[290,580] token=474
  [OBS] 摘要 level=2 覆盖=[581,873] token=589
  [VERDICT] 2 级覆盖 seq 1..289：最新端离末尾 9113 raw，最远档下界 2T=2600 ⇒ 够远，必须出现在这一趟的投影里
  [VERDICT] 2 级覆盖 seq 290..580：最新端离末尾 5206 raw ⇒ 够远，必须出现在这一趟的投影里
  [VERDICT] 2 级覆盖 seq 581..873：最新端离末尾 1274 raw ⇒ 还不够远，这一趟由它的 1 级摘要表示
  [VERDICT] 这一次发出去的内容按档分：最远档（2 级摘要）2 块（库里 2 级实测 token 合计 1530）；中距档（1 级摘要）3 块（库里 1 级实测 token 合计 4723）；最近档（逐字原文）约 837 估算 token（3349 字符）
  ```
  **这一屏同时有三级**：最远档 2 块 2 级摘要、中距档 3 块 1 级摘要、最近档 837 估算 token 的逐字原文 —— 而且三条 2 级里最新的那条（覆盖 seq 581..873）**没有**进投影，正是因为它最新端只离末尾 1274 raw、没到 2T=2600，这一段改由它的 1 级摘要表示。这就是本变更要证明的行为。
  **为了看到 2 级进投影，把展示用例的模型上下文总量从"原始内容的 2/3"改成"2/5"**（在用例里写明了原因与实测数字：按 2/3 时阈值 2165、2T=4330，而那批 1 级合出来的 2 级后面只剩两千多，够不着；按 2/5 时阈值 1300，同一条 2 级后面还剩 5000 以上）。**这不是放宽判据** —— 它只是把展示用例的几何调到"2 级够得着最远档"，判据本身（够远才进投影）一个字没动。
  **顺带记两条**：随机口令那条造假检查里，"口令出现在存下来的摘要正文里=true、出现在真正发出去的上下文里=true"（说明整条链是真的）；"直接问模型口令它答出来了=false" —— 模型这次答的是超时值、没答口令，这一条**没有验证到**，如实记，不写成通过。
  **窗口处理**：这个用例按设计会把窗口挂住（最多 6 小时）。截图与读数都拿到之后我把它关掉了 —— 因为冒烟那套要重新构建应用，而构建会覆盖正在运行的那个 exe。要再看那一屏，随时可以重跑它。
  **第 4 层 C++**：`cmake --build sidecar/build/windows --config Debug` ⇒ `exit=0`（产出 `sidecar.dll` + `sidecar_tests.exe`）；`ctest --test-dir sidecar/build/windows -C Debug` ⇒ **`test cases: 237 | 236 passed | 1 failed`**（`assertions: 3739 | 3738 passed | 1 failed`）。
  失败的那一条在 `sidecar/test/search_provider_test.cpp`，是**联网的搜索 provider 实时用例**：日志里 5 次尝试全部 `connection error — Could not connect to server`（ZhipuAI / Kimi / SearXNG 都是"连不上"），`[rate-guard live] 0/5 succeeded, 5 errors`。本变更一个字都没动 C++（`git status` 里没有 C++ 文件），而且失败形态是"所有 provider 一起连不上"，是当前网络条件所致 —— 按规则如实记在这里，不拿"不是我的代码"收口：**这一条本次没有通过，原因是跑的时候到那些 provider 的网络不通**。
  **第 5 层 冒烟**：Git Bash 跑 `bash test/smoke/run_all.sh`，结果
  ```
  ✓ Build — PASS
  ✗ Analyze — FAIL
  ✗ Checkpoints — FAIL
  ✓ Launch & Verify — PASS
  ✗ Visual Regression — FAIL
  Total: 2 passed, 3 failed
  ```
  **这三步失败不是这次改动造成的，而且有对照**：`test/smoke/output/run.log` 是**追加**写的，里面同时留着改动之前那次（2026-09-20）和这一次的记录，逐项对得上：
  - Analyze：两次的告警清单是同一批 —— `main.dart` 的 `nsCount`（HEAD 里就有这个变量，`git show HEAD:lib/main.dart` 能核到）、`sidecar_bridge.dart` 的 8 条未用字段与 1 条未用栈变量；**本次改动的代码一条告警都没有**（`lib/main.dart` 里新增的那部分、`compaction_plan.dart` 全部干干净净）。
  - Checkpoints：两次都是 `Checkpoint Results: 4 passed, 3 failed`、`3 script(s) failed`。
  - Visual Regression：两次失败的是同三条用例（`capture error state`、`capture message flow`、`capture tool call`，都是 `+1 -3`），通过的也是同一条。
  **本变更动的是压缩投影，跟这三条截图用例的界面状态无关；`Launch & Verify` 这一步是 PASS**（应用能起来）。如实记：**冒烟这一层本次没有全绿，失败的是这三步，且与改动前完全同型**。

## 6. 收口

- [x] 6.1 把实测数字写回 `design.md`：过渡期有多长（2 级从落盘到进投影隔了多少条消息 / 多少 token）、稳态下投影里各档各占多少 token，并据此回答两个待定问题（`2T` 要不要调、过渡期能不能接受）。没有读数就写"未测"，不许拿感觉当依据。

  **已写回 `design.md`**（把原来的 Open Questions 换成了《实测读数》一节，含两张表与三条结论）。要点：
  - 几何：原始 12991 估算 token、总量 8660 ⇒ `T=2165`、`2T=4330`；远端 807 条折成 5 批 1 级（首批 159 条 / 2170 raw），近端 159 条逐字发。
  - 稳态（第二次运行，`All tests passed`）：最远档 1 条 2 级 = **529** token（覆盖 seq 1..483）；中距档 2 条 1 级 = **366 + 410** token；最近档逐字原文 ≈ **2.1k** 估算 token。投影合计约 3.4k vs 原始 12 991（约 26%）。
  - 过渡期：第二次运行 **0 条消息**（那条 2 级落盘时最新端离末尾 6482 > 4330，直接可用）；第一次运行按打印的读数推算只差 **19 个估算 token（约两条消息）**。
  - 两个待定问题的答复：`2T` 先不调（它把顶替推迟约一整批，实测余量 2152 / 差 19，不早也不至于够不着）；过渡期可接受（0 到两条消息）。
  - **如实记未测的一条**：没有量到"第 3 档在投影里能占多大比例"（本次那条 2 级只盖了 3 条 1 级），要回答"2 级能省多少"需要更长的历史。这一条在 `design.md` 里也写明是未测。
- [x] 6.2 同步 `Docs/context-compression-reference.md` 里描述"按距离分层/梯度"的段落，并给出一条能核的判据（grep 得到新口径的原话）。

  **改了两处**：Phase 3 那段（原来只写"recency 梯度作为 segment index+config 纯函数""梯度单调(近详→远略)"）补上投影分档的完整口径；§4.1 测试表里 P3 那一行（原来写"梯度单调(近详→远略)"）改成具体的可失败判据。
  **能核的判据（一条命令）**：
  ```
  Select-String -Path Docs\context-compression-reference.md -Pattern '一条 2 级要等它覆盖的整段都超过 `2T` 才顶替'
  ```
  实测命中第 121 行（这句话整句在同一行，不会被换行切开）：
  ```
  超过 `2T` 才发 2 级摘要。**一段内容只用一种表示**:一条 2 级要等它覆盖的整段都超过 `2T` 才顶替,在那之前这一段由它的 1 级摘要表示 —— 所以"压缩"随时按阈值做(合成与
  ```
- [x] 6.3 逐条核对 delta 里每句 SHALL 都有对应场景与实现覆盖，特别是"每段恰好一种表示、不许重复""2 级要等整段够远才进投影""某档没有摘要时按更细的表示发"三条；贴核对清单（每条 SHALL → 场景 → 任务编号）。

  **核对清单（`specs/context-compaction/spec.md` 的 MODIFIED 两段）**

  第一段《Recency-gradient hierarchical compaction》：

  | 规范里那句 SHALL | 对应场景 | 落在哪条任务 / 怎么实现的 | 能核的判据 |
  |---|---|---|---|
  | 按层级压缩：近原文、中距按段摘要、最远摘要之摘要 | `Recent verbatim`、`Summary of summaries` | 未改（`buildTree` 的两级折卷照旧） | 既有用例全绿（`compaction_projection_test.dart`、`compaction_engine_test.dart`） |
  | 梯度是 history + config 的纯函数；已闭合的分割是固定输入 | （规范既有条文） | 2.1 `distancesFromNewest`（只看原文估算，不看摘要实测大小）；2.2 只改"选哪些已落盘节点"，不改分割 | 单元用例的距离读数；状态 A/B 的跨度断言 |
  | 梯度只由同一个阈值 `T` 推、只按 token；折卷在累计超过 `T` 时立刻发生；不许有条数门槛 | `Recent verbatim` | 未改（`thresholdTokens` 是唯一计算点） | `test/unit/compaction_engine_test.dart` 的阈值与切批用例；6.1/6.2 |
  | 投影按离最新的距离分档，每个档边界都是同一个 `T` 的倍数 | （由下面几条场景合并覆盖） | 2.1 `bandFloorTokens(level, t)` ⇒ `T` 与 `2T`，没有写死的绝对数 | 单元用例：容量 20000 ⇒ 5000 / 10000；40000 ⇒ 10000 / 20000 |
  | 距离按一段**最旧那条消息**算（比它更新的所有原文估算之和），绝不用摘要的实测大小 | （同上） | 2.1 `distancesFromNewest` + `spanIndices` | 单元用例的距离读数（seq1=906 … seq11=0） |
  | 距离 ≤ `T` 发原文、`T`–`2T` 发 1 级、超过 `2T` 发 2 级 | `Recent verbatim` | 2.2/2.3 的按档选表示 | 状态 A（1 级）/ 状态 B（2 级）/ 状态 C（原文） |
  | 一条摘要只有在它盖住的内容**到了它该在的那一档**才顶替；提前压出来的摘要不许提前顶替 | `A level-2 that is not far enough back yet stays out of the projection` | 2.3 phase B/C 的 `sentAsSummary` 门；2.2 里"2 级不够远就不收它" | 状态 A：`1级标记=true 2级标记=false`；6.2 改写后的断言 |
  | 判定单位是**整条摘要盖住的跨度**；每一段恰好一种表示，绝不两种同时出现 | `Once the whole span is far enough…`、`Rolled-up level-1s are not duplicated` | 2.3 的按跨度选表示 + 时间线拼装 | 状态 A/B/C 的 `没有任何表示的 seq=[]` 与 `出现两次的 seq=[]`；4.2 的"互不重叠"不变式 |
  | 一条 2 级要等它盖住的**整段**都到最远档（两端都超过 `2T`）才进投影，在那之前由它的 1 级表示 | `A level-2 that is not far enough back yet stays out of the projection`、`Once the whole span is far enough…` | 2.1 `substitutesSpan` 对 level ≥ 2 查两端；2.2 "2 级不够远 ⇒ 改收它盖住的 1 级" | 单元用例（2 级两端 906/706 对下界 800 ⇒ 判 false）；状态 A/B；5.2 的反例构造 |
  | 某一段还没有摘要时按**更细**的表示发（原文，或它的 1 级），不许发出空档 | `A band with no summary yet falls back to the finer representation` | 3.2 `buildTree` 的未覆盖原文段 + 2.3 的原文回落 | 状态 C（`原文逐条出现的 seq` 含 seq 1 与 40）；状态 B 的 seq 27..30 |

  第二段《Level-2 roll-up is threshold-only and accumulates across folds》：

  | 规范里那句 SHALL | 对应场景 | 落在哪条任务 / 怎么实现的 | 能核的判据 |
  |---|---|---|---|
  | 合成只看一个 token 阈值：从最旧累计**实测** token，首次超过 `T` 就成组 | `Accumulated level-1 tokens exceed the threshold` | 未改（`_resolveSummaries` 的收拢循环 + `l2GroupCount`） | `3.2/3.3` 的 `summarizeTextCalls=1`；`⑪.3 coarsen`；live 的 ④ 段 |
  | 够阈值就够，不等预算、与预算无关；不许有条数门槛 | `The threshold is enough on its own` | 未改；**实现时发现并修掉了一处我自己的回归**：一开始"不够远就一律不收"，把 1 级也从合成输入里拿掉了 ⇒ 6.2 变成一条 2 级都合不出来。现在 1 级（不论够不够远）都参与累加 | 6.2：`L2节点数=1`、`summarizeTextCalls=1` |
  | 只有实测比被替换的那几条更小才接受 | （规范既有条文） | 未改 | `⑪.3 reject-bloated-L2` |
  | 落盘的 1 级在后续轮次仍然可以参与合成，文本复用、不重新生成 | `Accumulation spans folds` | 未改（2.2 只影响"进不进投影"） | `3.4/6.4 跨轮次累加` |
  | 2 级永远不再作为另一条 2 级的输入（只有两级） | `Level-2 is never rolled up again` | 未改 | `3.2/3.3`（`层级2覆盖=[9,12],[1,8]`，原有的那条没被重合成） |
  | （`Level-2 actually reaches the request projection` 场景：够远 ⇒ 必须真的发出去） | 同名场景 | 2.3 | 状态 B：`2级标记=true` 且 `摘要段=1..26`；live 的 ④ 段按同一口径判 |

  **三条重点**逐条落地：①"每段恰好一种表示、不许重复" ⇒ 状态 A/B/C 三条用例各查一次 `没有任何表示的 seq` 与 `出现两次的 seq`（都为空），外加 4.2 的互不重叠不变式与 4.1 的 live 检查；②"2 级要等整段够远才进投影" ⇒ `substitutesSpan` 的 level ≥ 2 分支 + 状态 A + 单元用例 + 5.2 的反例构造（改回旧行为后变红）；③"某档没有摘要时按更细的表示发" ⇒ 状态 C + `buildTree` 的未覆盖原文段（这条同时修掉了 1.1 红态里量到的既有缺陷：seq 27..30 原本在投影里凭空消失）。

## 7. 收尾之后补的验证（我自己承认还缺的三处 + 用户当面问的两个不变量，做完才归档）

> 这几条是"工件里所有任务都勾完之后"才承认的缺口 —— 写在最后是因为没有别的任务依赖它们；但**归档之前必须做完**。写法沿用前面的规矩：先给出能失败的判据，再改代码。


> 这三条是"工件里所有任务都勾完之后"才承认的缺口 —— 写在最后是因为没有别的任务依赖它们；但**归档之前必须做完**。写法沿用前面的规矩：先给出能失败的判据，再改代码。

- [x] 7.1 **投影里"摘要段与原文段交错"时，工具轮不许被拆**：这次把投影从"所有摘要拼成一条前缀消息"改成"按时间交错"，而工具轮（带 tool_calls 的 assistant + 它合成出来的 tool_result）必须成对出现、`tool_use` 与 `tool_result` 一一对应 —— 这条不变量目前**只是论证过**（说段边界落在安全切点上），没有用例。
  **判据**：在 `test/integration/compaction_projection_test.dart` 加一条用例：历史里放一个完整的工具轮，并让投影形成"摘要段 | 原文段 | 摘要段"的交错；断言发出去的 JSON 里每个 `tool_use` 的 id 恰好有一个对应的 `tool_result`、顺序紧跟、且没有相邻的两条 role:user。先跑一次贴输出；**再用变异证明它会红**（把交错拼装改成按消息逐条切，让它把工具轮切开），贴红。

  **已落地**：新增用例 `7.1 投影里摘要段与原文段交错时，工具轮不会被拆`。几何沿用状态 C（库里只有一条不够远的 2 级 [1..40]）⇒ 投影是三段交错的 `[原文 1..40][摘要 41..91][原文 92..130]`；工具轮放在第一段原文里：seq2 是发起调用的 assistant（内容为空、带 tool_use），seq3 是这一轮结束时把同一批 tool_calls 重带一遍的 assistant（生产里两条都真实存在）。
  **先跑（绿）**：
  ```
  [OBS] 7.1 发出去 82 条消息；摘要段=41..91；tool_use=1（第 1 条）tool_result=1（第 2 条）；
        角色序列=user,assistant,user,assistant,assistant,user,…（无 user,user）；
        没有任何表示的 seq=[2]；出现两次的 seq=[]
  ```
  `没有任何表示的 seq=[2]` 是预期的：那条内容为空的工具 assistant 的表示就是那个 tool_use 块；别的 seq 一条不缺。
  **变异（把原文段改成逐条调用 `_buildApiMessages`，等于把工具轮切开）⇒ 红**：
  ```
  [OBS] 7.1 发出去 83 条消息；… tool_use=2（第 3 条）tool_result=2（第 4 条）；…
  Expected: <1>  Actual: <2>
  同一条工具调用只许发一次 —— 工具轮被切开就会发两遍
  00:01 +13 -1: … 7.1 投影里摘要段与原文段交错时，工具轮不会被拆 [E]
  ```
  变异已删掉，删后该文件 `00:02 +20: All tests passed!`。
- [x] 7.2 **某段回落成原文时，容量判定必须按原文算**：我把投影大小的口径改成"会当摘要发的按摘要实测算、回落成原文的按原文估算算"，但没有任何用例钉住它 —— 拿"存下来了、这一趟却不会发"的摘要去抵容量，会导致该省的没省、或者反过来把内容丢掉。
  **判据**：构造一个"库里的 1 级还不够远（这一趟发原文）"、且容量恰好卡在"按摘要算装得下、按原文算装不下"之间的场景；断言这一趟的行为与"按原文算"一致（超出容量时丢弃的是可丢的那些摘要，而不是把已经决定发原文的那一段丢掉）。贴输出；再用变异证明会红（把这条口径改回"一律按摘要实测 token 算"），贴红。

  **已落地**：新增用例 `7.2 某段回落成原文时，容量判定按原文算`。几何：容量 4000（阈值 1000），对话 200 条 × 100 raw；库里预置四条 1 级 —— `[1..60]`/`[61..130]`/`[131..190]` 各实测 1200（起点都够远 ⇒ 当摘要发、可丢），`[191..200]` 实测 100（起点距离 906 ≤ 1000 ⇒ **还不够远** ⇒ 这一趟发 1000 估算 token 的原文、且不可丢）。假摘要器把 2 级报 5000（不小于它要替换的 1200 ⇒ 合成被拒）⇒ 容量压力只能靠丢弃化解，于是"按哪种口径算容量"成了唯一能决定丢不丢的东西。
  **先跑（绿）**：
  ```
  [OBS] 7.2 发出去 11 条消息；摘要段=61..130,131..190；
        没有任何表示的 seq 共 60 个（1..60）；出现两次的 seq=[]
  ```
  `1..60` 被丢是"按原文算"的可观测结果（按原文算 3600+1000+6=4606 > 4000 ⇒ 超容量 ⇒ 丢最旧那条可丢的摘要；丢完 3406 停手）；回落成原文的 `191..200` 一条不缺（用例逐条断言了 191/195/200）。
  **变异（把口径改回"一律按摘要实测 token 算"）⇒ 红**：
  ```
  [OBS] 7.2 发出去 11 条消息；摘要段=1..60,61..130,131..190；没有任何表示的 seq 共 0 个（-）
  Expected: [1, 2, … 60]  Actual: []
  按原文算 ⇒ 超容量 ⇒ 最旧那条够远的摘要被丢…；按摘要实测算就会判定为装得下、什么都不丢，那时这条会红
  00:02 +14 -1: … 7.2 某段回落成原文时，容量判定按原文算 [E]
  ```
  变异已删掉，删后该文件 `00:02 +21: All tests passed!`。
- [x] 7.3 **更长历史下的稳态比例**：目前只跑过两次真模型（历史 12 991 / 13 002 估算 token），量到的都是"一条 2 级 + 几条 1 级"；`design.md` 里"第 3 档能占多大比例"如实写着未测。
  **判据**：用更长的历史跑一次（把展示用例的填充轮数或模型上下文总量调大，让投影里同时出现**多条** 2 级摘要），把"最远档 / 中距档 / 最近档各占多少 token"的读数写回 `design.md`；**跑不动就如实写"仍未测"并说明卡在哪**（缺时间 / 缺额度 / 环境），不许拿推算当读数。

  **已落地**：用的是 2026-09-27 那次展示用例的 live 运行（967 条消息、原始内容 13002 估算 token、总量 5200 ⇒ `T=1300`、`2T=2600`）—— 它的投影里同时有 **2 条 2 级**，第三条 2 级因为最新端只离末尾 1274 raw（没到 2600）而**没进投影**、那一段改由它的三条 1 级表示。读数已写回 `design.md` 的《实测读数》一节：
  - 最远档（2 级）**941** token（两条：467 + 474），中距档（1 级）**1416**（368 + 451 + 597），最近档（逐字原文）约 **837**；
  - 投影合计约 **3194** token vs 原始 13 002 ⇒ 约 **25%**，三档之比约 **29% : 44% : 26%**。
  所有数字都能追溯到展示用例打印的 `[OBS] 摘要 level=… token=…` 与 `[VERDICT] …按档分…` 两行（日志在 `%TEMP%\band_live_demo2.txt`，同一次运行的截图是 `test/live_visual/show_compaction_live.png`）。
  **仍然未测的**（如实写进 `design.md` 了）：只有两次真模型读数，"最远档会不会随历史继续变长而继续变大"没有量到。
- [x] 7.4 **已经被压过的原文不会再进折卷；库里同等级的摘要跨度互不重叠**（2026-09-30 用户当面问的两个不变量，补成常驻守卫）。
  **为什么补**：用户问"同等级摘要覆盖的段落会不会重叠""会不会对压缩过的原文再做压缩"。当时的答案是"不会"，靠的是三处构造（尾部从"所有已落盘节点覆盖到的最远 seq"之后开始；2 级只从相邻的一串 1 级合成；载入/投影那一侧再贪心去重），并且我只在展示用例那次运行的库上**手工查过一遍**（9 条 1 级 `1..93…776..873`，同级重叠 0 对）。手工查不算守卫，所以把这两条钉成用例。
  **判据**：`test/integration/compaction_projection_test.dart` 新增用例 `7.4`：库里预置两条 1 级（`1..4`、`5..8`），这一趟的可折尾部必须从 seq 9 起；断言 ①摘要器**实际收到的每一批**都不碰这两段（用真实调用记录，不是从计划里推的）；②同趟各批互不重叠；③库里新落的 1 级不碰已有 1 级；④库里同级摘要（1 级之间、2 级之间）两两不重叠。先跑一次贴输出，再用变异证明会红。
  **先跑（绿）**：
  ```
  [OBS] 7.4 摘要器收到的批次=9..19；库里新落的 1 级=9..19（另有预置的 1..4、5..8）；库里的 2 级=；
        折卷批次碰到预置段落=null；新落的 1 级碰到预置段落=null；同级 1 级互相重叠=null；同级 2 级互相重叠=null
  ```
  **变异（把 `buildTree` 里那个"已覆盖到哪"的上界换成 -1，等于假装没有任何已覆盖内容）⇒ 红**：
  ```
  [OBS] 7.4 摘要器收到的批次=1..11；库里新落的 1 级=1..11（另有预置的 1..4、5..8）；
        折卷批次碰到预置段落=(hi: 11, lo: 1)；新落的 1 级碰到预置段落=(hi: 11, lo: 1)；同级 1 级互相重叠=(hi: 4, lo: 1)
  Expected: null  Actual: ({int hi, int lo}):<(hi: 11, lo: 1)>
  已经被压过的原文（预置的 1..4 / 5..8）不许再进折卷 —— 尾部必须从 seq 9 起
  ```
  正是"同一段被压第二次"的现场：折卷重新吃进了 seq 1..8、库里多出一条 `1..11` 与已有的 `1..4` 重叠。变异已删掉。
  **这条守卫覆盖到与没覆盖到的（如实记）**：它钉的是"折卷输入不许碰已覆盖的跨度 + 库里同级不许重叠"；**没有**单独区分"上界取自所有已落盘节点"与"只取这一趟进投影的那些"（当前这套几何里预置的两条都够远、都会被投影，两者取值相同）。那个区别要靠"还不够远的节点"才会显出来，等以后有这种几何的用例再补。

