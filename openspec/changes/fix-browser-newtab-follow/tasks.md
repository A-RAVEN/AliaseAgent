## 1. 先捕获红态：把"新标签页来得比等待窗口更晚"变成确定性复现

- [ ] 1.1 在 `test/integration/browser_worker_test.dart` 新增一条用例：页面由**本地 HTTP 服务**提供（照既有那条 `target=_blank` 用例的写法：`HttpServer.bind(InternetAddress.loopbackIPv4, 0)` 加一条 `/landing` 路由；**不能用 `data:` URL** —— 既有用例的注释写明 Chromium 不会把新标签页导航到 `data:` URL）。页面里放一个链接 `id='slow'`：`target="_blank"`、点击处理器先 `preventDefault()`、再 `setTimeout(() => window.open('/landing'), 1500)` —— 新标签页**必然晚于 1 秒窗口、早于 5 秒窗口**才开。断言按既有那条用例的**同一套口径五条**：返回 `ok` 为真、快照含 `LANDING`、点击记录 `browser_opened > 0`、`adopted_tabs > 0`、`tabs >= 2`（后三条从 stderr 的 `browser-record:` 行读）。**另外加一步"红得可归因"**：点击之后**再发一次 snapshot**（时点在弹窗之后），断言它的记录 `tabs >= 2`（新页确实开过）而点击记录的 `adopted_tabs == 0`（没跟上）—— 记录里的计数是在点击返回之后才求值的，只打印点击返回的 JSON 分不清"等到 1 秒就走"和"弹窗根本没开"。
  **判据**：在**还没改** `scripts/browser_worker.py` 的代码上跑这一条，必须**稳定失败**：连跑 3 次都是红，且每次红时都能看到"新页确实开过（`tabs >= 2`）但点击没跟随（`adopted_tabs == 0`）"。把 3 次的输出都贴出来。这一条是本变更的红，也是将来的守卫。

## 2. 改 worker：跟随新标签页不再依赖那个固定短窗口

- [ ] 2.1 点击前判断"这个元素会不会开新标签页"：读目标元素的 `target` 属性（`_blank` 或具名/新窗口目标）。**这次读取必须不等待元素、且有显式小超时（500 毫秒以内）** —— worker 没有设置 Playwright 默认超时，等待式取值会继承 30 秒，加上点击自己的 30 秒正好撞上 sidecar 的 60 秒上限（超时即杀 worker），测试侧 45 秒还会先返回 `worker response timeout`。**读取失败（选择器不匹配、元素已被移除、执行出错、超时）一律按"不会开新页"处理，绝不让判断本身的失败导致点击失败。**
  **判据**：加一条用例 —— 用一个不存在的选择器点击，断言①错误仍是"选择器超时/找不到元素"这一类（不是预检抛出来的异常）、②该命令在 45 秒内返回（贴两个数字：错误原文 + 实际耗时秒数）。
- [ ] 2.2 判定"会开新标签页"时，这一次点击改用更长的**有界**窗口 `NEW_TAB_WAIT_SEC = 5`（秒）；其余点击继续用现在的 1 秒。两个窗口都是上界：新页一到立即返回。**并把起算点从不改成"点击返回之后"**：现在 `page.click(...)` 被包在 `expect_page` 块里，计时从点击**之前**开始，慢点击会把弹窗预算吃掉；改法是点击前先记下页面集合（兜住点击期间就注册的新页）、执行点击、点击返回之后再有界地等新页事件。
  **判据**：1.1 那条用例由红转绿；并加一条"普通点击不多等"的用例 —— 点一个原地跳转的链接，断言该命令的总耗时**小于一个写死的秒数**（取 3 秒；贴实际耗时数字），这条要能失败（把 `NEW_PAGE_WAIT_SEC` 改成 5 就会红）。
- [ ] 2.3 "判定会开新页、但窗口内没等到新页"时，在 per-call 记录（stderr 的 `browser-record:` 行）里加布尔键 `expected_new_tab_unfulfilled: true`。**值挂在会话属性上、由 `_emit_record` 读取**（照 `_read_permissions` 的既有做法），**不得**出现在 `_handle_click` 的返回字典里（那份字典会被原样打印到 stdout，是模型可见内容），**不得**把它变成失败。**不用**现成的 `_log()` 记一行 —— 它打的是 `WORKER:` 前缀，测试侧只认 `browser-record:`，那样写出来判据根本读不到。**同时把既有的防泄漏断言收紧**：现在测试用的是"五个键名不许出现在模型可见返回里"的黑名单，新增第六个键不会被抓住，改成"模型可见返回的键集合等于允许集合"。
  **判据**：加一条用例 —— 一个 `target="_blank"`、处理器里 `preventDefault()` 且**不开窗**的链接，断言①点击仍返回成功、②记录里 `expected_new_tab_unfulfilled` 为 true、③模型可见返回里没有这个键；贴两次输出（记录行 + 返回内容）。再跑一次收紧后的防泄漏断言：人为往返回字典里塞一个新键 ⇒ 必须红。
