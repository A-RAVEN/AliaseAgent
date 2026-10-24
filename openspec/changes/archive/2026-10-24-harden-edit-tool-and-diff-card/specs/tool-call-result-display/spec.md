## ADDED Requirements

### Requirement: edit_file card shows the applied diff

Inside the **expanded** result area, when a settled `edit_file` tool call carries a non-empty `hunks` list, the card SHALL render a diff block in place of the plain result text. Each hunk SHALL render its start line number (`第 N 行`), then its removed text as one line per line prefixed with `-`, then its added text as one line per line prefixed with `+`. Removed lines and added lines SHALL be visually distinguishable from each other and from body text (distinct foreground and/or background color).

While the card is **collapsed**, its body SHALL keep today's behavior (the one-line `resultPreview`); the diff block SHALL NOT be rendered in the collapsed body, so the existing requirement "collapsed card with no structured data shows resultPreview" stays true.

This diff block replaces the plain string fallback **only** for an `edit_file` result that carries `hunks`; every other tool (and any `edit_file` result without `hunks`) keeps the existing string-based display.

Inside the expanded diff block the card SHALL display at most **12** content lines by default (用户在本次对话中选定，2026-10-18); line-number rows SHALL NOT count toward that limit. When the flattened diff exceeds 12 lines, the remaining lines SHALL be collapsed behind a marker that states the exact number hidden (`还有 N 行未显示，点击展开`), and activating the marker SHALL reveal every remaining line. The card SHALL NOT drop diff lines without such a marker.

#### Scenario: Small edit renders in full

- **WHEN** an `edit_file` call succeeds with one hunk whose removed and added text total 4 lines, and the result area is expanded
- **THEN** the card SHALL show the line number, those 4 lines with `-`/`+` prefixes, and no collapse marker

#### Scenario: Collapsed card does not render the diff

- **WHEN** an `edit_file` result with hunks is displayed while the result area is collapsed
- **THEN** the body SHALL show the one-line result text and SHALL NOT contain any `第 N 行` row

#### Scenario: Large edit collapses with an exact count

- **WHEN** the flattened diff totals 30 content lines in the expanded result area
- **THEN** the card SHALL show the first 12 content lines and a marker reading `还有 18 行未显示，点击展开`

#### Scenario: Expanding reveals everything

- **WHEN** the user activates the collapse marker
- **THEN** all remaining diff lines SHALL be shown and the marker SHALL disappear

#### Scenario: Multiple hunks are separated and ordered

- **WHEN** a call succeeds with three hunks at lines 3, 40 and 88
- **THEN** the expanded card SHALL render them in that order, each introduced by its own line-number row

#### Scenario: No hunks falls back to the text result

- **WHEN** a settled `edit_file` call has no `hunks` (an older session record, or a failed call)
- **THEN** the card SHALL render the existing string result exactly as before, with no diff block and no collapse marker

### Requirement: edit_file and write_file card titles show only the path

The collapsed and expanded header of an `edit_file` or `write_file` card SHALL show the tool name and the target path only (`edit_file(<路径>)` / `write_file(<路径>)`). The full argument list SHALL NOT be joined into the title. For a settled `edit_file` call carrying `hunks`, the title SHALL additionally show `+N/−M`, where N is the total number of added lines and M the total number of removed lines across all hunks; it SHALL NOT be shown when `hunks` is empty or absent.

#### Scenario: Title shows the path rather than every argument

- **WHEN** an `edit_file` call is displayed with `path`, `edits` (containing long `old_text`/`new_text` strings) as arguments
- **THEN** the title SHALL read `edit_file(<路径>)` and SHALL NOT contain the replacement texts

#### Scenario: Line totals appear once settled

- **WHEN** a settled `edit_file` call has hunks adding 3 lines and removing 1
- **THEN** the title SHALL show `+3/−1`

#### Scenario: Other tools keep their existing title

- **WHEN** a `read_file`, `list_dir`, `glob_file`, `grep_file`, `run_command`, `web_search`, or `web_fetch` card is displayed
- **THEN** its title SHALL be unchanged from the current behavior

### Requirement: edit hunks survive persistence and reload

`ToolCallActivity` SHALL carry an optional `hunks` list of `{start_line, old_text, new_text}` and SHALL serialize it into the stored tool-call JSON. Deserializing a record that lacks `hunks` SHALL yield an empty/absent value without error, and deserializing one that carries it SHALL restore every field so a reopened session renders the same diff block.

#### Scenario: Round trip preserves hunks

- **WHEN** a `ToolCallActivity` with two hunks is serialized with `toJson` and read back with `fromJson`
- **THEN** both hunks SHALL be restored with identical `start_line`, `old_text` and `new_text`

#### Scenario: Old records still load

- **WHEN** a stored tool-call JSON produced before this change (no `hunks` key) is deserialized
- **THEN** `fromJson` SHALL succeed and the card SHALL fall back to the text result

#### Scenario: Reopened session still shows the diff

- **WHEN** a session containing a persisted `edit_file` activity with hunks is reopened
- **THEN** the card SHALL render the diff block with the same line numbers and texts as when the call happened

