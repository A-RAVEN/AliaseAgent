## MODIFIED Requirements

### Requirement: Stay-hidden default and follow-new-tab (design 甲)
The system SHALL NOT call per-step bring-to-front. The system SHALL implement the mechanisms for `alert`/`confirm` auto-handling, download/permission suppression via a download cancel and Playwright's default auto-denial of permission requests / auto-dismissal of dialogs (no permission is granted; the worker additionally grants NO permissions up front via `grant_permissions([])`), and — per design 甲 (the user-chosen design decision) — SHALL FOLLOW a newly-opened page (a click on a `target=_blank` result / a `window.open` popup) rather than closing it, so the AI reads the real landing page the click produced; the original tab stays open and the AI manages multi-tab via the session (session-close is the fallback). The original "single-tab reuse via an explicit popup/new-tab close handler" is REMOVED by design 甲. Whether, on a triggering page, those mechanisms hold (no dialog, no download/permission granted) is external browser behavior: change task 1.4 confirmed alert/confirm auto-handling (dialog_count=2, page alive), download denial (dl.cancel() or accept_downloads=False, no file persisted), and that window.open + target=_blank open a new page (which design 甲 now FOLLOWS rather than closes). Permission suppression was confirmed by change task 1.6 on a real HTTPS secure-context page (permission.site): Playwright automation auto-denies permission requests by default — Notifications permission.query becomes 'denied' and Notification.requestPermission() resolves 'denied'; geolocation was not granted (getCurrentPosition returned error 3, a TIMEOUT — the request could not obtain a position within the 6s test timeout; permission.query stayed 'prompt', not 'denied'). Therefore no permission is granted (notifications denied; geolocation not granted). Design 甲 additionally calls `grant_permissions([])` at context creation (spike 2026-09-08: removes Bing's `edge://permission-request-dialog/`), which — as measured on the local worker record — makes BOTH notifications and geolocation query 'denied' up front.

**The follow of a newly-opened page is bounded by a wait that belongs to that one click, and that wait is counted from the moment the click returns.** The worker SHALL decide the bound BEFORE clicking, by reading the clicked element's target: `target=_blank` and equivalent named / new-window targets get the longer bound (`NEW_TAB_WAIT_SEC`, 5 seconds today), every other click keeps the ordinary bound (`NEW_PAGE_WAIT_SEC`, 1 second today). Both bounds are upper bounds only: the worker proceeds as soon as a new page appears, and SHALL NOT sit out the rest of the bound once a page has appeared. The bound SHALL be counted from after the click call returns — the time the click itself spends waiting for the element SHALL NOT be subtracted from the page wait. A page that registers only after that bound is NOT followed: the click returns its in-place result, and when the pre-click check expected a new page the worker SHALL record on its observability channel that a new tab was expected but not observed (never in the model-visible response, never as a failure). A failure to perform the pre-click check SHALL be treated as "does not open a new page" and SHALL NOT fail the click. The wait obligation above is decided by the clicked element's target attribute alone: a click whose element carries no `target` and opens a window only from the page's own script keeps the ordinary bound — that case is a documented non-goal of this change, not a promise.

#### Scenario: Minimized window stays minimized during automation
- **WHEN** the tool runs navigates/clicks while the window is minimized
- **THEN** if task 1.2 confirmed the window can be held minimized, it stays minimized and the tool does not raise it; otherwise the tool applies `--disable-backgrounding-occluded-windows` and operates user-visibly rather than claiming hidden-by-default; the outcome is recorded by task 1.2, not asserted as guaranteed. The occluded-by-an-overlapping-window case was measured by task 1.5 (a fullscreen topmost opaque window over the browser: commands execute, snapshot fresh, no render throttle), so the tool's off-screen execution holds for occlusion too.

#### Scenario: Clicking a result follows the page it opens
- **WHEN** the agent clicks a result link that opens a new tab (`target=_blank`) or a `window.open` popup
- **THEN** the tool SHALL FOLLOW that newly-opened page (make it the active page, wait for it to load, snapshot it) so the AI reads the real target page, provided the page registers within the bound that belongs to that click (the longer bound when the pre-click check judged the click opens a new page); the original tab stays open; the tool records the browser-opened / adopted-tab counts as observable. This is design 甲 — the original single-tab close (which dropped the landing page) is removed.

#### Scenario: A page that opens while the click is still running is followed without waiting out the bound
- **WHEN** the clicked element carries `target=_blank` / a named target and its new page registers while the click call itself is still running (the ordinary immediate case)
- **THEN** the tool SHALL follow that page and produce a response carrying it, and the click command SHALL return without sitting out the longer bound — the page wait is an upper bound, so a page that has already appeared is never waited for

#### Scenario: The page wait is counted from after the click returns
- **WHEN** the click itself takes noticeable time (the element appears late, the machine is loaded) and the new page registers within the bound measured from the moment the click returned
- **THEN** the tool SHALL still follow that page — the time the click spent waiting for the element SHALL NOT be subtracted from the page wait

#### Scenario: A named-target click gets the longer bound
- **WHEN** the clicked element's target is a name or a new-window target rather than the literal `_blank` (e.g. `target="landing"`)
- **THEN** the pre-click check SHALL judge it as opening a new page and that click SHALL use the longer bound

