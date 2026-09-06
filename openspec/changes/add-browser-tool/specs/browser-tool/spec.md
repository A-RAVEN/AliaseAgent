# Browser Tool — Spec

## ADDED Requirements

### Requirement: Independent agent-driven browser
The system SHALL expose browser tools (`browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`) that are independent of `web_search`, letting the agent drive a real, user-visible browser to navigate, interact, and read pages. They SHALL share one persistent headed browser session per task (multi-step), driven programmatically via the sidecar, NOT through a harness MCP (the model endpoint does not support MCP server tools). The lib/main.dart tool_use loop depth (Flutter client) needed for multi-step was confirmed by the change's pre-apply verification (task 1.1, 2026-09-06): the loop supports deep multi-step (`while(true)` @922, tool results fed back @1338, 50-turn cap @1347).

#### Scenario: Agent navigates and interacts across steps
- **WHEN** the agent issues successive browser commands (`browser_navigate`, `browser_click`, `browser_type`) in one task
- **THEN** they operate on the same persistent browser session, and the prior step's state carries to the next

#### Scenario: Independent of the search tool
- **WHEN** a browser tool is used for a non-search purpose (e.g. fill a form, read a JS page)
- **THEN** it does not require or alter the `web_search` tool or its providers

### Requirement: Programmatic control independent of window visibility
The system SHALL drive the browser programmatically (via browser-process protocol, not screen-level mouse simulation). Whether commands still execute and the page state stays readable while the window is minimized/occluded is external browser behavior: change task 1.2 confirmed the MINIMIZED case (commands execute, snapshot stays fresh, window NOT re-raised), and change task 1.5 confirmed the OCCLUDED-by-overlapping-window case (a fullscreen topmost opaque window over the browser: navigate/click/snapshot all succeed, snapshot stays fresh, requestAnimationFrame frame rate unchanged → no render throttling). Therefore off-screen (minimized/occluded) execution is supported and no `--disable-backgrounding-occluded-windows` was needed in the measurement. Honest caveat: the occlusion occluder was a synthetic fullscreen window and Chromium's internal occluded flag was not separately read, but the operational signal (working ops + unchanged frame rate) answers the requirement.

#### Scenario: Commands succeed while the window is not on-screen
- **WHEN** the browser window is minimized/hidden/occluded and the tool is operated
- **THEN** task 1.2 confirmed the minimized case (commands execute, snapshot fresh, not re-raised) and task 1.5 confirmed the occluded-by-overlapping-window case (commands execute, snapshot fresh, no render throttle); so the commands execute in the browser process and the page state is readable programmatically even when the window is minimized/hidden/occluded

### Requirement: Text snapshot for a non-multimodal model
The system SHALL return, for each browser step, a text representation of the page (DOM inner-text / readable extraction) for the model, bounded/length-capped to control context cost. The worker SHALL expose an observable per-call record (tool name, input, result/status, snapshot length, plus tool-emitted bring-to-front count, popup/new-tab-closed count, download-denied, permission-denied, and active-tab count) for test attribution via a machine-readable channel (not in the model-visible snapshot text), and SHALL keep these counters out of the model-visible content.

#### Scenario: Text snapshot returned per step
- **WHEN** the agent takes a snapshot of a text-bearing page
- **THEN** the tool returns the page's readable text (not a raw image), bounded to control context cost