- [ ] 2.4 把 `_install_page_handler` 里那句与代码不符的注释改对（它写着"跟随是靠点击前后做页面集合差集实现的"，而差集根本不存在，跟随只发生在点击分支），并写明"计数"与"跟随"各自归谁。**重写 `_handle_click` 时必须保留**既有源码扫描用例钉住的 `_recheck_window_bounds("click")` 调用点。
  **判据**：`grep` 那段旧注释串不再出现（贴 grep 输出）；`flutter test test/integration/browser_worker_test.dart` 里那条源码扫描用例仍绿（贴输出）。

## 3. 同步用户文档（CLAUDE.md 的硬性同步规则）

- [ ] 3.1 `Docs/user-guide/tools-browser.md`：两处写死的"每次点击最多等 **1 秒**"（"点开会新标签页的链接会怎样"一节与"限制"一节）改成按点击类型区分 —— 点 `target="_blank"` 的链接最多等 5 秒、普通点击仍是 1 秒；"新页面出现得比这更慢，这一次点击就停在原页面"改成"超过该上限才停在原页面"。
  **判据**：`grep` 该文档不再出现"最多等 1 秒"（贴输出）；文中秒数与 `scripts/browser_worker.py` 的 `NEW_TAB_WAIT_SEC` / `NEW_PAGE_WAIT_SEC` 取值一致（把两边的 grep 都贴出来）；`flutter test test/unit/user_docs_test.dart` 仍绿（那份文档被一致性检查覆盖）。

## 4. 验证

- [ ] 4.1 反例构造（防假绿）：临时把 `NEW_TAB_WAIT_SEC` 也改成 1.0（等于退回到"所有点击都只等 1 秒"），重跑 1.1 那条用例 ⇒ 必须变红；改回来 ⇒ 必须变绿。两个状态的输出都贴。**这一步是为了证明 1.1 的红确实由"窗口太短"造成，而不是别的原因。**
- [ ] 4.2 跑整个 `test/integration/browser_worker_test.dart` ⇒ 全绿，贴输出。
- [ ] 4.3 `flutter analyze` + `python -c "import ast; ast.parse(open('scripts/browser_worker.py',encoding='utf-8').read())"`（`python` 就是 sidecar 启动 worker 用的那个解释器，本机为 `python`）：改动文件不得新增问题，贴输出。
- [ ] 4.4 全量 `flutter test` 连跑 3 次（**附加观测**：这条用例原来约一半概率红，三次全绿有约八分之一的概率是碰巧，所以归因靠 1.1 与 4.1，不靠这一条）。**前置**：先让仓库根的 `sidecar.dll` 是最新的（`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`，即 CLAUDE.md 验证清单第 2 步）。**⚠️ 由主循环自己跑，禁止派子 agent 跑全量**（会拉起真实浏览器窗口）。贴三次的最后一行。
- [ ] 4.5 live 层（本变更改的正是这条行为）：`flutter test --tags live --run-skipped integration_test/browser_live_test.dart -d windows` ⇒ 贴输出；跑完用 `read_image` 读它留下的 `test/live_visual/browser_live_*.png` 做视觉验收（只看 "All tests passed" 不算过）；浏览器工具会开 OS 级独立窗口，按 `Docs/TESTING.md` 的要求另补一张 OS 全屏截图。配置或网络缺失导致跑不了时，按 `Docs/TESTING.md` §3.2 如实标注，**不得静默跳过**。

## 5. 收口实测结论与记账

- [ ] 5.1 design 的 Open Question 1（5 秒这个上界够不够）：加一条变体用例 —— 弹窗延迟改成 3 秒（仍在 5 秒内），断言仍被跟随 ⇒ 绿；贴输出。若 3 秒这条不稳或不被跟随，如实记录并把上界与依据写进 design。**不接受**"没见到更晚的情形"这类没有数据来源的结论（现在记录里没有任何"点击到新页注册耗时"的读数）。
- [ ] 5.2 逐条核对 delta 里每句 SHALL 都有对应场景与实现任务覆盖，**特别确认不再出现"超时后比较页面集合"这类已删设计的残留**（那份 delta 是整块改写既有条文的，抄错一句就会带进主规范）。贴核对清单：每条 SHALL → 对应的场景 → 对应的任务编号。
