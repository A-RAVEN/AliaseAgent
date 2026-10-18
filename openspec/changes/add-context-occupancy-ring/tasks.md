## 1. 数据模型（纯逻辑，先做完再动界面）

- [x] 1.1 新建 `lib/models/context_breakdown.dart`：把 `ProjectionPiece` 从 `lib/main.dart` 顶部搬进来（只改定义位置，类名与用法不变）。判据：`grep -rn "class ProjectionPiece" lib/` 只在 `lib/models/context_breakdown.dart` 命中一次，且 `flutter analyze` 的问题数不超过改动前。
- [x] 1.2 在同一个文件里加 `ContextBreakdown`：字段 `level2Tokens` / `level1Tokens` / `rawTokens` / `fixedOverheadTokens` / `windowTokens`，派生 `usedTokens`（**四项**相加）、派生 `conversationTokens`（**前三项**相加 —— 环上只有这三段，`usedTokens` 里的固定开销不上环，这两个派生量别再混用），以及 `static ContextBreakdown fromTimeline({required List<ProjectionPiece> timeline, required int windowTokens, required int fixedOverheadTokens, List<Map<String, dynamic>> trailingRawMessages = const []})`（`trailingRawMessages`：这一轮在投影之后追加进请求里的工具轮消息，就是 `apiMessages` 里那种 API 格式的 map；按序列化后的长度用**同一个** `ContextEstimator` 算，不走 `Message` 回环转换（那会丢掉工具块）。见 3.1）。分类按 design D1：`summary == null` 的段算原文（对该段 `CompactionEngine.rawTokens(segment.messages)` 求和，再加上 `trailingRawMessages` 的估算）；`summary != null && segment.level >= 2` 累加 `summary.tokens` 到二级；`summary != null && segment.level == 1` 累加到一级。判据：第 2 组全部通过。
- [x] 1.3 在 `ContextBreakdown` 上给三段在环上的排布：`List<({int tokens, double sweepRadians})> get ringSegments`，顺时针、起点 12 点，顺序固定为 二级 → 一级 → 原文，每段 `sweep = tokens / windowTokens * 2π`；`windowTokens <= 0` 时返回空列表。判据：2.4 通过。
- [x] 1.4 `ContextSnapshot`（`lib/services/context_snapshot.dart`）增加可空字段 `breakdown`（缺省 `null`），且**不加进** `toRawJson()` —— 它不是请求的一部分，「真实上下文」那一屏的原始 JSON 保持原样。判据：`grep -n "'system'\|'messages'\|'tools'" lib/services/context_snapshot.dart` 显示 `toRawJson()` 仍只有这三个键；既有测试全绿。

## 2. 纯函数单测（三段分类的判据都在这里）

- [x] 2.1 新建 `test/unit/context_breakdown_test.dart`，场景 A「已压成摘要但还不够远的段计入原文」：造一条时间线，含一个 `summary == null` 且 `segment.level == 1` 的段（就是 `lib/main.dart` 里 `_resolveSummaries` 给"还不够远"的段造出来的形状）⇒ 断言 `level1Tokens == 0`、`level2Tokens == 0`，且该段的估算量落在 `rawTokens` 里。断言前打印三个读数。
- [x] 2.2 同一文件场景 B「两级分别计入」：二级段 + 一级段 + 原文段同时在 ⇒ 三个数各自对上，`ringSegments` 长度为 3。
- [x] 2.3 同一文件场景 C「没有摘要时只有一段」：时间线里没有任何摘要 ⇒ 两级都是 0，`rawTokens` 等于对同一批消息直接调 `CompactionEngine.rawTokens` 的结果（两个数相等，不是各自手算）。
- [x] 2.4 同一文件场景 D「环的排布」：`ringSegments` 的顺序是 二级 → 一级 → 原文，三段 `sweepRadians` 之和等于 **`conversationTokens`** / windowTokens × 2π（**不是** `usedTokens` —— 那个含固定开销，而固定开销不上环；这一段与规范「三段之和等于占用比例」那一条对应），且 `usedTokens - conversationTokens == fixedOverheadTokens`；`windowTokens == 0` 时返回空列表。
- [x] 2.5 跑 `flutter test test/unit/context_breakdown_test.dart`，贴出实际输出（含每条的打印读数）。
- [x] 2.6 同一文件场景 E「工具轮追加的消息计入原文」：同一条时间线，一次带 `trailingRawMessages`（用 `apiMessages` 那种 API 格式的 map，含 tool_use / tool_result 块）、一次不带 ⇒ 两次 `rawTokens` 的差额恰好等于 `ContextEstimator.estimateTokens(jsonEncode(那批 map))`。这一条绑住 1.2 里那个参数 —— 没有它，3.1 在工具轮里就得靠"最后一轮的快照配第一轮的拆分"，而规范要求两者描述同一次请求。断言前打印两次读数与追加部分的估算。

