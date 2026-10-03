## 1. 先写出会失败的判据（红态）

- [x] 1.1 **后台压缩这条路径**：在 `test/integration/background_fold_test.dart` 里复用已有的那两个现成条件 —— 摘要生成能被卡在 `Completer` 上的假摘要提供者，以及 `backgroundFoldEnabled: true` 的那套 harness —— 新增用例：压缩被卡住期间，断言对话视图里出现压缩提示；放行之后断言提示消失。
  **判据**：先只写"界面上有没有那句提示"这一条断言（它不依赖任何新 API，现在就能编译、现在必然找不到），在**没改产品代码**之前跑这条用例，必须失败，把红态实际输出贴在这条下面。读状态的断言（"期间非空闲、结束回空闲"）等 2.2 把 getter 加上之后再补进同一个用例。

  **红态实测（改产品代码之前，`flutter test test/integration/background_fold_test.dart --plain-name "压缩期间对话视图出现提示"`）**：
  ```
  [OBS] 启动后 banner=0 [expect 0]
  [OBS] 未触发压缩的发送之后 banner=0 summarizeCalls=0 [expect 0 / 0]
  [OBS] 后台压缩卡住期间 banner=0 summarizeCalls=1 文案="" [expect banner=1]
  Expected: exactly one matching candidate
    Actual: _KeyWidgetFinder:<Found 0 widgets with key [<'compaction-status-banner'>]: []>
  压缩正在跑，对话视图必须出现提示
  ```
  这条红的现场是真的：后台压缩**已经跑到生成摘要那一步**（`summarizeCalls=1`，只有它可能把这个计数加上去），而界面上一个提示都没有 —— 正是本变更要修的那件事。用例里同时有"没触发压缩的发送不许出现提示"这条断言，它在旧代码上通过（当时提示根本不存在），它的可失败性由 5.1 的变异证明。

- [x] 1.2 **发送前那条路径 + 不该出现的情形**：在 `test/integration/compaction_projection_test.dart` 新增两条用例：
  - ①历史已经超过阈值、这次发送要生成新摘要，摘要被卡住期间提示必须出现；
  - ②历史很短、这次不需要压缩的普通发送，整场断言提示**从未出现**。
  **判据**：同样先跑红（①找不到提示；②在现在的代码上会"通过"，如实记下它是**恒真**的 —— ②的可失败性由 5.1 的变异自检证明）。

  **红态实测（改产品代码之前，`flutter test test/integration/compaction_projection_test.dart --plain-name "压缩提示 · "`）**：
  ```
  [OBS] 发送前 banner=0 [expect 0]
  [OBS] 压缩卡住期间 banner=0 summarizeCalls=1 已发给模型=false 文案="" [expect banner=1]
  Expected: exactly one matching candidate … 压缩正在进行，对话视图必须出现提示
  [OBS] 未触发压缩的发送：summarizeCalls=0 banner=0 已发给模型=true [expect 0 / 0 / true]
  ```
  ①红的现场是真的：摘要**已经在生成**（`summarizeCalls=1`）、请求**还没发出去**（`已发给模型=false`），界面却一个提示都没有 —— 用户就卡在这段什么都没有的时间里。②如预期在旧代码上通过（那时提示根本不存在），它的可失败性由 5.1 证明。

- [x] 1.3 **组件层判据**：`test/widget/context_view_test.dart` 新增用例 —— 直接传入"压缩中"的状态，断言这一屏顶部出现提示、提示里写明这是**上一次实际发出的内容**；再断言空闲状态下该组件不渲染内容、尺寸为零。
  **判据**：现在编译不过（组件与状态都还没有），把编译失败的实际输出贴出来当红态。

  **红态实测（`flutter test test/widget/context_view_test.dart`，整个文件加载失败）**：
  ```
  Error when reading 'lib/models/compaction_status.dart': 系统找不到指定的文件。
  test/widget/context_view_test.dart:362: Error: Undefined name 'CompactionStatus'.
  test/widget/context_view_test.dart:362: Error: No named parameter with the name 'status'.
  lib/ui/context_view.dart:27: Context: Found this candidate, but the arguments don't match.
    const ContextView({super.key, this.snapshot});
  ```
  "空闲不占位"这条没有写成"尺寸为零"，而是写成**更强的对照**：空闲时首条消息的 y 坐标，必须与"根本不传这个组件状态"时完全一样 —— 组件要是留了空白高度，这个比较立刻不等（5.3 的变异就是照这条设计的）。

- [x] 1.4 **真实上下文视图在压缩期间的内容边界**：在 `test/integration/` 里新增一条端到端用例：摘要被卡住期间切到真实上下文视图，断言 ①提示在、②这一屏里找不到假提供者正在生成的那段摘要文本、③还没有任何快照时提示与 `尚无捕获的上下文快照` 占位并存。
  **判据**：先跑红（①③找不到提示）。②是一条**边界**断言：它必须在 4.3 接入之后仍然通过，且被 5.x 的变异证明它可以失败（若构造不出失败状态，就在这条下面写明"未能证明此检查可失败"）。

  **红态实测（改产品代码之前，`flutter test test/integration/compaction_projection_test.dart --plain-name "压缩提示 · 真实上下文视图"`）**：
  ```
  [OBS] 前两轮之后：summarizeCalls=0 已发给模型=true banner=0 [expect 0 / true / 0]
  [OBS] 第 3 轮之前：库里 8 条、估算 raw=1419（阈值 1000，超了才会压）；
        每条"字符数/估算 raw"=381/100 381/100 381/100 381/100 5/6 2000/504 4/5 2000/504
  [OBS] 压缩期间真实上下文视图：banner=0 summarizeCalls=1 有"grow2"=0 有摘要标记=0 文案=""
  Expected: exactly one matching candidate … 压缩正在进行，这一屏顶部必须有提示
  [OBS] 首次发送压缩期间：banner=0 占位=1 summarizeCalls=1 [expect 1 / 1]
  ```
  两条红都是"压缩真的在跑（`summarizeCalls=1`）而这一屏没有任何提示"。

  ②（压缩中不许出现新摘要标记）在旧代码上通过，但**不是恒真**：同一条用例在放行之后用**同一个 finder** 断言标记必须出现（`有摘要标记` ≥1），所以"压缩中找不到"是因为那时确实还没发出去，而不是因为这个 finder 在这份几何下永远找不到。

  **顺带记两个实测踩到的坑**（都写进了用例注释）：
  - 发送前这条路径读的是**界面上那串消息**（`_chatItemsToMessages`），往库里塞消息对它**无效**（那只对后台那条路径有效，`background_fold_test.dart` 用的是那个办法）。所以这条用例靠两轮长回复把界面上的历史撑过阈值。
  - `FakeSidecar` 每次 `sendMessage` 只消费到**第一个 done**：构造时预置的那份回复会被第 1 轮吃掉，后面几轮的回复长度就跟预期对不上 —— 实测第一次跑量出的 raw 是 921 而不是算出来的 1419，原因就在这里。改法：不要在构造时预置，每一轮发之前现排队。

## 2. 状态模型与单点持有

- [x] 2.1 新增 `lib/models/compaction_status.dart`：空闲态常量；三个阶段（挑选分段主题 / 生成一级摘要 / 合成二级摘要）；已完成数与总数（总数可为空）；给出界面文案 —— 总数已知时写"第 k 段，共 n 段"，未知时只写"已完成 k 段"；给一个空闲判断。
  **判据**：新增 `test/unit/compaction_status_test.dart`，断言两种总数情形下的文案与空闲判断；把某条用例的总数从 9 改成空，它的期望文案必须随之不同（证明这条检查不是恒真）。

  **实现与实测（`flutter test test/unit/compaction_status_test.dart`，5 条全过）**：
  ```
  [OBS] idle.isIdle=true label=null note=null
  [OBS] seam: label="正在挑选分段主题" note=null
  [OBS] 后台: label="正在压缩较早的对话：正在生成第 1 段摘要，共 9 段" note="你发消息会让压缩先让路"
  [OBS] 总数已知: "正在压缩较早的对话：正在生成第 3 段摘要，共 9 段"；总数未知: "正在压缩较早的对话：正在生成第 3 段摘要"
  [OBS] level2: "正在把一级摘要合成二级摘要：正在生成第 2 段，共 3 段"
  ```
  **落实现时改了措辞（原文写的"已完成 k 段"，实现是"正在生成第 k 段"）**：字段只留一个含义 = 正在生成第几段（从 1 开始），总数已知才补"，共 n 段"。设计里"未知时只显示已完成数"这句已同步改成"只显示正在生成第几段，不编造分母"（spec 的同一条也同步改了）。

- [x] 2.2 `ChatScreenState` 持有该状态并提供只读 getter（与既有的上下文快照 getter 同一做法）；空闲时用 2.1 的常量，不每次重建。
  **判据**：1.1 里"压缩期间状态非空闲、放行后回到空闲"的两条断言转绿。

  **实测**：`_compactionStatus` 字段 + `compactionStatus` getter 与既有的 `contextSnapshot` 并排；改状态统一走 `_setCompactionStatus`（带 `mounted` 判断，见 3.4）。
  ```
  [OBS] 压缩期间状态：isIdle=false label="正在压缩较早的对话：正在生成第 1 段摘要，共 4 段" note="你发消息会让压缩先让路"
  [OBS] 结束后状态空闲=true 文案=null
  ```

