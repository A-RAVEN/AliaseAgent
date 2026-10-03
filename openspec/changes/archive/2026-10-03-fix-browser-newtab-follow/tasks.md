## 1. 先捕获红态：把"新标签页来得比等待窗口更晚"变成确定性复现

- [x] 1.1 在 `test/integration/browser_worker_test.dart` 新增一条用例：页面由**本地 HTTP 服务**提供（照既有那条 `target=_blank` 用例的写法：`HttpServer.bind(InternetAddress.loopbackIPv4, 0)` 加一条 `/landing` 路由；**不能用 `data:` URL** —— 既有用例的注释写明 Chromium 不会把新标签页导航到 `data:` URL）。页面里放一个链接 `id='slow'`：`target="_blank"`、点击处理器先 `preventDefault()`、再 `setTimeout(() => window.open('/landing'), 1500)` —— 新标签页**必然晚于 1 秒窗口、早于 5 秒窗口**才开。
  **绿态断言**（改完 worker 之后必须全绿；与既有那条用例同一套口径，点击侧共**六条**）：返回 `ok` 为真；快照含 `LANDING`；**点击记录行存在**（`expect(clickRec, isNotNull, ...)` —— 它是后三条的前提，漏掉它的话记录收不到时后三条会被 `if (clickRec != null)` 整段跳过、用例仍然绿）；记录里 `browser_opened > 0`；`adopted_tabs > 0`；`tabs >= 2`（后三条从 stderr 的 `browser-record:` 行读）。
  **红态归因**（只用来证明红是"新页确实开了、只是这一次没跟上"，**不许写成断言**）：点击之后**显式等 2 秒**（`await Future<void>.delayed(const Duration(seconds: 2))`）再发一次 snapshot；把两次 `browser-record:` 行与两次返回 JSON **全部打印出来，打印要放在断言之前**（否则红态会先停在"快照不含 LANDING"那条断言上，记录根本打不出来）。红态读数应是：点击返回的快照仍是被点的原页面（不含 `LANDING`）、点击记录 `browser_opened == 0` 且 `adopted_tabs == 0`、**后一次 snapshot 的记录 `tabs >= 2`**（新页确实开过）。
  **为什么不把归因写成断言**：`adopted_tabs == 0` 只在未改代码时成立，改完后同一个键必然是 1；把它写成断言，这条用例永远不可能转绿，而它同时又是 2.2 要求"由红转绿"的那条守卫。
  **判据**：在**还没改** `scripts/browser_worker.py` 的代码上连跑 3 次，3 次都失败，且每次输出里都能看到上面那组归因读数。把 3 次输出都贴出来。这一条是本变更的红，也是将来的守卫。
  **附带说明（写进用例注释）**：这几个计数是 worker **进程内累计**值，本文件每个用例都新起一个 worker 进程，所以本用例里它们从 0 起；同一个进程里点第二次时，不能再拿绝对数当"这一次"的读数。

## 2. 改 worker：跟随新标签页不再依赖那个固定短窗口

- [x] 2.1 点击前判断"这个元素会不会开新标签页"：读目标元素的 `target` 属性（`_blank`，或具名 / 新窗口目标）。**这次读取必须不等待元素、且有显式小超时（500 毫秒以内）** —— worker 没有设置 Playwright 默认超时，等待式取值会继承 30 秒，加上点击自己的 30 秒正好撞上 sidecar 的 60 秒上限（超时即杀 worker），测试侧 45 秒还会先返回 `worker response timeout`。**读取失败（选择器不匹配、元素已被移除、执行出错、超时）一律按"不会开新页"处理，绝不让判断本身的失败导致点击失败。**
  **判据**：加一条用例 —— 用一个不存在的选择器点击，**断言**①错误串里含 `timed out waiting for`（即 worker 自己的选择器超时原文，不是预检抛出来的异常，也不是 45 秒超时那支会返回的 `worker response timeout`）、②该命令的墙钟耗时**小于 45 秒**（在用例里记命令前后的时刻、断言差值，不许只贴数字不写成断言）。贴三样：错误原文、实际耗时秒数、两次断言的实际读数。