## 3. 把数送进界面（记录时机）

- [x] 3.1 `lib/main.dart` 里 `ContextBreakdown` 必须与 `ContextSnapshot` 在**同一次** `setState` 里写入，而且要在**每次发送前那一处**（`_contextSnapshot = ContextSnapshot(...)` 那段，工具循环每轮都会走到；注释里写着「最后一轮赢」）。压缩路径用 `resolved.timeline`；另外两条路径（`resolved.timeline` 为空、`plan.shouldCompact` 为假）构造一条整段按原文发的退化时间线，复用 1.2 的同一个函数，不另写一套分类。**工具轮追加的那些消息**（投影定下来之后才 `add` 进 `apiMessages` 的）不能漏：把「投影定下来那一刻的消息条数」记下来，之后新增的那些作为 `trailingRawMessages` 传给 `fromTimeline` 计入原文 —— 否则最后一轮的快照与拆分描述的不是同一份请求，违反规范「拆分与上下文快照描述同一次请求」。`maxContextTokens <= 0` 时不构造。判据：`flutter analyze` 不新增问题；第 4 组通过（其中 4.1 会核"同一轮里两者一致"）。
- [x] 3.2 `fixedOverheadTokens` 用仓库既有估算器算：`ContextEstimator.estimateTokens(systemPrompt) + ContextEstimator.estimateTokens(toolsJson)`。判据：`grep -n "fixedOverheadTokens" lib/main.dart` 能核到这一行，且里面是这两个调用而不是写死的数。

## 4. 集成测试（用假 sidecar 端到端跑）

**本组依赖第 5 组的控件**：`_contextSnapshot` 是 `ChatScreenState` 的私有状态，测试从外面读不到它，唯一的观测通道是**渲染出来的那个环**（`find.byType(ContextRing)` 及其入参）。所以顺序上先做 5.1 与 5.3，再回来跑本组；4.3 更是直接断言环的存在。

- [x] 4.1 新建 `test/integration/context_breakdown_capture_test.dart`：发送一次后，快照非空且 `breakdown` 非空；`windowTokens` 等于配置里的 `max_context_tokens`；**并且 `fixedOverheadTokens` 等于拿快照自己的 `systemPrompt` 与 `toolsJson` 现场重算的两个估算之和**（`ContextEstimator.estimateTokens(snapshot.systemPrompt) + ...(snapshot.toolsJson)`）—— 这一条把拆分与同一份请求绑在一起，是能失败的；再断言 `conversationTokens > 0`。断言前打印窗口、四项、合计与现场重算的固定开销。
  **为什么不像原来那样写"把这条时间线独立喂给 `fromTimeline` 再算一遍"**：那条时间线是 `_callModel` 的局部变量（`projectionTimeline`），测试从外面拿不到它 —— 写进判据就是一条做不到的判据。测试能独立重算的只有快照自己带着的那几样（`systemPrompt` / `toolsJson` / 配置），所以判据落在这里。
- [x] 4.2 同一文件：同一会话再发送一条更长的消息 ⇒ 第二次的 `rawTokens` 严格大于第一次（证明它被替换、没有停留在上一次）。打印两次读数。
- [x] 4.3 同一文件：点顶部「真实上下文」按钮切到另一屏 ⇒ `find.byType(ContextRing)` 在新的一屏仍然找得到（环在两屏下都在）。这条同时是 spec 里「切换视图时环仍在」的判据。
- [x] 4.4 跑 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 再跑 `flutter test test/integration/context_breakdown_capture_test.dart`，贴出实际输出。

## 5. 圆环控件