#### Scenario: A new tab that registers later than the ordinary wait is still followed
- **WHEN** the agent clicks a `target="_blank"` link whose new page registers after the ordinary wait window has already expired (planned deterministic case, task 1.1: the page opens about 1.5s after the click, the ordinary window is 1s, and the longer bound for such a click is 5s)
- **THEN** the tool SHALL follow that page (make it the active page, wait for it to load, snapshot it), so the response carries the landing page rather than the page that was clicked

#### Scenario: An ordinary in-place click pays no extra wait
- **WHEN** the pre-click check judged that this click does NOT open a new page (the element carries no `target=_blank` / named target), and no new page registers
- **THEN** the tool SHALL keep today's ordinary wait window (no additional delay), and the click's response SHALL be produced as it is today. A click that the pre-click check judged as opening a new page is governed by the longer bound instead — it is not this scenario

#### Scenario: A judged new-tab click that opens nothing is recorded, not failed
- **WHEN** the pre-click check concluded the click opens a new page, but the new page does not register within the bound for that click
- **THEN** the tool SHALL still return a successful response for the click (the in-place outcome), and SHALL record on its observability channel that a new tab was expected but not observed

#### Scenario: The pre-click check itself failing never fails the click
- **WHEN** the pre-click check (reading the clicked element's target) cannot be performed, e.g. the selector no longer matches or the element is removed
- **THEN** the tool SHALL proceed with the ordinary wait window as if the element does not open a new page, and SHALL NOT report the click as failed because of the pre-check

#### Scenario: Dialogs are handled, downloads denied, permissions not granted
- **WHEN** a page triggers an alert/confirm, or a download/permission prompt appears
- **THEN** the tool denies downloads by cancelling them, and relies on Playwright's default auto-dismissal of alerts/confirms and auto-denial of permission prompts (plus `grant_permissions([])` so no permission is granted up front); whether no dialog / no download / no permission-grant holds is confirmed by task 1.4 (alert/confirm auto-handling, download denial) and task 1.6 (no permission granted). The permission case was confirmed by task 1.6 on an HTTPS secure-context page: no permission granted (notifications denied; geolocation not granted — it timed out, permission.state 'prompt'). The tool SHALL NOT grant permission; Playwright's default auto-denial denies permission prompts (confirmed for the notifications path; for geolocation the permission.state stayed 'prompt'/undecided in the task-1.6 measurement, so the no-prompt behavior is not established there — though design 甲's `grant_permissions([])` denies geolocation up front in the worker record).

### Requirement: Text snapshot for a non-multimodal model
The system SHALL return, for each browser step, a text representation of the page (DOM inner-text / readable extraction) for the model, bounded/length-capped to control context cost. The worker SHALL expose an observable per-call record (tool name, input, result/status, snapshot length, plus tool-emitted bring-to-front count, browser-opened count, adopted-tab count, popup/new-tab-closed count, download-denied, permission-denied, active-tab count, and the "a new tab was expected but not observed" flag) for test attribution via a machine-readable channel (not in the model-visible snapshot text), and SHALL keep these counters out of the model-visible content. Each record SHALL describe that one call only: the "a new tab was expected but not observed" flag SHALL be decided by that call and SHALL NOT persist into later calls' records. The model-visible response SHALL carry only its documented keys and SHALL never carry an observability counter or flag.

**⚠️ round-12 更正（12.31）—— 上面两个计数器是"恒 0 的触发线"，不是可用证据**：`bring-to-front count`（`raise_count`）与 `popup/new-tab-closed count`（`popup_closed`）在本实现里**没有任何写入方**（只有初始化与读出），**结构上恒为 0**（`popup_closed` 在 design 甲 下更是死计数器 —— 新页是「跟随」而非「关闭」）。它们照旧被 emit（故本 SHALL 字面上仍成立），但**不得当作"未 emit bringToFront"的证据**；可强制执行的守卫是 `test/integration/browser_worker_test.dart` 里的源码扫描（对 `sidecar/src` 全部 `.cpp/.h` 扫 6 个 bring-to-front API + 对 worker 脚本扫其 bring-to-front 调用）。同见 `design.md` 与 `scripts/browser_worker.py` 中的 VACUITY 披露。

#### Scenario: Text snapshot returned per step
- **WHEN** the agent takes a snapshot of a text-bearing page
- **THEN** the tool returns the page's readable text (not a raw image), bounded to control context cost

#### Scenario: The expected-but-not-observed flag is per call and stays out of the model's content
- **WHEN** a click is judged as opening a new page and no new page registers within its bound, and then a later ordinary click runs in the same worker session
- **THEN** the first click's record carries the flag as true, the later click's record carries it as false (it does not persist), and neither click's model-visible response contains the flag or any other observability key (the response's key set equals its documented allow set)

#### Scenario: A counter that is structurally always zero is not usable evidence
- **WHEN** a reader of the per-call record wants to prove that no bring-to-front happened
- **THEN** the bring-to-front and popup-closed counters SHALL NOT be treated as that evidence (they have no writer and read 0 unconditionally); the enforceable guard is the source scan described above
