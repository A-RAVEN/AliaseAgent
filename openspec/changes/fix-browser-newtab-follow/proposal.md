## Why

点一个会开新标签页的链接（`target="_blank"` 或 `window.open`）时，浏览器 worker 只等 **1 秒**（`scripts/browser_worker.py` 的 `NEW_PAGE_WAIT_SEC`）就断定"这次是原地跳转"，于是**不跟随新标签页**、快照停在被点的那张原页面上。机器一忙，弹窗注册得比 1 秒更晚 ⇒ 这个判定就错。后果有两层：

- **产品层**：AI 以为自己在看搜索结果页，实际上真正的落地页它一次都没看到（点进去的内容读不到）。
- **验证层**：`test/integration/browser_worker_test.dart` 里那条"点 `target=_blank` 要跟随新标签页"的用例，**单独跑必过、跟着全量套件跑约一半概率失败**（全量时机器负载高得多），让"全量测试全绿"这个验收口径变得不可信。

这条缺陷是 2026-09-20 在做另一个变更（上下文压缩阈值，已归档）时被暴露出来的；当时我判断错了根因（以为是"读取时机"而不是"等待窗口太短"），还改了一处**等价于没改**的代码，已撤回。现在按真实根因单独立项。

## What Changes

- **点击前先判断这个元素会不会开新标签页**：worker 在点击前读一次目标元素的 `target` 属性（`target="_blank"` 的锚点，或带 `window.open` 的点击处理器）。
- **会开新标签页 ⇒ 等得更稳**：现在的 1 秒窗口不变；窗口内没等到新页时，**再看一次"页面集合是不是多出来一个"**（把点击前的页面集合记下来做差），并在一段有界的时间内轮询确认。这样"弹窗来得晚"不会再被误判成"原地跳转"。
- **不会开新标签页 ⇒ 行为不变**：普通原地点击**不额外等待**，不牺牲日常点击的速度。
- **把这条行为写进规范**：`browser-tool` 的 `Stay-hidden default and follow-new-tab (design 甲)` 里补上"跟随新标签页这件事不得依赖一个固定的短窗口"和"等待必须有界、超时后要如实记录"。
- **补一条确定性复现用例**：测试页里放一个 `preventDefault` + `setTimeout(window.open, 1500)` 的链接，让新标签页**必然晚于那 1 秒窗口**才出现。这条用例在现在的代码上**稳定失败**（不再依赖"机器忙不忙"），修好后稳定通过。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `browser-tool`：现有条文 `Stay-hidden default and follow-new-tab (design 甲)` 及其场景 `Clicking a result follows the page it opens` —— 「跟随新标签页」这一条行为要补上稳健性要求：判定"这次是原地跳转"不能只看一个固定的短窗口；对**确实会开新标签页**的点击，等待与确认必须有界、且"没等到"要能被观测到。

## Impact

- **产品代码**：`scripts/browser_worker.py` 的 click 分支（判断是否开新标签页、等待与确认新页、超时后的记录）。
- **测试**：`test/integration/browser_worker_test.dart` 新增一条"新标签页来得比等待窗口更晚"的用例；既有那条"点 `target="_blank` 要跟随"的用例保留不动（它测的是正常时序）。
- **规范**：`openspec/specs/browser-tool/spec.md` 的 `Stay-hidden default and follow-new-tab (design 甲)`。
- **不做**（明确划界）：不动 `ctest` 里那条联网搜索用例的不稳定（另一件事）；不改"看不到窗口/最小化"相关的任何行为；不改多标签页的管理方式（新页照旧被跟随、原页照旧保留）；不新增任何对外的模型可见字段。
- **兼容性**：只影响"点击后等多久再下结论"这件事；原地点击的耗时不变；worker 与 sidecar 之间的报文格式不变。