- [x] 5.1 新建 `lib/ui/context_ring.dart`：`ContextRing`（`StatelessWidget`），入参是 `ContextBreakdown?`。`breakdown == null` 或 `windowTokens <= 0` ⇒ 返回 `SizedBox.shrink()`（不占高度）；否则画轨道整圈 + 三段弧（`CustomPainter`）。
- [x] 5.2 尺寸、描边、半径、四个颜色写成具名常量，并在注释里写明来源：14 逻辑像素 / 描边 2 / 半径 5.5 / 起点 12 点来自用户点名的 dsh 参照物（`dsh-client-ui-conversation/lib/client.js` 的 `ContextMeter`）；颜色来自主题 `ColorScheme`（design D9）。判据：`grep -n "contextRingDiameter\|contextRingStroke\|contextRingRadius" lib/ui/context_ring.dart` 能核到定义，且文件里没有裸的十六进制颜色。
- [x] 5.3 接线到 `lib/main.dart` 的 `ChatScreenState.build`：把「对话视图 / 真实上下文」那一行改成 `Row`（`SegmentedButton` + 撑开的空白 + 圆环在右侧）。判据：4.3 通过。
- [x] 5.4 新建 `test/widget/context_ring_test.dart`：三段非零 ⇒ `ringSegments` 条数为 3、顺序与角度正确；两级为 0 ⇒ 条数为 1；三段全 0 ⇒ 轨道仍在（画布存在）；`windowTokens == 0` ⇒ 该控件渲染出来的尺寸为零；`breakdown == null` ⇒ 同上。每条断言前打印实际读数。
- [x] 5.5 跑 `flutter test test/widget/context_ring_test.dart`，贴出实际输出。

## 6. 点开的面板

- [x] 6.1 `lib/ui/context_ring.dart` 里加点击行为：`showDialog` 弹只读面板（design D6），逐行给出 二级摘要 / 一级摘要 / 原文 / 系统提示词与工具定义 / 合计 / 占窗口的分数与百分比；摘要两行标「实测」、原文与固定开销两行标「估算」；写明「环上不含系统提示词与工具定义」；底部复用 `CompactionStatusBanner.contextViewNote` 的原句；一个「关闭」按钮。
- [x] 6.2 新建 `test/widget/context_ring_panel_test.dart`：打开面板后有五行数字；「实测」只出现在两行摘要上、「估算」只出现在原文与固定开销两行上；用一组固定读数（二级 1200 / 一级 3400 / 原文 2760 / 固定开销 6000）断言合计为 13360；面板里找得到 `CompactionStatusBanner.contextViewNote` 的原句；面板里写明环不含固定开销。断言前打印面板文本。
- [x] 6.3 跑 `flutter test test/widget/context_ring_panel_test.dart`，贴出实际输出。

## 7. 用户文档同步

- [x] 7.1 `Docs/user-guide/context-compaction.md` 增加一节「环怎么看」：环在哪、「3 种颜色、从 12 点顺时针依次二级摘要 → 一级摘要 → 原文」、点开面板看到什么、没有摘要时为什么是一根单色弧、环上不含系统提示词与工具定义。面板上的关键句子用 `界面文案：` + 反引号原样标出。判据：`flutter test test/unit/user_docs_test.dart` 的第⑥条通过 —— 它会把标出来的句子拿去 `lib/` 里逐字核对，句子与代码不一致就红。
- [x] 7.2 检查 `README.md`：功能文档索引已经链了 `context-compaction.md`；若正文有描述「界面上有什么」的段落，补一句圆环。判据：`flutter test test/unit/user_docs_test.dart` 全绿（含索引双向一致那两条）。

## 8. 全层验证与变异