- [x] 2.2 判定"会开新标签页"时，这一次点击改用更长的**有界**窗口 `NEW_TAB_WAIT_SEC = 5`（秒）；其余点击继续用现在的 1 秒。两个窗口都是上界：新页一到立即返回。
  **起算点**：把计时从点击**之前**改成点击**返回之后**（现在的写法把 `page.click(...)` 包在 `expect_page` 块里，块一进入就开始计时，慢点击会把弹窗预算吃掉）。
  **取页方式写死（三步，不许只做其中一步）**：①点击前先记下基准 —— 会话里由页面处理器登记过的"浏览器打开的页"名单（既有的 `on("page")` 处理器就是它：既有用例断言点击记录里 `browser_opened > 0`，就是它在点击期间被触发的证据；它现在只计数，要让它同时把页对象记进名单）；②点击返回后**立刻**看名单有没有新增（这一步是本地读、不等待）：有就立即跟随、**不进入等待**，否则同步弹窗的点击会白等满窗口；③名单没有新增，才进入有界等待新页事件，等待到期后再核一次名单，仍没有才判"这一次没等到"。**这一层为什么必须留**：`wait_for_event` 是调用时才挂监听，点击期间就已冲洗掉的页面事件它永远等不到 —— 只写等待会让普通 `target=_blank` 点击白等满 5 秒，只写名单会漏掉点击返回之后才开的页。
  **判据**：①1.1 那条用例由红转绿（贴输出）；②既有那条 `browser_worker: click a target=_blank link FOLLOWS the new tab (design 甲)` 用例**新增一条断言**：该次点击命令的总耗时**小于 3 秒**。**实测（2026-10-03）**：绿态 188 毫秒；把这次等待实现成"固定 5 秒延时、再核名单"（变异，只改等待那一句）⇒ 该断言红，读数 5252 毫秒（快照仍跟到了 LANDING，说明红的正是"上界被当成固定延时"）；改回来 ⇒ 188 毫秒绿。**另一条变异如实记：把"点击返回后立刻核名单"这一步去掉，本机没有变红 —— 该用例仍在 352 毫秒内跟随成功（page 事件是在点击返回之后才到达客户端的），所以这一步是顺序保险，不是本机可证失败的路径。**③加一条"普通点击不多等"的用例 —— 点一个原地跳转的链接，断言该命令总耗时**小于 3 秒**。**实测**：绿态 1134 / 1313 毫秒；把 `NEW_PAGE_WAIT_SEC` 改成 5.0 ⇒ 红，读数 5122 毫秒；改回来 ⇒ 绿。④加一条具名目标的用例 —— `target='landing'` 的链接（本地 HTTP 服务的第二张页面上放一个），断言仍被跟随。**实测**：跟随成功，记录里 `adopted_tabs=1`、`tabs=2`、点击后快照是 `/landing` 的内容。
- [x] 2.3 "判定会开新页、但窗口内没等到新页"时，在 per-call 记录（stderr 的 `browser-record:` 行）里加布尔键 `expected_new_tab_unfulfilled: true`。**值挂在会话属性上、由 `_emit_record` 读取**（照 `_read_permissions` 的既有做法），**不得**出现在 `_handle_click` 的返回字典里（那份字典会被原样打印到 stdout，是模型可见内容），**不得**把它变成失败。**不用**现成的 `_log()` 记一行 —— 它打的是 `WORKER:` 前缀，测试侧只认 `browser-record:`，那样写出来判据根本读不到。
  **必须复位**：**在分发每一条命令之前**把它置回 `False`，只有"本次判成会开新页且界内确实没等到"才置 `True`。（条目原文写的是"每次 `_handle_click` 一开始先复位"；实现时改成在命令分发处复位 —— 这个键出现在每一条命令的记录里，只在点击里复位的话，点击之后那条 snapshot 的记录会带着上一次点击的值。design D4 已同步改。）
  **同时把既有的防泄漏断言收紧**：现在测试用的是"五个键名不许出现在模型可见返回里"的黑名单，新增第六个键不会被抓住，改成"模型可见返回的键集合等于允许集合"。
  **判据**：加一条用例 —— 一个 `target="_blank"`、处理器里 `preventDefault()` 且**不开窗**的链接，断言①点击仍返回成功、②该次记录里 `expected_new_tab_unfulfilled` 为 true、③模型可见返回里没有这个键；**紧接着在同一个 worker 进程里再点一次普通链接，断言第二条记录里该键为 `false`**（这条是复位的判据，不复位必红）；贴三次输出（两次记录行 + 一次返回内容）。再跑一次收紧后的防泄漏断言：人为往返回字典里塞一个新键 ⇒ 必须红（贴输出）。
  **实测（2026-10-03）**：①点击成功，读数 5079 毫秒（走满 5 秒界）；②记录行里 `"expected_new_tab_unfulfilled":true`，模型可见返回的键仍是 `ok/url/title/snapshot/snapshot_len/truncated` 六个；③同一进程里的下一次点击（原地跳转）记录为 `false`。防泄漏变异：往 `_snapshot` 的返回里加一个 `leaked_probe` 键 ⇒ 用例红（`Actual: Set:['leaked_probe', …]`，`Which: larger than expected`），删掉后绿（贴输出）。