## 3. 两条路径的置位与清除

- [x] 3.1 逐段生成摘要那一处（`lib/main.dart` 的 `_resolveSummaries`）：进入时置位为"生成一级摘要"，每完成一段把已完成数加一，`finally` 里清空**并触发界面重画**（带 `mounted` 判断）。
  **判据**：1.1、1.2① 的"卡住期间提示在、状态非空闲"转绿；1.1 的"放行后回到空闲"转绿。

  **落实现时的结构（与任务原文略有出入，如实记下）**：把 `_resolveSummaries` 拆成两层 —— 外层只做一件事：`try { 内层 } finally { 状态回空闲 }`；内层是原来的全部逻辑，在"每开始一条摘要段"和"每次合成二级摘要"两处推进状态。这样"四种结束都要回到空闲"只需要在一处保证，不必在每个出口各写一遍。
  **实测（同一批用例）**：
  ```
  [OBS] 压缩卡住期间 banner=1 summarizeCalls=1 已发给模型=false 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 1 段"
  [OBS] 放行之后 banner=0 已发给模型=true [expect 0 / true]
  [OBS] 后台压缩卡住期间 banner=1 summarizeCalls=1 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 4 段 | 你发消息会让压缩先让路"
  ```
  `已发给模型=false` 这一条是顺带量到的：压缩期间请求**还没发出去**，用户等的是压缩而不是模型。

- [x] 3.2 挑选分段主题那一处（`_prepareSeamChooser`）：只在 `CompactionEngine.resolveFoldSeamInputs` 返回非空（这次确实有远端内容要压）时才置位，阶段写成"挑选分段主题"。
  **判据**：新增一条用例 —— 历史没到阈值时该函数返回空，整场无提示；到阈值时才有提示。两次运行的实际读数（返回空 / 非空）贴在用例的输出里。

  **落实现时加了一个更强的闸门**：`resolveFoldSeamInputs` 非空只说明"这次有内容要压"，但分段选择那一步在**热缓存**时不会发请求（`SeamSelector.ensure` 命中 memo 直接返回），所以还要求 `memoizedSeams(...) == null`（冷缓存）才亮。两条用例分别钉住这两面（`test/integration/compaction_projection_test.dart`，两条全过）：
  ```
  [OBS] 分段选择卡住期间：banner=1 ensures=1 summarizeCalls=0 文案="正在挑选分段主题"
  [OBS] 分段选完之后：banner=1 summarizeCalls=1 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 1 段"
  [OBS] 全部放行之后：banner=0 [expect 0]
  [OBS] 热缓存期间：ensures=1 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 1 段" [expect 有"生成第 1 段摘要"、没有"挑选分段主题"]
  ```
  第一次跑红是**我自己的假选择器写错了**：`_GatedSeamSelector.memoizedSeams` 一开始返回 `const []`（非空 = 热缓存），于是冷缓存那条永远不亮 —— 界面提示没问题，是我的假对象不符合接口约定（"`ensure` 没跑过这个键时返回 null"）。改成先返回 null、`ensure` 之后才返回 `const []`，两条就都对了。

- [x] 3.3 后台压缩的每条出口都要回到空闲：无事可做提前返回、成功、抛异常、被用户发送打断。`_foldInFlight`（后台折叠的内部标志）**不是**界面状态，单独检查它不要被当成状态来源。
  **判据**：新增一条"历史很短、后台压缩无事可做"的用例（`backgroundFoldEnabled: true`，等过 2 秒防抖），断言整场无提示、状态始终空闲。

  **实测**：`test/integration/background_fold_test.dart` 新增该用例，与既有的"打断"用例（`a user send during a background fold fires the preempt path`）一起覆盖出口。
  ```
  [OBS] 后台压缩无事可做：summarizeCalls=0 banner=0 状态空闲=true [expect 0 / 0 / true]
  ```
  状态来源只有 `_compactionStatus` 一处，`_foldInFlight` 没有被读进界面（它是后台折叠的调度标志，结束时连界面都不重画 —— 这正是当初不能拿它当界面状态的原因）。

- [x] 3.4 界面销毁安全：压缩期间销毁界面不得抛 `setState() called after dispose`。
  **判据**：在 1.1 的用例末尾卡住摘要的状态下换成另一个空界面，断言没有异常抛出。

  **实测（这条判据第一版是假的，构造变异时才发现的）**：写成独立用例 `压缩提示：压缩期间界面被销毁，收尾不许抛异常`（后台路径，卡住摘要 → `pumpWidget(const SizedBox())` 销毁界面 → 放行压缩）。
  - 第一版断言是"测试没红即通过"。**变异 5.4**（去掉 `_setCompactionStatus` 的 `mounted` 判断）跑出来：`setState() called after dispose()` **确实抛了**，但被后台折叠自己的 `catch` 吞掉，只留下一行日志 —— 测试照样绿。也就是说那条断言在缺陷仍在时也通过，是假通过。
  - 改成：接管 `debugPrint`，断言日志里**没有** `called after dispose`。同一变异下现在会红：
  ```
  [OBS] 界面已销毁、压缩已放行：日志 1 行，其中含"called after dispose"的 1 行
        (第一条="[AliasAgent] background fold aborted for session s1: setState() called after dispose(): ChatScreenState#cd471(lifecycle state: defunct, not mounted)")
  Expected: empty
  ```
  还原 `mounted` 判断后转绿（同一行读数变成 0 行，日志第一条是正常的折叠完成信息）。
  - 还原调试变量必须发生在**测试体里面**（`try/finally`），不能用 `addTearDown`：框架在测试体结束后会校验"没有调试变量被改过"，放 `addTearDown` 里太晚，实测报 `The value of a foundation debug variable was changed by the test`。

## 4. 界面

- [x] 4.1 新增 `lib/ui/compaction_status_banner.dart`：两个视图共用的组件；空闲时返回 `SizedBox.shrink()`（不留高度、不加分隔线）；非空闲时显示阶段 + 进度；后台压缩时补一句"你发消息会让压缩先让路"；真实上下文视图那一份补一句"下面是上一次实际发出的内容，压缩结果下次发送时才出现"。
  **判据**：1.3 的组件用例转绿（含空闲尺寸为零）。

  **实测（`flutter test test/widget/context_view_test.dart`，4 条全过）**：
  ```
  [OBS] 空闲：提示节点数=0 提示高度=0.0 首条消息 y=164.0；不传状态：y=164.0
  [OBS] 压缩中：提示节点数=1 首条消息 y=209.0（空闲时 164.0）
  ```
  两个视图共用这一个组件（key `compaction-status-banner`），差别只在真实上下文视图那份多显示一句附注。

- [x] 4.2 `lib/ui/chat_area.dart`：新增参数接收状态，固定在输入框上方渲染。
- [x] 4.3 `lib/ui/context_view.dart`：新增参数接收状态，固定在这一屏顶部渲染；还没有快照时与既有占位并存。
- [x] 4.4 `lib/main.dart`：把状态传进两个视图。
  **判据**：4.2–4.4 一起由 1.1、1.2、1.4 转绿来验收 —— 三条用例分别覆盖对话视图（后台路径）、对话视图（发送前路径）、真实上下文视图。

  **实测（`test/integration/compaction_projection_test.dart` 与 `background_fold_test.dart`，4+5 条全过）**：
  ```
  [OBS] 压缩期间真实上下文视图：banner=1 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 1 段 | 下面是上一次实际发出的内容，压缩结果下次发送时才出现"
  [OBS] 放行之后：banner=0 已发给模型=true 有摘要标记=1 [expect 0 / true / >=1]
  [OBS] 首次发送压缩期间：banner=1 占位=1 summarizeCalls=1 [expect 1 / 1]
  ```
  参数名与模型字段对齐后的实际签名：`ChatArea.compactionStatus`、`ContextView.compactionStatus`、`CompactionStatus.level1(segment:, total:)`（建模时先按任务里的 `status:` / `done:` 写，落到实现时统一改名，用例同步改）。

## 5. 反例自检（证明这些断言真的能失败）

- [x] 5.1 变异一：把置位改成从"正在发送"（`_isStreaming`）推断。
  **判据**：1.2② 必须变红（普通发送也显示提示）；把红的实际输出贴在这条下面，然后还原。

  **实测（在 `_sendMessage` 置 `_isStreaming` 的同一个 `setState` 里把状态设成"压缩中"）**：
  ```
  Which: means one was found but none were expected
  没触发压缩的普通发送不许出现压缩提示
  ```
  1.2② 如期变红 —— 这条断言不是恒真。还原后转绿。
- [x] 5.2 变异二：去掉 `finally` 里的清除（或去掉那一次重画）。
  **判据**：1.1 的"放行后回到空闲"必须变红；贴输出后还原。

  **实测（注释掉 `_resolveSummaries` 外层的 `_setCompactionStatus(CompactionStatus.idle)`）**：
  ```
  压缩结束后提示必须消失
  Expected: no matching candidates / Actual: found 1 widget with key [<'compaction-status-banner'>]
  ```
  1.1 如期变红（提示挂在界面上不消失）。还原后转绿。