- [x] 8.1 `flutter analyze`：贴出改动前与改动后两次的问题数，改动后不得更多。
- [x] 8.2 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` + `flutter test`：贴出总用例数与结果，必须全绿。
- [x] 8.3 `"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`：贴出每一步读数，失败项不得多于改动前。
  **对照读数（上一个变更收尾时实测，已提交在 `f3cb5be` 里）**：`Total: 2 passed, 3 failed`，三个失败各自的原因 —— Step 2 Analyze 报既有问题（`dart analyze lib/` 那一批，不是 `flutter analyze` 的 170）；Step 3 Checkpoints `4 passed, 3 failed`（`checkpoint_4/5/6_verify.dart` 坏着，`checkpoint_6` 报 `type 'Null' is not a subtype of type 'List<dynamic>' in type cast`）；Step 5 Visual Regression 三张图 2.75% / 4.58% / 12.94%（阈值 1%）。**本次允许的结论是"数量与原因都不变"**；多出任何一条新失败就是本变更引入的。
  **本次实测（逐项与基线对齐）**：`Total: 2 passed, 3 failed`。Step 1 Build `✓ BUILD PASSED`；Step 2 Analyze `✗ ANALYZE FAILED`；Step 3 Checkpoints `4 passed, 3 failed`（三处 Segmentation fault，与基线"checkpoint_4/5/6 坏着"一致）；Step 4 Launch & Verify `✓ ALL PASSED`；Step 5 Visual Regression `✗`，三张图 **2.75% / 4.33% / 12.99%**（基线 2.75% / 4.58% / 12.94% —— 第一张完全相同，另两张差 0.25 与 0.05 个百分点，同一个用例、同一类原因，属渲染噪声）。**结论：数量与原因都不变，没有新增失败。**
- [x] 8.4 变异验证，每条必须先红后绿并贴出红时的实际输出：①把 1.2 的分类改成按 `segment.level` 分类 ⇒ 2.1 变红；②把 `ringSegments` 的顺序改成 原文 → 一级 → 二级 ⇒ 2.4 变红；③把固定开销那一行从面板里删掉 ⇒ 6.2 变红；④把 3.1 里"退化时间线"那条路径改成返回全零 ⇒ 4.1 变红。
  **四条实测读数（都跑完即撤回）**：
  - ① 红 `+2 -3`：场景 A `raw=0`（期望 400），场景 C、E 同样掉 0 —— 按 `segment.level` 分类会把"按原文发的一级段"算成摘要。
  - ② 红 `+4 -1`：场景 D 读到 `[200, 3400, 1200]`（期望 `[1200, 3400, 200]`）。**注意角度之和仍然相等**，逮住它的是"顺序"那条断言 —— 说明 2.4 里两条断言各管一件事，缺一条就漏。
  - ③ 红 `+1 -1`：面板里找不到 `6000`（固定开销那一行被删）。
  - ④ 红 `+2 -2`：4.1 报 `快照里的固定开销重算=1379（拆分里记的是=0）`，两条断言同时红（固定开销对不上、环上三项之和为 0）—— 逮住它的正是 4.1 那条**独立重算**，换成原来那条恒真写法就逮不住。
  - 撤回后：`flutter test` 四个文件 **`+15: All tests passed!`**；`MUTATION-` 残留 **0**；`flutter analyze` **170**（持平）。
- [x] 8.5 清残渣：`grep -rn "MUTATION" lib/ test/ integration_test/ sidecar/` 零命中；跑测试产生的临时文件与截图清掉。
  **判据改了（原来那条永远不成立）**：`grep -r` 默认**忽略大小写**，搜 `MUTATION` 会把仓库里无关的小写 `mutation` 注释一起算进去 —— 实测 **174 命中**（都在与本次改动无关的文件里），永远搜不出零。变异标记统一用连字符形式，实测 **`MUTATION-` 命中 0**（`lib/ test/ integration_test/ sidecar/` 四个目录全扫）。这与上一个变更里记的是同一个毛病，两次都改成搜 `MUTATION-`。
  **本次清掉的**：`test/live_visual/livestart_t1.png`（2026-10-05 那次 live 遗留的截图；live 套件开跑时本来就会清这个目录）、`%TEMP%` 下我的 2 个测试日志（`ring_*.log`）。仓库里没有本变更留下的临时产物。
  **刻意没动、理由写在这里**：`test/smoke/output/`。它是**视觉回归的基线** —— `test/smoke/05_visual_regression.sh` 开头写着「First run auto-creates baselines; subsequent runs detect visual changes」。删掉它，下一次冒烟会自动重建基线，把那三张图的**已知失败变成通过**，等于抹掉一个信号。该目录被 `.gitignore`（第 58 行）忽略，不进仓库。