- [x] 2.4 把 `_install_page_handler` 里那句与代码不符的注释改对（它写着"跟随是靠点击前后做页面集合差集实现的"，而差集根本不存在，跟随只发生在点击分支），并写明"计数"与"跟随"各自归谁、名单归谁维护。**重写 `_handle_click` 时必须保留**既有源码扫描用例钉住的 `_recheck_window_bounds("click")` 调用点。
  **判据**：`grep` 那段旧注释串不再出现（贴 grep 输出）；`flutter test test/integration/browser_worker_test.dart` 里那条源码扫描用例仍绿（贴输出）。

## 3. 同步用户文档（CLAUDE.md 的硬性同步规则）

- [x] 3.1 `Docs/user-guide/tools-browser.md`：两处写死的"1 秒"上限改成按点击类型区分 —— 点 `target="_blank"` 的链接最多等 5 秒、普通点击仍是 1 秒；"新页面出现得比这更慢，这一次点击就停在原页面"改成"超过该上限才停在原页面"。
  **判据**（**点名式**，因为文档现有两处措辞不同、其中一处把数字包在粗体记号里，负向 grep 必须两种写法都点）：
  ①正向：文档里存在一句写明"点 `target="_blank"` 的链接最多等 5 秒"、且存在一句写明"普通点击仍是 1 秒（或等价措辞）"（两条 grep 各命中一次，贴输出）；
  ②负向：`点击之后最多等 **1 秒**`（含粗体记号）与 `新页面出现得比这更慢` 都零命中（贴输出）—— 只写"`最多等 1 秒` 零命中"会漏掉粗体那一处（本机实测：那个串只命中"每次点击最多等 1 秒新标签页"那一行），执行者可以只改另一处就通过判据、文档继续写着错的 1 秒上限；
  ③文中秒数与 `scripts/browser_worker.py` 的 `NEW_TAB_WAIT_SEC` / `NEW_PAGE_WAIT_SEC` 取值一致（把两边的 grep 都贴出来）；
  ④`flutter test test/unit/user_docs_test.dart` 仍绿（那份文档被一致性检查覆盖）。

## 4. 验证

- [x] 4.1 反例构造（防假绿）：临时把 `NEW_TAB_WAIT_SEC` 也改成 1.0（等于退回到"所有点击都只等 1 秒"），重跑 1.1 那条用例 ⇒ 必须变红；改回来 ⇒ 必须变绿。两个状态的输出都贴。**这一步是为了证明 1.1 的红确实由"窗口太短"造成，而不是别的原因。**
  **实测（2026-10-03）**：`NEW_TAB_WAIT_SEC = 1.0` ⇒ 1.1 那条用例红（`Expected: true / Actual: <false>`，点击后快照仍是原页面；点击记录 `adopted_tabs=0`、`expected_new_tab_unfulfilled=true`，之后那次 snapshot 记录 `tabs=2 / browser_opened=1` —— 新页确实开过、这一次没跟上）；改回 5.0 ⇒ 绿。变异标记已全部删除（`grep MUTATION-` 计数 0）。