- [x] 5.3 变异三：空闲时返回一个有高度的空容器（例如固定高度的 `SizedBox`）。
  **判据**：1.3 的"空闲不占位"必须变红；贴输出后还原。

  **实测（空闲分支改成 `SizedBox(height: 30)`）**：
  ```
  [OBS] 空闲：提示节点数=0 提示高度=30.0 首条消息 y=194.0；不传状态：y=194.0 [expect 0 / 0.0 / 两者相同]
  Expected: <0>
    Actual: <30.0>
  空闲态不许占位：这个组件自己的高度必须是 0（留了空白高度就是占了位置）
  ```
  **这条变异顺带证明我最初那版判据是假的**：原来只比较"显式空闲态"与"不传状态"时首条消息的 y，两者在变异下都是 194.0 —— 两边一样，断言照样通过。改成直接量这个组件自己的高度（必须为 0）之后，变异立刻红。改前 / 改后：
  - 改前：`expect(noParamTop, idleTop)`（只证明默认值等于空闲态，证明不了"不占位"）
  - 改后：`expect(idleHeight, 0)`（直接量高度）+ 保留原比较当"默认值是空闲态"的一致性检查
- [x] 5.4 三处变异跑完立刻还原：`git diff` 里不许留任何变异痕迹（搜 `MUTATION` 应为零命中），并把三次红的实际输出记在 5.1–5.3 下面。

  **实测**：三次变异都已还原；`Select-String -Pattern 'MUTATION'` 在 `lib/` 与 `test/` 下零命中（另有一处 `browser_worker_test.dart` 里早就存在的英文 "mutation testing" 注释，不是本次留下的标记）。另加做了第四处变异（去掉 `mounted` 判断），记在 3.4 下面 —— 它抓出的是一条**假通过的判据**，比原计划的三处更值。

## 6. 收尾验证（逐层跑，一次只做一件）

**执行顺序说明**：6.3（live）/ 6.4（C++）/ 6.5（冒烟）挪到第 7 组（文档）之后才跑 —— 它们是跑在**最终代码**上的端到端验收，文档改完再跑才不会作废。6.1 / 6.2 按原顺序先跑。

- [x] 6.1 `flutter analyze` —— 改动文件不得新增问题，把实际输出贴出来。

  **实测**：`171 issues found`（改之前是 175，少掉的 4 条正是我一开始故意留着的 3 条编译错误 + 1 条连带）。改动文件里只剩两条**既有**条目：
  ```
  warning - The value of the local variable 'nsCount' isn't used - lib\main.dart:2780:11
  info - Don't invoke 'print' in production code - test\widget\context_view_test.dart:95:3
  ```
  两条都在本次改动之前就存在（`nsCount` 是旧账，`avoid_print` 是那个文件里原有的 `_dumpVisibleTexts` 打印）。
- [x] 6.2 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 之后跑**全量** `flutter test`，贴出末尾统计行。

  **实测**：`SYNC-OK: sidecar.dll already current`；全量
  ```
  00:23 +275: All tests passed!
  ```
  （改之前是 +260，新增 15 条：状态模型 5 条、组件层 4 条里的新增 1 条、后台路径 3 条、投影/真实上下文 6 条。）
- [x] 6.3 **live 与视觉验收**：`integration_test/` 新增一条 live 用例 —— 用真实模型触发一次压缩，轮询到状态非空闲后各截一张图到 `test/live_visual/`（对话视图、真实上下文视图各一张）；然后 `flutter test --tags live --run-skipped integration_test/<新用例> -d windows` 跑它，并用 `read_image` 逐张读 PNG 确认两张图里都能看到提示。只看 "All tests passed" 不算过；几十秒的压缩窗口没抓到就如实记"未截到"，不算通过。

  **实测**（这一条最初写成**新开一个独立 live 文件**；后按 6.6 合并进既有的压缩 live 用例，那个独立文件已删除。下面是合并之前那次独立运行的现场，原样保留 —— 里面的截图名是当时的命名，合并后的名字见 6.6）：`05:12 +1: All tests passed!`
  ```
  [OBS] 预置历史 965 条、原始内容 12979 估算 token；模型上下文总量设为 5191 ⇒ 阈值 1297
  [OBS] 对话视图上抓到提示：正在挑选分段主题
  [SHOT] captured test/live_visual/compaction_status_conversation.png (64474 bytes)
  [OBS] 真实上下文视图上抓到提示：正在挑选分段主题 | 下面是上一次实际发出的内容，压缩结果下次发送时才出现
  [SHOT] captured test/live_visual/compaction_status_real_context.png (23558 bytes)
  [VERDICT] 抓到对话视图提示=true；抓到真实上下文提示=true；库里 1 级摘要 5 条、2 级摘要 0 条
  ```
  **视觉验收（read_image 逐张读过）**：
  - `compaction_status_conversation.png`（1266×683）：输入框正上方一条浅紫提示带，左边转圈，文字"正在挑选分段主题"；上面是对话内容。
  - `compaction_status_real_context.png`（1266×683）：这一屏顶部同样的提示带，第一行"正在挑选分段主题"，第二行"下面是上一次实际发出的内容，压缩结果下次发送时才出现"；下面正是"尚无捕获的上下文快照"占位（这是本次会话的第一条消息，还没有发出去过）—— 提示与占位并存，与规范里那条场景一致。
  - 顺带一条实测：生产路径上真的会走到"挑选分段主题"这一步（不是只在测试里出现的分支）—— 真模型下第一次发送抓到的那一刻就是这个阶段。
- [x] 6.4 C++ 本次未改动：`cmake --build sidecar/build/windows --config Debug` 与 `ctest --test-dir sidecar/build/windows -C Debug` 各跑一次，确认没被连带影响，贴出统计行。

  **实测**：构建通过（`sidecar.dll` / `sidecar_tests.exe` 都出来了）；ctest
  ```
  test cases:  237 |  236 passed | 1 failed
  assertions: 3739 | 3738 passed | 1 failed
  ```
  唯一失败项是**联网 live 用例**：`search_provider_test.cpp` 的 "Rate guard: rapid-fire 5 consecutive ZhipuAI searches"，日志里是 5 条 `ZhipuAI: connection error — Could not connect to server`（SearXNG 同样 unavailable）。归属依据：①本次改动一个 C++ 文件都没碰（`git status` 里只有 Dart / Markdown）；②失败原因是连不上外部服务；③条数与上一轮记录完全一致（237 / 236 / 1）。
- [x] 6.5 冒烟 `test/smoke/run_all.sh`：确认空闲态没有改变既有布局 —— 失败项与本改动之前完全一致（本改动之前视觉回归本来就有 3 个失败截图用例），不得新增失败。

  **实测**（用 Git Bash 跑：`& "C:\Program Files\Git\bin\bash.exe" -lc "cd /e/Projects/AliasAgent && bash test/smoke/run_all.sh"` —— WSL 的 bash 里没有 `sqlite3` / `powershell`，会直接 ABORTED，这一步也如实记下来）：
  ```
  ✓ Build — PASS      ✗ Analyze — FAIL     ✗ Checkpoints — FAIL
  ✓ Launch & Verify — PASS   ✗ Visual Regression — FAIL
  Total: 2 passed, 3 failed
  ```
  视觉回归仍是那 3 个**既有**失败用例（`capture empty state` 过、`message flow` / `tool call` / 另 1 个红）。三次运行的读数（run.log 里前后两轮 + 本轮）：`2.75% / 4.58% / 12.99%` → `2.75% / 4.57% / 12.99%` → **本轮 `2.75% / 4.32% / 12.93%`**，同一批用例、同一量级，没有新增失败项。**本改动不可能出现在这些截图里**：`integration_test/screenshot_test.dart` 注册的 agent 没有设 `max_context_tokens`，压缩根本不会跑，提示也就无从渲染（归属依据，不是"感觉无关"）。