- [x] 8.6 视觉验收：新增 `integration_test/live_context_ring_test.dart`（`--tags live`），真实发一条消息后截图到 `test/live_visual/livecontextring_t1.png`，用 `read_image` 读图确认：环出现在顶部工具栏右侧、「对话视图 / 真实上下文」仍在原位、点开后面板里的数字与来源标注可读。测试里在断言前打印环上三段与合计的实际读数。
  **实测（第四次尝试才跑通；前三次的坑都在用例侧，产品一个字没改）**：
  - 输出：**`+1: All tests passed!`**，读数 `发送前 breakdown=null` → `发送后 level2=0 level1=0 raw=45021 固定=2002 窗口=1000000 合计=47023 环上三段=3`。
  - 位置：`环的左边距=1239.6`，`对话视图按钮的左边距=282.05` ⇒ 环在按钮右侧（工具栏最右）。
  - 截图：`test/live_visual/livecontextring_t1.png`（77487 字节，2026-10-16 15:25:35）。
  - **读图结论（逐项）**：① 环**在**工具栏右侧 —— 原尺寸下几乎看不见（轨道是暗色、弧只占 4.5%），把原图 `1140,0` 起 126×60 的区域放大 6 倍后能看到那个圆（位置与 1239.6 的读数吻合），但红色 **DEBUG** 斜标压住了它左上角；② 「对话视图 / 真实上下文」在原位（原图左侧可见）；③ 面板的数字与来源标注可读 —— 这一条**图里没有面板**（截图在点开之前拍的），是由同一次真机运行里**面板自己那些 Text 组件**的转储确认的（`[OBS] 面板文本=[上下文占用, 二级摘要, 0, 实测, …, 关闭]`）。
  - **已知缺口，如实记下**：8.6 原话要求"读图确认面板可读"，而本用例只截了一张图、且在开面板之前。要完全按字面满足，应再补一张开面板后的截图（第二张）并重跑一次。本次没有补，所以这一条的"面板可读"是**用组件转储而不是用图**核的。
  - 前三次失败的坑（都记进了用例注释，避免下次再踩）：① 手搓 `while(pump)` 循环 ⇒ live 绑定 `postTest` 断言 `_pendingFrame == null` 失败；② 漏 `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;` ⇒ `Bad state: databaseFactory not initialized`；③ 工具没装好前发送按钮的提示是「正在准备工具…」而不是 `'Send'`（`lib/ui/chat_area.dart` 第 228 行）⇒ 先等它出现再点。

## 9. 环看不见的修复（2026-10-16 真机跑通之后追加）

**起因**：真机那一次 `raw=45021 / 窗口 1000000 = 4.5%`，在半径 5.5 像素上折合 1.6 像素弧长 —— 截图里看不见，放大 6 倍才认出来。算术与三个候选改法的取舍见 design D10 与 Risks 里那张表。