### Requirement: Model-facing edit result names the changed lines

A successful `edit_file` call SHALL give the model a result text that names the changed line numbers. The text SHALL be composed, in order, of: `Edited <路径> (N replacements)`, then the existing optional `— matched with <matched_with>` segment (present exactly when the sidecar reported `matched_with`), then ` — 第 X、Y 行`, with X/Y taken from the hunks' `start_line` in ascending order and duplicates removed. When the response carries no usable `hunks` (older sidecar, or the oversized-hunks omission), the text SHALL be byte-identical to the pre-change text (including the optional `— matched with …` segment). Error texts SHALL NOT be rewritten: the `error` string produced by the sidecar is passed through to the model unchanged.

The line-number list SHALL itself be bounded: when it would exceed **8000 characters** (the repository's existing `kToolResultElisionThreshold`, reused rather than a new number), the text SHALL list only the leading entries and then state the exact total and where the full list lives — `共 N 处改动，其余行号见卡片`. The list SHALL NOT be cut without that statement.

#### Scenario: Success text names the lines

- **WHEN** `edit_file` succeeds with hunks whose `start_line` values are 12 and 40, and no normalization was used
- **THEN** the model-facing result text SHALL be `Edited <路径> (N replacements) — 第 12、40 行`

#### Scenario: Normalized match keeps its segment before the line numbers

- **WHEN** `edit_file` succeeds through whitespace normalization (`matched_with` present) with a hunk at line 7
- **THEN** the text SHALL read `Edited <路径> (N replacements) — matched with <matched_with> — 第 7 行`

#### Scenario: No hunks keeps the old wording

- **WHEN** the response carries no usable `hunks` (an older sidecar, or the oversized-hunks omission)
- **THEN** the model-facing result text SHALL equal the pre-change text byte-for-byte (with the optional `— matched with …` segment when the sidecar reported one), with no line numbers

#### Scenario: A huge line list is bounded and states the total

- **WHEN** a successful edit produces so many hunks that listing every `start_line` would exceed 8000 characters
- **THEN** the text SHALL contain the exact total (`共 N 处改动`) and the pointer `其余行号见卡片`, and SHALL NOT contain thousands of comma-separated line numbers

#### Scenario: Error text is passed through unchanged

- **WHEN** the sidecar returns `{"ok":false,"code":"stale","error":"cannot edit \"a.txt\": file changed since it was read; read it again before editing"}`
- **THEN** the model SHALL see that English sentence verbatim, and the card status SHALL be `error`

### Requirement: Persisted hunks do not change the context estimate

The stored `toolCallsJson` feeds two counters: the context estimator (`lib/services/context_estimator.dart`, characters ÷ 4 per message plus round overhead) and the occupancy readout's raw-span accumulation (`ContextBreakdown.fromTimeline`). Both SHALL exclude the `hunks` array and the oversized-omission marker, so a large edit cannot inflate the reported occupancy or trigger compaction early.

#### Scenario: Estimation ignores hunks

- **WHEN** the same assistant message with the same `edit_file` tool call is estimated once with a large `hunks` array and once without it
- **THEN** both estimates SHALL be equal

#### Scenario: Occupancy readout is unaffected

- **WHEN** a session performs an edit that produces a 200-line diff
- **THEN** the reported context occupancy (including the raw-span portion) and the compaction decision SHALL be the same as if the result carried no `hunks`

### Requirement: Requests never carry edit hunks

The live request path SHALL build each `tool_use` block from the same four fields the replay path uses (`type`, `id`, `name`, `input`), so that the per-call activity fields — including `hunks`, `result` and `resultPreview` — are never serialized into a request body. A `hunks` array as large as the 1MB cap SHALL therefore never reach the model service.

#### Scenario: Second request in the same tool round carries no hunks

- **WHEN** an `edit_file` call in a tool round produced hunks and the same round issues another request
- **THEN** the serialized `tool_use` block for that call SHALL contain only `type`, `id`, `name` and `input`

#### Scenario: Live and replay produce the same tool_use block

- **WHEN** the same stored tool call is sent live and replayed through `_buildApiMessages`
- **THEN** both `tool_use` blocks SHALL have the same four keys and the same values

### Requirement: Oversized diffs are visibly omitted on the card

When `edit_file` succeeds but the sidecar omitted `hunks` because they exceeded the size cap, the card SHALL state that the diff was omitted and why, together with the exact number of applied replacements (`diff 未显示：改动过大（N 处改动）`). The card SHALL NOT look identical to a call that simply had no changes to show.

#### Scenario: Omission is visible

- **WHEN** a settled `edit_file` result carries the oversized-omission marker and `replacements: 3`
- **THEN** the card SHALL show the omission sentence containing `3 处改动`, and SHALL NOT render an empty diff block

#### Scenario: Cards without the marker show nothing extra

- **WHEN** a settled `edit_file` result has hunks (or is an older record with neither hunks nor the marker)
- **THEN** the card SHALL NOT show the omission sentence