- [x] 6.6 **返工：live 验收改成与既有的压缩 live 用例共用（2026-10-02 用户指出）**。6.3 原先把它写成了**新开一个 live 文件**（`integration_test/compaction_status_live_test.dart`），用户当场指出「应该直接和压缩的测试共用一个测试就行吧？」。
  **这条返工的起因要如实记下**：我当时**没有先写任务就直接改了测试**（把断言合并进既有 live 用例、并把独立文件删掉），用户指出「你这次直接改测试没先写工件，你越界了」。按 `CLAUDE.md`「代码必须对应 tasks.md 任务」的做法处理：先把那批无任务的改动**回退**（`git restore integration_test/compact_quality_live_test.dart`，删掉新加的守卫测试；独立文件当时也一并被删，因此它按本条任务重新落成"合并进既有用例"的形态），再作为本条任务干净重写。
  要做的事：
  - 合并进既有的 `integration_test/compact_quality_live_test.dart`：给它已有的等待函数 `pumpUntilReplyOrTurnDone` 加一个 `onTick` 钩子（**不复制**它的等待逻辑），在等待期间第一次看到提示时就地取证 —— 截 `compact_quality_status_conversation.png`，切到「真实上下文」再截 `compact_quality_status_real_context.png`，然后切回来；断言对话视图那句含"正在"、真实上下文那句含 `CompactionStatusBanner.contextViewNote`。
  - 同一条用例里顺手把**空闲自动**那条路径也验掉（⑤只覆盖"发送前"那次）：往库里塞一批消息（后台压缩读的是库，不是界面上那串消息），什么都不做等它自己压起来，抓到提示截 `compact_quality_status_background.png`，并断言提示里有"你发消息会让压缩先让路"。
  - 用例超时从 300 秒放宽到 900 秒（多了一段空闲压缩）；文件头写清这条用例现在覆盖三件事（摘要质量 / 发送前提示 / 空闲自动提示），满足"共用时必须写清它覆盖哪几件事"。
  **判据 ①**：`flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows` 全绿，且 `[OBS] ⑤` 与 `[OBS] ⑥` 都打印出抓到的提示原文；跑完用 `read_image` 读三张 PNG 确认画面里真有那条提示。
  **判据 ②（返工前的状态必须能红）**：把 `onTick` 那段去掉再跑，⑤ 的"压缩进行中，对话视图上必须能看到提示"必须红 —— 否则这两条断言是恒真的。

  **判据 ①实测（`00:56 +1: All tests passed!`）**：
  ```
  [OBS] ⑤ 压缩进行中，对话视图上抓到提示：正在挑选分段主题
  [SHOT] captured test/live_visual/compact_quality_status_conversation.png (72626 bytes)
  [OBS] ⑤ 同一时刻真实上下文视图上的提示：正在挑选分段主题 | 下面是上一次实际发出的内容，压缩结果下次发送时才出现
  [SHOT] captured test/live_visual/compact_quality_status_real_context.png (23572 bytes)
  [OBS] ⑥ 空闲自动压缩期间，对话视图上的提示：正在挑选分段主题 | 你发消息会让压缩先让路
  [SHOT] captured test/live_visual/compact_quality_status_background.png (71513 bytes)
  [VERDICT] ⑥ 空闲自动压缩：抓到提示=true；库里摘要条数 6 → 6
  ```
  三张图都 `read_image` 看过：对话视图那张是输入框上方一条提示带（转圈 + "正在挑选分段主题"）；真实上下文那张是顶部固定的两行提示带（第一行"正在挑选分段主题"，第二行"下面是上一次实际发出的内容，压缩结果下次发送时才出现"），下面是"尚无捕获的上下文快照"占位；空闲自动那张是两行"正在挑选分段主题" + "你发消息会让压缩先让路"。
  **判据 ②实测**（在 `onTick` 开头插一句直接返回，其余不动）：
  ```
  [OBS] ⑤ 对话视图抓到提示=false（""）；真实上下文视图抓到提示=false（""）
  Expected: true
    Actual: <false>
  ⑤ 压缩进行中，对话视图上必须能看到提示 —— 几十秒的压缩窗口没抓到就是"未截到"，不算通过
  00:50 +0 -1: Some tests failed.
  ```
  还原后转绿（即上面判据①的那次）。

  **补充（2026-10-02，8.13 要求的一句话）**：`test/live_visual/` 是 gitignore 的，而且这个 live 用例的 `setUp` 会调 `clearLiveVisualDir()` **清空该目录** —— 所以上面点名的 PNG 会被**下一次 live 运行**删掉（复核时若发现文件不在，就是又跑过一次 live，重跑 8.9 即可重新留图）。8.9 那次跑完留下的四张：`compact_quality_status_conversation.png`（72691 字节）、`compact_quality_status_real_context.png`（23643）、`compact_quality_status_background.png`（86970）、`compact_quality_live.png`（60876），四张都 `read_image` 看过。

- [x] 6.7 **给"提案必须有测试"加一条守卫（2026-10-02 用户要求）**。用户当场要求：「以后所有新功能的添加都应该有能反映它的测试用例，可以多个功能共用一个测试，但是不允许没有测试」「添加测试应该是所有 proposal 的硬性要求」。规则已按用户指令写进 `CLAUDE.md`（"不许有'没有测试的新功能'"那条），再把它做成一条会失败的守卫：新增 `test/unit/openspec_proposal_test.dart` —— 每个还没归档的 change（`openspec/changes/<名字>/` 顶层且含 `.openspec.yaml`，不含 `archive/`），其 `tasks.md` 里必须出现测试层路径（`test/unit` / `test/widget` / `test/integration` / `integration_test` / `sidecar/test` / `test/smoke` 之一），否则红；一个活跃 change 都没有时如实打印"这是空集，不是通过"。
  **判据**：①正常跑绿，并打印活跃 change 名单与各自命中几处（贴输出）；②反例自证 —— 临时造一个"没有测试路径"的活跃 change（一份 `.openspec.yaml` + 一份不提任何测试的 `tasks.md`），这条必须红，贴出红态输出后**立刻删掉**那个临时目录（`git status` 里不留痕迹）。

  **判据 ①实测（`00:00 +2: All tests passed!`，两条用例：真仓库扫描 + 临时目录反例自证）**：
  ```
  [活跃 change] 2 个：[add-compaction-status-indicator, fix-browser-newtab-follow]
  [测试层路径] add-compaction-status-indicator：命中 28 处，例如 test/integration ← - [x] 1.1 **后台压缩这条路径**…
  [测试层路径] fix-browser-newtab-follow：命中 5 处，例如 test/integration ← - [ ] 1.1 在 `test/integration/browser_worker_test.dart` 新增一条…
  [反例] 假 change 命中测试层路径 0 处（期望 0）
  ```
  **判据 ②实测**（真在 `openspec/changes/zz-probe-no-tests/` 造了一份不提测试的活跃 change 再跑）：
  ```
  [活跃 change] 3 个：[add-compaction-status-indicator, fix-browser-newtab-follow, zz-probe-no-tests]
  [测试层路径] zz-probe-no-tests：命中 0 处
  Expected: empty
    Actual: ['zz-probe-no-tests']
  这些还没归档的 change，tasks.md 里没有任何一处提到测试层路径（test/unit / test/widget / test/integration / integration_test / sidecar/test / test/smoke 之一）：[zz-probe-no-tests] —— 按 CLAUDE.md，添加测试是所有 proposal 的硬性要求…
  00:00 +1 -1: Some tests failed.
  ```
  删掉那个临时目录后重跑转绿（`+2: All tests passed!`），`git status` 里没有它的残留。

- [x] 6.8 收尾补跑（6.6 / 6.7 都改了测试文件，按"改一处就跑一处"重跑）：`flutter analyze` + `flutter test`，贴出末尾统计行。

  **实测**：`flutter analyze` → `171 issues found`（与本改动之前的既有问题同一批，改动文件里没有新增）；全量 `flutter test` →
  ```
  00:21 +278: All tests passed!
  ```
  （6.2 那次是 +276，这两条是 6.7 新增的守卫用例。）

## 7. 文档（同一变更内完成）

- [x] 7.1 `Docs/user-guide/chat.md`：写清提示出现在输入框上方、说什么、什么时候消失。

  **实测**：`怎么操作` 加了第 9 条（提示的样子、三条界面文案、后台那趟多一句"让路"）；`出错时会看到什么` 里"点了发送但一直没有任何回复"那一行补上"如果输入框上方出现了压缩提示，那是在压缩，还没开始问模型"；`限制` 里如实写明"等模型吐出第一个字那段等待没有单独的提示"。
- [x] 7.2 `Docs/user-guide/real-context-view.md`：写清提示在这一屏顶部、那句附注的内容、以及"压缩中还没发出去的摘要不会出现在这里"。

  **实测**：`怎么操作` 末尾加了压缩期间的说明与那句界面文案；`出错时会看到什么` 加了一行"顶部多出提示、下面没变 = 正常"；`限制` 加了一条"压缩期间这一屏不会刷新"。
- [x] 7.3 `Docs/user-guide/context-compaction.md`：补一句"压缩期间界面上能看到提示"，与既有的"自动压缩、界面上没有开关"保持一致。

  **实测**：`什么时候会压缩` 补了"你不动的时候也会压"（空闲约 2 秒、发消息会让路）；`界面上怎么认出来` 改成先说压缩**进行中**的提示（在哪个位置、说什么、空闲那趟多一句），再说压完之后的摘要标记。
- [x] 7.4 **给文档加一条会失败的守卫**：`test/unit/user_docs_test.dart` 新增一条检查 —— 文档里用统一标记写出的界面文案，必须在 `lib/` 下原样找得到。
  **判据**：把 7.1–7.3 里的某一句界面文案改掉一个字，这条检查必须失败（贴出红的输出），再改回来。

  **实测**：标记写法是 `界面文案：` + 反引号里的原句（见该文件的 `_uiTextMarker`），检查⑥逐条到 `lib/**/*.dart` 里找。正常跑：
  ```
  [⑥ 界面文案] 共 6 条：
  [⑥ 界面文案]   chat.md：「正在挑选分段主题」→ 代码里有
  [⑥ 界面文案]   chat.md：「正在压缩较早的对话：」→ 代码里有
  [⑥ 界面文案]   chat.md：「正在把一级摘要合成二级摘要：」→ 代码里有
  [⑥ 界面文案]   chat.md：「你发消息会让压缩先让路」→ 代码里有
  [⑥ 界面文案]   context-compaction.md：「你发消息会让压缩先让路」→ 代码里有
  [⑥ 界面文案]   real-context-view.md：「下面是上一次实际发出的内容，压缩结果下次发送时才出现」→ 代码里有
  ```
  把 `正在挑选分段主题` 改成 `正在挑选分段的话题`（改 3 个字）后：
  ```
  [⑥ 界面文案]   chat.md：「正在挑选分段的话题」→ 代码里没有
  Expected: empty
    Actual: ['chat.md：「正在挑选分段的话题」']
  这些标成界面文案的句子在 lib/ 下找不到（界面改了文案、文档没跟着改？）
  ```
  改回后转绿。这条检查自己也有防空转断言（一条都没标出来就红）。