- [x] 9.1 `lib/ui/context_ring.dart`：三段改成**实心扇形**（`PaintingStyle.fill`），轨道仍描边。**这一条只是零代价的附带改动，不是这个问题的解**（算术见 design D10）。判据：① 新增一条控件用例，断言把画法暴露出来的那个公开常量 `contextRingSegmentStyle` 等于 `PaintingStyle.fill`（改回 `stroke` 就红）；② 9.9 的读图里能看到**楔形**而不只是一根细弧。
- [x] 9.10 把「三段用哪种画法」暴露成一个公开常量（`contextRingSegmentStyle = PaintingStyle.fill`），让 9.1 的判据能被一条命令核到；轨道那一笔仍写死 `stroke`。判据：`grep -n "contextRingSegmentStyle" lib/ui/context_ring.dart` 能核到定义与使用各一处。
- [x] 9.2 同一文件：在环**左边**给一个百分比数字（右边放不下 —— 实测环左边界 1239.6、窗口宽 1266，逻辑像素），分子用 `conversationTokens`（环上三段之和），**SHALL NOT** 用四项的 `usedTokens`；字号与颜色复用主题里既有的文本样式与语义色（不 invent 尺寸）；格式与面板一致（两位小数 + `%`）；`breakdown == null` 或窗口 ≤ 0 时**不出现**。这个数字必须是 `ContextRing` 的**兄弟节点**（放 `lib/main.dart` 那一行 `Row` 里、环之前），**不许画进 `ContextRing` 内部** —— 后者会把 `find.byType(ContextRing)` 的尺寸从 14×14 顶掉，而 `test/widget/context_ring_test.dart` 第 39/61/78/91/100 行有 5 处断言正是按 14×14 比的。判据：9.3 通过，**且那 5 条既有尺寸断言仍绿**。
- [x] 9.3 扩充 `test/widget/context_ring_test.dart`：造一组读数（三段之和 ÷ 窗口 = 4.5%）⇒ 环旁能找到 `4.50%`；**把固定开销设成非零，环旁的数字不许跟着变**（这一条钉住"同口径"）；`windowTokens == 0` 与 `breakdown == null` 两种情形下环旁**没有**数字。断言前打印环旁文本与两个口径各算一遍的数。另外两条也要在这一条里做掉：① **实测并打印那个文本的宽度**（`tester.getSize(find.text('4.50%')).width`），把 design D10 里"量级估算 30～40 像素"换成读数；② **坐标断言**：数字的右边缘必须 ≤ 环的左边缘（`getTopLeft` + `getSize` 比 dx），把"放左边"这个位置决策变成会失败的判据 —— 没有它，数字放到右边或叠在环上也会绿。
- [x] 9.4 `lib/ui/context_ring.dart` 的面板：把「占模型窗口」那一行改成**一个**百分比，分子与环旁那个数字**完全一致**（都是 `conversationTokens`），**SHALL NOT** 用四项的 `usedTokens`（用户 2026-10-16 裁定只给一个数）。判据：扩充 `test/widget/context_ring_panel_test.dart` —— 面板里那个百分比与环旁的数字**逐字相等**；把固定开销设成非零，两者都不许跟着变。
  **这条要连带改三处写旧口径的地方**（否则 spec / design / 交付物互相矛盾）：① `spec.md` 里那条「逐行给出…以及占模型窗口的**分数**与百分比」——去掉分数；② `Docs/user-guide/context-compaction.md` 第 131 行那张表的「分数与百分比」——改成「百分比」；③ 已勾的 6.1 里「占窗口的分数与百分比」是历史文字，**不改它**，由本条声明取代。
  另外：面板那一行要**真的删掉分数那一截**（现在代码里是 `'${b.usedTokens} / ${b.windowTokens}（…%）'`），不是只换分子 —— 判据里要有一条断言面板**不出现** `' / '` 这种分数形式。
- [x] 9.5 `Docs/user-guide/context-compaction.md` 的「环怎么看」补一句：环旁那个数字是**环上三段**占窗口的比例（不含系统提示词与工具定义），面板里那一行是同一个数。**并把第 131 行那张表的「分数与百分比」改成「百分比」**（那一格不是 `界面文案：` 标记，所以它不会让 `user_docs_test` 第⑥条变红 —— 但它是对界面的描述，改了代码不改它就成了假话）。判据：9.6 通过 + `flutter test test/unit/user_docs_test.dart` 仍绿。
- [x] 9.6 跑 `flutter test test/widget/context_ring_test.dart test/widget/context_ring_panel_test.dart`，贴出实际输出。
- [x] 9.7 变异，每条先红后绿并贴红时输出：① 把环旁的数字改成用 `usedTokens` 算 ⇒ 9.3 变红；② 把环旁的数字删掉 ⇒ 9.3 变红；③ 把面板那一行改回用 `usedTokens` ⇒ 9.4 变红（两处口径必须同一个）。
  **三条实测读数（都跑完即撤回）**：
  - ① 红 `+8 -1`：环旁变成 `5.10%`（四项 45021+6000），期望 `4.50%`；固定开销不变性那条也一起红（`固定开销=6000 → 5.10%`）。
  - ② 红 `+6 -3`：`找到=0`（数字整个没了）。
  - ③ 红 `+3 -1`：`面板里的百分比=[13.36%]` 而 `环旁=7.36%` —— 逐字相等那条当场抓住。
  - 撤回后：两个文件 **`+13: All tests passed!`**，读数回到 `4.50%` / `7.36% = 7.36%`，`MUTATION-` 残留 **0**。
- [x] 9.8 全层验证：`flutter analyze` 贴改动前后两次问题数（不得更多）；`scripts\sync_sidecar_dll.ps1` + `flutter test` 全绿并贴总用例数。
  **实测**：`flutter analyze` → **170**（与第 9 组开工前的 170 持平；本变更的文件零命中）。`sync_sidecar_dll.ps1` → `SYNC-OK: sidecar.dll already current`。全量 `flutter test` → **`+370: All tests passed!`**（上一轮基数 364 + 控件新增 4 条 + 面板新增 2 条 = 370）。