- [x] 4.2 跑整个 `test/integration/browser_worker_test.dart` ⇒ 全绿，贴输出。
  **实测（2026-10-03）**：`01:02 +17: All tests passed!`（17 条，含本次新增的 5 条：1.5 秒晚到的新页被跟随、缺选择器仍是选择器超时、原地点击不多等、具名目标被跟随、记账键与复位）。
- [x] 4.3 `flutter analyze` + `python -c "import ast; ast.parse(...)"`：改动文件不得新增问题，贴输出。
  **实测（2026-10-03）**：`ast.parse OK`；`flutter analyze` = `171 issues found`（与本次改动前记录的 171 条同数，改动文件 `test/integration/browser_worker_test.dart` 在输出里零命中）。
- [x] 4.4 全量 `flutter test` 连跑 3 次
  **实测（2026-10-03，DLL 已是最新：`SYNC-OK: sidecar.dll already current`）**：三次都是 `All tests passed!`，读数 `01:09 +296` / `01:10 +296` / `01:09 +296`（改动前那次归档记录是 `+291`，多出的 5 条正是本次新增的用例）。三次跑的是同一份冻结代码：第一次启动后对 `_handle_click` 做过一次**仅注释**的修改，为免歧义已终止该次并重跑，上面三次都是重跑的结果。
- [x] 4.5 live 层（本变更改的正是这条行为）
  **实测（2026-10-03）**：连跑 3 次 `flutter test --tags live --run-skipped integration_test/browser_live_test.dart -d windows`，三次都 `All tests passed!`（第一次 `01:59 +1`，第二次 `01:25 +1`，第三次同样通过）。**关键读数（真实模型、真实网站）**：点搜索结果里那条 `target=_blank` 链接时，记录是 `{"tool":"click",…,"browser_opened":1,"adopted_tabs":1,"tabs":2}`，点击后快照的 URL 是 `https://flutter.dev/` —— 模型读到的是真正的落地页，而不是搜索结果页。
  **视觉验收（`read_image` 读 `test/live_visual/browser_live_*.png`）**：第一次的图里，模型报告"点开第一条结果后落在 `https://flutter.dev/`，标题 Flutter - Build apps for any screen"；最后一次的图（该目录每次运行都会被清空重写）里，模型报告点开第一条结果后落在 `https://zhuanlan.zhihu.com/p/37232700`，但知乎拒绝了自动访问（返回 JSON 403、没有 HTML 标题）—— 跟随本身是成功的（URL 就是真正的目标页），被拒是站点的反自动化行为。
  **OS 级窗口截图：这一项没有拿到，如实记（不静默跳过）**。共尝试 6 次（`desktop-screenshot` 的 full 模式 4 次、按标题 1 次、按前台窗口 2 次，外加一次用 `user32` 枚举窗口句柄的尝试），卡在两件事上：① 当时前台是一个"文件资源管理器"窗口，Edge 窗口在它后面，按标题截 Edge 拿回来的是遮挡它的那个窗口的像素；② AliasAgent 自己的窗口（`alias_agent`）截出来是一片空白矩形（Flutter 窗口的画面没有被屏幕 DC 抓到）。P/Invoke 枚举那次的标题匹配在本会话里没有解析出任何名字（返回句柄 0）。**结论：本会话无法产出可信的 OS 级截图；这一层的视觉证据只有应用内 PNG（上面两张）。** 需要补的话，得在窗口没有被遮挡、且用能抓合成窗口的方式重截。
- [x] 4.6 C++ 层（CLAUDE.md 验证清单第 4 条，缺一层即未验证）
  **实测（2026-10-03）**：`cmake --build sidecar/build/windows --config Debug` 成功（`sidecar.dll`、`sidecar_tests.exe` 都产出了）；`ctest` = `test cases: 237 | 236 passed | 1 failed`、`assertions: 3739 | 3738 passed | 1 failed`，与本次改动前记录的**同一组数字**（237/236/1、3739/3738/1）。失败的那条是联网 live 用例（`Rate guard: rapid-fire 5 consecutive ZhipuAI searches`，日志里 5 次 `Could not connect to server`；同批还有 `Kimi: connection error`），属**改动前就红**的既有项，不是本次引入。
