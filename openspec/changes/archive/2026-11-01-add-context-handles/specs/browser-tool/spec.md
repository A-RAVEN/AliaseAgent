## MODIFIED Requirements

### Requirement: Independent agent-driven browser
The system SHALL expose browser tools (`browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`) that are independent of `web_search`, letting the agent drive a real, user-visible browser to navigate, interact, and read pages. They SHALL share one persistent headed browser session **per context** — a task's successive steps land in the same session, while two different contexts get separate sessions with their own pages, cookies and storage. A single Python worker process SHALL host one browser process (`chromium.launch()` once) and give each context its own `BrowserContext`; instantiating a browser per context is forbidden. It SHALL support a `stats` command reporting the browser process identifier and live context count. Each context SHALL record the worker generation to which its browser session belongs. Process start, stop, handle replacement and generation advancement SHALL be serialized by one worker-lifecycle lock, with the command lock nested inside it; they SHALL NOT write shared handles outside that lock. Commands for an unknown context SHALL fail visibly and SHALL NOT silently create a fresh session. The tools SHALL be driven programmatically via the sidecar, NOT through a harness MCP (the model endpoint does not support MCP server tools). The lib/main.dart tool_use loop depth (Flutter client) needed for multi-step was confirmed by the change's pre-apply verification (task 1.1, 2026-09-06): the loop supports deep multi-step (`while(true)` loop, tool results fed back as user messages, 50-turn cap), so no extra front-end depth work was needed.

#### Scenario: Agent navigates and interacts across steps
- **WHEN** the agent issues successive browser commands (`browser_navigate`, `browser_click`, `browser_type`) in one task
- **THEN** they operate on the same persistent browser session, and the prior step's state carries to the next

#### Scenario: Two contexts do not share a browser session
- **WHEN** context 甲 navigates to page A and context 乙 then navigates to page B
- **THEN** 乙's navigation SHALL NOT move 甲's page; a `browser_snapshot` from 甲 SHALL still read page A

#### Scenario: Two contexts share one browser process
- **WHEN** the worker has contexts for 甲 and 乙 and reports `stats`
- **THEN** the reported browser process identifier SHALL be the same for both, and the context count SHALL be 2; a second `chromium.launch()` for 乙 SHALL make this fail

#### Scenario: A closed window is reported once per context
- **WHEN** the shared browser worker dies while both context 甲 and context 乙 have a session
- **THEN** each of 甲 and 乙 SHALL receive a detectable failure saying its window is gone before **that context** is allowed to continue; one context may report and reopen before the other calls again, but no context may skip its own failure

#### Scenario: Another context restarts the worker first
- **WHEN** the worker has died, context 甲 reports the death and successfully reopens the worker, and only then context 乙 issues its next command
- **THEN** 乙 SHALL still see a `dead:true` failure because its recorded worker generation is stale; it SHALL NOT receive `ok:true` from a silently created fresh page

#### Scenario: Unknown context is not implicitly opened
- **WHEN** the worker receives a navigate/click/type/snapshot command for a context that has no live `BrowserContext`
- **THEN** it SHALL return a distinguishable `dead:true` / unknown-context error and SHALL NOT create a `BrowserContext` implicitly; only an explicit open/retry MAY create it

#### Scenario: Two contexts start the browser at the same time
- **WHEN** 甲 and 乙 issue their first browser commands concurrently and no worker exists yet
- **THEN** exactly one worker/browser generation SHALL be created, both contexts SHALL receive sessions from that generation, and no process handle or generation counter SHALL be read/written outside the lifecycle lock

#### Scenario: Independent of the search tool
- **WHEN** a browser tool is used for a non-search purpose (e.g. fill a form, read a JS page)
- **THEN** it does not require or alter the `web_search` tool or its providers