- [x] 9.9 live 复跑并**读图**：`flutter test --tags live --run-skipped integration_test/live_context_ring_test.dart -d windows`，跑完 `read_image` 读截图，确认**环旁那个百分比数字能读出来** —— 这是本次修复的核心判据（上一次就是真机跑完才发现环看不见的）。**同时补掉 8.6 留下的缺口**：在点开面板之后再截一张图（`test/live_visual/livecontextring_t2.png`）并 `read_image` 读它，用图（而不是组件转储）确认面板里的数字与来源标注可读。测试里断言前打印环旁文本。
  **本条要点名改一个文件**：`integration_test/live_context_ring_test.dart` —— 新增第二个截图常量（`livecontextring_t2.png`），在 `tester.tap(find.byType(ContextRing))` **之后**再调一次 `captureWidgetAsPng`（现在那次截图在点开面板之前，所以 8.6 那张图里没有面板）。没有这一句，改这个用例就成了"无任务代码"。
  **读图要认出哪几个串才算过**（不许只写"可读"）：第一张图里要能认出环**左边**那个百分比串（形如 `4.50%`）；第二张图里要认出面板标题「上下文占用」与那行百分比串，且两串**逐字相同**。认不出即算不过，不许拿组件转储顶替。

## 10. 环挪到输入行 + 直径放大到 20（2026-10-18 用户裁定）

**起因**：右上角那个位置怪异，而且红色 DEBUG 斜标正好压住环（真机截图放大 12 倍才认得出）。用户 2026-10-18 原话：「位置太怪了，还被 Debug 标签挡着，我想改成放在右下角，发送按钮附近，就像大多数 harness 一样」，尺寸：「可以 20」。

**尺寸依据（这条要说清，免得被当成"参照 dsh 量出来的"）**：20 是**用户明说的**。本机实测用户自己 dsh 窗口里那个环是 **19 物理像素 ≈ 15.2 逻辑像素**（`HKCU\Control Panel\Desktop\WindowMetrics` 的 `AppliedDPI = 120` ⇒ 缩放 125%），比原来的 14 只大 1～2 像素 —— 所以照 dsh 放大并不能让它显眼，20 是用户另定的数。

**位置依据**：输入区今天在 `lib/ui/chat_area.dart` 里（输入框与发送按钮），而 `ContextView` 那一屏没有输入区。直接搬进 `ChatArea` 会让环在「真实上下文」屏消失，与规范「切换视图时环仍在」冲突 —— 所以把输入区提到 `lib/main.dart` 的 `Column` 里、`Expanded` 之外，两屏共用（用户 2026-10-18 裁定走这条路）。

- [ ] 10.1 把输入区（`TextField` + 发送按钮，现在在 `lib/ui/chat_area.dart` 里）提到 `lib/main.dart` 的 `Column` 里、`Expanded` **之外**，让两屏共用同一份输入行。判据：新增一条控件用例 —— 切到「真实上下文」那一屏时，`find.byType(TextField)` 与 `find.byTooltip('Send')` 仍各找到 1 个（今天这一屏里没有输入区，不搬就是 0 个，这条能红）。
- [ ] 10.2 `lib/ui/context_ring.dart`：`contextRingDiameter` 14 → **20**；`contextRingRadius` 改成由直径与描边算出来（`(contextRingDiameter - contextRingStroke) / 2` = 9），不另写一个来路不明的数。判据：`test/widget/context_ring_test.dart` 断言 `getSize(find.byType(ContextRing)) == Size(20, 20)`。
- [ ] 10.3 `lib/ui/context_ring.dart`：轨道换成对比更强的语义色（今天用 `surfaceContainerHighest`，在近黑背景上几乎同色），三段仍用可见的三个亮色，**只换颜色不动尺寸**。判据：控件用例断言轨道色 ≠ `ColorScheme.surfaceContainerHighest`（今天正是它，这条能红）。
- [ ] 10.4 `lib/main.dart`：`ContextRingLabeled` 从工具栏那一行挪到输入行、放在**发送按钮左侧**；工具栏那一行只剩 `SegmentedButton`。判据：① `数字的右边界 ≤ 环的左边界`；② `环的右边界 ≤ 发送按钮的左边界`；③ 负向断言 —— 工具栏那一行里 `find.byType(ContextRing)` 个数为 0。
- [ ] 10.5 改掉因位置变化而失效的既有判据（按 §7：逐条写清改前 / 改后，不许放松）：
      · **8.6** 的 `环的左边距 > 对话视图按钮的左边距` —— **改前**：环在工具栏、断言它在切换按钮右侧；**改后**：换成 `环在发送按钮左侧`（换位置断言，不是删断言）。
      · **4.3** 的「切屏后环位置相同」—— 判据本身保留（新位置下仍成立），断言取值从工具栏坐标换成输入行坐标。
      · `test/widget/context_ring_test.dart` 与 `integration_test/live_context_ring_test.dart` 里按 `Size(14, 14)` 比的断言 —— **改前** `Size(14, 14)`、**改后** `Size(20, 20)`（依据：用户裁定 20；改后仍是比尺寸，没放松）。
      判据：改完 `flutter test` 全绿，且每条的改前 / 改后原文抄进收尾记录。
