## Why

点一个会开新标签页的链接（`target="_blank"` 或 `window.open`）时，浏览器 worker 只等 **1 秒**（`scripts/browser_worker.py` 的 `NEW_PAGE_WAIT_SEC`）就断定"这次是原地跳转"，于是**不跟随新标签页**、快照停在被点的那张原页面上。机器一忙，弹窗注册得比 1 秒更晚 ⇒ 这个判定就错。后果有两层：

- **产品层**：AI 以为自己在看搜索结果页，实际上真正的落地页它一次都没看到（点进去的内容读不到）。
- **验证层**：`test/integration/browser_worker_test.dart` 里那条"点 `target=_blank` 要跟随新标签页"的用例，**单独跑必过、跟着全量套件跑约一半概率失败**（全量时机器负载高得多），让"全量测试全绿"这个验收口径变得不可信。

这条缺陷是 2026-09-20 在做另一个变更（上下文压缩阈值，已归档）时被暴露出来的；当时我判断错了根因（以为是"读取时机"而不是"等待窗口太短"），还改了一处**等价于没改**的代码，已撤回。现在按真实根因单独立项。

**2026-09-20 对抗审查后修订过一版**，改掉了三处会让人白干的设计（依据都写在 `design.md`）：

1. 原方案里"超时后再看一眼页面集合"这一层**删掉了** —— 它看的时间点早于晚到的弹窗（算术上必然看不到），而且这个做法在归档变更 `2026-09-13-add-browser-tool` 里**已被实测否决过**。
2. 原方案在 proposal 里写"1 秒窗口不变 + 有界轮询"，与 design 的"判定会开新页就用 5 秒窗口"互相矛盾 —— 统一成后者。
3. 原方案写"给既有条文补上稳健性要求"，但 delta 用的是新增需求，归档后既有条文一字不改、两句相反的话会并存 —— 改成**整块改写既有条文**（`## MODIFIED Requirements`）。

## What Changes

- **点击前先判断这个元素会不会开新标签页**：worker 在点击前读一次目标元素的 `target` 属性（`target="_blank"`，或等价的具名/新窗口目标）。这次读取**不等待元素、且有明确的小超时**；读不到、读失败、超时一律按"不会开新页"处理，绝不让判断本身把点击弄失败。
- **判定会开新页 ⇒ 这一次点击用更长的有界窗口**：`NEW_TAB_WAIT_SEC = 5` 秒；其余点击继续用现在的 1 秒。两个窗口都是**上界**：新页一到立即返回。**窗口从点击返回之后起算**（现在的代码是从点击之前起算，慢点击会把弹窗预算吃掉）。
- **不做"超时后看页面集合"这一层**：删掉。理由见 `design.md` 的 D3（时窗算术 + 已有实测否决 + 本机 Playwright 的页面集合是不泵动事件的本地读 + `expect_page` 已经覆盖了窗口内所有开页事件）。
- **"该开新页却没等到"要记一笔**：per-call 记录里新增一个布尔键 `expected_new_tab_unfulfilled`，值挂在会话属性上（不放进 `_handle_click` 的返回字典，绝不进模型可见内容），也**不算失败**。
- **把跟随义务收窄成"界内注册"并写进规范**：用 `## MODIFIED Requirements` 整块改写既有条文 `Stay-hidden default and follow-new-tab (design 甲)` —— 界内注册的新页必须跟随；界由点击前的预检决定；界外才注册的页不跟随（这条如实写进规范，不再留一句做不到的无条件承诺）。
- **补一条确定性复现用例**：页面由**本地 HTTP 服务**提供（Chromium 不会把新标签页导航到 `data:` URL），链接 `target="_blank"` + 点击处理器 `preventDefault()` + `setTimeout(() => window.open('/landing'), 1500)` —— 新标签页**必然晚于 1 秒窗口、早于 5 秒窗口**。这条用例在现在的代码上稳定失败，修好后稳定通过。
- **同步用户文档**：`Docs/user-guide/tools-browser.md` 现在写着"每次点击最多等 1 秒"，改完就错了，同一个变更里改掉（CLAUDE.md 的硬性同步规则）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `browser-tool`：**改写**既有条文 `Stay-hidden default and follow-new-tab (design 甲)`（连同它的三个场景整块替换）—— 把"必须跟随新开的页"限定为"在该次点击的等待界内注册的新页必须跟随"，界由点击前的预检决定（`target="_blank"` 一类用较长的界，其余用现在的界），并补上"界内没等到时要记录、但不算失败"与"预检失败不得让点击失败"。

## Impact

- **产品代码**：`scripts/browser_worker.py` —— 点击前的预检、两个窗口（含起算点改到点击返回之后）、per-call 记录新增一个键。
- **测试**：`test/integration/browser_worker_test.dart` 新增一条"新标签页比 1 秒窗口更晚"的确定性用例；既有那条"点 `target=_blank` 要跟随"的用例保留不动；重写 `_handle_click` 时**必须保留**既有源码扫描用例钉住的 `_recheck_window_bounds("click")` 调用点。
- **文档**：`Docs/user-guide/tools-browser.md` 的等待时长表述随代码同步。
- **规范**：`openspec/specs/browser-tool/spec.md` 的 `Stay-hidden default and follow-new-tab (design 甲)`（经 `## MODIFIED Requirements` 整块合并）。
- **不做**（明确划界）：不动 `ctest` 里那条联网搜索用例的不稳定（另一件事）；不改"看不到窗口/最小化"相关行为；不改多标签页管理方式；不新增任何对模型可见的字段；**不给"锚点没有 `target`、由 JS 开页且晚于窗口"这一类加支持**（现状如此，本变更只是把它如实写进规范）。
- **兼容性**：只影响"点击后等多久再下结论"；普通点击（无 `target`）的等待窗口不变；worker 与 sidecar 之间的报文格式不变；模型可见的返回内容一个字段都不加。