- [x] 7.5 核对 `README.md` 的功能索引：压缩是既有功能页，本次不需要新增条目，三条链接仍指向存在的文件（`test/unit/user_docs_test.dart` 的既有双向一致检查转绿即可）。

  **实测**：该文件的"README 的功能索引与 Docs/user-guide/ 双向一致"这条用例在本轮运行里通过（`00:00 +5: All tests passed!`），README 未改动。

## 8. 等待门槛（2026-10-02 用户追加的要求）

**背景**：用户原话「我觉得强制等待压缩的条件应该是总占用的模型上下文超过一个较大比例时才需要触发，比如现有发送给模型的原文+一级+二级摘要超过总上文的75%时触发等待，此时新一轮对话需要等压缩完成后才能继续」。这一组把"这一轮要不要为压缩等待"从压缩触发阈值里分出来；压缩动作本身不动（攒够阈值照旧压）。

- [x] 8.1 **先写红态（核心判据）**：`test/integration/compaction_projection_test.dart` 新增用例 —— 容量 4000（压缩阈值 1000、等待阈值 3000），这一趟不压就发的估算总量落在 1000～3000 之间 ⇒ 虽然已经攒过压缩阈值，这一轮**不该等**。
  四条断言：①请求确实发出去了；②计数假摘要器**被调用 0 次**（一个模型调用都没有）；③那段攒过阈值、还没压过的内容在投影里是**原文**；④界面上找不到压缩提示。
  **判据**：在没改产品代码之前跑，必须红（现行为是发送前当场压完再发）；把红态实际输出贴在这条下面。

  **红态实测（`flutter test test/integration/compaction_projection_test.dart --plain-name "8.1 ..."`）**：
  ```
  [OBS] 8.1 不压就发的估算总量≈1506（容量 4000 ⇒ 压缩阈值 1000、等待上界 3000，占比 37.6%）；
        摘要调用次数=1；逐字出现的 seq={}；界面提示节点数=1；已发给模型=false
  Expected: non-empty
    Actual: <null>
  前提：这一轮必须真的发出去了，否则"没提示"是空跑
  ```
  **第一版判据是弱的，改成现在这样**：第一版用"立即返回"的假摘要器，跑出来是 `摘要调用次数=1`、`逐字出现的 seq={12,13,14,15}`（远端 1..11 被摘要接走）、`界面提示节点数=0` —— 第 ④ 条"界面无提示"在这版里**区分不出新旧行为**（旧行为下提示亮过、但断言跑在压缩结束之后，那时它已经灭了）。改成**把假摘要器挂住**（`_GatedSummaryProvider` + `Completer`）：新规则下这一轮根本不该调用它，旧行为下它被调用并把这一轮卡在发送前 —— 于是①"请求已发出"也一起红了，现场变成 `逐字出现的 seq={}`、`已发给模型=false`、`界面提示节点数=1`。这四条现在条条指向同一件事：占比 37.6% 的这一轮，旧行为**连请求都没发出去**。

- [x] 8.2 **等的那一侧 + 不许死等**：同文件再加三条 —— ②这一趟占比**超过**等待阈值（正好等于 3000 **不算**超，与 8.3 的边界口径一致）⇒ 照旧等待（假摘要器被调用、界面出现提示、请求在压缩完成后才发出）；③压完仍超过等待上界、但没超过模型容量 ⇒ **照发、什么都不丢**（等待上界只决定这一轮等不等，它不是省略的门槛）；④压完仍超过模型容量 ⇒ 按既有规则把最旧的可省略内容留出这一轮投影，请求照发（库里数据不动）。
  **判据**：②在旧代码上通过（回归钉）；③与④要能失败 —— 构造"压完仍超"的几何（原文远大于容量），先跑一次确认它们在缺陷仍在时会红；构造不出就明写「未能证明此检查可失败」。

  **实测（三条都写进 `test/integration/compaction_projection_test.dart`，跑 `--plain-name "8.2"` 全绿）**：
  ```
  [OBS] 8.2② 占比 100% > 75% ⇒ 该等：摘要调用次数=1；已发给模型=false；界面提示节点数=1（压缩中）
  [OBS] 8.2② 放行之后：已发给模型=true；界面提示节点数=0
  [OBS] 8.2③ 摘要调用次数=3；摘要覆盖=[(1..11),(12..22),(23..33)]；尾部原文估算=712
        ⇒ 压完投影估算≈912（等待上界 3000、容量 4000）；已发给模型=true
  [OBS] 8.2④ 逐字出现的 seq={}；摘要覆盖={7..30}；这一轮有表示的 seq=24 个（历史 30 条）；已发给模型=true
  ```
  **③ 那一支按任务许可如实标注：未能证明此检查可失败。** 原③要的是"压完仍超过等待上界、但没超过容量 ⇒ 什么都不丢"。实测构造不出来：尾部原文必然小于压缩阈值（1000），而等待上界是容量的 75%（3000），所以"压完仍超等待上界"要求尾部 > 2800，与"尾部 < 1000"矛盾；除非预置一大堆已落盘摘要把占比顶上去，那又绕过了"这一轮有可压内容"这个前提。所以③改写成它真正能钉住的那件事：**"等"不等于"丢"** —— 占比超上界 ⇒ 该等；等完投影降到上界以下（实测 912 < 3000），并且一条内容都不许少（`_expectEveryMessageExactlyOnce`）。
  **④ 的现场推翻了我原来的假设，如实记下**：我以为"省略"由 `_resolveSummariesInner` 收拢循环里 `if (!overCapacity) break;` 之后那段（`table.indexWhere(omittable)` → `table.removeAt`）产生。把那段改成"永不省略"再跑 ④，**读数一个字都没变**（`摘要覆盖={7..30}`、`有表示的 seq=24 个`）——说明这次观察到的"seq 1..6 没有表示"不是那段代码干的，而是更早的几何/切分结果（远端只从 seq 7 起被切进批次）。所以④里"最旧那段被留出投影"这条**同样未能证明可失败**；④现在钉住的是"压完仍超容量时请求照发（不死等）"与"投影里不是 30 条原文全都在"。**这条未解之谜留给 8.7**：变异要挑真正产生该现象的那段代码，不能想当然。

- [x] 8.3 **纯函数判据**：`test/unit/compaction_engine_test.dart` 新增等待判据 —— 容量 20000 ⇒ 等待阈值 15000、容量 40000 ⇒ 30000（按比例翻倍）；正好等于阈值**不算**超（边界）；分子里已落盘摘要按它自己的实测 token 计、其余按原文估算（同一份历史，摘要比原文小 ⇒ 占比更小）。
  **判据**：先跑红（函数还不存在 ⇒ 编译不过，如实贴出来），再实现到绿。

  **红态实测**：`flutter test test/unit/compaction_engine_test.dart` ⇒
  ```
  Error: Member not found: 'CompactionEngine.waitBoundTokens'.（5 处）
  Error: Member not found: 'CompactionEngine.exceedsWaitBound'.（2 处）
  Error: Member not found: 'CompactionEngine.estimatedProjectionTokens'.（1 处）
  ```
  **转绿实测（`00:00 +28: All tests passed!`）**：
  ```
  [OBS] 容量 20000 ⇒ 上界 15000；容量 40000 ⇒ 30000；容量 40000 配 50% ⇒ 20000；容量 0 ⇒ 0
  [OBS] 15000 对 15000 ⇒ false（不算超）；15001 对 15000 ⇒ true（算超）
  [OBS] 摘要实测 500+300、尾部原文估算 400+400 ⇒ 合计 1600；摘要换成一条实测 50 ⇒ 合计 850
  ```
  最后一条是**对照**：摘要实测值一变合计就跟着变（1600 → 850），证明这个分子不是恒真的常数。

- [x] 8.4 **配置键判据**：`test/unit/config_service_test.dart` 新增 `compaction_wait_threshold_percent` 的四条 —— 缺省 75、写了合法值就用它、`0` / 负数 / 大于 100 / 小数 / 字符串一律回落 75、回落时日志里**至少有一行**说明。
  **判据**：先跑红，再实现到绿。
  **口径按实测写死**：既有规则是"进程级只打印一次"（实测同一进程里 6 个非法值只出 1 行日志），所以这条判据写成"至少一行"，不许写成"每个非法值各一行"。

  **落点更正**：任务原文点名的 `test/unit/config_service_test.dart` 里没有这类用例 —— 既有 `compaction_threshold_percent` 的三条用例在 `test/unit/agent_registry_test.dart` 的 `compactionThresholdPercent` 组里，新键的用例按同一处落，方便对照。
  **红态实测**：`Error: The getter 'compactionWaitThresholdPercent' isn't defined for the type 'AgentTypeConfig'.`（6 处，编译不过）。
  **转绿实测（`00:00 +16: All tests passed!`）**：
  ```
  [OBS] explicit wait percent -> 60
  [OBS] absent wait percent -> 75
  [OBS] illegal wait percent abc / 0 / -5 / 101 / 12.5 / true -> 75（六种非法值全回落）
  ```