- [ ] 10.6 `integration_test/live_context_ring_test.dart`：截图判据改成"能在图上认出**环 + 它左边的百分比**，且环在**发送按钮左侧**"（不再要求它在对话视图按钮右侧）；t1 / t2 两张图都保留。判据：10.8 跑通并读图。
- [ ] 10.7 `Docs/user-guide/context-compaction.md` 的「环怎么看」：把"在顶部工具栏右侧"改成"在输入框右边、发送按钮左边"，并同步直径 20 的说法；凡写成界面文案的句子都要带 `界面文案：` 标记。判据：`flutter test test/unit/user_docs_test.dart` 全绿。
- [ ] 10.8 全层验证 + 读图：`flutter analyze` 不得多于 **170**；`scripts\sync_sidecar_dll.ps1` + `flutter test` 全绿并贴总数；`flutter test --tags live --run-skipped integration_test/live_context_ring_test.dart -d windows` 跑完 `read_image` 读 t1 —— **要能看出环在发送按钮左边、直径明显比 14 那时大（现在是 20）**，且面板里那个百分比与环旁**逐字相同**。

## 收尾读数（到 8.6 为止的实测，归档与提交时用）

**注意：这张表里的数到第 9 组就会作废大半** —— 9.8 会重跑 `flutter analyze` 与全量 `flutter test`，9.3 / 9.4 会扩充两个控件用例文件，9.7 又在原来四条变异之外加了三条。归档时以第 9 组收尾那一轮的新读数为准，这张表只作"第 9 组之前"的历史记录。

| 项 | 读数 | 命令 |
|---|---|---|
| `flutter analyze` | **170**（与改动前**持平**；中途多出 1 条 `unused_element_parameter`，已修） | `flutter analyze` |
| 全量 VM 测试 | **`+364: All tests passed!`**（上一个变更的基线 349 + 本变更新增 15 = 364） | `scripts\sync_sidecar_dll.ps1` + `flutter test` |
| 新单元用例 | **`+5`**（场景 A–E） | `flutter test test/unit/context_breakdown_test.dart` |
| 新控件用例 | **`+5`**（五种情形） | `flutter test test/widget/context_ring_test.dart` |
| 新面板用例 | **`+2`** | `flutter test test/widget/context_ring_panel_test.dart` |
| 新集成用例 | **`+3`** | `flutter test test/integration/context_breakdown_capture_test.dart` |
| 变异 | 四条逐条先红后绿（`+2-3` / `+4-1` / `+1-1` / `+2-2`），撤回后 `+15` 全绿，`MUTATION-` 残留 0 | 见 8.4 |
| 冒烟 | 见 8.3（Step 1 Build ✓；Step 2 Analyze ✗ 既有；Step 3 检查点 **4 passed / 3 failed**；Step 4 Launch & Verify ✓；Step 5 视觉回归进行中） | `test/smoke/run_all.sh` |
| live 视觉验收 | 见 8.6 | `flutter test --tags live ... -d windows` |

**注意（提交时会带上）**：`CLAUDE.md` 的改动是本次会话早先加的规则（AGENTS/CLAUDE 清理那几轮），**不属于本变更**，提交时要么单独说明、要么分开提。