### Requirement: Stay-hidden default and popup suppression
The system SHALL NOT call per-step bring-to-front. The system SHALL implement, via explicit popup/new-tab close handler + deny-downloads/permission-denial configuration, the mechanisms for single-tab reuse, `alert`/`confirm` auto-handling, and download/permission suppression. Whether, on a triggering page, those mechanisms actually hold (no new window/tab, no dialog, no download/permission granted) is external browser behavior: change task 1.4 confirmed popup/new-tab-close (window.open + target=_blank → back to 1 tab), alert/confirm auto-handling (dialog_count=2, page alive), and download denial (dl.cancel() or accept_downloads=False, no file persisted). Permission suppression was confirmed by change task 1.6 on a real HTTPS secure-context page (permission.site): Playwright automation auto-denies permission requests by default — Notifications permission.query becomes 'denied' and Notification.requestPermission() resolves 'denied'; geolocation was not granted (getCurrentPosition returned error 3, a TIMEOUT — the request could not obtain a position within the 6s test timeout; permission.query stayed 'prompt', not 'denied'). Therefore no permission is granted (notifications denied; geolocation not granted). No permission prompt is surfaced is confirmed for the Notifications path (Playwright auto-denies); for geolocation the permission.state stayed 'prompt' (undecided/pending), so the no-prompt behavior is NOT demonstrated for geolocation. Honest caveat: the geolocation case timed out (error 3) rather than being permission-denied and left the permission undecided, so it was not granted but the no-prompt behavior is not established for it. The tool SHALL NOT raise the window on its own per-step actions; any deliberate raise requires a separately-defined visibility-request mechanism, which is out of this change's scope (a future change).

#### Scenario: Minimized window stays minimized during automation
- **WHEN** the tool runs navigates/clicks while the window is minimized
- **THEN** if task 1.2 confirmed the window can be held minimized, it stays minimized and the tool does not raise it; otherwise the tool applies `--disable-backgrounding-occluded-windows` and operates user-visibly rather than claiming hidden-by-default; the outcome is recorded by task 1.2, not asserted as guaranteed. The occluded-by-an-overlapping-window case was measured by task 1.5 (a fullscreen topmost opaque window over the browser: commands execute, snapshot fresh, no render throttle), so the tool's off-screen execution holds for occlusion too.

#### Scenario: Dialogs are handled and no new windows or prompts
- **WHEN** a page triggers an alert/confirm, or a link opens a new window/tab, or a download/permission prompt appears
- **THEN** the tool applies its explicit popup/new-tab close handler + deny-downloads/permission-denial config and auto-dismisses alerts/confirms; whether single-tab reuse / no new window/tab / no dialog / no download holds is confirmed by task 1.4 (recorded and observable); if task 1.4 does not confirm it, the tool SHALL NOT represent suppression as guaranteed. The permission case was confirmed by task 1.6 on an HTTPS secure-context page: no permission granted (notifications denied; geolocation not granted — it timed out, permission.state 'prompt'). The tool SHALL NOT grant permission; its config auto-denies permission prompts (confirmed for the notifications path; for geolocation the permission.state stayed 'prompt'/undecided, so the no-prompt behavior is not established there).

### Requirement: Robustness against window close and state divergence
The system SHALL recover when the browser window/session is closed (a watchdog detects it and lets the AI relaunch), SHALL re-read the live snapshot before acting rather than trusting a prior snapshot, SHALL detect URL/content divergence (e.g. the user navigated away), and SHALL surface a user-takeover signal to the AI when manual navigation is detected.

#### Scenario: Window closed mid-task
- **WHEN** the user (or an error) closes the browser window/session during a task
- **THEN** the next browser command returns a detectable failure/state and the AI may reopen the session rather than silently acting on a dead browser

#### Scenario: User navigated away (divergence)
- **WHEN** the user manually navigated the browser to a different page than the AI's last snapshot
- **THEN** the tool detects the divergence (URL/content change) and surfaces it so the AI re-reads before acting

### Requirement: Graceful degradation / declaration gating
The system SHALL declare the browser tool(s) only when the required browser stack (Playwright + a usable Edge/Chromium) is available; when unavailable, the tool SHALL be absent or return a readable error, and SHALL NOT silently substitute a placeholder that misrepresents a browse. This is a policy for this change: declaration is gated on a **browser-runtime availability probe** (e.g. a sidecar `browser_available()` returning whether Playwright + a usable Edge/Chromium is present), and the browser tools are declared **outside** the `if (hasProviders)` block so they are **not** tied to search-provider availability — unlike `web_search`/`web_fetch`, which are declared under the `hasProviders` gate and `web_fetch` additionally degrades to a curl fallback rather than not declaring.

#### Scenario: Browser stack unavailable
- **WHEN** Playwright/Edge is not present at runtime
- **THEN** the browser tool is not advertised (or returns a readable "browser unavailable" error), rather than pretending to browse