- [x] 8.5 **实现（一）：配置键与唯一计算点**。`lib/models/agent_type_config.dart` 加新键解析与校验（与既有 `compaction_threshold_percent` 同一套规则）；`lib/services/compaction/compaction_plan.dart` 加"这一趟不压就发的话占多少"的纯函数与"是否超过等待阈值"的判定（等待上界 = `maxContextTokens × 百分比 ÷ 100`，不发任何模型调用）。
  **判据**：8.3 与 8.4 转绿。

  **实测**：随 8.3 / 8.4 一并落地，两条都绿（`+28` 与 `+16`）。落地形态：
  - `AgentTypeConfig.kDefaultCompactionWaitThresholdPercent = 75`、字段 `compactionWaitThresholdPercent`、`_parseCompactionWaitThresholdPercent`（独立的一次性日志标记，不与既有键共用，免得不写这个键的配置把既有那条提示吃掉）、`fromJson` / `toJson` 都接上（写出来是为了在 `~/.aliasagent/config.json` 里看得见这个旋钮）。
  - `CompactionEngine.waitBoundTokens(maxContextTokens, waitPercent)`（唯一计算点）、`exceedsWaitBound(...)`（**严格大于**才算超，边界口径只写在这一处）、`estimatedProjectionTokens({summaryMeasuredTokens, rawTail})`（分子口径：摘要按实测、原文按估算）。三个都是纯函数，不发任何请求。

- [x] 8.6 **实现（二）：发送前分叉**。`lib/main.dart`：占比超过等待上界 ⇒ 走现在的路径（生成摘要并等待）；不到 ⇒ 走"只取已落盘摘要拼投影"的路径，攒过阈值但还没压的内容按原文发，**整个过程中一次摘要调用都不发**；两条路径结束时压缩状态都回到空闲。
  **判据**：8.1 与 8.2 全部转绿；后台折叠、抢占、投影分档的既有用例一条都不许回归。

  **落地形态（都在 `_callModel` 与 `_resolveSummaries` 里）**：
  - 在 `_loadClosedSegments` 之后、**`_prepareSeamChooser` 之前**算这一轮的"不压就发"占比（`estimatedProjectionTokens(已落盘摘要的实测值, 未覆盖原文)`）与 `exceedsWaitBound(...)`；不等的那一轮**连分段选择都不发起**（生产环境的分段选择器自己要发一次模型请求）。
  - 不等 ⇒ `CompactionEngine.projectionWithoutNewSummaries(plan)` 把"这一趟还没落盘的摘要段"降级成原文段（降级后 `rollable` 为假，收拢循环也不会对它们发起合成请求）；已落盘的段原样保留、照旧取库。
  - `_resolveSummaries` / `_resolveSummariesInner` 加 `generate` 参数；`generate == false` 时收拢循环整段跳过（`while (generate && table.isNotEmpty)`）—— 占比不到上界 ⇒ 不超容量 ⇒ 不需要收拢也不需要省略。
  - 界面进度只数**要生成**的段（`reuse == null`）：已落盘的段是取库、不算进度，也不会把提示点亮 ⇒ 不等的那一轮界面上没有任何提示。
  **实测（`flutter test test/integration/compaction_projection_test.dart` ⇒ `00:03 +32: All tests passed!`）**：
  ```
  [OBS] 8.1 不压就发的估算总量≈1512（容量 4000 ⇒ 压缩阈值 1000、等待上界 3000，占比 37.8%）；
        摘要调用次数=0；逐字出现的 seq={1..15}；界面提示节点数=0；已发给模型=true
  [OBS] 8.2② 占比 100% > 75% ⇒ 该等：摘要调用次数=1；已发给模型=false；界面提示节点数=1（压缩中）
  [OBS] 8.2② 放行之后：已发给模型=true；界面提示节点数=0
  [OBS] 8.2③ 摘要调用次数=3；摘要覆盖=[(1..11),(12..22),(23..33)]；压完投影估算≈912 < 3000；一条不丢
  [OBS] 8.2④ 有表示的 seq=24 个（历史 30 条）；已发给模型=true（压完仍超容量也照发）
  ```
  **既有用例的回归情况**：实现后该文件一度有 14 条既有用例变红（与对抗验证审查预估的 14 条一致）—— 它们的几何占比只有 30%～40%，新规则下不再在发送前压。处理见 8.10。
  **全量实测（全量 `flutter test`）**：`00:21 +287 -1`，唯一一条红是 `test/unit/user_docs_test.dart` 的配置键反向检查（新键还没写进文档）—— 正是 8.8 要做的，其余一条不回归。

  **⚠ 这一条里我出过一次自己的事故，如实记下（含机制改进）**：为了给用例加 `waitPercent` 参数，我用 PowerShell 的 `Get-Content -Raw` 读源码再写回 —— 它按系统 ANSI 解码了 UTF-8 文件，**把 `test/integration/compaction_projection_test.dart` 全文件的中文注释与中文断言字符串写成了乱码**（乱码里还出现了不可逆的 U+FFFD，反解不回来）。表现是 8 条用例的 `find.textContaining('中文')` 全部找不到（界面文案本身是好的）。修复：`git show HEAD:<该文件>` 取回正确中文的基线（本轮对该文件只做过"新增"，没改过既有判据），再把 6 条提示用例与 8.1/8.2 四条重新插回，跑出 `+32: All tests passed!`。
  **机制改进（不是"下次注意"）**：改含中文的源文件只用 `read` / `write` / `edit` 工具（它们按 UTF-8 读写）；确实要用 shell 时必须显式指定编码 —— `[System.IO.File]::ReadAllText(path, [System.Text.UTF8Encoding]::new($false))` 与 `WriteAllText(..., UTF8Encoding(false))`，**禁止** `Get-Content` / `Set-Content` 的默认编码路径。这条也写进了 8.7 之后的收尾记录。

- [x] 8.7 **反例自检（证明这些断言不是恒真）**：①把判据改成"永远等待" ⇒ 8.1 必须红（假摘要器被调用、提示出现）；②把"不等"那条路径改成"照样生成摘要但不等待" ⇒ 8.1 的"零调用"断言必须红。两次都贴输出后还原，`MUTATION` 在仓库里零命中。

  **变异①实测（`final waitForCompaction = true;`，判据临时挪进一个未使用的变量免得编译报错）**：
  ```
  [OBS] 8.1 不压就发的估算总量≈1506（…占比 37.6%）；摘要调用次数=1；逐字出现的 seq={}；
        界面提示节点数=1；已发给模型=false
  Expected: non-empty
    Actual: <null>
  前提：这一轮必须真的发出去了，否则"没提示"是空跑
  ```
  **变异②实测（把 `final plan = waitForCompaction ? planned : projectionWithoutNewSummaries(planned);` 改成 `final plan = planned;`，即照样生成、只是不等待）**：读数与变异①逐字相同（`摘要调用次数=1`、`逐字出现的 seq={}`、`已发给模型=false`）⇒ 8.1 同样红。
  两处都还原后 8.1 转绿（`摘要调用次数=0`、`seq={1..15}`、`已发给模型=true`）；`MUTATION-8` 在 `lib/`、`test/`、`integration_test/` 下零命中。