- [x] 4.7 整套冒烟（CLAUDE.md 验证清单第 5 条）
  **实测（2026-10-03）**：`bash test/smoke/run_all.sh`（经 Git Bash；直接 `bash` 会落到 WSL，`utils.sh` 读 `$USERPROFILE` 会报 unbound variable 而跑不起来）= `Total: 2 passed, 3 failed`，逐项：Build PASS、Analyze FAIL、Checkpoints FAIL、Launch & Verify PASS、Visual Regression FAIL —— 与改动前记录的**同一组**（同样是 Analyze / Checkpoints / Visual Regression 三项红，Build 与 Launch & Verify 过），没有本次引入的新失败。

## 5. 收口实测结论与记账

- [x] 5.1 design 的 Open Question 1（5 秒这个上界够不够）
  **实测（2026-10-03）**：加了变体用例「a page opening 3s after the click is still inside the bound and followed」（同一条 1.5 秒用例的写法，`setTimeout(...,3000)`）⇒ 绿：`{"ok":true,…,"snapshot":"LANDING\n\n3s landing content"}`，命令耗时 **3121 毫秒**（走满它需要的 3 秒，没有白等剩下的 1.9 秒），记录 `browser_opened=1 / adopted_tabs=1 / tabs=2 / expected_new_tab_unfulfilled=false`。**这就是 5 秒这个上界的实测下界证据**：3 秒的延迟仍在界内且被跟随；仍然没有"点击到新页注册耗时"的分布读数（要按真实分布调这个数，得先加那个读数）。
- [x] 5.2 逐条核对 delta 里每一处义务（**核对单位是"含括注的义务"**）
  **实测（2026-10-03）核对清单**（义务 → 场景 → 任务）：
  ① 不逐步调用置顶 → 「Minimized window stays minimized during automation」→ 既有实现，不改码（既有源码扫描用例覆盖）；
  ② `alert`/confirm 自动处理、下载与权限抑制 → 「Dialogs are handled, downloads denied, permissions not granted」→ 既有实现，本变更不动；
  ③ 跟随新开的页（设计甲）→ 「Clicking a result follows the page it opens」→ 2.2；
  ④ 界由点击前读 `target` 决定（`_blank` 与具名/新窗口目标用长界）→ 「A named-target click gets the longer bound」+「An ordinary in-place click pays no extra wait」→ 2.1、2.2④；
  ⑤ 两个界都是上界、到页即返回 → 「A page that opens while the click is still running is followed without waiting out the bound」→ 2.2②（既有同步用例新增的"小于 3 秒"断言）+ 5.1（3 秒变体 3121 毫秒）；
  ⑥ 计时从点击返回之后起算 → 「The page wait is counted from after the click returns」→ 2.2（起算点已改，`wait_for_event` 在 `click` 返回之后才调用）；
  ⑦ 界外注册的页不跟随、返回原地结果 → 「A judged new-tab click that opens nothing is recorded, not failed」+「A new tab that registers later than the ordinary wait is still followed」→ 1.1（红态）、4.1（反例）；
  ⑧ 判成会开新页却没等到要记录、不算失败、不进模型可见内容 → 「A judged new-tab click that opens nothing is recorded, not failed」→ 2.3；
  ⑨ 预检失败按"不会开新页"且不得让点击失败 → 「The pre-click check itself failing never fails the click」→ 2.1 判据（缺选择器仍是选择器超时、30022 毫秒返回）；
  ⑩ 原标签页保留、会话关闭兜底 → 既有实现，不改码；
  ⑪ 已删的"单标签复用 / 显式关窗"不再回来 → 2.4（注释改正）+ 既有源码扫描用例；
  ⑫ 没有 `target`、由 JS 开页的点击保持普通界（非目标）→ 「An ordinary in-place click pays no extra wait」的 WHEN 措辞 → 2.2③；
  ⑬ 每步返回有界文本快照 → 「Text snapshot returned per step」→ 既有实现；
  ⑭ per-call 记录含各计数与新键 → 「The expected-but-not-observed flag is per call and stays out of the model's content」→ 2.3；
  ⑮ 每条记录只描述本次调用（不复位就粘住）→ 同上 → 2.3 的复位判据；
  ⑯ 模型可见返回只带自己的键、绝不带可观测量 → 同上 → 2.3（白名单 + 变异）；
  ⑰ `raise_count`/`popup_closed` 恒 0 不得当证据 → 「A counter that is structurally always zero is not usable evidence」→ 既有源码扫描用例。
  **残留检查**：delta 里 `poll`、`page set`、`pages`、`diffing`、`context.pages` 五个字样全部零命中 —— 被删的那层（不带事件泵动的轮询、把超时后看页面集合当作跟随晚到页的手段）没有残留；2.2 里"点击返回后立刻核名单、等待到期后再核一次"是保留项（补漏），不是被删的那层。