- [x] 8.8 **文档（同一变更内完成）**：`Docs/user-guide/configuration.md` 写清新键（缺省 75、非法值行为）；`Docs/user-guide/context-compaction.md` 写清"什么时候这一轮需要等压缩"与代价（连续快速发消息、一直不空闲时，压缩会推迟到占比超过阈值那一次，那一次等待更长）。
  **判据**：`test/unit/user_docs_test.dart` 里"代码里解析的每个配置键都必须在文档里出现"这条既有检查转绿；把该键从文档里删掉，这条必须变红（贴一次红）。

  **实测**：
  - 写进 `configuration.md` 的 ```json 块（这是关键：那条检查只读 json 围栏里的 `"键":` 行）+ 键表一行 + "出错时会看到什么"一行（非法值的日志提示）。
  - `context-compaction.md` 新增《什么时候这一轮需要等压缩》：判据（这一轮要发的原文 + 一级 + 二级摘要占模型总上下文多少）、缺省 75、一张"不到 75% / 超过 75% 各会发生什么"的表、以及代价（连续快速发消息会把它推迟到占比超阈值那一次，那次等待更长；想更早等就把百分比调小）。
  - 转绿：`flutter test test/unit/user_docs_test.dart` ⇒ `00:00 +5: All tests passed!`（配置键反向检查与第六项界面文案检查都过）。
  - **反例自证（把新键从 json 块里删掉再跑）**：
    ```
    Expected: empty
      Actual: ['compaction_wait_threshold_percent']
    代码解析这些配置键，但没有一份文档把它们写成配置键：[compaction_wait_threshold_percent]
    ```
    改回后转绿 ⇒ 这条守卫能失败，不是摆设。

### 8.A 对抗验证审查带出来的返工与补强（2026-10-02 审查结论，逐条都指到了产物）

- [x] 8.10 **既有用例 6.1 / 6.2 的期望必须按新规则改（审查判为高）**：`test/integration/compaction_projection_test.dart` 的「6.1 原文攒够阈值就压：内容远没到模型容量、但已超过阈值」与「6.2 没超容量也合成更粗的摘要：库里两条 L1 实测相加超过阈值」用的是**同一类几何**（容量 4000、阈值 1000、这一趟占比 37.5% 与约 30%），新规则下这两轮都不该在发送前压 ⇒ 它们现在钉的正是相反行为（"发送前必须已经压出摘要"）；8.6 那句"既有用例一条都不许回归"没有认出这一点。
  **做法**：按 §18 三条改判据 —— ①能溯源：用户 2026-10-02 原话 + 本变更 spec 的《Send-time wait gate》；②不许放松：6.1 改成"这一轮不压"之后，另加一条**同一份几何、把等待阈值调低到让占比超过它**的用例，钉住"超过就该压"，两条合起来比原来一条更严；③留下对照：把 6.1 / 6.2 改前改后的期望原文贴在这条下面。
  **判据**：改完后这两条与 8.1 / 8.2 一起全绿；把等待阈值改回"永远等待"（8.7①）时，新加的那条仍然绿、6.1 也仍然绿（说明改的是行为口径而不是断言松紧）。

  **实际做法（比"改 6.1 的期望"更稳，逐条对照 §18 三条）**：
  1. **能溯源**：用户 2026-10-02 原话（"只有占比超过 75% 才触发等待"）+ 本变更 spec 的《Send-time wait gate》第一段（判据只有一个量）。
  2. **不许放松 —— 6.1 / 6.2 的判据一个字都没改**。改的只是这个文件 helper 的**前提**：`_setupAgentRegistry` 新增 `int waitPercent = 1`（缺省 1% ⇒ 等于"永远等"），并写明"这个缺省不是生产缺省，要验证'不等'的用例必须显式传 75"。既有用例的几何（容量、历史条数、预置节点）与全部断言保持原样 ⇒ 它们继续验"压缩与投影规则本身"，前提显式化了。
  3. **同时加严**：同一份几何上新增了**两个方向**的用例 —— 8.1（生产缺省 75% ⇒ 这一轮**不压**、零摘要调用、原文照发）与 8.2②（把占比顶到 100% ⇒ 该等、真压、提示在）。原来只有"会压"这一侧，现在是两侧都钉住。
  **改前 / 改后对照（原文）**：
  ```dart
  // 改前（HEAD 版，helper 不带 waitPercent ⇒ AgentTypeConfig 用生产缺省 75%）
  void _setupAgentRegistry({
    int maxContextTokens = 200,
    List<String> standingRequirements = const [],
  }) { ... maxContextTokens: maxContextTokens, ... }

  // 改后（多加一个参数 + 一段说明它为什么不是生产缺省）
  void _setupAgentRegistry({
    int maxContextTokens = 200,
    List<String> standingRequirements = const [],
    int waitPercent = 1,
  }) { ... compactionWaitThresholdPercent: waitPercent, ... }
  ```
  实测：改完后该文件 `00:03 +32: All tests passed!`（含 6.1 / 6.2 与 8.1 / 8.2 四条）；8.7① 那处变异跑完，6.1 与新加的两侧用例表现一致（见 8.7 的读数）。

- [x] 8.11 **压缩状态要带归属（审查判为高/中，属已实现代码的缺陷）**：现在 `_setCompactionStatus` 是无条件清空，而后台折叠与发送前压缩可能同时在跑 —— 谁先结束谁把对方正在显示的提示清掉；另外切换会话既不销毁界面也不清状态，旧会话的压缩提示会挂在新会话界面上。
  **做法**：状态带归属（哪条路径置的 + 属于哪个会话），清除只在归属匹配时生效；切换会话时清掉不属于当前会话的状态。
  **判据（先写红态，两条都要能失败）**：①在 `test/integration/background_fold_test.dart` 里构造"后台那趟被抢占后收尾"与"发送前那趟正在跑"同时存在的那一刻（把界面历史也撑过阈值，并把假摘要器的 gate 按调用次序分成两个：第一次报错模拟被取消、第二次继续挂住），断言那一刻提示仍在；②发送后在压缩被卡住期间切到另一个会话，断言新会话界面上找不到 `compaction-status-banner`。
  **这两条现在都不存在**：现有抢占用例里用户那趟根本没触发压缩（假仓库被撑大、界面历史没有），所以两条并发缺陷现在没有任何守卫 —— 红态就是加进去之后跑一次看它们红。

  **实现（`lib/main.dart`，三层）**：
  1. **归属令牌**：`_setCompactionStatus(status, {owner})` / `_clearCompactionStatus({owner})` —— 每次置位的人拿一个自己的 `Object()`，清除时只清**自己那一份**（`identical(_compactionOwner, owner)` 才动），别人正在显示的提示不清。`_prepareSeamChooser` 与 `_resolveSummaries`（外层建令牌、内层沿用它做进度更新）各自持有自己的令牌。
  2. **会话校验**：置位时带 `sessionId`，只有它**就是当前会话**才画（切走之后旧会话那趟压缩还会跑一阵，它后续的置位不许画到新会话界面上）。
  3. **切会话清状态**：`_selectSession` 里把状态与归属一起清空。
  **实测（`flutter test test/integration/background_fold_test.dart` ⇒ `00:01 +7: All tests passed!`）**：
  ```
  [OBS] 8.11① 第 1 轮（占比 60%）：调用次数=0 banner=0 [expect 0 / 0]
  [OBS] 8.11① 后台那趟起来后：调用次数=1 banner=1 [expect >=1 / 1]
  [OBS] 8.11① 用户这趟开始压：调用次数=2 banner=1 文案="正在压缩较早的对话：正在生成第 1 段摘要，共 3 段" 已发给模型=true
  [OBS] 8.11① 后台那趟收尾之后：banner=1 [expect 1 —— 用户那趟还在跑]
  [OBS] 8.11① 两趟都收尾后：banner=0 [expect 0]
  [OBS] 8.11② 发送后（压缩卡住）：调用次数=1 banner=1 文案="…共 3 段" 已发给模型=false 库里本会话消息数=61
  [OBS] 8.11② 切到 Session 2 之后：banner=0 [expect 0 —— 旧会话的压缩提示不许跟过来]
  ```
  **两处变异自证（都实测过、都还原了）**：
  ```
  变异 A（_clearCompactionStatus 忽略归属、无条件清）：
    [OBS] 8.11① 后台那趟收尾之后：banner=0 [expect 1 —— 用户那趟还在跑]
    Expected: exactly one matching candidate / Actual: Found 0 widgets … ⇒ 用例①红
  变异 B（_selectSession 里不清压缩状态）：
    [OBS] 8.11② 切到 Session 2 之后：banner=1 [expect 0 —— 旧会话的压缩提示不许跟过来]
    Expected: no matching candidates / Actual: Found 1 widget … ⇒ 用例②红
  ```
  还原后两条转绿，`MUTATION-8` 在 `lib/` 与 `test/` 下零命中；**全量 `flutter test` ⇒ `00:21 +290: All tests passed!`**。
  **构造这条用例踩到的坑（§19 第 4 条：数字不许手算）**：我一开始按"`growConversation` 每条 100 raw"排几何，两条用例的前提全落空（实测 `调用次数=0`）—— 它每条插的是 `'A' * 100`，估算只有 **29 raw**。按实测读数把规模改成 40 条 / 60 条之后才对。另外一趟压缩可能生成多段，收尾时只放行"当时已存在的闸门"不够（后续段会新建闸门），所以给假摘要器加了 `gateOnlyFirst`：前 N 次挂住、之后自动返回。

- [x] 8.12 **补强判据本身（审查指出 4 处）**：
  - 8.1 要加这个文件自带的通用守卫 `_expectEveryMessageExactlyOnce`（"每段恰好一种表示"）：新路径要重写一份投影拼装，**漏发一整段**这种缺陷光靠 8.1 的四条断言查不出来。
  - 分叉点写在 `_prepareSeamChooser` **之前**（见 design 决定 9）：另加一条**注入分段选择器**的用例，断言"不等"那一轮连分段选择请求都没发（否则生产路径照样发一次请求并亮提示，而 8.1 查不出来）。
  - `test/integration/compaction_projection_test.dart` 里「没触发压缩的普通发送：整场都不出现提示」这条用例的三条断言全在"不该出现"侧，提示功能整条坏掉它也全绿：给它补一条正向对照（同一用例里让一次发送**触发**压缩并断言提示出现），或把它并进已有正向对照的那条用例。
  - `integration_test/compact_quality_live_test.dart` 的 ⑤/⑥ 断言太短：`contains('正在')` / `contains('让路')` 挡不住"文案改成别的意思但含这两个字"；⑥ 还把"后台那趟真的跑了"降级成纯打印（`nodesBeforeIdle → nodesAfterIdle` 只有 debugPrint），要改成实测断言（例如断言摘要条数真的增加，或断言那一刻的状态确实标着"后台那趟"）。
  **判据**：每条补强都要能指出"它在缺陷仍在时怎么红"（改前先说清，改后跑一次确认）。

  **逐项落地与实测**：
  1. **8.1 加通用守卫** —— 已在 8.1 用例末尾用上 `_expectEveryMessageExactlyOnce(projected, upToSeq: 15)`（见 8.1 的实测块）。它在缺陷仍在时怎么红：新路径漏发一整段时，这条守卫会报"没有任何表示的 seq=[…]"。
  2. **分段选择那条新用例** —— 新增 `8.12 不等的那一轮：连分段选择请求都不发`（用 `_WarmSeamSelector` 数 `ensure` 次数）：
     ```
     [OBS] 8.12 不等的那一轮：分段选择 ensure 次数=0；摘要调用次数=0；界面提示节点数=0；
           已发给模型=true [expect 0 / 0 / 0 / true]
     ```
     它在缺陷仍在时怎么红：把分叉点挪到 `_prepareSeamChooser` 之后（生产路径就会先发一次分段选择请求），`ensure 次数` 立刻不为 0 ⇒ 这条红。
  3. **"没触发压缩的普通发送"的正向对照** —— 在该用例的注释里指名两条对照用例（同文件的「压缩提示 · 发送前这条路径」与 8.2②，它们用同一类几何断言"该压的那一轮提示确实出现"），并写明它自己只钉"不压 ⇒ 不亮"这一侧；它的可失败性由 5.1 那处变异（把提示改成从"正在发送"推断）保证 —— 那次变异跑出来的红是 `没触发压缩的普通发送不许出现压缩提示`。
  4. **live 的 ⑤/⑥ 断言补强**（`integration_test/compact_quality_live_test.dart`）：
     - ⑤ 从 `contains('正在')` 改成"必须命中三个已知阶段词之一"（`正在挑选分段主题` / `正在压缩较早的对话：` / `正在把一级摘要合并…`），并在 reason 里打印实际拿到的文案。
     - ⑥ 从 `contains('让路')` 改成与 `CompactionStatus.level1(segment: 1, background: true).note!` **整句比对**（文案改了这条跟着走），并在抓到提示的**那一刻**读一次 `ChatScreenState.compactionStatus.background`，断言它为真 —— 这正是审查指出的"没有对照证明这句标志只由后台那趟置位"。
     这两处在缺陷仍在时怎么红：⑤ 若提示文案变成不含任何已知阶段词的句子 ⇒ 第一条红；⑥ 若那句"让路"被改成别的路径也会显示的通用句子（或后台标志失效）⇒ `idleBackground` 断言红。
  **该文件回归实测**：`flutter test test/integration/compaction_projection_test.dart` ⇒ `00:03 +33: All tests passed!`；`flutter analyze` 对改动的两个文件无问题。live 那两处断言的实际运行在 8.9 里跑（它要留图，8.13 也靠它）。

- [x] 8.9 **逐层验证（在冻结代码上跑）**：`flutter analyze`；`scripts\sync_sidecar_dll.ps1` + 全量 `flutter test`；live —— `integration_test/compact_quality_live_test.dart` 先核几何（它的容量是原始总量 × 2/3 ⇒ "不压就发"的占比是 150% > 75% ⇒ ⑤ 那条发送前提示在新规则下仍应发生），跑 `flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows` 并用 `read_image` 读它留下的 PNG；C++ 构建 + `ctest`（既有那条联网用例失败照实记）；冒烟 `test/smoke/run_all.sh`（失败项与改动前一致，不得新增）。
  **顺序说明（2026-10-02 调整）**：本条原本排在 8.12 之前，但 8.12 要**改测试文件**，验证必须跑在冻结代码上 —— 所以本条移到 8.12 之后执行（它在文件里的位置也已挪到 8.12 与 8.13 之间）。

  **五层实测（全部在 8.12 改完之后的代码上跑）**：
  1. `flutter analyze` ⇒ `171 issues found` —— 与本次改动之前同一批（既有条目：`main.dart` 的 `nsCount`、`sidecar_bridge` 的未用字段、既有测试的 `avoid_print`/deprecated 等），**改动文件里没有新增问题**。
  2. `scripts\sync_sidecar_dll.ps1` ⇒ `SYNC-OK: sidecar.dll already current`；全量 `flutter test` ⇒ **`00:20 +291: All tests passed!`**。
  3. live ⇒ **`00:49 +1: All tests passed!`**，含新补强的 ⑤（"必须命中三个已知阶段词之一"）与 ⑥（整句比对 + "状态标着后台那趟=true"）：
     ```
     [OBS] ⑤ 压缩进行中，对话视图上抓到提示：正在挑选分段主题
     [OBS] ⑤ 同一时刻真实上下文视图上的提示：正在挑选分段主题 | 下面是上一次实际发出的内容，压缩结果下次发送时才出现
     [OBS] ⑥ 空闲自动压缩期间，对话视图上的提示：正在挑选分段主题 | 你发消息会让压缩先让路（状态标着后台那趟=true）
     [VERDICT] ⑥ 抓到提示=true；状态标着后台那趟=true；库里摘要条数 6 → 6
     ```
     四张 PNG 都 `read_image` 看过（见 8.13）；几何核对也成立：该用例容量 = 原始总量 × 2/3 ⇒ "不压就发"的占比 150% > 75% ⇒ ⑤ 仍会发生。
  4. C++ ⇒ `cmake --build` 通过（`sidecar.dll` / `sidecar_tests.exe` 都出来了）；`ctest` ⇒ `test cases: 237 | 236 passed | 1 failed`、`assertions: 3747 | 3746 passed | 1 failed`。唯一失败仍是那条**联网**用例 `search_provider_test.cpp` 的 "Rate guard: rapid-fire 5 consecutive ZhipuAI searches"，与本次改动之前一模一样（归属：本次没碰任何 C++ 文件，失败原因是连不上外部服务，条数与上一轮记录一致）。
  5. 冒烟 `test/smoke/run_all.sh`（Git Bash 跑）⇒ `Total: 2 passed, 3 failed`：Build PASS / Analyze FAIL / Checkpoints FAIL / Launch & Verify PASS / Visual Regression FAIL —— 与本次改动之前完全一致（同样五步、同样三项失败，没有新增失败项）。

- [x] 8.13 **live 截图现在不在了，重跑留图并如实记录（审查指出 5 张截图一个都不存在）**：`test/live_visual/` 是 gitignore 的，最后一次跑的是**变异版**（判据②，失败退出），它的 `clearLiveVisualDir()` 把之前的图删了 ⇒ 6.3 与 6.6 记录里点名的 5 张 PNG 现在都不在（记录当时为真，现在对不上）。
  **做法**：跑一次非变异的 live（8.9 那次就是）留下三张状态图 + `compact_quality_live.png`；在 6.6 的记录里补一句"截图目录会被下次 live 运行清空，要复核就重跑 8.9"。

  **实测**：8.9 那次非变异 live 跑完（`00:49 +1: All tests passed!`）留下四张，文件名与字节数见 6.6 的补充；其中三张状态图与一张总图我都 `read_image` 逐张看过：
  - `compact_quality_status_conversation.png`：输入框上方一条提示带（转圈 + "正在挑选分段主题"）。
  - `compact_quality_status_real_context.png`：这一屏顶部固定两行（"正在挑选分段主题" + "下面是上一次实际发出的内容，压缩结果下次发送时才出现"），下面是"尚无捕获的上下文快照"占位。
  - `compact_quality_status_background.png`：输入框上方两行（"正在挑选分段主题" + "你发消息会让压缩先让路"）—— 空闲自动那趟。
  6.6 的记录里已补上"目录会被下次 live 清空、复核就重跑 8.9"那句。

- [x] 8.14 **守卫宽松处如实记下来（审查判为中等）**：`test/unit/openspec_proposal_test.dart` 按整行子串判定、不区分任务行与证据输出块，所以"只在红态实测的日志里出现过测试路径"的提案也会通过；它拦得住"零命中"的提案，拦不住"只在叙述里提到测试"的提案。
  **做法**：把这条宽松处写进该测试文件的注释里（说清它有意从宽、真正的判断在 apply 阶段的验收），不改成更严的判定 —— 更严会误伤"判据行里点名测试"的合法写法。
  **判据**：注释写清后不需要新断言；在 8.9 的报告里如实说明这条守卫的边界。

  **实测**：注释已写进 `test/unit/openspec_proposal_test.dart` 的文件头，写明三件事 —— ①判定口径是"整行子串、任何一处命中即算"；②**它的边界**是"只在叙述或证据日志里提到测试路径的提案也能通过"；③为什么有意从宽（写严会误伤"判据行里点名测试文件"这类合法写法，真正的判断在 apply 阶段的验收）。该文件跑一次仍绿（`+2`），既有的反例自证用例（临时目录造一份不提测试的假工件 ⇒ 命中 0 处）继续钉住"零命中必须红"这一侧。