- [x] 5.3 规范里写死的秒数与代码常量一致
  **实测（2026-10-03）**：这条要求 grep「归档后的 `openspec/specs/browser-tool/spec.md`」；本 change 还没归档，所以核对的是将要合并进去的那份 delta（`openspec/changes/fix-browser-newtab-follow/specs/browser-tool/spec.md`）：正文写 `` `NEW_TAB_WAIT_SEC`, 5 seconds today `` 与 `` `NEW_PAGE_WAIT_SEC`, 1 second today ``，那条场景写"页面约 1.5s 后开、普通界 1s、这条点击的界 5s"；代码常量是 `NEW_TAB_WAIT_SEC = 5.0`、`NEW_PAGE_WAIT_SEC = 1.0` —— **两边一致**。归档时这份 delta 会整块替换主规范里的同名要求，秒数随文本一起过去，不需要另改。
- [x] 5.4 规范改写的留档（AGENTS.md 第 18 条：改既有判据要能溯源、不许放松、留下改前改后对照）
  **已做（2026-10-03）**：下面两段原文已抄在本条里，并在**本次 apply 的收尾报告里并排贴出**。
  **改前（`openspec/specs/browser-tool/spec.md` 的既有条文，节选）**：
  > … SHALL FOLLOW a newly-opened page (a click on a `target=_blank` result / a `window.open` popup) rather than closing it, so the AI reads the real landing page the click produced; the original tab stays open …
  >
  > #### Scenario: Clicking a result follows the page it opens
  > - **THEN** the tool SHALL FOLLOW that newly-opened page (make it the active page, wait for it to load, snapshot it) so the AI reads the real target page; the original tab stays open …
  **改后（本次 delta）**：
  > … SHALL FOLLOW a newly-opened page … provided the page registers within the bound that belongs to that click (the longer bound when the pre-click check judged the click opens a new page) …
  >
  > **The follow of a newly-opened page is bounded by a wait that belongs to that one click, and that wait is counted from the moment the click returns.** … A page that registers only after that bound is NOT followed … A failure to perform the pre-click check SHALL be treated as "does not open a new page" …
  **溯源**：用户拍板的"甲"（`openspec/changes/archive/2026-09-13-add-browser-tool/design.md` 的《设计变更（用户已拍板甲）》：保留多标签页、跟随新标签页）是"必须跟随"的来源；而"跟随有等待上界"是**改动前就存在的事实**（`scripts/browser_worker.py` 的 `NEW_PAGE_WAIT_SEC = 1.0`，以及归档 `2026-09-20-align-compaction-thresholds` 记录的间歇性失败现场），既有条文那句无条件承诺从写下起就与代码不符。
  **这次哪里更严**：改后新增四条可失败的义务（点击前判定界、计时从点击返回后起算、界内没等到要记账、预检失败不得让点击失败），并要求两个界都是上界；句子从"无条件跟随"变成"界内必须跟随、界外如实写进规范说不跟随"，是把做不到的承诺改成可验收的承诺，不是把判据改松。
